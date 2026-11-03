-- coop_story.lua: shared story.
-- RE7's story moves on through triggers (areas, items, cutscene ends); the progress
-- numbers only record it (setting one changes nothing in the world). So whoever triggers
-- a story beat leads it: their game sends it, the other game plays the same thing.
--   story <name> <chapter>       a story cutscene started (names like c03e01_00)
--   prog <flow hash> <value> <chapter>   a story stage's progress number went up
--   evend <event hash> <chapter> a story event was marked finished
-- Cutscenes start by name with GameEventManager.requestEvent. Each cutscene plays once per
-- side; progress only ever goes up. Events go through coop_enemies.lua's reliable channel.
--
-- Rules since the first real session (2026-11-02), which showed that pushing a player who
-- is elsewhere breaks their game (a tape ended early, a chapter change stuck, a washed-out
-- picture, the dinner chair skipping ahead):
--   * a friend's cutscene is only played here when we are in the same chapter and within
--     NEAR metres of them; otherwise we see it ourselves when we get there;
--   * progress numbers and finished events are only copied while "in step": for
--     IN_STEP seconds after we were pulled into a cutscene of theirs. Outside that each
--     game keeps its own story.

story_sync = {
    played = {},       -- cutscene name -> true (started on this side, by us or the friend)
    applying = {},     -- key -> clock: changes we made on the friend's word (not sent back)
    pending = {},      -- cutscene name -> { ch, t }: friend's cutscene not loaded here yet
    sent = 0, applied = 0, msg = "-", msg_t = -100, pend_t = 0,
}
local ss = story_sync
local STORY_NAME = "^c%d%de%d%d_%d%d$"

-- Cutscenes already played this chapter survive Reset scripts (coop_story_played.json):
-- replaying one the game had finished (the dinner, on the bot's word after a reset) hung
-- it halfway and left the player unable to move. The list starts over on a new chapter.
local function save_played()
    pcall(json.dump_file, "coop_story_played.json", { chapter = ss.played_chapter, played = ss.played })
end
do
    local ok, data = pcall(json.load_file, "coop_story_played.json")
    if ok and type(data) == "table" and type(data.played) == "table" then
        ss.played, ss.played_chapter = data.played, data.chapter
    end
end
local function mark_played(name, ch)
    if ss.played_chapter ~= ch then ss.played, ss.played_chapter = {}, ch end
    if not ss.played[name] then
        ss.played[name] = true
        save_played()
    end
end
local PENDING_FOR = 10    -- s to keep waiting for a nearby friend's cutscene to load here
local NEAR = 12           -- m: a friend's cutscene pulls us in only this close
local IN_STEP = 30        -- s after a shared cutscene during which their progress is copied

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t = {}, 0
local function log(s)
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_story_log.txt") or ""
    if #f > 200000 then f = f:sub(-100000) end
    fs.write("coop_story_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
    log_buf = {}
end)

local function chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    local ok, v = pcall(gm.get_field, gm, "_CurrentChapter")
    return tonumber(ok and v or 0) or 0
end

local function note(msg)
    ss.msg, ss.msg_t = msg, os.clock()
    log(msg)
end

-- "Share story" (RE7 Co-op window, off by default): off = neither send nor apply.
-- Off unless ticked: in the first real session it pushed the player who was behind
-- (tape ended early, washed-out picture, chapter change stuck), 2026-11-02.
local function sharing() return settings ~= nil and settings.share_story == true end

local function send(text)
    if not sharing() then return end
    if coop_send_event then coop_send_event(text) ss.sent = ss.sent + 1 log("sent: " .. text) end
end

local function ours(key) return ss.applying[key] and os.clock() - ss.applying[key] < 5 end

local function u32(p) return sdk.to_int64(p) & 0xFFFFFFFF end
local function i32(p)
    local v = sdk.to_int64(p) & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

local function flow_mgr() return sdk.get_managed_singleton("app.GameFlowFsmManager") end
local function event_mgr()
    return sdk.find_type_definition("app.GameManager"):get_field("_GameEventMan"):get_data(nil)
end

-- Our side ---------------------------------------------------------------------------
local ec = sdk.find_type_definition("app.GameEventController")
sdk.hook(ec:get_method("requestSetup(app.GameEventSetting, via.Transform)"), function(args)
    pcall(function()
        local st = sdk.to_managed_object(args[3])
        local name = st and tostring(st:call("get_eventName"))
        if name == nil or not name:match(STORY_NAME) then return end
        local ch = chapter()
        if ss.played_chapter ~= ch then ss.played, ss.played_chapter = {}, ch end
        local first = not ss.played[name]
        mark_played(name, ch)
        if first and not ours("ev:" .. name) then send(string.format("story %s %d", name, ch)) end
    end)
end, function(r) return r end)

local gf = sdk.find_type_definition("app.GameFlowFsmManager")
sdk.hook(gf:get_method("setProgressiveNo(System.UInt32, System.Int32)"), function(args)
    pcall(function()
        local h, v = u32(args[3]), i32(args[4])
        if v > 0 and not ours(string.format("pg:%08x", h)) then
            send(string.format("prog %08x %d %d", h, v, chapter()))
        end
    end)
end, function(r) return r end)
sdk.hook(gf:get_method("sendEventEnded(System.UInt32)"), function(args)
    pcall(function()
        local h = u32(args[3])
        if not ours(string.format("ee:%08x", h)) then send(string.format("evend %08x %d", h, chapter())) end
    end)
end, function(r) return r end)

-- Friend's side ----------------------------------------------------------------------
-- Distance to the friend's Ethan (nil when there's none to measure).
local function friend_distance()
    local g = coop_ghost and coop_ghost()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local player = om and om:get_field("PlayerObj")
    if g == nil or player == nil then return nil end
    local ok, gp = pcall(function() return g:call("get_Transform"):call("get_Position") end)
    if not ok or gp == nil then return nil end
    local pp = player:call("get_Transform"):call("get_Position")
    return math.sqrt((gp.x - pp.x) ^ 2 + (gp.y - pp.y) ^ 2 + (gp.z - pp.z) ^ 2)
end

local function in_step() return ss.in_step_until ~= nil and os.clock() < ss.in_step_until end
local function setting_loaded(name)
    local em = event_mgr()
    local list = em and em:get_field("EventSettings")
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local s = list:call("get_Item", i)
        if s and tostring(s:call("get_eventName")) == name then return true end
    end
    return false
end

local function play(name)
    ss.applying["ev:" .. name] = os.clock()
    mark_played(name, chapter())
    local em = event_mgr()
    local ok, err = pcall(em.call, em, "requestEvent(System.String, via.Transform, System.Boolean)",
        sdk.create_managed_string(name), nil, false)
    ss.applied = ss.applied + 1
    if ok then ss.in_step_until = os.clock() + IN_STEP end
    note(ok and ("your friend's story: " .. name) or ("ERR playing " .. name .. ": " .. tostring(err)))
end

local function apply_story(name, ch)
    if ch ~= chapter() then log("story event in another chapter, ignored: " .. name) return end
    if ss.played_chapter == ch and ss.played[name] then log("already played here: " .. name) return end
    local d = friend_distance()
    if d == nil or d > NEAR then
        note(string.format("your friend is watching a cutscene (%s m away: you'll see it when you get there)",
            d and string.format("%.0f", d) or "?"))
        return
    end
    if setting_loaded(name) then play(name)
    else
        ss.pending[name] = { ch = ch, t = os.clock() }
        log("waiting for " .. name .. " to load here")
    end
end

local function apply_prog(hash, value, ch)
    if ch ~= chapter() then return end
    if not in_step() then log(string.format("progress %08x %d not copied (not in step)", hash, value)) return end
    local fm = flow_mgr()
    local var = fm and fm:call("getProgressiveNo(System.UInt32)", hash)
    local cur = var and var:call("get_S32") or 0
    if value > cur then
        ss.applying[string.format("pg:%08x", hash)] = os.clock()
        pcall(fm.call, fm, "setProgressiveNo(System.UInt32, System.Int32)", hash, value)
        ss.applied = ss.applied + 1
        log(string.format("progress %08x %d -> %d (from the friend)", hash, cur, value))
    end
end

local function apply_evend(hash, ch)
    if ch ~= chapter() then return end
    if not in_step() then log(string.format("event %08x end not copied (not in step)", hash)) return end
    local fm = flow_mgr()
    if fm and not fm:call("isEventEnded(System.UInt32)", hash) then
        ss.applying[string.format("ee:%08x", hash)] = os.clock()
        pcall(fm.call, fm, "sendEventEnded(System.UInt32)", hash)
        log(string.format("event %08x ended (from the friend)", hash))
    end
end

-- Saving together. Each player saves their own game; to load matching points later,
-- both should save at the same moment. When ours really saves (only possible with "Allow
-- saving" on; the save guard blocks the rest), tell the friend, and show theirs.
local sdm = sdk.find_type_definition("app.SaveDataManager")
local function hook_save(method_name, kind)
    local m = sdm:get_method(method_name)
    if m == nil then log("save hook missing: " .. method_name) return end
    sdk.hook(m, function(args)
        pcall(function()
            if settings and settings.allow_saving then send(string.format("saved %s %d", kind, chapter())) end
        end)
    end, function(r) return r end)
end
hook_save("saveFileMenuRequestExecute()", "menu")
hook_save("saveFileAutoRequestExecute()", "auto")

local function on_saved(kind, ch)
    local what = kind == "menu" and "Your friend saved at a tape recorder" or "Your friend's game autosaved"
    if not (settings and settings.allow_saving) then
        note(what .. " (your saving is off: turn on Allow saving to keep matching saves)")
    elseif kind == "menu" then
        note(what .. ": save too so your games match")
    else
        note(what)
    end
end

-- Called by coop_enemies.lua for every incoming event; true if it was ours.
function coop_story_on_event(text)
    local skind, sch = text:match("^saved (%a+) (%-?%d+)")
    if skind then pcall(on_saved, skind, tonumber(sch)) return true end
    if not sharing() and (text:match("^story ") or text:match("^prog ") or text:match("^evend ")) then
        log("story sharing is off, ignored: " .. text)
        return true
    end
    local name, ch = text:match("^story (%S+) (%-?%d+)")
    if name then pcall(apply_story, name, tonumber(ch)) return true end
    local h, v, pch = text:match("^prog (%x+) (%-?%d+) (%-?%d+)")
    if h then pcall(apply_prog, tonumber(h, 16), tonumber(v), tonumber(pch)) return true end
    local eh, ech = text:match("^evend (%x+) (%-?%d+)")
    if eh then pcall(apply_evend, tonumber(eh, 16), tonumber(ech)) return true end
    return false
end

-- Cutscenes the friend started before their area loaded here.
re.on_frame(function()
    local now = os.clock()
    if now - ss.pend_t < 1 then return end
    ss.pend_t = now
    for name, p in pairs(ss.pending) do
        local d = friend_distance()
        if now - p.t > PENDING_FOR or p.ch ~= chapter() or d == nil or d > NEAR then
            ss.pending[name] = nil
            log("gave up waiting for " .. name)
        elseif not ss.played[name] and setting_loaded(name) then
            ss.pending[name] = nil
            play(name)
        end
    end
end)

function story_sync_hud()
    if os.clock() - ss.msg_t < 6 then return "Story: " .. ss.msg end
    return nil
end

function story_sync_status()
    local fm = flow_mgr()
    local stage = fm and fm:call("get_CurrentMainGameFlow")
    local played, pend = 0, 0
    for _ in pairs(ss.played) do played = played + 1 end
    for _ in pairs(ss.pending) do pend = pend + 1 end
    return string.format("Story: stage %s; cutscenes played %d, waiting %d; sent %d, applied %d",
        tostring(stage), played, pend, ss.sent, ss.applied)
end

-- Testing: the bot "triggers" the next story cutscene loaded here that hasn't played.
function story_sync_bot_next()
    local em = event_mgr()
    local list = em and em:get_field("EventSettings")
    local names = {}
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local n = tostring(list:call("get_Item", i):call("get_eventName"))
        if n:match(STORY_NAME) and not ss.played[n] then names[#names + 1] = n end
    end
    table.sort(names)
    if #names == 0 then return "no unplayed story cutscene loaded here" end
    fs.write("coopnet_command.txt", string.format("botevent story %s %d", names[1], chapter()))
    return "the bot triggers " .. names[1]
end

log("coop_story loaded")
