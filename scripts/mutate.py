#!/usr/bin/env -S python3 -I
"""Mutation testing for MangaCarta: break code on purpose, check a test goes red.

Usage:
  python3 -I scripts/mutate.py MUTATIONS.json [--report OUT.md] [--only ID,ID] [--check]

The mutation file is JSON:

  {
    "runner": "swift",                    # default runner: "swift" or "worker"
    "mutations": [
      {
        "id": "M1",
        "description": "ordinals sorted oldest first",
        "file": "MangaCarta/Models/UpdatesTimeline.swift",   # relative to the repo root
        "old": "ordinals.sorted(by: >)",  # must occur in the file exactly once
        "new": "ordinals.sorted(by: <)",
        "tests": ["MangaCartaTests/UpdatesPresentationTests"],
        "runner": "swift",                # optional, overrides the default
        "equivalent": "why no test can tell"   # optional: an expected survivor
      }
    ]
  }

tests, per runner:
  swift   -only-testing: selectors, e.g. "MangaCartaTests/UpdatesPresentationTests" or
          "MangaCartaTests/MangaCartaTests/testSomething".
  worker  run with node:test in server/analytics-worker. An entry ending in .js/.mjs/.cjs
          is a test file (relative to that directory); anything else is a
          --test-name-pattern regex. With no files, the glob from package.json's
          "test" script is used, so a pattern alone filters the whole suite.

What happens:
  1. Refuses to start if any target file has uncommitted changes, so a crash can never
     leave a mutation mixed in with real work. (A run killed with SIGKILL leaves a journal
     in the git dir; the next run restores the file from it before anything else.)
  2. Baseline: runs the named tests on unmodified code. Stops (exit 2) unless green.
  3. For each mutation: apply the edit, run only its tests, restore the file - always,
     including on Ctrl-C, SIGTERM or an exception.
       KILLED    a named test failed
       SURVIVED  every named test passed (an "equivalent" entry is expected to)
       ERROR     text not found or not unique, build/syntax error, a test file that
                 failed to load, no test matched the selectors, or a timeout
  4. Prints a Markdown table for the PR description (also written to --report).

Swift: build-for-testing on the iPhone 17 Pro simulator (looked up by name, addressed by
UDID), then test-without-building with the selectors; the result comes from the .xcresult (`xcresulttool get test-results
tests`), not from scraping output. A failed build is ERROR, never KILLED. Every mutation
rebuilds incrementally (the source changed), so the cost per mutation is one incremental
compile plus one test launch.

Exit status: 0 every mutation killed (or an expected equivalent survivor); 1 a mutation
survived unexpectedly or errored; 2 usage, dirty tree or red baseline.
"""

import argparse
import base64
import glob
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional, Tuple

KILLED, SURVIVED, ERROR = "KILLED", "SURVIVED", "ERROR"
DEFAULT_DEVICE = "iPhone 17 Pro"
JOURNAL_NAME = "mutate-journal.json"


class Terminated(BaseException):
    """Raised from a SIGTERM/SIGHUP handler so `finally` blocks still restore files."""


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def git(root: str, *args: str) -> str:
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True,
                          text=True).stdout


def run_cmd(cmd: List[str], cwd: str, timeout: float, log_path: str) -> Tuple[Optional[int], float]:
    """Run cmd with output to log_path. Returns (exit code or None on timeout, seconds).

    The child gets its own session so a timeout or Ctrl-C kills the whole tree
    (xcodebuild spawns many helpers) instead of orphaning it.
    """
    start = time.monotonic()
    with open(log_path, "ab") as out:
        out.write(("$ " + " ".join(shlex.quote(c) for c in cmd) + "\n").encode())
        out.flush()
        proc = subprocess.Popen(cmd, cwd=cwd, stdout=out, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)  # type: Optional[int]
        except subprocess.TimeoutExpired:
            code = None
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
    return code, time.monotonic() - start


def first_compile_error(path: str, root: str) -> str:
    """The first `file:line:col: error: ...` line, repo-relative; else the last `error:` line."""
    try:
        with open(path, errors="replace") as f:
            lines = [ln.strip() for ln in f if "error:" in ln]
    except OSError:
        return ""
    for ln in lines:
        m = re.match(r"(/\S+?):(\d+):\d+: error: (.*)", ln)
        if m:
            return "%s:%s: %s" % (os.path.relpath(m.group(1), root), m.group(2), m.group(3))
    return lines[-1] if lines else ""


# ---------------------------------------------------------------- runners

class Outcome:
    def __init__(self, status: str, detail: str = "", failed: Optional[List[str]] = None):
        self.status = status          # KILLED / SURVIVED / ERROR
        self.detail = detail          # why, for ERROR; the killing test(s) for KILLED
        self.failed = failed or []


class SwiftRunner:
    name = "swift"

    def __init__(self, root: str, args: argparse.Namespace, workdir: str):
        self.root, self.args, self.workdir = root, args, workdir
        self.count = 0
        self.destination = args.destination or self._resolve(args.device)

    @staticmethod
    def _resolve(name: str) -> str:
        """The simulator's UDID. `name=` alone means OS:latest, which misses a device that
        lives on an older runtime - as the seeded iPhone 17 Pro does once Xcode updates."""
        out = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                             check=True, capture_output=True, text=True).stdout
        found = [d for ds in json.loads(out)["devices"].values() for d in ds if d.get("name") == name]
        if not found:
            raise SystemExit("mutate: no available simulator named %r (pass --destination)" % name)
        found.sort(key=lambda d: d.get("state") != "Booted")  # a booted one is the one in use
        return "platform=iOS Simulator,id=" + found[0]["udid"]

    def _base(self) -> List[str]:
        cmd = ["xcodebuild", "-scheme", self.args.scheme, "-destination", self.destination]
        if self.args.derived_data:
            cmd += ["-derivedDataPath", self.args.derived_data]
        return cmd

    def check_file(self, path: str) -> Optional[str]:
        return None  # the build is the check

    def run(self, tests: List[str], label: str) -> Outcome:
        self.count += 1
        logf = os.path.join(self.workdir, "%02d-%s.log" % (self.count, label))
        code, secs = run_cmd(self._base() + ["-quiet", "build-for-testing"], self.root,
                             self.args.build_timeout, logf)
        log("    build-for-testing %.0fs" % secs)
        if code is None:
            return Outcome(ERROR, "build timed out (log: %s)" % logf)
        if code != 0:
            why = first_compile_error(logf, self.root) or "exit %d" % code
            return Outcome(ERROR, "build failed: %s" % why)

        bundle = os.path.join(self.workdir, "%02d-%s.xcresult" % (self.count, label))
        cmd = self._base() + ["-resultBundlePath", bundle, "test-without-building"]
        cmd += ["-only-testing:" + t for t in tests]
        code, secs = run_cmd(cmd, self.root, self.args.test_timeout, logf)
        log("    test-without-building %.0fs" % secs)
        if code is None:
            return Outcome(ERROR, "tests timed out (log: %s)" % logf)
        cases = self._cases(bundle)
        if cases is None:
            return Outcome(ERROR, "no readable .xcresult, xcodebuild exit %d (log: %s)" % (code, logf))
        failed = [n for n, r in cases if r == "Failed"]
        if failed:
            return Outcome(KILLED, failed=failed)
        if not any(r == "Passed" for _, r in cases):
            return Outcome(ERROR, "no test matched the selectors (log: %s)" % logf)
        if code != 0:
            return Outcome(ERROR, "xcodebuild exit %d with no failed test (log: %s)" % (code, logf))
        return Outcome(SURVIVED)

    @staticmethod
    def _cases(bundle: str) -> Optional[List[Tuple[str, str]]]:
        if not os.path.exists(bundle):
            return None
        proc = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests",
                               "--path", bundle, "--compact"], capture_output=True, text=True)
        if proc.returncode != 0:
            return None
        cases = []  # type: List[Tuple[str, str]]

        def walk(nodes, trail):
            for node in nodes or []:
                kind, name = node.get("nodeType"), node.get("name", "?")
                if kind == "Test Case":
                    # Swift Testing names are display strings; nodeIdentifier is the selector.
                    ident = node.get("nodeIdentifier") or "/".join(trail + [name])
                    cases.append((ident, node.get("result", "")))
                else:
                    keep = kind in ("Unit test bundle", "UI test bundle", "Test Suite")
                    walk(node.get("children"), trail + [name] if keep else trail)

        walk(json.loads(proc.stdout).get("testNodes"), [])
        return cases


class WorkerRunner:
    name = "worker"
    SOURCE_EXT = (".js", ".mjs", ".cjs")

    def __init__(self, root: str, args: argparse.Namespace, workdir: str):
        self.root, self.args, self.workdir = root, args, workdir
        self.dir = os.path.join(root, args.worker_dir)
        self.count = 0

    def _default_files(self) -> List[str]:
        with open(os.path.join(self.dir, "package.json")) as f:
            script = json.load(f).get("scripts", {}).get("test", "")
        words = shlex.split(script)
        if words[:2] != ["node", "--test"] or len(words) < 3:
            raise SystemExit("mutate: %s/package.json's test script is not `node --test <files>`: %r"
                             % (self.args.worker_dir, script))
        files = []  # type: List[str]
        for pattern in words[2:]:
            files += sorted(glob.glob(pattern, root_dir=self.dir)) if sys.version_info >= (3, 10) \
                else sorted(os.path.relpath(p, self.dir) for p in glob.glob(os.path.join(self.dir, pattern)))
        return files

    def check_file(self, path: str) -> Optional[str]:
        if not path.endswith(self.SOURCE_EXT):
            return None
        proc = subprocess.run(["node", "--check", path], capture_output=True, text=True)
        if proc.returncode != 0:
            lines = [ln for ln in proc.stderr.splitlines() if "Error" in ln]
            return "syntax error: " + (lines[0].strip() if lines else proc.stderr.strip()[:200])
        return None

    def run(self, tests: List[str], label: str) -> Outcome:
        self.count += 1
        files = [t for t in tests if t.endswith(self.SOURCE_EXT)]
        patterns = [t for t in tests if t not in files]
        files = files or self._default_files()
        junit = os.path.join(self.workdir, "%02d-%s.junit.xml" % (self.count, label))
        logf = os.path.join(self.workdir, "%02d-%s.log" % (self.count, label))
        cmd = ["node", "--test", "--test-reporter=junit", "--test-reporter-destination=" + junit,
               "--test-reporter=spec", "--test-reporter-destination=stdout"]
        cmd += ["--test-name-pattern=" + p for p in patterns] + files
        code, secs = run_cmd(cmd, self.dir, self.args.worker_timeout, logf)
        log("    node --test %.1fs" % secs)
        if code is None:
            return Outcome(ERROR, "tests timed out (log: %s)" % logf)
        try:
            cases = ET.parse(junit).getroot().iter("testcase")
        except (OSError, ET.ParseError):
            return Outcome(ERROR, "no JUnit report, node exit %d (log: %s)" % (code, logf))
        abs_files = {os.path.normpath(os.path.join(self.dir, f)) for f in files}
        ran, failed, load_failures = 0, [], []
        for case in cases:
            name = case.get("name", "?")
            bad = case.find("failure") is not None or case.find("error") is not None
            # A file that never registered a test (it failed to load, or nothing in it
            # matched the filter) is reported as one testcase named after the file.
            if os.path.normpath(os.path.join(self.dir, name)) in abs_files:
                if bad:
                    load_failures.append(name)
                continue
            if case.find("skipped") is not None:
                continue
            ran += 1
            if bad:
                failed.append(name)
        if load_failures:
            return Outcome(ERROR, "test file failed to load: %s" % ", ".join(load_failures))
        if failed:
            return Outcome(KILLED, failed=failed)
        if ran == 0:
            return Outcome(ERROR, "no test matched %s" % (patterns or files))
        if code != 0:
            return Outcome(ERROR, "node exit %d with no failed test (log: %s)" % (code, logf))
        return Outcome(SURVIVED)


RUNNERS = {"swift": SwiftRunner, "worker": WorkerRunner}


# ---------------------------------------------------------------- mutation file

class Mutation:
    def __init__(self, raw: dict, default_runner: Optional[str], index: int):
        where = "mutation #%d" % (index + 1)
        for key in ("id", "description", "file", "old", "new", "tests"):
            if key not in raw:
                raise SystemExit("mutate: %s is missing %r" % (where, key))
        self.id = str(raw["id"])
        self.description = str(raw["description"])
        self.file = str(raw["file"])
        self.old, self.new = raw["old"], raw["new"]
        self.tests = raw["tests"]
        self.runner = raw.get("runner", default_runner)
        self.equivalent = raw.get("equivalent")
        if not isinstance(self.tests, list) or not self.tests or \
                not all(isinstance(t, str) and t for t in self.tests):
            raise SystemExit("mutate: %s (%s): tests must be a non-empty list of strings" % (where, self.id))
        if self.runner not in RUNNERS:
            raise SystemExit("mutate: %s (%s): runner must be one of %s" % (where, self.id, sorted(RUNNERS)))
        if not isinstance(self.old, str) or not isinstance(self.new, str) or self.old == self.new:
            raise SystemExit("mutate: %s (%s): old and new must be different strings" % (where, self.id))


def load_mutations(path: str) -> List[Mutation]:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("mutations"), list):
        raise SystemExit("mutate: %s must be an object with a \"mutations\" list" % path)
    muts = [Mutation(m, data.get("runner"), i) for i, m in enumerate(data["mutations"])]
    ids = [m.id for m in muts]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        raise SystemExit("mutate: duplicate ids: %s" % ", ".join(dupes))
    return muts


# ---------------------------------------------------------------- file safety

class Journal:
    """Remembers the original bytes of the file under mutation, in the git dir.

    try/finally covers exceptions, Ctrl-C and SIGTERM; this covers SIGKILL and power loss:
    the next run restores the file before it does anything else.
    """

    def __init__(self, root: str):
        gitdir = git(root, "rev-parse", "--absolute-git-dir").strip()
        self.path = os.path.join(gitdir, JOURNAL_NAME)

    def recover(self) -> None:
        if not os.path.exists(self.path):
            return
        with open(self.path) as f:
            entry = json.load(f)
        original = base64.b64decode(entry["original"])
        with open(entry["file"], "rb") as f:
            current = f.read()
        if current != original:
            write_bytes(entry["file"], original)
            log("mutate: restored %s, left mutated by an interrupted run" % entry["file"])
        os.remove(self.path)

    def record(self, path: str, original: bytes) -> None:
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"file": path, "original": base64.b64encode(original).decode()}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)

    def clear(self) -> None:
        if os.path.exists(self.path):
            os.remove(self.path)


def write_bytes(path: str, data: bytes) -> None:
    with open(path, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def refuse_dirty(root: str, files: List[str]) -> None:
    for rel in files:
        if not os.path.isfile(os.path.join(root, rel)):
            raise SystemExit("mutate: target file does not exist: %s" % rel)
        if not git(root, "ls-files", "--", rel).strip():
            raise SystemExit("mutate: target file is not tracked by git: %s" % rel)
    dirty = git(root, "status", "--porcelain", "--", *files).strip()
    if dirty:
        raise SystemExit("mutate: refusing to start - target files have uncommitted changes, "
                         "commit or stash them first:\n" + dirty)


def locate(source: str, old: str) -> Optional[str]:
    """None if `old` occurs exactly once, else why not."""
    n = source.count(old)
    if n == 0:
        return "old text not found"
    if n > 1:
        return "old text matches %d times, must match once" % n
    return None


# ---------------------------------------------------------------- main

def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def table(rows: List[Tuple[Mutation, Outcome]]) -> str:
    out = ["| id | description | result | killed by |", "|---|---|---|---|"]
    for m, o in rows:
        result = o.status
        if o.status == SURVIVED and m.equivalent:
            result = "SURVIVED (equivalent: %s)" % m.equivalent
        elif o.status == ERROR:
            result = "ERROR: %s" % o.detail
        killer = ""
        if o.failed:
            killer = "`%s`" % o.failed[0] + (" +%d more" % (len(o.failed) - 1) if len(o.failed) > 1 else "")
        out.append("| %s | %s | %s | %s |" % (cell(m.id), cell(m.description), cell(result), cell(killer)))
    killed = sum(o.status == KILLED for _, o in rows)
    equiv = sum(o.status == SURVIVED and bool(m.equivalent) for m, o in rows)
    surv = sum(o.status == SURVIVED and not m.equivalent for m, o in rows)
    errs = sum(o.status == ERROR for _, o in rows)
    out.append("")
    out.append("%d killed, %d survived, %d equivalent, %d error (of %d)." % (killed, surv, equiv, errs, len(rows)))
    return "\n".join(out)


def parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="mutate.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mutations", help="the mutation file (JSON)")
    p.add_argument("--report", help="also write the Markdown table here")
    p.add_argument("--only", help="comma-separated ids to run (baseline still runs)")
    p.add_argument("--check", action="store_true",
                   help="validate the file and that every old text matches once; run nothing")
    p.add_argument("--scheme", default="MangaCarta")
    p.add_argument("--device", default=DEFAULT_DEVICE,
                   help="simulator name, resolved to its UDID (default %(default)s)")
    p.add_argument("--destination", help="xcodebuild -destination, overriding --device")
    p.add_argument("--derived-data", help="xcodebuild -derivedDataPath (default: Xcode's own)")
    p.add_argument("--worker-dir", default="server/analytics-worker",
                   help="the Worker directory, relative to the repo root")
    p.add_argument("--build-timeout", type=float, default=1200, help="seconds (default 1200)")
    p.add_argument("--test-timeout", type=float, default=900, help="seconds (default 900)")
    p.add_argument("--worker-timeout", type=float, default=120, help="seconds (default 120)")
    p.add_argument("--keep-logs", action="store_true", help="keep build/test logs and result bundles")
    return p.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    muts = load_mutations(args.mutations)
    if args.only:
        wanted = set(args.only.split(","))
        unknown = wanted - {m.id for m in muts}
        if unknown:
            raise SystemExit("mutate: --only names unknown ids: %s" % ", ".join(sorted(unknown)))
        muts = [m for m in muts if m.id in wanted]

    root = git(os.getcwd(), "rev-parse", "--show-toplevel").strip()
    journal = Journal(root)
    journal.recover()
    files = sorted({m.file for m in muts})
    refuse_dirty(root, files)

    sources = {}  # type: Dict[str, str]
    for rel in files:
        with open(os.path.join(root, rel), "rb") as f:
            sources[rel] = f.read().decode("utf-8")
    problems = {m.id: locate(sources[m.file], m.old) for m in muts}
    if args.check:
        for m in muts:
            log("%-12s %s" % (m.id, problems[m.id] or "ok"))
        return 1 if any(problems.values()) else 0

    def on_signal(signum, _frame):
        raise Terminated("signal %d" % signum)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGHUP, on_signal)

    workdir = tempfile.mkdtemp(prefix="mutate-")
    runners = {}  # type: Dict[str, object]
    for name in sorted({m.runner for m in muts}):
        runners[name] = RUNNERS[name](root, args, workdir)

    rows = []  # type: List[Tuple[Mutation, Outcome]]
    try:
        # Baseline: Swift selectors are unioned into one run; each distinct Worker
        # test list runs once (a pattern and a file list don't union cleanly).
        log("baseline")
        groups = {}  # type: Dict[Tuple[str, Tuple[str, ...]], None]
        for m in muts:
            key = ("swift", ()) if m.runner == "swift" else ("worker", tuple(m.tests))
            groups[key] = None
        for runner_name, tests in groups:
            if runner_name == "swift":
                tests = tuple(sorted({t for m in muts if m.runner == "swift" for t in m.tests}))
            o = runners[runner_name].run(list(tests), "baseline")
            if o.status != SURVIVED:
                what = o.detail or "failed: %s" % ", ".join(o.failed[:5])
                log("mutate: baseline is not green (%s %s): %s - fix that before mutating; logs in %s"
                    % (runner_name, " ".join(tests), what, workdir))
                args.keep_logs = True
                return 2
        log("baseline green")

        for m in muts:
            log("%s: %s" % (m.id, m.description))
            if problems[m.id]:
                rows.append((m, Outcome(ERROR, problems[m.id])))
                log("    ERROR: %s" % problems[m.id])
                continue
            path = os.path.join(root, m.file)
            original = sources[m.file].encode("utf-8")
            journal.record(path, original)
            try:
                write_bytes(path, sources[m.file].replace(m.old, m.new, 1).encode("utf-8"))
                bad = runners[m.runner].check_file(path)
                o = Outcome(ERROR, bad) if bad else runners[m.runner].run(m.tests, m.id)
            finally:
                write_bytes(path, original)
                journal.clear()
            rows.append((m, o))
            log("    %s %s" % (o.status, o.detail or ", ".join(o.failed[:3])))
    except (KeyboardInterrupt, Terminated):
        log("mutate: interrupted - files restored")
        if rows:
            print(table(rows))
        return 130
    finally:
        if not args.keep_logs:
            shutil.rmtree(workdir, ignore_errors=True)
        else:
            log("logs: %s" % workdir)

    report = table(rows)
    print(report)
    if args.report:
        with open(args.report, "w") as f:
            f.write(report + "\n")
    bad = any(o.status == ERROR or (o.status == SURVIVED and not m.equivalent) for m, o in rows)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
