"""Build the installable release package and its release notes.

Usage: python3 audit/build_release.py [--out dist]
Creates <out>/QQT_Warpigz_v2-vX.Y.Z.zip with the plugin folders listed in versions.json under
scripts/ (the only folders users copy into QQT's scripts directory) plus the
user documents, and <out>/RELEASE_NOTES.md from the matching CHANGELOG entry.
Used by .github/workflows/release.yml; runs locally the same way.
"""
import argparse
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DOCS = {"README.md": "README.md", "CHANGELOG.md": "CHANGELOG.md", "AUDIT.md": "AUDIT.md",
        "CREDITS.md": "CREDITS.md", "audit/LIVE_CHECKLIST.md": "LIVE_CHECKLIST.md",
        "docs/INSTALL_RU.txt": "УСТАНОВКА_RU.txt"}
SKIP = {".gitignore", "Thumbs.db", ".DS_Store"}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", default="dist")
args = parser.parse_args()
version = (ROOT / "VERSION").read_text().strip()
manifest = json.loads((ROOT / "versions.json").read_text())
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
name = f"QQT_Warpigz_v2-v{version}"
package = out / f"{name}.zip"
with zipfile.ZipFile(package, "w", zipfile.ZIP_DEFLATED) as archive:
    for folder in manifest["components"]:
        for path in sorted((ROOT / folder).rglob("*")):
            if path.is_file() and path.name not in SKIP and "__pycache__" not in path.parts:
                archive.write(path, f"{name}/scripts/{path.relative_to(ROOT).as_posix()}")
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
