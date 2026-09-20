# CLI presentation and installation plan

User-requested preferences: colorized usage and other appropriate human output;
Bash, Zsh, and Fish completion; installation of the man page and all completions
with the CLI. These are continuing requirements recorded in [AGENT.md](../AGENT.md).

## Implementation scope

1. Color help headings, option names, diagnostics, operation status, and
   installation/removal messages. Preserve automatic terminal detection,
   `NO_COLOR`, explicit overrides, and plain machine-readable output.
2. Complete the supported short-option coverage in all three shells. Keep
   completion generation local and usable outside a repository.
3. Retain the installer's existing man-page and completion destinations and
   checksum-managed upgrade/removal behavior. Verify the installed files and
   exercise their completion behavior in native shells.
4. Update usage documentation and validate syntax, integration behavior,
   terminal color policy, installation, and uninstallation in disposable roots.

This task updates the repository implementation. Live installation and changes
to shell startup files are outside this task. Keep changes uncommitted/unpushed.

## Implementation status

The presentation changes and completion aliases are implemented. CLI help accepts
color flags on either side of `--help`; stdout and stderr detect terminals
independently. Install/uninstall share the CLI color policy. All three completion
files and the manual retain their existing managed installation paths.

Integration coverage now includes ANSI-free machine output, terminal detection,
`NO_COLOR` and CLI overrides, installer color controls, installed-file contents,
Bash and Fish completion candidates, interactive Zsh Tab completion, and removal
of the installed manual and completions. See [validation.md](validation.md) for
the recorded results.
