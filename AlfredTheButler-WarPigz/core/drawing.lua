local gui          = require 'gui'
local settings     = require 'core.settings'
local task_manager = require 'core.task_manager'
local tracker      = require 'core.tracker'

local function get_affix_screen_position(item)
    local row, col = item:get_inventory_row(), item:get_inventory_column()

    local origin_x   = gui.elements.draw_inventory_origin_x:get()
    local origin_y   = gui.elements.draw_inventory_origin_y:get()
    local slot_w     = gui.elements.draw_offset_x:get()
    local slot_h     = gui.elements.draw_offset_y:get()
    local box_width  = gui.elements.draw_box_width:get()
    local box_height = gui.elements.draw_box_height:get()

    local x = origin_x + col * slot_w
    local y = origin_y + row * slot_h

    return x, y, box_width, box_height
end

local FONT        = 14
local FONT_HDR    = 17
local LINE_H      = 18
local HDR_H       = 26
local PAD_X       = 10
local PAD_Y       = 6

local COL_BG      = color.new(5, 5, 5, 5)
local COL_BORDER  = color.new(255, 130, 0, 230)
local COL_DIVIDER = color.new(255, 140, 0, 100)
local COL_HEADER  = color_orange(255)
local COL_TEXT    = color_white(255)
local COL_DIM     = color_white(140)
local COL_GREEN   = color_green(255)
local COL_ORANGE  = color_orange(255)
local COL_RED     = color_red(255)

local function status_color(s)
    local sl = string.lower(s)
    if sl:match('fail') or sl:match('stuck') then return COL_RED end
    if sl:match('retry') or sl:match('re%-try') or sl:match('reset') then return COL_ORANGE end
    if sl:match('wait') then return COL_ORANGE end
    if sl:match('paused') then return COL_DIM end
    if sl:match('idle') or sl:match('done') then return COL_GREEN end
    return COL_GREEN
end

local drawing = {}

function drawing.draw_status()
    local current_task = task_manager.get_current_task()
    local status = ''
    if tracker.external_pause then
        status = 'Paused by ' .. tostring(tracker.pause_caller or tracker.external_caller or '?')
    elseif not (settings.get_keybind_state() or tracker.external_trigger or tracker.manual_trigger) then
        status = 'Paused'
    elseif current_task and settings.allow_external and tracker.external_caller then
        status = '(' .. tracker.external_caller .. ') '
        -- plain replace: a caller name with pattern characters used to throw
        local text, prefix = tostring(current_task.status), '(' .. tostring(tracker.external_caller) .. ')'
        local at = text:find(prefix, 1, true)
        if at then text = text:sub(1, at - 1) .. text:sub(at + #prefix) end
        status = status .. text
    elseif current_task then
        status = '(' .. current_task.name .. ') ' .. current_task.status
    else
        status = 'Unknown'
    end

    local max = settings.max_stash_items or 350
    local stash_text, stash_col
    if tracker.stash_item_count_cached then
        local pct = tracker.stash_item_count_cached / max * 100
        stash_text = string.format('Stash     : %d/%d (%.0f%%)', tracker.stash_item_count_cached, max, pct)
        stash_col  = pct >= 90 and COL_RED or pct >= 70 and COL_ORANGE or COL_TEXT
    else
        stash_text = 'Stash     : --/-- (open stash to scan)'
        stash_col  = COL_DIM
    end

    local lines = {
        { text = 'Status    : ' .. status,                      col = status_color(status), bold = true },
        { text = 'Inventory : ' .. tracker.inventory_count,     col = COL_TEXT },
        { text = stash_text,                                     col = stash_col },
        { text = 'Keep      : ' .. tracker.stash_count,         col = COL_TEXT },
        { text = 'Salvage   : ' .. tracker.salvage_count,       col = COL_TEXT },
        { text = 'Sell      : ' .. tracker.sell_count,          col = COL_TEXT },
        { text = 'Tal Keep  : ' .. tracker.stash_talisman_count,    col = COL_TEXT },
        { text = 'Tal Salvage: ' .. tracker.salvage_talisman_count, col = COL_TEXT },
    }
    if settings.get_export_keybind_state() then
        lines[#lines+1] = { text = 'Export    : On', col = COL_GREEN }
    end

    local max_w = #'Alfred (WarPigz)' * FONT_HDR * 0.55
    for _, l in ipairs(lines) do
        local w = #l.text * FONT * 0.55
        if w > max_w then max_w = w end
    end

    local panel_w = max_w + PAD_X * 2
    local panel_h = HDR_H + #lines * LINE_H + PAD_Y * 2
    local x = 8 + gui.elements.draw_status_offset_x:get()
    local y = 50 + gui.elements.draw_status_offset_y:get()

    graphics.rect_filled(vec2:new(x, y), vec2:new(x + panel_w, y + panel_h), COL_BG)
    graphics.rect(vec2:new(x, y), vec2:new(x + panel_w, y + panel_h), COL_BORDER, 1, 3)
    graphics.text_2d('Alfred (WarPigz)', vec2:new(x + PAD_X + 2, y + PAD_Y), FONT_HDR, COL_HEADER)
    graphics.text_2d('Alfred (WarPigz)', vec2:new(x + PAD_X + 1, y + PAD_Y), FONT_HDR, COL_HEADER)
    graphics.text_2d('Alfred (WarPigz)', vec2:new(x + PAD_X,     y + PAD_Y), FONT_HDR, COL_HEADER)
    graphics.line(vec2:new(x + 4, y + HDR_H), vec2:new(x + panel_w - 4, y + HDR_H), COL_DIVIDER, 1)

    local ty = y + HDR_H + PAD_Y
    for _, l in ipairs(lines) do
        if l.bold then
            graphics.text_2d(l.text, vec2:new(x + PAD_X + 1, ty), FONT, l.col)
        end
        graphics.text_2d(l.text, vec2:new(x + PAD_X, ty), FONT, l.col)
        ty = ty + LINE_H
    end
end


function drawing.draw_inventory_boxes()
    local items = tracker.cached_inventory
    for _,cache in pairs(items) do
        local x, y, box_width, box_height = get_affix_screen_position(cache.item)
        local draw_affix = false
        if gui.elements.draw_stash:get() and cache.is_stash then
            graphics.rect(vec2:new(x, y), vec2:new(x + box_width, y + box_height), color_blue(255), 1, 4)
            draw_affix = true
        elseif gui.elements.draw_sell:get() and cache.is_sell then
            graphics.rect(vec2:new(x, y), vec2:new(x + box_width, y + box_height), color_pink(255), 1, 3)
            draw_affix = true
        elseif gui.elements.draw_salvage:get() and cache.is_salvage then
            graphics.rect(vec2:new(x, y), vec2:new(x + box_width, y + box_height), color_orange_red(255), 1, 3)
            draw_affix = true
        end
        if draw_affix then
            if cache.is_max_aspect and cache.affix_count > 0 then
                graphics.text_2d(tostring(cache.affix_count) .. "*", vec2:new(x + box_width - 24, y + box_height - 25), 20, color_white(255))
            elseif cache.is_max_aspect then
                graphics.text_2d("*", vec2:new(x + box_width - 15, y + box_height - 25), 20, color_white(255))
            elseif cache.affix_count > 0 then
                graphics.text_2d(tostring(cache.affix_count), vec2:new(x + box_width - 15, y + box_height - 25), 20, color_white(255))
            end
        end
        
    end

end


return drawing