"""Warm timings and external-command counts, exclusively in disposable repos."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import statistics
import subprocess
import time

from test_git_it import CLI, GitItTest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--baseline-icon", type=Path)
    parser.add_argument("--baseline-path", type=Path)
    args = parser.parse_args()
    if args.runs < 2:
        parser.error("--runs must be at least two")
    fixture = GitItTest()
    fixture.setUp()
    try:
        base = fixture.repo("benchmark")
        fixture.git(base, "remote", "add", "origin", "git@github.com:5nik7/benchmark.git")
        leaf = fixture.repo("leaf")
        middle = fixture.repo("middle")
        fixture.sub(middle, leaf, "leaf")
        top = fixture.repo("top")
        fixture.sub(top, middle, "middle")
        fixture.git(top, "submodule", "update", "--init", "--recursive")
        wrappers = fixture.base / "wrappers"
        wrappers.mkdir()
        trace = fixture.base / "trace"
        bash = shutil.which("bash")
        for name in ("git", "sed", "awk", "grep", "cut", "tput", "dirname", "basename"):
            real = shutil.which(name)
            if not real:
                continue
            wrapper = wrappers / name
            wrapper.write_text(f'#!{bash}\nprintf "%s\\n" {shlex.quote(name)} >> "$GIT_IT_TRACE"\nexec {shlex.quote(real)} "$@"\n')
            wrapper.chmod(0o700)
        results = []

        def measure(label, cwd, command):
            def run(env):
                return subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, timeout=10)
            for _ in range(3):
                run(fixture.env)
            timings = []
            for _ in range(args.runs):
                start = time.perf_counter_ns()
                result = run(fixture.env)
                timings.append((time.perf_counter_ns() - start) / 1_000_000)
            trace.write_text("")
            env = fixture.env.copy()
            env.update(PATH=str(wrappers) + os.pathsep + env["PATH"], GIT_IT_TRACE=str(trace))
            run(env)
            counts = {}
            for name in trace.read_text().splitlines():
                counts[name] = counts.get(name, 0) + 1
            ordered = sorted(timings)
            results.append(dict(scenario=label, runs=args.runs,
                                median_ms=round(statistics.median(timings), 3),
                                p95_ms=round(ordered[min(len(ordered)-1, int(len(ordered)*0.95))], 3),
                                returncode=result.returncode, external_commands=counts,
                                output=result.stdout.decode(errors="replace").rstrip("\n")))

        current = [bash, str(CLI), "--no-config"]
        measure("icon-small", base, current + ["-i"])
        if args.baseline_icon:
            measure("legacy-icon-small", base, [bash, str(args.baseline_icon), "-i"])
        for i in range(3000):
            (base / f"untracked-{i}").touch()
        measure("icon-3000-untracked", base, current + ["-i"])
        for depth, cwd in enumerate((top, top / "middle", top / "middle/leaf"), 1):
            measure(f"path-depth-{depth}", cwd, current + ["path", "--format", "{parent_basename}/{path_outermost}/{cwd_prefix}"])
        if args.baseline_path:
            measure("legacy-path-depth-3", top / "middle/leaf",
                    [bash, str(args.baseline_path), "--format", "%M/%T/%W"])
        baselines = {}
        for key, path in (("icon", args.baseline_icon), ("path", args.baseline_path)):
            if path:
                baselines[key] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "name": path.name}
        print(json.dumps({"platform": platform.platform(), "machine": platform.machine(),
                          "git": fixture.run_cmd(["git", "--version"]).stdout.strip(),
                          "bash": fixture.run_cmd([bash, "--version"]).stdout.splitlines()[0],
                          "timing": "warm, uninstrumented, sequential; no cold-cache claim",
                          "counts": "separate instrumented invocation; listed external commands only, not Bash forks",
                          "baselines": baselines, "results": results}, indent=2))
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    main()
