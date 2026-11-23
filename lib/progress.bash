# Only the renderer runs in the background. Git keeps its stdin and the parent
# owns results, prompts and cleanup. The worker uses a private pipe as its timer.
# shellcheck shell=bash
progress_symbol() {
    local role=$1 default=$2 ascii=$3 symbol
    ui_icon "progress.bar.$role" "$default" 2; symbol=$REPLY
    if [[ -z $symbol && $UI_ICON_MODE != never && $role == @(left|right) ]]; then REPLY=''; return; fi
    if [[ ${#symbol} == 1 && $symbol != *[[:cntrl:]]* ]]; then
        ui_cell_width "$symbol"
        if ((REPLY==1)); then REPLY=$symbol; return; fi
    fi
    REPLY=$ascii
}

progress_worker() {
    local label=$1 completed=$2 total=$3 owner=$4 mode=$UI_PROGRESS
    trap - EXIT INT TERM HUP
    local width=80 resize=1 frame=0 spinner='' shown='' plain='' bar=''
    local prefix suffix length inner filled left right empty fill body rest point
    local reset='' fill_style='' empty_style='' boundary_style='' percent_style='' label_style=''
    local frames=$'|/-\\'
    if [[ $UI_ICON_MODE != never ]]; then frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; fi
    progress_symbol left '[' '['; left=$REPLY
    progress_symbol right ']' ']'; right=$REPLY
    progress_symbol empty '-' '-'; empty=$REPLY
    progress_symbol filled '━' '#'; fill=$REPLY
    if color_enabled 2; then
        reset=$'\e[0m'
        printf -v fill_style '\033[%sm' "${UI_COLORS[progress.filled]:-${UI_COLORS[96]:-96}}"
        printf -v percent_style '\033[%sm' "${UI_COLORS[progress.percentage]:-${UI_COLORS[96]:-96}}"
        printf -v empty_style '\033[%sm' "${UI_COLORS[progress.empty]:-${UI_COLORS[90]:-90}}"
        printf -v boundary_style '\033[%sm' "${UI_COLORS[progress.surround]:-${UI_COLORS[90]:-90}}"
        printf -v label_style '\033[%sm' "${UI_COLORS[94]:-94}"
    fi
    # The function can return on EOF before the worker shell's EXIT trap runs.
    # Store its last drawn width in that process, outside function-local scope.
    PROGRESS_DRAWN_WIDTH=0
    trap 'if ((PROGRESS_DRAWN_WIDTH)); then printf "\r%*s\r" "$PROGRESS_DRAWN_WIDTH" "" >&2; fi' EXIT
    trap 'exit 0' HUP TERM
    trap 'resize=1' WINCH
    while kill -0 "$owner" 2>/dev/null; do
        # EOF or a stop message ends the worker immediately. A timeout draws
        # the next frame; a short operation finishes before its first frame.
        local rc=0
        IFS= read -r -t 0.15 _ || rc=$?
        ((rc>128)) || break
        if ((resize)); then
            width=${COLUMNS:-80}
            if command -v stty >/dev/null 2>&1; then
                local geometry='' term_columns=''
                geometry=$(stty size <&2 2>/dev/null) && term_columns=${geometry##* }
                [[ $term_columns =~ ^[1-9][0-9]{0,3}$ ]] && width=$term_columns
            fi
            [[ $width =~ ^[1-9][0-9]{0,3}$ ]] || width=80
            ((width>1)) && ((width-=1))
            if ((PROGRESS_DRAWN_WIDTH>width)); then PROGRESS_DRAWN_WIDTH=$width; fi
            resize=0
        fi
        prefix='' suffix='' bar='' plain='' shown=$label
        if [[ $mode != bar ]]; then spinner=${frames:frame%${#frames}:1}; prefix="$spinner "; fi
        if ((total>0)); then suffix=" $completed/$total $((completed*100/total))%"; fi
        length=$((width-${#prefix}-${#suffix}))
        if [[ $mode != spinner && ( $mode == bar || $total -gt 0 ) ]]; then
            inner=$((length-${#left}-${#right}-1))
            if ((inner>0)); then
                # Keep room for the activity name, especially on narrow panes.
                ((inner<=24)) || inner=24
                if ((inner>length/2)); then inner=$((length/2)); fi
                if ((inner>0)); then
                    if ((total)); then
                        filled=$((completed*inner/total))
                        printf -v body '%*s' "$filled" ''; body=${body// /"$fill"}
                        printf -v rest '%*s' "$((inner-filled))" ''; rest=${rest// /"$empty"}
                        bar=$fill_style$body$reset$empty_style$rest$reset
                    else
                        point=$((frame%inner))
                        printf -v body '%*s' "$point" ''; body=${body// /"$empty"}
                        printf -v rest '%*s' "$((inner-point-1))" ''; rest=${rest// /"$empty"}
                        bar=$empty_style$body$reset$fill_style$fill$reset$empty_style$rest$reset
                    fi
                    bar=" $boundary_style$left$reset$bar$boundary_style$right$reset"
                    length=$((length-inner-${#left}-${#right}-1))
                fi
            fi
        fi
        ((length>=0)) || length=0
        shown=${shown:0:length}
        if ((width<${#suffix}+${#prefix})); then
            plain=${suffix# }; [[ -n $plain ]] || plain=$spinner
            plain=${plain:0:width}
            PROGRESS_DRAWN_WIDTH=${#plain}
            printf '\r%s%s%s' "$percent_style" "$plain" "$reset" >&2
        else
            PROGRESS_DRAWN_WIDTH=$((${#prefix}+${#shown}+${#suffix}))
            [[ -z $bar ]] || ((PROGRESS_DRAWN_WIDTH+=inner+${#left}+${#right}+1))
            printf '\r%s%s%s%s%s%s%s%s%s%s' "$fill_style" "$prefix" "$reset" "$label_style" "$shown" "$reset" "$bar" "$percent_style" "$suffix" "$reset" >&2
        fi
        ((frame+=1))
    done
}

progress_start() {
    progress_stop
    [[ ${JSON:-0} == 0 && ${DRY_RUN:-0} == 0 && ${NO_PROGRESS:-0} == 0 && -t 1 && -t 2 && ${TERM:-dumb} != dumb ]] || return 0
    ui_prepare
    [[ $UI_PROGRESS != none ]] || return 0
    local completed=${2:-0} total=${3:-0} label=$1 i ch clean='' owner=$BASHPID
    [[ $completed =~ ^[0-9]{1,9}$ && $total =~ ^[0-9]{1,9}$ ]] || { completed=0; total=0; }
    completed=$((10#$completed)) total=$((10#$total)); ((completed<=total)) || completed=$total
    # Width is measured in cells. Keep untrusted activity labels inert and
    # single-width, including paths containing control bytes or wide glyphs.
    for ((i=0;i<${#label} && i<200;i++)); do
        ch=${label:i:1}
        if [[ $ch == [\ -~] ]]; then clean+=$ch
        else printf -v ch '\\u%04x' "'$ch"; clean+=$ch; fi
    done
    if exec {PROGRESS_FD}> >(progress_worker "$clean" "$completed" "$total" "$owner"); then PROGRESS_PID=$!; fi
    return 0
}

progress_stop() {
    [[ -n ${PROGRESS_PID:-} ]] || return 0
    if [[ -n ${PROGRESS_FD:-} ]]; then exec {PROGRESS_FD}>&-; PROGRESS_FD=''; fi
    kill "$PROGRESS_PID" 2>/dev/null || :
    wait "$PROGRESS_PID" 2>/dev/null || :
    PROGRESS_PID=''
}

progress_run() {
    local label=$1 rc; shift
    progress_start "$label" "${progress_completed:-0}" "${progress_total:-0}"
    "$@" >/dev/null 2>&1; rc=$?
    progress_stop
    return "$rc"
}
