# Use the same literal completion source for --completion and installation.
completion() {
    local installed file
    case $1 in
        bash) installed=bash-completion/completions/git-it ;;
        zsh) installed=zsh/site-functions/_git-it ;;
        fish) installed=fish/vendor_completions.d/git-it.fish ;;
        *) die 2 'completion shell must be bash, zsh, or fish' ;;
    esac
    if [[ $DATA == "$BASE" ]]; then file=$DATA/completion/$1
    else file=${DATA%/*}/$installed; fi
    [[ -f $file && -r $file ]] || die 3 "cannot read completion for $1"
    cat -- "$file"
}

# Nested routes share one literal record protocol across the shell adapters.
# The last word is the current prefix. Only selector completion queries Git.
scope_candidate() {
    local role=$1 value=$2 description=$3
    [[ $value == "$prefix"* && $value != *[[:cntrl:]]* ]] || return 0
    printf 'candidate\t%s\t%s\t%s\n' "$value" "$description" "$role"
}

scope_selectors() {
    local query=$1 chain=$2 lead='' candidate
    if [[ $query == names && $prefix == *:* ]]; then
        lead=${prefix%:*}:
        chain+=${chain:+:}${lead%:}
    fi
    local -a args=()
    [[ -z $chain ]] || args+=("$chain")
    [[ -z $directory ]] || args+=(-C "$directory")
    # The optional chain follows the query; -C selects the initial base.
    while IFS= read -r -d '' candidate; do
        scope_candidate value "$lead$candidate" 'Registered submodule'
    done < <("$ENTRY" "__complete-submodule-$query" "${args[@]}" 2>/dev/null)
}

complete_scope() {
    (($#)) || return 0
    local prefix=${!#} flag arg description directory='' pending='' literal=0
    local scope='' action='' chain='' expecting_name=0 selected=0
    local -a positional=() actions=()
    while (($# > 1)); do
        arg=$1; shift
        if [[ $pending ]]; then
            [[ $pending != -C && $pending != --directory ]] || directory=$arg
            pending=''
        elif (( literal )); then positional+=("$arg")
        else
            case $arg in
                --) literal=1 ;;
                -C|--directory|--depth|--view|--color|--completion|--config|--message|-m) pending=$arg ;;
                --directory=*|-C=*) directory=${arg#*=} ;;
                -*) ;;
                *) positional+=("$arg") ;;
            esac
        fi
    done
    local lead=''
    if [[ ! $pending && $prefix == --*=* ]]; then
        pending=${prefix%%=*}
        lead=$pending=
    fi
    if [[ $pending ]]; then
        case $pending in
            -C|--directory) printf 'directory\t\t\n' ;;
            --config) printf 'file\t\t\n' ;;
            --view) for arg in default short verbose; do scope_candidate value "$lead$arg" View; done ;;
            --color) for arg in auto always never; do scope_candidate value "$lead$arg" Policy; done ;;
            --completion) for arg in bash zsh fish; do scope_candidate value "$lead$arg" Shell; done ;;
        esac
        return 0
    fi
    for arg in "${positional[@]}"; do
        if [[ -z $scope ]]; then
            scope=$arg
            [[ $scope != submodule ]] || expecting_name=1
        elif (( expecting_name )); then
            chain+=${chain:+:}$arg
            expecting_name=0
        elif [[ $scope == submodule && ! $action && $arg == submodule ]]; then
            expecting_name=1
        elif [[ $scope == submodule && ! $action && $arg == submodules ]]; then
            scope=submodules
        elif [[ -z $action ]]; then
            action=$arg
        else selected=1
        fi
    done
    case $scope in wiki|submodule|submodules) ;; *) return 0 ;; esac
    if (( ! literal )) && [[ $prefix == -* ]]; then
        local -a flags=(-C --directory --config --no-config --color --no-color --no-progress --completion
                        -h --help -V --version --json)
        if (( ! expecting_name )); then
            flags+=(--view --full-paths -s --short -v --verbose)
            case $scope:$action in
                submodules:) flags+=(--details --depth) ;;
                submodules:info) flags+=(--depth) ;;
                submodule:status|submodules:status) flags+=(--dirty) ;;
            esac
            case $action in
                sync) flags+=(--dry-run --init --remote) ;;
                publish)
                    flags+=(--dry-run --all --yes --message -m)
                    [[ $scope != submodules ]] || flags+=(--all-submodules) ;;
            esac
        fi
        for flag in "${flags[@]}"; do
            case $flag in
                -C|--directory) description='Select the working directory' ;;
                --config) description='Read a configuration file' ;;
                --no-config) description='Ignore configuration' ;;
                --color) description='Choose the color policy' ;;
                --no-color) description='Disable color' ;;
                --no-progress) description='Disable progress indicators' ;;
                --completion) description='Print shell completion source' ;;
                -h|--help) description='Show help' ;;
                -V|--version) description='Print version' ;;
                --json) description='Print JSON' ;;
                --view) description='Select the human output view' ;;
                -v|--verbose) description='Show additional details' ;;
                -s|--short) description='Use compact output' ;;
                --full-paths) description='Show absolute paths' ;;
                --depth) description='Limit submodule levels' ;;
                --details) description='Show remote and commit details' ;;
                --dirty) description='Show changed or blocked entries' ;;
                --dry-run) description='Preview without changes or network' ;;
                --init) description='Permit initializing missing submodules' ;;
                --remote) description='Advance configured submodule branches' ;;
                --all) description='Include unstaged files' ;;
                --yes) description='Accept the publication preview' ;;
                -m|--message) description='Use this commit message' ;;
                --all-submodules) description='Select every direct child subtree' ;;
            esac
            scope_candidate option "$flag" "$description"
        done
    elif (( expecting_name )); then
        scope_selectors names "$chain"
    elif [[ ! $action ]]; then
        case $scope in
            wiki) actions=(info status sync publish) ;;
            submodule) actions=(info status publish submodules submodule) ;;
            submodules) actions=(info status publish) ;;
        esac
        for arg in "${actions[@]}"; do
            case $arg in
                info) description='Show repository metadata' ;;
                status) description='Show working tree changes' ;;
                sync) description='Synchronize the repository tree' ;;
                publish) description='Preview and publish changes' ;;
                submodules) description='Inspect registered descendants' ;;
                submodule) description='Select a registered child' ;;
            esac
            scope_candidate command "$arg" "$description"
        done
    elif [[ $scope == submodules && ( $action == status || $action == publish ) && $selected == 0 ]]; then
        scope_selectors paths "$chain"
    fi
}
