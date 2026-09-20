# Installation uses a fixed allowlist and a checksum manifest, never shell eval.
# shellcheck shell=bash
# Reuse presentation helpers without invoking the CLI or loading configuration.
# shellcheck source=lib/core.bash
source "$SOURCE_DIR/lib/core.bash"
maintenance_fail() {
    colors; display "$*"
    printf '%sgit-it maintenance:%s %s\n' "$ERR_RED" "$ERR_RESET" "$REPLY" >&2
    exit 1
}
checksum() { local line; line=$(sha256sum < "$1") || return 1; DIGEST=${line%% *}; }
maintenance_cleanup() {
    local i dest
    if [[ ${MAINT_FINISHED:-0} == 0 ]]; then
        for ((i=${#MAINT_CHANGED[@]}-1;i>=0;i--)); do
            dest=${MAINT_CHANGED[i]}
            if [[ -f $INSTALL_STAGE/backup-$i ]]; then
                cp -p -- "$INSTALL_STAGE/backup-$i" "$dest" || printf 'Could not restore %s\n' "$dest" >&2
            else
                rm -f -- "$dest" || printf 'Could not remove partial file %s\n' "$dest" >&2
            fi
        done
    fi
    [[ -z ${INSTALL_STAGE:-} ]] || rm -rf -- "$INSTALL_STAGE"
    [[ -z ${MAINT_LOCK:-} ]] || rmdir -- "$MAINT_LOCK" 2>/dev/null || :
}

maintenance_write() {
    local source=$1 dest=$2 mode=$3 idx=${#MAINT_CHANGED[@]}
    if [[ -f $dest ]]; then
        cp -p -- "$dest" "$INSTALL_STAGE/backup-$idx" || return 1
    fi
    MAINT_CHANGED+=("$dest")
    install -D -m "$mode" -- "$source" "$dest"
}
maintenance_safe_path() {
    local rel=$1 part cursor=$INSTALL_PREFIX
    while [[ -n $rel ]]; do
        part=${rel%%/*}; cursor+=/$part
        [[ ! -L $cursor ]] || return 1
        if [[ $rel == */* ]]; then
            [[ ! -e $cursor || -d $cursor ]] || return 1
            rel=${rel#*/}
        else [[ ! -e $cursor || -f $cursor ]] || return 1; break; fi
    done
}
maintenance_main() {
    local action=$1; shift
    local dry=0 arg rel hash extra manifest temp='' interpreter mode i result=0 show_help=0
    COLOR=auto JSON=0
    INSTALL_PREFIX=${PREFIX:-$HOME/.local}
    while (($#)); do
        arg=$1; shift
        case $arg in
            --prefix=*) INSTALL_PREFIX=${arg#*=} ;;
            -p|--prefix) (($#)) || maintenance_fail '--prefix requires a directory'; INSTALL_PREFIX=$1; shift ;;
            -n|--dry-run) dry=1 ;;
            --color=*) COLOR=${arg#*=} ;;
            --color) (($#)) || maintenance_fail '--color requires a policy'; COLOR=$1; shift ;;
            --no-color) COLOR=never ;;
            -h|--help) show_help=1 ;;
            -V|--version) bash "$SOURCE_DIR/git-it" --version; return $? ;;
            *) maintenance_fail "unknown argument: $arg" ;;
        esac
    done
    case $COLOR in auto|always|never) ;; *) maintenance_fail 'color must be auto, always, or never' ;; esac
    colors
    if ((show_help)); then
        printf '%sUsage:%s bash %s.sh [--prefix DIR] [--dry-run]\n' "$CYAN" "$RESET" "$action"
        printf '       [--color auto|always|never] [--no-color]\n'
        return 0
    fi
    [[ -n $INSTALL_PREFIX ]] || maintenance_fail 'empty prefix'
    INSTALL_PREFIX=$(realpath -m -- "$INSTALL_PREFIX") || maintenance_fail 'cannot resolve prefix'
    [[ $INSTALL_PREFIX != / ]] || maintenance_fail 'refusing filesystem root as prefix'
    local -a paths=(bin/git-it lib/git-it/core.bash lib/git-it/inspect.bash lib/git-it/operations.bash lib/git-it/completion.bash share/man/man1/git-it.1 share/bash-completion/completions/git-it share/zsh/site-functions/_git-it share/fish/vendor_completions.d/git-it.fish)
    local -A allowed=() previous=()
    for rel in "${paths[@]}"; do allowed[$rel]=1; done
    manifest=$INSTALL_PREFIX/share/git-it/manifest
    maintenance_safe_path share/git-it/manifest || maintenance_fail 'unsafe manifest path'
    if [[ -f $manifest ]]; then
        while IFS=$'\t' read -r hash rel extra; do
            [[ $hash =~ ^[0-9a-f]{64}$ && -n $rel && -v allowed[$rel] && -z $extra && ! -v previous[$rel] ]] || maintenance_fail 'invalid installation manifest'
            previous[$rel]=$hash
        done < "$manifest"
    fi
    for rel in "${paths[@]}"; do
        maintenance_safe_path "$rel" || maintenance_fail "unsafe destination: $rel"
        if [[ -e $INSTALL_PREFIX/$rel ]]; then
            [[ -v previous[$rel] ]] || maintenance_fail "unmanaged destination exists: $rel"
            checksum "$INSTALL_PREFIX/$rel" || maintenance_fail "cannot hash $rel"
            if [[ $DIGEST != "${previous[$rel]}" ]]; then
                if [[ $action == install ]]; then maintenance_fail "locally modified file preserved: $rel"
                else printf '%sPreserve modified%s %s\n' "$YELLOW" "$RESET" "$rel"; result=1; fi
            fi
        fi
    done
    if [[ $action == uninstall ]]; then
        MAINT_LOCK=''
        if ((!dry)) && [[ -d $INSTALL_PREFIX ]]; then
            mkdir -- "$INSTALL_PREFIX/.git-it-install.lock" 2>/dev/null || maintenance_fail 'installation is locked; inspect a stale lock manually'
            MAINT_LOCK=$INSTALL_PREFIX/.git-it-install.lock
            trap 'rmdir -- "$MAINT_LOCK" 2>/dev/null || :' EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
        fi
        for rel in "${paths[@]}"; do
            maintenance_safe_path "$rel" || maintenance_fail "destination changed before removal: $rel"
            [[ -v previous[$rel] && -f $INSTALL_PREFIX/$rel ]] || continue
            checksum "$INSTALL_PREFIX/$rel" || maintenance_fail "cannot hash $rel"
            if [[ $DIGEST != "${previous[$rel]}" ]]; then result=1; continue; fi
            printf '%sRemove%s %s\n' "$CYAN" "$RESET" "$rel"
            ((dry)) || rm -- "$INSTALL_PREFIX/$rel" || maintenance_fail "cannot remove $rel"
        done
        if ((!dry && result == 0)) && [[ -f $manifest ]]; then rm -- "$manifest" || return 1; fi
        [[ -z $MAINT_LOCK ]] || rmdir -- "$MAINT_LOCK" || return 1
        trap - EXIT INT TERM
        return "$result"
    fi
    temp=$(mktemp -d) || maintenance_fail 'cannot create staging directory'
    # Staging is outside the installation; dry runs leave the prefix untouched.
    INSTALL_STAGE=$temp; MAINT_CHANGED=(); MAINT_FINISHED=0; MAINT_LOCK=''
    trap maintenance_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    interpreter=$(command -v bash) || maintenance_fail 'Bash is required'
    [[ $interpreter == /* && $interpreter != *$'\n'* && $interpreter != *' '* ]] || maintenance_fail 'Bash interpreter needs an absolute path without spaces'
    for ((i=0;i<${#paths[@]};i++)); do
        rel=${paths[i]}
        case $rel in
            bin/git-it) { printf '#!%s\n' "$interpreter"; tail -n +2 "$SOURCE_DIR/git-it"; } > "$temp/$i" ;;
            lib/git-it/*) cp -- "$SOURCE_DIR/lib/${rel##*/}" "$temp/$i" ;;
            share/man/*) cp -- "$SOURCE_DIR/git-it.1" "$temp/$i" ;;
            share/bash*) bash "$SOURCE_DIR/git-it" --completion bash > "$temp/$i" ;;
            share/zsh*) bash "$SOURCE_DIR/git-it" --completion zsh > "$temp/$i" ;;
            share/fish*) bash "$SOURCE_DIR/git-it" --completion fish > "$temp/$i" ;;
        esac || maintenance_fail "cannot stage $rel"
        checksum "$temp/$i" || maintenance_fail 'cannot hash staged file'
        printf '%s\t%s\n' "$DIGEST" "$rel" >> "$temp/manifest"
    done
    if ((!dry)); then
        mkdir -p -- "$INSTALL_PREFIX" || maintenance_fail 'cannot create prefix'
        mkdir -- "$INSTALL_PREFIX/.git-it-install.lock" 2>/dev/null || maintenance_fail 'installation is locked; inspect a stale lock manually'
        MAINT_LOCK=$INSTALL_PREFIX/.git-it-install.lock
        # Staging can take time. Revalidate after taking the installation lock.
        maintenance_safe_path share/git-it/manifest || maintenance_fail 'manifest path changed during staging'
        for rel in "${paths[@]}"; do
            maintenance_safe_path "$rel" || maintenance_fail "destination changed during staging: $rel"
            if [[ -e $INSTALL_PREFIX/$rel ]]; then
                [[ -v previous[$rel] ]] || maintenance_fail "new collision during staging: $rel"
                checksum "$INSTALL_PREFIX/$rel" || maintenance_fail "cannot recheck $rel"
                [[ $DIGEST == "${previous[$rel]}" ]] || maintenance_fail "file changed during staging: $rel"
            fi
        done
    fi
    for ((i=0;i<${#paths[@]};i++)); do
        rel=${paths[i]}; printf '%sInstall%s %s\n' "$GREEN" "$RESET" "$rel"
        if ((!dry)); then
            mode=644; [[ $rel != bin/git-it ]] || mode=755
            maintenance_write "$temp/$i" "$INSTALL_PREFIX/$rel" "$mode" || maintenance_fail "install failed at $rel (restoring prior files)"
        fi
    done
    if ((!dry)); then maintenance_write "$temp/manifest" "$manifest" 644 || maintenance_fail 'cannot install manifest'; fi
    MAINT_FINISHED=1; maintenance_cleanup; trap - EXIT INT TERM
}
