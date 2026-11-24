# Ordered, incremental operations. Every failure is an explicit subtree result.
# shellcheck disable=SC2034

# shellcheck source=lib/progress.bash
source "${BASH_SOURCE[0]%/*}/progress.bash"

# Human sections receive raw label/value pairs. The legacy stream keeps its
# existing alignment; the selected terminal view measures and escapes each field.
operation_fields() {
    local section=$1 detail
    shift
    if ((OP_BOXES)); then ui_tree_box '  ' "$@"; return; fi
    while (($#)); do
        case $section in
            settings) ui_field "$1" "$2" ;;
            publish) printf -v detail '%-7s  %s' "$1" "$2"; ui_detail "$detail" ;;
            *) ui_detail "$2" ;;
        esac
        shift 2
    done
}

event() {
    local dir=$1 state=$2 reason=$3 shown=$1 label
    shift 3
    EVENT_DIRS+=("$dir"); EVENT_STATES+=("$state"); EVENT_REASONS+=("$reason")
    [[ $state != blocked && $state != failed ]] || RESULT=1
    [[ $state != cancelled ]] || CANCELLED=1
    if ((!JSON)); then
        progress_stop
        if ((!VERBOSE)); then
            if [[ $dir == "$ROOT" ]]; then shown=.
            elif [[ $dir == "${ROOT%/}/"* ]]; then shown=${dir#"${ROOT%/}/"}; fi
        fi
        # Selected paths are grouped once the complete preview is available.
        [[ $state != selected ]] || return 0
        if [[ $state == planned && $LAST_EVENT_DIR == "$dir" ]]; then
            operation_fields detail Note "$reason"
        else
            ui_status "$state" "$shown"
            # Preview uncertainty and actionable details are never hidden.
            if ((VERBOSE)) || [[ $OP_PHASE == preview || $state != @(updated|published|unchanged) ]]; then
                if (($#)); then operation_fields publish "$@"
                else
                    case $state in planned) label=Plan ;; blocked|failed|skipped) label=Reason ;; pending) label='Next step' ;; *) label=Detail ;; esac
                    operation_fields detail "$label" "$reason"
                fi
            fi
        fi
        LAST_EVENT_DIR=$dir
    fi
}

operations_heading() {
    ((JSON)) && return 0
    ui_prepare
    UI_GIT_VIEW=${STATUS_VIEW:-$UI_GIT_VIEW}
    [[ $UI_GIT_VIEW != verbose ]] || VERBOSE=1
    if ui_report_active; then OP_BOXES=1; ui_tree_symbols; ui_report_start; fi
    ui_heading "${CMD^}"
    local mode
    local -a settings=(Root "$ROOT")
    if [[ $CMD == sync ]]; then
        if ((ADVANCE)); then mode='Configured submodule branches'
        else mode='Pinned submodules'; fi
    elif ((ALL)); then mode='Tracked and untracked changes'
    else mode='Staged changes'; fi
    settings+=(Mode "$mode")
    if ((DRY_RUN)); then settings+=(Preview 'Local only; no network or writes'); fi
    operation_fields settings "${settings[@]}"
    printf '\n'
    if [[ $CMD == publish ]]; then ui_heading Preview; fi
}

cleanup_locks() {
    local dir
    progress_stop
    for dir in "${LOCKS[@]}"; do rmdir -- "$dir" 2>/dev/null || :; done
}

lock_repo() {
    local dir=$1 common
    ((DRY_RUN)) && return 0
    text_cmd git -C "$dir" rev-parse --git-common-dir || return 1
    common=$REPLY; [[ $common == /* ]] || common=$dir/$common
    text_cmd canonical_dir "$common" || return 1; common=$REPLY/git-it.lock
    [[ -v HELD[$common] ]] && return 0
    if ! mkdir -- "$common" 2>/dev/null; then
        event "$dir" blocked 'another git-it operation holds the lock (or a stale lock needs manual inspection)'
        return 1
    fi
    HELD[$common]=1; LOCKS+=("$common")
}

in_progress() {
    local dir=$1 name
    for name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
        text_cmd git -C "$dir" rev-parse --git-path "$name" || return 0
        [[ $REPLY == /* ]] || REPLY=$dir/$REPLY
        [[ ! -e $REPLY ]] || return 0
    done
    return 1
}

clean_own_files() {
    local dir=$1
    in_progress "$dir" && return 1
    git -C "$dir" diff --cached --quiet --ignore-submodules=none -- || return 1
    records_cmd git -C "$dir" status --porcelain=v1 -z --untracked-files=all --ignore-submodules=all || return 1
    ((${#RECORDS[@]} == 0))
}

# Return all stage-zero gitlinks, independent of submodule.active filters.
children() {
    local dir=$1 purpose=${2:-operation} row meta mode oid stage path last_conflict=''
    CHILD_PATHS=(); CHILD_OIDS=()
    records_cmd git -C "$dir" ls-files --stage -z || return 1
    for row in "${RECORDS[@]}"; do
        meta=${row%%$'\t'*}; path=${row#*$'\t'}
        read -r mode oid stage <<< "$meta"
        if [[ $stage != 0 ]]; then
            [[ $purpose == status ]] || return 1
            # Report ordinary conflicts through porcelain. An unresolved gitlink
            # is listed once with an empty OID so status can report that child.
            if [[ $mode == 160000 && $path != "$last_conflict" ]]; then
                CHILD_PATHS+=("$path"); CHILD_OIDS+=(''); last_conflict=$path
            fi
            continue
        fi
        if [[ $mode == 160000 ]]; then CHILD_PATHS+=("$path"); CHILD_OIDS+=("$oid"); fi
    done
}

safe_child_path() {
    local base=$1 path=$2 part cursor=$1
    [[ -n $path && $path != /* ]] || return 1
    while [[ -n $path ]]; do
        part=${path%%/*}
        [[ -n $part && $part != . && $part != .. ]] || return 1
        cursor+=/$part
        [[ ! -L $cursor ]] || return 1
        [[ ! -e $cursor || -d $cursor ]] || return 1
        [[ $path == */* ]] || break
        path=${path#*/}
    done
    [[ $cursor == "$base/"* ]]
}

submodule_registrations() {
    local dir=$1 purpose=${3:-operation} key value name
    local -n name_map=$2
    local -a keys=()
    # Read keys and values separately: both subsection names and path values
    # can contain newlines, making config's key-newline-value output ambiguous.
    records_cmd git -C "$dir" config --no-includes --null --name-only --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null || return 1
    keys=("${RECORDS[@]}")
    for key in "${keys[@]}"; do
        records_cmd git -C "$dir" config --no-includes --null --file .gitmodules --get-all "$key" || return 1
        if ((${#RECORDS[@]} != 1)); then
            [[ $purpose == status ]] || return 1
            # Each claimed path is ambiguous, even if another key also names
            # it. Unrelated siblings can still be inspected.
            for value in "${RECORDS[@]}"; do
                # shellcheck disable=SC2004
                [[ ! $value ]] || name_map[$value]=''
            done
            continue
        fi
        value=${RECORDS[0]}; [[ -n $value ]] || continue
        name=${key#submodule.}; name=${name%.path}
        # name_map is a reference to an associative array. Empty means more
        # than one registration claims the same indexed path.
        # shellcheck disable=SC2004
        if [[ ${name_map[$value]+set} ]]; then name_map[$value]=''
        else name_map[$value]="=$name"; fi
    done
    return 0
}

submodule_name() {
    local dir=$1 path=$2
    local -A by_path=()
    submodule_registrations "$dir" by_path || return 1
    REPLY=${by_path[$path]-}
    [[ -n $REPLY ]] || return 1
    REPLY=${REPLY#=}
}

upstream() {
    local dir=$1
    text_cmd git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || return 1; BRANCH=$REPLY
    text_cmd git -C "$dir" config --get "branch.$BRANCH.remote" || return 1; UP_REMOTE=$REPLY
    text_cmd git -C "$dir" config --get-all "branch.$BRANCH.merge" || return 1; UP_REF=$REPLY
    [[ $UP_REMOTE != . && $UP_REF == refs/heads/* && $UP_REF != *$'\n'* ]] || return 1
    git check-ref-format "$UP_REF" >/dev/null 2>&1 || return 1
    TRACKING="refs/remotes/$UP_REMOTE/${UP_REF#refs/heads/}"
    git check-ref-format "$TRACKING" >/dev/null 2>&1
}

fetch_branch() {
    progress_run Fetching git -C "$1" -c fetch.recurseSubmodules=false fetch --quiet --no-tags --no-recurse-submodules \
        --refmap= -- "$2" "$3:$4"
}

remote_contains() {
    text_cmd git -C "$1" for-each-ref --format='%(refname)' --contains "$2" refs/remotes/ 2>/dev/null && [[ -n $REPLY ]]
}

# Do not let a parent change remove/retype populated submodules or adopt an
# unrelated existing directory. Such topology edits need deliberate Git work.
safe_topology() {
    local dir=$1 target=$2 row meta path mode oid current
    local -A old=() next=()
    children "$dir" || return 1
    for path in "${CHILD_PATHS[@]}"; do old[$path]=1; done
    records_cmd git -C "$dir" ls-tree -r -z "$target" || return 1
    for row in "${RECORDS[@]}"; do
        meta=${row%%$'\t'*}; path=${row#*$'\t'}; read -r mode current oid <<< "$meta"
        [[ $mode == 160000 ]] || continue
        next[$path]=1
        safe_child_path "$dir" "$path" || return 1
        [[ -v old[$path] || ! -e $dir/$path ]] || return 1
    done
    for path in "${!old[@]}"; do [[ -v next[$path] ]] || return 1; done
}

sync_children() {
    local dir=$1 i path oid child
    local -a paths=() oids=()
    local progress_completed=0 progress_total=0
    if [[ -L $dir/.gitmodules || ( -e $dir/.gitmodules && ! -f $dir/.gitmodules ) ]]; then
        event "$dir" blocked 'unsafe submodule registration file'; return 1
    fi
    children "$dir" || { event "$dir" blocked 'cannot enumerate a conflict-free submodule index'; return 1; }
    paths=("${CHILD_PATHS[@]}"); oids=("${CHILD_OIDS[@]}")
    progress_total=${#paths[@]}
    for ((i=0;i<${#paths[@]};i++)); do
        progress_completed=$i
        path=${paths[i]}; oid=${oids[i]}; child=$dir/$path
        if ! safe_child_path "$dir" "$path" || [[ -L $child/.git ]] || ! submodule_name "$dir" "$path"; then
            event "$child" blocked 'unsafe path or missing/ambiguous .gitmodules entry'; continue
        fi
        if ! repo_root "$child" || [[ $REPLY != "$child" ]]; then
            if ((!INIT)); then event "$child" blocked 'not initialized; use sync --init to permit downloading this submodule'; continue; fi
            if ((DRY_RUN)); then event "$child" planned 'initialize at recorded commit; deeper structure requires download'; continue; fi
            # Refuse to adopt any nonempty directory, including hidden files.
            if [[ -d $child ]] && [[ -n $(find "$child" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
                event "$child" blocked 'uninitialized submodule directory is not empty'; continue
            fi
            if ! progress_run Initializing git --literal-pathspecs -C "$dir" -c submodule.recurse=false submodule update --init --checkout -- "$path"; then
                event "$child" failed 'initialization failed; check URL, credentials, and Git transport policy'; continue
            fi
        fi
        sync_node "$child" "$oid" "$dir" "$path" || :
    done
}

sync_node() {
    local dir=$1 pinned=${2:-} parent=${3:-} path=${4:-} before target name branch remote ref tracking attached=0
    [[ ! -v VISITED[$dir] ]] || { event "$dir" blocked 'repeated repository in traversal'; return 1; }
    VISITED[$dir]=1
    # The root has three local stages. Once children are enumerated their
    # parent supplies an actual sibling count for recursive activity.
    local count_stages=0 progress_completed=${progress_completed:-0} progress_total=${progress_total:-0}
    if ((!progress_total)); then count_stages=1; progress_total=3; fi
    progress_start 'Checking repository' "$progress_completed" "$progress_total"
    lock_repo "$dir" || return 1
    if ! clean_own_files "$dir"; then event "$dir" blocked 'local edits, staged changes, untracked files, or an operation in progress'; return 1; fi
    text_cmd git -C "$dir" rev-parse --verify HEAD || { event "$dir" blocked 'repository has no commit'; return 1; }; before=$REPLY
    if [[ -z $pinned ]]; then
        upstream "$dir" || { event "$dir" blocked 'root needs an attached branch with one configured upstream'; return 1; }
        remote=$UP_REMOTE; ref=$UP_REF; tracking=$TRACKING; attached=1
    elif ((ADVANCE)); then
        submodule_name "$parent" "$path" || return 1; name=$REPLY
        branch=''
        if text_cmd git -C "$parent" config --get "submodule.$name.branch" 2>/dev/null; then branch=$REPLY
        elif text_cmd git -C "$parent" config --file .gitmodules --get "submodule.$name.branch" 2>/dev/null; then branch=$REPLY; fi
        if [[ $branch == . ]]; then
            text_cmd git -C "$parent" symbolic-ref --quiet --short HEAD 2>/dev/null || { event "$dir" blocked 'branch=. requires an attached parent'; return 1; }; branch=$REPLY
        fi
        if [[ -n $branch ]]; then
            select_remote "$dir" || return 1; remote=${REMOTE:-origin}; ref=refs/heads/$branch; tracking=refs/remotes/$remote/$branch
            git check-ref-format "$ref" >/dev/null 2>&1 || { event "$dir" blocked 'invalid configured submodule branch'; return 1; }
        elif upstream "$dir"; then remote=$UP_REMOTE; ref=$UP_REF; tracking=$TRACKING
        else event "$dir" blocked '--remote requires a configured submodule branch or attached upstream'; return 1; fi
    fi
    if ((DRY_RUN)); then
        if [[ -z $pinned || $ADVANCE == 1 ]]; then
            event "$dir" planned "fetch and fast-forward/check out $remote/$ref; remote state not checked"
        else event "$dir" planned "check out parent-recorded commit $pinned; missing objects may need download"; fi
        sync_children "$dir"; return 0
    fi
    ((count_stages == 0)) || progress_completed=1
    progress_stop
    if [[ -z $pinned || $ADVANCE == 1 ]]; then
        if ! fetch_branch "$dir" "$remote" "$ref" "$tracking"; then event "$dir" failed 'fetch failed; check upstream, credentials, or rewritten remote history'; return 1; fi
        text_cmd git -C "$dir" rev-parse --verify "$tracking^{commit}" || return 1; target=$REPLY
    else
        target=$pinned
        if ! git -C "$dir" cat-file -e "$target^{commit}" 2>/dev/null; then
            select_remote "$dir" || return 1; remote=${REMOTE:-origin}
            if ! progress_run Fetching git -C "$dir" fetch --quiet --no-tags --no-recurse-submodules -- "$remote" "$target"; then
                event "$dir" failed 'recorded commit could not be fetched'; return 1
            fi
        fi
    fi
    ((count_stages == 0)) || progress_completed=2
    progress_start 'Checking update' "$progress_completed" "$progress_total"
    # Fetch can invoke credential helpers; recheck worktree state afterwards.
    if [[ $dir == "$WIKI_ROOT" ]] && ! wiki_recheck; then event "$dir" blocked 'wiki association changed during fetch'; return 1; fi
    if ! clean_own_files "$dir" || ! text_cmd git -C "$dir" rev-parse HEAD || [[ $REPLY != "$before" ]]; then
        event "$dir" blocked 'repository changed during fetch'; return 1
    fi
    if ((attached)); then
        if git -C "$dir" merge-base --is-ancestor "$target" HEAD; then
            event "$dir" unchanged 'already current or locally ahead; local commits retained'
        elif ! git -C "$dir" merge-base --is-ancestor HEAD "$target"; then
            event "$dir" blocked 'local and upstream histories diverged'; return 1
        elif ! safe_topology "$dir" "$target"; then
            event "$dir" blocked 'submodule removal, replacement, or occupied new path needs manual review'; return 1
        elif ! progress_run Updating git -C "$dir" -c submodule.recurse=false merge --ff-only --no-edit --no-overwrite-ignore "$target"; then
            event "$dir" failed 'fast-forward failed; local work was not reset'; return 1
        else event "$dir" updated 'fast-forwarded upstream'; fi
    elif [[ $before == "$target" ]]; then event "$dir" unchanged 'at selected submodule commit'
    else
        if ! remote_contains "$dir" "$before"; then event "$dir" blocked 'refusing to leave a submodule commit without remote reachability evidence'; return 1; fi
        if ! safe_topology "$dir" "$target"; then event "$dir" blocked 'submodule topology change needs manual review'; return 1; fi
        if ! progress_run 'Checking out' git -C "$dir" -c submodule.recurse=false checkout --quiet --detach --no-overwrite-ignore "$target" --; then
            event "$dir" failed 'submodule checkout failed; local work was not reset'; return 1
        else event "$dir" updated 'checked out selected commit; parent pointer is not staged'; fi
    fi
    sync_children "$dir"
}

# Snapshot all publish inputs, including unstaged/untracked contents for --all.
fingerprint() {
    local dir=$1
    # shellcheck disable=SC2016
    text_cmd bash -o pipefail -c '
        dir=$1; all=$2
        {
            git -C "$dir" rev-parse HEAD || exit
            git -C "$dir" status --porcelain=v1 -z --untracked-files=all --ignore-submodules=all || exit
            git -C "$dir" diff --cached --binary --no-ext-diff --no-textconv || exit
            if [[ $all == 1 ]]; then
                git -C "$dir" diff --binary --no-ext-diff --no-textconv --ignore-submodules=all || exit
                while IFS= read -r -d "" file; do
                    if [[ -L $dir/$file ]]; then readlink -- "$dir/$file" || exit
                    elif [[ -f $dir/$file ]]; then git hash-object --no-filters -- "$dir/$file" || exit
                    else exit 1; fi
                done < <(git -C "$dir" ls-files --others --exclude-standard -z)
            fi
        } | sha256sum
    ' bash "$dir" "$ALL"
}

collect_publish() {
    local dir=$1 parent=${2:-} path child
    local -a paths=()
    [[ ! -v VISITED[$dir] ]] || { event "$dir" blocked 'repeated repository'; return 1; }
    VISITED[$dir]=1; PARENT[$dir]=$parent
    lock_repo "$dir" || { BLOCKED[$dir]=1; return 1; }
    if [[ -L $dir/.gitmodules || ( -e $dir/.gitmodules && ! -f $dir/.gitmodules ) ]] || ! children "$dir"; then BLOCKED[$dir]=1; event "$dir" blocked 'conflicted index'; return 1; fi
    paths=("${CHILD_PATHS[@]}")
    for path in "${paths[@]}"; do
        child=$dir/$path
        if ! safe_child_path "$dir" "$path" || ! submodule_name "$dir" "$path" || [[ -L $child/.git ]] || ! repo_root "$child" || [[ $REPLY != "$child" ]]; then
            BLOCKED[$dir]=1; event "$child" blocked 'initialize the submodule before recursive publication'; continue
        fi
        collect_publish "$child" "$dir" || BLOCKED[$dir]=1
    done
    if ! fingerprint "$dir"; then BLOCKED[$dir]=1; event "$dir" blocked 'cannot snapshot publish inputs'; return 1; fi
    SNAPSHOTS[$dir]=$REPLY; PUB_DIRS+=("$dir")
}

publish_destination() {
    local dir=$1 row
    upstream "$dir" || return 1
    # Explicit upstream refspecs prevent push.default or push refspec surprises.
    if git -C "$dir" config --get-all "remote.$UP_REMOTE.push" >/dev/null 2>&1 ||
       git -C "$dir" config --get "branch.$BRANCH.pushRemote" >/dev/null 2>&1 ||
       git -C "$dir" config --get remote.pushDefault >/dev/null 2>&1; then return 1; fi
    text_cmd git -C "$dir" config --bool --get "remote.$UP_REMOTE.mirror" 2>/dev/null && [[ $REPLY == true ]] && return 1
    text_cmd git -C "$dir" remote get-url --push --all -- "$UP_REMOTE" || return 1
    [[ -n $REPLY && $REPLY != *$'\n'* ]] || return 1
    row=$REPLY; parse_url "$row"
    [[ $OWNED == true ]] || return 1
    if [[ $dir == "$WIKI_ROOT" && $WIKI_ONLY == 1 && $WIKI_DECLARED == 0 ]]; then
        scope_wiki_url_matches "$WIKI_SOURCE" "$row" || return 1
        parse_url "$row"
    fi
    PUSH_URL=$row
}

publication_needed() {
    local dir=$1 parent=${PARENT[$1]} path row meta index head
    git -C "$dir" diff --cached --quiet --ignore-submodules=none -- || return 0
    if ((ALL)); then
        records_cmd git -C "$dir" status --porcelain=v1 -z --untracked-files=all --ignore-submodules=all || return 0
        ((${#RECORDS[@]} == 0)) || return 0
    fi
    if [[ -n $parent ]]; then
        path=${dir#"$parent/"}
        text_cmd git -C "$dir" rev-parse HEAD || return 0; head=$REPLY
        records_cmd git -C "$parent" ls-files --stage -z -- ":(literal)$path" || return 0
        ((${#RECORDS[@]} == 1)) || return 0
        row=${RECORDS[0]}; meta=${row%%$'\t'*}; index=${meta#* }; index=${index%% *}
        [[ $index == "$head" ]] || return 0
    fi
    if upstream "$dir"; then
        git -C "$dir" rev-parse --verify "$TRACKING" >/dev/null 2>&1 || return 0
        git -C "$dir" merge-base --is-ancestor HEAD "$TRACKING" || return 0
    fi
    return 1
}

publish_preview() {
    local dir=$1 row parent=${PARENT[$1]} dest
    if [[ -v BLOCKED[$dir] ]]; then
        event "$dir" blocked 'required child or preflight check failed'
        [[ -z $parent ]] || BLOCKED[$parent]=1
        return 1
    fi
    if publication_needed "$dir" || [[ -v EXPECTED[$dir] ]]; then
        if in_progress "$dir" || ! publish_destination "$dir"; then
            BLOCKED[$dir]=1; [[ -z $parent ]] || BLOCKED[$parent]=1
            event "$dir" blocked 'needs an owned push URL, attached upstream, unambiguous push configuration, and no operation in progress'
            return 1
        fi
        dest="$SAFE_URL → $UP_REF"
        PREVIEW_DEST[$dir]=$PUSH_URL; PREVIEW_REF[$dir]=$UP_REF
        PREVIEW_REMOTE[$dir]=$UP_REMOTE; PREVIEW_BRANCH[$dir]=$BRANCH
        ((PUBLISH_CANDIDATES+=1))
        event "$dir" planned "branch $BRANCH: publish to $dest; message: $MESSAGE" \
            Branch "$BRANCH" 'Push to' "$SAFE_URL" Target "$UP_REF" Message "$MESSAGE"
        [[ -z $parent ]] || EXPECTED[$parent]=1
    else
        event "$dir" unchanged 'no selected changes or known ahead commits (remote state not fetched)'
        return 0
    fi
    records_cmd git -C "$dir" status --porcelain=v1 -z --untracked-files=all || return 1
    local i xy path old view=${STATUS_VIEW:-${UI_GIT_VIEW:-default}}
    local -a paths=() codes=() oldpaths=()
    for ((i=0;i<${#RECORDS[@]};i++)); do
        row=${RECORDS[i]}; xy=${row:0:2}; path=${row:3}; old=''
        if [[ $xy == *[RC]* ]]; then ((i+=1)); old=${RECORDS[i]}; fi
        if ((ALL)) || [[ ${xy:0:1} != ' ' && ${xy:0:1} != '?' ]]; then
            event "$dir" selected "$xy $path"
            if ((!JSON)); then paths+=("$path"); codes+=("$xy"); oldpaths+=("$old"); fi
        fi
    done
    if ((!JSON)); then
        ((VERBOSE == 0)) || view=verbose
        status_files "$dir"
    fi
    event "$dir" planned 'successfully published child pointers may also be staged; remote state requires fetch'
}

publish_node() {
    local dir=$1 parent=${PARENT[$1]} remote ref tracking before destination path child index head old row meta
    [[ ! -v BLOCKED[$dir] ]] || { event "$dir" blocked 'a required child or preflight check failed'; return 1; }
    if ! scope_still_registered "$dir"; then event "$dir" blocked 'registered scope changed after preview'; return 1; fi
    if ! fingerprint "$dir" || [[ $REPLY != "${SNAPSHOTS[$dir]}" ]]; then
        event "$dir" blocked 'publish inputs changed after preview'; return 1
    fi
    in_progress "$dir" && { event "$dir" blocked 'Git operation in progress'; return 1; }
    # A clean dependency can stay detached or foreign when its parent pointer
    # is unchanged. Otherwise it must pass the same publication checks.
    if ! publication_needed "$dir"; then event "$dir" unchanged 'no selected changes or known ahead commits'; return 0; fi
    if ! publish_destination "$dir"; then
        event "$dir" blocked 'publication requires an owned push URL, attached upstream, and unambiguous push configuration'; return 1
    fi
    if [[ $PUSH_URL != "${PREVIEW_DEST[$dir]:-}" || $UP_REF != "${PREVIEW_REF[$dir]:-}" ||
          $UP_REMOTE != "${PREVIEW_REMOTE[$dir]:-}" || $BRANCH != "${PREVIEW_BRANCH[$dir]:-}" ]]; then
        event "$dir" blocked 'branch or destination changed after the preview'; return 1
    fi
    remote=$UP_REMOTE; ref=$UP_REF; tracking=$TRACKING; destination=$PUSH_URL
    text_cmd git -C "$dir" rev-parse HEAD || return 1; before=$REPLY
    if ! fetch_branch "$dir" "$remote" "$ref" "$tracking"; then event "$dir" failed 'upstream fetch failed'; return 1; fi
    if ! git -C "$dir" merge-base --is-ancestor "$tracking" HEAD; then
        event "$dir" blocked 'remote is ahead or diverged; sync or resolve manually before publishing'; return 1
    fi
    if ! scope_still_registered "$dir" || ! fingerprint "$dir" || [[ $REPLY != "${SNAPSHOTS[$dir]}" ]] || ! publish_destination "$dir" ||
       [[ $PUSH_URL != "$destination" || $UP_REF != "$ref" || $UP_REMOTE != "$remote" || $BRANCH != "${PREVIEW_BRANCH[$dir]}" ]]; then
        event "$dir" blocked 'inputs or destination changed during preflight'; return 1
    fi
    if [[ $dir == "$WIKI_ROOT" ]] && ! wiki_publish_check recheck; then
        event "$dir" blocked 'wiki verification changed during preflight'; return 1
    fi
    if ((ALL)); then
        git -C "$dir" add --all -- . >/dev/null 2>&1 || { event "$dir" failed 'staging failed; inspect index'; return 1; }
    fi
    if ! git -C "$dir" diff --cached --quiet --ignore-submodules=none --; then
        if ! progress_run Committing git -C "$dir" commit -m "$MESSAGE"; then
            event "$dir" failed 'commit failed; staged changes retained (check identity and hooks)'; return 1
        fi
    fi
    if ! progress_run Pushing git -C "$dir" -c push.followTags=false push --porcelain --recurse-submodules=check -- "$destination" "HEAD:$ref"; then
        event "$dir" failed 'push failed; local commit retained and parent publication blocked'; return 1
    fi
    event "$dir" published 'selected changes and ahead commits pushed'
    # Pushing an explicit URL need not update a named remote-tracking ref.
    # Refresh evidence before Git checks availability in the parent's push.
    if ! fetch_branch "$dir" "$destination" "$ref" "$tracking"; then
        event "$dir" failed 'push completed, but refreshing remote evidence failed; parent remains blocked'; return 1
    fi
    if [[ -n $parent ]]; then
        # Parent may have deliberately staged an older pointer. Do not replace it.
        path=${dir#"$parent/"}
        records_cmd git -C "$parent" ls-files --stage -z -- ":(literal)$path" || return 1
        row=${RECORDS[0]}; meta=${row%%$'\t'*}; index=${meta#* }; index=${index%% *}
        records_cmd git -C "$parent" ls-tree -z HEAD -- ":(literal)$path" || return 1
        old=''; if ((${#RECORDS[@]})); then meta=${RECORDS[0]%%$'\t'*}; old=${meta##* }; fi
        text_cmd git -C "$dir" rev-parse HEAD || return 1; head=$REPLY
        if [[ $index != "$old" && $index != "$head" ]]; then
            event "$parent" blocked 'pre-existing staged child pointer differs; preserved for manual review'; return 1
        fi
        # Child worktree changes are excluded from the parent's fingerprint;
        # its own files and staged gitlinks must still match the preview.
        if ! fingerprint "$parent" || [[ $REPLY != "${SNAPSHOTS[$parent]}" ]]; then
            event "$parent" blocked 'parent changed during child publication'; return 1
        fi
        git -C "$parent" add -- ":(literal)$path" >/dev/null 2>&1 || return 1
        fingerprint "$parent" || return 1; SNAPSHOTS[$parent]=$REPLY
    fi
}

# Recheck the selected scope before any operation that can contact a remote.
wiki_recheck() {
    [[ -n $WIKI_ROOT ]] || return 0
    if ((WIKI_DECLARED)); then
        local path digest
        text_cmd python3 -IB "$LIB/wiki_scope.py" checkout "$WIKI_SOURCE" && path=$REPLY &&
            [[ $path == "$WIKI_ROOT" ]] && text_cmd python3 -IB "$LIB/wiki_scope.py" digest "$WIKI_SOURCE" &&
            digest=$REPLY && [[ $digest == "$WIKI_DIGEST" ]] && repo_root "$path" && [[ $REPLY == "$path" ]]
    else scope_sibling_matches "$WIKI_SOURCE" "$WIKI_ROOT"; fi
}

wiki_publish_check() {
    local phase=$1 source_revision wiki_revision=':'
    wiki_recheck || return 1
    ((WIKI_DECLARED)) || return 0
    upstream "$WIKI_SOURCE" || return 1
    if ((ALL)); then wiki_revision=''; fi
    source_revision=$wiki_revision
    if ((WIKI_ONLY)) || [[ $phase == execute || $phase == recheck ]]; then
        if [[ $phase == execute ]]; then fetch_branch "$WIKI_SOURCE" "$UP_REMOTE" "$UP_REF" "$TRACKING" || return 1; fi
        source_revision=$TRACKING
    fi
    python3 -IB "$LIB/wiki_scope.py" verify "$WIKI_SOURCE" "$WIKI_ROOT" "$WIKI_DIGEST" "$UP_REF" "$source_revision" "$wiki_revision"
}

operation_root_available() {
    local dir=$1
    if [[ $dir == "$WIKI_ROOT" ]]; then
        if [[ ! -e $dir && $WIKI_ONLY == 0 ]]; then event "$dir" skipped 'declared wiki checkout is missing'; return 1; fi
        if ! wiki_recheck; then event "$dir" blocked 'wiki association changed or checkout unavailable'; return 1; fi
    fi
    if [[ -L $dir/.git ]] || ! repo_root "$dir" || [[ $REPLY != "$dir" ]] || ! scope_still_registered "$dir"; then
        event "$dir" blocked 'selected repository unavailable'; return 1
    fi
    return 0
}

operations_main() {
    EVENT_DIRS=(); EVENT_STATES=(); EVENT_REASONS=(); LOCKS=(); PUB_DIRS=(); RESULT=0; PUBLISH_CANDIDATES=0
    CANCELLED=0 LAST_EVENT_DIR='' OP_PHASE=execution
    PROGRESS_PID='' PROGRESS_FD=''
    local progress_completed=0 progress_total=0 OP_BOXES=0
    if ((DRY_RUN)) || [[ $CMD == publish ]]; then OP_PHASE=preview; fi
    declare -gA HELD=() VISITED=() BLOCKED=() SNAPSHOTS=() PARENT=() EXPECTED=()
    declare -gA PREVIEW_DEST=() PREVIEW_REF=() PREVIEW_REMOTE=() PREVIEW_BRANCH=()
    trap cleanup_locks EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local selected dir parent answer
    if ((WIKI_DECLARED)); then
        text_cmd python3 -IB "$LIB/wiki_scope.py" digest "$WIKI_SOURCE" || die 3 'invalid wiki declaration'
        WIKI_DIGEST=$REPLY
    fi
    operations_heading
    if [[ $CMD == sync ]]; then
        for selected in "${OP_ROOTS[@]}"; do
            if ((RESULT)) && [[ $selected == "$WIKI_ROOT" ]]; then event "$selected" blocked 'source synchronization failed'; continue; fi
            operation_root_available "$selected" || continue
            sync_node "$selected" || RESULT=1
        done
    else
        if ((!JSON)); then
            # Shared counted file groups for status and publish previews.
            # shellcheck source=lib/git_views.bash
            source "$LIB/git_views.bash"
        fi
        command -v sha256sum >/dev/null 2>&1 || die 3 'publishing requires sha256sum'
        if [[ -z $MESSAGE ]]; then
            text_cmd date -u '+%Y-%m-%d %H:%M UTC'
            MESSAGE="Sync via ${DOTS_PROFILE:-${HOSTNAME:-unknown}} on $REPLY"
        fi
        progress_start 'Discovering repositories'
        for selected in "${OP_ROOTS[@]}"; do
            operation_root_available "$selected" || continue
            if [[ $selected == "$WIKI_ROOT" ]] && ! wiki_publish_check preview; then
                event "$selected" blocked 'cannot verify selected wiki content or source association'
                operations_report; return 1
            fi
            collect_publish "$selected" || RESULT=1
        done
        progress_stop
        for dir in "${PUB_DIRS[@]}"; do publish_preview "$dir"; done
        if ((!DRY_RUN && PUBLISH_CANDIDATES > 0)); then
            if ((!YES)); then
                [[ -t 0 ]] || die 2 'publish requires a terminal confirmation or --yes'
                if ((JSON)); then
                    local preview_i
                    for ((preview_i=0;preview_i<${#EVENT_DIRS[@]};preview_i++)); do
                        display "${EVENT_DIRS[preview_i]}: ${EVENT_STATES[preview_i]} — ${EVENT_REASONS[preview_i]}"
                        printf '%s\n' "$REPLY" >&2
                    done
                fi
                printf '%sPublish the selected changes? [y/N]%s ' "$ERR_BOLD" "$ERR_RESET" >&2
                IFS= read -r answer || answer=''
                if [[ $answer != y && $answer != Y ]]; then event "$ROOT" cancelled 'nothing committed or pushed'; operations_report; return "$RESULT"; fi
            fi
            OP_PHASE=execution LAST_EVENT_DIR=''
            if ((!JSON)); then printf '\n'; ui_heading Publishing; fi
            progress_total=${#PUB_DIRS[@]}
            for dir in "${PUB_DIRS[@]}"; do
                parent=${PARENT[$dir]}
                if [[ -n $WIKI_ROOT && ( $dir == "$WIKI_ROOT" || $dir == "$WIKI_ROOT/"* ) ]]; then
                    if ((RESULT)) || ! wiki_publish_check execute; then
                        event "$dir" blocked 'source publication failed or wiki verification changed'; continue
                    fi
                fi
                # Validate parent BEFORE permitting the known child-induced change.
                if [[ -n $parent ]]; then
                    if ! fingerprint "$parent" || [[ $REPLY != "${SNAPSHOTS[$parent]}" ]]; then
                        BLOCKED[$dir]=1; BLOCKED[$parent]=1
                    fi
                fi
                if ! publish_node "$dir"; then
                    RESULT=1; [[ -z $parent ]] || BLOCKED[$parent]=1
                fi
                ((progress_completed+=1))
            done
        fi
    fi
    if [[ $CMD == publish ]] && ((!DRY_RUN && !CANCELLED)); then
        for selected in "${OP_ROOTS[@]}"; do
            parent=${SELECTED_PARENTS[$selected]-}
            if [[ -n $parent ]] && scope_still_registered "$selected" &&
               ! git -C "$parent" diff --quiet --ignore-submodules=dirty -- ":(literal)${selected#"$parent"/}"; then
                event "$parent" pending "review the updated submodule pointer: ${selected#"$parent"/}"
            fi
        done
    fi
    operations_report
    return "$RESULT"
}

operations_report() {
    progress_stop
    local i comma=''
    if ((JSON)); then
        printf '{"complete":'; if ((RESULT)); then printf false; else printf true; fi
        printf ',"dry_run":'; if ((DRY_RUN)); then printf true; else printf false; fi
        printf ',"events":['
        for ((i=0;i<${#EVENT_DIRS[@]};i++)); do
            printf '%s{' "$comma"; comma=,
            json_string "${EVENT_DIRS[i]}"; printf '"path":%s,' "$REPLY"
            json_string "${EVENT_STATES[i]}"; printf '"status":%s,' "$REPLY"
            json_string "${EVENT_REASONS[i]}"; printf '"detail":%s}' "$REPLY"
        done
        printf ']}\n'
    else
        local title=Complete style=$GREEN
        local -a details=()
        if ((CANCELLED)); then
            title=Cancelled; style=$YELLOW
            details+=(Result 'Nothing committed or pushed.')
            if ((RESULT)); then details+=('Next step' 'Preflight blockers remain; resolve them before publishing.'); fi
        elif ((RESULT)); then
            style=$RED
            if ((DRY_RUN)); then title='Preview incomplete'; details+=('Next step' 'Resolve blockers and rerun; no changes were made.')
            else title=Incomplete; details+=('Next step' 'Completed work is retained; resolve blockers and rerun.'); fi
        elif ((DRY_RUN)); then title='Preview complete'; style=$CYAN
        elif [[ $CMD == publish && $PUBLISH_CANDIDATES == 0 ]]; then
            details+=(Result 'No selected changes or known ahead commits; remote state was not fetched.')
        fi
        if ((DRY_RUN)); then details+=(Note 'Remote state and undiscovered descendants were not checked.'); fi
        ui_summary "$title" "$style"
        if ((${#details[@]})); then operation_fields detail "${details[@]}"; fi
    fi
}
