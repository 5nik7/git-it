# Local, parent-first Git status snapshots. The launcher disables optional locks.
# shellcheck shell=bash
# shellcheck source=lib/operations.bash
source "$LIB/operations.bash"
# shellcheck source=lib/git_views.bash
source "$LIB/git_views.bash"

status_discover() {
    local dir=$1 path child i unsafe=0 registered=1
    local -a paths=() oids=()
    local -A by_path=()
    status_dirs+=("$dir")
    if [[ -L $dir/.git || ( -e $dir/.git && ! -d $dir/.git && ! -f $dir/.git ) ||
          -L $dir/.gitmodules || ( -e $dir/.gitmodules && ! -f $dir/.gitmodules ) ]]; then
        unavailable[$dir]=blocked; reasons[$dir]='Unsafe repository metadata'
        return 1
    fi
    if [[ ! -d $dir ]] || ! repo_root "$dir" || [[ $REPLY != "$dir" ]]; then
        unavailable[$dir]=missing; reasons[$dir]='Repository is unavailable or uninitialized'
        return 0
    fi
    if ! children "$dir" status 2>/dev/null; then
        unavailable[$dir]=blocked; reasons[$dir]='Cannot inspect the index'
        return 1
    fi
    paths=("${CHILD_PATHS[@]}"); oids=("${CHILD_OIDS[@]}")
    if ((${#paths[@]})); then submodule_registrations "$dir" by_path status 2>/dev/null || registered=0; fi
    for i in "${!paths[@]}"; do
        path=${paths[i]}; child=${dir%/}/$path
        if [[ ! ${oids[i]} ]]; then
            status_dirs+=("$child"); unavailable[$child]=blocked; reasons[$child]='Unresolved submodule index entry'
            unsafe=1
        elif ((!registered)) || [[ -z ${by_path[$path]-} ]] || ! safe_child_path "$dir" "$path"; then
            status_dirs+=("$child"); unavailable[$child]=blocked; reasons[$child]='Unsafe or unregistered submodule'
            unsafe=1
        else
            status_discover "$child" || unsafe=1
        fi
    done
    if ((unsafe)); then
        # Git itself can recursively inspect submodule worktrees for a parent
        # status. Do not let that secondary traversal bypass the checks above.
        skip_submodules[$dir]=1
        return 1
    fi
}

status_tracking() {
    local dir=$1
    branch='' tracking='' ahead=null behind=null
    [[ ! ${unavailable[$dir]+set} ]] || return 0
    if text_cmd git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null; then branch=$REPLY
    elif text_cmd git -C "$dir" rev-parse --verify --short HEAD 2>/dev/null; then branch="detached $REPLY"; fi
    if text_cmd git -C "$dir" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null; then
        tracking=$REPLY
        if text_cmd git -C "$dir" rev-list --left-right --count "HEAD...$tracking" 2>/dev/null; then
            read -r ahead behind <<< "$REPLY"
        fi
    fi
}

status_snapshot() {
    local dir=$1 row xy i ignore=none
    paths=() codes=() oldpaths=()
    state=${unavailable[$dir]:-clean}
    [[ $state == clean ]] || return 0
    [[ ! ${skip_submodules[$dir]+set} ]] || ignore=all
    if ! records_cmd git -C "$dir" -c core.fsmonitor=false status --porcelain=v1 -z \
        --untracked-files=all --ignore-submodules="$ignore" 2>/dev/null; then
        state=blocked; reasons[$dir]='Cannot read worktree status'
        return 0
    fi
    for ((i=0; i<${#RECORDS[@]}; i++)); do
        row=${RECORDS[i]}; xy=${row:0:2}
        paths+=("${row:3}"); codes+=("$xy")
        if [[ $xy == *[RC]* ]]; then ((i+=1)); oldpaths+=("${RECORDS[i]}"); else oldpaths+=(''); fi
        if [[ $xy == *U* || $xy == AA || $xy == DD ]]; then state=conflict
        elif [[ $state == clean ]]; then state=modified; fi
    done
    # This snapshot covers ordinary files, but Git could not safely account
    # for all submodule changes. Do not claim the parent is clean.
    if [[ $ignore == all ]]; then
        reasons[$dir]='Submodule changes could not be fully inspected'
        [[ $state != clean ]] || state=blocked
    fi
}

status_json_row() {
    local dir=$1 i
    json_string "$dir"; printf '{"path":%s,' "$REPLY"
    json_string "$branch"; printf '"branch":%s,' "$REPLY"
    printf '"status":"%s","ahead":%s,"behind":%s,"files":[' "$state" "$ahead" "$behind"
    for i in "${!paths[@]}"; do
        ((i == 0)) || printf ','
        json_string "${paths[i]}"; printf '{"path":%s,' "$REPLY"
        json_string "${codes[i]}"; printf '"xy":%s,' "$REPLY"
        json_string "${oldpaths[i]}"; printf '"old_path":%s}' "$REPLY"
    done
    printf ']}'
}

status_human_row() {
    local dir=$1 label=${1##*/} branch_label=$branch repo_role=repo branch_role=branch
    local remote_icon=git.repository repo_icon branch_icon='' head
    local REMOTE='' URL='' HOST='' OWNED=false HOST_ICON='' SAFE_URL='' OWNER=''
    local -a spans=()
    if ((FULL_PATHS)); then label=$dir
    elif [[ $dir != "$ROOT" ]]; then label=${dir#"${ROOT%/}/"}; fi
    if [[ ! ${unavailable[$dir]+set} ]] && select_remote "$dir"; then
        parse_url "$URL"; [[ $OWNED != true ]] || repo_role=repo_owned
        case $HOST in github.com) remote_icon=hosts.github ;; gitlab.com) remote_icon=hosts.gitlab ;;
            bitbucket.org) remote_icon=hosts.bitbucket ;; esac
    fi
    ui_icon "$remote_icon" "$HOST_ICON"; repo_icon=$REPLY
    if [[ $branch == 'detached '* ]]; then branch_role=detached
    elif [[ $branch ]]; then ui_icon git.branch ''; branch_icon=$REPLY; fi
    if [[ ! $branch_label ]]; then
        if [[ $state == missing || $state == blocked ]]; then branch_label=unavailable
        else branch_label=unborn; fi
    fi
    ui_git_style "$repo_role"; spans+=("${repo_icon:+$repo_icon }$label" "$REPLY")
    ui_git_style "$branch_role"; spans+=("  $branch_icon$branch_label" "$REPLY")
    ui_git_style "$state"; spans+=("  $state" "$REPLY")
    if [[ $ahead == null ]]; then spans+=('  tracking unknown (cached)' '')
    else
        ui_git_style ahead; spans+=("  $ahead ahead" "$REPLY")
        ui_git_style behind; spans+=(" / $behind behind (cached)" "$REPLY")
    fi
    ui_spans 2 "${spans[@]}"
    [[ ! ${reasons[$dir]+set} ]] || ui_field Reason "${reasons[$dir]}"
    if [[ $view == verbose && ! ${unavailable[$dir]+set} ]]; then
        ui_field Path "$dir" path
        head=unborn; if text_cmd git -C "$dir" rev-parse --verify HEAD 2>/dev/null; then head=$REPLY; fi
        ui_field HEAD "$head"; ui_field Upstream "${tracking:-unavailable}"
        ui_field Remote "${REMOTE:-unavailable}"; ui_field URL "${SAFE_URL:-unavailable}"
        ui_field Owner "${OWNER:-unavailable}"
        # OWNERS is the configuration loaded by the entry point.
        # shellcheck disable=SC2153
        if ((${#OWNERS[@]})); then ui_field Owned "$OWNED"; else ui_field Owned unavailable; fi
    fi
    status_files "$dir"
}

status_main() {
    local -a status_dirs=() paths=() codes=() oldpaths=()
    local -A unavailable=() skip_submodules=() reasons=()
    local dir branch tracking ahead behind state view total inspected=0 changed=0 incomplete=0
    # A partial clone must report unavailable local state without fetching objects.
    local -x GIT_NO_LAZY_FETCH=1
    if ((OUTERMOST)); then ancestry; ROOT=${CHAIN[0]}; fi
    if ((!JSON)); then ui_prepare; fi
    view=${STATUS_VIEW:-${UI_GIT_VIEW:-default}}
    trap 'progress_stop' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    progress_start 'Discovering repositories'
    status_discover "$ROOT" || :
    progress_stop
    total=${#status_dirs[@]}
    if ((JSON)); then printf '{"schema":1,"remote_state":"cached","repositories":['
    elif [[ $CMD != overview ]]; then ui_heading 'Git status'; fi
    for dir in "${status_dirs[@]}"; do
        progress_start 'Inspecting repositories' "$inspected" "$total"
        status_snapshot "$dir"
        if [[ $CMD == overview && $state == clean ]]; then
            progress_stop
            ((inspected+=1))
            continue
        fi
        status_tracking "$dir"
        progress_stop
        if [[ $CMD == overview && $changed == 0 ]]; then
            printf '\n'
            ui_heading 'Git status'
        fi
        [[ $state == clean ]] || ((changed+=1))
        [[ $state != blocked && $state != missing ]] || incomplete=1
        if ((JSON)); then
            ((inspected == 0)) || printf ','
            status_json_row "$dir"
        else status_human_row "$dir"; fi
        ((inspected+=1))
    done
    if ((JSON)); then
        if ((incomplete)); then printf '],"complete":false}\n'; else printf '],"complete":true}\n'; fi
    elif [[ $CMD != overview || $changed != 0 ]]; then
        ui_line "$total repositories / $changed changed or unavailable / $((total - changed)) clean" '' 2
        ui_line 'Remote state uses local tracking refs; no fetch performed.' '' 2
    fi
    return "$incomplete"
}
