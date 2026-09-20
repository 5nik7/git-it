# Validation evidence

This record describes local execution of the initial implementation. The Linux
workflow is configured in `.github/workflows/test.yml` but has not been run from
this uncommitted checkout. No native Linux, macOS or Windows result is claimed.

## Native environment

- Android 15 / Termux, aarch64.
- Bash 5.3.15, Git 2.55.0.
- Python unittest runner, ShellCheck, mandoc, Bash, Zsh and Fish available locally.
- Repository mutations confined to disposable test-owned roots and bare remotes.
- No live installation, commit, push, or modification of the legacy scripts.

## Functional checks

Final native run: **37 tests passed in 91.703 seconds**. Bash syntax,
ShellCheck, Bash/Zsh/Fish completion syntax, mandoc lint, and tracked/new-file
whitespace checks passed. No platform skips occurred in this Termux run.

The suite covers inspection/configuration/formatting, three-level submodule
ancestry, pinned and remote sync, missing initialization, local ahead commits,
divergence, staged/unstaged/ignored-file preservation, locks, special filenames,
linked worktrees, staged-only and all-files publication, ownership/push overrides,
child-before-parent publication, safe sibling continuation, and staged gitlinks.

Additional tests exercise real terminal cancellation, process-group interruption,
completion syntax in Bash/Zsh/Fish, disposable installation/upgrade/uninstallation,
modified-file preservation, symlink/FIFO refusal and installer rollback.

Failure injection is explicit: remote rejection uses a test-owned receive hook;
interruption uses a Git wrapper that pauses a fetch; installation failure uses an
`install` wrapper. Successful Git operations are native Git execution against
local remotes, including an SSH fixture that runs pack commands locally. These
tests do not validate a real network provider, credentials or signing hardware.

Commands:

```bash
python3 -m unittest discover -s tests -v
for file in git-it install.sh uninstall.sh maintenance.sh lib/*.bash; do
    bash -n "$file"
done
shellcheck -x git-it install.sh uninstall.sh maintenance.sh lib/*.bash
mandoc -Tlint git-it.1
git diff --check
```

## CLI presentation and installation update — September 20, 2026

After the changes recorded in [planning.md](planning.md), the full native Termux
suite passed: **42 tests in 97.783 seconds**, with no skips. Bash syntax,
ShellCheck, mandoc lint, edited-file whitespace, and Markdown link checks passed.

The added coverage verifies colored help and diagnostics, separate stdout/stderr
terminal detection, `NO_COLOR` and explicit overrides, plain machine output,
operation status colors, and installer/uninstaller color controls. Disposable
installation checks confirm the man page and all three generated completions,
native Bash and Fish completion candidates, interactive Zsh Tab completion, and
removal of the unchanged manual and completion files.

Existing preservation, rollback, sync, and publication tests also passed. No
live installation, shell configuration change, commit, or external push was
performed. Linux CI was not run for this update. The earlier timing evidence
below is retained; benchmarks were not rerun for these presentation changes.

## Prompt timing

Thirty sequential warm invocations per scenario, preceded by three warmups, in
disposable repositories. Timing used an uninstrumented PATH. External-command
counts came from a separate invocation with wrappers; these counts exclude Bash
subshells and are not a total process/fork count. Queries used `--no-config`;
loading an existing user configuration requires an additional Git config read.
No cold-cache, thermal-control or production-latency guarantee is implied.

| Scenario | Median ms | p95 ms | Git calls | Other counted commands |
| --- | ---: | ---: | ---: | ---: |
| New icon, small repo | 80.932 | 86.146 | 4 | 0 |
| Legacy icon, same repo | 139.995 | 170.448 | 2 | 8 |
| New icon, 3,000 untracked files | 82.160 | 92.568 | 4 | 0 |
| New path, one repository | 119.715 | 129.101 | 6 | 0 |
| New path, two-level chain | 187.135 | 202.457 | 9 | 0 |
| New path, three-level chain | 262.585 | 273.160 | 11 | 0 |
| Legacy path, three-level chain | 435.196 | 472.579 | 12 | 20 |

All measured commands exited successfully. The legacy three-level path output
was `top/middle/`; the rebuilt command returned `top/middle/leaf/`. Therefore this
is a comparison of analogous tasks, not identical output semantics. The icon
output was identical. File-count growth did not change the icon's Git call count;
path call counts grew with ancestry depth.

The baseline files were the local legacy `dots/bin/git-it` and `dots/bin/gitsub`.
They were only read and executed in inspection modes, inside disposable roots.
SHA-256 identifies the versions used:

```text
git-it  4ffa86f31d0b473a969f5fd06603fd34557f932024abd4434aa91d6e75aaba2e
gitsub  c7502a8fa9bae21e098cd7c9adf347d34964f4f8dc9a4f0d42397266b771ebe6
```

Reproduce with explicit local baseline paths:

```bash
python3 tests/benchmark.py --runs 30 \
  --baseline-icon /path/to/legacy/git-it \
  --baseline-path /path/to/legacy/gitsub
```

Omit the baseline options to benchmark only the new implementation. Linux CI is
configured to retain its own JSON benchmark artifact when the workflow runs.

## Limits

Publication and synchronization are incremental across repositories. Ordinary
Git commands do not honor git-it's locks; avoid competing mutations. Branch and
input snapshots are rechecked, but no cross-repository atomicity is promised.
SIGKILL or machine failure can leave a stale lock; inspect it manually. A caught
installer failure restores prior files, while power-loss atomic installation is
not claimed. Git's own transport, hooks, authentication and signing policies apply.
