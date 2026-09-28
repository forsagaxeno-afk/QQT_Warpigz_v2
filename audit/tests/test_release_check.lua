-- QQT_Warpigz_v3 3.3.6: audit/check_release.py rules for a component that
-- leaves the package (the owner parked WarRoom in archive/). Runs the real
-- check_release.py against a small throw-away git repository (two plugins,
-- Alpha and Ghost, tagged `base`), then removes Ghost from versions.json and
-- README and checks:
--   * a removed component needs no version bump and the release passes;
--   * an untracked leftover folder with only runtime data (what an old
--     checkout keeps after the move, e.g. WarRoom/data/alltime.txt) is noted,
--     not an error (up to the first 3.3.6 draft it failed the release);
--   * a leftover plugin (main.lua), a still tracked file or a README row of
--     the removed component fails;
--   * a top-level plugin folder missing from versions.json fails;
--   * a changed component still needs a version bump.
-- Python and git are already required by the runner and check_release.py.
-- Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required')

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local SCRIPT = [[
import json, pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
GIT = ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
       "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"]

def git(repo, *parts):
    subprocess.run(GIT + list(parts), cwd=repo, check=True, capture_output=True, text=True)

def write(repo, rel, text):
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")

def release(repo, version, components, readme_rows, changelog):
    write(repo, "VERSION", version + "\n")
    write(repo, "versions.json", json.dumps({"project": "QQT_Warpigz_v3", "version": version,
                                             "first_release": "2.0.0", "components": components}, indent=2))
    rows = "\n".join(f"| `{name}` | test plugin | {v} |" for name, v in readme_rows.items())
    write(repo, "README.md", f"# Test\n\nCurrent release: v{version}\n\n| Folder | What | Version |\n"
                             f"|---|---|---|\n{rows}\n\nCredits: @ZEWX, LONG LIVE LEGEND\n")
    write(repo, "CHANGELOG.md", "# Changelog\n\n" + changelog)

def plugin(repo, name, version):
    write(repo, f"{name}/main.lua", "-- test plugin\n")
    write(repo, f"{name}/gui.lua", f'local version = "v{version}"\n')

def check(repo, label):
    run = subprocess.run([sys.executable, str(repo / "audit" / "check_release.py"), "--base", "base"],
                         cwd=repo, capture_output=True, text=True)
    print(f"CASE {label} rc={run.returncode} " + (run.stdout + run.stderr).replace("\n", " | "))

with tempfile.TemporaryDirectory() as tmp:
    repo = pathlib.Path(tmp) / "repo"
    repo.mkdir()
    write(repo, "audit/check_release.py", (root / "audit" / "check_release.py").read_text(encoding="utf-8"))
    plugin(repo, "Alpha", "1.0.0")
    plugin(repo, "Ghost", "1.0.0")
    OLD = "## [1.0.0]\n- first\n"
    release(repo, "1.0.0", {"Alpha": "1.0.0", "Ghost": "1.0.0"}, {"Alpha": "1.0.0", "Ghost": "1.0.0"}, OLD)
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "base")
    git(repo, "tag", "base")

    # The release: Ghost parked in archive/ (git mv), gone from versions.json
    # and README; Ghost keeps its version (no bump), Alpha is unchanged.
    (repo / "archive").mkdir()
    git(repo, "mv", "Ghost", "archive/Ghost")
    NEW = "## [1.0.1]\n### Removed\n- Ghost\n\n" + OLD
    release(repo, "1.0.1", {"Alpha": "1.0.0"}, {"Alpha": "1.0.0"}, NEW)
    check(repo, "removed")

    write(repo, "Ghost/data/alltime.txt", "12345\n")
    check(repo, "leftover-data")

    write(repo, "Ghost/main.lua", "-- stale copy\n")
    check(repo, "leftover-plugin")
    (repo / "Ghost" / "main.lua").unlink()

    git(repo, "add", "Ghost/data/alltime.txt")
    check(repo, "leftover-tracked")
    git(repo, "rm", "-q", "--cached", "Ghost/data/alltime.txt")
    shutil.rmtree(repo / "Ghost")

    release(repo, "1.0.1", {"Alpha": "1.0.0"}, {"Alpha": "1.0.0", "Ghost": "1.0.0"}, NEW)
    check(repo, "readme-row")
    release(repo, "1.0.1", {"Alpha": "1.0.0"}, {"Alpha": "1.0.0"}, NEW)

    plugin(repo, "Beta", "1.0.0")
    check(repo, "unlisted-plugin")
    shutil.rmtree(repo / "Beta")

    write(repo, "Alpha/main.lua", "-- changed\n")
    check(repo, "no-bump")
    plugin(repo, "Alpha", "1.0.1")
    write(repo, "Alpha/main.lua", "-- changed\n")
    release(repo, "1.0.1", {"Alpha": "1.0.1"}, {"Alpha": "1.0.1"}, NEW)
    check(repo, "bumped")
print("DONE")
]]

local pipe = assert(io.popen(('python3 -c %s %s 2>&1'):format(sh_quote(SCRIPT), sh_quote(root))), 'io.popen')
local out = pipe:read('*a')
pipe:close()
assert(out:find('\nDONE') or out:find('^DONE'), 'setup failed:\n' .. out)

local results = {}
for label, rc, text in out:gmatch('CASE (%S+) rc=(%d+) ([^\n]*)') do results[label] = {rc = tonumber(rc), text = text} end

local failures, checks = {}, 0
local function expect(label, rc, needles, absent)
    checks = checks + 1
    local r = results[label]
    local problem
    if not r then
        problem = 'no result'
    elseif r.rc ~= rc then
        problem = 'rc ' .. r.rc .. ', expected ' .. rc
    else
        for _, needle in ipairs(needles) do
            if not r.text:find(needle, 1, true) then problem = 'missing "' .. needle .. '"' break end
        end
        for _, needle in ipairs(absent or {}) do
            if r.text:find(needle, 1, true) then problem = 'unexpected "' .. needle .. '"' break end
        end
    end
    if problem then failures[#failures + 1] = label .. ': ' .. problem .. '\n  ' .. (r and r.text or out) end
end

expect('removed', 0, {'PASS', 'NOTE: components removed since base: Ghost'}, {'Component version must increase'})
expect('leftover-data', 0, {'PASS', 'NOTE: untracked leftover folder Ghost/'})
expect('leftover-plugin', 1, {'Plugin folder not listed in versions.json: Ghost'})
expect('leftover-tracked', 1, {'Removed component still tracked at the top level: Ghost'})
expect('readme-row', 1, {'README still lists the removed component: Ghost'})
expect('unlisted-plugin', 1, {'Plugin folder not listed in versions.json: Beta'})
expect('no-bump', 1, {'Component version must increase: Alpha'})
expect('bumped', 0, {'PASS'})

if #failures > 0 then
    error(('%d/%d check_release cases failed:\n%s'):format(#failures, checks, table.concat(failures, '\n')))
end
print(('check_release removed-component rules: %d cases passed'):format(checks))
