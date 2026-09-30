"""Build the installable release package and its release notes.

Usage: python3 audit/build_release.py [--out dist]
Creates <out>/QQT_Warpigz_v3-vX.Y.Z.zip with the plugin folders listed in versions.json under
scripts/ (the only folders users copy into QQT's scripts directory) plus the
user documents, and <out>/RELEASE_NOTES.md from the matching CHANGELOG entry.
Used by .github/workflows/release.yml; runs locally the same way.
`import build_release` exposes ships(relative_path) without building anything.
"""
import argparse
import fnmatch
import json
from pathlib import PurePosixPath, Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DOCS = {"README.md": "README.md", "CHANGELOG.md": "CHANGELOG.md", "AUDIT.md": "AUDIT.md",
        "CREDITS.md": "CREDITS.md", "audit/LIVE_CHECKLIST.md": "LIVE_CHECKLIST.md",
        "docs/INSTALL_RU.txt": "УСТАНОВКА_RU.txt",
        "docs/GUIDE_EN.md": "docs/GUIDE_EN.md",
        # QQT_Warpigz_v3 owner-build: the Russian note for the build without Rosie.
        "docs/OWNER_BUILD_RU.txt": "OWNER_BUILD_RU.txt"}
SKIP = {".gitignore", "Thumbs.db", ".DS_Store", "NOTES.md"}  # NOTES.md: session notes, not for players
# Placeholder files that keep otherwise empty runtime folders in the package.
KEEP = ".keep"
# QQT_Warpigz_v3: files the plugins generate on the user's machine never ship:
# HelltideRevamped's learned chest spots / fence / stats and dashboard data.
GENERATED = ("HelltideRevamped/learned/*.txt", "HelltideRevamped/learned/*.tmp",
             "HelltideRevamped/dashboard/hr_data.js", "HelltideRevamped/dashboard/*.tmp",
             "ArkhamAsylum/back_portals.txt")  # QQT_Warpigz_v3 3.3.13: Arkham back-portal memory
# QQT_Warpigz_v3 3.3.6: repository folders that are never part of the package:
# parked plugins (archive/, e.g. WarRoom), developer tools (tools/ApiProbe),
# the audit and test tooling, the documents (shipped only through DOCS) and CI.
NEVER_SHIP = {"archive", "tools", "audit", "docs", "assets", ".github", "dist"}


def ships(rel):
    """True when the repository file at `rel` (a POSIX path relative to the repo root) goes into the zip."""
    path = PurePosixPath(rel)
    if path.parts and path.parts[0] in NEVER_SHIP:
        return False
    if path.name in SKIP or "__pycache__" in path.parts:
        return False
    if path.name == KEEP:
        return True
    return not any(fnmatch.fnmatch(rel, pattern) for pattern in GENERATED)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="dist")
    args = parser.parse_args()
    version = (ROOT / "VERSION").read_text().strip()
    manifest = json.loads((ROOT / "versions.json").read_text())
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    name = f"QQT_Warpigz_v3-v{version}"
    package = out / f"{name}.zip"
    for folder in manifest["components"]:
        # Only the plugin folders listed in versions.json ship, each a top-level folder.
        if folder in NEVER_SHIP or "/" in folder or not (ROOT / folder / "main.lua").is_file():
            raise SystemExit(f"versions.json component is not a shippable plugin folder: {folder}")
    with zipfile.ZipFile(package, "w", zipfile.ZIP_DEFLATED) as archive:
        for folder in manifest["components"]:
            for path in sorted((ROOT / folder).rglob("*")):
                rel = path.relative_to(ROOT).as_posix()
                if path.is_file() and ships(rel):
                    archive.write(path, f"{name}/scripts/{rel}")
        for source, target in DOCS.items():
            archive.write(ROOT / source, f"{name}/{target}")

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    match = re.search(rf"^## \[{re.escape(version)}\].*?$(.*?)(?=^## \[|\Z)", changelog, re.S | re.M)
    body = match.group(1).strip() if match else "See CHANGELOG.md."
    rows = "\n".join(f"| `{folder}` | {v} |" for folder, v in manifest["components"].items())
    notes = (f"{body}\n\n## Install\n\nDownload `{name}.zip` and copy **only the {len(manifest['components'])} folders inside `scripts/`** "
             f"into QQT's scripts directory (see `УСТАНОВКА_RU.txt` / README).\n\n| Folder | Version |\n| --- | --- |\n{rows}\n")
    (out / "RELEASE_NOTES.md").write_text(notes, encoding="utf-8")
    print(f"Built {package} and {out / 'RELEASE_NOTES.md'}")


if __name__ == "__main__":
    main()
