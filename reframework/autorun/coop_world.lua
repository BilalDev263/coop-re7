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

local function poll_doors(now)
    for id, s in pairs(ws.doors) do
        local d = s.d
        local locked = safe(d.call, d, "get_isLocked") == true
        local state = safe(d.call, d, "get_doorState") or 0
        local open = is_open(state)
        local ours = ws.applying[id] and now - ws.applying[id] < 3
        if s.locked and not locked and not ours then send(string.format("unlock %s %d", id, chapter())) end
        if open and not s.open and not ours then send(string.format("open %s %d", id, chapter())) end
        if s.open and not open and not ours then send(string.format("close %s %d", id, chapter())) end
        s.locked, s.open = locked, open
    end
end

local function apply_door(kind, id, ch)
    if ch ~= chapter() then return end
    local s = ws.doors[id]
    if s == nil then log("door not loaded here: " .. kind .. " " .. id) return end
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
            log(string.format("opened door %s (state %s -> %s)%s", id, tostring(before),
                tostring(safe(s.d.call, s.d, "get_doorState")), ok and "" or (" ERR " .. tostring(err))))
        else
            log(string.format("open door %s: already state %s, locked %s", id, tostring(before),
                tostring(s.d:call("get_isLocked"))))
        end
    elseif kind == "close" then
        if is_open(s.d:call("get_doorState")) then
            local ok, err = pcall(s.d.call, s.d, "requestClosed(System.Boolean)", false)
            log("closed door " .. id .. (ok and "" or (" ERR " .. tostring(err))))
        end
    end
    ws.applied = ws.applied + 1
end

-- Items ------------------------------------------------------------------------------
local function refresh_items()
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.Item"))
    local seen = {}
    for _, it in ipairs(arr and arr:get_elements() or {}) do
        local id = id_of(it)
        if id then
            seen[id] = true
            if ws.items[id] == nil then
                ws.items[id] = { it = it, go = it:call("get_GameObject"), state = safe(it.call, it, "getItemState") }
            end
            ws.items[id].it = it
        end
    end
    for id in pairs(ws.items) do if not seen[id] then ws.items[id] = nil end end
    -- Pickups the friend made before this area was loaded here.
    for id, ch in pairs(ws.pending_took) do
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
local ITEM_IN_SCENE, ITEM_GONE = 0, 6
local function poll_items(now)
    for id, e in pairs(ws.items) do
        local st = safe(e.it.call, e.it, "getItemState")
        if e.state == ITEM_IN_SCENE and st == ITEM_GONE then
            local ours = ws.applying[id] and now - ws.applying[id] < 3
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
            elseif s.kind == "intr" and on and interactions_shared() then send(string.format("intr %s %d", s.id, chapter()))
            elseif s.kind == "switch" and interactions_shared() then
                send(string.format("switch %s %d %d", s.id, on and 1 or 0, chapter()))
            end
        end
        s.on = on
    end
end

local function apply_prop(kind, id, want, ch)
    if ch ~= chapter() then return end
    local key = kind .. ":" .. id
    local s = ws.props[key]
    if s == nil then log(kind .. " not loaded here: " .. id) return end
    local before = safe(s.pt.state, s.c) == true
    if before == want then return end
    ws.applying[key] = os.clock()
    local ok, err
    if kind == "box" then
        -- The hit path: RigidBodyDestruct.setBreak(dir, pos, normal, attacker, type).
        local rb = safe(s.c.get_field, s.c, "RigidBodyCompo")
        local go = s.c:call("get_GameObject")
        local pos = go:call("get_Transform"):call("get_Position")
        local up = Vector3f.new(0, 1, 0)
        if rb then
            ok, err = pcall(rb.call, rb, "setBreak(via.vec3, via.vec3, via.vec3, via.GameObject, System.UInt32)",
                Vector3f.new(0, -1, 0), pos, up, nil, 0)
        else
            ok, err = false, "no RigidBodyCompo"
        end
        note("your friend smashed a box")
    elseif kind == "intr" then
        ok, err = pcall(s.c.call, s.c, "successInteract")
        note("your friend used something here (" .. tostring(safe(function() return s.c:call("get_GameObject"):call("get_Name") end)) .. ")")
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
    local iid, ich = text:match("^intr (%S+) (%-?%d+)")
    if iid then
        if interactions_shared() then pcall(apply_prop, "intr", iid, true, tonumber(ich)) end
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
