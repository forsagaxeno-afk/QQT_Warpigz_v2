local plugin_label = 'alfred_the_butler'
-- kept plugin label instead of waiting for update_tracker to set it

local tracker = {
    name                      = plugin_label,
    version                   = nil,
    inventory_full            = false,
    inventory_count           = 0,
    salvage_count             = 0,
    salvage_talisman_count    = 0,
    stash_talisman_count      = 0,
    sell_count                = 0,
    stash_count               = 0,
    trigger_tasks             = false,
    last_reset                = 0,
    salvage_failed            = false,
    salvage_done              = false,
    salvage_talisman_failed   = false,
    salvage_talisman_done     = false,
    sell_failed               = false,
    sell_done                 = false,
    repair_failed             = false,
    repair_done               = false,
    stash_failed              = false,
    stash_done                = false,
    stash_full                = false,
    stash_item_count_cached   = nil,   -- last known count from when stash was open
    stash_pull_done           = false,
    stash_pull_failed         = false,
    pending_pulls             = {},
    all_task_done             = false,
    external_caller           = nil,
    external_trigger          = false,
    external_trigger_callback = nil,   -- last callback (compat); all are in the list below
    external_trigger_callbacks = {},   -- every caller waiting on the current cycle
    external_pause            = false,
    pause_caller              = nil,
    talisman_count            = 0,
    teleport                  = false,
    teleport_done             = false,
    teleport_failed           = false,
    manual_trigger            = false,
    last_task                 = 'status',
    previous                  = {},
    stash_socketables         = false,
    stash_keys                = false,
    stash_boss_materials      = false,
    stash_talisman_seal       = false,
    stash_talisman_charm      = false,
    salvage_talisman_seal     = false,
    salvage_talisman_charm    = false,
    cached_inventory          = {},

    need_repair               = false,
    need_trigger              = false,
    need_stash_socketables    = false,
    need_stash_consumables    = false,
    need_stash_keys           = false,
    talisman_inventory_full       = false,
    batmobile_resume          = nil,   -- true: Alfred paused a running Batmobile this cycle
    stuck                     = false, -- last cycle given up (stash full), see external.give_up
    stuck_reason              = nil,
}

return tracker