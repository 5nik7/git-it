# Shared rendering for NUL-decoded Git porcelain file lists. Callers supply
# the paths, oldpaths, codes and view for the snapshot being displayed.
# shellcheck shell=bash disable=SC2154
# Git's two porcelain columns encode independent staged and unstaged changes.
status_group() {
    local xy=$1 marker where word index
    group_label=''
    case $xy in
        '??') group_label=untracked ;; '!!') group_label=ignored ;;
        DD) group_label='conflict: both deleted' ;; AA) group_label='conflict: both added' ;;
        UU) group_label='conflict: both modified' ;; AU) group_label='conflict: added by us' ;;
        UA) group_label='conflict: added by them' ;; UD) group_label='conflict: deleted by them' ;;
        DU) group_label='conflict: deleted by us' ;;
        *) for index in 0 1; do
               marker=${xy:index:1}
               case $marker in
                   ' ') continue ;; M) word=modified ;; A) word=added ;; D) word=deleted ;;
                   R) word=renamed ;; C) word=copied ;; T) word='type changed' ;; *) word=$marker ;;
               esac
               if ((index)); then where=unstaged; else where=staged; fi
               group_label+=${group_label:+' + '}"$where $word"
           done ;;
    esac
    case $xy in
        *U*|AA|DD) group_role=conflict; group_icon='' ;;
        '??') group_role=untracked; group_icon='' ;;
        '!!') group_role=ignored; group_icon='' ;;
        *D*) group_role=deleted; group_icon='󰆴' ;;
        *R*) group_role=renamed; group_icon='' ;;
        *C*) group_role=copied; group_icon='' ;;
        *A*) group_role=added; group_icon='󰐕' ;;
        *T*) group_role=type_changed; group_icon='󰑓' ;;
        *) group_role=modified; group_icon='' ;;
    esac
    local color_role=$group_role
    if [[ $group_role == type_changed || $group_role == modified ]]; then
        if [[ ${xy:1:1} == ' ' ]]; then color_role=staged; else color_role=modified; fi
    fi
    ui_git_style "$color_role"; group_color=$REPLY
    ui_icon "git.status.$group_role" "$group_icon"; group_icon=$REPLY
}

status_file_line() {
    local dir=$1 i=$2 last=$3 prefix=${4:-} path=${paths[$2]} old=${oldpaths[$2]} actual
    actual=${dir%/}/$path
    if ((FULL_PATHS)); then
        path=$actual; [[ ! $old ]] || old=${dir%/}/$old
    fi
    if [[ ${TREE_FILES:-0} == 1 ]]; then
        local edge=$TREE_FORK edge_color=${guide_colors[${codes[i]}]}
        local UI_WRAP_GUTTER=$TREE_GUTTER UI_WRAP_EDGE="$TREE_BAR " UI_WRAP_EDGE_COLOR=$edge_color
        if [[ $i == "$last" ]]; then edge=$TREE_END; UI_WRAP_EDGE='  '; UI_WRAP_EDGE_COLOR=''; fi
        local -a segments=("$TREE_GUTTER" "$TREE_COLOR" "$edge " "$edge_color" "$prefix" '')
        local value shown style file_icon
        for value in "${oldpaths[$i]}" "${paths[$i]}"; do
            [[ -n $value ]] || continue
            shown=$value; (( ! FULL_PATHS )) || shown=${dir%/}/$value
            ui_file_style "${dir%/}/$value"; style=$REPLY; file_icon=$UI_FILE_ICON
            if [[ $value == "${paths[$i]}" && $old ]]; then segments+=(' → ' ''); fi
            [[ ! $file_icon ]] || segments+=("$file_icon " "$style")
            if [[ $shown == */* ]]; then
                ui_file_style "$dir" dir; segments+=("${shown%/*}/" "$REPLY"); shown=${shown##*/}
            fi
            segments+=("$shown" "$style")
        done
        ui_spans 0 "${segments[@]}"; return
    fi
    ui_file_style "$actual"
    ui_line "$prefix${UI_FILE_ICON:+$UI_FILE_ICON }${old:+$old -> }$path" "$REPLY" 6
}

status_files() {
    local dir=$1 xy i group_label group_role group_icon group_color label last heading_indent=4
    local TREE_FILES=${TREE_FILES:-0} TREE_GUTTER=${TREE_GUTTER:-} UI_WRAP_GUTTER=${UI_WRAP_GUTTER:-}
    if (( ! TREE_FILES )) && ui_tree_active; then TREE_FILES=1; ui_tree_symbols; TREE_GUTTER="  "; fi
    if ((TREE_FILES)); then heading_indent=0; UI_WRAP_GUTTER="$TREE_GUTTER  "; fi
    local -a order=() spans=()
    local -A members=() counts=() guide_colors=()
    for i in "${!paths[@]}"; do
        xy=${codes[i]}
        [[ ${members[$xy]+set} ]] || order+=("$xy")
        members[$xy]+="$i "; counts[$xy]=$(( ${counts[$xy]:-0} + 1 ))
    done
    for xy in "${order[@]}"; do
        status_group "$xy"
        if ((TREE_FILES)); then ui_foreground "$group_color"; guide_colors[$xy]=$REPLY; fi
        if [[ $view == short || ${REPORT_MODE:-status} == @(info|list) ]]; then
            if ((${#spans[@]})); then spans+=(' / ' ''); elif [[ ${REPORT_MODE:-status} == @(info|list) ]]; then spans+=('Changes  ' ''); else spans+=('States  ' ''); fi
            if [[ $view == short ]]; then label="[$xy]"; else label=$group_label; fi
            spans+=("$label (${counts[$xy]})" "$group_color")
        else
            label="$group_label (${counts[$xy]})"
            [[ $view != verbose ]] || label="[$xy] $label"
            ui_spans "$heading_indent" "$TREE_GUTTER" "${TREE_COLOR:-}" "${group_icon:+$group_icon }$label" "$group_color"
            # Group membership holds integer array positions only.
            last=${members[$xy]% }; last=${last##* }
            for i in ${members[$xy]}; do
                status_file_line "$dir" "$i" "$last"
            done
        fi
    done
    if ((${#spans[@]})); then
        ui_spans "$heading_indent" "$TREE_GUTTER" "${TREE_COLOR:-}" "${spans[@]}"
        if [[ ${REPORT_MODE:-status} == status ]]; then
            for i in "${!paths[@]}"; do
                status_file_line "$dir" "$i" "$((${#paths[@]}-1))" "[${codes[i]}] "
            done
        fi
    fi
}
