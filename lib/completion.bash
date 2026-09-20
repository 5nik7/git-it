# Completion output is static: generating it never reads a repository.
completion() {
    case $1 in
        bash) cat <<'EOF'
_git_it() {
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    local opts='info path sync publish --sync -C --config --no-config --color --no-color --get --json -f --format --list-fields -i --icon --remote --outermost --dry-run --all --yes -m --message -n --no-newline --completion -h --help -V --version'
    COMPREPLY=()
    case $prev in
        -C) mapfile -t COMPREPLY < <(compgen -d -- "$cur"); compopt -o filenames; return ;;
        --config) mapfile -t COMPREPLY < <(compgen -f -- "$cur"); compopt -o filenames; return ;;
        --color) opts='auto always never' ;;
        --completion) opts='bash zsh fish' ;;
        --get) opts='root remote url protocol host owner repo owned icon current parent outermost parent_dirname parent_basename submodule_prefix submodule_basename cwd_prefix path_parent path_outermost chain_length chain_repos chain_paths is_submodule' ;;
        --format|-f|--message|-m) return ;;
    esac
    mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
}
complete -F _git_it git-it
EOF
            ;;
        zsh) cat <<'EOF'
#compdef git-it
_git_it() {
    _arguments \
        '1:command:(info path sync publish)' \
        '--sync[Synchronize repository tree]' \
        '-C[Working directory]:directory:_directories' \
        '--config[Configuration file]:file:_files' \
        '--no-config[Ignore configuration]' \
        '--color[Color policy]:policy:(auto always never)' \
        '--no-color[Disable color]' \
        '--get[Single field]:field:(root remote url protocol host owner repo owned icon current parent outermost parent_dirname parent_basename submodule_prefix submodule_basename cwd_prefix path_parent path_outermost chain_length chain_repos chain_paths is_submodule)' \
        '--format[Named field format]:format:' \
        '-f[Named field format]:format:' \
        '--json[JSON output]' '--icon[Host icon]' '-i[Host icon]' \
        '--list-fields[List fields]' '--no-newline[Suppress newline]' \
        '-n[Suppress newline]' \
        '--remote[Inspection remote or sync branch advancement]' \
        '--outermost[Start at verified outermost parent]' \
        '--dry-run[Preview without network or writes]' \
        '--all[Publish tracked and untracked changes]' \
        '--yes[Accept publication preview]' \
        '--message[Commit message]:message:' \
        '-m[Commit message]:message:' \
        '--completion[Generate completion]:shell:(bash zsh fish)' \
        '--help[Help]' '-h[Help]' '--version[Version]' '-V[Version]'
}
_git_it "$@"
EOF
            ;;
        fish) cat <<'EOF'
complete -c git-it -f
complete -c git-it -n 'not __fish_seen_subcommand_from info path sync publish' -a 'info path sync publish'
complete -c git-it -s C -r -a '(__fish_complete_directories)' -d 'Working directory'
complete -c git-it -l config -r -F -d 'Configuration file'
complete -c git-it -l color -x -a 'auto always never'
complete -c git-it -l completion -x -a 'bash zsh fish'
complete -c git-it -l get -x -a 'root remote url protocol host owner repo owned icon current parent outermost parent_dirname parent_basename submodule_prefix submodule_basename cwd_prefix path_parent path_outermost chain_length chain_repos chain_paths is_submodule'
complete -c git-it -l format -s f -x
complete -c git-it -l message -s m -x
complete -c git-it -l icon -s i -d 'Host icon'
complete -c git-it -l no-newline -s n -d 'Suppress newline'
complete -c git-it -l help -s h -d 'Help'
complete -c git-it -l version -s V -d 'Version'
complete -c git-it -l sync -d 'Synchronize repository tree'
for flag in no-config no-color json list-fields outermost dry-run all yes remote
    complete -c git-it -l $flag
end
EOF
            ;;
        *) die 2 'completion shell must be bash, zsh, or fish' ;;
    esac
}
