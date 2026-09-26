local old=rawget(_G,'RosiePlugin')
local cached=type(old)=='table' and old._elements or nil
local conflict
for _,name in ipairs({'LooteerPlugin','AlfredTheButlerPlugin','PLUGIN_alfred_the_butler'}) do
    local peer=rawget(_G,name)
    if type(peer)=='table' and peer._rosie~=true then conflict='Unload the separate looter and Alfred addons, then reload Rosie.' end
end
if type(old)=='table' and type(old._owns_installation)=='function' and not old._owns_installation() then
    conflict=conflict or 'Another pickup or town addon loaded. Unload it, then reload Rosie.'
end
if conflict and type(old)=='table' and type(old._yield_movement)=='function' then old._yield_movement() end
if type(old)=='table' and type(old.shutdown)=='function' then old.shutdown() end
local movement_cleanup
if type(old)=='table' and type(old._take_movement_cleanup)=='function' then
    movement_cleanup=old._take_movement_cleanup()
end
-- QQT_Warpigz_v2 local patch (M1): if the host keeps package.loaded across a
-- reload, every rosie.* module would come back cached (the town and pickup
-- mains would not run again and the globals would stay on the retired
-- instance). The old instance is shut down and its cleanup taken above, so
-- start from fresh modules; a no-op on a host that already clears them.
if type(package)=='table' and type(package.loaded)=='table' then
    for name in pairs(package.loaded) do
        if type(name)=='string' and name:match('^rosie%.') then package.loaded[name]=nil end
    end
end
if movement_cleanup then require('rosie.movement').adopt_cleanup(movement_cleanup) end
local app=require('rosie.controller').new(cached,conflict)
if not conflict and type(old)=='table' and type(old._pending_pulls)=='function' then
    for _,entry in ipairs(old._pending_pulls()) do app.town.queue_stash_pull(entry.sno_id,entry.action) end
end
RosiePlugin=app.api
on_update(app.update)
on_render_menu(app.menu)
on_render(app.render)
