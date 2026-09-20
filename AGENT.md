# Agent guidance for git-it

Read this file before working in this repository. It applies throughout the
repository, alongside any more specific directory instructions. Current explicit
user instructions take precedence over the defaults below.

This file was reconstructed from recorded user preferences and the current
project documentation. It is not a verbatim recovery of the deleted file.
Historical task restrictions remain scoped to their tasks; they do not imply
approval of new work here.

## Working with the user

- Treat requests to fix or implement something as authorization to do the work
  within that scope. Carry authorized work through appropriate validation.
- Make routine, reversible implementation decisions independently. Do not ask
  repeatedly for permission already given in the current conversation.
- Respect explicit phase boundaries. "Inspection and planning only" means no
  edits or installs. "Do not implement" and "do not begin the next phase" remain
  binding even when implementation looks straightforward.
- Ask only for missing information or authorization that materially affects the
  task. Complete independent authorized work while awaiting an answer. Explain
  the concrete reason and source of any required approval.
- Keep changes bounded and reviewable. Avoid unrelated refactors, migrations,
  repository reorganization, dependency additions, or speculative features.
- Give concise progress updates during longer work. Explain findings, remaining
  uncertainty, and the next useful step in plain language.
- Final reports should say what changed, why, what was checked, and what remains
  unverified or blocked. Link the relevant files and retained evidence.

## Preserve local work and publication boundaries

- Inspect Git status and applicable instructions before editing. Treat existing
  tracked modifications, untracked files, and staged changes as user-owned work.
- Preserve unrelated files, the index, local commits, refs, historical decisions,
  repository layout, and retained validation evidence. Do not use broad staging
  or destructive cleanup to make a checkout look clean.
- Leave changes uncommitted and unpushed unless the user authorizes those actions.
  Successful tests or CI do not override an explicit no-commit/no-push boundary.
  Disposable fixture commits and pushes to test-owned local remotes are allowed
  as part of authorized testing.
- When a commit or push is authorized, inspect the actual staged paths and diff,
  include only the intended work, and honor any requested destination/refspec.
- Preserve the live dots command, legacy scripts, dotfiles, shell setup,
  personal Git configuration, and unrelated assets such as logo.txt. Working on
  git-it does not authorize modifying or installing into those locations.
- Respect explicit worktree restrictions. If asked to reuse an existing
  worktree, inspect `git worktree list --porcelain` and use the authorized one.
- Do not run sync, publish, install, uninstall, or maintenance against personal
  repositories or live prefixes merely to validate a code change.

## Project context

git-it is a modular Bash Git helper targeting Termux and Linux. Read
[README.md](README.md) for the interface, [git-it.1](git-it.1) for the manual,
and [docs/validation.md](docs/validation.md) for recorded evidence and limits.

- `git-it`: launcher; requires Bash 5 or newer.
- `lib/core.bash`: CLI and configuration handling.
- `lib/inspect.bash`: local metadata, paths, formatting, and ancestry.
- `lib/operations.bash`: recursive synchronization and publication.
- `lib/completion.bash`: shell completions.
- `install.sh`, `uninstall.sh`, `maintenance.sh`: installation and maintenance.
- `tests/test_git_it.py`: integration tests using disposable repositories.
- `tests/benchmark.py`: warm timing and external-command measurements.
- `.github/workflows/test.yml`: configured Linux validation workflow.

There is no build step or runtime dependency download. Preserve the separation
between inspection and mutation, and keep documentation consistent with changes
to observable behavior. Do not import dots-specific Go experiments, phase plans,
or validation commands into this project without an explicit task requiring them.

## Behavioral contracts to preserve

- Plan for colorized human-readable output, including usage/help, summaries,
  operation status, errors, and installer messages wherever useful. Respect
  `--color auto|always|never`, `--no-color`, and `NO_COLOR`; auto mode checks the
  destination stream's terminal. Keep JSON, field values, formatted prompt
  output, and generated completion source free of added ANSI sequences.
- Maintain completions for Bash, Zsh, and Fish alongside CLI changes, including
  supported short options and option values. The installer must install all
  three completion files and the man page into the selected prefix, and the
  uninstaller must manage them with the same preservation rules as other files.
- Inspection and prompt modes remain local. Icon/path queries must not fetch,
  scan worktree status, or refresh the index.
- Dry runs make no network calls, repository writes, or locks. Identify unknown
  state instead of claiming the preview proves remote readiness.
- Configuration is data, never shell code. Keep exact host/namespace matching,
  explicit host aliases, credential redaction, safe control-character handling,
  and unambiguous JSON output.
- Verify registered submodule ancestry; do not treat arbitrary nested
  repositories as submodules. Do not initialize private or unrelated submodules
  during general verification.
- Sync updates parents before descendants and defaults to pinned child commits.
  Remote branch advancement requires the explicit remote mode.
- Publish handles children before parents, previews intended changes and
  destinations, and retains explicit confirmation or unattended opt-in. Preserve
  staged-only defaults and explicit all-files selection.
- Check the effective push destination, ownership configuration, upstream, and
  snapshot safety. Ownership matching does not prove authentication or access.
  Preserve hooks and signing in real operations.
- Never add automatic stash, reset, clean, rebase, or force-push behavior.
  Preserve local work and refuse unsafe or uncertain mutations.
- Keep installation scoped to managed files. Refuse unsafe paths, symlink
  destinations, special files, unrelated collisions, and locally modified files.
- Do not describe multi-repository operations as atomic transactions. Report
  partial completion and retain failed-operation evidence accurately.

## Safety and validation

- For safety defects, reproduce the failure first in disposable, test-owned
  roots. Preserve originals and use local bare remotes with isolated config.
- Inspect filesystem metadata before opening potentially special files. Refuse
  FIFOs, sockets, device nodes, and unresolved path uncertainty where safety
  depends on an ordinary file or directory.
- Exercise meaningful failure cases for affected behavior, including spaces,
  existing targets, broken symlinks, staged work, and partial failures where
  relevant. Clearly distinguish injected failures from native execution.
- Use retained evidence when it still applies. Run checks appropriate to the
  change; broaden or repeat them for new changes, failures, or concrete doubt.
  Documentation-only edits need link and whitespace review, not a full runtime
  or benchmark rerun.
- Do not claim that configured CI has run. Distinguish proposed from implemented
  behavior, compilation from native target execution, and experimental evidence
  from production support. Report platform skips and missing coverage honestly.
- Warm benchmarks do not establish cold-start or cold-cache performance.
  Checksums establish integrity against a manifest, not publisher identity.

Available checks from the repository root, selected according to the change:

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

`git diff --check` does not cover untracked files; review newly created files too.
Do not install missing validation tools without authorization. Report checks
that could not run and the reason.

## Termux workflow

- Account for Termux paths and available tools; avoid assuming `/bin/bash`,
  desktop Linux filesystem layout, or native Windows/macOS support.
- Prefer `rg` and `rg --files` for searches. If the supplied executable fails
  with `cannot execute: required file not found`, use `grep`, `find`, or Python.
- Quote paths, preserve unusual filenames, and avoid evaluating user-controlled
  text as shell code. Keep inspection and tests away from personal credentials.
