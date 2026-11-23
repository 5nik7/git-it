"""Public no-command behavior, including real empty argv."""
import json
import unittest

import test_git_it as fixtures


class DefaultReportTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GitItTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.repo = self.fixture.repo('project')

    def cli(self, cwd, *args, **kwargs):
        return self.fixture.run_cmd([str(fixtures.CLI), *args], cwd=cwd, **kwargs)

    def test_clean_and_dirty_invocations(self):
        git = self.fixture.git
        git(self.repo, 'branch', 'upstream')
        git(self.repo, 'branch', '--set-upstream-to=upstream')
        git(self.repo, 'commit', '--allow-empty', '-m', 'ahead')
        clean = self.cli(self.repo)
        self.assertIn('Repository project', clean.stdout)
        self.assertEqual(clean.stdout, self.cli(self.repo, 'info').stdout)
        self.assertNotIn('Git status', clean.stdout)
        self.assertEqual(clean.stderr, '')

        (self.repo/'file').write_text('unstaged\n')
        (self.repo/'new').touch()
        (self.repo/'staged').touch()
        git(self.repo, 'add', 'staged')
        trace = self.fixture.base/'trace.jsonl'
        env = dict(self.fixture.env, GIT_TRACE2_EVENT=str(trace))
        before = (self.repo/'.git/index').read_bytes()
        dirty = self.cli(self.repo, env=env).stdout
        self.assertEqual((self.repo/'.git/index').read_bytes(), before)
        self.assertTrue(dirty.startswith(clean.stdout + '\nGit status\n'))
        for group in ('staged added', 'unstaged modified', 'untracked'):
            self.assertIn(group + ' (1)', dirty)
        events = (json.loads(line) for line in trace.read_text().splitlines())
        self.assertEqual(sum(e.get('event') == 'cmd_name' and e.get('name') == 'status'
                             for e in events), 1)

        for args in (('-C', str(self.repo)), ('--no-color', '--no-progress'),
                     ('--config', str(self.fixture.config))):
            with self.subTest(args=args):
                self.assertEqual(self.cli(self.repo, *args).stdout, dirty)
        self.assertIn('[??] untracked (1)', self.cli(self.repo, '-v').stdout)
        self.assertEqual(self.cli(self.repo, 'info').stdout, clean.stdout)
        self.assertEqual(self.cli(self.repo, '--json').stdout, self.cli(self.repo, 'info', '--json').stdout)
        self.assertEqual(self.cli(self.repo, '--get', 'root').stdout, str(self.repo) + '\n')

    def test_nested_changes_and_unavailable_children(self):
        source = self.fixture.repo('source')
        child = self.fixture.sub(self.repo, source, 'changed-child')
        self.fixture.sub(self.repo, source, 'clean-sibling')
        self.fixture.sub(self.repo, source, 'other-child')
        self.assertNotIn('Git status', self.cli(self.repo).stdout)
        (child/'example').touch()
        changed = self.cli(self.repo).stdout
        self.assertIn('changed-child', changed)
        self.assertIn('example', changed)
        self.assertNotIn('clean-sibling', changed)
        self.assertNotIn('other-child', changed)
        self.fixture.git(self.repo, 'submodule', 'deinit', '-f', '--', 'other-child')
        incomplete = self.cli(self.repo, ok=False)
        self.assertEqual(incomplete.returncode, 1)
        self.assertIn('other-child', incomplete.stdout)
        self.assertIn('missing', incomplete.stdout)
        self.assertIn('example', incomplete.stdout)
        self.assertNotIn('clean-sibling', incomplete.stdout)
        self.assertFalse((self.repo/'other-child/.git').exists())

    def test_outside_worktree_routes_usage_to_stderr(self):
        outside = self.fixture.base
        for opts in ((), ('--color=always',)):
            with self.subTest(opts=opts):
                usage = self.cli(outside, '--help', *opts)
                failed = self.cli(outside, *opts, ok=False)
                self.assertEqual(failed.returncode, 3)
                self.assertEqual((failed.stdout, usage.stderr), ('', ''))
                self.assertIn('not inside a Git worktree', failed.stderr)
                self.assertTrue(failed.stderr.endswith(usage.stdout))
                self.assertIn('Usage:', usage.stdout)
        for args in (('info',), ('status', '--json'), ('--get', 'root')):
            with self.subTest(args=args):
                result = self.cli(outside, *args, ok=False)
                self.assertEqual(result.returncode, 3)
                self.assertEqual(result.stdout, '')
                self.assertNotIn('Usage:', result.stderr)
