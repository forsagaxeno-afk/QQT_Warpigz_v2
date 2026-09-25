local M={}
local stack,error_message={},nil
local function push(node,label)
    if not node:push(label) then return false end
    stack[#stack+1]=node;return true
end
local function pop(node) node:pop();stack[#stack]=nil end
local function render(app)
    local e=app.elements
    if not push(e.root,'Rosie') then return false end
    if app.conflict then render_menu_header(app.conflict);pop(e.root);return true end
    e.enabled:render('Enable Rosie','One controller for pickup, bags, repairs and storage. Turning off cancels work.')
    app.refresh_preview()
    local status=app.overlay_status and app.overlay_status() or app.status()
    render_menu_header(status.detail)
    if app.notice then render_menu_header(app.notice) end
    if app.preview_error then
        render_menu_header(app.preview_error)
    else
        render_menu_header(string.format('Equipment: %d | Keep: %d | Salvage: %d | Sell: %d',
            status.town.inventory_count or 0,status.town.stash_count or 0,status.town.salvage_count or 0,status.town.sell_equipment_count or 0))
        render_menu_header(string.format('Talismans: %d | Keep: %d | Salvage: %d | Sell: %d',
            status.town.talisman_inventory_count or 0,status.town.stash_talisman_count or 0,
            status.town.salvage_talisman_count or 0,status.town.sell_talisman_count or 0))
    end
    if status.enabled then
        if status.town.running then
            e.stop:render('Stop Rosie','Cancel this trip, release owned resources and turn Rosie off.',0.25);app.actions.stop=true
        elseif status.town.enabled then
            e.service:render('Run town service','Service bags and repairs now, or retry after correcting a stopped trip.',0.25);app.actions.service=true
        else
            render_menu_header('Enable town service below to start a trip.')
        end
    end
    app.loot_gui.render()
    if app.loot_gui.render_error then error('Pickup settings could not be displayed.') end
    app.town_gui.render()
    if app.town_gui.render_error then error('Town settings could not be displayed.') end
    if push(e.storage,'Queued stash pulls') then
        render_menu_header('Run town service processes all matching unlocked stash copies of each queued Item ID.')
        render_menu_header("Rosie's automatic bag/repair trips defer this queue; an addon request can process it. Locked or unreadable copies remain protected and can stop the request.")
        local entries=app.town.get_pending_pulls()
        if #entries==0 then render_menu_header('No items queued.') end
        local catalog=require('rosie.data.items').by_id
        for _,entry in ipairs(entries) do
            local item=catalog[entry.sno_id]
            render_menu_header(tostring(item and item.name or 'Unknown item')..' [Item ID: '..tostring(entry.sno_id)..'] -> '..entry.action)
        end
        if not status.town.running then
            e.queue_id:render('Item ID','Use the Item ID shown in the named-item picker.',false,'','')
            e.queue_action:render('After pulling',{'Salvage','Sell'},'Applies to every matching unlocked stash copy, after its transfer is observed.')
            e.queue_add:render('Add to queue','Queue every matching unlocked stash copy for Run town service or an explicit request from another addon. Automatic bag/repair trips leave the queue pending.',0.25)
            app.actions.queue_add=true
            if #entries>0 then
                e.queue_clear:render('Clear queue','Remove pending requests without moving items.',0.25);app.actions.queue_clear=true
            end
        end
        pop(e.storage)
    end
    if push(e.movement,'Movement') then
        e.pace:render('Pace',{'Smooth and responsive','Fast'},'Paces movement requests. Both modes keep progress checks, interaction pauses and finite recovery.')
        render_menu_header(status.movement.detail)
        render_menu_header('Stable paths, measured progress and owned movement. Chat and loading pause work.')
        pop(e.movement)
    end
    if push(e.display,'Display and diagnostics') then
        e.overlay:render('Show Rosie status','Show the current phase and reason on screen.')
        e.diagnose:render('Log item and service decisions','Read-only console report of nearby drops, filter reasons and service state.',0.25)
        app.actions.diagnose=true
        render_menu_header('Season 15 | Item data '..require('rosie.data.items').build)
        render_menu_header('Host Auto Loot must be off for Rosie pickup rules to control drops.')
        pop(e.display)
    end
    pop(e.root);return true
end
function M.render(app)
    stack={}
    app.actions={}
    local ok,result=pcall(render,app)
    for i=#stack,1,-1 do pcall(function() stack[i]:pop() end) end
    stack={}
    if not ok then
        local message=tostring(result)
        if error_message~=message then console.print('[Rosie] Menu error: '..message) end
        error_message=message;app.actions={stop=app.actions.stop==true};return false
    end
    error_message=nil;return result==true
end
function M.overlay(app)
    local s=app.overlay_status and app.overlay_status() or app.status()
    graphics.text_2d('Rosie | '..s.phase,vec2:new(18,70),18,color_orange(255))
    graphics.text_2d(s.detail,vec2:new(18,94),14,color_white(255))
end
return M
