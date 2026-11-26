"""Self-test for scripts/mutate.py: python3 -I -m unittest discover -s scripts -p 'test_mutate.py'

Hermetic: each test builds a throwaway git repo with a tiny node:test "Worker" and drives
the real script against it, so the Worker runner, the safety rails and the table are
exercised end to end. Needs git and node; no simulator. The Swift runner's proof is a run
on real code (scripts/mutate-examples/updates-timeline.json), recorded in the PR.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutate.py")

LIB = """export function clamp(x, lo, hi) {
  return Math.min(Math.max(x, lo), hi);
}
export const UNUSED = 1;
export function slow() {
  return 1;
}
"""

TESTS = """import { test } from "node:test";
import assert from "node:assert/strict";
import { clamp, slow } from "../src/lib.mjs";

test("clamp keeps values in range", () => {
  assert.equal(clamp(5, 0, 3), 3);
  assert.equal(clamp(-1, 0, 3), 0);
});

test("slow is slow", async () => {
  await new Promise((r) => setTimeout(r, Number(process.env.SLOW_MS || 0)));
  assert.equal(slow(), 1);
});
"""


class MutateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.realpath(self.tmp.name)
        w = os.path.join(self.root, "server", "analytics-worker")
        os.makedirs(os.path.join(w, "src"))
        os.makedirs(os.path.join(w, "test"))
        self.write("server/analytics-worker/package.json",
                   json.dumps({"type": "module", "scripts": {"test": 'node --test "test/*.test.mjs"'}}))
        self.write("server/analytics-worker/src/lib.mjs", LIB)
        self.write("server/analytics-worker/test/lib.test.mjs", TESTS)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "init")
        self.lib = os.path.join(self.root, "server/analytics-worker/src/lib.mjs")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        with open(os.path.join(self.root, rel), "w") as f:
            f.write(text)

    def git(self, *args):
        subprocess.run(["git", "-C", self.root, *args], check=True)

    def mutations(self, *entries):
        path = os.path.join(self.root, "m.json")
        with open(path, "w") as f:
            json.dump({"runner": "worker", "mutations": [
                dict({"file": "server/analytics-worker/src/lib.mjs", "tests": ["test/lib.test.mjs"]}, **e)
                for e in entries]}, f)
        return path

    def run_script(self, mfile, *extra, env=None):
        return subprocess.run([sys.executable, "-I", SCRIPT, mfile, *extra], cwd=self.root,
                              capture_output=True, text=True, env=env)

    def lib_text(self):
        with open(self.lib) as f:
            return f.read()

    def test_killed_survived_error_and_restored(self):
        m = self.mutations(
            {"id": "K", "description": "no upper bound", "old": "), hi);", "new": "), Infinity);"},
            {"id": "S", "description": "unused constant", "old": "UNUSED = 1", "new": "UNUSED = 2"},
            {"id": "E1", "description": "syntax", "old": "export function slow() {", "new": "export function slow() {{"},
            {"id": "E2", "description": "missing", "old": "nowhere", "new": "x"},
            {"id": "E3", "description": "ambiguous", "old": "export", "new": "x"},
            {"id": "E4", "description": "no test matches", "old": "UNUSED = 1", "new": "UNUSED = 3",
             "tests": ["test/lib.test.mjs", "no such test name"]},
        )
        # E4's selectors match nothing, so the baseline for its group is not green either:
        # run it separately below.
        p = self.run_script(m, "--only", "K,S,E1,E2,E3")
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertIn("| K | no upper bound | KILLED | `clamp keeps values in range` |", p.stdout)
        self.assertIn("| S | unused constant | SURVIVED |  |", p.stdout)
        self.assertIn("| E1 | syntax | ERROR: syntax error", p.stdout)
        self.assertIn("| E2 | missing | ERROR: old text not found |", p.stdout)
        self.assertIn("| E3 | ambiguous | ERROR: old text matches 3 times, must match once |", p.stdout)
        self.assertIn("1 killed, 1 survived, 0 equivalent, 3 error (of 5).", p.stdout)
        self.assertEqual(self.lib_text(), LIB)

        p = self.run_script(m, "--only", "E4")
        self.assertEqual(p.returncode, 2)
        self.assertIn("baseline is not green", p.stderr)
        self.assertIn("no test matched", p.stderr)

    def test_equivalent_survivor_passes(self):
        m = self.mutations({"id": "Q", "description": "unused", "old": "UNUSED = 1", "new": "UNUSED = 2",
                            "equivalent": "nothing reads it"})
        p = self.run_script(m)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("SURVIVED (equivalent: nothing reads it)", p.stdout)

    def test_red_baseline_stops_before_mutating(self):
        self.write("server/analytics-worker/test/lib.test.mjs", TESTS.replace("clamp(5, 0, 3), 3", "clamp(5, 0, 3), 4"))
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qam", "red")
        m = self.mutations({"id": "K", "description": "d", "old": "), hi);", "new": "), Infinity);"})
        p = self.run_script(m)
        self.assertEqual(p.returncode, 2)
        self.assertIn("baseline is not green", p.stderr)
        self.assertNotIn("| K |", p.stdout)

    def test_refuses_dirty_target(self):
        self.write("server/analytics-worker/src/lib.mjs", LIB + "// work in progress\n")
        m = self.mutations({"id": "K", "description": "d", "old": "), hi);", "new": "), Infinity);"})
        p = self.run_script(m)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("uncommitted changes", p.stderr)
        self.assertEqual(self.lib_text(), LIB + "// work in progress\n")

    def test_ctrl_c_mid_mutation_restores(self):
        m = self.mutations({"id": "K", "description": "d", "old": "), hi);", "new": "), Infinity);"})
        env = dict(os.environ, SLOW_MS="4000")
        proc = subprocess.Popen([sys.executable, "-I", SCRIPT, m], cwd=self.root, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 30
        while self.lib_text() == LIB and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertNotEqual(self.lib_text(), LIB, "mutation was never applied")
        proc.send_signal(signal.SIGINT)
        out, err = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 130, err)
        self.assertIn("interrupted - files restored", err)
        self.assertEqual(self.lib_text(), LIB)

    def test_sigkill_leftover_is_recovered_by_next_run(self):
        m = self.mutations({"id": "K", "description": "d", "old": "), hi);", "new": "), Infinity);"})
        env = dict(os.environ, SLOW_MS="4000")
        proc = subprocess.Popen([sys.executable, "-I", SCRIPT, m], cwd=self.root, env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 30
        while self.lib_text() == LIB and time.monotonic() < deadline:
            time.sleep(0.05)
        proc.kill()  # no finally runs: the mutation stays on disk
        proc.wait()
        self.assertNotEqual(self.lib_text(), LIB)
        p = self.run_script(m, "--check")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("left mutated by an interrupted run", p.stderr)
        self.assertEqual(self.lib_text(), LIB)

    def test_bad_file_is_a_usage_error(self):
        path = os.path.join(self.root, "bad.json")
        with open(path, "w") as f:
            json.dump({"mutations": [{"id": "A", "description": "d", "file": "x", "old": "a", "new": "b",
                                      "tests": ["t"]}]}, f)
        p = self.run_script(path)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("runner must be one of", p.stderr)


if __name__ == "__main__":
    unittest.main()
