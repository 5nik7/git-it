# Local Git discovery, URL parsing and prompt rendering.
# shellcheck disable=SC2034,SC2153
repo_root() {
    text_cmd git -C "$1" rev-parse --show-toplevel 2>/dev/null || return 1
    text_cmd canonical_dir "$REPLY"
}

list_fields() {
    printf '%s\n' root remote url https_url protocol host owner repo owned icon current parent outermost \
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
    elif [[ $REMOTE != origin ]] && text_cmd git -C "$dir" remote get-url -- origin 2>/dev/null; then REMOTE=origin; URL=$REPLY
    else REMOTE=''; fi
}

https_path() {
    # SCP paths are literal. In ssh:// URLs an existing percent escape already
    # represents its byte. Encode other bytes that are not URI path characters.
    local path=$1 uri=$2 char escape hex i
    local -a bytes
    local allowed="[a-zA-Z0-9._~!\$&'()*+,;=:@/-]"
    if [[ $path =~ ^$allowed+$ || ( $uri == 1 && $path =~ ^($allowed|%[[:xdigit:]]{2})+$ ) ]]; then
        REPLY=$path; return
    fi
    # Android's C locale may still iterate multibyte characters. Read the
    # original octets once for paths that actually need escaping.
    hex=$(printf '%s' "$path" | od -An -v -tx1) || return 1
    read -ra bytes <<< "${hex//$'\n'/ }"
    REPLY=''
    for ((i=0; i<${#bytes[@]}; i++)); do
        printf -v char '%b' "\\x${bytes[i]}"
        if [[ $char =~ ^$allowed$ ]]; then REPLY+=$char; continue; fi
        if [[ $uri == 1 && $char == '%' ]] && ((i+2 < ${#bytes[@]})); then
            printf -v escape '%b' "\\x${bytes[i+1]}\\x${bytes[i+2]}"
            if [[ $escape =~ ^[[:xdigit:]]{2}$ ]]; then REPLY+="%$escape"; ((i+=2)); continue; fi
        fi
        REPLY+="%${bytes[i]^^}"
    done
}

parse_url() {
    local url=$1 rest authority path alias entry identity parsed_host=0 uri=0
    local authority_re='^(\[[[:xdigit:]:.]+\]|[a-zA-Z0-9._-]+)(:[0-9]+)?$'
    local scp_re='^([^/@:]+@)?(\[[[:xdigit:]:.]+\]|[^/:@]+):([^:].*)$'
    # Fragments and queries may contain credentials, including @ or slash.
    url=${url%%\?*}; url=${url%%\#*}
    PROTOCOL=local HOST='' OWNER='' REPO='' OWNED=false HOST_ICON='' SAFE_URL=$url HTTPS_URL=''
    if [[ $url =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://(.*)$ ]]; then
        uri=1; PROTOCOL=${BASH_REMATCH[1],,}; rest=${BASH_REMATCH[2]}
        authority=${rest%%/*}; path=${rest#*/}; [[ $rest == */* ]] || path=''
        authority=${authority##*@}
        SAFE_URL="$PROTOCOL://$authority/$path"
        HOST=${authority%%:*}
        if [[ $authority == \[*\]* ]]; then HOST=${authority%%]*}; HOST+=']'; fi
        if [[ $authority =~ $authority_re ]]; then parsed_host=1; fi
    elif [[ $url =~ ^([a-zA-Z][a-zA-Z0-9+.-]*):: ]]; then
        # Remote helpers interpret their own payloads, including embedded secrets.
        PROTOCOL=${BASH_REMATCH[1],,}; SAFE_URL="${BASH_REMATCH[1]}::"; path=''
    elif [[ $url =~ $scp_re ]]; then
        PROTOCOL=ssh; HOST=${BASH_REMATCH[2]}; path=${BASH_REMATCH[3]}
        SAFE_URL="$HOST:$path"
        if [[ $HOST =~ $authority_re ]]; then parsed_host=1; fi
    else
        path=$url
    fi
    path=${path#/}; path=${path%/}
    HOST=${HOST,,}
    for entry in "${HOST_ALIASES[@]}"; do
        alias=${entry%%=*}
        [[ $HOST == "${alias,,}" ]] && HOST=${entry#*=}
    done
    HOST=${HOST,,}
    if ((parsed_host && ${2:-0})) && [[ -n $path && $path != *[[:cntrl:]]* ]]; then
        case $PROTOCOL in
            ssh)
                if [[ $HOST =~ $authority_re && -z ${BASH_REMATCH[2]} ]] && https_path "$path" "$uri"; then
                    HTTPS_URL="https://$HOST/$REPLY"; fi ;;
            https) HTTPS_URL=$SAFE_URL ;;
        esac
    fi
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
    local key project_https=0
    F[root]=$ROOT
    select_remote "$ROOT" || die 3 'requested remote does not exist'
    if [[ $GET == https_url || $JSON == 1 || $FORMAT == *'{https_url}'* ]]; then project_https=1; fi
    parse_url "$URL" "$project_https"
    if ((ICON)); then printf '%s' "$HOST_ICON"; ((NEWLINE)) && printf '\n'; return 0; fi
    F[remote]=$REMOTE F[url]=$SAFE_URL F[https_url]=$HTTPS_URL F[protocol]=$PROTOCOL F[host]=$HOST
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
            ui_prepare
            if [[ $OWNED == true ]]; then ui_git_style repo_owned; else ui_git_style repo; fi
            ui_heading "Repository ${ROOT##*/}" "$REPLY"
            ui_field Root "$ROOT" path
            ui_field Remote "$REMOTE"
            ui_field Host "$HOST"
            ui_field Owner "$OWNER"
            if [[ $OWNED == true ]]; then ui_field Ownership 'Matches configured owner'
            else ui_field Ownership 'No configured owner match'; fi
            if ((VERBOSE)) || [[ $UI_GIT_VIEW == verbose ]]; then
                printf '\n'
                ui_heading 'Remote details'
                ui_field Repository "$REPO"
                ui_field URL "$SAFE_URL"
                ui_field Protocol "$PROTOCOL"
                printf '\n'
                ui_heading 'Verified ancestry'
                ui_field Parent "${F[parent]:-None}" path
                ui_field Outermost "${F[outermost]}" path
                for key in "${CHAIN[@]}"; do ui_path "$key"; ui_detail "$REPLY"; done
            fi
            return 0
        fi
    fi
    ((NEWLINE)) && printf '\n'
    return 0
}
