-- QQT_Warpigz_v3 HordeDev 2.2.8 (sweep D3): explorer:movement_spell_to_target
-- printed one line per enabled spell per call ("Movement spell on cooldown."
-- about 10 lines every combat pulse live). It now prints one summary line at
-- most every 30 s.
local root = assert(SUITE_ROOT) .. '/HordeDev/'

local function load_explorer()
  local s = {now = 100, logs = {}, ready = false, casts = 0}
  local settings = {enabled = true, use_evade_as_movement_spell = true, use_teleport = true,
    use_teleport_enchanted = true, use_dash = true, use_shadow_step = true, use_the_hunter = true,
    use_soar = true, use_rushing_claw = true, use_leap = true, use_nether_step = true, use_rampage = true,
    path_angle = 10, reset_time = 9999}
  local modules = {
    ['core.utils'] = {get_keybind_state = function() return true end, player_in_zone = function() return false end},
    ['data.enums'] = {},
    ['core.settings'] = settings,
    ['core.tracker'] = {pit_start_time = 0},
    ['core.horde_zones'] = assert(loadfile(root .. 'core/horde_zones.lua'))(),
  }
  local vec = {}
  vec.__index = vec
  function vec:new(x, y, z) return setmetatable({x_ = x, y_ = y, z_ = z or 0}, vec) end
  local player = {is_spell_ready = function() return s.ready end, is_dead = function() return false end}
  local env = setmetatable({
    vec3 = vec, vec2 = vec,
    get_time_since_inject = function() return s.now end,
    get_local_player = function() return player end,
    get_player_position = function() return vec:new(0, 0, 0) end,
    get_current_world = function() return nil end,
    cast_spell = {position = function() s.casts = s.casts + 1; return true end},
    console = {print = function(msg) s.logs[#s.logs + 1] = msg end},
    on_update = function() end, on_render = function() end,
    require = function(name) return assert(modules[name], name) end,
  }, {__index = _G})
  env._G = env
  local explorer = assert(loadfile(root .. 'core/explorer.lua', 't', env))()
  return explorer, s
end

local function spell_lines(s)
  local n = 0
  for _, l in ipairs(s.logs) do
    if tostring(l):lower():find('movement spell', 1, true) then n = n + 1 end
  end
  return n
end

-- (b) 10 calls within 5 s, every spell on cooldown: at most one line.
do
  local explorer, s = load_explorer()
  local target = {}
  for i = 1, 10 do
    explorer:movement_spell_to_target(target)
    s.now = s.now + 0.5
  end
  local n = spell_lines(s)
  assert(n <= 1, 'expected <= 1 movement spell line from 10 calls in 5 s, got ' .. n)
  print('PASS HordeDev movement spell spam: 10 calls in 5 s -> ' .. n .. ' line(s)')
end

-- (a) standing still 60 s, the stuck path calls every 0.45 s: at most one
-- line per 30 s, and casts still happen when spells are ready.
do
  local explorer, s = load_explorer()
  local target = {}
  s.ready = true
  local t_end = s.now + 60
  while s.now < t_end do
    explorer:movement_spell_to_target(target)
    s.now = s.now + 0.45
  end
  local n = spell_lines(s)
  assert(n >= 1 and n <= 2, 'expected 1..2 summary lines in 60 s, got ' .. n)
  assert(s.casts > 0, 'movement spells must still be cast')
  print('PASS HordeDev movement spell spam: 60 s of calls -> ' .. n .. ' line(s), casts=' .. s.casts)
end
