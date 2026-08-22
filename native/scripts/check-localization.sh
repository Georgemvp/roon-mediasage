#!/usr/bin/env bash
# Report LS()/LT() dot-keys used in RoonSageUI that are missing from a string
# catalogue. A missing key is not a compile error — SwiftUI silently renders the
# key itself, so "localNowPlaying.nothingPlaying" shows up in the UI as literal
# text. Found the hard way on 2026-08-10 from a user screenshot.
#
# Usage:  native/scripts/check-localization.sh [--strict]
#         --strict  exit 1 when anything is missing (for a future CI gate; the
#                   backlog must be empty first — see docs/STATE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI="$ROOT/native/RoonSage/Sources/RoonSageUI"
CORE="$ROOT/native/RoonSage/Sources/RoonSageCore"
RES="$UI/Resources"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Only dot-keys: bare-literal LS("Speel alles") calls are a separate, deliberate
# migration backlog (see the header of Localization.swift), not a rendering bug.
grep -rhoE '\bL[ST]\("[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+"\)' --include='*.swift' "$UI" \
  | sed -E 's/^L[ST]\("//; s/"\)$//' | sort -u > "$tmp/used"

# Core cannot call LS (the catalogue is a RoonSageUI resource), so its own error
# messages go through CoreStrings.s/f with an injected translator. Those keys are
# just as able to go missing, and the gate was blind to them until now.
#
# Python, not grep: the key routinely lands on the line AFTER the call, and a
# line-oriented match silently found only 15 of 22 keys when this was written —
# a checker with a blind spot is worse than no checker.
python3 - "$CORE" >> "$tmp/used" <<'PYEOF'
import pathlib, re, sys
keys = set()
for path in pathlib.Path(sys.argv[1]).rglob("*.swift"):
    for m in re.finditer(r'CoreStrings\.[sf]\(\s*"([a-zA-Z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)+)"',
                         path.read_text(encoding="utf-8")):
        keys.add(m.group(1))
print("\n".join(sorted(keys)))
PYEOF
sort -u -o "$tmp/used" "$tmp/used"

status=0
for lang in nl en; do
    grep -hoE '^"[^"]+"' "$RES/$lang.lproj/Localizable.strings" | tr -d '"' | sort -u > "$tmp/$lang"
    missing=$(comm -23 "$tmp/used" "$tmp/$lang")
    count=$(printf '%s' "$missing" | grep -c . || true)
    echo "── $lang.lproj: $count missing of $(wc -l < "$tmp/used" | tr -d ' ') used keys"
    if [[ -n "$missing" ]]; then
        printf '%s\n' "$missing" | sed 's/^/     /'
        status=1
    fi
done

# Interpolated keys: LS("Bibliotheek (\(count))"). These CANNOT resolve — the
# value is baked into the key, so the lookup always misses and SwiftUI renders
# the key itself, which is the Dutch literal. On an English phone that shows as
# one Dutch line between English ones; the app's own main heading did exactly
# that until a screenshot from native/scripts/ui-verify.sh caught it.
#
# Not gated yet: there are ~70, and a gate that fails from day one gets ignored.
# Reported so the number can only go down, and so a new one is visible in the
# diff of whoever adds it. The fix is always the same shape:
#   String(format: LS("some.key"), value)   met %d / %@ in de catalogus.
interp=$(grep -rhoE '\bL[ST]\("[^"]*\\\([^"]*"' --include='*.swift' "$UI" | sort -u || true)
interp_count=$(printf '%s' "$interp" | grep -c . || true)
echo "── interpolated keys (kunnen nooit oplossen, vallen terug op het Nederlands): $interp_count"
if [[ -n "${VERBOSE:-}" && -n "$interp" ]]; then
    printf '%s\n' "$interp" | sed 's/^/     /'
fi

# Orphans: defined but no longer referenced. Harmless at runtime, but they hide
# real drift — two of them (from a deleted component) are what made the missing
# count not add up when this script was first written.
orphans=$(comm -13 "$tmp/used" "$tmp/nl" || true)
orphan_count=$(printf '%s' "$orphans" | grep -c . || true)
echo "── orphaned keys (defined, never used): $orphan_count"
[[ -n "$orphans" ]] && printf '%s\n' "$orphans" | sed 's/^/     /'

# Keys defined in one catalogue but not the other — a language falling back
# silently to the key is the same failure in a different disguise.
if ! diff -q "$tmp/nl" "$tmp/en" >/dev/null; then
    echo "── catalogues out of sync (nl vs en):"
    diff "$tmp/nl" "$tmp/en" | sed 's/^/     /'
    status=1
fi

# Lowercase \uXXXX escapes. Apple's .strings format does NOT understand them
# (only \UXXXX with a capital U), so the backslash is eaten and the digits are
# rendered as text: "Couldn’t" reached the phone as "Couldnu2019t", live on
# a user's Now Playing screen on 2026-08-11. Nothing in the build or the tests
# notices — the string is present and non-empty, it just reads as gibberish.
# This repo's convention is literal UTF-8 characters, so flag any escape at all.
for lang in nl en; do
    bad=$(grep -nE '\\u[0-9A-Fa-f]{4}' "$RES/$lang.lproj/Localizable.strings" || true)
    if [[ -n "$bad" ]]; then
        echo "── $lang.lproj: \\uXXXX escapes (use the literal character):"
        printf '%s\n' "$bad" | sed 's/^/     /'
        status=1
    fi
done

if [[ "${1:-}" == "--strict" ]]; then exit $status; fi
exit 0
