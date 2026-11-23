# Human output. Only ui_prepare reads optional preferences; data routes bypass it.
# shellcheck shell=bash disable=SC2034
declare -gA UI_COLORS
declare -gA UI_ICONS=() UI_GIT=() UI_TYPES=()
declare -gA UI_SUFFIX_STYLE=() UI_SUFFIX_ORDER=() UI_SUFFIX_SIZES=() UI_MIME_STYLE=() UI_MIME_ORDER=()
declare -ga UI_RESOURCE_ROWS=()
UI_GIT_VIEW=default UI_PROGRESS=both UI_ICON_MODE=auto
UI_INDENT=2 UI_LABEL_WIDTH=10 UI_GAP=1 UI_ALIGN=left UI_INDENT_STYLE=spaces UI_TAB_WIDTH=2

ui_valid_sgr() { [[ ${#1} -le 128 && $1 =~ ^[0-9]+(\;[0-9]+)*$ ]]; }

# Read effective settings from the user's Dots installation through its data
# projection. Never source the output, or search the inspected worktree for code.
ui_profile() {
    local root=${DOTS:-} cmd rows key data value
    if [[ -z $root ]]; then
        cmd=$(type -P dots) || return 0
        [[ $cmd == /* ]] || return 0
        cmd=$(realpath -- "$cmd" 2>/dev/null) || return 0
        [[ $cmd == */bin/dots ]] || return 0
        root=${cmd%/bin/dots}
    fi
    [[ $root == /* && -f $root/lib/dots/profile_config.py && -r $root/lib/dots/profile_config.py ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    rows=$(DOTS="$root" command python3 -B "$root/lib/dots/profile_config.py" __settings 2>/dev/null) || return 0
    while IFS= read -r data; do
        [[ $data == *$'\t'*$'\t'* ]] || continue
        key=${data%%$'\t'*}; data=${data#*$'\t'}; value=${data%%$'\t'*}
        case $key in
            __color.*|__help.color.*)
                key=${key#__}; key=${key/color./}
                [[ $key =~ ^[a-z0-9_.]+$ ]] && ui_valid_sgr "$value" && UI_COLORS[$key]=$value ;;
            __icon.*)
                key=${key#__icon.}
                [[ $key =~ ^[a-z][a-z0-9_.]*$ && ${#value} -le 32 && $value != *[[:cntrl:]]* ]] &&
                    UI_ICONS[$key]=$value ;;
            __format.indent|__format.label_gap|__format.tab_width)
                [[ $value =~ ^[0-9]{1,4}$ ]] || continue
                case $key in
                    *.indent) UI_INDENT=$((10#$value)) ;; *.label_gap) UI_GAP=$((10#$value)) ;;
                    *.tab_width) ((10#$value)) && UI_TAB_WIDTH=$((10#$value)) ;;
                esac ;;
            __format.label_width) [[ $value =~ ^[0-9]{1,4}%?$ ]] && UI_LABEL_WIDTH=$value ;;
            __format.alignment) [[ $value == @(left|right|center) ]] && UI_ALIGN=$value ;;
            __format.indent_style) [[ $value == @(spaces|tabs) ]] && UI_INDENT_STYLE=$value ;;
            __cli.progress) [[ $value == @(both|bar|spinner|none) ]] && UI_PROGRESS=$value ;;
            __git.view) [[ $value == @(default|short|verbose) ]] && UI_GIT_VIEW=$value ;;
            DOTS_ICONS) [[ $value == @(auto|always|never) ]] && UI_ICON_MODE=$value ;;
            DOTS_COLOR) [[ ${COLOR_SET:-0} == 0 && $value == @(auto|always|never) ]] && COLOR=$value ;;
        esac
    done <<< "$rows"
    if [[ -f $root/lib/dots/resources.tsv && ! -L $root/lib/dots/resources.tsv ]]; then
        local group pattern icon mime fallback
        while IFS=$'\t' read -r group pattern icon mime fallback; do
            [[ $group == @(kind|name|suffix) && -n $pattern && $pattern != *[[:cntrl:]]* &&
                $icon =~ ^files\.[a-z0-9_]+$ && $mime != *[[:cntrl:]]* &&
                $fallback != *[[:cntrl:]]* ]] || continue
            UI_RESOURCE_ROWS+=("$group" "$pattern" "$icon" "$mime" "$fallback")
        done < "$root/lib/dots/resources.tsv"
    fi
    return 0
}

# The generation link can move when a theme is published. Read regular payloads
# once; validate the whole table before publishing any of its values.
ui_theme_table() {
    local path=$1 kind=$2 line header group key code mode extra suffix index=0 data=''
    local -A types=() styles=() order=() sizes=() mime_styles=() mime_order=()
    [[ -f $path && -r $path && ! -L $path ]] || return 0
    local LC_ALL=C
    IFS= read -r -N 2097153 data < "$path" || :
    (( ${#data} <= 2097152 )) || return 0
    {
        IFS= read -r header
        [[ $header == "dots-$kind-styles"$'\t1' ]] || return 0
        while IFS= read -r line; do
            [[ -n $line ]] || continue
            if [[ $kind == git ]]; then
                IFS=$'\t' read -r key code extra <<< "$line"
                [[ $key =~ ^[a-z][a-z0-9_]*$ && ! ${types[$key]+set} && -z $extra ]] &&
                    ui_valid_sgr "$code" || return 0
                types[$key]=$code
            else
                IFS=$'\t' read -r group key code mode extra <<< "$line"
                [[ $group == @(type|extension|suffix|mime|default_mime) && -n $key &&
                    $key != *[[:cntrl:]]* && $mode == @(-|fold|exact) && -z $extra ]] &&
                    ui_valid_sgr "$code" || return 0
                case $group in
                    type) types[$key]=$code ;;
                    mime|default_mime) if [[ ! ${mime_styles[$key]+set} ]]; then
                            mime_styles[$key]=$code; mime_order[$key]=$index
                        fi ;;
                    extension|suffix)
                        suffix="exact:$key"
                        [[ $mode == exact ]] || suffix="fold:${key,,}"
                        if [[ ! ${styles[$suffix]+set} ]]; then
                            styles[$suffix]=$code; order[$suffix]=$index; sizes[${#key}]=1
                        fi ;;
                esac
            fi
            ((index+=1))
        done
    } <<< "$data"
    if [[ $kind == git ]]; then
        for key in "${!types[@]}"; do UI_GIT[$key]=${types[$key]}; done
    else
        for key in "${!types[@]}"; do UI_TYPES[$key]=${types[$key]}; done
        for key in "${!styles[@]}"; do UI_SUFFIX_STYLE[$key]=${styles[$key]}; UI_SUFFIX_ORDER[$key]=${order[$key]}; done
        for key in "${!mime_styles[@]}"; do UI_MIME_STYLE[$key]=${mime_styles[$key]}; UI_MIME_ORDER[$key]=${mime_order[$key]}; done
        for key in "${!sizes[@]}"; do UI_SUFFIX_SIZES[$key]=1; done
    fi
}

ui_load_preferences() {
    UI_READY=1
    [[ ${JSON:-0} == 0 ]] || return 0
    local geometry term_columns fd=${1:-1} theme=${XDG_STATE_HOME:-$HOME/.local/state}/dots/current/theme
    if [[ -z ${COLUMNS:-} && -t 1 ]] && command -v stty >/dev/null 2>&1; then
        geometry=$(stty size <&1 2>/dev/null) && term_columns=${geometry##* } || term_columns=''
        [[ $term_columns =~ ^[1-9][0-9]{0,3}$ ]] && UI_TERM_COLUMNS=$term_columns
    fi
    if [[ -t $fd || ${COLOR:-auto} == always || ${DOTS_COLOR:-} == always ||
        ${DOTS_ICONS:-} == always || ${DOTS_MENU_CAPTURE:-} == 1 ]]; then
        ui_profile
        if [[ ${COLOR_SET:-0} == 0 && ${DOTS_COLOR:-} == @(auto|always|never) ]]; then COLOR=$DOTS_COLOR; fi
        [[ ${DOTS_ICONS:-} != @(auto|always|never) ]] || UI_ICON_MODE=$DOTS_ICONS
        colors
        if [[ -n $RESET ]]; then
            ui_theme_table "$theme/git-styles.tsv" git
            ui_theme_table "$theme/file-styles.tsv" file
        fi
    fi
    case ${DOTS_PROGRESS:-auto} in
        auto) ;; spinner|bar|both) UI_PROGRESS=$DOTS_PROGRESS ;; *) UI_PROGRESS=none ;;
    esac
    return 0
}

ui_icon() {
    REPLY=''
    if [[ $UI_ICON_MODE == always || ( $UI_ICON_MODE == auto && ${TERM:-dumb} != dumb &&
        ( -t ${3:-1} || ${DOTS_MENU_CAPTURE:-} == 1 ) ) ]]; then REPLY=${UI_ICONS[$1]-$2}; fi
}

ui_git_style() {
    REPLY=''
    [[ -n $RESET ]] || return 0
    local code
    case $1 in
        repo) code='1;95' ;; repo_owned) code='1;93' ;; branch|untracked) code=95 ;;
        modified|behind|detached|missing) code=93 ;; staged|added|clean|ahead) code=92 ;;
        deleted|blocked) code=91 ;; conflict) code='1;91' ;; renamed|copied) code=96 ;;
        ignored) code='2;90' ;; *) code=94 ;;
    esac
    printf -v REPLY '\033[%sm' "${UI_GIT[$1]:-$code}"
}

ui_file_style() {
    local name=${1##*/} kind=${2:-file} size id priority best=2147483647 code=97
    local group pattern icon=files.file fallback='󰈔' mime='' i
    if [[ -z ${2:-} ]]; then
        if [[ -L $1 ]]; then
            if [[ -e $1 ]]; then kind=symlink; else kind=broken_symlink; fi
        elif [[ -d $1 ]]; then kind=dir
        elif [[ -f $1 && -x $1 ]]; then kind=executable
        elif [[ ! -e $1 ]]; then kind=missing
        fi
    fi
    for ((i=0;i<${#UI_RESOURCE_ROWS[@]};i+=5)); do
        group=${UI_RESOURCE_ROWS[i]} pattern=${UI_RESOURCE_ROWS[i+1]}
        if [[ $group == kind && $pattern == "$kind" ]]; then
            icon=${UI_RESOURCE_ROWS[i+2]}; fallback=${UI_RESOURCE_ROWS[i+4]}
        elif [[ $kind == @(file|missing) ]] &&
            [[ ( $group == name && $name == "$pattern" ) || ( $group == suffix && ${name,,} == *"${pattern,,}" ) ]]; then
            icon=${UI_RESOURCE_ROWS[i+2]}; mime=${UI_RESOURCE_ROWS[i+3]}; fallback=${UI_RESOURCE_ROWS[i+4]}; break
        fi
    done
    ui_icon "$icon" "$fallback"; UI_FILE_ICON=$REPLY
    REPLY=''
    [[ -n $RESET ]] || return 0
    case $kind in dir) code='1;94' ;; executable) code=92 ;; symlink) code=96 ;; broken_symlink) code=91 ;; esac
    code=${UI_TYPES[$kind]:-$code}
    if [[ $kind == file || $kind == missing ]]; then
        local folded=${name,,}
        for size in "${!UI_SUFFIX_SIZES[@]}"; do
            ((size <= ${#name})) || continue
            for id in "exact:${name: -size}" "fold:${folded: -size}"; do
                priority=${UI_SUFFIX_ORDER[$id]:-2147483647}
                if ((priority<best)); then
                    best=$priority; code=${UI_SUFFIX_STYLE[$id]}
                fi
            done
        done
    fi
    if [[ $mime && $mime != '-' ]]; then
        for id in "$mime" "${mime%/*}/*"; do
            priority=${UI_MIME_ORDER[$id]:-2147483647}
            if ((priority<best)); then
                best=$priority; code=${UI_MIME_STYLE[$id]}
            fi
        done
    fi
    printf -v REPLY '\033[%sm' "$code"
}

ui_help_style() {
    local role=$1 code
    REPLY=''
    [[ -n $RESET ]] || return 0
    case $role in
        executable) code=36 ;; command) code=34 ;; subcommand) code=35 ;; option) code=33 ;;
        heading) code='1;96' ;; argument) code=32 ;; punctuation) code=90 ;; *) code=39 ;;
    esac
    printf -v REPLY '\033[%sm' "${UI_COLORS[help.$role]:-$code}"
}

ui_help_span() {
    [[ -n $2 ]] || return 0
    ui_help_style "$1"
    printf '%s%s%s' "$REPLY" "$2" "${REPLY:+$RESET}"
}

ui_help_tokens() {
    local rest=$1 token role grammar='^([[:space:]]+|--?[[:alnum:]][[:alnum:]-]*|[[:alnum:]_.-]+|.)'
    local -n tokens=$2
    tokens=()
    if [[ -z $RESET ]]; then tokens+=("$rest" ''); return; fi
    while [[ $rest =~ $grammar ]]; do
        token=${BASH_REMATCH[1]}; rest=${rest#"$token"}
        case $token in
            git-it|install.sh|uninstall.sh|bash) role=executable ;;
            -[[:alnum:]]*|--*) role=option ;; *[[:space:]]*) role=description ;;
            info|path|sync|status|publish) role='command' ;;
            *[[:alnum:]]*) role=argument ;; *) role=punctuation ;;
        esac
        ui_help_style "$role"; tokens+=("$token" "$REPLY")
    done
}

ui_help_syntax() {
    local -a syntax=()
    local i style
    ui_help_tokens "$1" syntax
    for ((i=0;i<${#syntax[@]};i+=2)); do
        style=${syntax[i+1]}
        printf '%s%s%s' "$style" "${syntax[i]}" "${style:+$RESET}"
    done
}

ui_help_row() { ui_field "$1" "$2" help; }

ui_logo_line() {
    printf ' '
    display "$1"; ui_help_span heading "$REPLY"; printf '\n'
}

# Only human filesystem labels use a literal tilde. Git and format fields keep
# the original path, including when this label contains whitespace or controls.
# shellcheck disable=SC2088
ui_path() {
    local home=${HOME:-} prefix
    REPLY=$1
    [[ $home == /* && ${FULL_PATHS:-0} == 0 ]] || return 0
    while [[ $home != / && $home == */ ]]; do home=${home%/}; done
    prefix=${home%/}/
    if [[ $1 == "$home" ]]; then REPLY='~'
    elif [[ $1 == "$prefix"* ]]; then REPLY="~/${1#"$prefix"}"; fi
}

ui_columns() {
    UI_COLUMNS=${COLUMNS:-${UI_TERM_COLUMNS:-80}}
    [[ $UI_COLUMNS =~ ^[0-9]{1,4}$ ]] || UI_COLUMNS=80
    UI_COLUMNS=$((10#$UI_COLUMNS))
    ((UI_COLUMNS >= 8)) || UI_COLUMNS=8
}

ui_indent() {
    local count=$1
    if [[ $UI_INDENT_STYLE == tabs ]]; then
        printf -v REPLY '%*s' "$((count/UI_TAB_WIDTH))" ''
        REPLY=${REPLY// /$'\t'}; printf -v REPLY '%s%*s' "$REPLY" "$((count%UI_TAB_WIDTH))" ''
    else printf -v REPLY '%*s' "$count" ''; fi
}

ui_cell_width() {
    local cp
    printf -v cp '%d' "'$1"
    if ((cp>=768 && cp<=879 || cp>=65024 && cp<=65039)); then REPLY=0
    elif ((cp>=4352 && cp<=4447 || cp>=11904 && cp<=42191 || cp>=44032 && cp<=55203 ||
           cp>=63744 && cp<=64255 || cp>=65281 && cp<=65376 || cp>=127744 && cp<=129791)); then REPLY=2
    else REPLY=1; fi
}

ui_spans() {
    local indent=$1 text style ch prefix i used=0 cells continuation=${UI_CONTINUATION:-$1}
    shift
    ui_columns
    ((indent < UI_COLUMNS-2)) || indent=$((UI_COLUMNS-2))
    ui_indent "$indent"; printf '%s' "$REPLY"
    ((continuation < UI_COLUMNS-2)) || continuation=$((UI_COLUMNS-2))
    ui_indent "$continuation"; prefix=$REPLY
    if [[ ! -t 1 && ${DOTS_MENU_CAPTURE:-} != 1 ]]; then
        while (($# >= 2)); do
            display "$1"; printf '%s%s%s' "$2" "$REPLY" "${2:+$RESET}"; shift 2
        done
        printf '\n'
        return
    fi
    while (($# >= 2)); do
        text=$1; style=$2; shift 2
        [[ -n $text ]] || continue
        if [[ $text != *[!\ -~]* ]] && ((used+${#text} <= UI_COLUMNS-indent)); then
            printf '%s%s%s' "$style" "$text" "${style:+$RESET}"
            ((used+=${#text})); continue
        fi
        display "$text"; text=$REPLY
        printf '%s' "$style"
        for ((i=0;i<${#text};i++)); do
            ch=${text:i:1}
            ui_cell_width "$ch"; cells=$REPLY
            if ((used+cells > UI_COLUMNS-indent && used)); then
                printf '%s\n%s%s' "${style:+$RESET}" "$prefix" "$style"; used=0; indent=$continuation
            fi
            printf '%s' "$ch"; ((used+=cells))
        done
        printf '%s' "${style:+$RESET}"
    done
    printf '\n'
}

ui_line() { ui_spans "$3" "$1" "$2"; }

ui_heading() {
    local style=${2:-$CYAN}
    [[ -z $style ]] || style=$BOLD$style
    ui_line "$1" "$style" 0
}

ui_field() {
    local label=$1 value=${2:-Not configured} indent=$UI_INDENT gap=$UI_GAP width=$UI_LABEL_WIDTH left=0
    local pad prefix after value_color=''
    local -a label_spans=("$label" "$BLUE")
    if [[ ${3:-} == help ]]; then
        value=${2:-}; ui_help_style description; value_color=$REPLY
        ui_help_tokens "$label" label_spans
        if [[ -z $value ]]; then ui_spans "$indent" "${label_spans[@]}"; return; fi
    elif [[ ${3:-} == path ]]; then
        ui_path "$value"; value=$REPLY
    fi
    ui_columns
    ((indent <= UI_COLUMNS-8)) || indent=$((UI_COLUMNS-8))
    ((gap <= UI_COLUMNS-indent-8)) || gap=$((UI_COLUMNS-indent-8))
    if [[ $width == *% ]]; then width=${width%\%}; width=$((UI_COLUMNS*10#$width/100))
    else width=$((10#$width)); fi
    ((width <= UI_COLUMNS-indent-gap-8)) || width=$((UI_COLUMNS-indent-gap-8))
    if ((width && ${#label}>width || indent+${#label}+gap>=UI_COLUMNS)); then
        ui_spans "$indent" "${label_spans[@]}"
        ui_line "$value" "$value_color" "$((indent+width+gap))"
    else
        pad=$((width-${#label})); ((pad >= 0)) || pad=0
        case $UI_ALIGN in center) left=$((pad/2)) ;; right) left=$pad ;; esac
        printf -v prefix '%*s' "$left" ''; printf -v after '%*s' "$((pad-left+gap))" ''
        local UI_CONTINUATION=$((indent+${#label}+pad+gap))
        ui_spans "$indent" "$prefix" '' "${label_spans[@]}" "$after" '' "$value" "$value_color"
    fi
}

ui_detail() { ui_line "$1" '' 4; }

ui_status() {
    local state=$1 role marker label
    case $state in
        blocked|failed) role=blocked; ui_icon status.error '' ;;
        updated|published|unchanged|Install) role=clean; ui_icon status.success '' ;;
        cancelled|'Preserve modified') role=modified; ui_icon status.warning '' ;;
        *) role=planned; ui_icon status.info '󰋽' ;;
    esac
    marker=$REPLY; printf -v label '%-10s' "$state"; ui_git_style "$role"
    ui_spans 2 "${marker:+$marker }$label" "$REPLY" " $2" ''
}

ui_summary() {
    printf '\n'
    ui_heading "$1" "$2"
    [[ -z ${3:-} ]] || ui_detail "$3"
    return 0
}
