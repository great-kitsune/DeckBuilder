"""Exercise a release-mode install -r on a disposable, rooted CI emulator."""
import hashlib
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

APP = "com.greatkitsune.deck_builder"
DATA = "/data/user/0/" + APP
PHOTO = bytes([1, 2, 3, 4])
CACHE = DATA + "/cache/card_images/" + hashlib.sha256(b"test-image|1").hexdigest()


def adb(*args, check=True):
    return subprocess.run(["adb", *args], check=check, capture_output=True)


def start():
    adb("shell", "am", "start", "-W", "-n", APP + "/.MainActivity")


def snapshot(remote, local):
    # The app is stopped for the authoritative before/after checks.
    for suffix in ["", "-wal", "-shm"]:
        target = Path(str(local) + suffix)
        target.unlink(missing_ok=True)
        adb("pull", remote + suffix, str(target), check=not suffix)


def run(old, new, tmp):
    adb("root")
    adb("wait-for-device")
    adb("install", old)
    start()
    for _ in range(60):
        found = adb("shell", "find", DATA, "-name", "catalog.sqlite").stdout.decode().strip()
        if found:
            break
        time.sleep(1)
    else:
        raise RuntimeError("The old app did not create its database")
    adb("shell", "am", "force-stop", APP)
    local = tmp / "catalog.sqlite"
    snapshot(found, local)
    with sqlite3.connect(local) as db:
        assert db.execute("pragma user_version").fetchone() == (0,)
        db.execute("INSERT INTO decks VALUES(1,'Upgrade fixture')")
        db.execute("""INSERT INTO spoiler_cards VALUES('sp','Test','test',1,1,'',
            '{"uuid":"sp","name":"Test"}',?)""", (PHOTO,))
        db.execute("""INSERT INTO spoiler_editions VALUES('pr','sp','SET','001','1',
            '{"uuid":"pr"}',0)""")
        db.execute("INSERT INTO deck_entries VALUES(1,'main','sp','pr',3)")
        db.execute("INSERT OR REPLACE INTO metadata VALUES('thumbnailGrid','1'),('updated','preserve-this-date')")
    db.execute("pragma wal_checkpoint(truncate)")
    db.close()
    with local.open("rb") as stream:
        subprocess.run(["adb", "shell", "-T", "cat > " + found], stdin=stream, check=True)
    adb("shell", "rm", "-f", found + "-wal", found + "-shm")
    adb("shell", f"mkdir -p {os.path.dirname(CACHE)} && echo retained > {CACHE}")
    adb("install", "-r", new)
    start()
    for _ in range(45):
        snapshot(found, local)
        try:
            con = sqlite3.connect(local)
            try:
                version = con.execute("pragma user_version").fetchone()[0]
            finally:
                con.close()
            if version == 1:
                break
        except sqlite3.DatabaseError:
            pass
        time.sleep(1)
    else:
        raise RuntimeError("The upgraded app did not open and migrate the original DB")
    adb("shell", "am", "force-stop", APP)
    snapshot(found, local)
    with sqlite3.connect(local) as db:
        assert db.execute("pragma integrity_check").fetchone() == ("ok",)
        assert db.execute("SELECT name FROM decks").fetchall() == [("Upgrade fixture",)]
        assert db.execute("SELECT zone,card,edition,quantity FROM deck_entries").fetchone() == ("main", "sp", "pr", 3)
        assert db.execute("SELECT photo FROM spoiler_cards").fetchone() == (PHOTO,)
        assert db.execute("SELECT value FROM metadata WHERE key='thumbnailGrid'").fetchone() == ("1",)
        assert db.execute("SELECT value FROM metadata WHERE key='updated'").fetchone() == ("preserve-this-date",)
    assert adb("shell", "cat", CACHE).stdout.strip() == b"retained"
    print("In-place upgrade retained the deck, edition, quantity, spoiler, settings, DB date and cache.")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        run(sys.argv[1], sys.argv[2], Path(directory))
