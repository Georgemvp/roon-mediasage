#!/usr/bin/env python3
"""Pull the XCTAttachment screenshots out of an .xcresult bundle.

A green test run whose evidence stays locked in a result bundle is no use for a
judgement call, and `xcresulttool get --format json` changed shape across Xcode
versions. This walks whatever shape it finds instead of assuming one, and falls
back to the legacy object graph when the modern `--test-results` route is absent.

Usage: extract-screenshots.py <result.xcresult> <output-dir>
"""
import json
import pathlib
import re
import subprocess
import sys


def xcresult(args):
    out = subprocess.run(["xcrun", "xcresulttool", *args],
                         capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else ""


def walk(node, found):
    """Collect every {name, payload-id} pair, whatever nesting it hides in."""
    if isinstance(node, dict):
        if node.get("_type", {}).get("_name") == "ActionTestAttachment":
            ref = node.get("payloadRef", {}).get("id", {}).get("_value")
            name = node.get("name", {}).get("_value") or node.get("filename", {}).get("_value")
            if ref and name:
                found.append((name, ref))
        for v in node.values():
            walk(v, found)
    elif isinstance(node, list):
        for v in node:
            walk(v, found)
    return found


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    bundle, outdir = sys.argv[1], pathlib.Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    # Xcode 16+ can export attachments in one go; use it when it's there.
    direct = subprocess.run(
        ["xcrun", "xcresulttool", "export", "attachments",
         "--path", bundle, "--output-path", str(outdir)],
        capture_output=True, text=True)
    if direct.returncode == 0 and any(outdir.iterdir()):
        rename_to_attachment_names(outdir)
        return 0
    return legacy(bundle, outdir)


def rename_to_attachment_names(outdir: pathlib.Path) -> None:
    """`export attachments` writes UUID-suffixed names; the manifest holds the
    readable ones. Without this you get 00-foo_0_5CA2F60E-….png, which is a file
    list you have to decode instead of read."""
    manifest = outdir / "manifest.json"
    if manifest.exists():
        for entry in json.loads(manifest.read_text()):
            for att in entry.get("attachments", []):
                src = outdir / att.get("exportedFileName", "")
                label = att.get("suggestedHumanReadableName") or att.get("name") or ""
                if src.exists() and label:
                    src.rename(outdir / f"{pathlib.Path(label).stem}.png")
        manifest.unlink()
    # Belt and braces: anything still carrying the "_0_<uuid>" tail gets it cut,
    # so a manifest shape we don't recognise still leaves readable filenames.
    for f in outdir.glob("*.png"):
        stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", f.stem)
        if stem != f.stem:
            f.rename(outdir / f"{stem}.png")


def legacy(bundle: str, outdir: pathlib.Path) -> int:
    # Legacy route: read the object graph and fetch each payload by id.
    root = xcresult(["get", "--legacy", "--format", "json", "--path", bundle])
    if not root:
        print("   (geen schermafdrukken gevonden — xcresulttool gaf niets terug)")
        return 0
    refs = []
    tests = json.loads(root)
    walk(tests, refs)
    seen = set()
    for name, ref in refs:
        if ref in seen:
            continue
        seen.add(ref)
        data = subprocess.run(
            ["xcrun", "xcresulttool", "get", "--legacy", "--path", bundle, "--id", ref],
            capture_output=True)
        if data.returncode == 0 and data.stdout:
            (outdir / f"{pathlib.Path(name).stem}.png").write_bytes(data.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
