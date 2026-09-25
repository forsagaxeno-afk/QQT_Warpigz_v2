-- Private workers register here. Only Rosie's main registers with the host.
local M={}
local groups={}
function M.callbacks(owner)
    local group={update={},render={},menu={}}
    groups[owner]=group
    return {
        on_update=function(fn) group.update[#group.update+1]=fn end,
        on_render=function(fn) group.render[#group.render+1]=fn end,
        on_render_menu=function(fn) group.menu[#group.menu+1]=fn end,
    }
end
function M.run(owner,event)
    local group=groups[owner]
    if not group then return end
    for _,fn in ipairs(group[event]) do fn() end
end
return M
