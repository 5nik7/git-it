"""Command-scope and mutation boundaries in isolated worktrees."""
import json
import unittest

import test_git_it as fixtures


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.GitItTest()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)

    def test_registered_selection_names_paths_depth_and_forest(self):
        f = self.f
        root, mid, leaf = (f.repo(name) for name in ('project', 'middle', 'leaf'))
        f.sub(mid, leaf, 'nested/child')
        child = f.sub(root, mid, 'plugins/one')
        f.sub(root, leaf, 'tools/two')
        f.git(root, 'submodule', 'update', '--init', '--recursive')
        for args in (('submodule', 'one:child', '--get', 'root'),
                     ('submodule', 'one', 'submodule', 'child', 'info', '--get', 'root')):
            self.assertEqual(f.cli(root, *args).stdout.strip(), str(child/'nested/child'))
        for args in (('submodule', 'nested/child'), ('submodule', 'child'),
                     ('submodules', 'status', '../middle'), ('submodules', 'publish')):
            self.assertEqual(f.cli(root, *args, ok=False).returncode, 2)
        for args, values in [
            (('__complete-submodule-names',), ['one', 'two']),
            (('__complete-submodule-paths', 'one'), ['nested/child']),
        ]:
            output = f.cli(root, *args).stdout
            self.assertEqual(output.split('\0')[:-1], values)
        forest = json.loads(f.cli(root, 'submodules', 'publish', '--all-submodules', '--dry-run', '--json').stdout)
        self.assertEqual({e['path'] for e in forest['events']}, {str(child), str(child/'nested/child'), str(root/'tools/two')})
        self.assertEqual(json.loads(f.cli(root, 'submodules', 'status', 'plugins/one/nested/child', '--json').stdout)
                         ['repositories'][0]['path'], str(child/'nested/child'))
        f.sub(root, leaf, 'other/one')
        self.assertEqual(f.cli(root, 'submodule', 'one', ok=False).returncode, 2)

    def test_scoped_publish_does_not_stage_outer_parent(self):
        f = self.f
        root = f.repo('parent')
        _, bare, _ = f.remote_repo('child')
        child = f.sub(root, bare, 'child')
        f.owned_remote(child, bare)
        (child/'example').touch()
        f.git(child, 'add', 'example')
        head = f.git(root, 'rev-parse', 'HEAD')
        index = (root/'.git/index').read_bytes()
        f.cli(root, 'submodule', 'child', 'publish', '--yes', '-m', 'child')
        self.assertEqual(f.git(root, 'rev-parse', 'HEAD'), head)
        self.assertEqual((root/'.git/index').read_bytes(), index)
        self.assertEqual(f.git(bare, 'rev-parse', 'main'), f.git(child, 'rev-parse', 'HEAD'))

    def test_sync_needs_explicit_init(self):
        f = self.f
        _, remote, root = f.remote_repo('root')
        child = f.repo('child')
        f.sub(root, child, 'private')
        f.git(root, 'push', str(remote), 'main')
        f.git(root, 'submodule', 'deinit', '-f', '--', 'private')
        for flags in [('--dry-run',), ()]:
            outcome = f.cli(root, 'sync', *flags, '--json', ok=False)
            self.assertEqual(outcome.returncode, 1)
            self.assertTrue(any('--init' in row['detail'] for row in json.loads(outcome.stdout)['events']))
            self.assertFalse((root/'private/.git').exists())
        f.cli(root, 'sync', '--init')
        self.assertTrue((root/'private/.git').exists())

    def test_wiki_routes_verify_identity_and_require_explicit_sibling_mutation(self):
        f = self.f
        _, bare, root = f.remote_repo('project')
        _, wiki_bare, wiki = f.remote_repo('project.wiki')
        for repo, path in [(root, bare), (wiki, wiki_bare)]:
            f.owned_remote(repo, path)
        (wiki/'page.md').touch()
        f.git(wiki, 'add', 'page.md')
        self.assertEqual(f.cli(root, 'wiki', '--get', 'root').stdout.strip(), str(wiki))
        primary = json.loads(f.cli(root, 'publish', '--dry-run', '--json').stdout)
        self.assertTrue(all(row['path'] == str(root) for row in primary['events']))
        f.cli(root, 'wiki', 'publish', '--yes', '-m', 'wiki')
        self.assertEqual(f.git(wiki_bare, 'rev-parse', 'main'), f.git(wiki, 'rev-parse', 'HEAD'))
        f.cli(root, 'wiki', 'sync')
        f.git(wiki, 'remote', 'set-url', 'origin', 'https://wrong.invalid/team/project.wiki.git')
        self.assertEqual(f.cli(root, 'wiki', 'sync', '--dry-run', ok=False).returncode, 3)

    def test_inferred_wiki_ports_and_push_destination(self):
        f = self.f
        _, bare, root = f.remote_repo('project')
        _, wiki_bare, wiki = f.remote_repo('project.wiki')
        f.owned_remote(root, bare)
        f.owned_remote(wiki, wiki_bare)
        (wiki/'example').touch()
        f.git(wiki, 'add', 'example')
        other_url = 'ssh://git@example.invalid' + str(bare)
        f.git(wiki, 'config', 'remote.origin.pushurl', other_url)
        result = f.cli(root, 'wiki', 'publish', '--dry-run', '--json', ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(any(e['status'] == 'blocked' for e in json.loads(result.stdout)['events']))
        for source, target, expected in [
            ('ssh://git@host:22/owner/r', 'https://host:443/owner/r.wiki.git', 0),
            ('ssh://git@host:2222/owner/r', 'https://host:8443/owner/r.wiki', 3),
            ('ssh://git@host:2222/owner/r', 'https://host:2222/owner/r.wiki', 3),
            ('https://host:8443/owner/r', 'https://host:8443/owner/r.wiki', 0),
        ]:
            f.git(root, 'remote', 'set-url', 'origin', source)
            f.git(wiki, 'remote', 'set-url', 'origin', target)
            self.assertEqual(f.cli(root, 'wiki', '--get', 'root', ok=False).returncode, expected)

    def test_declared_wiki_missing_and_absent_provenance_verifier(self):
        f = self.f
        _, bare, root = f.remote_repo('source')
        wiki = f.repo('unrelated-name')
        (root/'.dots').mkdir()
        manifest = root/'.dots/wiki.json'
        manifest.write_text(json.dumps({'schema': 1, 'checkout': str(wiki)}))
        self.assertEqual(f.cli(root, 'wiki', '--get', 'root').stdout.strip(), str(wiki))
        f.owned_remote(root, bare)
        f.git(root, 'add', '.dots/wiki.json')
        before = f.git(root, 'rev-parse', 'HEAD')
        outcome = f.cli(root, 'publish', '--yes', '--json', ok=False)
        self.assertEqual(outcome.returncode, 1)
        self.assertEqual(f.git(root, 'rev-parse', 'HEAD'), before)
        self.assertEqual(f.git(bare, 'rev-parse', 'main'), before)
        manifest.write_text(json.dumps({'schema': 1, 'checkout': str(root.parent/'missing')}))
        self.assertEqual(f.cli(root, 'wiki', ok=False).returncode, 3)


if __name__ == '__main__':
    unittest.main()
