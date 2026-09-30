-- QQT_Warpigz_v3: minimal JSON encoder for WarRoom's dashboard/suite_data.js
-- (a copy of HelltideRevamped/core/hr_json.lua with a deeper MAX_DEPTH).
-- Strings are escaped, numbers must be finite (NaN / inf become 0), a table
-- with #t > 0 is an array, any other table an object (string keys; other
-- keys are skipped). Depth is limited to MAX_DEPTH (deeper values are null).
-- No decoder: WarRoom persists with core/wr_persist.lua.
local M = {MAX_DEPTH = 10}

local format, concat, floor = string.format, table.concat, math.floor

local ESCAPES = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}

local function escape_char(c)
    return ESCAPES[c] or format('\\u%04x', c:byte())
end

-- QQT_Warpigz_v3 3.3.3 (WarRoom 1.0.3): a string with nothing to escape
-- (almost all of them) skips gsub, and object keys are encoded once (a
-- full dashboard encoded in ~4.4 ms, on the game thread every write).
local find = string.find
function M.string(s)
    s = tostring(s)
    if not find(s, '[%c"\\]') then return '"' .. s .. '"' end
    return '"' .. s:gsub('[%c"\\]', escape_char) .. '"'
end
local KEYS = {} -- bounded: the payload has a fixed key set (plus boss names)
local key_count = 0
local function key_string(k)
    local text = KEYS[k]
    if text then return text end
    text = M.string(k) .. ':'
    if key_count < 4096 then KEYS[k], key_count = text, key_count + 1 end
    return text
end

function M.number(n)
    if type(n) ~= 'number' or n ~= n or n == math.huge or n == -math.huge then return '0' end
    if n == floor(n) and n > -1e15 and n < 1e15 then return format('%d', n) end
    local text = format('%.3f', n):gsub('0+$', '')
    return (text:gsub('%.$', ''))
end

local encode

local function encode_array(t, depth, out)
    out[#out + 1] = '['
    for i = 1, #t do
        if i > 1 then out[#out + 1] = ',' end
        encode(t[i], depth + 1, out)
    end
    out[#out + 1] = ']'
end

local function encode_object(t, depth, out)
    local keys = {}
    for k in pairs(t) do
        if type(k) == 'string' then keys[#keys + 1] = k end
    end
    table.sort(keys)
    out[#out + 1] = '{'
    for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = ',' end
        out[#out + 1] = key_string(k)
        encode(t[k], depth + 1, out)
    end
    out[#out + 1] = '}'
end

local ARRAY = {}

encode = function(v, depth, out)
    local kind = type(v)
    if kind == 'string' then
        out[#out + 1] = M.string(v)
    elseif kind == 'number' then
        out[#out + 1] = M.number(v)
    elseif kind == 'boolean' then
        out[#out + 1] = v and 'true' or 'false'
    elseif kind == 'table' and depth < M.MAX_DEPTH then
        local mt = getmetatable(v)
        if mt and mt.__json then
            out[#out + 1] = tostring(mt.__json(v))
        elseif mt == ARRAY or #v > 0 then
            encode_array(v, depth, out)
        else
            encode_object(v, depth, out)
        end
    else
        out[#out + 1] = 'null'
    end
end

function M.encode(v)
    local out = {}
    encode(v, 0, out)
    return concat(out)
end

-- A list that stays a JSON array when empty ([] instead of {}).
function M.array(t)
    return setmetatable(t or {}, ARRAY)
end

-- A pre-encoded fragment that encode() inserts verbatim.
local RAW = {__json = function(t) return t[1] end}
function M.raw(text)
    return setmetatable({text}, RAW)
end

return M
