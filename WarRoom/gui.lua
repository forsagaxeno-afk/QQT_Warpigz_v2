-- QQT_Warpigz_v3: WarRoom menu. Buttons only raise a request here; main.lua
-- handles it on the next update (no file work inside the menu callback).
local gui = {}
local version = 'v1.0.3'
local plugin_label = 'war_room'

gui.version = version
gui.plugin_label = plugin_label
gui.request_reset = nil -- 'session' | 'today' | 'alltime'

gui.elements = {
    main_tree = tree_node:new(0),
    main_toggle = checkbox:new(true, get_hash(plugin_label .. '_main_toggle')),
    write_every = slider_int:new(5, 60, 15, get_hash(plugin_label .. '_write_every')),
    reset_session = button:new(get_hash(plugin_label .. '_reset_session')),
    reset_today = button:new(get_hash(plugin_label .. '_reset_today')),
    reset_alltime = button:new(get_hash(plugin_label .. '_reset_alltime')),
}

local function header(text)
    if type(render_menu_header) == 'function' then render_menu_header(text) end
end

function gui.render()
    local e = gui.elements
    if not e.main_tree:push('Z | War Room | Dashboard | ' .. version) then return end
    e.main_toggle:render('Enable', 'Collect statistics from the whole suite and write the web dashboard data (WarRoom\\dashboard\\suite_data.js)')
    if e.main_toggle:get() then
        e.write_every:render('Write every (s)', 'How often the dashboard data file is rewritten (5-60 s)', 1)
    end
    e.reset_session:render('Reset session stats', 'Clear this session: totals, timeline and the activity strip', 0)
    if e.reset_session:get() then gui.request_reset = 'session' end
    e.reset_today:render('Reset today stats', 'Clear today\'s totals (they also reset by themselves at local midnight)', 0)
    if e.reset_today:get() then gui.request_reset = 'today' end
    e.reset_alltime:render('Reset all-time stats', 'Clear the all-time totals and the notable drops list', 0)
    if e.reset_alltime:get() then gui.request_reset = 'alltime' end
    header('Open the dashboard: run WarRoom\\server\\serve.bat and open the address it prints,')
    header('or open WarRoom\\dashboard\\index.html in a browser.')
    e.main_tree:pop()
end

return gui
