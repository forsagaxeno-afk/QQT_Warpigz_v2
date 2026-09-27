-- QQT_Warpigz_v3: release package layout. audit/build_release.py must ship the
-- whole WarRoom plugin (runtime Lua, dashboard page, server scripts, .keep
-- placeholders) and never the files the plugins generate on the user's PC
-- (dashboard data, persisted totals, the server's access token / stop flag).
-- .gitignore keeps the same files out of Git. Asks Python (already required by
-- the test runner) through io.popen. Runs under Lua 5.4 and LuaJIT.
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

local ships = {
    'WarRoom/main.lua', 'WarRoom/gui.lua', 'WarRoom/core/qqt_events.lua',
    'WarRoom/dashboard/index.html', 'WarRoom/dashboard/app.js', 'WarRoom/dashboard/style.css',
    'WarRoom/server/serve.ps1', 'WarRoom/server/serve.bat', 'WarRoom/server/serve-lan.bat',
    'WarRoom/data/.keep', 'WarRoom/dashboard/.keep',
    'HelltideRevamped/main.lua', 'HelltideRevamped/learned/.keep',
}
local generated = {
    'WarRoom/dashboard/suite_data.js', 'WarRoom/dashboard/hr_data.js', 'WarRoom/dashboard/suite_data.js.tmp',
    'WarRoom/data/alltime.txt', 'WarRoom/data/today.txt', 'WarRoom/data/alltime.txt.tmp',
    'WarRoom/server/.dashboard-token', 'WarRoom/server/stop.flag',
    'HelltideRevamped/learned/stats.txt', 'HelltideRevamped/dashboard/hr_data.js',
    'WarRoom/.gitignore', 'WarRoom/core/__pycache__/x.pyc',
}

check('build_release.ships()', function()
    local py = 'import sys; sys.path.insert(0, sys.argv[1] + "/audit"); import build_release as b; '
        .. '[print(("Y " if b.ships(p) else "N ") + p) for p in sys.argv[2:]]'
    local args = {}
    for _, p in ipairs(ships) do args[#args + 1] = "'" .. p .. "'" end
    for _, p in ipairs(generated) do args[#args + 1] = "'" .. p .. "'" end
    local cmd = ("python3 -c '%s' '%s' %s 2>&1"):format(py, root, table.concat(args, ' '))
    local pipe = assert(io.popen(cmd), 'io.popen unavailable')
    local out = pipe:read('*a')
    pipe:close()
    local seen = {}
    for flag, path in out:gmatch('([YN]) (%S+)') do seen[path] = flag end
    for _, p in ipairs(ships) do assert(seen[p] == 'Y', 'not shipped: ' .. p .. '\n' .. out) end
    for _, p in ipairs(generated) do assert(seen[p] == 'N', 'shipped generated file: ' .. p .. '\n' .. out) end
end)

check('.gitignore', function()
    local gi = read('.gitignore')
    for _, line in ipairs({'WarRoom/dashboard/suite_data.js', 'WarRoom/dashboard/hr_data.js',
                           'WarRoom/data/*', '!WarRoom/data/.keep',
                           'WarRoom/server/.dashboard-token', 'WarRoom/server/stop.flag'}) do
        assert(('\n' .. gi .. '\n'):find('\n' .. line .. '\n', 1, true), 'missing ' .. line)
    end
end)

check('versions.json lists WarRoom', function()
    local manifest = read('versions.json')
    assert(manifest:find('"WarRoom": "%d+%.%d+%.%d+"'), 'WarRoom component missing')
end)

check('WarRoom data placeholder exists', function()
    assert(io.open(root .. '/WarRoom/data/.keep', 'rb'), 'WarRoom/data/.keep missing')
end)

if #failures > 0 then
    error(('%d/%d release layout checks failed:\n%s'):format(#failures, checks, table.concat(failures, '\n')))
end
print(('Release layout: %d checks passed'):format(checks))
