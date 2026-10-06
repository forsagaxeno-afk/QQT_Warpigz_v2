-- QQT_Warpigz_v3: WarRoom's persistence format (data/alltime.txt,
-- data/today.txt). A table becomes one line per scalar leaf:
--     <path>=<type><value>
-- path components are joined with '.', integer keys are written '#<n>',
-- the characters . = # % and control characters inside a key are %XX
-- escaped; type is n (number), s (string, control characters and % escaped)
-- or b (1 / 0). The first line is a header. No JSON decoder is needed and a
-- damaged line only loses that one value.
local M = {HEADER = '#warroom 1', MAX_DEPTH = 8}

local format = string.format

local function esc_key(s)
    return (s:gsub('[%.=#%%%c]', function(c) return format('%%%02X', c:byte()) end))
end

local function esc_val(s)
    return (s:gsub('[%%%c]', function(c) return format('%%%02X', c:byte()) end))
end

local function unesc(s)
    return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

local function num(n)
    if n ~= n or n == math.huge or n == -math.huge then return '0' end
    if n == math.floor(n) and n > -1e15 and n < 1e15 then return format('%d', n) end
    return format('%.17g', n)
end

local function walk(t, prefix, depth, out)
    if depth > M.MAX_DEPTH then return end
    local keys = {}
    for k in pairs(t) do
        local tk = type(k)
        if tk == 'string' or (tk == 'number' and k == math.floor(k)) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta == 'number' end
        return a < b
    end)
    for _, k in ipairs(keys) do
        local part = type(k) == 'number' and ('#' .. format('%d', k)) or esc_key(k)
        local path = prefix == '' and part or (prefix .. '.' .. part)
        local v = t[k]
        local tv = type(v)
        if tv == 'table' then
            walk(v, path, depth + 1, out)
        elseif tv == 'number' then
            out[#out + 1] = path .. '=n' .. num(v) .. '\n'
        elseif tv == 'string' then
            out[#out + 1] = path .. '=s' .. esc_val(v) .. '\n'
        elseif tv == 'boolean' then
            out[#out + 1] = path .. '=b' .. (v and '1' or '0') .. '\n'
        end
    end
end

-- Array of line chunks (each ends with '\n') for wr_store.write().
function M.encode(t)
    local out = {M.HEADER .. '\n'}
    if type(t) == 'table' then walk(t, '', 0, out) end
    return out
end

local function set_path(root, path, value)
    local node, parts = root, {}
    for part in path:gmatch('[^%.]+') do
        if part:sub(1, 1) == '#' then
            local n = tonumber(part:sub(2))
            if not n then return end
            parts[#parts + 1] = n
        else
            parts[#parts + 1] = unesc(part)
        end
    end
    if #parts == 0 or #parts > M.MAX_DEPTH + 1 then return end
    for i = 1, #parts - 1 do
        local k = parts[i]
        local nxt = node[k]
        if type(nxt) ~= 'table' then
            if nxt ~= nil then return end
            nxt = {}
            node[k] = nxt
        end
        node = nxt
    end
    node[parts[#parts]] = value
end

-- Lines (from wr_store.read_lines) -> table, or nil when the header is wrong.
function M.decode(lines)
    if type(lines) ~= 'table' or lines[1] ~= M.HEADER then return nil end
    local root = {}
    for i = 2, #lines do
        local line = lines[i]
        local path, kind, raw = line:match('^([^=]+)=([nsb])(.*)$')
        if path then
            local value
            if kind == 'n' then value = tonumber(raw)
            elseif kind == 's' then value = unesc(raw)
            else value = raw == '1' end
            if value ~= nil then pcall(set_path, root, path, value) end
        end
    end
    return root
end

return M
