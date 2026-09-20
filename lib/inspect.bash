# Local Git discovery, URL parsing and prompt rendering.
# shellcheck disable=SC2034,SC2153
repo_root() {
    text_cmd git -C "$1" rev-parse --show-toplevel 2>/dev/null || return 1
    text_cmd canonical_dir "$REPLY"
}

list_fields() {
    printf '%s\n' root remote url protocol host owner repo owned icon current parent outermost \
        parent_dirname parent_basename submodule_prefix submodule_basename cwd_prefix \
        path_parent path_outermost chain_length chain_repos chain_paths is_submodule
}

select_remote() {
    local dir=$1 branch
    REMOTE=$REMOTE_ARG
    if [[ -z $REMOTE ]]; then
        if text_cmd git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null; then
            branch=$REPLY
            text_cmd git -C "$dir" config --get "branch.$branch.remote" 2>/dev/null && REMOTE=$REPLY
        fi
        [[ -n $REMOTE && $REMOTE != . ]] || REMOTE=origin
    fi
    URL=''
    if text_cmd git -C "$dir" remote get-url -- "$REMOTE" 2>/dev/null; then URL=$REPLY
    elif [[ -n $REMOTE_ARG ]]; then return 1
    else REMOTE=''; fi
}

parse_url() {
    local url=$1 rest authority path alias entry identity
    PROTOCOL=local HOST='' OWNER='' REPO='' OWNED=false HOST_ICON='' SAFE_URL=$url
    if [[ $url =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://(.*)$ ]]; then
        PROTOCOL=${BASH_REMATCH[1],,}; rest=${BASH_REMATCH[2]}
        authority=${rest%%/*}; path=${rest#*/}; [[ $rest == */* ]] || path=''
        authority=${authority##*@}
        SAFE_URL="$PROTOCOL://$authority/$path"
        HOST=${authority%%:*}
        if [[ $authority == \[*\]* ]]; then HOST=${authority%%]*}; HOST+=']'; fi
    elif [[ $url != /* && $url != ./* && $url != ../* && $url == *:* ]]; then
        PROTOCOL=ssh; authority=${url%%:*}; HOST=${authority##*@}; path=${url#*:}
        SAFE_URL="$HOST:$path"
    else
        path=$url
    fi
    # Query strings can contain credentials; never render them.
    SAFE_URL=${SAFE_URL%%\?*}; SAFE_URL=${SAFE_URL%%\#*}
    path=${path%%\?*}; path=${path%%\#*}; path=${path#/}; path=${path%/}
    HOST=${HOST,,}
    for entry in "${HOST_ALIASES[@]}"; do
        alias=${entry%%=*}
        [[ $HOST == "${alias,,}" ]] && HOST=${entry#*=}
    done
    HOST=${HOST,,}
    REPO=${path##*/}; REPO=${REPO%.git}
    [[ $path == */* ]] && OWNER=${path%/*}
    case $HOST in github.com) HOST_ICON='󰊤' ;; gitlab.com) HOST_ICON='' ;; bitbucket.org) HOST_ICON='' ;; esac
    if [[ -n $HOST && -n $OWNER && $PROTOCOL != file ]]; then
        for identity in "${OWNERS[@]}"; do
            if [[ ${identity%%/*} == "$HOST" && ${identity#*/} == "$OWNER" ]]; then OWNED=true; break; fi
        done
    fi
}

# A gitlink must match exactly, at stage zero, and resolve to this child.
verified_edge() {
    local parent=$1 child=$2 rel row meta count=0
    [[ $child == "$parent/"* ]] || return 1
    rel=${child#"$parent/"}
    records_cmd git -C "$parent" ls-files --stage -z -- ":(literal)$rel" || return 1
    for row in "${RECORDS[@]}"; do
        meta=${row%%$'\t'*}
        [[ $meta == '160000 '* && $meta == *' 0' && ${row#*$'\t'} == "$rel" ]] && ((count+=1))
    done
    ((count == 1)) || return 1
    repo_root "$child" && [[ $REPLY == "$child" ]] || return 1
    REPLY=$rel
}

ancestry() {
    local current=$ROOT candidate rel i
    local -a reverse=("$ROOT") hops=()
    while [[ $current != / ]]; do
        candidate=''
        text_cmd git -C "$current" rev-parse --show-superproject-working-tree 2>/dev/null && candidate=$REPLY
        if [[ -z $candidate ]]; then
            repo_root "${current%/*}/" || break
            candidate=$REPLY
        else
            text_cmd canonical_dir "$candidate" || break; candidate=$REPLY
        fi
        [[ $candidate != "$current" ]] || break
        verified_edge "$candidate" "$current" || break
        rel=$REPLY; reverse+=("$candidate"); hops+=("$rel"); current=$candidate
    done
    CHAIN=(); HOPS=()
    for ((i=${#reverse[@]}-1;i>=0;i--)); do CHAIN+=("${reverse[i]}"); done
    for ((i=${#hops[@]}-1;i>=0;i--)); do HOPS+=("${hops[i]}"); done
}

path_fields() {
    local outer parent='' relative='.' prefix='.'
    ancestry
    outer=${CHAIN[0]}
    if ((${#CHAIN[@]} > 1)); then
        parent=${CHAIN[${#CHAIN[@]}-2]}; relative=${ROOT#"$outer/"}
        [[ $relative == */* ]] && prefix=${relative%/*}
    fi
    F[current]=$ROOT F[parent]=$parent F[outermost]=$outer
    F[parent_dirname]=${outer%/*}; [[ -n ${F[parent_dirname]} ]] || F[parent_dirname]=/
    F[parent_basename]=${outer##*/}
    F[submodule_prefix]=$prefix F[submodule_basename]=${ROOT##*/}
    F[cwd_prefix]=''; [[ $TARGET == "$ROOT" ]] || F[cwd_prefix]=${TARGET#"${ROOT%/}/"}
    F[path_parent]='.'; [[ -z $parent ]] || F[path_parent]=${ROOT#"$parent/"}
    F[path_outermost]=$relative F[chain_length]=${#CHAIN[@]} F[is_submodule]=false
    ((${#CHAIN[@]} > 1)) && F[is_submodule]=true
    local joined='' value
    for value in "${CHAIN[@]}"; do joined+="${joined:+$'\n'}$value"; done
    F[chain_repos]=$joined; joined=''
    for value in "${HOPS[@]}"; do joined+="${joined:+$'\n'}$value"; done
    F[chain_paths]=$joined
}

render_format() {
    local fmt=$1 out='' name ch i=0
    while ((i < ${#fmt})); do
        ch=${fmt:i:1}
        if [[ ${fmt:i:2} == '{{' ]]; then out+='{'; ((i+=2))
        elif [[ ${fmt:i:2} == '}}' ]]; then out+='}'; ((i+=2))
        elif [[ $ch == '{' ]]; then
            name=${fmt:i+1}; [[ $name == *'}'* ]] || die 2 'unclosed format placeholder'
            name=${name%%\}*}
            [[ -n $name && -v F[$name] ]] || die 2 "unknown format field: $name"
            display "${F[$name]}"; out+=$REPLY; ((i+=${#name}+2))
        elif [[ $ch == '}' ]]; then die 2 'unescaped closing brace in format'
        else out+=$ch; ((i+=1)); fi
    done
    printf '%s' "$out"
}

inspect_json() {
    local key value comma='' item sep
    printf '{'
    while IFS= read -r key; do
        printf '%s' "$comma"; comma=,
        json_string "$key"; printf '%s:' "$REPLY"
        case $key in
            chain_repos|chain_paths)
                local -a values=()
                if [[ $key == chain_repos ]]; then values=("${CHAIN[@]}"); else values=("${HOPS[@]}"); fi
                printf '['; sep=''
                for item in "${values[@]}"; do json_string "$item"; printf '%s%s' "$sep" "$REPLY"; sep=,; done
                printf ']' ;;
            owned|is_submodule|chain_length) printf '%s' "${F[$key]}" ;;
            *) value=${F[$key]}; json_string "$value"; printf '%s' "$REPLY" ;;
        esac
    done < <(list_fields)
    printf '}'
}

inspect_main() {
    declare -gA F=()
    local key
    F[root]=$ROOT
    select_remote "$ROOT" || die 3 'requested remote does not exist'
    parse_url "$URL"
    if ((ICON)); then printf '%s' "$HOST_ICON"; ((NEWLINE)) && printf '\n'; return 0; fi
    F[remote]=$REMOTE F[url]=$SAFE_URL F[protocol]=$PROTOCOL F[host]=$HOST
    F[owner]=$OWNER F[repo]=$REPO F[owned]=$OWNED F[icon]=$HOST_ICON
    # Single remote-field queries avoid ancestry discovery.
    if [[ -n $GET && -v F[$GET] ]]; then
        printf '%s' "${F[$GET]}"
    else
        path_fields
        if [[ -n $GET ]]; then
            [[ -v F[$GET] ]] || die 2 "unknown field: $GET"
            printf '%s' "${F[$GET]}"
        elif ((JSON)); then inspect_json
        elif ((FORMAT_SET)); then render_format "$FORMAT"
        elif [[ $CMD == path ]]; then display "$ROOT"; printf '%s' "$REPLY"
        else
            for key in root remote host owner repo owned; do
                display "${F[$key]}"; printf '%s%-8s%s %s\n' "$CYAN" "$key" "$RESET" "$REPLY"
            done
            return 0
        fi
    fi
    ((NEWLINE)) && printf '\n'
    return 0
}
