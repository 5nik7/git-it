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
        status_parent[$child]=$dir; status_depth[$child]=$(($2 + 1)); recorded[$child]=${oids[i]}
        if [[ ! ${oids[i]} ]]; then
            status_dirs+=("$child"); unavailable[$child]=blocked; reasons[$child]='Unresolved submodule index entry'
            unsafe=1
        elif ((!registered)) || [[ -z ${by_path[$path]-} ]] || ! safe_child_path "$dir" "$path"; then
            status_dirs+=("$child"); unavailable[$child]=blocked; reasons[$child]='Unsafe or unregistered submodule'
            unsafe=1
        else
            status_discover "$child" "$(($2 + 1))" || unsafe=1
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

# Compute the prefix from registered edges, not from slash-separated names.
status_gutter() {
    local dir=$1 parent=${status_parent[$1]:-} column='' grand ancestor
    row_prefix='' detail_prefix=''
    if [[ $parent ]]; then
        ancestor=$parent
        while [[ -n ${status_parent[$ancestor]:-} ]]; do
            grand=${status_parent[$ancestor]}
            if [[ ${last_child[$grand]:-} == "$ancestor" ]]; then column="  $column"
            else column="$TREE_BAR $column"; fi
            ancestor=$grand
        done
        if [[ ${last_child[$parent]:-} == "$dir" ]]; then row_prefix="$column$TREE_END "; detail_prefix="$column  "
        else row_prefix="$column$TREE_FORK "; detail_prefix="$column$TREE_BAR "; fi
    elif [[ $dir == "${WIKI_ROOT:-}" ]]; then detail_prefix='  '
    else detail_prefix=$TREE_BAR; fi
    ui_columns
    local limit=$((UI_COLUMNS/3))
    if ((${#row_prefix}>limit)); then row_prefix="... ${row_prefix: -limit+4}"; detail_prefix="... ${detail_prefix: -limit+4}"; fi
}

status_tree_row() {
    local dir=$1 label=${1##*/} branch_role=branch repo_role=repo kind=${REPORT_KIND:-root}
    local REMOTE='' URL='' HOST='' OWNER='' PROTOCOL='' OWNED=false HOST_ICON='' SAFE_URL='' icon head
    local bar=$detail_prefix branch_display=$branch
    local -a spans=() fields=()
    if [[ -n ${status_parent[$dir]:-} ]]; then kind=submodule; fi
    if [[ $dir == "${WIKI_ROOT:-}" || ${WIKI_ONLY:-0} == 1 && $dir == "$ROOT" ]]; then kind=wiki; fi
    if ((FULL_PATHS)); then label=$dir
    elif [[ ${name_counts[$label]:-0} -gt 1 && $dir == "$ROOT/"* ]]; then label=${dir#"$ROOT/"}; fi
    if [[ ! ${unavailable[$dir]+set} ]] && select_remote "$dir"; then
        parse_url "$URL"; [[ $OWNED != true ]] || repo_role=repo_owned
    fi
    case $kind in
        wiki) ui_icon git.wiki '󱔘' ;;
        submodule) if [[ $HOST == github.com ]]; then ui_icon git.submodule_github ''; else ui_icon git.submodule ''; fi ;;
        *) case $HOST in github.com) ui_icon hosts.github "$HOST_ICON" ;; gitlab.com) ui_icon hosts.gitlab "$HOST_ICON" ;;
               bitbucket.org) ui_icon hosts.bitbucket "$HOST_ICON" ;; *) ui_icon git.repository "$HOST_ICON" ;; esac ;;
    esac
    icon=$REPLY; ui_git_style "$repo_role"; spans+=("$row_prefix" '' "${icon:+$icon }$label" "$REPLY")
    if [[ $branch_display == 'detached '* ]]; then branch_display=${branch_display#detached }; branch_role=detached; fi
    if [[ -z $branch_display ]]; then
        if [[ $state == missing || $state == blocked ]]; then branch_display=unavailable; else branch_display=unborn; fi
    fi
    ui_icon git.branch ''; icon=$REPLY; ui_git_style "$branch_role"; spans+=(" $icon$branch_display" "$REPLY")
    if [[ $ahead != null && $ahead != 0 ]]; then
        ui_icon git.ahead '󱦲'; icon=$REPLY; ui_git_style ahead; spans+=(" ${icon:-ahead }$ahead" "$REPLY")
    fi
    if [[ $behind != null && $behind != 0 ]]; then
        ui_icon git.behind '󱦳'; icon=$REPLY; ui_git_style behind
        if [[ $ahead == 0 || ! $icon ]]; then spans+=(' ' ''); fi
        spans+=("${icon:-behind }$behind" "$REPLY")
    fi
    if [[ $state == @(missing|blocked|conflict) || $view == verbose ]]; then ui_git_style "$state"; spans+=("  $state" "$REPLY"); fi
    local UI_WRAP_GUTTER="$bar "
    ui_spans 0 "${spans[@]}"
    if [[ ${pointer_changed[$dir]:-} ]]; then ui_spans 0 "$bar Pointer  " "$YELLOW" 'differs from parent index' ''; fi
    if [[ -n ${reasons[$dir]:-} ]]; then ui_spans 0 "$bar Reason  " "$YELLOW" "${reasons[$dir]}" ''; fi
    if [[ $state != @(missing|blocked) && ( $view == verbose || $view != short && $dir == "$ROOT" ) ]]; then
        ui_path "$dir"
        if [[ -z $HOST || $PROTOCOL == file ]]; then OWNER=''; fi
        fields=(Host "$HOST" Protocol "${URL:+$PROTOCOL}" Remote "$REMOTE" Upstream "${tracking#refs/remotes/}" Owner "$OWNER" Root "$REPLY")
        if [[ $view == verbose ]]; then
            head=unborn; if text_cmd git -C "$dir" rev-parse --verify HEAD 2>/dev/null; then head=$REPLY; fi
            fields+=(HEAD "$head" URL "$SAFE_URL" Tracking "${tracking:-unavailable}")
        fi
        if [[ $view == verbose && $dir == "$ROOT" && ${REPORT_MODE:-status} == info && -v F[parent] ]]; then
            ui_path "${F[parent]:-none}"; fields+=(Parent "$REPLY")
            ui_path "${F[outermost]}"; fields+=(Outermost "$REPLY")
        fi
        ui_tree_box "$bar" "${fields[@]}"
    fi
    local TREE_GUTTER="$bar " TREE_FILES=1
    status_files "$dir"
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
    local -A recorded=() pointer_changed=() status_parent=() status_depth=() last_child=() name_counts=() states=() starts=() sizes=()
    local -a visible=() file_paths=() file_codes=() file_oldpaths=()
    local dir branch tracking ahead behind state view total inspected=0 changed=0 incomplete=0 tree=0
    local parent idx count row_prefix detail_prefix
    local -x GIT_NO_LAZY_FETCH=1
    if ((OUTERMOST)); then ancestry; ROOT=${CHAIN[0]}; fi
    if ((!JSON)); then ui_prepare; if ui_tree_active; then tree=1; ui_tree_symbols; fi; fi
    view=${STATUS_VIEW:-${UI_GIT_VIEW:-default}}
    trap 'progress_stop' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    progress_start 'Discovering repositories'
    status_depth[$ROOT]=0
    status_discover "$ROOT" 0 || :
    if [[ -n ${WIKI_ROOT:-} && $WIKI_ROOT != "$ROOT" ]]; then
        status_depth[$WIKI_ROOT]=0
        status_discover "$WIKI_ROOT" 0 || :
    fi
    progress_stop
    total=${#status_dirs[@]}
    for dir in "${status_dirs[@]}"; do
        if [[ ${REPORT_SUBMODULES:-0} == 1 && $dir == "$ROOT" ]]; then continue; fi
        if [[ -n ${DEPTH_LIMIT:-} ]] && ((status_depth[$dir]>DEPTH_LIMIT)); then continue; fi
        progress_start 'Inspecting repositories' "$inspected" "$total"
        status_snapshot "$dir"
        ((inspected+=1))
        progress_stop
        if [[ ${REPORT_SUBMODULES:-0} == 1 && $state != @(missing|blocked) && -n ${recorded[$dir]:-} ]] &&
            text_cmd git -C "$dir" rev-parse --verify HEAD 2>/dev/null && [[ $REPLY != "${recorded[$dir]}" ]]; then
            pointer_changed[$dir]=1
        fi
        if [[ $state == clean && ! ${pointer_changed[$dir]:-} && ( $CMD == overview || ${DIRTY_ONLY:-0} == 1 ) ]]; then continue; fi
        [[ $state == clean && ! ${pointer_changed[$dir]:-} ]] || ((changed+=1))
        [[ $state != blocked && $state != missing ]] || incomplete=1
        visible+=("$dir"); states[$dir]=$state
        starts[$dir]=${#file_paths[@]}; sizes[$dir]=${#paths[@]}
        file_paths+=("${paths[@]}"); file_codes+=("${codes[@]}"); file_oldpaths+=("${oldpaths[@]}")
        parent=${status_parent[$dir]:-}; [[ ! $parent ]] || last_child[$parent]=$dir
        name_counts[${dir##*/}]=$((${name_counts[${dir##*/}]:-0}+1))
    done
    if ((JSON)); then printf '{"schema":1,"remote_state":"cached","repositories":['
    elif ((!tree)) && [[ $CMD != overview || $changed != 0 ]]; then
        [[ $CMD != overview ]] || printf '\n'
        ui_heading 'Git status'
    fi
    for idx in "${!visible[@]}"; do
        dir=${visible[idx]}; state=${states[$dir]}
        count=${sizes[$dir]}; parent=${starts[$dir]}
        paths=("${file_paths[@]:parent:count}"); codes=("${file_codes[@]:parent:count}"); oldpaths=("${file_oldpaths[@]:parent:count}")
        status_tracking "$dir"
        if ((JSON)); then
            ((idx == 0)) || printf ','
            status_json_row "$dir"
        elif ((tree)); then
            status_gutter "$dir"
            if ((idx)); then printf '%s\n' "${row_prefix%??}$TREE_BAR"; fi
            status_tree_row "$dir"
        else status_human_row "$dir"; fi
    done
    if ((JSON)); then
        if ((incomplete)); then printf '],"complete":false}\n'; else printf '],"complete":true}\n'; fi
    elif ((!tree)) && [[ $CMD != overview || $changed != 0 ]]; then
        ui_line "$total repositories / $changed changed or unavailable / $((total - changed)) clean" '' 2
        ui_line 'Remote state uses local tracking refs; no fetch performed.' '' 2
    elif [[ $tree == 1 && ( $view == verbose || ${#visible[@]} == 0 ) ]]; then
        ui_line "${#visible[@]} repositories / $changed changed or unavailable" '' 0
        if [[ $view == verbose ]]; then ui_line 'Remote state uses local tracking refs; no fetch performed.' '' 0; fi
    fi
    return "$incomplete"
}
