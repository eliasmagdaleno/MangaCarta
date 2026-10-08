#!/usr/bin/env python3
"""Read-before / restore-after harness for the one live MAL write test.

`testLiveHorimiyaCompletionPushesProgress` moves progress on a *real* MyAnimeList
account (issue #93). This wraps that run so the account is put back exactly as it
was found:

    scripts/mal_live_write.py snapshot     # record the current list entry
    scripts/mal_live_write.py fire         # snapshot, run the test, restore
    scripts/mal_live_write.py restore      # put the recorded entry back

`fire` restores even when the test fails, which is the whole point: a half-finished
UI run is exactly the case that leaves the account moved.

The snapshot is written to `.mal-live-write/` (gitignored) rather than stdout so a
crashed shell does not lose the only record of the pre-run value.

The token is the app's own (issue #360). MAL will not approve an OAuth request made
outside the app's sign-in sheet, so the harness launches the seeded simulator's
*Debug* build with `-debug-export-mal-token`; the app writes its current access token
to its `tmp/`, and the harness reads that file and deletes it at once. The simulator
must be signed in to MAL. Set `MAL_ACCESS_TOKEN` to use another token instead.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.myanimelist.net/v2"
HORIMIYA_ID = 42451
# The seeded simulator, by id: a name matches every simulator of that model (worker
# clones included), and xcodebuild refuses an ambiguous destination.
SIMULATOR = "ADDAB2F8-38C7-4D44-97EA-4E98281CF691"
BUNDLE_ID = "Elias-Magdaleno.Manga-Reader"
# Must match `MALDebugTokenExport.flag` and `.fileName`.
EXPORT_FLAG = "-debug-export-mal-token"
EXPORT_FILE = "mal-debug-token.json"
EXPORT_TIMEOUT = 30
SNAPSHOT_DIR = Path(__file__).resolve().parent.parent / ".mal-live-write"

# Every writable field of a manga list entry. Restoring a subset would silently
# flatten the others, so the snapshot round-trips all of them.
WRITABLE = [
    "status",
    "is_rereading",
    "score",
    "num_volumes_read",
    "num_chapters_read",
    "priority",
    "num_times_reread",
    "reread_value",
    "tags",
    "comments",
]

TEST = (
    "MangaCartaUITests/MangaCartaUITests/"
    "testLiveHorimiyaCompletionPushesProgress"
)


_token = None


def token() -> str:
    global _token
    if _token is None:
        _token = os.environ.get("MAL_ACCESS_TOKEN") or token_from_simulator()
    return _token


def simctl(*args: str, check: bool = True) -> str:
    result = subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"simctl {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def token_from_simulator() -> str:
    """The signed-in app's access token, via its DEBUG-only export (issue #360)."""
    simctl("boot", SIMULATOR, check=False)  # already booted is fine
    simctl("bootstatus", SIMULATOR)
    # Before the export launch: the container moves on every reinstall.
    container = Path(simctl("get_app_container", SIMULATOR, BUNDLE_ID, "data"))
    exported = container / "tmp" / EXPORT_FILE
    exported.unlink(missing_ok=True)
    simctl("terminate", SIMULATOR, BUNDLE_ID, check=False)  # not running is fine
    simctl("launch", SIMULATOR, BUNDLE_ID, EXPORT_FLAG)
    try:
        deadline = time.monotonic() + EXPORT_TIMEOUT
        while not exported.exists():
            if time.monotonic() > deadline:
                sys.exit(
                    f"the app wrote no token in {EXPORT_TIMEOUT}s. The installed build must be "
                    "a Debug build that has the export (any `xcodebuild test` run of main since "
                    "#360 installs one), or set MAL_ACCESS_TOKEN."
                )
            time.sleep(0.5)
        payload = json.loads(exported.read_text())
    finally:
        # It is account credentials: it should outlive this read by as little as possible.
        exported.unlink(missing_ok=True)
        simctl("terminate", SIMULATOR, BUNDLE_ID, check=False)
    if payload.get("error"):
        sys.exit(
            f"the app has no usable MAL token ({payload['error']}). "
            "Sign in to MAL in the app's Settings on the seeded simulator first."
        )
    print("token: read from the app on the seeded simulator")
    return payload["access_token"]


def call(method: str, path: str, *, query=None, form=None, retried=False):
    url = f"{API}/{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    if data is not None:
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        # The test run between snapshot and restore can refresh the app's token. Read it
        # again once, so a refreshed token cannot strand the account half-restored.
        if error.code == 401 and not retried and not os.environ.get("MAL_ACCESS_TOKEN"):
            global _token
            _token = None
            return call(method, path, query=query, form=form, retried=True)
        detail = error.read().decode(errors="replace")
        sys.exit(f"MAL {method} {path} failed: {error.code} {detail}")


def snapshot_path(manga_id: int) -> Path:
    return SNAPSHOT_DIR / f"snapshot-{manga_id}.json"


def do_snapshot(manga_id: int) -> dict:
    payload = call("GET", f"manga/{manga_id}", query={"fields": "my_list_status"})
    entry = payload.get("my_list_status")
    record = {
        "manga_id": manga_id,
        "title": payload.get("title"),
        # A missing entry is not the same as an empty one: restoring it means
        # deleting the entry the test created, not writing zeroes over it.
        "existed": entry is not None,
        "entry": entry,
    }
    SNAPSHOT_DIR.mkdir(exist_ok=True)
    path = snapshot_path(manga_id)
    path.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    if entry is None:
        print(f"snapshot: no list entry for {record['title']} ({manga_id}) -> {path}")
    else:
        print(
            f"snapshot: {record['title']} ({manga_id}) at "
            f"{entry.get('num_chapters_read')} chapters, status "
            f"{entry.get('status')!r} -> {path}"
        )
    return record


def do_restore(manga_id: int) -> None:
    path = snapshot_path(manga_id)
    if not path.exists():
        sys.exit(f"no snapshot at {path}; refusing to guess the pre-run value")
    record = json.loads(path.read_text())

    if not record["existed"]:
        call("DELETE", f"manga/{manga_id}/my_list_status")
        print(f"restore: deleted the entry the run created for {manga_id}")
        return

    entry = record["entry"]
    form = {}
    for field in WRITABLE:
        if field not in entry:
            continue
        value = entry[field]
        if isinstance(value, bool):
            value = "true" if value else "false"
        elif isinstance(value, list):
            value = ",".join(str(item) for item in value)
        form[field] = str(value)

    confirmed = call("PATCH", f"manga/{manga_id}/my_list_status", form=form)
    print(
        f"restore: {record['title']} ({manga_id}) back to "
        f"{confirmed.get('num_chapters_read')} chapters, status "
        f"{confirmed.get('status')!r}"
    )


def do_fire(manga_id: int) -> int:
    if manga_id != HORIMIYA_ID:
        sys.exit(
            f"`fire` runs the Horimiya-specific test, so it can only guard {HORIMIYA_ID}. "
            "Use `snapshot`/`restore` around your own run for another title."
        )
    do_snapshot(manga_id)
    command = [
        "xcodebuild",
        "-scheme", "MangaCarta",
        "-destination", f"id={SIMULATOR}",
        # Serial, on the seeded device itself. A parallel run executes on a clone, which
        # need not hold the MAL sign-in or the unread chapter this test depends on.
        "-parallel-testing-enabled", "NO",
        "test",
        f"-only-testing:{TEST}",
    ]
    # The runner only sees this as a *shell* variable, and `xcodebuild` strips the
    # `TEST_RUNNER_` prefix on the way in. Passing it as a build-setting argument
    # looks right and silently does nothing (issue #93).
    env = dict(os.environ, TEST_RUNNER_MAL_LIVE_WRITE="1")
    print("fire: " + " ".join(command))
    result = subprocess.run(command, env=env, cwd=SNAPSHOT_DIR.parent, check=False)
    print(f"fire: xcodebuild exited {result.returncode}; restoring regardless")
    do_restore(manga_id)
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["snapshot", "restore", "fire"])
    parser.add_argument("--manga-id", type=int, default=HORIMIYA_ID)
    args = parser.parse_args()

    if args.action == "snapshot":
        do_snapshot(args.manga_id)
    elif args.action == "restore":
        do_restore(args.manga_id)
    else:
        return do_fire(args.manga_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
