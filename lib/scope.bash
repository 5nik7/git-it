# Resolve only indexed gitlinks with a unique registration and verified safe path.
# shellcheck shell=bash disable=SC2154,SC2034
# shellcheck source=lib/operations.bash
source "$LIB/operations.bash"

scope_children() {
    local dir=$1 path i
    local -A registered=()
    SCOPE_CHILDREN=()
    [[ ! -L $dir/.git && ! -L $dir/.gitmodules && ( ! -e $dir/.gitmodules || -f $dir/.gitmodules ) ]] || return 1
    children "$dir" status || return 1
    ((${#CHILD_PATHS[@]})) || return 0
    submodule_registrations "$dir" registered status || return 1
    for i in "${!CHILD_PATHS[@]}"; do
        path=${CHILD_PATHS[i]}
        [[ -n ${CHILD_OIDS[i]} && -n ${registered[$path]-} ]] && safe_child_path "$dir" "$path" &&
            [[ ! -L $dir/$path/.git && ( ! -e $dir/$path/.git || -f $dir/$path/.git || -d $dir/$path/.git ) ]] || return 1
        SCOPE_CHILDREN+=("$path")
    done
}

scope_select() {
    local remaining=$1 mode=$2 path match token count
    [[ -n $remaining && $remaining != /* && $remaining != */ && $remaining != *//* ]] || return 1
    while [[ -n $remaining ]]; do
        scope_children "$ROOT" || return 1
        count=0; match=''
        token=${remaining%%:*}
        for path in "${SCOPE_CHILDREN[@]}"; do
            if [[ $mode == name ]]; then [[ ${path##*/} == "$token" ]] || continue
            else [[ $remaining == "$path" || $remaining == "$path/"* ]] || continue; fi
            match=$path; ((count+=1))
        done
        ((count == 1)) || return 1
        SCOPE_PARENT=$ROOT; ROOT=$ROOT/$match
        SELECTED_PARENTS[$ROOT]=$SCOPE_PARENT
        if [[ $mode == name && $remaining == *:* ]]; then
            remaining=${remaining#*:}; [[ -n $remaining ]] || return 1
        elif [[ $mode == path && $remaining != "$match" ]]; then remaining=${remaining#"$match"/}
        else remaining=''; fi
        if ! repo_root "$ROOT" || [[ $REPLY != "$ROOT" ]]; then
            [[ ! $remaining ]] || return 1
            SCOPE_UNAVAILABLE=1
        fi
    done
}

scope_paths() {
    local dir=$1 base=$2 path child
    local -a paths=()
    scope_children "$dir" || return 1
    paths=("${SCOPE_CHILDREN[@]}")
    for path in "${paths[@]}"; do
        child=$dir/$path
        printf '%s\0' "${child#"$base"/}"
        if repo_root "$child" && [[ $REPLY == "$child" ]]; then scope_paths "$child" "$base" || return 1; fi
    done
}

scope_complete() {
    local name path
    local -A counts=() SELECTED_PARENTS=()
    for name in "${scope_names[@]}"; do scope_select "$name" name || return 1; done
    if [[ $query == __complete-submodule-paths ]]; then scope_paths "$ROOT" "$ROOT"; return; fi
    scope_children "$ROOT" || return 1
    for path in "${SCOPE_CHILDREN[@]}"; do name=${path##*/}; counts[$name]=$((${counts[$name]:-0} + 1)); done
    for path in "${SCOPE_CHILDREN[@]}"; do
        name=${path##*/}; [[ ${counts[$name]} != 1 || $name == *:* ]] || printf '%s\0' "$name"
    done
}

scope_still_registered() {
    local dir=$1 root parent path
    for root in "${OP_ROOTS[@]}"; do
        [[ $dir == "$root" || $dir == "$root/"* ]] || continue
        while [[ ${SELECTED_PARENTS[$root]+set} ]]; do
            parent=${SELECTED_PARENTS[$root]}; path=${root#"$parent/"}
            [[ ! -L $parent/.gitmodules && -f $parent/.gitmodules && ! -L $root/.git ]] &&
                safe_child_path "$parent" "$path" && submodule_name "$parent" "$path" &&
                verified_edge "$parent" "$root" || return 1
            root=$parent
        done
        return 0
    done
    return 1
}

# The sibling convention applies only to a real external worktree with a fetch
# identity matching the source host, complete namespace and repository name.
scope_remote_identity() {
    local url=$1 authority port=''
    [[ $url && $url != *[[:cntrl:]]* ]] || return 1
    parse_url "$url"
    [[ -n $HOST && -n $OWNER && -n $REPO && $PROTOCOL == @(ssh|http|https|git) ]] || return 1
    if [[ $url == *://* ]]; then
        authority=${url#*://}; authority=${authority%%/*}; authority=${authority##*@}
        [[ $authority =~ ^(\[[[:xdigit:]:.]+\]|[a-zA-Z0-9._-]+)(:([0-9]{1,5}))?$ ]] || return 1
        port=${BASH_REMATCH[3]}
        if [[ $port ]]; then port=$((10#$port)); ((port > 0 && port <= 65535)) || return 1; fi
    fi
    case "$PROTOCOL:$port" in ssh:22|http:80|https:443|git:9418) port='' ;; esac
    # The ordinary SSH/HTTPS forms identify the same hosting service. A custom
    # port is an endpoint and must match both the scheme and the numeric port.
    REPLY=$HOST${port:+/$PROTOCOL:$port}
}

scope_wiki_url_matches() {
    local source=$1 candidate=$2 endpoint owner repo REMOTE_ARG=''
    select_remote "$source" && scope_remote_identity "$URL" || return 1
    endpoint=$REPLY owner=$OWNER repo=$REPO
    [[ $repo != *.wiki ]] && scope_remote_identity "$candidate" || return 1
    [[ $REPLY == "$endpoint" && $OWNER == "$owner" && $REPO == "$repo.wiki" ]]
}

scope_sibling_matches() {
    local source=$1 wiki=$2 REMOTE_ARG=''
    [[ -d $wiki && ! -L $wiki && ! -L $wiki/.git && ( -d $wiki/.git || -f $wiki/.git ) ]] || return 1
    repo_root "$wiki" && [[ $REPLY == "$wiki" ]] || return 1
    select_remote "$wiki" && scope_wiki_url_matches "$source" "$URL"
}

scope_wiki() {
    local source=$1
    WIKI_ROOT='' WIKI_DECLARED=0
    if [[ ! -L $source/.dots && ( -e $source/.dots/wiki.json || -L $source/.dots/wiki.json ) ]]; then
        command -v python3 >/dev/null || die 3 'declared wiki requires Python 3'
        text_cmd python3 -IB "$LIB/wiki_scope.py" checkout "$source" || die 3 'invalid declared wiki checkout'
        WIKI_ROOT=$REPLY; WIKI_DECLARED=1
    elif scope_sibling_matches "$source" "$source.wiki"; then WIKI_ROOT=$source.wiki; fi
}

scope_apply() {
    local name
    SCOPE_PARENT='' SCOPE_UNAVAILABLE=0 OP_ROOTS=()
    declare -gA SELECTED_PARENTS=()
    if ((OUTERMOST)); then ancestry; ROOT=${CHAIN[0]}; OUTERMOST=0; fi
    for name in "${scope_names[@]}"; do
        scope_select "$name" name || die 2 'child name is unknown, ambiguous, or unsafe; use an exact registered path'
        REPORT_KIND=submodule
    done
    if [[ -n $scope_path ]]; then
        scope_select "$scope_path" path || die 2 'path must identify an exact registered submodule'
        REPORT_KIND=submodule
    fi
    if ((SCOPE_UNAVAILABLE)) && { [[ $CMD == publish ]] || ((collection && ! ${#scope_path})); }; then die 1 'selected submodule is unavailable'; fi
    if (( ${#scope_names[@]} || collection )); then
        TARGET=$ROOT
        if ((all_submodules)); then
            scope_children "$ROOT" || die 1 'cannot verify registered child paths'
            for name in "${SCOPE_CHILDREN[@]}"; do
                OP_ROOTS+=("$ROOT/$name"); SELECTED_PARENTS[$ROOT/$name]=$ROOT
            done
        else OP_ROOTS=("$ROOT"); fi
        return
    fi
    WIKI_SOURCE=$ROOT
    if ((!no_wiki)); then scope_wiki "$ROOT"; fi
    if ((WIKI_ONLY)); then
        [[ -n $WIKI_ROOT ]] && repo_root "$WIKI_ROOT" && [[ $REPLY == "$WIKI_ROOT" ]] || die 3 'associated wiki checkout unavailable'
        ROOT=$WIKI_ROOT TARGET=$WIKI_ROOT REPORT_KIND=wiki
    fi
    OP_ROOTS=("$ROOT")
    # A conventionally named sibling can only be changed by an explicit wiki action.
    if ((!WIKI_ONLY && WIKI_DECLARED)) && [[ $CMD == publish || $CMD == sync ]]; then OP_ROOTS+=("$WIKI_ROOT"); fi
}
