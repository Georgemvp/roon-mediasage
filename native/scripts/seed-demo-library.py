#!/usr/bin/env python3
"""Put a handful of tracks in a simulator's client-library.db.

Not a fixture for correctness tests — it exists because the connect screen only
offers "Offline gebruiken" when `RoonClient.hasLocalLibrary` is true, so without
a few rows the UI walk can't get past the gate at all. Four albums is enough to
make the overview render its shelves and browse tiles with something in them.

The app must have run once already: it owns the schema and the migrations, and
this only inserts rows.

Usage: seed-demo-library.py <path-to-client-library.db>
"""
import sqlite3
import sys

ALBUMS = [
    ("Kind of Blue", "Miles Davis", 1959,
     ["So What", "Freddie Freeloader", "Blue in Green", "All Blues", "Flamenco Sketches"]),
    ("Brothers in Arms", "Dire Straits", 1985,
     ["So Far Away", "Money for Nothing", "Walk of Life", "Your Latest Trick"]),
    ("Blue Lines", "Massive Attack", 1991,
     ["Safe from Harm", "Unfinished Sympathy", "Daydreaming", "Hymn of the Big Wheel"]),
    # A deliberately long title: the marquee only moves when the text overflows,
    # so a library of short titles would photograph as "no marquee" and prove
    # nothing.
    ("Symphony No. 9", "Ludwig van Beethoven", 1824,
     ["Symphony No. 9 in D minor, Op. 125: IV. Presto — Allegro assai (Ode an die Freude)",
      "Symphony No. 9 in D minor, Op. 125: II. Molto vivace"]),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    con = sqlite3.connect(sys.argv[1])
    cur = con.cursor()
    n = 0
    for album, artist, year, titles in ALBUMS:
        album_key = f"{artist}|{album}".lower()
        for title in titles:
            n += 1
            cur.execute(
                "INSERT OR REPLACE INTO tracks"
                " (id, title, artist, album, album_key, year, is_live, match_key, image_key, album_fp)"
                " VALUES (?,?,?,?,?,?,0,?,NULL,?)",
                (f"demo{n}", title, artist, album, album_key, year,
                 f"{artist}|{album}|{title}".lower(), album_key),
            )
    con.commit()
    total = cur.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
    print(f"   {n} demo-tracks gezaaid ({total} in de database)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
