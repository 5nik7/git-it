# Use the same literal completion source for --completion and installation.
completion() {
    local installed file
    case $1 in
        bash) installed=bash-completion/completions/git-it ;;
        zsh) installed=zsh/site-functions/_git-it ;;
        fish) installed=fish/vendor_completions.d/git-it.fish ;;
        *) die 2 'completion shell must be bash, zsh, or fish' ;;
    esac
    if [[ $DATA == "$BASE" ]]; then file=$DATA/completion/$1
    else file=${DATA%/*}/$installed; fi
    [[ -f $file && -r $file ]] || die 3 "cannot read completion for $1"
    cat -- "$file"
}
