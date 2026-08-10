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
RES="$UI/Resources"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Only dot-keys: bare-literal LS("Speel alles") calls are a separate, deliberate
# migration backlog (see the header of Localization.swift), not a rendering bug.
grep -rhoE '\bL[ST]\("[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+"\)' --include='*.swift' "$UI" \
  | sed -E 's/^L[ST]\("//; s/"\)$//' | sort -u > "$tmp/used"

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

if [[ "${1:-}" == "--strict" ]]; then exit $status; fi
exit 0
