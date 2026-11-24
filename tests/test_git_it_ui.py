"""Standalone presentation and lazy Dots integration, with test-owned inputs."""
import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import termios
import unittest

import test_git_it as fixtures


def styled_lines(output):
    """Pair each visible character with its active SGR for span-level assertions."""
    active = ""
    rows = []
    for line in output.splitlines():
        parts = re.split(r"\x1b\[([0-9;]*)m", line)
        styles = []
        for i, part in enumerate(parts):
            if i % 2:
                active = "" if part in ("", "0") else part
            else:
                styles.extend([active] * len(part))
        rows.append(("".join(parts[::2]), styles))
    return rows


class PresentationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GitItTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.repo = self.fixture.repo("presentation")
        self.env = {key: value for key, value in self.fixture.env.items()
                    if not key.startswith("DOTS") and key != "NO_COLOR"}
        self.dots = self.fixture.base / "dots"
        self.theme = self.fixture.base / "state/dots/current/theme"
        self.theme.mkdir(parents=True)
        self.lib = self.dots / "lib/dots"
        self.lib.mkdir(parents=True)
        self.env.update(DOTS=str(self.dots), XDG_STATE_HOME=str(self.fixture.base / "state"),
                        TERM="xterm-256color")
        self.prefs = self.fixture.base / "prefs"
        self.probes = self.fixture.base / "probes"
        self.env.update(TEST_PREFS=str(self.prefs), TEST_PROBES=str(self.probes))
        (self.lib / "profile_config.py").write_text(
            "import os, pathlib, sys\n"
            "assert sys.argv[1:] == ['__settings']\n"
            "with open(os.environ['TEST_PROBES'], 'a') as log: log.write('probe\\n')\n"
            "print(pathlib.Path(os.environ['TEST_PREFS']).read_text(), end='')\n")
        self.prefs.write_text("__help.color.option\t38;5;123\tstyle\n"
                              "__color.git_guide\t38;5;238\tstyle\n"
                              "__cli.progress\tboth\tliteral\n"
                              "__format.label_width\t14\tformatting\n"
                              "__format.indent\t3\tformatting\n"
                              "__icon.git.status.untracked\t?\tstyle\n")
        (self.theme / "git-styles.tsv").write_text(
            "dots-git-styles\t1\nuntracked\t38;5;165\nmodified\t1;48;5;236;38;5;166\n")
        (self.theme / "file-styles.tsv").write_text(
            "dots-file-styles\t1\ntype\tfile\t39\t-\ntype\tdir\t38;5;118\t-\n"
            "suffix\t.xyz\t38;5;177\tfold\n")

    def cli(self, *args, **kwargs):
        return self.fixture.cli(self.repo, *args, env=self.env, **kwargs)

    def test_optional_profile_and_styles_loaded_once_per_human_invocation(self):
        self.assertIn("\x1b[38;5;123m--host", self.cli("--help", "--color=always").stdout)
        self.assertEqual(self.probes.read_text(), "probe\n")
        self.env["DOTS_ICONS"] = "always"
        (self.repo / "demo.XYZ").touch()
        output = self.cli("status", "--color=always").stdout
        self.assertIn("\x1b[38;5;165m? untracked (1)", output)
        self.assertIn("\x1b[38;5;177m", output)
        self.assertEqual(self.probes.read_text(), "probe\nprobe\n")
        self.prefs.write_text("__git.view\tverbose\tliteral\n__format.label_width\t14\tformatting\n"
                              "__format.indent\t3\tformatting\n")
        self.assertRegex(self.cli("status").stdout, r"(?m)^│ Root +/")

    def test_default_scalar_and_structured_routes_skip_dots(self):
        (self.repo / "example.xyz").touch()
        for args in (("-R",), ("-H",), ("--format", "{repo}"), ("--get", "root"),
                     ("--list-fields",), ("-i",), ("path",), ("--version",),
                     ("--completion", "bash"), ("status", "--json"), ("--json",)):
            with self.subTest(args=args):
                output = self.cli("--color=always", *args)
                self.assertNotIn("\x1b", output.stdout)
                self.assertFalse(self.probes.exists())
        for args in (("path", "-C", str(self.fixture.base)), ("--completion", "unknown")):
            with self.subTest(args=args):
                self.assertNotEqual(self.cli("--color=always", *args, ok=False).returncode, 0)
                self.assertFalse(self.probes.exists())

    def test_home_paths_in_human_info_and_status(self):
        home = self.fixture.repo("user home")
        child = self.fixture.sub(home, self.repo, "child")
        env = dict(self.env, HOME=str(home) + "/", COLUMNS="200")

        def child_cli(*args):
            return self.fixture.cli(child, *args, env=env).stdout

        info = child_cli("info", "-v")
        self.assertRegex(info, r"(?m)^│ Root +~/child +│$")
        self.assertRegex(info, r"(?m)^│ Parent +~ +│$")
        self.assertRegex(info, r"(?m)^│ Outermost +~ +│$")
        (child / "new file").touch()
        status = child_cli("status", "-v")
        self.assertRegex(status, r"(?m)^│ Root +~/child +│$")
        self.assertIn("\n└ new file\n", status)
        full = child_cli("status", "-v", "--full-paths")
        self.assertIn(str(child / "new file"), full)
        self.assertRegex(full, r"(?m)^│ Root +" + re.escape(str(child)) + r" +│$")
        self.assertEqual(child_cli("--get", "root"), str(child) + "\n")
        self.assertEqual(child_cli("--format", "{root}"), str(child) + "\n")
        self.assertEqual(child_cli("path"), str(child) + "\n")
        self.assertEqual(json.loads(child_cli("status", "--json"))["repositories"][0]["path"], str(child))

        sibling = self.fixture.repo("user home-more")
        self.assertIn(str(sibling), self.fixture.cli(sibling, "info", env=env).stdout)

    def test_missing_dots_and_invalid_published_style_fall_back(self):
        self.env["DOTS"] = str(self.fixture.base / "missing")
        self.assertIn("\x1b[33m--host", self.cli("--help", "--color=always").stdout)
        (self.repo / "demo.xyz").touch()
        (self.theme / 'git-styles.tsv').write_text(
            "dots-git-styles\t1\nuntracked\t42\nadded\t\x1b]8;example\n")
        output = self.cli("status", "--color=always").stdout
        self.assertNotIn("\x1b]8", output)
        self.assertNotIn("\x1b[42m", output)
        self.assertIn("\x1b[95m", output)
        self.assertFalse(self.probes.exists())

    def test_colored_tree_distinguishes_repository_guides_file_edges_and_names(self):
        self.env.update(DOTS_MENU_CAPTURE="1", DOTS_ICONS="never", COLUMNS="200")
        self.fixture.sub(self.repo, self.fixture.repo("module-source"), "module")
        folder = self.repo / "nested"
        folder.mkdir()
        mixed = folder / "mixed.xyz"
        mixed.write_text("committed\n")
        self.fixture.git(self.repo, "add", "nested/mixed.xyz")
        self.fixture.git(self.repo, "commit", "-m", "Track mixed-state file")
        mixed.write_text("staged\n")
        self.fixture.git(self.repo, "add", "nested/mixed.xyz")
        mixed.write_text("unstaged\n")
        for name in ("new-a.xyz", "new-b.xyz"):
            (folder / name).touch()

        rendered = self.cli("status", "--color=always").stdout
        rows = dict(styled_lines(rendered))
        # Compare the same terminal view with all SGR removed. Icons are off
        # throughout, so these box and tree glyphs belong to the layout.
        self.assertEqual(self.cli("status", "--no-color").stdout,
                         re.sub(r"\x1b\[[0-9;]*m", "", rendered))
        guide = "38;5;238"
        for corner in ("│┌", "│└"):
            edge, = (line for line in rows if line.startswith(corner))
            self.assertEqual(set(rows[edge]), {guide}, edge)
        detail, = (line for line in rows if line.startswith("││ Root "))
        self.assertEqual([rows[detail][i] for i in (0, 1, -1)], [guide] * 3)
        child, = (line for line in rows if line.startswith("└ module "))
        self.assertEqual(rows[child][0], guide)
        self.assertEqual(rows["│ untracked (2)"][0], guide)
        self.assertEqual(rows["│ staged modified + unstaged modified (1)"][-1], "1;48;5;236;38;5;166")

        for prefix, name, shade in (("│ └ ", "mixed.xyz", "38;5;166"),
                                    ("│ ├ ", "new-a.xyz", "38;5;165"),
                                    ("│ └ ", "new-b.xyz", "38;5;165")):
            row = prefix + "nested/" + name
            colors = rows[row]
            self.assertEqual((colors[0], colors[2]), (guide, shade), row)
            self.assertEqual(set(colors[len(prefix):-len(name)]), {"38;5;118"}, row)
            self.assertEqual(set(colors[-len(name):]), {"38;5;177"}, row)

        short = dict(styled_lines(self.cli("status", "--short", "--color=always").stdout))
        for row, shade in (("│ ├ [MM] nested/mixed.xyz", "38;5;166"),
                           ("│ ├ [??] nested/new-a.xyz", "38;5;165"),
                           ("│ └ [??] nested/new-b.xyz", "38;5;165")):
            self.assertEqual((short[row][0], short[row][2]), (guide, shade), row)
            self.assertEqual(short[row][-1], "38;5;177", row)

    def test_tree_fallback_without_dots(self):
        self.env.update(DOTS=str(self.fixture.base / "absent-dots"),
                        XDG_STATE_HOME=str(self.fixture.base / "empty-state"),
                        DOTS_MENU_CAPTURE="1", DOTS_ICONS="never")
        (self.repo / "new").touch()
        rows = dict(styled_lines(self.cli("status", "--color=always").stdout))
        colors = rows["└ new"]
        self.assertEqual(colors[0], "95")

    def test_status_wraps_with_sibling_guides_at_terminal_width(self):
        names = ["a" * 150 + ".xyz", "z" * 150 + ".xyz"]
        for name in names:
            (self.repo / name).touch()
        for width in (40, 80, 120):
            with self.subTest(width=width):
                self.env.update(DOTS_MENU_CAPTURE="1", DOTS_ICONS="never", COLUMNS=str(width))
                rows = styled_lines(self.cli("status", "--color=always").stdout)
                self.assertTrue(all(len(line) <= width for line, _ in rows))
                for name, edge, continuation in zip(names, ("├ ", "└ "), ("│ ", "  ")):
                    start = next(i for i, (line, _) in enumerate(rows) if line.startswith(edge + name[0]))
                    shown = rows[start][0][len(edge):]
                    self.assertLess(len(shown), len(name))
                    i = start
                    while len(shown) < len(name):
                        i += 1
                        line, colors = rows[i]
                        self.assertTrue(line.startswith(continuation), line)
                        if continuation.startswith("│"):
                            self.assertEqual(colors[0], "38;5;165", line)
                        shown += line[len(continuation):]
                    self.assertEqual(shown, name)

    def test_scoped_publish_uses_real_terminal_width_without_columns(self):
        _, bare, _ = self.fixture.remote_repo("seed")
        child = self.fixture.sub(self.repo, bare, "child")
        self.fixture.owned_remote(child, bare)
        (child / "staged").touch()
        self.fixture.git(child, "add", "staged")
        env = dict(self.env, DOTS_ICONS="never", NO_COLOR="1")
        env.pop("COLUMNS", None)
        for width in (40, 80, 120):
            with self.subTest(width=width):
                master, slave = pty.openpty()
                try:
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, width, 0, 0))
                    result = subprocess.run(
                        [str(fixtures.CLI), "--config", str(self.fixture.config), "-C", str(self.repo),
                         "submodule", "child", "publish", "--dry-run", "-m", "x" * 140],
                        stdout=slave, stdin=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, timeout=40)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    output = bytearray()
                    while select.select([master], [], [], 0)[0]:
                        output.extend(os.read(master, 4096))
                finally:
                    os.close(master)
                    os.close(slave)
                rows = output.decode().splitlines()
                self.assertEqual(rows[:3], ["", "presentation main", "Publish"])
                self.assertEqual(max(map(len, rows)), width)
                self.assertIn("  └ staged", rows)

    def test_operation_plans_wrap_inside_their_boxes(self):
        _, bare, repo = self.fixture.remote_repo("operation")
        self.fixture.owned_remote(repo, bare)
        (repo / "new").touch()
        self.fixture.git(repo, "add", "new")
        message = "x" * 55 + "雪\tend"
        for width in (40, 80, 120):
            self.env.update(DOTS_MENU_CAPTURE="1", DOTS_ICONS="never", COLUMNS=str(width))
            rows = self.fixture.cli(repo, "publish", "--dry-run", "-m", message, env=self.env).stdout.splitlines()
            self.assertEqual(rows[:2], ["", "Publish"])
            self.assertIn("Preview", rows)
            self.assertIn("  └ new", rows)
            fields = [r for r in rows if r.startswith("  │")]
            self.assertTrue(all(r.endswith("│") for r in fields))
            for key in ("Root", "Mode", "Preview", "Branch", "Push to", "Target", "Message", "Note"):
                self.assertTrue(any(r.startswith("  │ " + key + " ") for r in fields), key)
            start = next(i for i, row in enumerate(fields) if row.startswith("  │ Message "))
            value_rows = fields[start:]
            joined = value_rows[0][12:-2].strip()
            for r in value_rows[1:]:
                if not r.startswith("  │          "):
                    break
                joined += r[12:-2].strip()
            self.assertEqual(joined, message.replace("\t", r"\x09"))
            self.assertTrue(all(sum(2 if c == "雪" else 1 for c in r) <= width for r in rows))

    def test_terminal_progress_modes_and_streams(self):
        # Give the renderer separate ttys, so its stderr and the permanent
        # stdout report can be checked independently.
        script = ('source "$1/lib/core.bash"; source "$1/lib/progress.bash"; '
                  'JSON=0; COLOR=auto; colors; '
                  'progress_start "Reading repositories" 1 4; sleep 0.55; '
                  'progress_stop; printf "Finished\\n"')
        self.env.update(COLUMNS="40", NO_COLOR="1")
        for mode in ("both", "bar", "spinner", "none"):
            with self.subTest(mode=mode):
                # setup supplies a real slave TTY, without any controlling terminal.
                out, stdout = pty.openpty()
                err, stderr = pty.openpty()
                try:
                    result = subprocess.run(["bash", "-uc", script, "bash", str(fixtures.PROJECT)],
                                            env=dict(self.env, DOTS_PROGRESS=mode),
                                            stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, timeout=8)
                    self.assertEqual(result.returncode, 0)
                    # Keep slaves open and read only bytes known to be available.
                    def receive(fd):
                        data = b""
                        while select.select([fd], [], [], 0)[0]:
                            data += os.read(fd, 8192)
                        return data.decode("utf-8")
                    stdout_text, stderr_text = receive(out), receive(err)
                    self.assertEqual(stdout_text.strip(), "Finished")
                    if mode == "none":
                        self.assertEqual(stderr_text, "")
                    else:
                        self.assertIn("25%", stderr_text)
                        self.assertIn("1/4", stderr_text)
                        self.assertEqual("[" in stderr_text, mode != "spinner")
                        self.assertEqual(bool(re.search("[⠋⠙⠹⠸]", stderr_text)), mode != "bar")
                        self.assertNotIn("\x1b", stderr_text)
                        self.assertTrue(stderr_text.endswith("\r"))
                finally:
                    for fd in (out, stdout, err, stderr):
                        os.close(fd)
