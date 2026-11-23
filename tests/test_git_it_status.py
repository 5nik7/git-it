"""Read-only recursive status in isolated repositories with cached tracking refs."""
import json
import os
import pty
import subprocess
import unittest
import unicodedata

import test_git_it as fixtures


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GitItTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.git = self.fixture.git
        self.cli = self.fixture.cli
        self.fixture.env.update(DOTS=str(self.fixture.base / "dots"), DOTS_ICONS="never",
                                DOTS_PROGRESS="never", DOTS_MENU_CAPTURE="0")

    def test_cached_tracking_exact_paths_and_no_mutation(self):
        source, bare, root = self.fixture.remote_repo("root")
        self.fixture.advance(source, bare)
        self.git(root, "fetch", "origin")
        (root / "local").write_text("ahead\n")
        self.git(root, "add", "local")
        self.git(root, "commit", "-m", "local")
        old = 'file'
        new = 'renamed with\tλ'
        self.git(root, "mv", old, new)
        loose = 'unknown\n\x1b[32m$(false)'
        (root / loose).touch()
        self.git(root, "remote", "set-url", "origin", "https://user:SECRET@example.invalid/group/repo.git?token=PRIVATE")
        ref_bytes = self.git(root, "show-ref")
        index = (root / ".git/index").read_bytes()
        result = self.cli(root, "-s", "--color", "always", "--json")
        self.assertEqual(result.stderr, '')
        report = json.loads(result.stdout)
        self.assertEqual(set(report), {"schema", "remote_state", "repositories", "complete"})
        self.assertEqual((report["schema"], report["remote_state"], report["complete"]), (1, "cached", True))
        self.assertEqual(report["repositories"], [
            dict(path=str(root), branch="main", status="modified", ahead=1, behind=1, files=[
                dict(path=new, xy="R ", old_path=old), dict(path=loose, xy="??", old_path="")])])
        self.assertEqual(self.cli(root, "status", "--json").stdout, result.stdout)
        self.assertEqual((root / ".git/index").read_bytes(), index)
        self.assertEqual(self.git(root, "show-ref"), ref_bytes)
        verbose = self.cli(root, "status", "--view", "verbose", "--no-color").stdout
        self.assertIn("[R ] staged renamed (1)", verbose)
        self.assertIn(r"file → renamed with\x09λ", verbose)
        self.assertIn(r"unknown\x0a\x1b", verbose)
        self.assertIn("refs/remotes/origin/main", verbose)
        self.assertIn("https://example.invalid/group/repo.git", verbose)
        self.assertNotIn("SECRET", verbose)
        self.assertNotIn("PRIVATE", verbose)

    def test_dirty_submodules_include_clean_child_at_a_different_gitlink(self):
        parent = self.fixture.repo("parent")
        child = self.fixture.sub(parent, self.fixture.repo("child-source"), "nested/child")
        flags = ("submodules", "status", "--dirty")
        self.assertEqual(json.loads(self.cli(parent, *flags, "--json").stdout)["repositories"], [])

        (child / "file").write_text("new revision\n")
        self.git(child, "commit", "-am", "move child away from parent gitlink")
        report = json.loads(self.cli(parent, *flags, "--json").stdout)
        self.assertEqual([(row["path"], row["status"]) for row in report["repositories"]], [(str(child), "clean")])
        self.assertTrue(report["complete"])
        report = self.cli(parent, *flags, "--view", "default").stdout
        self.assertIn("differs from parent index", report)
        self.assertIn("child", report)

        self.git(parent, "add", "nested/child")
        self.assertEqual(json.loads(self.cli(parent, *flags, "--json").stdout)["repositories"], [])

    def test_registered_children_detached_missing_and_outermost(self):
        source = self.fixture.repo("source")
        root = self.fixture.repo("super")
        child = self.fixture.sub(root, source, "modules/one")
        missing = self.fixture.sub(root, source, "modules/two")
        self.git(child, "checkout", "--detach")
        self.git(root, "submodule", "deinit", "-f", "--", "modules/two")
        unrelated = self.fixture.repo("super/unrelated")
        (child / "file").write_text("child change")
        (unrelated / "unlisted").touch()
        report = self.cli(child, "--outermost", "status", "--json", ok=False)
        self.assertEqual(report.returncode, 1, report.stderr)
        rows = json.loads(report.stdout)
        self.assertFalse(rows['complete'])
        self.assertEqual([row["path"] for row in rows["repositories"]], list(map(str, (root, child, missing))))
        self.assertEqual([row["status"] for row in rows["repositories"]], ["modified", "modified", "missing"])
        detached = rows["repositories"][1]
        self.assertTrue(detached["branch"].startswith("detached "))
        self.assertIsNone(detached["ahead"])
        self.assertEqual(detached["files"], [dict(path="file", xy=" M", old_path="")])
        self.assertFalse((missing / ".git").exists())
        self.assertEqual(len(json.loads(self.cli(child, "-s", "--json").stdout)["repositories"]), 1)

    def test_ordinary_conflicts_and_view_groups(self):
        repo = self.fixture.repo("conflicts")
        self.git(repo, "switch", "-c", "other")
        (repo / "file").write_text("other\n")
        self.git(repo, "commit", "-am", "other")
        self.git(repo, "switch", "main")
        (repo / "file").write_text("main\n")
        self.git(repo, "commit", "-am", "main")
        self.git(repo, "merge", "other", ok=False)
        (repo / "a").touch()
        (repo / "z").touch()
        report = json.loads(self.cli(repo, "status", "--json").stdout)
        self.assertTrue(report["complete"])
        self.assertEqual(report["repositories"][0]["status"], "conflict")
        grouped = self.cli(repo, "status", "--view", "default", "--no-color").stdout
        self.assertRegex(grouped, r'(?m)^\| conflict: both modified \(1\)$')
        self.assertRegex(grouped, r'(?m)^\| untracked \(2\)\n\| \| a\n\| ` z$')
        short = self.cli(repo, "-s", "--short", "--no-color").stdout
        self.assertIn("States  [UU] (1) / [??] (2)", short)
        self.assertIn("[UU] file", short)
        full = self.cli(repo, "status", "--full-paths", "--no-color").stdout
        self.assertIn(str(repo / "file"), full)

    def test_blocked_submodule_keeps_healthy_sibling_and_special_metadata_is_safe(self):
        source = self.fixture.repo("source")
        root = self.fixture.repo("super")
        bad = self.fixture.sub(root, source, "bad")
        good = self.fixture.sub(root, source, "good")
        (bad / ".git").unlink()
        os.mkfifo(bad / ".git")
        result = self.cli(root, "-s", "--json", ok=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        rows = json.loads(result.stdout)
        self.assertFalse(rows["complete"])
        self.assertEqual([row["path"] for row in rows["repositories"]], list(map(str, (root, bad, good))))
        self.assertEqual([row["status"] for row in rows["repositories"][1:]], ["blocked", "clean"])
        (bad / ".git").unlink()
        self.git(root, "config", "--file", ".gitmodules", "--add", "submodule.bad.path", "bad")
        result = self.cli(root, "-s", "--json", ok=False)
        rows = json.loads(result.stdout)["repositories"]
        self.assertEqual([row["status"] for row in rows[1:]], ["blocked", "clean"])
        # A second submodule name can also make an indexed path ambiguous.
        self.git(root, "config", "--file", ".gitmodules", "submodule.second.path", "good")
        result = self.cli(root, "-s", "--json", ok=False)
        rows = json.loads(result.stdout)["repositories"]
        self.assertEqual(rows[-1]["status"], "blocked")

    def test_unborn_branch_and_unresolved_gitlink(self):
        unborn = self.fixture.base / "unborn"
        unborn.mkdir()
        self.git(unborn, "init", "-b", "new")
        row = json.loads(self.cli(unborn, "-s", "--json").stdout)["repositories"][0]
        self.assertEqual(row, dict(path=str(unborn), branch="new", status="clean", ahead=None, behind=None, files=[]))
        root = self.fixture.repo("root")
        child = self.fixture.sub(root, self.fixture.repo("source"), "child")
        oid = self.git(child, "rev-parse", "HEAD")
        self.git(root, "update-index", "--force-remove", "--", "child")
        self.fixture.run_cmd(["git", "-C", str(root), "update-index", "--index-info"],
                             input=f"160000 {oid} 2\tchild\n160000 {oid} 3\tchild\n")
        result = self.cli(root, "status", "--json", ok=False)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertFalse(report["complete"])
        self.assertEqual([row["path"] for row in report["repositories"]], [str(root), str(child)])
        self.assertEqual(report["repositories"][1]["status"], "blocked")

    def test_terminal_widths_and_explicit_view_over_profile(self):
        repo = self.fixture.repo("terminal")
        (repo / ("雪" * 32 + ".txt")).touch()
        profile = self.fixture.base / "dots/lib/dots/profile_config.py"
        profile.parent.mkdir(parents=True)
        profile.write_text("print('__git.view\\tshort\\tfixture')\n")
        for width in (40, 80, 120):
            for options in ([], ["--view", "default"]):
                with self.subTest(width=width, options=options):
                    master, slave = pty.openpty()
                    try:
                        env = dict(self.fixture.env, TERM="xterm-256color", COLUMNS=str(width))
                        proc = subprocess.run(["bash", str(fixtures.CLI), "status", "-C", str(repo),
                                               "--no-color", *options], env=env, stdin=subprocess.DEVNULL,
                                              stdout=slave, stderr=subprocess.PIPE, timeout=15)
                        self.assertEqual((proc.returncode, proc.stderr), (0, b''))
                        os.close(slave)
                        slave = -1
                        data = bytearray()
                        while True:
                            try: chunk = os.read(master, 4096)
                            except OSError: break  # PTY EOF on Linux/Termux
                            if not chunk: break
                            data.extend(chunk)
                    finally:
                        os.close(master)
                        if slave >= 0: os.close(slave)
                    text = data.decode()
                    self.assertNotIn('\x1b', text)
                    self.assertIn('untracked (1)' if options else 'States  [??] (1)', text)
                    self.assertEqual(text.count('雪'), 32)
                    for line in text.splitlines():
                        cells = sum(2 if unicodedata.east_asian_width(ch) in ('F', 'W') else 1 for ch in line)
                        self.assertLessEqual(cells, width, line)


if __name__ == "__main__":
    unittest.main()
