"""Standalone presentation and lazy Dots integration, with test-owned inputs."""
import json
import os
import pty
import re
import select
import subprocess
import unittest

import test_git_it as fixtures


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
                              "__cli.progress\tboth\tliteral\n"
                              "__format.label_width\t14\tformatting\n"
                              "__format.indent\t3\tformatting\n"
                              "__icon.git.status.untracked\t?\tstyle\n")
        (self.theme / "git-styles.tsv").write_text("dots-git-styles\t1\nuntracked\t38;5;165\n")
        (self.theme / "file-styles.tsv").write_text(
            "dots-file-styles\t1\ntype\tfile\t39\t-\nsuffix\t.xyz\t38;5;177\tfold\n")

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
        self.assertRegex(self.cli("status").stdout, r"(?m)^   Path {11}/")

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
        env = dict(self.env, HOME=str(home) + "/")

        def child_cli(*args):
            return self.fixture.cli(child, *args, env=env).stdout

        info = child_cli("info", "-v")
        self.assertRegex(info, r"(?m)^  Root +~/child$")
        self.assertRegex(info, r"(?m)^  Parent +~$")
        self.assertRegex(info, r"(?m)^  Outermost +~$")
        self.assertIn("\n    ~\n    ~/child\n", info)
        self.assertNotIn(str(home), info.split("Verified ancestry", 1)[1])
        (child / "new file").touch()
        status = child_cli("status", "-v")
        self.assertRegex(status, r"(?m)^  Path +~/child$")
        self.assertIn("\n      new file\n", status)
        full = child_cli("status", "-v", "--full-paths")
        self.assertIn(str(child / "new file"), full)
        self.assertRegex(full, r"(?m)^  Path +" + re.escape(str(child)) + "$")
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

    def test_status_wraps_at_terminal_width(self):
        (self.repo / ("abcde" * 30 + ".xyz")).touch()
        for width in (40, 80, 120):
            with self.subTest(width=width):
                self.env.update(DOTS_MENU_CAPTURE="1", DOTS_ICONS="never", COLUMNS=str(width))
                rendered = self.cli("status", "--no-color").stdout
                self.assertTrue(all(len(line) <= width for line in rendered.splitlines()))
                self.assertIn("abcde" * 30 + ".xyz", "".join(row.strip() for row in rendered.splitlines()))

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
