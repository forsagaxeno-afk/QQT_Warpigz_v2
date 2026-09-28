-- QQT_Warpigz_v3: release package layout. 3.3.6: the owner parked WarRoom in
-- archive/WarRoom, so the package ships exactly the 10 plugin folders listed
-- in versions.json under scripts/, plus the user documents at the package
-- root. The zip never contains WarRoom, archive/, tools/, audit/ or docs/
-- (the user guide ships only as the DOCS target docs/GUIDE_EN.md at the
-- package root, never under scripts/), and never the files the plugins
-- generate on the user's PC. .gitignore / .gitattributes keep WarRoom's
-- entries under archive/WarRoom so it can be restored. Builds the real zip
-- with audit/build_release.py into a temporary folder through io.popen
-- (Python is already required by the test runner). Runs under Lua 5.4 and
-- LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local failures, checks = {}, 0

local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end

local function read(rel)
    local f = assert(io.open(root .. '/' .. rel, 'rb'), 'missing ' .. rel)
    local data = f:read('*a')
    f:close()
    return data
end

local function exists(rel)
    local f = io.open(root .. '/' .. rel, 'rb')
    if f then f:close() end
    return f ~= nil
end

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function popen_all(cmd)
    local pipe = assert(io.popen(cmd), 'io.popen unavailable')
    local out = pipe:read('*a')
    pipe:close()
    return out
end

-- The 10 shipped plugins (3.3.6). WarRoom is parked in archive/.
local COMPONENTS = {'ArkhamAsylum', 'Batmobile', 'HelltideRevamped', 'HordeDev', 'Reaper', 'Rosie',
    'SilentRaven', 'WarPigs', 'WarPug', 'WonderCity'}
local IS_COMPONENT = {}
for _, name in ipairs(COMPONENTS) do IS_COMPONENT[name] = true end
-- build_release.DOCS targets at the package root.
local DOC_TARGETS = {['README.md'] = true, ['CHANGELOG.md'] = true, ['AUDIT.md'] = true, ['CREDITS.md'] = true,
    ['LIVE_CHECKLIST.md'] = true, ['УСТАНОВКА_RU.txt'] = true, ['docs/GUIDE_EN.md'] = true}
local NEVER = {'WarRoom', 'archive', 'tools', 'audit', 'docs', 'assets', 'dist', '.github'}

check('versions.json lists exactly the 10 components, no WarRoom', function()
    local manifest = read('versions.json')
    local block = assert(manifest:match('"components"%s*:%s*(%b{})'), 'components block')
    local seen, n = {}, 0
    for name in block:gmatch('"([%w_]+)"%s*:%s*"%d+%.%d+%.%d+"') do
        n = n + 1
        assert(IS_COMPONENT[name], 'unexpected component ' .. name)
        seen[name] = true
    end
    assert(n == #COMPONENTS, 'components listed: ' .. n)
    for _, name in ipairs(COMPONENTS) do assert(seen[name], 'missing component ' .. name) end
    assert(not block:find('WarRoom', 1, true), 'WarRoom is still a component')
end)

check('WarRoom is parked in archive/, not at the top level', function()
    assert(not exists('WarRoom/main.lua'), 'a top-level WarRoom folder would be loaded by QQT')
    assert(exists('archive/WarRoom/main.lua'), 'archive/WarRoom/main.lua (kept for later)')
    assert(exists('archive/README.md'), 'archive/README.md explains how to restore it')
    for _, t in ipairs({'collector', 'dashboard', 'joint', 'server'}) do
        assert(exists('archive/tests/test_warroom_' .. t .. '.lua'), 'archived test ' .. t)
        assert(not exists('audit/tests/test_warroom_' .. t .. '.lua'), 'WarRoom test still in the suite: ' .. t)
    end
end)

local ships = {
    'HelltideRevamped/main.lua', 'HelltideRevamped/learned/.keep', 'HelltideRevamped/dashboard/.keep',
    'Rosie/main.lua', 'SilentRaven/silent_raven/gui.lua', 'WarPigs/core/qqt_events.lua',
}
local not_shipped = {
    'HelltideRevamped/learned/stats.txt', 'HelltideRevamped/learned/stats.txt.tmp',
    'HelltideRevamped/dashboard/hr_data.js', 'HelltideRevamped/NOTES.md', 'Rosie/.gitignore',
    'WarPigs/core/__pycache__/x.pyc',
    'archive/WarRoom/main.lua', 'archive/WarRoom/dashboard/index.html', 'archive/WarRoom/data/.keep',
    'archive/tests/test_warroom_joint.lua', 'archive/README.md',
    'tools/ApiProbe/main.lua', 'audit/tests/joint_host.lua', 'docs/GUIDE_EN.md', 'assets/branding/x.png',
}

check('build_release.ships()', function()
    local py = 'import sys; sys.path.insert(0, sys.argv[1] + "/audit"); import build_release as b; '
        .. '[print(("Y " if b.ships(p) else "N ") + p) for p in sys.argv[2:]]'
    local args = {}
    for _, p in ipairs(ships) do args[#args + 1] = sh_quote(p) end
    for _, p in ipairs(not_shipped) do args[#args + 1] = sh_quote(p) end
    local out = popen_all(('python3 -c %s %s %s 2>&1'):format(sh_quote(py), sh_quote(root), table.concat(args, ' ')))
    local seen = {}
    for flag, path in out:gmatch('([YN]) (%S+)') do seen[path] = flag end
    for _, p in ipairs(ships) do assert(seen[p] == 'Y', 'not shipped: ' .. p .. '\n' .. out) end
    for _, p in ipairs(not_shipped) do assert(seen[p] == 'N', 'shipped: ' .. p .. '\n' .. out) end
end)

-- Build the real package into a temporary folder and list its entries.
local BUILD = [[
import pathlib, subprocess, sys, tempfile, zipfile
root = sys.argv[1]
with tempfile.TemporaryDirectory() as out:
    run = subprocess.run([sys.executable, root + "/audit/build_release.py", "--out", out],
                         cwd=root, capture_output=True, text=True)
    if run.returncode:
        print("BUILD-FAILED " + (run.stderr or run.stdout).replace("\n", " | "))
        sys.exit(0)
    for package in sorted(pathlib.Path(out).glob("*.zip")):
        print("ZIP " + package.name)
        for name in zipfile.ZipFile(package).namelist():
            print("E " + name)
    notes = pathlib.Path(out, "RELEASE_NOTES.md").read_text(encoding="utf-8")
    print("NOTES-10 " + str("only the 10 folders" in notes))
    print("NOTES-WARROOM " + str("| `WarRoom` |" in notes))
]]

check('the built zip holds exactly the 10 plugin folders and the user documents', function()
    local out = popen_all(('PYTHONIOENCODING=utf-8 python3 -c %s %s 2>&1'):format(sh_quote(BUILD), sh_quote(root)))
    assert(not out:find('BUILD-FAILED', 1, true), out)
    local zips, entries = {}, {}
    for line in out:gmatch('[^\n]+') do
        local z = line:match('^ZIP (.+)$')
        if z then zips[#zips + 1] = z end
        local e = line:match('^E (.+)$')
        if e then entries[#entries + 1] = e end
    end
    assert(#zips == 1, 'one package: ' .. out:sub(1, 400))
    local version = read('VERSION'):gsub('%s+$', '')
    local name = 'QQT_Warpigz_v3-v' .. version
    assert(zips[1] == name .. '.zip', 'package name ' .. tostring(zips[1]))
    assert(#entries > 100, 'entries: ' .. #entries)
    local folders, main_lua, docs = {}, {}, {}
    for _, e in ipairs(entries) do
        assert(e:sub(1, #name + 1) == name .. '/', 'outside the package folder: ' .. e)
        local rel = e:sub(#name + 2)
        local folder, rest = rel:match('^scripts/([^/]+)/(.+)$')
        if folder then
            assert(IS_COMPONENT[folder], 'not a shipped plugin under scripts/: ' .. folder .. ' (' .. e .. ')')
            folders[folder] = true
            if rest == 'main.lua' then main_lua[folder] = true end
        else
            assert(DOC_TARGETS[rel], 'unexpected file at the package root: ' .. rel)
            docs[rel] = true
        end
        for _, bad in ipairs(NEVER) do
            assert(not rel:find('^scripts/' .. bad:gsub('%p', '%%%0') .. '/'), 'never shipped: ' .. e)
        end
        assert(not e:find('WarRoom', 1, true), 'WarRoom in the package: ' .. e)
        assert(not rel:find('^archive/') and not rel:find('^tools/') and not rel:find('^audit/'), 'repo folder: ' .. e)
        assert(not rel:find('^docs/') or rel == 'docs/GUIDE_EN.md', 'only the user guide under docs/: ' .. e)
        assert(not rel:find('NOTES%.md$') and not rel:find('__pycache__', 1, true), 'session / cache file: ' .. e)
        assert(not rel:find('learned/[^/]+%.txt$') and not rel:find('hr_data%.js$'), 'generated file: ' .. e)
    end
    local n = 0
    for _ in pairs(folders) do n = n + 1 end
    assert(n == #COMPONENTS, 'plugin folders under scripts/: ' .. n)
    for _, c in ipairs(COMPONENTS) do
        assert(folders[c], 'missing plugin folder ' .. c)
        assert(main_lua[c], c .. '/main.lua missing from the package')
    end
    for target in pairs(DOC_TARGETS) do assert(docs[target], 'missing document ' .. target) end
    assert(out:find('NOTES%-10 True'), 'RELEASE_NOTES says to copy the 10 folders')
    assert(out:find('NOTES%-WARROOM False'), 'RELEASE_NOTES has no WarRoom row in its folder table')
end)

check('.gitignore / .gitattributes keep WarRoom entries under archive/WarRoom', function()
    local gi = '\n' .. read('.gitignore') .. '\n'
    for _, line in ipairs({'HelltideRevamped/learned/*.txt', 'HelltideRevamped/dashboard/hr_data.js',
                           'archive/WarRoom/dashboard/suite_data.js', 'archive/WarRoom/dashboard/hr_data.js',
                           'archive/WarRoom/data/*', '!archive/WarRoom/data/.keep',
                           'archive/WarRoom/server/.dashboard-token', 'archive/WarRoom/server/stop.flag'}) do
        assert(gi:find('\n' .. line .. '\n', 1, true), '.gitignore missing ' .. line)
    end
    assert(not gi:find('\nWarRoom/', 1, true) and not gi:find('\n!WarRoom/', 1, true), '.gitignore: stale WarRoom/ line')
    local ga = '\n' .. read('.gitattributes') .. '\n'
    for _, line in ipairs({'archive/WarRoom/server/*.bat -text', 'archive/WarRoom/server/*.ps1 -text'}) do
        assert(ga:find('\n' .. line .. '\n', 1, true), '.gitattributes missing ' .. line)
    end
    assert(not ga:find('\nWarRoom/', 1, true), '.gitattributes: stale WarRoom/ line')
end)

-- No text of a shipped plugin (menu labels, tooltips, log lines) sends the
-- user to WarRoom any more. The only WarRoom literals left are
-- HelltideRevamped's optional integration: the _G.QQT_WarRoom lookup (nil
-- without WarRoom) and the log key of the file it would write there.
local ALLOWED_LITERALS = {['QQT_WarRoom'] = true, ['WarRoom/dashboard/'] = true}
check('no shipped string literal points to WarRoom', function()
    local dirs = {}
    for _, c in ipairs(COMPONENTS) do dirs[#dirs + 1] = sh_quote(root .. '/' .. c) end
    local list = popen_all('find ' .. table.concat(dirs, ' ') .. ' -name "*.lua" -type f')
    local files = 0
    for path in list:gmatch('[^\n]+') do
        files = files + 1
        local f = assert(io.open(path, 'rb'))
        local text = f:read('*a')
        f:close()
        local n = 0
        for line in (text .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            local code = line:gsub('%-%-.*$', '')
            for _, q in ipairs({'"', "'"}) do
                for lit in code:gmatch(q .. '([^' .. q .. ']*)' .. q) do
                    if lit:find('WarRoom', 1, true) then
                        assert(ALLOWED_LITERALS[lit], path:sub(#root + 2) .. ':' .. n .. ': ' .. lit)
                    end
                end
            end
        end
    end
    assert(files > 100, 'Lua files scanned: ' .. files)
end)

if #failures > 0 then
    error(('%d/%d release layout checks failed:\n%s'):format(#failures, checks, table.concat(failures, '\n')))
end
print(('Release layout: %d checks passed'):format(checks))
