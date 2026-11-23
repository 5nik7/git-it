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
        usage = self.cli(self.repo, '--help').stdout
        self.assertIn('Usage:', usage)
        self.assertEqual(self.cli(self.repo).stdout, usage)
        (self.repo/'file').write_text('unstaged\n')
        (self.repo/'untracked').touch()
        trace = self.fixture.base/'trace.jsonl'
        env = dict(self.fixture.env, GIT_TRACE2_EVENT=str(trace))
        before = (self.repo/'.git/index').read_bytes()
        for args in ((), ('-C', str(self.repo)), ('--no-color', '--no-progress')):
            self.assertEqual(self.cli(self.repo, *args, env=env).stdout, usage)
        self.assertEqual((self.repo/'.git/index').read_bytes(), before)
        events = (json.loads(line) for line in trace.read_text().splitlines())
        self.assertFalse(any(e.get('event') == 'cmd_name' and e.get('name') == 'status'
                             for e in events))
        self.assertEqual(self.cli(self.repo, '--json').stdout, self.cli(self.repo, 'info', '--json').stdout)
        self.assertEqual(self.cli(self.repo, '--get', 'root').stdout, str(self.repo) + '\n')

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
