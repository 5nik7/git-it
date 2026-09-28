# git-it

A modular Bash Git helper for Termux and Linux: local host icons, verified
submodule paths, recursive download synchronization, and explicit publication.

```bash
git-it -i                         # host icon for your prompt
git-it info --json                # local metadata
git-it sync                       # parent first, then pinned submodules
git-it sync --remote              # explicitly advance configured child branches
git-it publish --dry-run          # preview selected changes
git-it publish -m 'Update config' # preview, confirm, commit and push
```

Version **0.1.0**. Initial release with conservative operation rules. Termux and
Linux are the targets; Linux CI is included. Actual validation is recorded in
[docs/validation.md](docs/validation.md).

## Setup, run and installation

Requires Bash 5+, Git and standard core utilities. Publishing uses `sha256sum`;
installation also uses `realpath`, `install`, `mktemp`, `cp` and `tail`. A Nerd Font
is needed for host glyphs. Python 3 and ShellCheck are development dependencies.
Zsh, Fish and mandoc provide additional completion/manual validation.

On Termux: `pkg install bash git coreutils python shellcheck`.
On Debian/Ubuntu: `sudo apt-get install bash git coreutils python3 shellcheck`.
There is no build step or runtime dependency download.

```bash
bash ./git-it --help
bash ./install.sh --dry-run
bash ./install.sh
# Optional custom prefix:
bash ./install.sh --prefix "$HOME/.local"
```

Default prefix: `$PREFIX` on Termux, `$HOME/.local` otherwise. Add its `bin`
directory to PATH yourself if needed. Installation writes an absolute Bash
shebang for the environment, private modules, a man page and Bash/Zsh/Fish
completions. It does not edit shell startup files or configure Git.

The installer includes all three completion files, even when a shell is not
installed yet, and the manual:

| File | Location under the installation prefix |
| --- | --- |
| Man page | `share/man/man1/git-it.1` |
| Bash completion | `share/bash-completion/completions/git-it` |
| Zsh completion | `share/zsh/site-functions/_git-it` |
| Fish completion | `share/fish/vendor_completions.d/git-it.fish` |

Use your shell's completion system to load these locations: bash-completion for
Bash, `compinit` with the directory on `fpath` for Zsh, and Fish's vendor
completion search path. A custom prefix may need its completion and man
directories added to the shell's search paths and `MANPATH`. For a one-session
setup with a custom prefix, substitute its actual path below:

```bash
# Bash
source /path/to/prefix/share/bash-completion/completions/git-it
# Zsh
fpath=(/path/to/prefix/share/zsh/site-functions $fpath)
autoload -Uz compinit && compinit
# Fish
source /path/to/prefix/share/fish/vendor_completions.d/git-it.fish
```

Reinstall to upgrade an unmodified installation. Checksums identify managed files;
unrelated collisions, symlink destinations and locally modified files are refused.
Use the same prefix to uninstall:

```bash
bash ./uninstall.sh --dry-run
bash ./uninstall.sh
man git-it
```

Uninstall removes only unchanged managed files. Modified files and user config
are preserved; modified files produce a nonzero result and retain the manifest.
Empty installation directories may remain. There is no self-update mechanism.

## Inspection and prompt formatting

```bash
git-it
git-it -C ~/repos/dots -i
git-it info --remote origin --get host
git-it path --json
git-it path --format '{parent_basename}/{path_outermost}/{cwd_prefix}'
git-it --list-fields
```

Remote selection: explicit `--remote NAME`, current branch upstream remote, then
`origin`. Host icons identify all repositories, regardless of ownership. GitHub,
GitLab and Bitbucket have specific icons; other hosts and absent remotes use Git.
SSH, SCP-style, HTTPS, nested namespaces and local URLs are parsed. Displayed URLs
omit credentials, query strings and fragments. Hostnames match exactly.

| Group | Fields |
| --- | --- |
| Remote | `root`, `remote`, `url`, `protocol`, `host`, `owner`, `repo`, `owned`, `icon` |
| Roots | `current`, `parent`, `outermost`, `parent_dirname`, `parent_basename` |
| Paths | `path_parent`, `path_outermost`, `submodule_prefix`, `submodule_basename`, `cwd_prefix` |
| Ancestry | `is_submodule`, `chain_length`, `chain_repos`, `chain_paths` |

For `dots/windots/deeper/src`, `path_outermost` is the full `windots/deeper`
path and `cwd_prefix` is `src`. Ancestry verifies gitlinks and excludes unrelated
enclosing repositories. Linked worktrees are supported. Paths are physical paths.
For an ordinary repository, `parent` is empty, `outermost` equals `current`,
relative repository paths are `.`, and the chain contains one repository.

JSON chains are arrays; `--get` chains are newline-separated. JSON is the
unambiguous interface for filenames containing newlines. JSON escapes controls;
human/formatted values display escaped controls. Formats use `{field}` and double
braces for literal braces. Unknown fields are errors; there is no shell evaluation
or backslash expansion. Use `--no-newline` for prompts. Icon and formatted modes
print nothing outside Git; ordinary inspection reports a context error.

The [Starship example](examples/starship.toml) uses one formatter invocation and
Starship's own styling and default escaping. Merge it manually; full replacement
of Starship's directory module is outside this release.

## Configuration and ownership

Copy [examples/config](examples/config) to
`${XDG_CONFIG_HOME:-$HOME/.config}/git-it/config` and adjust your accounts:

```ini
[git-it]
    owner = github.com/5nik7
    owner = gitlab.com/team/subgroup
    hostAlias = github-work=github.com
    color = auto
```

Git-config syntax is read as data; includes and unknown keys are not accepted.
Use `--config FILE` or `--no-config` per invocation. CLI options override config.
`--color auto|always|never` controls color; `--no-color` means never. Auto requires
a terminal and no `NO_COLOR`; explicit always overrides that variable.

Human output uses compact headings, aligned labels, and colored statuses:
cyan for headings and plans, green for successful outcomes, yellow for warnings
and cancellation, and red for blockers and failures. Text labels remain readable
without color. Auto mode checks the destination stream: stdout for normal output
and stderr for diagnostics. JSON, bare `path` output, single-field values,
formatted prompt output, version output, and generated completion scripts stay
uncolored.
Help works without loading configuration; use CLI flags or `NO_COLOR` to control
its colors. Color flags can appear before or after `--help`.

Use `-v` or `--verbose` for additional explanations:

```bash
git-it info --verbose             # sanitized remote details and verified ancestry
git-it sync -v                    # full repository paths and routine status reasons
git-it publish --dry-run -v       # detailed local publication preview
```

Default operation output shows the root once, then uses `.` for that root and
relative paths for descendants. Routine execution successes occupy one line;
verbose mode adds their explanations and uses full paths. Blockers and failures
always include their reasons. Publish previews show selected files, branches, destinations,
messages, and child-pointer caveats. Dry-run limits remain visible in both modes.
Publication preview and execution have separate headings, followed by a result
that distinguishes completion, partial failure, and cancellation.

Inspection labels describe ownership as a configured owner match, not access
verification; missing metadata is shown as `Not configured`. Verbose mode adds
the sanitized URL, protocol, remote repository name, and verified ancestry.
It does not print raw Git logs or commands. There is no verbosity configuration
key. Repeating `-v` or `--verbose` has no additional effect; `-V` remains version.
Verbose does not change JSON, bare paths, field values, prompt formats, icons,
field lists, version output, or generated completion source.

During `sync` and `publish`, a colored spinner identifies the active Git step:
fetching, initializing, updating, checking out, committing, or pushing. It appears
after a short delay and clears before the result is printed. This indicates
activity, not a percentage or estimated completion time.

Animation requires both stdout and stderr to be terminals and a nonempty `TERM`
other than `dumb`. It works with default and verbose output. JSON, dry runs,
and redirected output retain static output, even with `--color always`.
`--no-color` and `NO_COLOR` keep the spinner plain; the usual explicit color
override still applies. Use `--no-progress` to disable animation, including when
credential helpers or signing tools need to draw their own terminal interface:

```bash
git-it sync --no-progress
git-it publish --verbose --no-progress
```

The installer and uninstaller also accept `--color auto|always|never` and
`--no-color`, honor `NO_COLOR` in auto mode, and keep redirected output plain.
Their default output shows the prefix and result. Add `-v` or `--verbose` for
per-file actions; dry runs always list intended actions, and modified-file
preservation warnings are always shown:

```bash
bash ./git-it --help --color always
bash ./install.sh --dry-run --color always
bash ./install.sh --verbose
```

Ownership is an exact host/namespace match, not proof of authentication or write
access. No owner is hardcoded. Publication checks the effective push URL, including
`pushurl`, rather than author identity or fetch URL. Local paths are not treated
as owned remote destinations. SSH aliases require an explicit hostAlias mapping.

## Recursive download sync

`sync` starts at the repository containing the current directory, or `-C DIR`.
`--outermost` explicitly climbs the verified parent chain. Only registered
submodules are traversed; unrelated nested repositories are not scanned.

The root requires an attached branch and one upstream. Fetch and fast-forward
retain local ahead commits and refuse divergence. Children default to the
parent-recorded commit; missing children are initialized, and checkouts may be
detached. Each parent updates before its descendants are discovered.

`sync --remote` selects `submodule.NAME.branch`, falling back to an attached
child's upstream. `branch=.` requires an attached parent. It does not guess a
default branch. Changed parent pointers remain unstaged. Existing local submodule
URL overrides are retained.

Local edits, staged changes, untracked files, operations in progress, unsafe paths
and unavailable commits block the affected subtree. Removing/retyping an existing
submodule or introducing one at an occupied path needs manual Git work. A child
commit needs remote-tracking reachability evidence before checkout leaves it.
Safe siblings continue; incomplete traversal returns nonzero.

## Recursive publish

```bash
git-it publish --dry-run
git-it publish -m 'Update shell configuration'
git-it publish --all --yes -m 'Sync repository tree'
```

Publish previews selections, messages and destinations, then asks once. Unattended
callers need `--yes`. Defaults to staged changes. `--all` explicitly stages tracked
and untracked changes, respecting ignore rules. Existing ahead commits also push.

Children publish before parents. Successfully published child pointers are staged
in their parent, without replacing a deliberately staged different pointer.
Failed children block dependent parents; independent siblings continue. Unchanged
third-party dependencies need no ownership; changed dependencies must pass checks.

Publication requires an owned push destination and attached upstream. Put new work
in a detached pinned submodule on its intended branch manually. Multiple push URLs,
custom push refspecs, mirror remotes and push-remote overrides are refused. Only
the selected branch pushes; tags are not automatically pushed. Git's recursive
push check guards submodule availability. Hooks and signing remain enabled. Failed
pushes leave local commits intact.

Neither operation automatically stashes, resets, cleans, rebases or force-pushes.
`--dry-run` makes no network calls, repository writes or locks; unknown remote
state and undiscovered descendants are identified. Publication rechecks snapshots
before mutation. Per-repository `git-it.lock` directories guard concurrent git-it
operations, including linked worktrees. Inspect stale locks before removing them.
Ordinary Git does not honor these locks: avoid competing mutations. Operations
are incremental, not an atomic transaction; completed work remains after failure.

## Development and validation

```bash
python3 -m unittest discover -s tests -v
for file in git-it install.sh uninstall.sh maintenance.sh lib/*.bash; do
    bash -n "$file"
done
shellcheck -x git-it install.sh uninstall.sh maintenance.sh lib/*.bash
mandoc -Tlint git-it.1
python3 tests/benchmark.py --runs 30
git diff --check
```

Tests use disposable repositories, isolated configuration and local bare remotes.
The SSH fixture runs pack commands against local repositories, without contacting
external hosts. Tests and benchmarks do not mutate personal repositories.

The root launcher selectively loads `lib/` modules for CLI/config, inspection,
recursive operations and completions. Inspection avoids loading mutation code.
Icon/path modes do not fetch, scan worktree status or refresh the index.
Benchmarks record warm median/p95 times and Git subprocess counts for file-count
and ancestry scenarios; no cold-start speed claim is made.

## Migration and exit codes

| Old interface | New interface |
| --- | --- |
| `git-it -i` / `--icon` | Preserved |
| `git-it -r`, `-o`, `-H`, `-p`, `-u` | `git-it info --get FIELD` |
| `gitsub --json` | `git-it path --json` |
| `gitsub -f '%M/%T/%W'` | `git-it path --format '{parent_basename}/{path_outermost}/{cwd_prefix}'` |
| `git-up` | Separate `git-it sync` and `git-it publish` |

No legacy wrappers or short-flag clusters. Exit statuses: `0` complete, preview,
help or cancellation; `1` failed/incomplete; `2` arguments/config; `3` dependency
or context. Operation JSON contains `complete`, `dry_run` and ordered `events`
with `path`, `status`, `detail`. MIT notice: [LICENSE](LICENSE).
