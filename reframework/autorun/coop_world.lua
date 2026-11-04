-- coop_world.lua: shared doors and items.
-- Events go through coop_enemies.lua's reliable channel (coop_send_event) and come back
-- through coop_world_on_event.
--   unlock <door id> <chapter>  a door was unlocked (key, one-way door, story)
--   open <door id> <chapter>    a door swung open
--   close <door id> <chapter>   it swung shut again
--   took <item id> <chapter> <item name>  a supply was picked up
--   break <box id> <chapter>    a breakable box (app.ItemDropDestruct) was smashed
--   drawer <id> <0|1> <chapter> a drawer (app.InteractDrawer) was shut / pulled open
--   intr <id> <chapter>         a one-off interaction (fridge, van, pot...) was completed
--   switch <id> <0|1> <chapter> a switch (app.InteractSwitch) was turned off / on
--   phys <key> <x y z> <qw qx qy qz> <chapter>  a loose physics prop (chair...) moved
-- Doors (app.DoorPush) and items (app.Item) carry SaveGUID, saved in the level, so the id
-- is the same on both PCs. Supplies (ammo, healing, materials, weapons) picked up by one
-- player vanish for the other (Item.disableFromScene); key items, files and maps stay in
-- both worlds so nobody gets stuck. A pickup for an area the other player hasn't loaded
-- yet is remembered and applied when it loads.

world_sync = {
    doors = {},        -- id -> { d = DoorPush, locked, open }
    doors_t = -100, poll_t = 0, items_t = -100,
    items = {},        -- id -> { it = Item, go }
    pending_took = {}, -- id -> chapter
    pending_unlock = {},  -- door id -> chapter (unlocked by the friend, not loaded here yet)
    pending_props = {},   -- "kind:id" -> { kind, id, want, ch } (same, for boxes/drawers/switches)
    applying = {},     -- id -> clock: changes we made on the friend's word (not sent back)
    props = {},        -- "box:<id>" / "drawer:<id>" -> { c = component, kind, on }
    props_t = -100,
    sent = 0, applied = 0, msg = "-", msg_t = -100,
}
local ws = world_sync

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t = {}, 0
local function log(s)
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_world_log.txt") or ""
    if #f > 200000 then f = f:sub(-100000) end
    fs.write("coop_world_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    return tonumber(gm and safe(gm.get_field, gm, "_CurrentChapter") or 0) or 0
end

local function note(msg)
    ws.msg, ws.msg_t = msg, os.clock()
    log(msg)
end

local function guid_text(g)
    local b = {}
    for i = 0, 7 do b[#b + 1] = string.format("%02x", (g:get_field("mData4_" .. i) or 0) & 0xFF) end
    return string.format("%08x-%04x-%04x-%s", (g:get_field("mData1") or 0) & 0xFFFFFFFF,
        (g:get_field("mData2") or 0) & 0xFFFF, (g:get_field("mData3") or 0) & 0xFFFF, table.concat(b))
end

local function id_of(comp)
    local g = safe(comp.get_field, comp, "SaveGUID")
    local t = g and safe(guid_text, g)
    if t == nil or t == "00000000-0000-0000-0000000000000000" then return nil end
    return t
end

local function send(text)
    if coop_send_event then coop_send_event(text) ws.sent = ws.sent + 1 log("sent: " .. text) end
end

local function scene()
    return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

-- Supplies are shared; weapons, keys, files and maps (ItemCategoryType 1, 4, 5, 6, 9, 10)
-- are not. Weapon pickups start story beats (the Chapter 1 handgun): taking one away
-- froze the friend mid-pickup (2026-11-02).
local KEYISH = { [1] = true, [4] = true, [5] = true, [6] = true, [9] = true, [10] = true }
local function is_supply(it)
    local d = safe(it.call, it, "get_ItemData")
    local cat = d and safe(d.get_field, d, "Category")
    return cat ~= nil and not KEYISH[cat]
end

-- Doors ------------------------------------------------------------------------------
-- doorState: 0 closed, 1 locked, 2 little open (creaks ajar as you approach), 3 pushed,
-- 4 auto-opening, 5 opened, 6 auto-closing. Only 3-5 count as "opened by someone".
local function is_open(state) return state ~= nil and state >= 3 and state <= 5 end

local function refresh_doors()
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.DoorPush"))
    local seen = {}
    for _, d in ipairs(arr and arr:get_elements() or {}) do
        local id = id_of(d)
        if id then
            seen[id] = true
            if ws.doors[id] == nil or ws.doors[id].d ~= d then
                ws.doors[id] = { d = d, locked = d:call("get_isLocked") == true,
                    open = is_open(d:call("get_doorState")) }
            end
        end
    end
    for id in pairs(ws.doors) do if not seen[id] then ws.doors[id] = nil end end
end

-- An "open" that didn't take (v0.25): 87 of 106 remote opens in three sessions left the door
-- at state 0 or 1, the latched main-house doors. Checked 0.7 s later and retried from the
-- other two sides (OpenSide 0 and 1; 2 was the only one used). Every try is logged.
ws.open_retry = {}
function check_open_retry(id, s, state, now)
    local r = ws.open_retry[id]
    if r == nil or now < r.t then return end
    if is_open(state) or state == 4 then
        log(string.format("door %s opened (state %d, side %s)", id, state, tostring(r.side)))
        ws.open_retry[id] = nil
        return
    end
    local side = table.remove(r.sides, 1)
    if side == nil then
        log(string.format("door %s didn't open (state %d): needs its handle (app.InteractDoor)", id, state))
        ws.open_retry[id] = nil
        return
    end
    ws.applying[id] = now
    local ok, err = pcall(s.d.call, s.d, "requestAutoOpen(app.DoorPush.OpenSide)", side)
    r.side, r.t = side, now + 0.7
    if not ok then log("door " .. id .. " open side " .. side .. " ERR " .. tostring(err)) end
end

local function player_near_door(s, m)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local pp = p and safe(function() return p:call("get_Transform"):call("get_Position") end)
    local dp = safe(function() return s.d:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    if pp == nil or dp == nil then return false end
    return (pp.x - dp.x) ^ 2 + (pp.z - dp.z) ^ 2 < m * m
end

local function poll_doors(now)
    -- Only doors the scene still has (v0.24): one unloaded by an area change threw inside the
    -- game, like the pushed objects did (see poll_phys).
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.DoorPush"))
    if arr == nil then return end
    local live = {}
    for _, d in ipairs(arr:get_elements() or {}) do live[d:get_address()] = true end
    ws.door_sent = ws.door_sent or {}
    -- Each open or close went out twice (the door passes through a middle state): the same
    -- message for the same door within 2 s is sent once.
    local function send_once(kind, id)
        local k = kind .. id
        if ws.door_sent[k] and now - ws.door_sent[k] < 2 then return end
        ws.door_sent[k] = now
        send(string.format("%s %s %d", kind, id, chapter()))
    end
    for id, s in pairs(ws.doors) do
        local d = s.d
        if not live[d:get_address()] then
            ws.doors[id] = nil
        else
            local locked = safe(d.call, d, "get_isLocked") == true
            local state = safe(d.call, d, "get_doorState") or 0
            local open = is_open(state)
            local ours = ws.applying[id] and now - ws.applying[id] < 3
            if s.locked and not locked and not ours then send_once("unlock", id) end
            if open and not s.open and not ours then send_once("open", id) end
            -- A door that swings shut by itself goes through state 6 (auto-closing): that's the
            -- game, not the player, and sending it slammed the door on the other player as
            -- they walked through (2026-11-03). Only a close straight from open is sent.
            if s.open and not open and not ours and state ~= 6 and s.state ~= 6 then send_once("close", id) end
            s.locked, s.open, s.state = locked, open, state
            pcall(check_open_retry, id, s, state, now)
        end
    end
end

local function apply_door(kind, id, ch)
    if ch ~= chapter() then return end
    local s = ws.doors[id]
    if s == nil then
        if kind == "unlock" then
            ws.pending_unlock[id] = ch   -- applied when that area loads here
            log("remembered unlock: " .. id)
        else
            log("door not loaded here: " .. kind .. " " .. id)
        end
        return
    end
    ws.applying[id] = os.clock()
    if kind == "unlock" then
        if s.d:call("get_isLocked") then
            pcall(s.d.call, s.d, "unlockDoor")
            note("your friend unlocked a door")
        end
    elseif kind == "open" then
        local before = s.d:call("get_doorState")
        if not is_open(before) and not s.d:call("get_isLocked") then
            local ok, err = pcall(s.d.call, s.d, "requestAutoOpen(app.DoorPush.OpenSide)", 2)
            log(string.format("opening door %s (state %s)%s", id, tostring(before), ok and "" or (" ERR " .. tostring(err))))
            ws.open_retry[id] = { t = os.clock() + 0.7, side = 2, sides = { 0, 1 } }
        else
            log(string.format("open door %s: already state %s, locked %s", id, tostring(before),
                tostring(s.d:call("get_isLocked"))))
        end
    elseif kind == "close" then
        if player_near_door(s, 2.5) then
            log("close door " .. id .. ": not closed, you're in the doorway")
        elseif is_open(s.d:call("get_doorState")) then
            local ok, err = pcall(s.d.call, s.d, "requestClosed(System.Boolean)", false)
            log("closed door " .. id .. (ok and "" or (" ERR " .. tostring(err))))
        end
    end
    ws.applied = ws.applied + 1
end

-- Items ------------------------------------------------------------------------------
-- "Share supplies" (off by default since v0.22): on, ammo and healing are one copy for both
-- players (whoever picks it up takes it from both worlds, the harder way to play); off, each
-- player gets their own. Each game applies its own player's choice, so set it the same.
local function supplies_shared() return settings ~= nil and settings.share_supplies == true end

-- Items dropped by smashed boxes: each player gets their own (the friend's game rolls its
-- own from the box's table), so their pickups are never shared. Both games' copies may
-- carry the same SaveGUID.
function box_item_ids()
    ws.box_items = ws.box_items or {}
    for _, s in pairs(ws.props or {}) do
        if s.kind == "box" then
            local di = safe(s.c.get_field, s.c, "DropItem")
            local it = di and safe(di.call, di, "getComponent(System.Type)", sdk.typeof("app.Item"))
            local id = it and id_of(it)
            if id then ws.box_items[id] = true end
        end
    end
end

local function refresh_items()
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.Item"))
    local seen = {}
    for _, it in ipairs(arr and arr:get_elements() or {}) do
        local id = id_of(it)
        if id then
            seen[id] = true
            if ws.items[id] == nil then
                local go = it:call("get_GameObject")
                ws.items[id] = { it = it, go = go, state = safe(it.call, it, "getItemState"),
                    pos = safe(function() return go:call("get_Transform"):call("get_Position") end) }
            end
            ws.items[id].it = it
        end
    end
    for id in pairs(ws.items) do if not seen[id] then ws.items[id] = nil end end
    box_item_ids()
    -- Pickups the friend made before this area was loaded here.
    for id, ch in pairs(supplies_shared() and ws.pending_took or {}) do
        local e = ws.items[id]
        if e and ch == chapter() and safe(e.go.call, e.go, "get_Draw") then
            ws.pending_took[id] = nil
            ws.applying[id] = os.clock()
            pcall(e.it.call, e.it, "disableFromScene")
            note("your friend already took " .. tostring(e.it:get_field("ItemDataID")) .. " here")
        end
    end
end

local function apply_took(id, ch, name)
    if ch ~= chapter() then return end
    if not supplies_shared() then log("friend took " .. tostring(name) .. ": yours stays (Share supplies is off)") return end
    if ws.box_items and ws.box_items[id] then log("box item stays here: " .. name) return end
    local e = ws.items[id]
    if e and safe(e.go.call, e.go, "get_Draw") then
        ws.applying[id] = os.clock()
        pcall(e.it.call, e.it, "disableFromScene")
        ws.applied = ws.applied + 1
        note("your friend took " .. name)
    else
        ws.pending_took[id] = ch   -- not loaded (or not shown) yet: when it is
        log("remembered pickup: " .. name .. " " .. id)
    end
end

-- Our pickups. A pickup doesn't go through Item.changeStateInventoryIn (a hook there never
-- fired): the game hides the item lying in the world (getItemState 0 -> 6, as
-- disableFromScene does) and makes a separate inventory Item. So watch world items for
-- 0 -> 6, except the ones we hid on the friend's word.
-- Leaving an area hides its items the same way (2026-11-03: 8 "pickups" at once on an area
-- change, all without an ItemDataID, and the same items again and again): only an item with
-- a name, within reach of us, counts, and each item is reported once.
local ITEM_IN_SCENE, ITEM_GONE = 0, 6
local PICKUP_REACH = 4.0
ws.reported = ws.reported or {}
local function within_reach(e)
    if e.pos == nil then return false end
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    local pp = player and safe(function() return player:call("get_Transform"):call("get_Position") end)
    if pp == nil then return false end
    return (pp.x - e.pos.x) ^ 2 + (pp.y - e.pos.y) ^ 2 + (pp.z - e.pos.z) ^ 2 < PICKUP_REACH * PICKUP_REACH
end
local function poll_items(now)
    for id, e in pairs(ws.items) do
        local st = safe(e.it.call, e.it, "getItemState")
        if e.state == ITEM_IN_SCENE and st == ITEM_GONE then
            local ours = ws.applying[id] and now - ws.applying[id] < 3
            if ws.box_items and ws.box_items[id] then
                ours = true   -- a box's item: the friend has their own
            end
            if not ours and (ws.reported[id] or e.it:get_field("ItemDataID") == nil or not within_reach(e)) then
                ws.not_pickup = ws.not_pickup or {}
                if not ws.reported[id] and not ws.not_pickup[id] then
                    ws.not_pickup[id] = true
                    log(string.format("not a pickup (no name or out of reach): %s %s", id, tostring(e.it:get_field("ItemDataID"))))
                end
                ours = true
            end
            if not ours then ws.reported[id] = true end
            if not ours and is_supply(e.it) then
                send(string.format("took %s %d %s", id, chapter(), tostring(e.it:get_field("ItemDataID"))))
            elseif not ours then
                -- Keys, weapons, files: they stay for the friend, who is told to pick them up too
                -- (their pickup can start a scripted moment in their game, like Jack's wall).
                send(string.format("got %s %d %s", id, chapter(), tostring(e.it:get_field("ItemDataID"))))
            end
        end
        e.state = st
    end
end

-- Boxes and drawers -----------------------------------------------------------------
-- Both carry SaveGUID (boxes their own, drawers from InteractObjectBase). A smashed box
-- is smashed for both (each game drops its own item; the supply rule then shares the
-- pickup). Drawers follow open/shut. Untested on a real session yet: every apply logs
-- the state before and after.
local PROP_TYPES = {
    { kind = "box", type = "app.ItemDropDestruct", state = function(c) return c:get_field("IsBreaked") == true end },
    { kind = "drawer", type = "app.InteractDrawer", state = function(c) return c:get_field("NowDrawerOpen") == true end },
    -- One-off interactions (open the fridge, the van, stir the pot...): app.InteractSendFsm and
    -- app.InteractLongPressSendFSM count successes in InteractObjectBase.InteractSuccessCount;
    -- the other game runs successInteract(), the game's own "done" step. Experimental: it can
    -- only be judged in play, so "Share interactions" can switch it off.
    { kind = "intr", type = "app.InteractSendFsm", optional = true,
        state = function(c) return (tonumber(c:get_field("InteractSuccessCount")) or 0) > 0 end },
    { kind = "intr", type = "app.InteractLongPressSendFSM", optional = true,
        state = function(c) return (tonumber(c:get_field("InteractSuccessCount")) or 0) > 0 end },
    { kind = "switch", type = "app.InteractSwitch", optional = true,
        state = function(c) return c:get_field("NowSwitchOn") == true end },
}
local function interactions_shared() return not (settings and settings.share_interactions == false) end
-- Never share these: saving (tape recorders), VHS tapes (followed separately), item boxes,
-- cutscene triggers. Matched on the names of the interactable's GameObject, its parent and
-- grandparent: the interactable itself is mostly just "InteractSendFsm" and the telling name
-- is on its parent (sm0113_Phone01A_AnswerPhoneCodex), so until v0.20 this list never matched.
-- Weapons and items stay per player (v0.23): the shotgun on the hall statue is a trap you
-- disarm by putting the broken shotgun back. Sharing that statue let the friend take the
-- shotgun for free (2026-11-03), so anything that hands out a weapon or an item is skipped.
-- Nor anything that moves the player or opens a view: run on the other game, "get into the
-- car" or "start the shadow puzzle" would do it to the friend wherever they stand (the car's
-- get-in and get-out went across in the 2026-11-03 session).
local INTR_SKIP = { "save", "tape", "video", "vhs", "record", "itembox", "event", "cs_",
    "shotgun", "statue", "pendulum", "item", "wp0", "wp1", "wp2", "wp4",
    "getinto", "getout", "ignition", "ethancar", "puzzle", "ladder", "hide", "crouch", "climb" }
local function intr_names(c)
    local out = {}
    local go = safe(c.call, c, "get_GameObject")
    for _ = 1, 3 do
        if go == nil then break end
        out[#out + 1] = tostring(safe(go.call, go, "get_Name") or ""):lower()
        local tr = safe(go.call, go, "get_Transform")
        local par = tr and safe(tr.call, tr, "get_Parent")
        go = par and safe(par.call, par, "get_GameObject")
    end
    return table.concat(out, "/")
end
-- Phones are shared on purpose (v0.20): when one player answers a call, the other's phone is
-- answered too, so both don't have to take every call to move on.
local function is_phone(c) return intr_names(c):find("phone", 1, true) ~= nil end
local function intr_allowed(c)
    local names = intr_names(c)
    if names:find("phone", 1, true) then return true end
    for _, w in ipairs(INTR_SKIP) do if names:find(w, 1, true) then return false end end
    return true
end

-- Finding what isn't shared yet (v0.23). The garage-door button and the shadow puzzle's
-- unlock never reached the other game, and nothing in the logs said what they are. Every
-- finished interaction the game reports (InteractObjectBase.successInteract) that isn't one of
-- the kinds above is now written to this log with its type and names, so the next bug report
-- shows what to add. Logging only: nothing is sent.
-- What the latched doors and lockpicked drawers can do (v0.25): their method names go to the
-- log once, so the next build can drive them. Names only: nothing is called.
do
    for _, tn in ipairs({ "app.DoorPush", "app.InteractDoor", "app.InteractDetailSearch", "app.InteractSendFsm" }) do
        local td = sdk.find_type_definition(tn)
        local names = {}
        for _, m in ipairs(td and td:get_methods() or {}) do
            names[#names + 1] = m:get_name() .. "/" .. m:get_num_params()
        end
        local fields = {}
        for _, f in ipairs(td and td:get_fields() or {}) do fields[#fields + 1] = f:get_name() end
        log(string.format("type %s: %d methods: %s | fields: %s", tn, #names, table.concat(names, " "), table.concat(fields, " ")))
    end
end
local TRACKED_TYPES = {}
for _, pt in ipairs(PROP_TYPES) do TRACKED_TYPES[pt.type] = true end
do
    local seen = {}
    local td = sdk.find_type_definition("app.InteractObjectBase")
    local hooked = 0
    for _, m in ipairs(td and td:get_methods() or {}) do
        local mname = m:get_name()
        if mname == "successInteract" or mname == "startInteract" then
            local ok = pcall(sdk.hook, m, function(args)
                pcall(function()
                    local c = sdk.to_managed_object(args[2])
                    if c == nil then return end
                    local tn = c:get_type_definition():get_full_name()
                    if TRACKED_TYPES[tn] and mname == "successInteract" then return end
                    local key = mname .. ":" .. tn .. ":" .. tostring(id_of(c) or intr_names(c))
                    if seen[key] then return end
                    seen[key] = true
                    log(string.format("not shared yet: %s %s (%s) id %s", mname, tn, intr_names(c), tostring(id_of(c))))
                end)
            end, function(r) return r end)
            if ok then hooked = hooked + 1 end
        end
    end
    log("interaction finder: " .. hooked .. " hooks")
end

local function refresh_props()
    local sc = scene()
    if sc == nil then return end
    local seen = {}
    for _, pt in ipairs(PROP_TYPES) do
        local arr = safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof(pt.type))
        for _, c in ipairs(arr and arr:get_elements() or {}) do
            local id = id_of(c)
            if id then
                local key = pt.kind .. ":" .. id
                seen[key] = true
                if ws.props[key] == nil or ws.props[key].c ~= c then
                    ws.props[key] = { c = c, kind = pt.kind, id = id, pt = pt, on = safe(pt.state, c) == true }
                end
            end
        end
    end
    for key in pairs(ws.props) do if not seen[key] then ws.props[key] = nil end end
end

local function poll_props(now)
    for key, s in pairs(ws.props) do
        local on = safe(s.pt.state, s.c) == true
        local ours = ws.applying[key] and now - ws.applying[key] < 3
        if on ~= s.on and not ours then
            if s.kind == "box" and on then send(string.format("break %s %d", s.id, chapter()))
            elseif s.kind == "drawer" then send(string.format("drawer %s %d %d", s.id, on and 1 or 0, chapter()))
            elseif s.kind == "intr" and on and interactions_shared() and intr_allowed(s.c) then
                send(string.format("intr %s %d%s", s.id, chapter(), is_phone(s.c) and " phone" or ""))
            elseif s.kind == "switch" and interactions_shared() then
                send(string.format("switch %s %d %d", s.id, on and 1 or 0, chapter()))
            end
        end
        s.on = on
    end
end

local function apply_prop(kind, id, want, ch, phone)
    if ch ~= chapter() then return end
    local key = kind .. ":" .. id
    local s = ws.props[key]
    if s == nil then
        if kind ~= "intr" or phone then
            -- Boxes, drawers and switches keep their state: applied when that area loads here.
            -- One-off interactions aren't replayed later (they can start scripted moments).
            ws.pending_props[key] = { kind = kind, id = id, want = want, ch = ch, phone = phone }
            log("remembered " .. kind .. ": " .. id)
        else
            log(kind .. " not loaded here: " .. id)
        end
        return
    end
    local before = safe(s.pt.state, s.c) == true
    if before == want then return end
    ws.applying[key] = os.clock()
    local ok, err
    if kind == "box" then
        -- RigidBodyDestruct.setBreak(dir, pos, normal, attacker, type) always threw from Lua
        -- (and crashed the game once with the player as attacker); setAlreadyBreak takes no
        -- arguments, the state a box smashed in the save loads in. It (and dispBreakAfter,
        -- breakObjectWithoutSetBreak) leaves the box drawn, so the box is also hidden and
        -- its collision and physics switched off: it's simply gone (no pieces). Both players
        -- get the contents: setItem() (the box's own drop, rolled from its table here) makes
        -- the item as a child of the box at the world origin; it's detached and put where
        -- the box stood. Box items are never shared pickups (see box_item_ids).
        if s.c:get_field("DropItem") == nil and s.c:get_field("IsDropItem") ~= true then
            local iok, ierr = pcall(s.c.call, s.c, "setItem")
            if not iok then log("box item ERR " .. tostring(ierr)) end
        end
        local rb = safe(s.c.get_field, s.c, "RigidBodyCompo")
        if rb then
            ok, err = pcall(rb.call, rb, "setAlreadyBreak")
            if ok then pcall(s.c.set_field, s.c, "IsBreaked", true) end
        else
            ok, err = false, "no RigidBodyCompo"
        end
        local go = s.c:call("get_GameObject")
        safe(go.call, go, "set_DrawSelf", false)
        for _, tn in ipairs({ "via.physics.Colliders", "via.dynamics.RigidBodySet" }) do
            local comp = safe(go.call, go, "getComponent(System.Type)", sdk.typeof(tn))
            if comp then safe(comp.call, comp, "set_Enabled", false) end
        end
        local di = s.c:get_field("DropItem")
        local bp = safe(function() return go:call("get_Transform"):call("get_Position") end)
        if di and bp then
            local itr = di:call("get_Transform")
            safe(itr.call, itr, "set_Parent", nil)
            safe(itr.call, itr, "set_Position", Vector3f.new(bp.x, bp.y + 0.1, bp.z))
            safe(di.call, di, "set_DrawSelf", true)
            note("your friend smashed a box (its item is there for you too)")
        else
            note("your friend smashed a box")
        end
    elseif kind == "intr" then
        if not intr_allowed(s.c) then log("intr " .. id .. ": not shared here (save, tape, item box...): " .. intr_names(s.c)) return end
        ok, err = pcall(s.c.call, s.c, "successInteract")
        if phone or is_phone(s.c) then
            note("your friend answered the phone: the call plays for you too")
        else
            note("your friend used something here (" .. intr_names(s.c) .. ")")
        end
    elseif kind == "switch" then
        ok, err = pcall(s.c.call, s.c, "SetSwitch(System.Boolean)", want)
        note(want and "your friend switched something on" or "your friend switched something off")
    else
        ok, err = pcall(s.c.call, s.c, "SetSwitch(System.Boolean)", want)
        note(want and "your friend opened a drawer" or "your friend shut a drawer")
    end
    log(string.format("%s %s: %s -> %s%s", kind, id, tostring(before), tostring(safe(s.pt.state, s.c)),
        ok and "" or (" ERR " .. tostring(err))))
    ws.applied = ws.applied + 1
end

-- Loose physics props ----------------------------------------------------------------
-- Chairs, bottles and the like (app.Havok.RigidBodyDynamics) have no SaveGUID; both games
-- load them at the same spot, so the key is the GameObject name plus where it was first
-- seen. Props within 12 m that moved are sent up to 4 times a second; the other game
-- re-places its copy (physics off, move, physics on). Untested (first build, 2026-11-03):
-- "Share pushed objects" switches it off, and the first moves are logged in detail.
ws.phys = {}            -- key -> { c, go, last = {x,y,z}, sent_t }
ws.phys_t, ws.phys_logged = -100, 0
local PHYS_NEAR, PHYS_MOVE = 12, 0.15
local function phys_shared() return not (settings and settings.share_physics == false) end

local function refresh_phys()
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.Havok.RigidBodyDynamics"))
    local seen = {}
    for _, c in ipairs(arr and arr:get_elements() or {}) do
        local go = safe(c.call, c, "get_GameObject")
        ws.phys_by_addr = ws.phys_by_addr or {}
        local known = ws.phys_by_addr[c:get_address()]
        if known and ws.phys[known] then seen[known] = true
        elseif go then
            local p = safe(function() return go:call("get_Transform"):call("get_Position") end)
            if p then
                local key = string.format("%s@%.1f,%.1f,%.1f", tostring(go:call("get_Name")), p.x, p.y, p.z)
                if ws.phys[key] == nil then
                    ws.phys[key] = { key = key, c = c, go = go, last = { x = p.x, y = p.y, z = p.z }, sent_t = -100 }
                end
                ws.phys_by_addr[c:get_address()] = key
                seen[key] = true
            end
        end
    end
    for key in pairs(ws.phys) do if not seen[key] then ws.phys[key] = nil end end
end

local function poll_phys(now)
    if not phys_shared() then return end
    local om = sdk.get_managed_singleton("app.ObjectManager")   -- nil while a load starts
    local player = om and om:get_field("PlayerObj")
    if player == nil then return end
    local pp = player:call("get_Transform"):call("get_Position")
    -- Which props still exist, asked of the scene first (v0.23): a door into another area
    -- unloads them, and the first call on each gone one threw inside the game. Both logs of
    -- the 2026-11-03 session had about 565 of those, in bursts at every door, and three
    -- "VMContext was already corrupted" warnings, which can end in a crash.
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.Havok.RigidBodyDynamics"))
    if arr == nil then return end
    local live = {}
    for _, c in ipairs(arr:get_elements() or {}) do live[c:get_address()] = true end
    for key, s in pairs(ws.phys) do
        if not live[s.c:get_address()] then
            ws.phys[key] = nil
            if ws.phys_by_addr then ws.phys_by_addr[s.c:get_address()] = nil end
            goto continue
        end
        local tr = safe(s.go.call, s.go, "get_Transform")
        local p = tr and safe(tr.call, tr, "get_Position")
        if p == nil then
            -- Unloaded (area change): every call on it throws a game exception (about 2,700
            -- logged in a minute once), so forget it now instead of at the next refresh.
            ws.phys[key] = nil
            if ws.phys_by_addr then ws.phys_by_addr[s.c:get_address()] = nil end
        elseif (p.x - pp.x) ^ 2 + (p.z - pp.z) ^ 2 < PHYS_NEAR * PHYS_NEAR then
            local moved = math.sqrt((p.x - s.last.x) ^ 2 + (p.y - s.last.y) ^ 2 + (p.z - s.last.z) ^ 2)
            local ours = ws.applying["phys:" .. key] and now - ws.applying["phys:" .. key] < 2
            if moved > PHYS_MOVE and not ours and now - s.sent_t > 0.25 then
                local q = tr:call("get_Rotation")
                s.last, s.sent_t = { x = p.x, y = p.y, z = p.z }, now
                send(string.format("phys %s %.3f %.3f %.3f %.4f %.4f %.4f %.4f %d", key, p.x, p.y, p.z,
                    q.w, q.x, q.y, q.z, chapter()))
            elseif ours then
                s.last = { x = p.x, y = p.y, z = p.z }
            end
        end
        ::continue::
    end
end

local function apply_phys(key, x, y, z, qw, qx, qy, qz, ch)
    if ch ~= chapter() or not phys_shared() then return end
    local s = ws.phys[key]
    if s == nil then return end
    ws.applying["phys:" .. key] = os.clock()
    local tr = s.go:call("get_Transform")
    local before = tr:call("get_Position")
    pcall(s.c.call, s.c, "disable")
    tr:call("set_Position", Vector3f.new(x, y, z))
    tr:call("set_Rotation", Quaternion.new(qw, qx, qy, qz))
    pcall(s.c.call, s.c, "enable")
    s.last = { x = x, y = y, z = z }
    if ws.phys_logged < 10 then
        ws.phys_logged = ws.phys_logged + 1
        local after = tr:call("get_Position")
        log(string.format("phys %s: %.2f %.2f %.2f -> wanted %.2f %.2f %.2f, now %.2f %.2f %.2f", key,
            before.x, before.y, before.z, x, y, z, after.x, after.y, after.z))
    end
end

-- Changes the friend made in an area that wasn't loaded here, applied once it is.
local function apply_pending()
    for id, ch in pairs(ws.pending_unlock) do
        if ws.doors[id] and ch == chapter() then
            ws.pending_unlock[id] = nil
            pcall(apply_door, "unlock", id, ch)
        end
    end
    for key, p in pairs(ws.pending_props) do
        if ws.props[key] and p.ch == chapter() then
            ws.pending_props[key] = nil
            pcall(apply_prop, p.kind, p.id, p.want, p.ch, p.phone)
        end
    end
end

-- Incoming events (called by coop_enemies.lua). Returns true if it was ours.
function coop_world_on_event(text)
    local kind, id, ch = text:match("^(unlock) (%S+) (%-?%d+)")
    if not kind then kind, id, ch = text:match("^(open) (%S+) (%-?%d+)") end
    if not kind then kind, id, ch = text:match("^(close) (%S+) (%-?%d+)") end
    if kind then pcall(apply_door, kind, id, tonumber(ch)) return true end
    local bid, bch = text:match("^break (%S+) (%-?%d+)")
    if bid then pcall(apply_prop, "box", bid, true, tonumber(bch)) return true end
    local did, don, dch = text:match("^drawer (%S+) ([01]) (%-?%d+)")
    if did then pcall(apply_prop, "drawer", did, don == "1", tonumber(dch)) return true end
    local iid, ich, itag = text:match("^intr (%S+) (%-?%d+) ?(%a*)")
    if iid then
        -- Phone calls move the story on, so they have their own switch ("Share phone calls",
        -- on by default), apart from "Share interactions".
        local phone = itag == "phone"
        if phone and settings and settings.share_phones == false then
            log("phone call not shared (Share phone calls is off): " .. iid)
        elseif phone or interactions_shared() then
            pcall(apply_prop, "intr", iid, true, tonumber(ich), phone)
        end
        return true
    end
    local sid, son, sch = text:match("^switch (%S+) ([01]) (%-?%d+)")
    if sid then
        if interactions_shared() then pcall(apply_prop, "switch", sid, son == "1", tonumber(sch)) end
        return true
    end
    local gid, gch, gname = text:match("^got (%S+) (%-?%d+) (%S+)")
    if gid then
        if tonumber(gch) == chapter() then
            local e = ws.items[gid]
            local here = e and safe(e.go.call, e.go, "get_Draw")
            note("your friend picked up " .. gname .. (here and ": pick it up too, it's still here for you" or ""))
        end
        return true
    end
    local pk, px, py, pz, pqw, pqx, pqy, pqz, pch =
        text:match("^phys (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%-?%d+)")
    if pk then
        pcall(apply_phys, pk, tonumber(px), tonumber(py), tonumber(pz), tonumber(pqw), tonumber(pqx),
            tonumber(pqy), tonumber(pqz), tonumber(pch))
        return true
    end
    local tid, tch, tname = text:match("^took (%S+) (%-?%d+) (%S+)")
    if tid then pcall(apply_took, tid, tonumber(tch), tname) return true end
    return false
end

re.on_frame(function()
    local now = os.clock()
    if now - ws.doors_t > 3 then
        ws.doors_t = now
        local ok, err = pcall(refresh_doors)
        if not ok and not ws.door_err then ws.door_err = true log("doors ERR " .. tostring(err)) end
    end
    if now - ws.props_t > 3 then
        ws.props_t = now
        local ok, err = pcall(refresh_props)
        if not ok and not ws.prop_err then ws.prop_err = true log("props ERR " .. tostring(err)) end
        local fok, ferr = pcall(refresh_phys)
        if not fok and not ws.phys_err then ws.phys_err = true log("phys ERR " .. tostring(ferr)) end
        local aok, aerr = pcall(apply_pending)
        if not aok and not ws.pend_err then ws.pend_err = true log("pending ERR " .. tostring(aerr)) end
    end
    if now - ws.items_t > 2 then
        ws.items_t = now
        local ok, err = pcall(refresh_items)
        if not ok and not ws.item_err then ws.item_err = true log("items ERR " .. tostring(err)) end
    end
    if now - ws.poll_t > 0.25 then
        ws.poll_t = now
        local ok, err = pcall(poll_doors, now)
        if not ok and not ws.poll_err then ws.poll_err = true log("door poll ERR " .. tostring(err)) end
        local fpok, fperr = pcall(poll_phys, now)
        if not fpok and not ws.phys_poll_err then ws.phys_poll_err = true log("phys poll ERR " .. tostring(fperr)) end
        local pok, perr = pcall(poll_props, now)
        if not pok and not ws.ppoll_err then ws.ppoll_err = true log("prop poll ERR " .. tostring(perr)) end
        local iok, ierr = pcall(poll_items, now)
        if not iok and not ws.ipoll_err then ws.ipoll_err = true log("item poll ERR " .. tostring(ierr)) end
    end
end)

-- On-screen line (coop_dummy shows it).
function world_sync_hud()
    if os.clock() - ws.msg_t < 6 then return "World: " .. ws.msg end
    return nil
end

function world_sync_status()
    local doors, locked, items, pend = 0, 0, 0, 0
    for _, s in pairs(ws.doors) do doors = doors + 1 if s.locked then locked = locked + 1 end end
    for _ in pairs(ws.items) do items = items + 1 end
    for _ in pairs(ws.pending_took) do pend = pend + 1 end
    return string.format("Doors and items: %d doors (%d locked), %d items here; sent %d, applied %d, remembered %d",
        doors, locked, items, ws.sent, ws.applied, pend)
end

-- Testing: the bot "opens" / "unlocks" the nearest door, or "takes" the nearest supply.
local function nearest(list, pick)
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    if player == nil then return nil end
    local pp = player:call("get_Transform"):call("get_Position")
    local best, best_id, best_d
    for id, e in pairs(list) do
        if pick(e) then
            local go = e.go or e.d:call("get_GameObject")
            local p = go:call("get_Transform"):call("get_Position")
            local dd = (p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2 + (p.z - pp.z) ^ 2
            if best_d == nil or dd < best_d then best, best_id, best_d = e, id, dd end
        end
    end
    return best, best_id
end

function world_sync_bot(kind)
    if kind == "unlock" or kind == "open" then
        local _, id = nearest(ws.doors, function(s)
            if kind == "unlock" then return s.locked end
            return not s.locked and not s.open
        end)
        if id == nil then return "no suitable door nearby" end
        fs.write("coopnet_command.txt", string.format("botevent %s %s %d", kind, id, chapter()))
        return "the bot will " .. kind .. " the nearest door"
    elseif kind == "took" then
        local e, id = nearest(ws.items, function(e) return safe(e.go.call, e.go, "get_Draw") and is_supply(e.it) end)
        if id == nil then return "no supply nearby" end
        local name = tostring(e.it:get_field("ItemDataID"))
        fs.write("coopnet_command.txt", string.format("botevent took %s %d %s", id, chapter(), name))
        return "the bot will take " .. name
    elseif kind == "break" or kind == "drawer" then
        local want = kind == "break" and "box" or "drawer"
        local s, key = nearest(ws.props, function(s)
            if s.kind ~= want then return false end
            s.go = s.go or s.c:call("get_GameObject")
            return want == "drawer" or not s.on
        end)
        if key == nil then return "no " .. want .. " nearby" end
        if kind == "break" then
            fs.write("coopnet_command.txt", string.format("botevent break %s %d", s.id, chapter()))
            return "the bot will smash the nearest box"
        end
        fs.write("coopnet_command.txt", string.format("botevent drawer %s %d %d", s.id, s.on and 0 or 1, chapter()))
        return "the bot will " .. (s.on and "shut" or "open") .. " the nearest drawer"
    end
end

log("coop_world loaded")
