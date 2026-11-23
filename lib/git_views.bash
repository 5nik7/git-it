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
    local dir=$1 i=$2 prefix=${3:-} path=${paths[$2]} old=${oldpaths[$2]} actual
    actual=${dir%/}/$path
    if ((FULL_PATHS)); then
        path=$actual; [[ ! $old ]] || old=${dir%/}/$old
    fi
    ui_file_style "$actual"
    ui_line "$prefix${UI_FILE_ICON:+$UI_FILE_ICON }${old:+$old -> }$path" "$REPLY" 6
}

status_files() {
    local dir=$1 xy i group_label group_role group_icon group_color label
    local -a order=() spans=()
    local -A members=() counts=()
    for i in "${!paths[@]}"; do
        xy=${codes[i]}
        [[ ${members[$xy]+set} ]] || order+=("$xy")
        members[$xy]+="$i "; counts[$xy]=$(( ${counts[$xy]:-0} + 1 ))
    done
    for xy in "${order[@]}"; do
        status_group "$xy"
        if [[ $view == short ]]; then
            if ((${#spans[@]})); then spans+=(' / ' ''); else spans+=('States  ' ''); fi
            spans+=("[$xy] (${counts[$xy]})" "$group_color")
        else
            label="$group_label (${counts[$xy]})"
            [[ $view != verbose ]] || label="[$xy] $label"
            ui_line "${group_icon:+$group_icon }$label" "$group_color" 4
            # Group membership holds integer array positions only.
            for i in ${members[$xy]}; do status_file_line "$dir" "$i"; done
        fi
    done
    if ((${#spans[@]})); then
        ui_spans 4 "${spans[@]}"
        for i in "${!paths[@]}"; do status_file_line "$dir" "$i" "[${codes[i]}] "; done
    fi
}
