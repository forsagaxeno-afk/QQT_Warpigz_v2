"""Check bundle/component versions and release notes; optionally compare a Git base."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base", help="Previous release tag/commit for version-bump checks")
args = parser.parse_args()
manifest = json.loads((ROOT / "versions.json").read_text())
version = (ROOT / "VERSION").read_text().strip()
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def semver(value):
    # X.Y.Z, or a pre-release X.Y.Z-rc.N (released as a private draft for
    # testing); a pre-release sorts before its final version.
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-rc\.(\d+))?", value)
    if not match:
        errors.append(f"Invalid release version: {value}")
        return (-1, -1, -1, -1)
    major, minor, patch, rc = match.groups()
    return (int(major), int(minor), int(patch), int(rc) if rc else 1 << 30)


semver(version)
require(version == manifest["version"], "VERSION and versions.json disagree")
require(manifest["project"] == "QQT_Warpigz_v3", "Unexpected project name")
readme = (ROOT / "README.md").read_text()
changelog = (ROOT / "CHANGELOG.md").read_text()
require(f"v{version}" in readme, "README is missing the current bundle version")
require(f"## [{version}]" in changelog, "Current release is missing from CHANGELOG.md")
require("@ZEWX" in readme and "LONG LIVE LEGEND" in readme, "Original credits missing")

for folder, component_version in manifest["components"].items():
    semver(component_version)
    require((ROOT / folder / "main.lua").is_file(), f"Missing plugin entrypoint: {folder}")
    if folder == "Reaper":
        source = (ROOT / folder / "main.lua").read_text()
        require(f"v{component_version}" in source, f"Reaper displayed version mismatch")
    elif folder == "Rosie":
        source = (ROOT / folder / "rosie" / "controller.lua").read_text()
        require(f"s.version='{component_version}'" in source, f"Rosie displayed version mismatch")
    else:
        gui = "silent_raven/gui.lua" if folder.startswith("SilentRaven") else "gui.lua"
        path = ROOT / folder / gui
        source = path.read_text() if path.is_file() else ""
        require(path.is_file(), f"Missing {folder}/{gui}")
        match = re.search(r"local (?:plugin_version|version)\s*=\s*['\"](?:WarPigz )?v?([^'\"]+)", source)
        require(bool(match) and match[1] == component_version, f"GUI version mismatch: {folder}")
    rows = [line for line in readme.splitlines() if line.startswith(f"| `{folder}` |")]
    require(len(rows) == 1 and f"| {component_version} |" in rows[0], f"README version mismatch: {folder}")

# QQT_Warpigz_v3 3.3.6: a top-level folder with a main.lua is a plugin, and
# build_release.py ships only the components listed in versions.json, so a
# plugin folder missing from the list would silently drop out of the package.
# Parked or developer-only code lives one level down (archive/WarRoom,
# tools/ApiProbe) and is never shipped.
for path in sorted(ROOT.iterdir()):
    if path.is_dir() and (path / "main.lua").is_file():
        require(path.name in manifest["components"],
                f"Plugin folder not listed in versions.json: {path.name} (list it, park it in archive/, "
                f"or delete a leftover copy of a removed component)")

if args.base:
    def git(*parts):
        return subprocess.check_output(["git", *parts], cwd=ROOT, text=True)

    previous = json.loads(git("show", f"{args.base}:versions.json"))
    changed = git("diff", "--name-only", args.base, "--").splitlines()
    if changed:
        require(semver(version) > semver(previous["version"]), "Bundle version must increase")
        require("CHANGELOG.md" in changed, "Every delivered change needs an English changelog entry")
    for folder, component_version in manifest["components"].items():
        # NOTES.md is a session note that build_release.py does not ship.
        if any(path.startswith(folder + "/") and not path.endswith("/NOTES.md") for path in changed):
            old = previous["components"].get(folder)
            require(old is None or semver(component_version) > semver(old), f"Component version must increase: {folder}")
    # QQT_Warpigz_v3 3.3.6: a component dropped from the package since the base
    # (WarRoom, parked in archive/) needs no version bump; the repository must
    # not keep it at the top level (no tracked file; a leftover main.lua fails
    # the plugin-folder check above) and README must not list it. An untracked
    # leftover folder with only the runtime data the plugin wrote in an old
    # checkout (e.g. WarRoom/data/*) is never shipped: noted, not an error.
    removed = sorted(set(previous["components"]) - set(manifest["components"]))
    for folder in removed:
        tracked = git("ls-files", "--", folder).splitlines()
        require(not tracked, f"Removed component still tracked at the top level: {folder} "
                             f"({len(tracked)} file(s); git mv it to archive/ or git rm it)")
        require(f"| `{folder}` |" not in readme, f"README still lists the removed component: {folder}")
        if not tracked and (ROOT / folder).is_dir() and not (ROOT / folder / "main.lua").exists():
            print(f"NOTE: untracked leftover folder {folder}/ of a removed component (not shipped; safe to delete)")
    if removed:
        print(f"NOTE: components removed since {args.base}: {', '.join(removed)}")

if errors:
    raise SystemExit("Release checks failed:\n- " + "\n- ".join(errors))
print(f"PASS: QQT_Warpigz_v3 v{version}, {len(manifest['components'])} component versions, credits and changelog")
