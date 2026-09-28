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
    if folder == "WarRoom":
        # QQT_Warpigz_v3: the dashboard page and the Windows server scripts ship
        # with the plugin; the scripts must stay ASCII with CRLF line endings.
        require((ROOT / folder / "dashboard" / "index.html").is_file(), "Missing WarRoom/dashboard/index.html")
        for script in ("serve.ps1", "serve.bat", "serve-lan.bat"):
            path = ROOT / folder / "server" / script
            if not path.is_file():
                errors.append(f"Missing WarRoom/server/{script}")
                continue
            data = path.read_bytes()
            require(data.isascii(), f"WarRoom/server/{script} must be ASCII")
            require(data.count(b"\n") == data.count(b"\r\n") > 0, f"WarRoom/server/{script} must use CRLF line endings")
    rows = [line for line in readme.splitlines() if line.startswith(f"| `{folder}` |")]
    require(len(rows) == 1 and f"| {component_version} |" in rows[0], f"README version mismatch: {folder}")

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

if errors:
    raise SystemExit("Release checks failed:\n- " + "\n- ".join(errors))
print(f"PASS: QQT_Warpigz_v3 v{version}, {len(manifest['components'])} component versions, credits and changelog")
