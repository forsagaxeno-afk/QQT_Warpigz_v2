-- QQT_Warpigz_v3: static checks of the WarRoom dashboard server
-- (WarRoom/server/serve.ps1, serve.bat, serve-lan.bat). The scripts run under
-- Windows PowerShell 5.1, so here we only pin their security contract:
-- ASCII + CRLF, 127.0.0.1:8765 by default, -Lan opt-in with an access token,
-- GET/HEAD only, allow-listed extensions, no traversal / dotfiles / listings,
-- Host and private-address checks, no-store for html/js/json, and a default
-- root of ..\dashboard. Runs under Lua 5.4 and LuaJIT.
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

local function has(text, needle, what)
    assert(text:find(needle, 1, true), (what or 'expected') .. ': ' .. needle)
end

local function lacks(text, needle, what)
    assert(not text:find(needle, 1, true), (what or 'unexpected') .. ': ' .. needle)
end

local files = {'WarRoom/server/serve.ps1', 'WarRoom/server/serve.bat', 'WarRoom/server/serve-lan.bat'}
local ps1, bat, lan = '', '', ''

check('scripts exist', function()
    ps1, bat, lan = read(files[1]), read(files[2]), read(files[3])
end)

for _, rel in ipairs(files) do
    check(rel .. ' is ASCII with CRLF line endings', function()
        local data = read(rel)
        assert(#data > 0, 'empty')
        assert(not data:find('[\128-\255]'), 'non-ASCII byte')
        local lf, crlf = 0, 0
        for _ in data:gmatch('\n') do lf = lf + 1 end
        for _ in data:gmatch('\r\n') do crlf = crlf + 1 end
        assert(lf > 0 and lf == crlf, ('bare LF line endings (%d LF, %d CRLF)'):format(lf, crlf))
        assert(not data:find('\r[^\n]'), 'bare CR')
        assert(data:sub(-2) == '\r\n', 'no final CRLF')
    end)
end

check('launchers', function()
    has(bat, '-ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*')
    has(bat, '-NoProfile')
    lacks(bat:lower(), 'set-executionpolicy', 'changes system policy')
    has(lan, 'call "%~dp0serve.bat" -Lan %*')
end)

check('defaults: 127.0.0.1:8765, root ..\\dashboard', function()
    has(ps1, '[ValidateRange(1024, 65535)][int]$Port = 8765')
    has(ps1, "if (-not $Root) { $Root = Join-Path (Split-Path -Parent $ScriptDir) 'dashboard' }")
    -- 0.0.0.0 only in the -Lan branch; otherwise loopback.
    has(ps1, '} elseif ($Lan) {\r\n    $bindIp = [Net.IPAddress]::Any\r\n} else {\r\n    $bindIp = [Net.IPAddress]::Loopback\r\n}')
    local any = 0
    for _ in ps1:gmatch('%[Net%.IPAddress%]::Any') do any = any + 1 end
    assert(any == 2, 'IPAddress::Any used outside the -Lan branch / banner: ' .. any)
    lacks(ps1, 'HttpListener', 'HttpListener needs URL ACLs/admin')
end)

check('LAN token', function()
    has(ps1, "$TokenFile = Join-Path $ScriptDir '.dashboard-token'")
    has(ps1, '[Security.Cryptography.RandomNumberGenerator]::Create()')
    has(ps1, 'if ($RemoteMode -and -not $NoToken) {')
    has(ps1, 'if ($AccessToken -and -not $isLocalClient) {')
    has(ps1, "Send-Text $ctx 401 ")
    has(ps1, 'function Test-TokenEqual')
    has(ps1, 'HttpOnly; SameSite=Lax')
    -- the token never reaches the request log
    has(ps1, "$ctx.LogPath = ($path -replace '^/(t|T)/[^/]*', '/t/***')")
end)

check('read-only: GET/HEAD, no bodies, no listing', function()
    has(ps1, "if ($method -ne 'GET' -and $method -ne 'HEAD') {")
    has(ps1, "Send-Text $ctx 405 ")
    has(ps1, "Send-Text $ctx 413 'Request bodies are not accepted'")
    has(ps1, "'dir'     { Send-Text $ctx 301 ")
    for _, bad in ipairs({'GetFiles', 'EnumerateFiles', 'GetDirectories', 'Get-ChildItem', 'Invoke-Expression',
                          'iex ', 'Start-Process', 'Set-Content', 'Out-File', 'Add-Content'}) do
        lacks(ps1, bad)
    end
    -- the only file the server writes is its own token file
    local writes = 0
    for _ in ps1:gmatch('WriteAll') do writes = writes + 1 end
    assert(writes == 1, 'unexpected file writes: ' .. writes)
end)

check('path safety', function()
    has(ps1, "if ($s.StartsWith('.')) { return $none }")
    has(ps1, 'if (-not $full.StartsWith($RootFull, $PathCmp)) { return $none }')
    has(ps1, "$BadChars = [char[]]@([char]0, '\\', ':', '*', '?', '\"', '<', '>', '|', '~')")
    has(ps1, 'function Test-NoReparse')
    has(ps1, '[Uri]::UnescapeDataString($rawPath)')
end)

check('extension allow-list', function()
    local block = assert(ps1:match('%$Mime = @{(.-)\r\n}'), 'no $Mime table')
    local exts = {}
    for ext in block:gmatch("'(%.%w+)'%s*=") do exts[ext] = true end
    for _, need in ipairs({'.html', '.js', '.css', '.json', '.png', '.svg'}) do
        assert(exts[need], 'missing ' .. need)
    end
    for _, bad in ipairs({'.txt', '.lua', '.ps1', '.bat', '.cmd', '.md', '.log', '.tmp', '.flag', '.exe', '.zip'}) do
        assert(not exts[bad], 'serves ' .. bad)
    end
end)

check('no-store for html/js/json', function()
    local block = assert(ps1:match('%$Cacheable = @{(.-)}'), 'no $Cacheable table')
    for _, ext in ipairs({'.html', '.htm', '.js', '.mjs', '.json', '.css', '.map'}) do
        assert(not block:find("'" .. ext:gsub('%.', '%%.') .. "'"), ext .. ' is cacheable')
    end
    has(ps1, "else { 'no-store, max-age=0' }")
    has(ps1, "$headers['Cache-Control'] = 'no-store'")
end)

check('Host header and client address checks', function()
    has(ps1, "if (-not (Test-HostHeader $hdr['host'])) { Send-Text $ctx 421 ")
    has(ps1, 'if (-not $isLocalClient -and -not $AllowPublic -and -not (Test-PrivateClient $remoteIp)) {')
    has(ps1, "if ($k -eq 'host' -and $hdr.ContainsKey('host')) { Send-Text $ctx 400 'Duplicate Host'")
    for _, range in ipairs({'# 10/8', '# 172.16/12', '# 192.168/16', '# CGNAT 100.64/10'}) do has(ps1, range) end
end)

check('headers and limits', function()
    has(ps1, 'X-Content-Type-Options: nosniff')
    -- The dashboard frames its own Helltide map (helltide/<theme>.html?embed=1):
    -- same-origin framing must be allowed, cross-origin framing refused (A1).
    has(ps1, "frame-ancestors 'self'")
    lacks(ps1, "frame-ancestors 'none'", 'blocks the Helltide tab iframe')
    has(ps1, 'X-Frame-Options: SAMEORIGIN`r`n')
    lacks(ps1, 'X-Frame-Options: DENY', 'blocks the Helltide tab iframe')
    local app = read('WarRoom/dashboard/app.js')
    has(app, "f.src = 'helltide/' + THEME + '.html?embed=1'", 'the framed page is a relative (same-origin) path')
    has(ps1, '$MaxHeaderBytes = 8192')
    has(ps1, '$MaxFileBytes   = 16MB')
end)

check('access link redirects only to / (no open redirect)', function()
    -- GET //evil.example/?t=x must never answer Location: //evil.example/ (A4).
    has(ps1, "$h = @{ 'Location' = '/' }")
    lacks(ps1, '$cleanPath', 'the request path is echoed into Location')
    local block = assert(ps1:match('# %-%-%-%- access token(.-)# %-%-%-%- file'), 'no access token block')
    for loc in block:gmatch("'Location'%s*=%s*([^}]+)}") do
        assert(loc:match("^'/'%s*$"), 'Location is not the literal /: ' .. loc)
    end
end)

check('stop.flag next to the script', function()
    has(ps1, "$StopFile  = Join-Path $ScriptDir 'stop.flag'")
end)

check('no personal data or absolute user paths', function()
    for _, rel in ipairs(files) do
        local data = read(rel):lower()
        for _, bad in ipairs({'c:\\users\\', '/home/', 'appdata'}) do
            assert(not data:find(bad, 1, true), rel .. ' contains ' .. bad)
        end
    end
end)

if #failures > 0 then
    error(('%d/%d WarRoom server checks failed:\n%s'):format(#failures, checks, table.concat(failures, '\n')))
end
print(('WarRoom server: %d checks passed'):format(checks))
