#!/usr/bin/env python3
"""Put a handful of tracks in a simulator's client-library.db — and, optionally,
make them actually playable.

Not a fixture for correctness tests. It exists because the connect screen only
offers "Offline gebruiken" when `RoonClient.hasLocalLibrary` is true, so without
a few rows the UI walk can't get past the gate at all. Four albums is enough to
make the overview render its shelves and browse tiles with something in them.

WHY THE FEATURES AND THE AUDIO
`LocalPlayability` calls a track playable **iff it has an analysed feature row**
(every feature came from a walked file), and `RoonClient.resolveLocalPlayback`
then looks for a local file before it builds any URL. A seed of bare `tracks`
rows therefore renders a library you cannot play a note of: every play verb
filters everything out, the mini-bar never appears, and the player — the one
screen this whole app is about — stays unphotographable. So we also write
`track_audio_features` rows and drop a real audio file in the pinned-download
directory, which is exactly the "on a plane with downloads" tier.

The app must have run once already: it owns the schema and the migrations, and
this only inserts rows.

Usage: seed-demo-library.py <path-to-client-library.db> [--downloads DIR]
"""
import hashlib
import re
import shutil
import sqlite3
import subprocess
import sys
import unicodedata
from datetime import datetime, timezone

# (album, artist, year, [(title, seconds, bpm, camelot, energy, moods)])
ALBUMS = [
    ("Kind of Blue", "Miles Davis", 1959, [
        ("So What", 26, 136.0, "5A", 0.42, "kalm,nachtelijk"),
        ("Freddie Freeloader", 22, 148.0, "7B", 0.51, "swingend"),
        ("Blue in Green", 18, 62.0, "9A", 0.22, "melancholisch"),
        ("All Blues", 24, 156.0, "4A", 0.47, "kalm"),
        ("Flamenco Sketches", 20, 58.0, "2A", 0.19, "melancholisch"),
    ]),
    ("Brothers in Arms", "Dire Straits", 1985, [
        ("So Far Away", 28, 106.0, "8B", 0.55, "weemoedig"),
        ("Money for Nothing", 32, 122.0, "11B", 0.78, "energiek,rock"),
        ("Walk of Life", 21, 170.0, "9B", 0.81, "vrolijk"),
        ("Your Latest Trick", 25, 98.0, "6A", 0.44, "nachtelijk"),
    ]),
    ("Blue Lines", "Massive Attack", 1991, [
        ("Safe from Harm", 30, 90.0, "1A", 0.61, "broeierig"),
        ("Unfinished Sympathy", 34, 100.0, "10A", 0.58, "melancholisch,filmisch"),
        ("Daydreaming", 23, 96.0, "3A", 0.49, "dromerig"),
        ("Hymn of the Big Wheel", 27, 84.0, "12A", 0.36, "dromerig"),
    ]),
    # A deliberately long title: the marquee only moves when the text overflows,
    # so a library of short titles would photograph as "no marquee" and prove
    # nothing.
    ("Symphony No. 9", "Ludwig van Beethoven", 1824, [
        ("Symphony No. 9 in D minor, Op. 125: IV. Presto — Allegro assai (Ode an die Freude)",
         45, 88.0, "7A", 0.66, "verheven,filmisch"),
        ("Symphony No. 9 in D minor, Op. 125: II. Molto vivace",
         38, 160.0, "5B", 0.72, "verheven"),
    ]),
]

# ── The match key, ported from AudioAnalysis/TrackIdentity.swift ──────────────
# It is the join between the library and everything the analyser produced, so a
# key computed differently here would seed features that match no track at all —
# silently, since a missing join just reads as "not analysed yet".

_FEAT = re.compile(r"\s*[\(\[]\s*(feat|ft|featuring)\.?\s[^)\]]*[\)\]]", re.I)
_REMASTER = re.compile(
    r"\s*[\(\[]\s*(\d{4}\s+remaster(ed)?|remaster(ed)?\s+\d{4}|remaster(ed)?|"
    r"deluxe(\s+edition)?|super\s+deluxe|anniversary(\s+edition)?|"
    r"special(\s+edition)?|expanded(\s+edition)?|bonus\s+track|"
    r"single\s+version|album\s+version)\s*[\)\]]", re.I)
_TRACK_PREFIX = re.compile(r"^\s*(\d+-\d+|\d+\.)\s*")
_ARTIST_FEAT = re.compile(r"\s+(feat\.?|ft\.?|featuring)\s+.*$", re.I)


def normalise(text: str) -> str:
    folded = unicodedata.normalize("NFKD", text or "")
    folded = "".join(c for c in folded if not unicodedata.combining(c)).lower()
    out, last_space = [], False
    for ch in folded:
        if ch.isascii() and (ch.isalpha() or ch.isdigit()):
            out.append(ch)
            last_space = False
        elif not last_space:
            out.append(" ")
            last_space = True
    return "".join(out).strip()


def primary_artist(artist: str) -> str:
    s = _ARTIST_FEAT.sub("", artist or "")
    for sep in (",", ";", "/", "&"):
        if sep in s:
            s = s.split(sep, 1)[0]
    return s.strip()


def clean_title(title: str) -> str:
    return _REMASTER.sub("", _FEAT.sub("", _TRACK_PREFIX.sub("", title or "")))


def match_key(artist: str, title: str) -> str:
    return f"{normalise(primary_artist(artist))}\x1f{normalise(clean_title(title))}"


def pinned_filename(key: str, variant: str = "orig") -> str:
    """`LocalAudioCache.filename(forKey:variant:)` — sha256 of "key|variant"."""
    return hashlib.sha256(f"{key}|{variant}".encode()).hexdigest()


def write_audio(directory: str, name: str, seconds: int, hz: int) -> int:
    """A real, decodable m4a. AVPlayer refuses a stub, and a queue that won't
    start is a queue you can't photograph."""
    path = f"{directory}/{name}"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-f", "lavfi", "-i", f"sine=frequency={hz}:duration={seconds}",
         # `-f ipod` writes the M4A brand an actual download carries; a generic
         # mp4 brand is not what the analyser server hands out.
         "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-f", "ipod", path],
        check=True)
    import os
    return os.path.getsize(path)


def main() -> int:
    args = sys.argv[1:]
    downloads = None
    if "--downloads" in args:
        i = args.index("--downloads")
        downloads = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2

    con = sqlite3.connect(args[0])
    cur = con.cursor()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    have_ffmpeg = downloads and shutil.which("ffmpeg")
    if downloads and not have_ffmpeg:
        print("   ffmpeg ontbreekt — geen audio gezaaid, de speler blijft leeg", file=sys.stderr)
    if have_ffmpeg:
        import os
        os.makedirs(downloads, exist_ok=True)

    n = audio = 0
    for album, artist, year, tracks in ALBUMS:
        album_key = f"{artist}|{album}".lower()
        for title, seconds, bpm, camelot, energy, moods in tracks:
            n += 1
            key = match_key(artist, title)
            cur.execute(
                "INSERT OR REPLACE INTO tracks"
                " (id, title, artist, album, album_key, year, is_live, match_key, image_key, album_fp)"
                " VALUES (?,?,?,?,?,?,0,?,NULL,?)",
                (f"demo{n}", title, artist, album, album_key, year, key, album_key))
            # Without this row the track is not "locally playable" and every
            # play verb silently drops it.
            cur.execute(
                "INSERT OR REPLACE INTO track_audio_features"
                " (match_key, bpm, camelot, key_root, key_mode, energy, duration,"
                "  moods, synced_at, loudness)"
                " VALUES (?,?,?,?,?,?,?,?,?,?)",
                (key, bpm, camelot, camelot[:-1], "major", energy, float(seconds),
                 moods, now, -12.0))
            if have_ffmpeg:
                name = pinned_filename(key)
                size = write_audio(downloads, name, seconds, 180 + 20 * n)
                audio += 1
                # The downloads screen reads this table, not the directory.
                cur.execute(
                    "INSERT OR REPLACE INTO offline_tracks"
                    " (match_key, variant, title, artist, album, image_key, bytes, added_at)"
                    " VALUES (?,?,?,?,?,NULL,?,?)",
                    (key, "orig", title, artist, album, size, now))

    con.commit()
    total = cur.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
    feats = cur.execute("SELECT COUNT(*) FROM track_audio_features").fetchone()[0]
    print(f"   {n} demo-tracks gezaaid ({total} in de database, {feats} met features"
          + (f", {audio} speelbaar" if audio else "") + ")")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
