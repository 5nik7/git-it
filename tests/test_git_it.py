"""Black-box tests: all Git mutations use test-owned directories and remotes."""
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

PROJECT = Path(__file__).resolve().parents[1]
CLI = PROJECT / "git-it"


class GitItTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="git-it-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith("GIT_"):
                self.env.pop(key)
        self.env.update(
            HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / ".config"),
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Git It Test", GIT_COMMITTER_NAME="Git It Test",
            GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_EMAIL="test@example.invalid",
            GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="3",
            GIT_CONFIG_KEY_0="protocol.file.allow", GIT_CONFIG_VALUE_0="always",
            GIT_CONFIG_KEY_1="commit.gpgSign", GIT_CONFIG_VALUE_1="false",
            GIT_CONFIG_KEY_2="core.hooksPath", GIT_CONFIG_VALUE_2=os.devnull,
        )
        self.config = self.base / "config"
        self.config.write_text('[git-it]\nowner = github.com/5nik7\n')

    def run_cmd(self, args, cwd=None, ok=True, env=None, **kwargs):
        result = subprocess.run(args, cwd=cwd or self.base, env=env or self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=40, **kwargs)
        if ok:
            self.assertEqual(result.returncode, 0, f"{args}\n{result.stdout}\n{result.stderr}")
        return result

    def git(self, repo, *args, ok=True):
        return self.run_cmd(["git", "-C", str(repo), *args], ok=ok).stdout.rstrip("\n")

    def cli(self, repo, *args, ok=True, env=None):
        return self.run_cmd(["bash", str(CLI), "--config", str(self.config), "-C", str(repo), *args], ok=ok, env=env)

    def repo(self, name):
        repo = self.base / name
        repo.mkdir(parents=True)
        self.git(repo, "init", "-b", "main")
        (repo / "file").write_text("initial\n")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-m", "initial")
        return repo

    def remote_repo(self, name):
        source = self.repo(name + "-source")
        bare = self.base / (name + ".git")
        self.run_cmd(["git", "clone", "--bare", str(source), str(bare)])
        clone = self.base / name
        self.run_cmd(["git", "clone", str(bare), str(clone)])
        return source, bare, clone

    def advance(self, source, bare, content="updated\n"):
        (source / "file").write_text(content)
        self.git(source, "add", "file")
        self.git(source, "commit", "-m", "advance")
        self.git(source, "push", str(bare), "main")
        return self.git(source, "rev-parse", "HEAD")

    def sub(self, parent, source, path):
        self.git(parent, "submodule", "add", "--", str(source), path)
        self.git(parent, "commit", "-am", "add submodule")
        return parent / path

    def owned_remote(self, repo, bare):
        # A test-only SSH transport runs upload/receive-pack against local bare
        # repositories. No GitHub access or URL-rewrite ownership bypass.
        ssh = self.base / "ssh-test"
        ssh.write_text("#!" + shutil.which("bash") + "\n"
                       "[[ $1 != -G ]] || exit 1\n"
                       "exec bash -c \"${!#}\"\n")
        ssh.chmod(0o700)
        self.env["GIT_SSH_COMMAND"] = str(ssh)
        self.env["GIT_SSH_VARIANT"] = "ssh"
        url = "ssh://git@example.invalid" + str(bare)
        namespace = str(bare.parent).lstrip("/")
        self.config.write_text(f'[git-it]\nowner = example.invalid/{namespace}\n')
        self.git(repo, "remote", "set-url", "origin", url)

    def test_help_version_completions_without_repository(self):
        self.assertIn("0.1.0", self.cli(self.base, "--version").stdout)
        self.assertIn("Usage:", self.cli(self.base, "--help").stdout)
        for shell in ("bash", "zsh", "fish"):
            result = self.cli(self.base, "--completion", shell)
            self.assertIn("git-it", result.stdout)
            if shutil.which(shell):
                self.run_cmd([shell, "-n"], input=result.stdout)

    def test_icon_outside_repo_is_empty(self):
        self.assertEqual(self.cli(self.base, "-i").stdout, "")
        self.assertEqual(self.cli(self.base, "path", "--format", "{current}").stdout, "")
        self.assertEqual(self.cli(self.base, "info", ok=False).returncode, 3)

    def test_remote_metadata_and_credentials(self):
        repo = self.repo("inspect")
        self.git(repo, "remote", "add", "origin", "https://user:SECRET@github.com/5nik7/repo.git?token=PRIVATE")
        data = json.loads(self.cli(repo, "--json").stdout)
        self.assertTrue(data["owned"])
        self.assertEqual(data["repo"], "repo")
        self.assertEqual(data["icon"], "󰊤")
        self.assertNotIn("SECRET", data["url"])
        self.assertNotIn("PRIVATE", data["url"])
        self.git(repo, "remote", "set-url", "origin", "git@github.com:someone/other.git")
        self.assertEqual(self.cli(repo, "-i", "--no-newline").stdout, "󰊤")
        self.assertEqual(self.cli(repo, "--get", "owned").stdout, "false\n")

    def test_exact_host_and_alias_nested_namespace(self):
        repo = self.repo("alias")
        self.git(repo, "remote", "add", "origin", "ssh://git@github.com.evil.invalid/a/b.git")
        self.assertEqual(self.cli(repo, "-i").stdout.strip(), "")
        self.git(repo, "remote", "set-url", "origin", "git@work:a/group/repo.git")
        self.config.write_text('[git-it]\nhostAlias = work=gitlab.com\nowner = gitlab.com/a/group\n')
        data = json.loads(self.cli(repo, "--json").stdout)
        self.assertEqual(data["owner"], "a/group")
        self.assertEqual(data["icon"], "")
        self.assertTrue(data["owned"])

    def test_no_remote_and_missing_explicit_remote(self):
        repo = self.repo("local")
        self.assertEqual(self.cli(repo, "-i").stdout.strip(), "")
        self.assertEqual(self.cli(repo, "--remote", "missing", ok=False).returncode, 3)

    def test_config_is_data_and_invalid_options(self):
        repo = self.repo("configtest")
        self.config.write_text('touch SHOULD_NOT_EXIST\n')
        self.assertEqual(self.cli(repo, "--json", ok=False).returncode, 2)
        self.assertFalse((self.base / "SHOULD_NOT_EXIST").exists())
        self.assertEqual(self.cli(repo, "--no-config", "--get", "root").stdout.strip(), str(repo))
        for args in (("--get",), ("--json", "-i"), ("--all",), ("sync", "--yes"), ("--wat",)):
            self.assertEqual(self.cli(repo, *args, ok=False).returncode, 2)

    def test_verified_three_level_paths_and_special_names(self):
        leaf = self.repo("leaf")
        mid = self.repo("middle")
        self.sub(mid, leaf, "deep space")
        outer = self.repo("outer")
        child = self.sub(outer, mid, "mods/middle")
        self.git(outer, "submodule", "update", "--init", "--recursive")
        cwd = child / "deep space" / "dir\twith\nline-λ-$(false)"
        cwd.mkdir()
        data = json.loads(self.cli(cwd, "path", "--json").stdout)
        self.assertEqual(data["chain_length"], 3)
        self.assertEqual(data["path_outermost"], "mods/middle/deep space")
        self.assertEqual(data["path_parent"], "deep space")
        self.assertEqual(data["cwd_prefix"], cwd.name)
        self.assertEqual(data["chain_paths"], ["mods/middle", "deep space"])
        formatted = self.cli(cwd, "path", "--format", "{{{parent_basename}}}/{path_outermost}/{cwd_prefix}").stdout
        self.assertIn("{outer}/mods/middle/deep space", formatted)
        self.assertIn(r"\x0a", formatted)
        self.assertEqual(self.cli(cwd, "path", "--format", "{unknown}", ok=False).returncode, 2)

    def test_unrelated_parent_does_not_destroy_valid_chain(self):
        enclosing = self.repo("enclosing")
        independent = self.repo("enclosing/independent")
        leaf = self.repo("leaf")
        child = self.sub(independent, leaf, "child")
        data = json.loads(self.cli(child, "path", "--json").stdout)
        self.assertEqual(data["chain_repos"], [str(independent), str(child)])
        self.assertNotIn(str(enclosing), data["chain_repos"])

    def test_worktree_and_symlink_input(self):
        repo = self.repo("worktrees")
        linked = self.base / "linked"
        self.git(repo, "worktree", "add", "-b", "other", str(linked))
        alias = self.base / "symlink"
        alias.symlink_to(linked, target_is_directory=True)
        self.assertEqual(self.cli(alias, "--get", "root").stdout.strip(), str(linked))

    def test_root_filename_controls_and_format_injection_are_data(self):
        repo = self.repo('odd\n"\\λ-$(touch OWNED)')
        data = json.loads(self.cli(repo, "path", "--json").stdout)
        self.assertEqual(data["root"], str(repo))
        self.assertEqual(data["chain_repos"], [str(repo)])
        self.assertEqual(self.cli(repo, "--get", '$(touch OWNED)', ok=False).returncode, 2)
        self.assertFalse((self.base / "OWNED").exists())

    def test_sync_uninitialized_literal_special_path(self):
        _, child_bare, _ = self.remote_repo("special-child")
        source, bare, top = self.remote_repo("special-top")
        path = 'mods/-literal[1] space\tline\nend'
        self.git(source, "submodule", "add", "--name", "special", "--", str(child_bare), path)
        self.git(source, "commit", "-am", "add specially named path")
        self.git(source, "push", str(bare), "main")
        self.cli(top, "sync")
        self.assertTrue((top / path / "file").is_file())
        data = json.loads(self.cli(top / path, "path", "--json").stdout)
        self.assertEqual(data["path_parent"], path)

    def test_sync_fast_forward_and_dry_run(self):
        source, bare, repo = self.remote_repo("sync")
        before = self.git(repo, "rev-parse", "HEAD")
        after = self.advance(source, bare)
        refs = self.git(repo, "show-ref")
        preview = json.loads(self.cli(repo, "sync", "--dry-run", "--json").stdout)
        self.assertTrue(preview["dry_run"])
        self.assertEqual(self.git(repo, "show-ref"), refs)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)
        self.cli(repo, "sync")
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), after)

    def test_sync_local_changes_preserved(self):
        source, bare, repo = self.remote_repo("dirty")
        self.advance(source, bare)
        (repo / "file").write_text("local edit\n")
        before = self.git(repo, "rev-parse", "HEAD")
        result = self.cli(repo, "sync", ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual((repo / "file").read_text(), "local edit\n")
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)
        self.assertFalse((repo / ".git/git-it.lock").exists())

    def test_sync_ahead_retained_and_divergence_refused(self):
        source, bare, repo = self.remote_repo("diverged")
        (repo / "local").write_text("local\n")
        self.git(repo, "add", "local"); self.git(repo, "commit", "-m", "local")
        head = self.git(repo, "rev-parse", "HEAD")
        self.cli(repo, "sync")
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), head)
        self.advance(source, bare)
        self.assertEqual(self.cli(repo, "sync", ok=False).returncode, 1)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), head)

    def test_sync_missing_upstream_detached_and_lock(self):
        repo = self.repo("no-upstream")
        self.assertEqual(self.cli(repo, "sync", ok=False).returncode, 1)
        self.git(repo, "checkout", "--detach")
        self.assertEqual(self.cli(repo, "sync", ok=False).returncode, 1)
        (repo / ".git/git-it.lock").mkdir()
        self.assertEqual(self.cli(repo, "sync", ok=False).returncode, 1)
        self.assertTrue((repo / ".git/git-it.lock").is_dir())

    def make_sync_tree(self):
        leaf_source, leaf_bare, _ = self.remote_repo("leaf")
        mid_source, mid_bare, _ = self.remote_repo("mid")
        self.sub(mid_source, leaf_bare, "leaf")
        self.git(mid_source, "push", str(mid_bare), "main")
        top_source, top_bare, top = self.remote_repo("top")
        self.sub(top_source, mid_bare, "middle")
        self.sub(top_source, leaf_bare, "sibling")
        self.git(top_source, "push", str(top_bare), "main")
        return top_source, top_bare, top, mid_source, mid_bare, leaf_source, leaf_bare

    def test_sync_initializes_three_levels_and_keeps_pins(self):
        _, _, top, _, _, leaf_source, leaf_bare = self.make_sync_tree()
        self.cli(top, "sync")
        nested = top / "middle/leaf"
        before = self.git(nested, "rev-parse", "HEAD")
        self.advance(leaf_source, leaf_bare)
        self.cli(top, "sync")
        self.assertEqual(self.git(nested, "rev-parse", "HEAD"), before)
        self.assertEqual(self.git(top, "status", "--porcelain"), "")

    def test_sync_remote_updates_and_continues_safe_sibling(self):
        _, _, top, _, _, leaf_source, leaf_bare = self.make_sync_tree()
        self.cli(top, "sync")
        self.git(top, "config", "submodule.middle.branch", "main")
        self.git(top, "config", "submodule.sibling.branch", "main")
        (top / "middle/file").write_text("local edit\n")
        new = self.advance(leaf_source, leaf_bare)
        result = self.cli(top, "sync", "--remote", "--json", ok=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.git(top / "sibling", "rev-parse", "HEAD"), new)
        self.assertEqual((top / "middle/file").read_text(), "local edit\n")
        self.assertEqual(self.git(top, "diff", "--cached", "--name-only"), "")

    def test_sync_outermost_is_explicit(self):
        _, _, top, _, _, _, _ = self.make_sync_tree()
        self.cli(top, "sync")
        # A pinned detached child is an invalid root by itself.
        self.assertEqual(self.cli(top / "middle", "sync", ok=False).returncode, 1)
        self.cli(top / "middle", "sync", "--outermost")

    def test_publish_staged_only_and_existing_commits(self):
        _, bare, repo = self.remote_repo("publish")
        self.owned_remote(repo, bare)
        (repo / "staged").write_text("selected\n")
        (repo / "untracked").write_text("leave me\n")
        self.git(repo, "add", "staged")
        preview = self.cli(repo, "publish", "--dry-run")
        self.assertIn("selected", preview.stdout)
        self.assertNotIn("?? untracked", preview.stdout)
        self.cli(repo, "publish", "--yes", "-m", "selected commit")
        self.assertEqual(self.git(repo, "log", "-1", "--format=%s"), "selected commit")
        self.assertEqual(self.git(bare, "rev-parse", "main"), self.git(repo, "rev-parse", "HEAD"))
        self.assertEqual(self.git(repo, "status", "--porcelain"), "?? untracked")
        self.git(repo, "add", "untracked"); self.git(repo, "commit", "-m", "already committed")
        self.cli(repo, "publish", "--yes")
        self.assertEqual(self.git(bare, "rev-parse", "main"), self.git(repo, "rev-parse", "HEAD"))

    def test_publish_all_and_ownership_block(self):
        _, bare, repo = self.remote_repo("all")
        self.owned_remote(repo, bare)
        (repo / "new file").write_text("new\n")
        before = self.git(repo, "rev-parse", "HEAD")
        self.config.write_text('[git-it]\nowner = other.invalid/other\n')
        self.assertEqual(self.cli(repo, "publish", "--all", "--yes", ok=False).returncode, 1)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)
        self.owned_remote(repo, bare)
        self.cli(repo, "publish", "--all", "--yes")
        self.assertEqual(self.git(repo, "status", "--porcelain"), "")

    def test_publish_requires_confirmation_and_no_dry_run_writes(self):
        _, bare, repo = self.remote_repo("confirm")
        self.owned_remote(repo, bare)
        (repo / "new").write_text("new\n"); self.git(repo, "add", "new")
        before = self.git(repo, "show-ref")
        index = (repo / ".git/index").read_bytes()
        self.cli(repo, "publish", "--dry-run")
        self.assertEqual((repo / ".git/index").read_bytes(), index)
        self.assertEqual(self.git(repo, "show-ref"), before)
        self.assertEqual(self.cli(repo, "publish", ok=False).returncode, 2)

    def test_publish_json_confirmation_shows_preview_and_cancel_preserves(self):
        _, bare, repo = self.remote_repo("cancel")
        self.owned_remote(repo, bare)
        (repo / "selected-file").write_text("selected\n"); self.git(repo, "add", "selected-file")
        before = self.git(repo, "rev-parse", "HEAD")
        master, slave = pty.openpty()
        try:
            proc = subprocess.Popen(["bash", str(CLI), "--config", str(self.config), "-C", str(repo),
                                     "publish", "--json"], env=self.env, stdin=slave,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.addCleanup(lambda: proc.poll() is not None or proc.kill())
            preview = b""
            deadline = time.monotonic() + 20
            while b"[y/N]" not in preview and time.monotonic() < deadline:
                if select.select([proc.stderr], [], [], 0.1)[0]:
                    chunk = os.read(proc.stderr.fileno(), 4096)
                    if not chunk:
                        break
                    preview += chunk
            self.assertIn(b"selected-file", preview)
            self.assertIn(b"[y/N]", preview)
            os.write(master, b"n\n")
            stdout, stderr = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, preview + stderr)
            self.assertTrue(any(e["status"] == "cancelled" for e in json.loads(stdout)["events"]))
            self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)
            self.assertFalse((repo / ".git/git-it.lock").exists())
        finally:
            os.close(master); os.close(slave)

    def test_sync_interruption_releases_owned_lock(self):
        _, _, repo = self.remote_repo("interrupt")
        wrappers = self.base / "wrappers"; wrappers.mkdir()
        marker = self.base / "fetch-started"
        script = wrappers / "git"
        script.write_text("#!" + shutil.which("bash") + "\n"
                          'for arg in "$@"; do\n'
                          '  if [[ $arg == fetch ]]; then : > "$TEST_MARKER"; sleep 30; exit 1; fi\n'
                          'done\nexec "$REAL_GIT" "$@"\n')
        script.chmod(0o700)
        env = self.env.copy()
        env.update(PATH=str(wrappers) + os.pathsep + env["PATH"],
                   TEST_MARKER=str(marker), REAL_GIT=shutil.which("git"))
        before = self.git(repo, "rev-parse", "HEAD")
        proc = subprocess.Popen(["bash", str(CLI), "--no-config", "-C", str(repo), "sync"],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists())
            os.killpg(proc.pid, signal.SIGTERM)
            proc.communicate(timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse((repo / ".git/git-it.lock").exists())
            self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL); proc.communicate()

    def test_publish_push_failure_retains_commit(self):
        _, bare, repo = self.remote_repo("reject")
        self.owned_remote(repo, bare)
        # Receive-pack hook policy is test-owned and configured only on this bare.
        hookdir = self.base / "hooks"; hookdir.mkdir()
        hook = hookdir / "pre-receive"
        hook.write_text("#!" + shutil.which("bash") + "\nexit 1\n"); hook.chmod(0o700)
        # Env core.hooksPath would override repo config, so replace it for this test.
        self.env["GIT_CONFIG_VALUE_2"] = str(hookdir)
        self.git(bare, "config", "core.hooksPath", str(hookdir))
        before = self.git(bare, "rev-parse", "main")
        (repo / "new").write_text("new\n"); self.git(repo, "add", "new")
        self.assertEqual(self.cli(repo, "publish", "--yes", ok=False).returncode, 1)
        self.assertNotEqual(self.git(repo, "rev-parse", "HEAD"), before)
        self.assertEqual(self.git(bare, "rev-parse", "main"), before)

    def publish_tree(self):
        leaf_source, leaf_bare, _ = self.remote_repo("pub-leaf")
        mid_source, mid_bare, _ = self.remote_repo("pub-mid")
        self.sub(mid_source, leaf_bare, "leaf")
        self.git(mid_source, "push", str(mid_bare), "main")
        top_source, top_bare, top = self.remote_repo("pub-top")
        self.sub(top_source, mid_bare, "middle")
        self.git(top_source, "push", str(top_bare), "main")
        self.cli(top, "sync")
        mid, leaf = top / "middle", top / "middle/leaf"
        for repo, bare in ((top, top_bare), (mid, mid_bare), (leaf, leaf_bare)):
            self.git(repo, "checkout", "main")
            self.owned_remote(repo, bare)
        return top, mid, leaf, top_bare, mid_bare, leaf_bare

    def test_publish_three_levels_child_before_parent(self):
        top, mid, leaf, top_bare, mid_bare, leaf_bare = self.publish_tree()
        (leaf / "change").write_text("leaf change\n"); self.git(leaf, "add", "change")
        result = self.cli(top, "publish", "--yes", "--json", "-m", "recursive")
        events = json.loads(result.stdout)["events"]
        self.assertEqual([e["path"] for e in events if e["status"] == "published"],
                         [str(leaf), str(mid), str(top)])
        for repo, bare in ((top, top_bare), (mid, mid_bare), (leaf, leaf_bare)):
            self.assertEqual(self.git(repo, "rev-parse", "HEAD"), self.git(bare, "rev-parse", "main"))
        self.assertEqual(self.git(top, "status", "--porcelain"), "")

    def test_publish_detached_changed_child_blocks_ancestors(self):
        top, _, leaf, top_bare, _, _ = self.publish_tree()
        self.git(leaf, "checkout", "--detach")
        (leaf / "change").write_text("leaf change\n"); self.git(leaf, "add", "change")
        before = self.git(top_bare, "rev-parse", "main")
        result = self.cli(top, "publish", "--yes", "--json", ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["complete"])
        self.assertEqual(self.git(top_bare, "rev-parse", "main"), before)

    def test_publish_rejected_child_allows_independent_sibling(self):
        top, mid, leaf, top_bare, mid_bare, leaf_bare = self.publish_tree()
        _, sibling_bare, _ = self.remote_repo("pub-sibling")
        sibling = self.sub(top, sibling_bare, "sibling")
        self.git(top, "push", str(top_bare), "main")
        self.owned_remote(sibling, sibling_bare)
        hookdir = self.base / "reject-leaf-hooks"; hookdir.mkdir()
        hook = hookdir / "pre-receive"
        hook.write_text("#!" + shutil.which("bash") + "\nexit 1\n"); hook.chmod(0o700)
        self.git(leaf_bare, "config", "core.hooksPath", str(hookdir))
        before_top = self.git(top_bare, "rev-parse", "main")
        before_mid = self.git(mid_bare, "rev-parse", "main")
        before_sibling = self.git(sibling_bare, "rev-parse", "main")
        for repo in (leaf, sibling):
            (repo / "change").write_text("selected\n"); self.git(repo, "add", "change")
        result = self.cli(top, "publish", "--yes", "--json", ok=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.git(top_bare, "rev-parse", "main"), before_top)
        self.assertEqual(self.git(mid_bare, "rev-parse", "main"), before_mid)
        self.assertNotEqual(self.git(sibling_bare, "rev-parse", "main"), before_sibling)
        events = json.loads(result.stdout)["events"]
        self.assertTrue(any(e["path"] == str(sibling) and e["status"] == "published" for e in events))

    def test_publish_preserves_deliberately_staged_child_pointer(self):
        top, mid, leaf, _, _, leaf_bare = self.publish_tree()
        (leaf / "second").write_text("second\n")
        self.git(leaf, "add", "second"); self.git(leaf, "commit", "-m", "second")
        self.git(leaf, "push", str(leaf_bare), "main")
        self.git(mid, "add", "leaf")
        staged = self.git(mid, "ls-files", "--stage", "leaf")
        (leaf / "third").write_text("third\n"); self.git(leaf, "add", "third")
        result = self.cli(top, "publish", "--yes", ok=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.git(mid, "ls-files", "--stage", "leaf"), staged)

    def test_sync_preserves_ignored_file_collision(self):
        source, bare, repo = self.remote_repo("ignored")
        (repo / ".git/info/exclude").write_text("collision\n")
        (repo / "collision").write_text("precious ignored contents\n")
        (source / "collision").write_text("upstream\n")
        self.git(source, "add", "collision"); self.git(source, "commit", "-m", "new tracked path")
        self.git(source, "push", str(bare), "main")
        before = self.git(repo, "rev-parse", "HEAD")
        self.assertEqual(self.cli(repo, "sync", ok=False).returncode, 1)
        self.assertEqual((repo / "collision").read_text(), "precious ignored contents\n")
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)

    def test_sync_preserves_unpublished_submodule_commit(self):
        _, _, top, _, _, _, _ = self.make_sync_tree()
        self.cli(top, "sync")
        child = top / "middle"
        (child / "local").write_text("unpublished\n")
        self.git(child, "add", "local"); self.git(child, "commit", "-m", "unpublished")
        before = self.git(child, "rev-parse", "HEAD")
        self.assertEqual(self.cli(top, "sync", ok=False).returncode, 1)
        self.assertEqual(self.git(child, "rev-parse", "HEAD"), before)

    def test_sync_refuses_submodule_removal(self):
        source, bare, top, _, _, _, _ = self.make_sync_tree()
        self.cli(top, "sync")
        self.git(source, "rm", "-f", "sibling"); self.git(source, "commit", "-m", "remove")
        self.git(source, "push", str(bare), "main")
        before = self.git(top, "rev-parse", "HEAD")
        self.assertEqual(self.cli(top, "sync", ok=False).returncode, 1)
        self.assertEqual(self.git(top, "rev-parse", "HEAD"), before)
        self.assertTrue((top / "sibling/file").is_file())

    def test_publish_checks_push_url_and_conflicting_configuration(self):
        _, bare, repo = self.remote_repo("push-config")
        self.owned_remote(repo, bare)
        (repo / "new").write_text("new\n"); self.git(repo, "add", "new")
        before = self.git(repo, "rev-parse", "HEAD")
        self.git(repo, "remote", "set-url", "--push", "origin", "https://not-owned.invalid/owner/repo")
        self.assertEqual(self.cli(repo, "publish", "--yes", ok=False).returncode, 1)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)
        self.git(repo, "config", "--unset-all", "remote.origin.pushurl")
        self.git(repo, "config", "remote.origin.push", "HEAD:refs/heads/surprise")
        self.assertEqual(self.cli(repo, "publish", "--yes", ok=False).returncode, 1)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)

    def test_color_json_and_no_color(self):
        repo = self.repo("colors")
        self.assertIn("\x1b[", self.cli(repo, "--color", "always").stdout)
        self.assertNotIn("\x1b[", self.cli(repo, "--color", "always", "--json").stdout)
        self.assertNotIn("\x1b[", self.cli(repo).stdout)

    def test_help_diagnostics_and_machine_output_color_policy(self):
        env = self.env.copy(); env["NO_COLOR"] = "1"
        plain = self.cli(self.base, "--help", env=env).stdout
        colored = self.cli(self.base, "--help", "--color=always", env=env).stdout
        self.assertNotIn("\x1b[", plain)
        self.assertIn("\x1b[36mUsage:", colored)
        self.assertIn("\x1b[36mCommands:", colored)
        self.assertIn("\x1b[36m--config FILE", colored)
        self.assertNotIn("\x1b[", self.cli(self.base, "--color=always", "--help", "--no-color").stdout)
        error = self.cli(self.base, "--color=always", "--invalid", env=env, ok=False)
        self.assertEqual(error.returncode, 2)
        self.assertIn("\x1b[31mgit-it:", error.stderr)
        repo = self.repo("plain-outputs")
        for args in (("--json",), ("--get", "root"), ("--format", "{root}"),
                     ("--list-fields",), ("--version",), ("--completion", "bash"),
                     ("--completion", "zsh"), ("--completion", "fish")):
            with self.subTest(args=args):
                self.assertNotIn("\x1b[", self.cli(repo, "--color=always", *args).stdout)
        result = self.cli(repo, "--color=always", "sync", "--dry-run", ok=False)
        self.assertIn("\x1b[31mblocked", result.stdout)
        result = self.cli(repo, "--color=always", "sync", "--dry-run", "--json", ok=False)
        self.assertNotIn("\x1b[", result.stdout + result.stderr)
        self.assertFalse(json.loads(result.stdout)["complete"])

    def test_auto_color_uses_destination_terminal(self):
        def terminal_output(args, stream, no_color=False):
            env = self.env.copy(); env.pop("NO_COLOR", None)
            if no_color:
                env["NO_COLOR"] = "1"
            master, slave = pty.openpty()
            proc = subprocess.Popen(["bash", str(CLI), "--no-config", *args],
                                    cwd=self.base, env=env, stdin=subprocess.DEVNULL,
                                    stdout=slave if stream == "stdout" else subprocess.PIPE,
                                    stderr=slave if stream == "stderr" else subprocess.PIPE)
            os.close(slave)
            captured = b""
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], 0.1)
                    if ready:
                        try:
                            chunk = os.read(master, 4096)
                        except OSError:
                            break
                        if not chunk:
                            break
                        captured += chunk
                stdout, stderr = proc.communicate(timeout=5)
                return captured, stdout or b"", stderr or b""
            finally:
                if proc.poll() is None:
                    proc.kill(); proc.communicate()
                os.close(master)

        for no_color in (False, True):
            with self.subTest(no_color=no_color):
                output, _, _ = terminal_output(["--help"], "stdout", no_color)
                self.assertEqual(b"\x1b[" in output, not no_color)
                output, _, _ = terminal_output(["--invalid"], "stderr", no_color)
                self.assertEqual(b"\x1b[" in output, not no_color)
        _, _, stderr = terminal_output(["--invalid"], "stdout")
        self.assertNotIn(b"\x1b[", stderr)

    def test_installer_color_policy(self):
        prefix = self.base / "color-prefix"
        for action in ("install", "uninstall"):
            command = ["bash", str(PROJECT / f"{action}.sh"), "--prefix", str(prefix)]
            self.assertIn("\x1b[36mUsage:", self.run_cmd(command + ["--help", "--color=always"]).stdout)
            result = self.run_cmd(command + ["--color=always", "--invalid"], ok=False)
            self.assertIn("\x1b[31mgit-it maintenance:", result.stderr)
            self.assertEqual(result.returncode, 1)
        install = ["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)]
        self.assertIn("\x1b[32mInstall", self.run_cmd(install + ["--dry-run", "--color=always"]).stdout)
        self.assertFalse(prefix.exists())
        self.assertNotIn("\x1b[", self.run_cmd(install + ["--color=always", "--no-color"]).stdout)
        uninstall = ["bash", str(PROJECT / "uninstall.sh"), "--prefix", str(prefix)]
        self.assertIn("\x1b[36mRemove", self.run_cmd(uninstall + ["--color=always"]).stdout)

    def test_installed_manual_and_completions(self):
        prefix = self.base / "completion prefix"
        self.run_cmd(["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)])
        manual = prefix / "share/man/man1/git-it.1"
        self.assertEqual(manual.read_bytes(), (PROJECT / "git-it.1").read_bytes())
        destinations = {"bash": "share/bash-completion/completions/git-it",
                        "zsh": "share/zsh/site-functions/_git-it",
                        "fish": "share/fish/vendor_completions.d/git-it.fish"}
        for shell, relative in destinations.items():
            installed = prefix / relative
            with self.subTest(shell=shell):
                self.assertEqual(installed.read_text(), self.cli(self.base, "--completion", shell).stdout)
                if shutil.which(shell):
                    self.run_cmd([shell, "-n", str(installed)])
        bash_completion = str(prefix / destinations["bash"])
        for word, expected in (("--col", "--color"), ("-h", "-h"), ("-V", "-V"), ("-m", "-m")):
            result = self.run_cmd(["bash", "-c", 'source "$1"; COMP_WORDS=(git-it "$2"); '
                                   'COMP_CWORD=1; _git_it; printf "%s\\n" "${COMPREPLY[@]}"',
                                   "completion-test", bash_completion, word])
            self.assertIn(expected, result.stdout.splitlines())
        result = self.run_cmd(["bash", "-c", 'source "$1"; COMP_WORDS=(git-it --color a); '
                               'COMP_CWORD=2; _git_it; printf "%s\\n" "${COMPREPLY[@]}"',
                               "completion-test", bash_completion])
        self.assertEqual(set(result.stdout.splitlines()), {"auto", "always"})
        if shutil.which("fish"):
            for query, expected in (("git-it --col", "--color"), ("git-it -", "-h"),
                                    ("git-it --color a", "always")):
                result = self.run_cmd(["fish", "--no-config", "-c",
                                       'source $argv[1]; complete -C $argv[2]',
                                       str(prefix / destinations["fish"]), query])
                self.assertIn(expected, [line.split("\t")[0] for line in result.stdout.splitlines()])
        self.run_cmd(["bash", str(PROJECT / "uninstall.sh"), "--prefix", str(prefix)])
        for relative in (*destinations.values(), "share/man/man1/git-it.1"):
            self.assertFalse((prefix / relative).exists())

    @unittest.skipUnless(shutil.which("zsh"), "Zsh is not installed")
    def test_zsh_installed_completion_in_terminal(self):
        prefix = self.base / "zsh prefix"
        self.run_cmd(["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)])
        master, slave = pty.openpty()
        env = self.env.copy(); env["TERM"] = "xterm"
        proc = subprocess.Popen(["zsh", "-f", "-i"], cwd=self.base, env=env,
                                stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)

        def read_until(expected):
            output = b""
            deadline = time.monotonic() + 15
            while expected not in output and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
            self.assertIn(expected, output)

        try:
            directory = shlex.quote(str(prefix / "share/zsh/site-functions"))
            setup = (f"fpath=({directory} $fpath); autoload -Uz compinit; compinit -D; "
                     "bindkey '^I' complete-word; PS1='READY> '; print COMPLETION_READY\n")
            os.write(master, setup.encode())
            read_until(b"\r\nCOMPLETION_READY\r\n")
            os.write(master, b"git-it --col\t")
            read_until(b"--color")
            os.write(master, b"\x15exit\n")
            proc.wait(timeout=5)
            self.assertEqual(proc.returncode, 0)
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait()
            os.close(master)

    def test_git_environment_redirection_rejected(self):
        repo = self.repo("env")
        env = self.env.copy(); env["GIT_DIR"] = str(repo / ".git")
        self.assertEqual(self.cli(repo, "-i", env=env, ok=False).returncode, 3)

    def test_install_upgrade_uninstall_and_modified_preservation(self):
        prefix = self.base / "install prefix"
        self.run_cmd(["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix), "--dry-run"])
        self.assertFalse(prefix.exists())
        for _ in range(2):
            self.run_cmd(["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)])
        installed = prefix / "bin/git-it"
        self.assertIn("0.1.0", self.run_cmd([str(installed), "--version"]).stdout)
        self.assertEqual(json.loads(self.run_cmd([str(installed), "-C", str(self.repo("installed")), "--json"]).stdout)["owned"], False)
        manual = prefix / "share/man/man1/git-it.1"
        manual.write_text(manual.read_text() + "\nlocal edit\n")
        result = self.run_cmd(["bash", str(PROJECT / "uninstall.sh"), "--prefix", str(prefix)], ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(manual.exists())
        self.assertFalse(installed.exists())

    def test_install_refuses_collisions_and_symlinks(self):
        prefix = self.base / "prefix"; (prefix / "bin").mkdir(parents=True)
        existing = prefix / "bin/git-it"; existing.write_text("unrelated")
        self.assertEqual(self.run_cmd(["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)], ok=False).returncode, 1)
        self.assertEqual(existing.read_text(), "unrelated")
        existing.unlink(); existing.symlink_to(self.config)
        self.assertEqual(self.run_cmd(["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)], ok=False).returncode, 1)
        existing.unlink(); os.mkfifo(existing)
        self.assertEqual(self.run_cmd(["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)], ok=False).returncode, 1)

    def test_failed_upgrade_restores_existing_files_and_manifest(self):
        prefix = self.base / "rollback-prefix"
        install_args = ["bash", str(PROJECT / "install.sh"), "--prefix", str(prefix)]
        self.run_cmd(install_args)
        before = {str(p.relative_to(prefix)): p.read_bytes() for p in prefix.rglob("*") if p.is_file()}
        wrappers = self.base / "install-wrappers"; wrappers.mkdir()
        shim = wrappers / "install"
        shim.write_text("#!" + shutil.which("bash") + "\n"
                        '[[ ${!#} != */inspect.bash ]] || exit 1\nexec "$REAL_INSTALL" "$@"\n')
        shim.chmod(0o700)
        env = self.env.copy()
        env.update(PATH=str(wrappers) + os.pathsep + env["PATH"], REAL_INSTALL=shutil.which("install"))
        self.assertEqual(self.run_cmd(install_args, env=env, ok=False).returncode, 1)
        after = {str(p.relative_to(prefix)): p.read_bytes() for p in prefix.rglob("*") if p.is_file()}
        self.assertEqual(after, before)
        self.assertFalse((prefix / ".git-it-install.lock").exists())


if __name__ == "__main__":
    unittest.main()
