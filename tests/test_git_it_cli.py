"""Black-box remote selectors, help assets, and shell grammar."""
import json
import os
import shutil
import unittest

import test_git_it as fixtures


class CliTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GitItTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.env.update(DOTS=str(self.fixture.base / 'no-dots'), DOTS_ICONS='never')
        self.repo = self.fixture.repo('selector fixture')

    def test_fields_and_remote_precedence(self):
        git = self.fixture.git
        git(self.repo, 'remote', 'add', 'origin', 'git@github.com:origin/project.git')
        git(self.repo, 'remote', 'add', 'mirror', 'git@work:team/subgroup/service.git')
        git(self.repo, 'config', 'branch.main.remote', 'mirror')
        self.fixture.config.write_text('[git-it]\nhostAlias = work=gitlab.com\n')
        for short, long, field, expected in (
            ('-o', '--owner', 'owner', 'team/subgroup'), ('-H', '--host', 'host', 'gitlab.com'),
            ('-r', '--repo', 'repo', 'service'), ('-p', '--protocol', 'protocol', 'ssh'),
            ('-R', '--url', 'url', 'work:team/subgroup/service.git'),
        ):
            for flags in ((short,), (long,), ('--get', field)):
                with self.subTest(flags=flags):
                    self.assertEqual(self.fixture.cli(self.repo, '--color=always', *flags, '-n').stdout, expected)
        expected = 'https://gitlab.com/team/subgroup/service.git'
        for flags in (('--https',), ('--https', '-R'), ('-R', '--https'),
                      ('--get', 'https_url'), ('-f', '{https_url}')):
            self.assertEqual(self.fixture.cli(self.repo, *flags).stdout, expected + '\n')
        self.assertEqual(json.loads(self.fixture.cli(self.repo, '--json').stdout)['https_url'], expected)
        self.assertIn('https_url', self.fixture.cli(self.repo, '--list-fields').stdout.splitlines())
        self.assertEqual(self.fixture.cli(self.repo, '--remote', 'origin', '-o').stdout, 'origin\n')
        self.assertEqual(git(self.repo, 'remote', 'get-url', 'mirror'), 'git@work:team/subgroup/service.git')
        git(self.repo, 'config', 'branch.main.remote', 'deleted')
        self.assertEqual(self.fixture.cli(self.repo, '--get', 'remote').stdout, 'origin\n')

    def test_https_projection_and_redaction(self):
        git = self.fixture.git
        git(self.repo, 'remote', 'add', 'origin', 'first')
        for url, expected in (
            ('ssh://git@example.invalid:2222/group/thing', 'https://example.invalid/group/thing'),
            ('ssh://git@example.invalid/a%20b/雪.git', 'https://example.invalid/a%20b/%E9%9B%AA.git'),
            ('git@example.invalid:a b/50%20.git', 'https://example.invalid/a%20b/50%2520.git'),
            ('git@[2001:db8::1]:group/thing.git', 'https://[2001:db8::1]/group/thing.git'),
            ('https://user:SECRET@example.invalid:8443/a/b.git?user=PRIVATE#frag',
             'https://example.invalid:8443/a/b.git'),
            ('file:///repos/thing.git', ''), ('./dir/name:part', ''),
            ('helper::https://user:SECRET@example.invalid/org/repo.git', ''),
            ('git://example.invalid/org/repo.git', ''), ('http://example.invalid/a/b.git', '')
        ):
            with self.subTest(url=url):
                git(self.repo, 'remote', 'set-url', 'origin', url)
                self.assertEqual(self.fixture.cli(self.repo, '--https').stdout, expected + '\n')
                data = self.fixture.cli(self.repo, '--json').stdout
                self.assertNotIn('SECRET', data)
                self.assertNotIn('PRIVATE', data)
                if url.startswith('helper::'):
                    self.assertEqual(self.fixture.cli(self.repo, '-R', '-n').stdout, 'helper::')
                    self.assertFalse(json.loads(data)['owned'])
        git(self.repo, 'remote', 'remove', 'origin')
        self.assertEqual(self.fixture.cli(self.repo, '-R', '--https', '-n').stdout, '')
        self.assertEqual(self.fixture.cli(self.repo, '--https', '--remote', 'missing', ok=False).returncode, 3)

    def test_quick_output_uses_only_remote_metadata(self):
        self.fixture.git(self.repo, 'remote', 'add', 'origin', 'git@example.invalid:a/b.git')
        trace = self.fixture.base / 'commands'
        wrapper = self.fixture.base / 'git'
        wrapper.write_text('#!' + shutil.which('bash') + '\n'
                           'printf "%s\\n" "$*" >> "$GIT_IT_TRACE"\nexec "$GIT_IT_GIT" "$@"\n')
        wrapper.chmod(0o700)
        env = dict(self.fixture.env, GIT_IT_GIT=shutil.which('git'), GIT_IT_TRACE=str(trace),
                   PATH=str(self.fixture.base) + os.pathsep + self.fixture.env['PATH'])
        for flag in ('-o', '-H', '-r', '-p', '-R', '--https'):
            with self.subTest(flag=flag):
                trace.write_text('')
                result = self.fixture.cli(self.repo, '--no-config', flag, '-n', env=env)
                self.assertTrue(result.stdout)
                self.assertEqual(result.stderr, '')
                self.assertEqual(trace.read_text().splitlines(), [
                    f'-C {self.repo} rev-parse --show-toplevel',
                    f'-C {self.repo} symbolic-ref --quiet --short HEAD',
                    f'-C {self.repo} config --get branch.main.remote',
                    f'-C {self.repo} remote get-url -- origin'])

    def test_selector_conflicts(self):
        for args in (('-o', '-p'), ('-R', '--json'), ('--https', '--repo'),
                     ('--https', '-f', '{url}'), ('sync', '--owner'), ('publish', '-R'),
                     ('status', '--url'), ('info', '--view', 'short'), ('publish', '--short'),
                     ('status', '--view=default', '-v'), ('-s', '--short', '--verbose'),
                     ('-s', '-n'), ('--owner=info',), ('sync', '--remote=--dry-run')):
            with self.subTest(args=args):
                self.assertEqual(self.fixture.cli(self.repo, *args, ok=False).returncode, 2)

    def test_source_and_installed_help_are_dynamic(self):
        project = fixtures.PROJECT
        source = self.fixture.base / 'source space'
        source.mkdir()
        for filename in ('git-it', 'install.sh', 'uninstall.sh', 'maintenance.sh', 'git-it.1'):
            shutil.copy2(project / filename, source / filename)
        for directory in ('lib', 'completion'):
            shutil.copytree(project / directory, source / directory)
        prefix = self.fixture.base / 'installed prefix'
        logo = source / 'logo.txt'
        logo.write_text('   new  logo   \n  second row\n')
        self.fixture.run_cmd(['bash', str(source/'install.sh'), '--prefix', str(prefix)])
        self.assertEqual((prefix/'share/git-it/logo.txt').read_bytes(), logo.read_bytes())
        for launcher, asset in ((source/'git-it', logo),
                                (prefix/'bin/git-it', prefix/'share/git-it/logo.txt')):
            alias = self.fixture.base / (launcher.parent.name + ' linked launcher')
            alias.symlink_to(os.path.relpath(launcher, alias.parent))
            for image in ('  changed  \n\nnew 🐧 row', '\t escaped ESC \x1b \n'):
                asset.write_text(image)
                help_text = self.fixture.run_cmd(['bash', str(alias), '--no-color', '--help']).stdout
                if '\x1b' in image:
                    self.assertNotIn('\x1b', help_text)
                else:
                    padded = '\n' + ''.join(' ' + row + '\n' for row in image.split('\n'))
                    self.assertTrue(help_text.startswith(padded + ' Version '), repr(help_text[:70]))
                self.assertIn('Usage:', help_text)
            for shell in ('bash', 'zsh', 'fish'):
                result = self.fixture.run_cmd(['bash', str(alias), '--completion', shell])
                self.assertEqual(result.stdout, (project / 'completion' / shell).read_text())
        uninstall = self.fixture.run_cmd(['bash', str(source/'uninstall.sh'), '--prefix', str(prefix)], ok=False)
        self.assertEqual(uninstall.returncode, 1)
        self.assertTrue((prefix/'share/git-it/logo.txt').is_file())
        logo.unlink()
        os.mkfifo(logo)
        fallback = self.fixture.run_cmd(['bash', str(source/'git-it'), '--no-color', '--help'])
        self.assertTrue(fallback.stdout.startswith('\n git-it '))
        self.assertIn('Usage:', fallback.stdout)
        fresh = self.fixture.base / 'new prefix'
        failed = self.fixture.run_cmd(['bash', str(source/'install.sh'), '--prefix', str(fresh)], ok=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(fresh.exists())
        # Simulate a plain readlink without GNU options. The first target and
        # the relocated checkout directory both have a trailing newline.
        relocated = self.fixture.base / 'relocated checkout\n'
        source.rename(relocated)
        hop = self.fixture.base / 'hop\n'
        hop.symlink_to(relocated/'git-it')
        alias = self.fixture.base / 'portable alias'
        alias.symlink_to(hop.name)
        for name, body in (('readlink', '[ "$#" = 1 ] || exit 2\nexec "$GIT_IT_READLINK" "$1"'),
                           ('realpath', 'exit 2')):
            wrapper = self.fixture.base / name
            wrapper.write_text('#!' + shutil.which('bash') + '\n' + body + '\n')
            wrapper.chmod(0o700)
        env = dict(self.fixture.env, GIT_IT_READLINK=shutil.which('readlink'),
                   PATH=str(self.fixture.base) + os.pathsep + self.fixture.env['PATH'])
        output = self.fixture.run_cmd(['bash', str(alias), '--completion', 'bash'], env=env)
        self.assertEqual(output.stdout, (relocated/'completion/bash').read_text())

    def test_completion_contexts(self):
        for words, expected, missing in (
            (['status', '--view', 'sh'], 'short', '--https'), (['-s', '--fu'], '--full-paths', '--host'),
            (['path', '--get', 'htt'], 'https_url', 'url'), (['info', '--'], '--https', '--short'),
            (['sync', '--remote', '--'], '--dry-run', '--https'),
            (['publish', '--'], '--all', '--https'),
        ):
            with self.subTest(words=words):
                result = self.fixture.run_cmd(['bash', '-c',
                    'source "$1"; shift; COMP_WORDS=(git-it "$@"); COMP_CWORD=$#; '
                    '_git_it; printf "%s\\n" "${COMPREPLY[@]}"',
                    'complete', str(fixtures.PROJECT/'completion/bash'), *words])
                self.assertIn(expected, result.stdout.splitlines())
                self.assertNotIn(missing, result.stdout.splitlines())
                if shutil.which('fish'):
                    result = self.fixture.run_cmd(['fish', '--no-config', '-c',
                        'source $argv[1]; complete -C $argv[2]', str(fixtures.PROJECT/'completion/fish'),
                        'git-it ' + ' '.join(words)])
                    values = [line.partition('\t')[0] for line in result.stdout.splitlines()]
                    self.assertIn(expected, values)
                    self.assertNotIn(missing, values)


if __name__ == '__main__':
    unittest.main()
