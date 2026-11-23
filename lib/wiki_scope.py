"""Resolve a declared Wiki without executing anything from the inspected repository."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys


def association(source):
    manifest = source / ".dots/wiki.json"
    if (manifest.parent.is_symlink() or manifest.is_symlink() or not manifest.is_file()
            or manifest.stat().st_size > 4 * 1024 * 1024):
        raise ValueError("invalid wiki declaration")
    data = manifest.read_bytes()
    spec = json.loads(data)
    if not isinstance(spec, dict) or spec.get("schema") != 1 or not isinstance(spec.get("checkout"), str):
        raise ValueError("invalid wiki declaration")
    value = os.environ.get("DOTS_WIKI_DIR") or spec["checkout"].replace("${HOME}", str(Path.home()))
    path = Path(value).expanduser()
    if (not path.is_absolute() or ".." in path.parts or "${" in value or
            path == source or path in source.parents or source in path.parents or
            any(parent.is_symlink() for parent in (path, *path.parents))):
        raise ValueError("wiki must be a separate checkout")
    if path.exists() and (not path.is_dir() or (path / ".git").is_symlink() or
                          not ((path / ".git").is_file() or (path / ".git").is_dir())):
        raise ValueError("invalid wiki repository")
    return path, hashlib.sha256(data).hexdigest()


def dots_library():
    root = os.environ.get("DOTS")
    if root:
        directory = Path(root)
        if not directory.is_absolute():
            raise ValueError("DOTS must name an absolute checkout")
    else:
        executable = shutil.which("dots")
        if not executable:
            raise ValueError("declared wiki publication requires an installed Dots provenance verifier")
        entry = Path(executable).resolve()
        if entry.parent.name != "bin" or entry.name != "dots":
            raise ValueError("cannot locate Dots provenance verifier")
        directory = entry.parent.parent
    lib = directory / "lib/dots"
    if not (lib / "wiki.py").is_file():
        raise ValueError("declared wiki publication requires an installed Dots provenance verifier")
    return lib


def main(action, source_name, *args):
    source = Path(source_name)
    path, digest = association(source)
    if action == "checkout":
        print(path)
        return
    if action == "digest":
        print(digest)
        return
    expected, signature, branch, source_rev, wiki_rev = args
    if path != Path(expected) or digest != signature:
        raise ValueError("wiki association changed after preview")
    sys.path.insert(0, str(dots_library()))
    from wiki import Reader, checkout, compare, manifest, require_checkout

    spec = manifest(Reader(source))
    if checkout(source, spec) != path:
        raise ValueError("wiki checkout changed")
    require_checkout(path)
    if branch != 'refs/heads/' + spec.get('source_branch', 'main'):
        raise ValueError("wiki publication requires the configured source branch")
    if compare(source, path, revision=wiki_rev or None, source_revision=source_rev or None):
        raise ValueError("selected wiki content is stale; rebuild and review the generated pages")


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (ValueError, OSError, ImportError, KeyError, TypeError) as error:
        # Project data can reach a verifier diagnostic; keep it printable.
        print(ascii(str(error))[1:-1], file=sys.stderr)
        sys.exit(1)
