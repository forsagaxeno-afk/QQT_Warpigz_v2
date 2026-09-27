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
        "docs/GUIDE_EN.md": "docs/GUIDE_EN.md"}
SKIP = {".gitignore", "Thumbs.db", ".DS_Store"}
# Placeholder files that keep otherwise empty runtime folders in the package.
KEEP = ".keep"
# QQT_Warpigz_v3: files the plugins generate on the user's machine never ship:
# HelltideRevamped's learned chest spots / fence / stats, and WarRoom's
# dashboard data, persisted totals and local server state (access token, stop flag).
GENERATED = ("HelltideRevamped/learned/*.txt", "HelltideRevamped/learned/*.tmp",
             "HelltideRevamped/dashboard/hr_data.js", "HelltideRevamped/dashboard/*.tmp",
             "WarRoom/dashboard/suite_data.js", "WarRoom/dashboard/hr_data.js",
             "WarRoom/dashboard/*.tmp", "WarRoom/data/*",
             "WarRoom/server/.dashboard-token", "WarRoom/server/stop.flag",
             "WarRoom/*.tmp", "WarRoom/*.log")


def ships(rel):
    """True when the repository file at `rel` (a POSIX path relative to the repo root) goes into the zip."""
    path = PurePosixPath(rel)
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
