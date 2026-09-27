-- QQT_Warpigz_v3: small, bounded file storage for HelltideRevamped
-- (learned chest spots, statistics, the web dashboard data).
--
--   * The root is the plugin folder, found from the plugin's own
--     package.path like WarPug's gui.lua. resolve_root() runs once at load
--     (main.lua) so the package read happens in this plugin's context; when
--     the folder cannot be resolved nothing is ever written.
--   * write() refuses more than MAX_BYTES, writes '<file>.tmp' and renames it
--     when os.rename exists (undocumented in QQT: probed, never assumed),
--     else writes the file directly. After FAIL_LIMIT consecutive failures a
--     file is not written again this session (one log line).
--   * read_lines() is protected, skips lines longer than MAX_LINE and reads
--     at most max_lines lines of a file no larger than MAX_READ.
--   * Folders are never created (Lua cannot mkdir portably): learned/ and
--     dashboard/ ship with a .keep file.
local M = {
    MAX_BYTES = 512 * 1024,
    MAX_READ = 1024 * 1024,
    MAX_LINE = 512,
    FAIL_LIMIT = 3,
    failed = {},       -- rel -> true once writing it is off for the session
    fails = {},        -- rel -> consecutive failures
    too_big = {},      -- rel -> logged once
    writes = 0,
    last_error = nil,
}

local root_cache = nil -- nil: not resolved yet; false: unresolvable

local function log(msg)
    pcall(function() console.print('[HelltideRevamped] ' .. msg) end)
end

local function exists(path)
    local ok, found = pcall(function()
        local f = io.open(path, 'r')
        if not f then return false end
        f:close()
        return true
    end)
    return ok and found == true
end

local function sep_of(root)
    if root:find('\\', 1, true) then return '\\' end
    return '/'
end

local function native(root, rel)
    local sep = sep_of(root)
    if sep == '/' then return rel end
    return (rel:gsub('/', '\\'))
end

-- The plugin folder (trailing separator) or nil.
function M.resolve_root()
    if root_cache ~= nil then return root_cache or nil end
    local candidates = {}
    pcall(function()
        local pkg = package
        if type(pkg) ~= 'table' then return end
        local search, ppath = pkg.searchpath, pkg.path
        if type(ppath) ~= 'string' then return end
        if type(search) == 'function' then
            local ok, found = pcall(search, 'gui', ppath)
            if ok and type(found) == 'string' then candidates[#candidates + 1] = found:match('^(.*[/\\])') end
        end
        candidates[#candidates + 1] = ppath:match('^([^;]-)%?')
    end)
    local root = false
    for _, dir in ipairs(candidates) do
        -- The host's package.path is absolute; a relative one ('./') would
        -- follow the working directory, never this plugin's folder.
        if type(dir) == 'string' and dir ~= '' and dir:sub(1, 1) ~= '.' then
            local sep = sep_of(dir)
            -- Only this plugin's own folder is accepted.
            if exists(dir .. 'gui.lua') and exists(dir .. 'core' .. sep .. 'hr_store.lua') then
                root = dir
                break
            end
        end
    end
    root_cache = root
    return root or nil
end

function M.root()
    if root_cache == nil then return M.resolve_root() end
    return root_cache or nil
end

-- Test hook / explicit override (nil path disables storage).
function M.set_root(path)
    root_cache = path or false
    M.failed, M.fails, M.too_big, M.writes = {}, {}, {}, 0
end

-- Test hook: resolve again on the next root() call.
function M.unresolve() root_cache = nil end

function M.path(rel)
    local root = M.root()
    if not root then return nil end
    return root .. native(root, rel)
end

local function write_file(path, text)
    local ok, res, err = pcall(function()
        local f, open_err = io.open(path, 'w')
        if not f then return false, open_err end
        local wrote, write_err = f:write(text)
        pcall(f.close, f)
        if not wrote then return false, write_err end
        return true
    end)
    if not ok then return false, res end
    return res == true, err
end

local function try(fn, ...)
    if type(fn) ~= 'function' then return false end
    local ok, res = pcall(fn, ...)
    return ok and res ~= nil and res ~= false
end

local function succeeded(rel)
    M.fails[rel] = 0
    M.writes = M.writes + 1
    return true
end

local function failed(rel, err)
    M.last_error = tostring(err)
    M.fails[rel] = (M.fails[rel] or 0) + 1
    if M.fails[rel] >= M.FAIL_LIMIT and not M.failed[rel] then
        M.failed[rel] = true
        log(string.format('cannot write %s (%s) — saving it is off for this session', rel, tostring(err)))
    end
    return false, err
end

-- chunks: array of strings (each line ends with '\n').
function M.write(rel, chunks)
    if M.failed[rel] then return false, 'disabled' end
    local path = M.path(rel)
    if not path then return false, 'no root' end
    local ok, text = pcall(table.concat, chunks or {})
    if not ok or type(text) ~= 'string' then return failed(rel, 'bad data') end
    if #text > M.MAX_BYTES then
        if not M.too_big[rel] then
            M.too_big[rel] = true
            log(string.format('%s would be %d KB (limit %d KB) — not written', rel,
                math.floor(#text / 1024), math.floor(M.MAX_BYTES / 1024)))
        end
        return false, 'too big'
    end
    -- rawget: probing must not trip hosts that report unknown globals.
    local os_lib = os
    local rename = type(os_lib) == 'table' and rawget(os_lib, 'rename') or nil
    local tmp_written, remove = false, nil
    if type(rename) == 'function' then
        local tmp = path .. '.tmp'
        if write_file(tmp, text) then
            tmp_written = true
            if try(rename, tmp, path) then return succeeded(rel) end
            -- Windows rename does not replace an existing file.
            remove = rawget(os_lib, 'remove')
            if try(remove, path) and try(rename, tmp, path) then return succeeded(rel) end
        end
    end
    local wrote, err = write_file(path, text)
    if wrote then
        -- The temp copy goes only once the file itself is complete.
        if tmp_written then try(remove, path .. '.tmp') end
        return succeeded(rel)
    end
    return failed(rel, err)
end

-- Lines of a stored file (without line ends); nil, 'missing' when neither
-- the file nor its temp copy exists; nil, 'unreadable' when it exists but
-- cannot be read (locked, too large): callers must not overwrite it then. A
-- save interrupted between the temp write and the rename left only
-- '<file>.tmp': that one is read instead.
function M.read_lines(rel, max_lines)
    local path = M.path(rel)
    if not path then return nil, 'no root' end
    max_lines = max_lines or 20000
    local out, why
    local ok = pcall(function()
        local f, err = io.open(path, 'r')
        if not f then
            local ft = io.open(path .. '.tmp', 'r')
            if ft then f = ft
            elseif err and not tostring(err):lower():find('no such', 1, true) then
                why = 'unreadable'
                return
            else
                why = 'missing'
                return
            end
        end
        local oks, size = pcall(f.seek, f, 'end')
        if oks and type(size) == 'number' then
            if size > M.MAX_READ then
                pcall(f.close, f)
                why = 'unreadable'
                log(string.format('%s is larger than %d KB — ignored', rel, math.floor(M.MAX_READ / 1024)))
                return
            end
            pcall(f.seek, f, 'set', 0)
        end
        out = {}
        local n = 0
        for line in f:lines() do
            n = n + 1
            if n > max_lines then break end
            if #line <= M.MAX_LINE then
                out[#out + 1] = (line:gsub('\r$', ''))
            end
        end
        pcall(f.close, f)
    end)
    if not ok then return nil, 'unreadable' end
    if not out then return nil, why or 'missing' end
    return out
end

return M
