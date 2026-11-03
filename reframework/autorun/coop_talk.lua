-- coop_talk.lua: catching up after a rejoin, pings and quick messages (coop-re7 v0.19).
--
-- Catch-up. Every lasting change this game makes to the world (a door unlocked, a box
-- smashed, a drawer or switch set, a supply taken, a Molded killed) is kept in a list, on
-- disk, for 12 hours. When the friend's data starts arriving again after a gap (they
-- restarted, rejoined, or just connected), or when either player clicks "Catch up", the
-- list is sent and the other game applies it with the usual handlers: changes in areas
-- not loaded there wait until the area loads, and changes already there do nothing. Each
-- game only lists what it did itself, so nothing echoes. Changes made while the friend was
-- away get to them this way too. The first two-player session ended "totally out of sync"
-- after a rejoin (2026-11-02).
--
-- The outgoing event file keeps only the last 30 lines, so the list goes out in batches:
-- "catchup <ev>|<ev>|..." with up to 20 changes per line, one line every half second.
--
-- Pings and quick messages. F5-F8 (or the buttons in the RE7 Co-op window) send
-- "talk <kind> <chapter> <x> <y> <z>": the friend sees the message in the middle of the
-- screen and, for a ping, a marker where you stood, with the distance and a pointer when
-- it's off screen.

local talk = {
    list = {},            -- { t = os.time(), text, key }
    loaded = false, dirty = false, save_t = 0,
    peer = nil,           -- the friend the list belongs to ("steam:<id>")
    queue = {},           -- changes waiting to be sent
    send_t = 0,
    present = false, absent_since = nil, ever_present = false,
    got_n = 0, sent_n = 0, last_catchup = "-",
    msg = nil, msg_t = -100, msg_color = 0xFFFFFFFF,
    marks = {},           -- { kind, label, pos, t }
    keys = {},
}
coop_talk = talk
-- Our health as last sent, and the friend's (see Health below).
local hp = { sent = nil, sent_t = -100, check_t = 0, friend = nil, friend_t = -100 }

local KEEP_HOURS = 12
local BATCH, BATCH_EVERY = 20, 0.5
local GAP_FOR_CATCHUP = 8    -- s without the friend's data before their return counts as a rejoin
local MSG_SECONDS, MARK_SECONDS = 6, 25
local LIST_FILE = "coop_catchup.txt"

local log_buf, log_t = {}, 0
local function log(s) log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s) end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_talk_log.txt") or ""
    if #f > 200000 then f = f:sub(-100000) end
    fs.write("coop_talk_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function kv()
    local n = coop_net_state and coop_net_state()
    return (n and n.kv) or {}
end

local function chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    return tonumber(gm and safe(gm.get_field, gm, "_CurrentChapter") or 0) or 0
end

local function player_pos()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    return p and safe(function() return p:call("get_Transform"):call("get_Position") end)
end

-- Catch-up list -----------------------------------------------------------------------
-- Which outgoing events are lasting world changes, and the key that a later change of the
-- same thing replaces (a drawer opened then shut keeps only "shut").
local function list_key(text)
    local kind, id = text:match("^(%a+) (%S+)")
    if kind == "unlock" or kind == "break" or kind == "took" then return kind .. ":" .. id end
    if kind == "drawer" or kind == "switch" then return kind .. ":" .. id end
    if kind == "intr" and text:match(" phone$") then return "intr:" .. id end   -- answered calls
    if kind == "kill" then
        local name = text:match("^kill %S+ %-?%d+ (%S+)")
        -- Only the Molded die for good; Jack and bosses get back up, so their kills aren't replayed.
        if name and name:match("^Em4%d%d%d") then return "kill:" .. id end
    end
    return nil
end
coop_talk_list_key = list_key

local function load_list()
    talk.loaded = true
    local text = fs.read(LIST_FILE) or ""
    local now = os.time()
    for line in text:gmatch("[^\n]+") do
        local peer = line:match("^peer\t(.+)$")
        if peer then talk.peer = peer
        else
            local t, body = line:match("^(%d+)\t(.+)$")
            t = tonumber(t)
            if t and now - t < KEEP_HOURS * 3600 then
                local key = list_key(body)
                if key then talk.list[#talk.list + 1] = { t = t, text = body, key = key } end
            end
        end
    end
    log(string.format("catch-up list: %d changes kept from earlier (friend %s)", #talk.list, tostring(talk.peer)))
end

local function save_list()
    local out = { "peer\t" .. tostring(talk.peer or "-") }
    for _, e in ipairs(talk.list) do out[#out + 1] = e.t .. "\t" .. e.text end
    fs.write(LIST_FILE, table.concat(out, "\n") .. "\n")
    talk.dirty = false
end

function coop_talk_clear_list(why)
    talk.list = {}
    talk.dirty = true
    log("catch-up list cleared (" .. tostring(why) .. ")")
end

-- Called by coop_enemies.lua for every event this game sends.
function coop_talk_record(text)
    if not talk.loaded then load_list() end
    local k = kv()
    -- The bot echoes catch-up lines back, so a bot test replays your own changes on
    -- yourself (all no-ops) through the real path; its list is dropped for a real friend.
    if k.mode ~= "steam" and k.mode ~= "bot" then return end
    local key = list_key(text)
    if key == nil then return end
    for i = #talk.list, 1, -1 do
        if talk.list[i].key == key then table.remove(talk.list, i) end
    end
    talk.list[#talk.list + 1] = { t = os.time(), text = text, key = key }
    talk.dirty = true
end

local function queue_all(why)
    talk.queue = {}
    for _, e in ipairs(talk.list) do talk.queue[#talk.queue + 1] = e.text end
    talk.last_catchup = string.format("%s: sending %d changes (%s)", os.date("%H:%M"), #talk.queue, why)
    log("catch-up: " .. talk.last_catchup)
end

function coop_talk_catch_up_now()
    queue_all("button")
    if coop_send_event then coop_send_event("catchup_req") end
end

-- The friend's data: present when a sample arrived in the last 3 s.
local function watch_friend()
    local n = coop_net_state and coop_net_state()
    local hist = n and n.history
    local last = hist and hist[#hist]
    local now = os.clock()
    local present = last ~= nil and now - last.t < 3
    if present and not talk.present then
        local gap = talk.absent_since and (now - talk.absent_since) or math.huge
        if not talk.ever_present or gap >= GAP_FOR_CATCHUP then
            talk.check_fresh_at = os.clock() + 2   -- once the friend's chapter is known
            queue_all(talk.ever_present and string.format("friend back after %d s", math.floor(gap)) or "friend connected")
        end
        talk.ever_present = true
        talk.absent_since = nil
    elseif not present and talk.present then
        talk.absent_since = now
    end
    talk.present = present
end

local function pump_queue()
    if #talk.queue == 0 or not coop_send_event then return end
    local now = os.clock()
    if now - talk.send_t < BATCH_EVERY then return end
    talk.send_t = now
    local batch = {}
    while #batch < BATCH and #talk.queue > 0 do batch[#batch + 1] = table.remove(talk.queue, 1) end
    coop_send_event("catchup " .. table.concat(batch, "|"))
    talk.sent_n = talk.sent_n + #batch
end

-- Pings and quick messages --------------------------------------------------------------
local KINDS = {
    ping = { label = "Over here", color = 0xFF7FE6FF, mark = true },
    come = { label = "Come here", color = 0xFF7FE6FF, mark = true },
    wait = { label = "Wait for me", color = 0xFFFFFFFF, mark = false },
    go = { label = "Go on ahead", color = 0xFFFFFFFF, mark = false },
    help = { label = "Help!", color = 0xFF5050FF, mark = true },
}
local KEY_ORDER = { { vk = 0x74, kind = "ping", name = "F5" }, { vk = 0x75, kind = "come", name = "F6" },
    { vk = 0x76, kind = "wait", name = "F7" }, { vk = 0x77, kind = "help", name = "F8" } }

local function show_msg(text, color)
    talk.msg, talk.msg_t, talk.msg_color = text, os.clock(), color or 0xFFFFFFFF
end

function coop_talk_send(kind)
    local def = KINDS[kind]
    if def == nil or not coop_send_event then return end
    local p = player_pos()
    local x, y, z = p and p.x or 0, p and p.y or 0, p and p.z or 0
    coop_send_event(string.format("talk %s %d %.2f %.2f %.2f", kind, chapter(), x, y, z))
    show_msg("You: " .. def.label, 0xFFBFBFBF)
    log("sent " .. kind)
end

local function on_talk(kind, ch, x, y, z)
    local def = KINDS[kind]
    if def == nil then return end
    local here = ch == chapter()
    local p = player_pos()
    local dist = (here and p) and math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2 + (z - p.z) ^ 2) or nil
    show_msg("Your friend: " .. def.label .. (dist and string.format(" (%d m)", math.floor(dist + 0.5)) or
        (here and "" or " (in another chapter)")), def.color)
    if def.mark and here then
        talk.marks = { { kind = kind, label = def.label, pos = Vector3f.new(x, y + 1.0, z), t = os.clock() } }
    end
    log(string.format("friend: %s at %.1f %.1f %.1f (chapter %d, %s m)", kind, x, y, z, ch, tostring(dist and math.floor(dist))))
end

-- Called by coop_enemies.lua for every incoming event, before the other scripts.
function coop_talk_on_event(text)
    local fh = tonumber(text:match("^hp (%d+)$"))
    if fh then
        hp.friend, hp.friend_t = fh, os.clock()
        return true
    end
    local kind, ch, x, y, z = text:match("^talk (%a+) (%-?%d+) (%S+) (%S+) (%S+)")
    if kind then
        on_talk(kind, tonumber(ch), tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
        return true
    end
    if text == "catchup_req" then
        queue_all("friend asked")
        return true
    end
    local batch = text:match("^catchup (.+)$")
    if batch then
        local n, bad = 0, 0
        for ev in batch:gmatch("[^|]+") do
            -- Only the lasting kinds: a catch-up line can never carry anything else.
            if kv().mode == "bot" and ev:match("^took ") then
                n = n + 1   -- bot test: our own pickups, never hidden here (a reload would lose the item)
            elseif list_key(ev) and coop_apply_event then
                local ok = pcall(coop_apply_event, ev)
                if ok then n = n + 1 else bad = bad + 1 end
            else
                bad = bad + 1
            end
        end
        talk.got_n = talk.got_n + n
        log(string.format("catch-up from the friend: %d changes applied or remembered%s", n,
            bad > 0 and string.format(", %d skipped", bad) or ""))
        show_msg(string.format("Caught up with %d changes from your friend", talk.got_n), 0xFFBFBFBF)
        return true
    end
    return false
end

-- Health ---------------------------------------------------------------------------------
-- "hp <percent>" when ours changes by 5 points or more (and every 15 s), so the friend knows
-- when to help or share healing. Shown on their status line and nameplate.
local function own_health()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local dc = p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.PlayerDamageController"))
    local h = dc and tonumber(safe(dc.call, dc, "get_health"))
    local m = dc and tonumber(safe(dc.call, dc, "get_maxHealth"))
    if h == nil or m == nil or m <= 0 then return nil end
    return math.max(0, math.min(100, math.floor(h / m * 100 + 0.5)))
end

local function send_health()
    local now = os.clock()
    if now - hp.check_t < 0.5 or not coop_send_event then return end
    hp.check_t = now
    local pct = own_health()
    if pct == nil then return end
    if hp.sent == nil or math.abs(pct - hp.sent) >= 5 or (pct ~= hp.sent and pct == 100) or now - hp.sent_t > 15 then
        hp.sent, hp.sent_t = pct, now
        coop_send_event("hp " .. pct)
    end
end

-- The friend's health in percent, or nil when we haven't heard for 40 s.
function coop_friend_health()
    if hp.friend == nil or os.clock() - hp.friend_t > 40 then return nil end
    return hp.friend
end

function coop_friend_health_color(pct)
    if pct >= 60 then return 0xFF7FFF8C elseif pct >= 30 then return 0xFF7FE6FF end
    return 0xFF6B6BFF
end

-- The last quick message, for the status line (it stays 20 s there, after the pop-up).
function coop_talk_hud()
    if talk.msg and os.clock() - talk.msg_t < 20 and talk.msg:find("^Your friend: ") then
        return "Last message: " .. talk.msg:sub(14), talk.msg_color
    end
    return nil
end

-- Fresh-list reminder. A catch-up change from a later chapter than the friend's (seen when
-- they connect) suggests a new game: the list would then carry changes from the old one.
-- Changes are only applied in the chapter they were made in, so nothing breaks; the
-- reminder just offers "Start a fresh list".
local function list_chapter(text)
    local kind = text:match("^(%a+)")
    if kind == "drawer" or kind == "switch" then return tonumber(text:match("^%a+ %S+ %d (%-?%d+)")) end
    return tonumber(text:match("^%a+ %S+ (%-?%d+)"))
end

local function check_fresh_list()
    local n = coop_net_state and coop_net_state()
    local fch = n and n.peer_chapter
    talk.stale = nil
    if fch == nil or fch <= 0 then return end
    local later = 0
    for _, e in ipairs(talk.list) do
        local ch = list_chapter(e.text)
        if ch and ch > fch then later = later + 1 end
    end
    if later > 0 then
        talk.stale = later
        show_msg(string.format("%d of your catch-up changes are from a later chapter than your friend's: new game? " ..
            "Start a fresh list (Talk and catch up)", later), 0xFF7FE6FF)
        log(string.format("fresh-list reminder: %d changes from a later chapter than the friend's (%d)", later, fch))
    end
end
coop_talk_list_chapter = list_chapter

-- Drawing --------------------------------------------------------------------------------
local function draw_mark(m)
    local p = player_pos()
    local d = p and math.sqrt((m.pos.x - p.x) ^ 2 + (m.pos.y - p.y) ^ 2 + (m.pos.z - p.z) ^ 2)
    local label = "[" .. m.label .. "]" .. (d and string.format("  %d m", math.floor(d + 0.5)) or "")
    local color = KINDS[m.kind] and KINDS[m.kind].color or 0xFFFFFFFF
    local sok, sp = pcall(draw.world_to_screen, m.pos)
    local w, h = 1920, 1080
    local ok, size = pcall(imgui.get_display_size)
    if ok and size then w, h = size.x, size.y end
    if sok and sp and sp.x >= 0 and sp.x <= w and sp.y >= 0 and sp.y <= h then
        draw.world_text(label, m.pos, color)
        return
    end
    -- Off screen: say which way, like the friend marker.
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local player = om and om:get_field("PlayerObj")
    local tr = player and safe(player.call, player, "get_Transform")
    if tr == nil or p == nil then return end
    local f, x = tr:call("get_AxisZ"), tr:call("get_AxisX")
    local vx, vz = m.pos.x - p.x, m.pos.z - p.z
    local ahead = vx * f.x + vz * f.z
    local right = -(vx * x.x + vz * x.z)
    if ahead < 0 and math.abs(right) < -ahead then
        draw.text("v " .. label .. " (behind you)", w / 2 - 90, h - 90, color)
    elseif right > 0 then
        draw.text(label .. " >", w - 260, h / 2 + 24, color)
    else
        draw.text("< " .. label, 20, h / 2 + 24, color)
    end
end

re.on_frame(function()
    local ok, err = pcall(function()
        if not talk.loaded then load_list() end
        -- The list belongs to one friend: a different friend starts a fresh one.
        local k = kv()
        local who = (k.mode == "bot" and "bot") or
            (k.mode == "steam" and k.peer and k.peer ~= "steam:0" and k.peer ~= "-" and k.peer) or nil
        if who and who ~= talk.peer then
            if talk.peer ~= nil and talk.peer ~= "-" and #talk.list > 0 then coop_talk_clear_list("new friend") end
            talk.peer = who
            talk.dirty = true
        end
        if talk.check_fresh_at and os.clock() >= talk.check_fresh_at then
            talk.check_fresh_at = nil
            pcall(check_fresh_list)
        end
        if k.mode == "steam" or k.mode == "bot" then
            watch_friend()
            pump_queue()
            send_health()
        end
        local now = os.clock()
        if talk.dirty and now - talk.save_t > 2 then talk.save_t = now save_list() end

        -- Hotkeys (edge-triggered), unless switched off in the window.
        if not (settings and settings.talk_keys == false) and reframework and reframework.is_key_down then
            for _, kd in ipairs(KEY_ORDER) do
                local down = reframework:is_key_down(kd.vk)
                if down and not talk.keys[kd.vk] then coop_talk_send(kd.kind) end
                talk.keys[kd.vk] = down
            end
        end

        if settings and settings.hud == false then return end
        if talk.msg and now - talk.msg_t < MSG_SECONDS then
            local w = 1920
            local okd, size = pcall(imgui.get_display_size)
            if okd and size then w = size.x end
            draw.text(talk.msg, w / 2 - 4 * #talk.msg, 120, talk.msg_color)
        end
        for i = #talk.marks, 1, -1 do
            local m = talk.marks[i]
            if now - m.t > MARK_SECONDS then table.remove(talk.marks, i) else draw_mark(m) end
        end
    end)
    if not ok and not talk.err then talk.err = true log("frame ERR " .. tostring(err)) end
end)

-- The "Talk and catch up" section of the RE7 Co-op window (drawn by coop_dummy.lua).
function coop_talk_ui()
    imgui.text("Quick messages (your friend sees them on screen):")
    for i, kd in ipairs(KEY_ORDER) do
        if i > 1 then imgui.same_line() end
        if imgui.button(KINDS[kd.kind].label .. " (" .. kd.name .. ")") then coop_talk_send(kd.kind) end
    end
    imgui.same_line()
    if imgui.button(KINDS.go.label) then coop_talk_send("go") end
    local c, v = imgui.checkbox("F5-F8 keys", not (settings and settings.talk_keys == false))
    if c and settings then settings.talk_keys = v if save_settings then save_settings() end end
    if imgui.separator then imgui.separator() end
    imgui.text(string.format("Catch-up list: %d changes you made (kept 12 hours, sent when your friend joins)", #talk.list))
    imgui.text("Last catch-up: " .. talk.last_catchup .. string.format(" | received from your friend: %d", talk.got_n))
    if imgui.button("Catch up now (both ways)") then coop_talk_catch_up_now() end
    imgui.same_line()
    if imgui.button("Start a fresh list (new game)") then coop_talk_clear_list("button") talk.stale = nil end
    if talk.stale then
        imgui.text(string.format("  %d changes are from a later chapter than your friend's. Started a new game together? " ..
            "Start a fresh list.", talk.stale))
    end
end

log("coop_talk loaded")
