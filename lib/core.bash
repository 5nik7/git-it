# Shared CLI and data primitives. No repository mutation in this module.
# shellcheck disable=SC2034
die() {
    colors
    ui_error 'git-it' "$2"
    exit "$1"
}
canonical_dir() { (cd -- "$1" && pwd -P); }

# Preserve embedded AND trailing newlines, removing only the command's terminator.
text_cmd() {
    local rc
    REPLY=$("$@"; rc=$?; printf '.'; exit "$rc"); rc=$?
    REPLY=${REPLY%.}
    REPLY=${REPLY%$'\n'}
    return "$rc"
}

# Commands passed here must output NUL-terminated records. Preserve exit status.
records_cmd() {
    local last rc
    mapfile -d '' -t RECORDS < <("$@"; printf '\0%d\0' "$?")
    last=$((${#RECORDS[@]} - 1)); rc=${RECORDS[last]}
    unset 'RECORDS[last]'; unset 'RECORDS[last-1]'
    return "$rc"
}

json_string() {
    local s=$1 ch i n LC_ALL=C
    REPLY='"'
    for ((i=0; i<${#s}; i++)); do
        ch=${s:i:1}
        case $ch in
            '"') REPLY+='\"' ;; \\) REPLY+=$'\\\\' ;;
            *) printf -v n '%d' "'$ch"
               if ((n < 32)); then printf -v ch '\\u%04x' "$n"; fi
               REPLY+=$ch ;;
        esac
    done
    REPLY+='"'
}

display() {
    local s=$1 ch i n LC_ALL=C
    REPLY=''
    for ((i=0; i<${#s}; i++)); do
        ch=${s:i:1}; printf -v n '%d' "'$ch"
        if ((n < 32 || n == 127)); then printf -v ch '\\x%02x' "$n"; fi
        REPLY+=$ch
    done
}

# Diagnostics need only this small palette. Load optional presentation code
# on the first human report; shell prompt and machine routes skip the module.
declare -A UI_COLORS=()
UI_READY=0
color_enabled() {
    [[ ${JSON:-0} == 0 ]] || return 1
    [[ ${COLOR:-auto} == always ]] ||
        { [[ ${COLOR:-auto} == auto && -t $1 && -z ${NO_COLOR+x} ]]; }
}

colors() {
    BOLD='' RESET='' GREEN='' CYAN='' BLUE='' RED='' YELLOW=''
    ERR_RED='' ERR_RESET='' ERR_BOLD=''
    if color_enabled 1; then
        BOLD=$'\e[1m'; RESET=$'\e[0m'
        printf -v CYAN '\033[%sm' "${UI_COLORS[96]:-96}"
        printf -v BLUE '\033[%sm' "${UI_COLORS[94]:-94}"
        printf -v GREEN '\033[%sm' "${UI_COLORS[92]:-92}"
        printf -v RED '\033[%sm' "${UI_COLORS[91]:-91}"
        printf -v YELLOW '\033[%sm' "${UI_COLORS[93]:-93}"
    fi
    if color_enabled 2; then
        printf -v ERR_RED '\033[%sm' "${UI_COLORS[91]:-91}"
        ERR_RESET=$'\e[0m'; ERR_BOLD=$'\e[1m'
    fi
}

ui_prepare() {
    [[ ${UI_READY:-0} == 0 ]] || return 0
    # shellcheck source=lib/presentation.bash
    source "${BASH_SOURCE[0]%/*}/presentation.bash" || exit 3
    ui_load_preferences "$@"
}

ui_error() {
    local label=$1
    if [[ ${CMD:-} != path && -z ${GET:-}${completion_shell:-} &&
        ${FORMAT_SET:-0}${ICON:-0}${LIST_FIELDS:-0}${show_version:-0} == 0000 ]]; then
        ui_prepare 2
    fi
    display "$2"
    printf '%s%s:%s\n  %s\n' "$ERR_RED" "$label" "$ERR_RESET" "$REPLY" >&2
}

help() {
    ui_prepare
    local line label detail
    printf '\n'
    # DATA comes from the launcher and identifies its source or installed assets.
    # shellcheck disable=SC2153
    if [[ -f $DATA/logo.txt && -r $DATA/logo.txt && -s $DATA/logo.txt ]]; then
        while IFS= read -r line || [[ -n $line ]]; do ui_logo_line "$line"; done < "$DATA/logo.txt"
        printf ' '; ui_help_span description "Version $VERSION"; printf '\n'
    else
        ui_logo_line "git-it $VERSION"
    fi
    printf '\n'
    while IFS= read -r line; do
        case $line in
            Usage:*) ui_help_span heading 'Usage:'; ui_help_syntax "${line#Usage:}"; printf '\n' ;;
            *:) ui_help_span heading "$line"; printf '\n' ;;
            '  '[![:space:]]*)
                label=${line#  }; detail=''
                if [[ $label == *'  '* ]]; then detail="  ${label#*  }"; label=${label%%  *}; fi
                ui_help_row "$label" "${detail#"${detail%%[![:space:]]*}"}" ;;
            '       git-it'*) ui_help_syntax "$line"; printf '\n' ;;
            *) ui_help_span description "$line"; printf '\n' ;;
        esac
    done <<'EOF'
Usage: git-it [global options] [COMMAND] [options]
       git-it -i | --icon

With no command, show help. Outside a Git worktree, also warn and exit 3.

Commands:
  info                    Local repository and remote summary
  path                    Verified repository ancestry and directory fields
  status, -s, --status    Local changes in the repository and its submodules
  sync, --sync            Update parent, then nested submodules
  publish                 Preview, commit, and push children before parents
  submodule NAME [ACTION] Inspect or publish a registered child (parent:child for nested names)
  submodules [ACTION]     List registered descendants, inspect status/info or publish a selection
  wiki [ACTION]           Inspect, synchronize or publish the associated wiki

Global options:
  -C, --directory DIR     Inspect or operate from DIR
  --config FILE           Read Git-config syntax from FILE
  --no-config             Ignore user configuration
  --color auto|always|never, --no-color
  -v, --verbose           Show full paths and additional explanations
  --no-progress           Disable the terminal spinner and progress bar
  -h, --help              Show this help without requiring Git
  -V, --version           Show version
  --completion SHELL      Generate bash, zsh, or fish completion

Inspection and formatting:
  -i, --icon              Host icon only; empty outside Git
  --remote NAME           Choose an inspection remote
  -o, --owner             Print the full remote namespace
  -H, --host              Print the remote host
  -r, --repo              Print the remote repository name
  -p, --protocol          Print the remote protocol
  -R, --url               Print the sanitized remote URL
  --https                 Print the HTTPS URL, alone or with -R
  --get FIELD             Print one field (info or path)
  --json                  Structured output, without colors
  -f, --format FORMAT     Render {field} placeholders; {{ and }} are literals
  --list-fields           List available fields
  -n, --no-newline        Suppress final output newline

Report views:
  -s, --short                 Show a compact repository summary
  --view VIEW             Select default, short, or verbose output
  --full-paths            Show absolute paths in human reports
  --no-wiki               Exclude the associated wiki
  --depth N, --details    Limit descendant levels or show detailed submodule reports
  --dirty                 Show changed or unavailable submodules
  --all-submodules        Publish each registered direct child and its descendants

Recursive operations:
  --outermost             Start at the outermost verified parent
  --dry-run               Local preview only; no network or repository writes
  sync --init             Allow initializing missing submodules
  sync --remote           Advance submodules to explicitly configured branches
  publish --all           Include tracked and untracked changes, not just staged
  publish -m MESSAGE      Commit message (default: Sync via HOST on TIMESTAMP)
  publish --yes           Accept the preview without an interactive question

Sync continues safe siblings when a subtree is blocked. Publish blocks parents
whose required children failed. Neither command stashes, resets, or force-pushes.
Exit status: 0 complete; 1 failed/incomplete; 2 usage/config; 3 dependency/context.
EOF
}

load_config() {
    OWNERS=(); HOST_ALIASES=()
    [[ $NO_CONFIG == 1 ]] && return 0
    if [[ ! -e $CONFIG ]]; then
        [[ $EXPLICIT_CONFIG == 0 ]] && return 0
        die 2 'configuration file does not exist'
    fi
    [[ -f $CONFIG && -r $CONFIG ]] || die 2 'configuration must be a readable regular file'
    records_cmd git config --no-includes --null --file "$CONFIG" --list 2>/dev/null || die 2 'invalid configuration'
    local row key value configured_color=0
    for row in "${RECORDS[@]}"; do
        key=${row%%$'\n'*}; value=${row#*$'\n'}
        case $key in
            git-it.owner) [[ $value == */* && $value != *$'\n'* ]] || die 2 'owner must be host/namespace'; OWNERS+=("$value") ;;
            git-it.hostalias) [[ $value == *=* ]] || die 2 'hostAlias must be alias=hostname'; HOST_ALIASES+=("$value") ;;
            git-it.color) [[ $COLOR_SET == 1 ]] || COLOR=$value; configured_color=1 ;;
            *) die 2 "unknown configuration key: $key" ;;
        esac
    done
    if ((configured_color)); then COLOR_SET=1; fi
}

status_view() {
    case $1 in default|short|verbose) ;; *) die 2 'view must be default, short, or verbose' ;; esac
    [[ -z $STATUS_VIEW || $STATUS_VIEW == "$1" ]] || die 2 'conflicting status views'
    STATUS_VIEW=$1
}

main() {
    if [[ ${1:-} == __complete-scope ]]; then
        shift
        # shellcheck source=lib/completion.bash
        source "$LIB/completion.bash"; complete_scope "$@"; return
    fi
    local arg command_set=0 selector=0 show_help=0 show_version=0 completion_shell='' https=0
    local collection=0 need_name=0 scope_path='' all_submodules=0 no_wiki=0 literal=0 query=''
    local -a scope_names=()
    REPORT_SUBMODULES=0 REPORT_MODE='' REPORT_KIND='' DEPTH_LIMIT='' DIRTY_ONLY=0
    WIKI_ROOT='' WIKI_SOURCE='' WIKI_ONLY=0 WIKI_DECLARED=0 INIT=0
    CMD=info TARGET=. COLOR=auto COLOR_SET=0 CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/git-it/config
    NO_CONFIG=0 EXPLICIT_CONFIG=0 REMOTE_ARG='' FORMAT='' FORMAT_SET=0 GET='' JSON=0 ICON=0 NEWLINE=1
    OUTERMOST=0 DRY_RUN=0 ADVANCE=0 ALL=0 YES=0 MESSAGE='' LIST_FIELDS=0 VERBOSE=0 NO_PROGRESS=0
    STATUS_VIEW='' FULL_PATHS=0
    while (($#)); do
        arg=$1; shift
        if ((literal)); then
            if ((need_name)); then scope_names+=("$arg"); need_name=0
            elif ((collection)) && [[ ! $scope_path ]]; then scope_path=$arg
            else die 2 'unexpected positional argument'; fi
            continue
        fi
        if ((need_name)) && [[ $arg != -* ]]; then scope_names+=("$arg"); need_name=0; continue; fi
        case $arg in
            --directory=*|--config=*|--color=*|--get=*|--format=*|--message=*|--completion=*|--view=*|--depth=*)
                set -- "${arg#*=}" "$@"; arg=${arg%%=*} ;;
            --remote=*)
                [[ $CMD != sync ]] || die 2 'sync --remote takes no value'
                set -- "${arg#*=}" "$@"; arg=--remote ;;
            --*=*) die 2 "unexpected value for ${arg%%=*}" ;;
        esac
        case $arg in
            --) literal=1 ;;
            __complete-submodule-names|__complete-submodule-paths)
                [[ $command_set == 0 && -z $query ]] || die 2 'unexpected completion query'
                query=$arg
                if (($#)) && [[ $1 != -* ]]; then scope_names+=("$1"); shift; fi ;;
            submodule|submodules|wiki)
                ((command_set == 0 && !collection && !WIKI_ONLY && !need_name)) || die 2 'invalid nested command'
                case $arg in
                    submodule) need_name=1 ;;
                    submodules) collection=1 ;;
                    wiki) (( ${#scope_names[@]} == 0 )) || die 2 'wiki requires a source repository'; WIKI_ONLY=1 ;;
                esac ;;
            -s)
                if ((command_set)); then status_view short
                else CMD=status; command_set=1; fi ;;
            info|path|status|--status|sync|--sync|publish)
                ((command_set == 0)) || die 2 'only one command may be selected'
                case $arg in -s|--status) CMD=status ;; --sync) CMD=sync ;; *) CMD=$arg ;; esac
                command_set=1 ;;
            -C|--directory|--config|--color|--get|-f|--format|-m|--message|--completion|--view|--depth)
                (($#)) || die 2 "$arg requires a value"
                case $arg in
                    -C|--directory) TARGET=$1 ;; --config) CONFIG=$1; EXPLICIT_CONFIG=1 ;;
                    --color) COLOR=$1; COLOR_SET=1 ;;
                    --get) [[ -n $1 ]] || die 2 '--get requires a nonempty field'; GET=$1; ((selector+=1)) ;;
                    -f|--format) FORMAT=$1; FORMAT_SET=1; ((selector+=1)) ;;
                    -m|--message) MESSAGE=$1 ;;
                    --view) status_view "$1" ;;
                    --depth) [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] || die 2 'depth must be a positive integer'; DEPTH_LIMIT=$1 ;;
                    --completion) completion_shell=$1
                        [[ -n $completion_shell ]] || die 2 'completion shell must be bash, zsh, or fish' ;;
                esac; shift ;;
            --remote)
                if [[ $CMD == sync ]]; then ADVANCE=1
                else [[ -n ${1:-} ]] || die 2 '--remote requires a name for inspection'; REMOTE_ARG=$1; shift; fi ;;
            --no-config) NO_CONFIG=1 ;;
            --no-color) COLOR=never; COLOR_SET=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            --short) status_view short ;;
            --full-paths) FULL_PATHS=1 ;;
            --details) status_view verbose ;;
            --dirty) DIRTY_ONLY=1 ;;
            --no-wiki) no_wiki=1 ;;
            --init) INIT=1 ;;
            --all-submodules) all_submodules=1 ;;
            --no-progress) NO_PROGRESS=1 ;;
            -i|--icon) ICON=1; ((selector+=1)) ;;
            -o|--owner|-H|--host|-r|--repo|-p|--protocol|-R|--url)
                case $arg in
                    -o|--owner) GET=owner ;; -H|--host) GET=host ;; -r|--repo) GET=repo ;;
                    -p|--protocol) GET=protocol ;; -R|--url) GET=url ;;
                esac
                ((selector+=1)) ;;
            --https) https=1 ;;
            --json) JSON=1; ((selector+=1)) ;;
            -n|--no-newline) NEWLINE=0 ;;
            --list-fields) LIST_FIELDS=1 ;;
            --outermost) OUTERMOST=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --all) ALL=1 ;;
            --yes) YES=1 ;;
            -h|--help) show_help=1 ;;
            -V|--version) show_version=1 ;;
            *) if ((collection && command_set)) && [[ $arg != -* && -z $scope_path ]]; then scope_path=$arg
               else die 2 "unknown argument: $arg"; fi ;;
        esac
    done
    case $COLOR in auto|always|never) ;; *) die 2 'color must be auto, always, or never' ;; esac
    colors
    if ((show_help)); then help; return 0; fi
    if ((show_version)); then printf 'git-it %s\n' "$VERSION"; return 0; fi
    if [[ -n $completion_shell ]]; then
        # shellcheck source=lib/completion.bash
        source "$LIB/completion.bash"; completion "$completion_shell"; return $?
    fi
    if ((https)); then
        if ((selector == 0)); then ((selector+=1))
        elif [[ $GET != url && $GET != https_url ]]; then die 2 '--https requires URL output'; fi
        GET=https_url
    fi
    ((selector <= 1 && (LIST_FIELDS == 0 || selector == 0))) || die 2 'choose only one output selector'
    (( !need_name )) || die 2 'submodule requires a direct child name'
    if ((collection)); then
        if ((!command_set)); then CMD=status; REPORT_MODE=list; else REPORT_MODE=$CMD; fi
        case $CMD in status|info) ;;
            publish) [[ -n $scope_path && $all_submodules == 0 || -z $scope_path && $all_submodules == 1 ]] ||
                         die 2 'select one registered PATH or --all-submodules' ;;
            *) die 2 'submodules supports info, status and publish' ;;
        esac
        if [[ $REPORT_MODE == info && -n $scope_path ]]; then die 2 'use submodule NAME info for a single child'; fi
        [[ -n $scope_path ]] || REPORT_SUBMODULES=1
    elif ((${#scope_names[@]})); then
        case $CMD in info|status|publish) ;; *) die 2 'submodule supports info, status, publish and submodules' ;; esac
    elif ((WIKI_ONLY)); then
        case $CMD in info|status|sync|publish) ;; *) die 2 'wiki supports info, status, sync and publish' ;; esac
        (( !no_wiki )) || die 2 'wiki conflicts with --no-wiki'
    elif ((command_set == 0 && selector == 0 && !LIST_FIELDS && NEWLINE)) && [[ -z $REMOTE_ARG ]]; then
        CMD=usage
    fi
    if ((DIRTY_ONLY)) && { [[ $CMD != status ]] || ((!collection && ${#scope_names[@]} == 0)); }; then die 2 '--dirty requires submodule status'; fi
    if [[ -n $DEPTH_LIMIT ]] && { ((!collection)) || [[ $CMD == publish ]]; }; then die 2 '--depth requires submodule inspection'; fi
    if ((all_submodules)) && { ((!collection)) || [[ $CMD != publish ]]; }; then die 2 '--all-submodules requires submodules publish'; fi
    if ((OUTERMOST && (collection || WIKI_ONLY || ${#scope_names[@]}))); then die 2 '--outermost conflicts with an explicit scope'; fi
    if ((INIT)) && [[ $CMD != sync ]]; then die 2 '--init requires sync'; fi
    if ((VERBOSE)) && [[ $CMD != path && $CMD != usage ]]; then status_view verbose; fi
    if [[ -n $STATUS_VIEW || $FULL_PATHS == 1 ]] && [[ $CMD == path || $CMD == usage ]]; then die 2 'view options require a report command'; fi
    if [[ $CMD == status ]]; then
        if ((!NEWLINE || ICON + FORMAT_SET + LIST_FIELDS + DRY_RUN + ALL + YES != 0)) || [[ -n $GET || -n $REMOTE_ARG || -n $MESSAGE ]]; then
            die 2 'invalid option for status'
        fi
    elif [[ $CMD != sync && $CMD != publish ]]; then
        if ((OUTERMOST + DRY_RUN + ALL + YES != 0)) || [[ -n $MESSAGE ]]; then
            die 2 'operation options require sync or publish'
        fi
    else
        if ((ICON + FORMAT_SET + LIST_FIELDS != 0)) || [[ -n $GET || -n $REMOTE_ARG ]]; then
            die 2 'inspection options cannot be used with operations'
        fi
        if [[ $CMD == sync ]] && { ((ALL + YES != 0)) || [[ -n $MESSAGE ]]; }; then die 2 'publish options require publish'; fi
    fi
    command -v git >/dev/null 2>&1 || die 3 'Git is required'
    # Explicit -C must not be silently redirected by a caller's Git environment.
    [[ -z ${GIT_DIR+x}${GIT_WORK_TREE+x}${GIT_INDEX_FILE+x}${GIT_COMMON_DIR+x} ]] || die 3 'unset GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and GIT_COMMON_DIR'
    load_config
    case $COLOR in auto|always|never) ;; *) die 2 'color must be auto, always, or never' ;; esac
    ((JSON)) && COLOR=never
    colors
    # shellcheck source=lib/inspect.bash
    source "$LIB/inspect.bash"
    if ((LIST_FIELDS)); then list_fields; return 0; fi
    text_cmd canonical_dir "$TARGET" 2>/dev/null || die 3 'target must be an existing directory'
    TARGET=$REPLY
    if ! repo_root "$TARGET"; then
        if ((ICON || FORMAT_SET)); then return 0; fi
        if [[ $CMD == usage ]]; then
            { colors; ui_error 'git-it' 'not inside a Git worktree'; help; } >&2
            return 3
        fi
        die 3 'not inside a Git worktree'
    fi
    ROOT=$REPLY
    if [[ $CMD == usage && -z $query ]]; then help; return 0; fi
    if [[ -n $query || $CMD == status || $CMD == publish || $CMD == sync || $WIKI_ONLY == 1 || $collection == 1 ]] ||
       ((${#scope_names[@]})) || { [[ $CMD == info ]] && ((!selector && !no_wiki)); }; then
        # shellcheck source=lib/scope.bash
        source "$LIB/scope.bash"
        if [[ -n $query ]]; then scope_complete; return; fi
        scope_apply
    fi
    if [[ $CMD == status || $REPORT_SUBMODULES == 1 && $CMD == info || ${SCOPE_UNAVAILABLE:-0} == 1 ]]; then
        # shellcheck source=lib/status.bash
        source "$LIB/status.bash"
        status_main
    elif [[ $CMD == sync || $CMD == publish ]]; then
        operations_main
    else
        inspect_main
    fi
}
