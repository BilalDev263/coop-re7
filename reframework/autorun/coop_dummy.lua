-- coop_dummy.lua: the other player's Ethan, and the co-op UI.
-- Builds the friend's body from RE7's VR dummy-player prefab
-- (Prefab/System/VrDummyPlayer.pfb, app.vr.VrManager.DummyPlayerPrefab) dressed in the
-- player's own Shadow* meshes, animates it from the network samples (walk/jog/crouch,
-- head look, footsteps), rebuilds it after loads, and owns the RE7 Co-op window, the
-- on-screen status, connecting, the chapter switcher and the testing tools.
-- Log: <game>/reframework/data/coop_dummy_log.txt; the previous script load's log is kept
-- as coop_dummy_log_prev.txt, so a Reset scripts doesn't wipe the last test.

-- Lines are collected and written once a second (writing the whole log on every line,
-- twice, cost a 300 KB+ write per line late in a session).
local lines, log_dirty, log_t = {}, false, 0
do
    local prev = fs.read("coop_dummy_log.txt")
    if prev and prev ~= "" then fs.write("coop_dummy_log_prev.txt", prev) end
end
local function log(s)
    lines[#lines + 1] = os.date("%H:%M:%S ") .. tostring(s)
    if #lines > 6000 then
        local keep = {}
        for i = #lines - 3999, #lines do keep[#keep + 1] = lines[i] end
        lines = keep
    end
    log_dirty = true
end
re.on_frame(function()
    if not log_dirty or os.clock() - log_t < 1 then return end
    log_t, log_dirty = os.clock(), false
    fs.write("coop_dummy_log.txt", table.concat(lines, "\n") .. "\n")
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r, nil end
    return nil, r
end

local function get_player()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    return om and om:get_field("PlayerObj")
end

-- Log a GameObject's components and recurse through its Transform children.
local function dump_tree(go, depth, budget)
    if budget.n <= 0 then return end
    budget.n = budget.n - 1
    local comps = {}
    for _, c in ipairs((safe(function() return go:call("get_Components"):get_elements() end)) or {}) do
        local tn = c:get_type_definition():get_full_name()
        if tn == "via.render.Mesh" then
            local h = safe(c.call, c, "getMesh")
            tn = tn .. "[" .. tostring(h and safe(h.call, h, "get_ResourcePath")) ..
                " ready=" .. tostring(safe(c.call, c, "get_ReadyToDraw")) .. "]"
        end
        comps[#comps + 1] = tn
    end
    log(string.rep("  ", depth) .. tostring(safe(go.call, go, "get_Name")) ..
        " draw=" .. tostring(safe(go.call, go, "get_Draw")) .. " : " .. table.concat(comps, ", "))
    local tr = safe(go.call, go, "get_Transform")
    local child = tr and safe(tr.call, tr, "get_Child")
    while child ~= nil and budget.n > 0 do
        local cgo = safe(child.call, child, "get_GameObject")
        if cgo then dump_tree(cgo, depth + 1, budget) end
        child = safe(child.call, child, "get_Next")
    end
end

-- Full-body model search ---------------------------------------------------
-- Ethan's pl0001.mesh is only the first-person torso, so look for another
-- character model: first among skinned meshes already in the scene, then by
-- probing likely paths for every app.PlayerID.

local prefab, dummy = nil, nil
local dummy_mesh = nil
local pose_err_logged = false

local function resource_exists(rtype, path)
    local r = safe(sdk.create_resource, rtype, path)
    return r ~= nil, r
end

function find_full_model()
    local found = {}
    -- 1. skinned character meshes already in the scene
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
    local seen = {}
    for _, m in ipairs((arr and arr:get_elements()) or {}) do
        local h = safe(m.call, m, "getMesh")
        local path = h and safe(h.call, h, "get_ResourcePath")
        if path and not seen[path] and path:find("^Character/") and safe(m.call, m, "get_SkinningMesh") then
            seen[path] = true
            local mh = safe(m.call, m, "get_Material")
            local mdf = mh and safe(mh.call, mh, "get_ResourcePath")
            local owner = safe(m.call, m, "get_GameObject")
            local oname = owner and tostring(safe(owner.call, owner, "get_Name")) or "?"
            local otr = owner and safe(owner.call, owner, "get_Transform")
            local rtr = otr
            while rtr do
                local p = safe(rtr.call, rtr, "get_Parent")
                if p == nil then break end
                rtr = p
            end
            local root = rtr and safe(rtr.call, rtr, "get_GameObject")
            local rname = root and tostring(safe(root.call, root, "get_Name")) or "?"
            local jarr = otr and safe(otr.call, otr, "get_Joints")
            local jn = jarr and #(safe(jarr.get_elements, jarr) or {}) or 0
            log(string.format("scene skinned character mesh: %s mdf=%s owner=%s root=%s joints=%d",
                path, tostring(mdf), oname, rname, jn))
            -- mh can be a live material with no file path (Mia's em2000 body), so
            -- filter on the holder, not the path.
            if not path:find("pl0001") and not path:find("_sim") and mh ~= nil then
                -- Hold references: without add_ref the GC can free these holders
                -- while we keep them, and setMesh on a stale holder crashed the
                -- game (access violation, 2026-10-29 15:35).
                safe(h.add_ref, h)
                safe(mh.add_ref, mh)
                found[#found + 1] = { mesh = path, mdf = mdf, from = "scene", holder = h, mholder = mh, comp = m }
            end
        end
    end
    -- Probing paths with sdk.create_resource is useless: it returns an object even
    -- for files that don't exist (every guessed pl*.mesh "existed"). Scene only.
    log("full-body candidates: " .. #found)
    for i, f in ipairs(found) do log(string.format("  %d. %s mdf=%s", i, f.mesh, tostring(f.mdf))) end
    return found
end

candidates = {}
local copy_pose = false   -- Ethan's pose on another character's skeleton makes no sense

-- Full-character assembly ----------------------------------------------------
-- RE Engine characters are split into several meshes (head, body, hair...) on
-- several GameObjects. Hand-built GameObjects don't render in RE7, but
-- prefab-spawned dummies do, so spawn one VR dummy per mesh of the source
-- character and keep them all at the same origin.

local parts = {}            -- { go, mesh, holder, mholder, path, state }
local parts_frames = 0

-- Follow: replay the player's own path DELAY seconds behind. The recorded
-- samples stand in for a remote player's packets until networking exists.
local DELAY, KEEP = 3.0, 10.0
TURN_TAU = 0.1          -- s; body facing eases toward the sender's (smaller = snappier)
LOOK_TAU = 0.12         -- s; head look eases toward the friend's (smooths mouse flicks)
BLEND_DIR = 12          -- frames to blend between directions of the same stance
BLEND_STANCE = 16       -- frames to blend walk/jog/crouch/stand changes
MIN_HOLD = 0.3          -- s a moving clip plays before a direction change
EXTRAPOLATE_MAX = 0.1   -- s to keep moving past the newest sample on a late packet
LOOKAHEAD = 0.08        -- s of buffered future used to start/stop the walk on time
MOVE_START, MOVE_STOP = 0.25, 0.15   -- m/s; separate thresholds so it doesn't toggle
local follow = true
local history = {}          -- { t, pos, rot }, oldest first

local function record_player()
    local player = get_player()
    if player == nil then return end
    local tr = player:call("get_Transform")
    local now = os.clock()
    history[#history + 1] = { t = now, pos = tr:call("get_Position"), rot = tr:call("get_Rotation") }
    while #history > 0 and history[1].t < now - KEEP do table.remove(history, 1) end
end

local function sample_from(list, t)
    for i = #list, 1, -1 do
        if list[i].t <= t then return list[i] end
    end
    return nil
end

local function sample_at(t) return sample_from(history, t) end

-- Interpolated sample at time t: lerp position and nlerp rotation between the
-- two samples around t. Before the first sample or past the newest one (late or
-- lost packets) it holds the nearest pose instead of snapping.
local function sample_interp(list, t)
    local n = #list
    if n == 0 then return nil end
    if t <= list[1].t then return list[1] end
    if t >= list[n].t then
        -- Late packet: keep moving at the last velocity for a short while instead
        -- of freezing on the newest sample (that hold-then-jump read as choppy).
        local last, prev = list[n], list[n - 1]
        local over = math.min(t - last.t, EXTRAPOLATE_MAX)
        if prev == nil or over <= 0 or last.t - prev.t < 1e-4 then return last end
        local span = last.t - prev.t
        local vx, vy, vz = (last.pos.x - prev.pos.x) / span, (last.pos.y - prev.pos.y) / span, (last.pos.z - prev.pos.z) / span
        return { t = t, pos = Vector3f.new(last.pos.x + vx * over, last.pos.y + vy * over, last.pos.z + vz * over),
            rot = last.rot, look_yaw = last.look_yaw, look_pitch = last.look_pitch, flags = last.flags }
    end
    local lo = 1
    for i = n - 1, 1, -1 do
        if list[i].t <= t then lo = i break end
    end
    local a, b = list[lo], list[lo + 1]
    local span = b.t - a.t
    local k = span > 1e-6 and (t - a.t) / span or 0
    local pa, pb, qa, qb = a.pos, b.pos, a.rot, b.rot
    local sign = (qa.x * qb.x + qa.y * qb.y + qa.z * qb.z + qa.w * qb.w) < 0 and -1 or 1
    local qx, qy, qz, qw = qa.x + (qb.x * sign - qa.x) * k, qa.y + (qb.y * sign - qa.y) * k,
        qa.z + (qb.z * sign - qa.z) * k, qa.w + (qb.w * sign - qa.w) * k
    local len = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if len < 1e-6 then len = 1 end
    return {
        t = t,
        pos = Vector3f.new(pa.x + (pb.x - pa.x) * k, pa.y + (pb.y - pa.y) * k, pa.z + (pb.z - pa.z) * k),
        rot = Quaternion.new(qw / len, qx / len, qy / len, qz / len),
        look_yaw = (a.look_yaw or 0) + ((b.look_yaw or 0) - (a.look_yaw or 0)) * k,
        look_pitch = (a.look_pitch or 0) + ((b.look_pitch or 0) - (a.look_pitch or 0)) * k,
        flags = (k < 0.5) and a.flags or b.flags,   -- discrete: take the nearer sample
    }
end

-- Stance -----------------------------------------------------------------------
-- Packed into the packet's animBank field: bit0 crouch, bit1 walking (vs jog),
-- bit2 "flags present" (old senders and replay samples have none).
STANCE_CROUCH, STANCE_WALK, STANCE_VALID, STANCE_CUTSCENE = 1, 2, 4, 8

-- In a cutscene? RE7 runs them as game events (app.GameEventManager, held in
-- GameManager's static _GameEventMan: RunningEventControllers) or as movies
-- (GameManager.PlayingMovie).
local gem_field = nil
function local_cutscene()
    local gm = sdk.get_managed_singleton("app.GameManager")
    if gm == nil then return false end
    if safe(gm.get_field, gm, "PlayingMovie") ~= nil then return true end
    if gem_field == nil then
        local t = sdk.find_type_definition("app.GameManager")
        gem_field = t and t:get_field("_GameEventMan") or false
    end
    local gem = gem_field and safe(gem_field.get_data, gem_field, nil)
    local list = gem and safe(gem.get_field, gem, "RunningEventControllers")
    local n = list and tonumber(safe(list.call, list, "get_Count") or 0) or 0
    cutscene_events = n
    -- Some events run in the background while you play (c01e00_01 after the basement
    -- ladder, 2026-11-02): it hid the friend for good. Only count an event the menus
    -- treat as playing.
    local mm = n > 0 and sdk.get_managed_singleton("app.MenuManager")
    if mm and safe(mm.call, mm, "isPlayingEvent") == false then return false end
    return n > 0
end

local function player_movement(player)
    return player and safe(player.call, player, "getComponent(System.Type)", sdk.typeof("app.PlayerMovement"))
end

function local_stance_flags(player)
    local pm = player_movement(player)
    if pm == nil then return 0 end
    local f = STANCE_VALID
    if safe(pm.call, pm, "get_isCrouch") then f = f + STANCE_CROUCH end
    if safe(pm.call, pm, "get_isWalk") then f = f + STANCE_WALK end
    if cutscene_now then f = f + STANCE_CUTSCENE end   -- lets the other side hide us
    return f
end

-- Which chapter we're in (app.GameManager._CurrentChapter), shared so each side can
-- tell when the other is somewhere else.
function local_chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    return tonumber(gm and safe(gm.get_field, gm, "_CurrentChapter") or 0) or 0
end

-- Ethan's real move speeds (same game on both PCs), as playback references.
function local_move_speeds()
    local pm = player_movement(get_player())
    if pm == nil then return nil end
    return { walk = tonumber(safe(pm.get_field, pm, "WalkSpeed")), jog = tonumber(safe(pm.get_field, pm, "JogSpeed")),
        crouch = tonumber(safe(pm.get_field, pm, "CrouchMoveSpeed")) }
end

-- Look direction ---------------------------------------------------------------
-- Sender: camera yaw relative to the body, and pitch (radians). Characters face
-- +Z (confirmed with the bot); which camera axis is "forward" is picked once as
-- the one closest to the body's facing.

local function qrot_v(q, x, y, z)
    local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
    return x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz), z + q.w * tz + (q.x * ty - q.y * tx)
end
local function wrap(a) while a > math.pi do a = a - 2 * math.pi end while a < -math.pi do a = a + 2 * math.pi end return a end
local cam_sign = nil

function local_look(body_q)
    local cam = sdk.get_primary_camera()
    local cgo = cam and cam:call("get_GameObject")
    local cq = cgo and cgo:call("get_Transform"):call("get_Rotation")
    if cq == nil then return 0, 0 end
    local bx, _, bz = qrot_v(body_q, 0, 0, 1)
    local fx, fy, fz = qrot_v(cq, 0, 0, 1)
    local body_yaw = math.atan(bx, bz)
    if cam_sign == nil then
        local d_pos = math.abs(wrap(math.atan(fx, fz) - body_yaw))
        local d_neg = math.abs(wrap(math.atan(-fx, -fz) - body_yaw))
        cam_sign = (d_neg < d_pos) and -1 or 1
        log("look: camera forward is " .. (cam_sign > 0 and "+Z" or "-Z"))
    end
    fx, fy, fz = fx * cam_sign, fy * cam_sign, fz * cam_sign
    return wrap(math.atan(fx, fz) - body_yaw), math.asin(math.max(-1, math.min(1, fy)))
end

-- Receiver: after animation, turn the ghost's neck and head toward the look.
-- enabled=false: writing joint world rotations froze the Motion (walk frame stuck
-- at 106.5, 2026-10-29 16:50) and the turns accumulated. Needs a Motion-side
-- method (Motion.setLocalRotation per joint, or a constraint) before it's on.
-- v1/v2 history is in NOTES.md; v3 (write at PrepareRendering) works, so on by default.
local look = { yaw = 0, pitch = 0, joints = nil, err = false, enabled = true }

local function qmul_l(a, b)
    return {
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
end

local function axis_q(ax, ay, az, ang)
    local s = math.sin(ang / 2)
    return { x = ax * s, y = ay * s, z = az * s, w = math.cos(ang / 2) }
end

local function find_look_joints(tr)
    local arr = safe(tr.call, tr, "get_Joints")
    local elems = (arr and safe(arr.get_elements, arr)) or {}
    local names, neck, head = {}, nil, nil
    for _, j in ipairs(elems) do
        local n = tostring(safe(j.call, j, "get_Name"))
        names[#names + 1] = n
        local ln = n:lower()
        if neck == nil and ln:find("neck") then neck = j end
        if head == nil and ln:find("head") and not ln:find("end") then head = j end
    end
    fs.write("coop_joints.txt", table.concat(names, "\n"))
    log(string.format("look: %d joints; neck=%s head=%s", #names,
        neck and tostring(neck:call("get_Name")) or "none", head and tostring(head:call("get_Name")) or "none"))
    return { { neck, 0.4 }, { head, 0.6 } }
end

function apply_look(body_tr, body_q)
    if look.joints == nil then look.joints = find_look_joints(body_tr) end
    local yaw = math.max(-1.2, math.min(1.2, look.yaw))       -- about 70 degrees
    local pitch = math.max(-0.7, math.min(0.7, look.pitch))   -- about 40 degrees
    local rx, ry, rz = qrot_v(body_q, 1, 0, 0)                -- body's right axis
    for _, e in ipairs(look.joints) do
        local j, share = e[1], e[2]
        if j then
            local r = j:call("get_Rotation")
            local d = qmul_l(axis_q(0, 1, 0, yaw * share), axis_q(rx, ry, rz, -pitch * share))
            local n = qmul_l(d, { x = r.x, y = r.y, z = r.z, w = r.w })
            j:call("set_Rotation", Quaternion.new(n.w, n.x, n.y, n.z))
        end
    end
end

-- Network bridge -------------------------------------------------------------
-- CoopNet.cs (REFramework C# plugin) moves samples over UDP. Lua writes the
-- local player's state to coopnet_out.txt and reads the peer's samples from
-- coopnet_in.txt ("seq t px py pz qx qy qz qw bank id frame" per line).

local net = {
    enabled = true,         -- co-op mode: the ghost follows the other player by default
    delay = 0.15,           -- live; use 3 s for the echo test (visible trail)
    last_io = 0, last_status = 0,
    seq = 0, last_in_seq = -1,
    offset = nil,           -- local clock - sender clock (minimum seen)
    history = {},
    stats = "no status yet",
}

-- Read-only access for diagnostics (the console helper, testing).
function coop_net_state() return net end
function coop_ghost() return dummy end

-- Actions (2026-11-03 recording): the player's body plays its walk on layer 0 and actions
-- on top: blocking (Hands_Guard_*) on layers 1 and 2 with an upper-body joint mask, door
-- and wall touches on layer 4. The action clip (bank 0 motion ID) rides in the packet's
-- chapter field (chapter + 256 * motion ID); the friend's Ethan plays it on its own layer 1
-- with the same mask and blend mode. Layer-0 walking is left to the ghost's own picker.
-- Every layer is checked: upper-body and hand layers first (4, 1, 2, 3, 5, 6, 7), then a
-- full-body action on layer 0 (ladders, interactions: any clip from ID 1000 up, since the
-- walk set uses low IDs). Weapon banks also report BankID 0; bank 1 is camera-only.
-- The packet field is chapter + 256 * motion ID + 2^24 * layer.
ACTION_LAYERS = { 4, 1, 2, 3, 5, 6, 7, 0 }
local act = { motion = nil, motion_go = nil }
function local_action_clip(player)
    if act.motion_go ~= player then
        act.motion_go = player
        act.motion = safe(player.call, player, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    end
    local m = act.motion
    if m == nil then return 0, 0 end
    local count = tonumber(safe(m.call, m, "getLayerCount") or 0) or 0
    for _, li in ipairs(ACTION_LAYERS) do
        if li < count then
            local L = safe(m.call, m, "getLayer", li)
            if L then
                local bank = safe(L.call, L, "get_MotionBankID")
                local id = tonumber(safe(L.call, L, "get_MotionID") or 0xFFFFFFFF) or 0xFFFFFFFF
                if bank == 0 and id >= 1000 and id < 65536 then return id, li end
            end
        end
    end
    return 0, 0
end

local function action_field(player)
    local id, li = local_action_clip(player)
    if id == 0 then return 0 end
    return 256 * id + 16777216 * li
end

local function net_io()
    if not net.enabled then return end
    local now = os.clock()
    if now - net.last_io < 1 / 30 then return end
    net.last_io = now

    local player = get_player()
    if player then
        local tr = player:call("get_Transform")
        local p, q = tr:call("get_Position"), tr:call("get_Rotation")
        local ly, lp = local_look(q)
        net.seq = net.seq + 1
        -- animId carries our chapter; animFrame echoes the newest sender time we've
        -- received from the peer (mod 1000 s), so they can measure the round trip.
        fs.write("coopnet_out.txt", string.format("%d %.4f %.5f %.5f %.5f %.6f %.6f %.6f %.6f %d %d %.4f %.4f %.4f\n",
            net.seq, now, p.x, p.y, p.z, q.x, q.y, q.z, q.w, local_stance_flags(player),
            local_chapter() + action_field(player),
            (net.peer_t or 0) % 1000, ly, lp))
    end

    if fs.read == nil then
        if not net.no_read then net.no_read = true log("net: fs.read is not available in this REFramework build") end
        return
    end
    local text = fs.read("coopnet_in.txt")
    if text then
        for line in text:gmatch("[^\r\n]+") do
            local v = {}
            for num in line:gmatch("%S+") do v[#v + 1] = tonumber(num) end
            if #v >= 14 then
                local seq, t = v[1], v[2]
                if seq < net.last_in_seq - 1000 then net.last_in_seq = -1 net.offset = nil end  -- peer restarted
                if seq > net.last_in_seq then
                    net.last_in_seq = seq
                    local off = now - t
                    -- Smallest offset seen = the least-delayed sample. If samples suddenly
                    -- look 5 s+ older, the sender's clock restarted (their game or plugin
                    -- restarted): start over, or every new sample counts as stale forever.
                    if net.offset == nil or off < net.offset or off > net.offset + 5 then net.offset = off end
                    net.history[#net.history + 1] = { t = t + net.offset,
                        pos = Vector3f.new(v[3], v[4], v[5]), rot = Quaternion.new(v[9], v[6], v[7], v[8]),
                        flags = math.floor(v[10]), look_yaw = v[13], look_pitch = v[14] }
                    net.peer_t = t                         -- echoed back to the peer
                    local f = math.floor(v[11])
                    net.peer_chapter = f % 256
                    net.peer_action = math.floor(f / 256) % 65536
                    net.peer_action_layer = math.floor(f / 16777216) % 8
                    -- Round trip: the peer echoes our own send time (mod 1000 s).
                    if v[12] and v[12] > 0 then
                        local rtt = (now % 1000) - v[12]
                        if rtt < 0 then rtt = rtt + 1000 end
                        if rtt < 5 then net.ping = net.ping and (net.ping * 0.8 + rtt * 0.2) or rtt end
                    end
                end
            end
        end
        while #net.history > 0 and net.history[1].t < now - KEEP do table.remove(net.history, 1) end
    end

    if now - net.last_status > 1 then
        net.last_status = now
        local st = fs.read("coopnet_status.txt")
        if st then
            net.stats = st:gsub("\n", "  ")
            net.kv = {}
            for k, v in st:gmatch("(%w+)=([^\n]*)") do net.kv[k] = v end
        end
    end
end

local function root_of(go)
    local tr = go:call("get_Transform")
    while true do
        local p = safe(tr.call, tr, "get_Parent")
        if p == nil then break end
        tr = p
    end
    return tr:call("get_GameObject")
end

-- Quaternion helpers (x, y, z, w tables or REFramework quats).
local function qconj(q) return { x = -q.x, y = -q.y, z = -q.z, w = q.w } end
local function qmul(a, b)
    return {
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
end
local function qrot(q, v)
    local r = qmul(qmul(q, { x = v.x, y = v.y, z = v.z, w = 0 }), qconj(q))
    return { x = r.x, y = r.y, z = r.z }
end

-- Offset of a piece relative to the character root, in root space, so pieces
-- parented to joints (heads on the neck) land in the right place.
local function local_offset(root, go)
    local rtr, tr = root:call("get_Transform"), go:call("get_Transform")
    local rp, rq = rtr:call("get_Position"), rtr:call("get_Rotation")
    local p, q = tr:call("get_Position"), tr:call("get_Rotation")
    local inv = qconj({ x = rq.x, y = rq.y, z = rq.z, w = rq.w })
    local off = qrot(inv, { x = p.x - rp.x, y = p.y - rp.y, z = p.z - rp.z })
    local rot = qmul(inv, { x = q.x, y = q.y, z = q.z, w = q.w })
    return off, rot
end

local function meshes_under(go, out, depth)
    out = out or {}
    depth = depth or 0
    if depth > 12 then return out end
    local m = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    if m then
        local h = safe(m.call, m, "getMesh")
        local mh = safe(m.call, m, "get_Material")
        if h and mh then
            safe(h.add_ref, h)
            safe(mh.add_ref, mh)
            -- Meshes hold variants as parts (e.g. Mia's normal vs infected head), so
            -- copy the source's on/off pattern instead of enabling everything.
            local n = tonumber(safe(m.call, m, "getPartsEnableCount") or 0) or 0
            local mask = {}
            for i = 0, n - 1 do mask[i] = safe(m.call, m, "getPartsEnable", i) and true or false end
            local tr = go:call("get_Transform")
            out[#out + 1] = { holder = h, mholder = mh, path = tostring(safe(h.call, h, "get_ResourcePath")),
                owner = tostring(safe(go.call, go, "get_Name")), mask = mask, mask_n = n, src = m, go = go,
                same_joints = safe(tr.call, tr, "get_SameJointsConstraint"),
                parent_joint = safe(tr.call, tr, "get_ParentJoint"),
                is_root = depth == 0 }
        end
    end
    local tr = go:call("get_Transform")
    local child = safe(tr.call, tr, "get_Child")
    while child ~= nil do
        local cgo = safe(child.call, child, "get_GameObject")
        if cgo then meshes_under(cgo, out, depth + 1) end
        child = safe(child.call, child, "get_Next")
    end
    return out
end

-- Animation ------------------------------------------------------------------
-- Borrow the scene character's own motion bank (its clips on its skeleton) for
-- the body piece, list the clips, and play walk/idle on layer 0.

local anim = {
    src_root = nil,      -- scene character root GameObject
    motion = nil,        -- our body piece's via.motion.Motion
    clips = {},          -- { bank, id, name, frames }
    walk = nil, idle = nil,
    auto = false,
    playing = nil,
    change = nil,        -- TreeLayer.changeMotion method found at runtime
    ready = false,
    walk_ref = 0.8,      -- m/s the walk clip looks right at (owner-tuned with the bot, 2026-10-29)
    speed = 0, rate = 1,
}

local function dump_methods(tname, file)
    local t = sdk.find_type_definition(tname)
    if t == nil then return end
    local out = {}
    for _, m in ipairs(t:get_methods() or {}) do
        local ps = {}
        for _, p in ipairs(m:get_param_types() or {}) do ps[#ps + 1] = p:get_full_name() end
        out[#out + 1] = m:get_name() .. "(" .. table.concat(ps, ", ") .. ")"
    end
    fs.write(file, table.concat(out, "\n"))
end

local function find_change_motion()
    local t = sdk.find_type_definition("via.motion.TreeLayer")
    local best = nil
    for _, m in ipairs((t and t:get_methods()) or {}) do
        if m:get_name() == "changeMotion" then
            local ps = m:get_param_types() or {}
            local sig = {}
            for _, p in ipairs(ps) do sig[#sig + 1] = p:get_full_name() end
            log("TreeLayer.changeMotion(" .. table.concat(sig, ", ") .. ")")
            -- prefer (bank, id, startFrame, interpFrame, mode, curve)
            if #ps == 6 and sig[1] == "System.UInt32" and sig[2] == "System.UInt32" then best = m end
            if best == nil and #ps >= 4 and sig[1] == "System.UInt32" then best = m end
        end
    end
    return best
end

local function list_clips(motion)
    local clips, out = {}, {}
    local info = safe(sdk.create_instance, "via.motion.MotionInfo")
    if info then safe(info.add_ref, info) end
    local nb = tonumber(safe(motion.call, motion, "getActiveMotionBankCount") or 0) or 0
    for b = 0, nb - 1 do
        local bank = safe(motion.call, motion, "getActiveMotionBank", b)
        local bid = bank and safe(bank.call, bank, "get_BankID")
        local bname = bank and safe(bank.call, bank, "get_Name")
        local n = bid and tonumber(safe(motion.call, motion, "getMotionCount", bid) or 0) or 0
        out[#out + 1] = string.format("bank %s id=%s name=%s motions=%d", tostring(b), tostring(bid), tostring(bname), n)
        for i = 0, n - 1 do
            local ok = info and safe(motion.call, motion, "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)", bid, i, info)
            if ok then
                local c = { bank = bid, id = safe(info.call, info, "get_MotionID"),
                    name = tostring(safe(info.call, info, "get_MotionName")),
                    frames = safe(info.call, info, "get_MotionEndFrame") }
                clips[#clips + 1] = c
                out[#out + 1] = string.format("  [%s/%s] %s (%s frames)", tostring(c.bank), tostring(c.id), c.name, tostring(c.frames))
            end
        end
    end
    fs.write("coop_motions.txt", table.concat(out, "\n"))
    log(string.format("animation: %d banks, %d clips listed (coop_motions.txt)", nb, #clips))
    return clips
end

anim_from_player = false

function setup_animation(body_part)
    if anim.src_root == nil or body_part == nil then return end
    local src = anim_from_player and get_player() or anim.src_root
    if anim_from_player then log("animation: using the player's own Motion (Ethan skeleton)") end
    local src_motion = safe(src.call, src, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    if src_motion == nil then log("animation: scene character has no via.motion.Motion") return end
    dump_methods("via.motion.TreeLayer", "coop_treelayer_api.txt")

    local go = body_part.go
    local motion = go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    local function counts(stage)
        log(string.format("animation %s: layers=%s activeBanks=%s banks=%s dynBanks=%s jointsConstructed=%s joints=%s",
            stage, tostring(safe(motion.call, motion, "getLayerCount")),
            tostring(safe(motion.call, motion, "getActiveMotionBankCount")),
            tostring(safe(motion.call, motion, "getMotionBankCount")),
            tostring(safe(motion.call, motion, "getDynamicMotionBankCount")),
            tostring(safe(motion.call, motion, "get_JointsConstructed")),
            tostring(safe(motion.call, motion, "get_JointCount"))))
        local l0 = safe(motion.call, motion, "getLayer", 0)
        if l0 then
            log(string.format("  layer0 bank=%s motion=%s frame=%s end=%s",
                tostring(safe(l0.call, l0, "get_MotionBankID")), tostring(safe(l0.call, l0, "get_MotionID")),
                tostring(safe(l0.call, l0, "get_Frame")), tostring(safe(l0.call, l0, "get_EndFrame"))))
        end
    end
    counts("before swap")
    -- Keep the dummy's MotionFsm running for now: it owns the layers. It gets
    -- disabled in play_clip only once a clip is actually bound to a layer.
    anim.fsm_components = {}
    for _, tn in ipairs({ "via.motion.MotionFsm", "app.MotionManager", "app.SequenceController", "app.EventActionController" }) do
        local c = safe(go.call, go, "getComponent(System.Type)", sdk.typeof(tn))
        if c then anim.fsm_components[#anim.fsm_components + 1] = c end
    end
    anim.counts = counts
    local bank_asset = safe(src_motion.call, src_motion, "get_MotionBankAsset")
    local jmap = safe(src_motion.call, src_motion, "get_JointMap")
    log("animation: scene bank asset " .. tostring(bank_asset and safe(bank_asset.call, bank_asset, "get_ResourcePath")) ..
        ", joint map " .. tostring(jmap and safe(jmap.call, jmap, "get_ResourcePath")))
    if bank_asset then
        safe(bank_asset.add_ref, bank_asset)
        local _, err = safe(motion.call, motion, "set_MotionBankAsset", bank_asset)
        if err then log("animation: set_MotionBankAsset ERR " .. tostring(err)) end
    end
    counts("after set_MotionBankAsset")
    if jmap then safe(jmap.add_ref, jmap) safe(motion.call, motion, "set_JointMap", jmap) end
    safe(motion.call, motion, "setupMotionBank")
    counts("after setupMotionBank")
    anim.motion = motion
    anim.change = find_change_motion()
    -- The scene character is inactive and has no active banks; list from our own
    -- Motion once the borrowed bank has loaded (async), retrying in poll_clips().
    anim.poll_until = os.clock() + 20
    anim.next_poll = os.clock() + 1
    anim.ready = true
end

local function poll_clips()
    if not anim.ready or anim.poll_until == nil or #anim.clips > 0 then return end
    local now = os.clock()
    if now < anim.next_poll then return end
    anim.next_poll = now + 1
    local nb = tonumber(safe(anim.motion.call, anim.motion, "getActiveMotionBankCount") or 0) or 0
    local nall = tonumber(safe(anim.motion.call, anim.motion, "getMotionBankCount") or 0) or 0
    log(string.format("animation poll: active banks=%d, banks=%d", nb, nall))
    if nb > 0 then
        anim.clips = list_clips(anim.motion)
        anim.poll_until = nil
        -- Without a playing clip the skeleton never updates and the body stays
        -- frozen while its transform moves. Pick walk/idle by name and start now.
        -- Ethan's bank has a full locomotion set; pick it by exact name. Otherwise
        -- (Mia) fall back to the first walk/idle-looking names.
        -- Player banks name clips "<plXXXX>_<suffix>" (Ethan pl0000_Hands_Walk_Loop);
        -- other playable characters (the videotapes) use their own prefix, so look the
        -- locomotion set up by suffix.
        local by_name = {}
        for _, c in ipairs(anim.clips) do
            local suffix = c.name:gsub("^pl%d+_", "")
            if by_name[suffix] == nil then by_name[suffix] = c end
        end
        local set = {
            fwd = by_name["Hands_Walk_Loop"], back = by_name["Hands_WalkB_Loop"],
            left = by_name["Hands_WalkL_Loop"], right = by_name["Hands_WalkR_Loop"],
            jfwd = by_name["Hands_Jog_Loop"], jback = by_name["Hands_JogB_Loop"],
            jleft = by_name["Hands_JogL_Loop"], jright = by_name["Hands_JogR_Loop"],
            cfwd = by_name["Hands_WalkCrouch_Loop"], cback = by_name["Hands_WalkCrouchB_Loop"],
            cleft = by_name["Hands_WalkCrouchL_Loop"], cright = by_name["Hands_WalkCrouchR_Loop"],
            -- Not Stand_Loop: it never binds and jams the layer (18:50, 19:09), and
            -- as the first clip of a fresh ghost it leaves him T-posed for good.
            idle = by_name["Hands_StandDamage_Loop"] or by_name["Hands_Stand_Loop"],
        }
        -- Stand_Loop and Crouch_Loop (20:49) jam the layer; crouching still is the
        -- crouch-walk clip held on one frame instead. Retire them under any prefix.
        anim.bad = anim.bad or {}
        anim.idle_hold = false   -- a fallback from an earlier ghost/chapter must not carry over
        for _, c in ipairs(anim.clips) do
            local suffix = c.name:gsub("^pl%d+_", "")
            if suffix == "Hands_Stand_Loop" or suffix == "Hands_Crouch_Loop" then anim.bad[c.name] = true end
        end
        set.cidle = nil
        if set.idle and anim.bad[set.idle.name] then set.idle = nil end
        if set.fwd and set.idle then
            anim.set, anim.walk, anim.idle = set, set.fwd, set.idle
            anim.walk_ref, anim.jog_ref, anim.crouch_ref = 1.3, 3.2, 0.9
            local sp = local_move_speeds()
            if sp and sp.walk and sp.walk > 0 then
                anim.walk_ref, anim.jog_ref = sp.walk, sp.jog or anim.jog_ref
                anim.crouch_ref = sp.crouch or anim.crouch_ref
            end
            log(string.format("animation: Ethan locomotion set (walk/jog/crouch x 4 + stand/crouch idle); refs walk %.2f jog %.2f crouch %.2f m/s",
                anim.walk_ref, anim.jog_ref, anim.crouch_ref))
        end
        for _, c in ipairs(anim.clips) do
            local ln = c.name:lower()
            if anim.walk == nil and ln:find("walk") then anim.walk = c end
            if anim.idle == nil and (ln:find("idle") or ln:find("wait")) then anim.idle = c end
        end
        log("animation: auto-picked walk=" .. (anim.walk and anim.walk.name or "none") ..
            " idle=" .. (anim.idle and anim.idle.name or "none"))
        -- Start on the known-good forward walk so the fresh layer binds a clip
        -- first; Auto switches to the idle on its next check.
        local first = anim.walk or anim.idle or anim.clips[1]
        if first then play_clip(first) end
        anim.auto = (anim.walk ~= nil)
    elseif now > anim.poll_until then
        log("animation: banks never became active on the ghost")
        anim.poll_until = nil
    end
end

-- Fresh, constructed layer on slot 0 (a jammed layer ignores later clips).
function rebuild_layer()
    local tl = safe(sdk.create_instance, "via.motion.TreeLayer")
    if tl == nil then log("rebuild_layer: create_instance failed") return end
    safe(tl.add_ref, tl)
    safe(tl.call, tl, ".ctor")
    safe(anim.motion.call, anim.motion, "setLayerCount", 1)
    anim.action = nil   -- the action layer went with it; ghost_action re-adds it
    local _, err = safe(anim.motion.call, anim.motion, "setLayer", 0, tl)
    log("rebuild_layer: new TreeLayer on slot 0" .. (err and (" ERR " .. tostring(err)) or ""))
end

-- Fallback idles once a clip has been retired as bad.
-- Matched by suffix so they work for any playable character's bank.
local IDLE_FALLBACKS = { "Hands_StandDamage_Loop", "E-Radar_Stand_Loop" }
function next_idle()
    for _, suffix in ipairs(IDLE_FALLBACKS) do
        for _, c in ipairs(anim.clips) do
            if c.name:gsub("^pl%d+_", "") == suffix and not (anim.bad and anim.bad[c.name]) then
                log("idle fallback -> " .. c.name)
                return c
            end
        end
    end
    -- Last resort: the forward walk held still at its first frame.
    log("idle fallback -> walk held at frame 0")
    anim.idle_hold = true
    return anim.set and anim.set.fwd or anim.walk
end

function play_clip(c)
    if not anim.ready or anim.change == nil then log("play: animation not ready") return end
    local layer = safe(anim.motion.call, anim.motion, "getLayer", 0)
    if layer == nil then
        -- Disabling the dummy's MotionFsm leaves the Motion with no layers;
        -- setLayerCount creates them.
        local before = safe(anim.motion.call, anim.motion, "getLayerCount")
        local _, err = safe(anim.motion.call, anim.motion, "setLayerCount", 1)
        layer = safe(anim.motion.call, anim.motion, "getLayer", 0)
        log(string.format("play: layer count %s -> setLayerCount(1)%s -> layer0 %s", tostring(before),
            err and (" ERR " .. tostring(err)) or "", layer and "ok" or "still missing"))
        if layer == nil then
            -- Recipe from EMV Engine (alphaZomega): construct the TreeLayer, then
            -- setLayerCount + setLayer. Without .ctor the clip never binds (end=0).
            local tl, cerr = safe(sdk.create_instance, "via.motion.TreeLayer")
            if tl then
                safe(tl.add_ref, tl)
                local ctor_ok = safe(tl.call, tl, ".ctor")
                log("play: TreeLayer .ctor -> " .. tostring(ctor_ok))
                safe(anim.motion.call, anim.motion, "setLayerCount", 1)
                local _, serr = safe(anim.motion.call, anim.motion, "setLayer", 0, tl)
                layer = safe(anim.motion.call, anim.motion, "getLayer", 0)
                log("play: created TreeLayer + setLayer(0)" .. (serr and (" ERR " .. tostring(serr)) or "") ..
                    " -> layer0 " .. (layer and "ok" or "still missing"))
            else
                log("play: create_instance(via.motion.TreeLayer) failed: " .. tostring(cerr))
            end
        end
        if layer == nil then return end
    end
    -- A motion-tree resource on the layer overrides direct clips; clear it.
    safe(layer.call, layer, "set_Resource", nil)
    local n = #(anim.change:get_param_types() or {})
    local ok, err
    if n == 6 then
        ok, err = pcall(anim.change.call, anim.change, layer, c.bank, c.id, 0.0, anim.next_blend or BLEND_DIR, 2, 0)
    else
        ok, err = pcall(anim.change.call, anim.change, layer, c.bank, c.id, 0.0, anim.next_blend or BLEND_DIR)
    end
    safe(layer.call, layer, "set_Speed", 1.0)
    safe(anim.motion.call, anim.motion, "set_Enabled", true)
    anim.playing = c
    anim.verify_at = os.clock() + 1.0
    log("play " .. c.name .. " [" .. tostring(c.bank) .. "/" .. tostring(c.id) .. "]: " .. (ok and "ok" or ("ERR " .. tostring(err))))
end

-- One second after a play, record what layer 0 is actually doing. If the clip
-- is bound (end frame > 0), stop the dummy's FSM so it can't override us.
local function verify_playback()
    if anim.verify_at == nil or os.clock() < anim.verify_at then return end
    anim.verify_at = nil
    local layer = safe(anim.motion.call, anim.motion, "getLayer", 0)
    if layer == nil then log("verify: no layer 0") return end
    local endf = tonumber(safe(layer.call, layer, "get_EndFrame") or 0) or 0
    local fr = tonumber(safe(layer.call, layer, "get_Frame") or 0) or 0
    local frozen = anim.last_verify_frame and math.abs(fr - anim.last_verify_frame) < 1e-4
    anim.last_verify_frame = fr
    -- Ethan's Stand_Loop never binds (end frame stays at the previous clip's) and
    -- jams the layer for good (2026-10-29 18:50). Detect a bad bind or a stuck
    -- frame, rebuild the layer, retire the clip, and move to a fallback idle.
    local want_end = anim.playing and tonumber(anim.playing.frames or 0) or 0
    -- During a blend the layer can still report the previous clip's length (20:50:
    -- JogB showed 48, JogL's), so a wrong length only counts on two checks in a row.
    local wrong_now = want_end > 0 and endf > 0 and math.abs(endf - want_end) > 0.5
    local wrong_end = wrong_now and anim.wrong_prev == (anim.playing and anim.playing.name)
    anim.wrong_prev = wrong_now and (anim.playing and anim.playing.name) or nil
    if wrong_now and not wrong_end then anim.verify_at = os.clock() + 0.5 end   -- re-check soon
    -- (Head look v3 is proven safe, so a freeze no longer switches it off.)
    if (frozen or wrong_end) and anim.playing then
        local bad = anim.playing
        -- Several rebuilds in a row that still don't bind: rebuild the whole ghost.
        anim.fail_streak = (anim.fail_streak or 0) + 1
        if anim.fail_streak >= 3 and os.clock() - (anim.last_full_rebuild or -100) > 30 then
            anim.last_full_rebuild = os.clock()
            anim.fail_streak = 0
            log("verify: layer rebuilds keep failing; rebuilding the whole Ethan ghost")
            local ok, err = pcall(build_ethan)
            if not ok then log("full rebuild ERR " .. tostring(err)) end
            return
        end
        log(string.format("verify: %s on %s (end=%s, want %s), rebuilding layer",
            frozen and "FROZEN" or "WRONG BIND", bad.name, tostring(endf), tostring(want_end)))
        anim.bad = anim.bad or {}
        anim.bad[bad.name] = true
        rebuild_layer()
        local was_idle = (bad == anim.idle)
        if was_idle then anim.idle = next_idle() end
        anim.last_verify_frame = nil
        play_clip(was_idle and (anim.idle or bad) or bad)
        return
    end
    log(string.format("verify: layer0 bank=%s motion=%s frame=%s speed=%s end=%s; Motion enabled=%s",
        tostring(safe(layer.call, layer, "get_MotionBankID")), tostring(safe(layer.call, layer, "get_MotionID")),
        tostring(safe(layer.call, layer, "get_Frame")), tostring(safe(layer.call, layer, "get_Speed")),
        tostring(endf), tostring(safe(anim.motion.call, anim.motion, "get_Enabled"))))
    if anim.counts then anim.counts("at verify") end
    -- A fresh layer sometimes doesn't bind the first clip; retry a few times.
    if endf <= 0 and anim.playing and (anim.retries or 0) < 3 then
        anim.retries = (anim.retries or 0) + 1
        log("verify: clip not bound, retry " .. anim.retries)
        play_clip(anim.playing)
        anim.verify_at = os.clock() + 0.5
        return
    end
    -- Fallback: re-add the active banks' motion lists as DynamicMotionBanks with
    -- the same bank ids (EMV Engine's way of adding clips), then retry once.
    if endf <= 0 and not anim.dyn_tried and anim.playing then
        anim.dyn_tried = true
        local m = anim.motion
        local nb = tonumber(safe(m.call, m, "getActiveMotionBankCount") or 0) or 0
        local added = 0
        for b = 0, nb - 1 do
            local bank = safe(m.call, m, "getActiveMotionBank", b)
            local list = bank and safe(bank.call, bank, "get_MotionList")
            local bid = bank and safe(bank.call, bank, "get_BankID")
            if list then
                local db = safe(sdk.create_instance, "via.motion.DynamicMotionBank")
                if db then
                    safe(db.add_ref, db)
                    safe(db.call, db, ".ctor")
                    safe(db.call, db, "set_MotionList", list)
                    safe(db.call, db, "set_OverwriteBankID", true)
                    safe(db.call, db, "set_BankID", bid)
                    local count = tonumber(safe(m.call, m, "getDynamicMotionBankCount") or 0) or 0
                    safe(m.call, m, "setDynamicMotionBankCount", count + 1)
                    safe(m.call, m, "setDynamicMotionBank", count, db)
                    added = added + 1
                end
            end
        end
        log("verify: clip not bound; added " .. added .. " DynamicMotionBank(s), retrying " .. anim.playing.name)
        play_clip(anim.playing)
        return
    end
    if endf > 0 then
        anim.retries = 0
        anim.fail_streak = 0
        anim.bound_t = os.clock()   -- a clip really bound and is advancing (reload test reads this)
        -- Leave the dummy's MotionFsm/app.MotionManager enabled: disabling them
        -- froze the layer (frame stuck at 0.2889 for 13 s, 2026-10-29 16:17).
        -- In RE7 app.MotionManager drives the Motion update.
    end
end

-- Auto: pick walk or idle from how fast the ghost moved over the last 0.25 s.
local last_auto = { t = 0, pos = nil }

-- The friend's action clip (blocking, touching a door) on the ghost's layer 1, over the
-- walk on layer 0. Mask and blend mode come from our own player's layer that plays such
-- clips (masks are shared: both use the pl0000 joint map). Nothing playing = layer 1 off.
local function own_layer_setup(li)
    local player = get_player()
    local m = player and safe(player.call, player, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    local L = m and safe(m.call, m, "getLayer", li)
    if L == nil then return nil, nil end
    return safe(L.call, L, "get_JointMaskID"), safe(L.call, L, "get_BlendMode")
end

function ghost_action()
    if not anim.ready or anim.motion == nil or anim.change == nil then return end
    -- test_action: set from a probe (bot tests); forced_action: coop_revive's lying-down pose.
    local want = net.test_action or net.forced_action or net.peer_action or 0
    local src_layer = (net.test_action and (net.test_action_layer or 1))
        or (net.forced_action and (net.forced_action_layer or 0)) or (net.peer_action_layer or 1)
    if want == (anim.action or 0) then return end
    local m = anim.motion
    if (tonumber(safe(m.call, m, "getLayerCount") or 0) or 0) < 2 then
        safe(m.call, m, "setLayerCount", 2)
        if safe(m.call, m, "getLayer", 1) == nil then
            local tl = safe(sdk.create_instance, "via.motion.TreeLayer")
            if tl then safe(tl.add_ref, tl) safe(tl.call, tl, ".ctor") safe(m.call, m, "setLayer", 1, tl) end
        end
    end
    local L = safe(m.call, m, "getLayer", 1)
    if L == nil then return end
    anim.action = want
    if want == 0 then
        safe(L.call, L, "set_BlendRate", 0.0)
        return
    end
    -- Same mask and blend mode as the layer it came from on the friend's body (layer 0 =
    -- a full-body move, which then covers the walk underneath).
    local mask, mode = own_layer_setup(src_layer)
    if mask then safe(L.call, L, "set_JointMaskID", mask) end
    if mode then safe(L.call, L, "set_BlendMode", mode) end
    safe(L.call, L, "set_Resource", nil)
    local n = #(anim.change:get_param_types() or {})
    if n == 6 then
        pcall(anim.change.call, anim.change, L, 0, want, 0.0, 6.0, 2, 0)
    else
        pcall(anim.change.call, anim.change, L, 0, want, 0.0, 6.0)
    end
    safe(L.call, L, "set_Speed", 1.0)
    safe(L.call, L, "set_BlendRate", 1.0)
    log(string.format("action: friend plays motion %d from layer %d (mask %s, mode %s)", want, src_layer,
        tostring(mask), tostring(mode)))
end

local function auto_animate(anchor, anchor_rot)
    if not anim.auto or anchor == nil then return end
    local now = os.clock()
    if now - last_auto.t < 0.1 then return end   -- was 0.25: felt laggy starting to move
    local vx, vz, speed = 0, 0, 0
    if anim.vel then
        vx, vz = anim.vel.x, anim.vel.z         -- look-ahead velocity from the buffer
    elseif last_auto.pos then
        local dt = now - last_auto.t
        vx, vz = (anchor.x - last_auto.pos.x) / dt, (anchor.z - last_auto.pos.z) / dt
    end
    speed = math.sqrt(vx * vx + vz * vz)
    last_auto.t, last_auto.pos = now, { x = anchor.x, z = anchor.z }
    -- Light smoothing so one jittery sample doesn't flip walk/idle.
    anim.speed = (anim.speed or 0) * 0.3 + speed * 0.7
    -- Start and stop at different speeds so it doesn't toggle around one value.
    local moving_now = anim.moving and (anim.speed > MOVE_STOP) or (anim.speed > MOVE_START)
    anim.moving = moving_now

    -- Stance from the sender's flags when present; otherwise infer jog from speed.
    local f = anim.flags or 0
    local has = (f & STANCE_VALID) ~= 0
    local crouch = has and (f & STANCE_CROUCH) ~= 0
    local s = anim.set
    local still_clip = (crouch and s and s.cidle and not (anim.bad and anim.bad[s.cidle.name])) and s.cidle
        or (crouch and s and s.cfwd) or anim.idle
    local hold_still = crouch and s and still_clip == s.cfwd   -- crouch-walk frozen on one frame
    local want, ref = still_clip, anim.walk_ref
    if anim.moving then
        want = anim.walk
        if s and anchor_rot then
            -- Direction of travel relative to facing: characters face +Z, so the
            -- right-hand side is -X in local space.
            local q = { x = anchor_rot.x, y = anchor_rot.y, z = anchor_rot.z, w = anchor_rot.w }
            local fx, _, fz = qrot_v(q, 0, 0, 1)
            local rx, _, rz = qrot_v(q, -1, 0, 0)
            local fwd, side = vx * fx + vz * fz, vx * rx + vz * rz
            local jog = (has and not crouch and (f & STANCE_WALK) == 0) or (not has and anim.speed > 2.2)
            local pick = crouch and { s.cfwd, s.cback, s.cleft, s.cright }
                or jog and { s.jfwd, s.jback, s.jleft, s.jright }
                or { s.fwd, s.back, s.left, s.right }
            local cand = (math.abs(fwd) >= math.abs(side)) and (fwd >= 0 and "fwd" or "back")
                or (side >= 0 and "right" or "left")
            -- Hysteresis: near a diagonal, keep the current direction unless the
            -- new axis clearly dominates (25% margin).
            local old = anim.dir
            if old and old ~= cand and old ~= "-" then
                local old_axis = (old == "fwd" or old == "back") and math.abs(fwd) or math.abs(side)
                local new_axis = (cand == "fwd" or cand == "back") and math.abs(fwd) or math.abs(side)
                if new_axis < old_axis * 1.25 then cand = old end
            end
            local idx = { fwd = 1, back = 2, left = 3, right = 4 }
            want = pick[idx[cand]] or s.fwd
            ref = crouch and anim.crouch_ref or jog and anim.jog_ref or anim.walk_ref
            anim.dir = cand
            anim.stance = crouch and "crouch" or jog and "jog" or "walk"
        end
    else
        anim.stance = crouch and "crouch" or "stand"
        anim.dir = "-"
    end
    -- Blend longer across stance changes than between directions, and give a
    -- moving clip a minimum hold so diagonals don't flicker.
    if want and anim.playing ~= want then
        local stance_changed = anim.stance ~= anim.last_stance
        local held = os.clock() - (anim.clip_t or 0)
        if stance_changed or held >= MIN_HOLD then
            anim.next_blend = stance_changed and BLEND_STANCE or BLEND_DIR
            play_clip(want)
            anim.clip_t = os.clock()
            anim.last_stance = anim.stance
        end
    end
    -- Last-resort idle is the walk clip held still (only while standing: walking forward
    -- plays that same clip and must keep its stride, 2026-11-02 slide).
    if not anim.moving and ((want == anim.idle and anim.idle_hold) or hold_still) then
        local layer = safe(anim.motion.call, anim.motion, "getLayer", 0)
        if layer then safe(layer.call, layer, "set_Speed", 0.0) end
    end
    -- Match the cycle to how fast the ghost actually moves (no foot sliding).
    if anim.moving and anim.playing == want then
        local layer = safe(anim.motion.call, anim.motion, "getLayer", 0)
        local target = math.max(0.5, math.min(2.0, anim.speed / ref))
        -- Ease the stride rate too; jumping it every 0.1 s looked choppy.
        local rate = (anim.rate or target) * 0.7 + target * 0.3
        if layer then safe(layer.call, layer, "set_Speed", rate) end
        anim.rate = rate
    end
end

-- Build the co-op ghost from the local player's character. Its meshes hang off the
-- player object; assembling from any of them collects the player's Shadow set (the
-- full body RE7 renders only for the shadow), animated with the player's own motion
-- bank. Usually Ethan (pl0000); in the videotapes both players play the same other
-- character, so that character works the same way. First person hides parts like
-- the head on the source, so every part is shown on the ghost.
function build_ethan()
    for _, c in ipairs(candidates) do
        if c.mesh:find("Character/Player/pl%d") then
            local owner = safe(c.comp.call, c.comp, "get_GameObject")
            local root = owner and root_of(owner)
            -- skip standalone event props (e.g. sm1649_EthanLHand_Event)
            local player = get_player()
            if root and player and root:get_address() == player:get_address() then
                parts_mode = "all"
                anim_from_player = true
                log("build Ethan from " .. c.mesh)
                assemble_from(c)
                return
            end
        end
    end
    log("build Ethan: no Ethan mesh on the player object (is the player loaded?)")
end

function assemble_from(c)
    local src_go = c.comp:call("get_GameObject")
    local root = root_of(src_go)
    anim.src_root = root
    log("assemble: source mesh owner '" .. tostring(src_go:call("get_Name")) ..
        "', root '" .. tostring(root:call("get_Name")) .. "'")
    -- Replace any previous ghost instead of stacking a second one on top.
    local destroy = sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)")
    for _, old in ipairs(parts) do pcall(destroy.call, destroy, nil, old.go) end
    parts = {}
    anim.clips, anim.playing, anim.walk, anim.idle, anim.set, anim.retries = {}, nil, nil, nil, nil, 0
    -- Head look caches the old ghost's joints; drop them or it addresses destroyed
    -- objects ("Invoke threw an exception" after Rebuild Ethan, 20:54).
    if look2 then look2.list, look2.jobj = nil, nil end
    look.err = false
    -- ...and the old ghost's Motion: until setup_animation binds the new one, head look
    -- and the watchdog must not touch it (that was the remaining Invoke error, 21:04).
    anim.motion, anim.ready, anim.verify_at, anim.last_verify_frame = nil, false, nil, nil
    anim.action = nil

    local list = meshes_under(root)
    log("assemble: " .. #list .. " meshes under root")
    if anim_from_player then
        -- Ethan: the player object also holds his first-person body, props, the
        -- molded-arm attachments and a full "Shadow" copy RE7 renders only for his
        -- shadow. The Shadow set is the complete third-person Ethan; use only it,
        -- with ShadowBody as the root whose skeleton the other pieces borrow.
        local shadow = {}
        for _, e in ipairs(list) do
            if e.owner:find("^Shadow") then
                e.is_root = (e.owner == "ShadowBody")
                if not e.is_root then e.same_joints = true end
                shadow[#shadow + 1] = e
            end
        end
        if #shadow == 0 then
            -- No full body to borrow (e.g. the temporary loading-scene player): no ghost.
            log("assemble: player '" .. tostring(root:call("get_Name")) .. "' has no Shadow body; no ghost yet")
            return
        end
        if dress_as_friend_choice then shadow = dress_as_friend_choice(shadow) end
        list = shadow
        log("assemble: " .. tostring(root:call("get_Name")) .. " uses " .. #shadow .. " Shadow* pieces")
        ghost_built_t = os.clock()
        -- The bot's circle was centred during the load (often outside the map): move it
        -- to where the real player now stands.
        if net.kv and net.kv.mode == "bot" then fs.write("coopnet_command.txt", "botrecenter") end
    end
    local p = get_player():call("get_Transform"):call("get_Position")
    for _, e in ipairs(list) do
        if not e.path:find("_sim") then
            local go = safe(prefab.call, prefab, "instantiate(via.vec3)", Vector3f.new(p.x + 1.5, p.y, p.z))
            if go then
                local off, lrot = local_offset(root, e.go)
                parts[#parts + 1] = { go = go, holder = e.holder, mholder = e.mholder, path = e.path, state = "new",
                    alts = e.alts,
                    mask = e.mask, mask_n = e.mask_n, src = e.src, off = off, lrot = lrot,
                    is_root = e.is_root, same_joints = e.same_joints, parent_joint = e.parent_joint }
                log(string.format("  offset from root: %.3f %.3f %.3f  root=%s SameJointsConstraint=%s ParentJoint=%s",
                    off.x, off.y, off.z, tostring(e.is_root), tostring(e.same_joints), tostring(e.parent_joint)))
                local bits = {}
                for i = 0, math.min(e.mask_n, 64) - 1 do bits[#bits + 1] = e.mask[i] and "1" or "0" end
                log("  part: " .. e.path .. " (from " .. e.owner .. ") source parts[" .. e.mask_n .. "]=" .. table.concat(bits))
            else
                log("  FAIL instantiate for " .. e.path)
            end
        end
    end
    parts_frames = 0
    -- The main dummy still wears Ethan's first-person shirt; hide it and keep it
    -- only as the invisible anchor the parts follow.
    safe(dummy.call, dummy, "set_DrawSelf", false)
end

-- The live character's look (e.g. Mia's infection) is driven by material
-- variables the game sets at runtime; a fresh material gets defaults. Copy every
-- float/float4 variable from the scene mesh. Variable types are logged once so
-- the type ids can be confirmed.
local INTEREST = { "infect", "mold", "black", "dirt", "blood", "damage", "wet", "blend", "rate", "mask" }
local types_logged = false

function copy_material_vars(src, dst, label)
    if src == nil or dst == nil then return 0 end
    local copied, notable = 0, {}
    local types_seen = {}
    local nm = tonumber(safe(src.call, src, "get_MaterialNum") or 0) or 0
    for mi = 0, nm - 1 do
        local mname = tostring(safe(src.call, src, "getMaterialName", mi))
        local nv = tonumber(safe(src.call, src, "getMaterialVariableNum", mi) or 0) or 0
        for vi = 0, nv - 1 do
            local vname = tostring(safe(src.call, src, "getMaterialVariableName", mi, vi))
            local vtype = safe(src.call, src, "getMaterialVariableType", mi, vi)
            types_seen[tostring(vtype)] = vname
            local value, ok = nil, false
            if vtype == 0 or vtype == 1 then
                value = safe(src.call, src, "getMaterialFloat", mi, vi)
                if value ~= nil then ok = safe(dst.call, dst, "setMaterialFloat", mi, vi, value) ~= false end
            elseif vtype == 4 or vtype == 2 then
                value = safe(src.call, src, "getMaterialFloat4", mi, vi)
                if value ~= nil then ok = safe(dst.call, dst, "setMaterialFloat4", mi, vi, value) ~= false end
            end
            if ok then copied = copied + 1 end
            local lv = vname:lower()
            for _, k in ipairs(INTEREST) do
                if lv:find(k) then
                    local dv = (vtype == 0 or vtype == 1) and safe(dst.call, dst, "getMaterialFloat", mi, vi) or nil
                    notable[#notable + 1] = string.format("%s.%s(t%s)=%s dst=%s", mname, vname, tostring(vtype),
                        type(value) == "number" and string.format("%.3f", value) or tostring(value),
                        type(dv) == "number" and string.format("%.3f", dv) or tostring(dv))
                    break
                end
            end
        end
    end
    if not types_logged then
        types_logged = true
        local t = {}
        for k, v in pairs(types_seen) do t[#t + 1] = k .. ":" .. v end
        log("material var types (type:example): " .. table.concat(t, ", "))
    end
    log(string.format("  %s: copied %d material vars from scene", label, copied))
    for _, s in ipairs(notable) do log("    " .. s) end
    return copied
end

local parts_mode = "source"  -- "source" = copy scene character's parts mask, "all" = everything on

function apply_mask(part)
    local mesh = part.mesh
    if mesh == nil then return end
    local n = tonumber(safe(mesh.call, mesh, "getPartsEnableCount") or 0) or 0
    for i = 0, n - 1 do
        local on = true
        if parts_mode == "source" and part.mask_n > 0 then on = part.mask[i] == true end
        safe(mesh.call, mesh, "setPartsEnable", i, on)
    end
end

-- Finish parts a few frames after spawning (components aren't ready at once),
-- then keep them glued to the main dummy's position.
re.on_frame(function()
    record_player()
    local nok, nerr = pcall(net_io)
    if not nok and not net.io_err then net.io_err = true log("net ERR " .. tostring(nerr)) end
    if #parts == 0 or dummy == nil then return end
    parts_frames = parts_frames + 1

    local dtr = dummy:call("get_Transform")
    local anchor_rot = nil
    if follow then
        local s
        local list = net.enabled and net.history or history
        local tr = os.clock() - (net.enabled and net.delay or DELAY)
        s = sample_interp(list, tr)
        -- The ghost renders in the past, so the next LOOKAHEAD s are already
        -- buffered: take velocity from there so the walk starts as he moves.
        local a = sample_interp(list, tr + LOOKAHEAD)
        local b = sample_interp(list, tr + LOOKAHEAD - 0.12)
        if a and b then
            anim.vel = { x = (a.pos.x - b.pos.x) / 0.12, z = (a.pos.z - b.pos.z) / 0.12 }
        end
        -- Ease the head toward the friend's look (time constant LOOK_TAU): their mouse
        -- flicks and the one-sample spikes when their body lags their camera in a fast
        -- turn made the head twitch.
        if s and s.look_yaw then
            local now_l = os.clock()
            local dt_l = math.min(0.1, now_l - (look.t or now_l))
            look.t = now_l
            local k = (look.yaw == nil) and 1 or (1 - math.exp(-dt_l / LOOK_TAU))
            look.yaw = (look.yaw or s.look_yaw) + (s.look_yaw - (look.yaw or s.look_yaw)) * k
            look.pitch = (look.pitch or s.look_pitch) + (s.look_pitch - (look.pitch or s.look_pitch)) * k
        end
        anim.flags = s and s.flags or nil
        if s then
            pcall(dtr.call, dtr, "set_Position", s.pos)
            -- Ease the body toward the incoming facing (time constant TURN_TAU) so
            -- turns read as turns instead of snapping.
            local now_t = os.clock()
            local dt = math.min(0.1, now_t - (anim.turn_t or now_t))
            anim.turn_t = now_t
            local tq = { x = s.rot.x, y = s.rot.y, z = s.rot.z, w = s.rot.w }
            local cq = anim.body_q or tq
            local dot = cq.x * tq.x + cq.y * tq.y + cq.z * tq.z + cq.w * tq.w
            if dot < 0 then tq = { x = -tq.x, y = -tq.y, z = -tq.z, w = -tq.w } end
            local a = 1 - math.exp(-dt / TURN_TAU)
            local q = { x = cq.x + (tq.x - cq.x) * a, y = cq.y + (tq.y - cq.y) * a,
                z = cq.z + (tq.z - cq.z) * a, w = cq.w + (tq.w - cq.w) * a }
            local len = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
            if len < 1e-6 then q, len = tq, 1 end
            q = { x = q.x / len, y = q.y / len, z = q.z / len, w = q.w / len }
            anim.body_q = q
            local rq = Quaternion.new(q.w, q.x, q.y, q.z)
            pcall(dtr.call, dtr, "set_Rotation", rq)
            anchor_rot = rq
        end
    end
    local anchor = safe(dtr.call, dtr, "get_Position")
    anchor_rot = anchor_rot or safe(dtr.call, dtr, "get_Rotation")
    pcall(poll_clips)
    pcall(verify_playback)
    local aok, aerr = pcall(auto_animate, anchor, anchor_rot)
    if aok then
        local cok, cerr = pcall(ghost_action)
        if not cok and not anim.action_err then anim.action_err = true log("action ERR " .. tostring(cerr)) end
    end
    if not aok and not anim.auto_err then anim.auto_err = true log("auto ERR " .. tostring(aerr)) end

    local diag_player = get_player()   -- nil while a chapter loads
    if parts_frames % 120 == 0 and anchor and diag_player then
        local pp = diag_player:call("get_Transform"):call("get_Position")
        local dx, dz = anchor.x - pp.x, anchor.z - pp.z
        local plines = {}
        for _, part in ipairs(parts) do
            local p = safe(function() return part.go:call("get_Transform"):call("get_Position") end)
            plines[#plines + 1] = string.format("  %s: %s", part.path:match("([^/]+)%.mesh$") or "?",
                p and string.format("%.3f %.3f %.3f", p.x, p.y, p.z) or "?")
        end
        fs.write("coop_follow_state.txt", string.format(
            "follow=%s\nanchor: %.3f %.3f %.3f\nplayer: %.3f %.3f %.3f\ngap: %.2f m\nhistory: %d samples\nparts:\n%s",
            tostring(follow), anchor.x, anchor.y, anchor.z, pp.x, pp.y, pp.z,
            math.sqrt(dx * dx + dz * dz), #history, table.concat(plines, "\n")))
    end
    for _, part in ipairs(parts) do
        if part.state == "new" and parts_frames > 90 then
            local ok, err = pcall(function()
                part.go:call("set_DrawSelf", true)
                part.go:call("set_UpdateSelf", true)
                local mesh = part.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                mesh:call("setMesh", part.holder)
                mesh:call("set_Material", part.mholder)
                mesh:call("set_Enabled", false)
                mesh:call("set_Enabled", true)
                -- Ethan's Shadow* meshes are shadow-only in the source; RE Engine skips
                -- animating skeletons it thinks are invisible, which froze the ghost.
                -- Force normal drawing on every piece.
                local src_dd = part.src and safe(part.src.call, part.src, "get_DrawDefault")
                local src_sc = part.src and safe(part.src.call, part.src, "get_DrawShadowCast")
                mesh:call("set_DrawDefault", true)
                mesh:call("set_DrawShadowCast", true)
                log(string.format("  %s: source DrawDefault=%s DrawShadowCast=%s -> forced DrawDefault=true",
                    part.path:match("([^/]+)%.mesh$") or "?", tostring(src_dd), tostring(src_sc)))
                part.mesh = mesh
                apply_mask(part)
                -- Mirror the source hierarchy: non-root pieces (heads) are children of
                -- the body and borrow its joints, or they collapse to the origin.
                if not part.is_root then
                    local root_part = nil
                    for _, q in ipairs(parts) do if q.is_root then root_part = q end end
                    if root_part then
                        local ptr = part.go:call("get_Transform")
                        ptr:call("set_Parent", root_part.go:call("get_Transform"))
                        -- set_Parent keeps the old world coords as local ones; reset them.
                        ptr:call("set_LocalPosition", Vector3f.new(0, 0, 0))
                        ptr:call("set_LocalRotation", Quaternion.new(1, 0, 0, 0))
                        if part.same_joints ~= nil then ptr:call("set_SameJointsConstraint", part.same_joints) end
                        if part.parent_joint and part.parent_joint ~= "" then ptr:call("set_ParentJoint", part.parent_joint) end
                        part.parented = true
                    end
                end
            end)
            part.state = ok and "shown" or "failed"
            log("  part " .. part.path .. ": " .. (ok and "shown" or ("ERR " .. tostring(err))))
            part.vars_at = parts_frames + 30
            part.alt_check_at = part.alts and parts_frames + 60 or nil
            if ok and part.is_root then
                local aok, aerr = pcall(setup_animation, part)
                if not aok then log("animation setup ERR " .. tostring(aerr)) end
            end
        end
        -- Pieces with guessed file names (Joe's hands): a file that doesn't exist loads as a
        -- mesh with no materials, so check after a second and try the next guess.
        if part.state == "shown" and part.alt_check_at and parts_frames >= part.alt_check_at then
            part.alt_check_at = nil
            local nm = tonumber(safe(part.mesh.call, part.mesh, "get_MaterialNum") or 0) or 0
            if nm > 0 then
                log("  guessed piece found: " .. part.path)
            else
                part.alt_i = (part.alt_i or 0) + 1
                local nxt = part.alts[part.alt_i]
                if nxt and load_holders_global then
                    local hok, h, mh = pcall(load_holders_global, nxt)
                    if hok and h and mh then
                        part.path = nxt .. ".mesh"
                        pcall(part.mesh.call, part.mesh, "setMesh", h)
                        pcall(part.mesh.call, part.mesh, "set_Material", mh)
                        pcall(part.mesh.call, part.mesh, "set_Enabled", false)
                        pcall(part.mesh.call, part.mesh, "set_Enabled", true)
                        part.alt_check_at = parts_frames + 60
                        log("  trying " .. nxt)
                    end
                else
                    log("  no guess worked for " .. part.path .. "; piece left empty")
                end
            end
        end
        -- Material instances exist only after the mesh is enabled; copy a bit later.
        if part.state == "shown" and part.vars_at and parts_frames >= part.vars_at then
            part.vars_at = nil
            pcall(copy_material_vars, part.src, part.mesh, part.path:match("([^/]+)%.mesh$") or part.path)
        end
        if anchor and not part.parented then
            local okp, perr = pcall(function()
                local ptr = part.go:call("get_Transform")
                local aq = anchor_rot and { x = anchor_rot.x, y = anchor_rot.y, z = anchor_rot.z, w = anchor_rot.w }
                    or { x = 0, y = 0, z = 0, w = 1 }
                local o = part.off and qrot(aq, part.off) or { x = 0, y = 0, z = 0 }
                -- Per-character height fix (Zoe's model stands lower than Ethan's).
                local lift = lobby and character_by_key(lobby.friend_look).lift or 0
                ptr:call("set_Position", Vector3f.new(anchor.x + o.x, anchor.y + o.y + lift, anchor.z + o.z))
                local r = part.lrot and qmul(aq, part.lrot) or aq
                ptr:call("set_Rotation", Quaternion.new(r.w, r.x, r.y, r.z))
                if not part.rot_checked then
                    part.rot_checked = true
                    local b = ptr:call("get_Rotation")
                    log(string.format("  rot check %s: wanted xyzw %.3f %.3f %.3f %.3f, got %.3f %.3f %.3f %.3f",
                        part.path:match("([^/]+)%.mesh$") or "?", r.x, r.y, r.z, r.w, b.x, b.y, b.z, b.w))
                end
            end)
            if not okp and not part.follow_err then
                part.follow_err = true
                log("  follow update ERR " .. (part.path:match("([^/]+)%.mesh$") or "?") .. ": " .. tostring(perr))
            end
        end
    end
end)
local current = "pl0001 (Ethan first-person, original)"

local function set_motion_enabled(on)
    local m = dummy and safe(dummy.call, dummy, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    if m then safe(m.call, m, "set_Enabled", on) end
end

-- Settings shared with coop_saveguard.lua (reframework/data/coop_settings.json).
settings = { allow_saving = false, hud = true, nameplate = true, footsteps = true }
do
    local ok, s = pcall(json.load_file, "coop_settings.json")
    if ok and type(s) == "table" then for k, v in pairs(s) do settings[k] = v end end
end
function save_settings()
    local ok, err = pcall(json.dump_file, "coop_settings.json", settings)
    if not ok then log("settings save ERR " .. tostring(err)) end
end

-- Connect panel: no config editing. Writes a one-line command that CoopNet.cs
-- applies live ("steam <SteamID64>" or "bot") and saves for next launch.
connect_ui = { friend = "", opened = false }

local function send_command(cmd)
    fs.write("coopnet_command.txt", cmd)
    log("connect: sent command '" .. cmd .. "'")
end

local function connection_text()
    local kv = net.kv or {}
    local last = net.history[#net.history]
    local fresh = last ~= nil and (os.clock() - last.t) < (NET_TIMEOUT or 2)
    if kv.mode == "bot" then return "Bot test (no friend connected)" end
    if kv.mode == "steam" then
        if kv.peer == nil or kv.peer == "steam:0" then return "Not connected: pick a friend below" end
        if fresh then return "Connected to your friend" end
        return "Waiting for your friend (they need to Accept, or click Connect on you)"
    end
    return "Mode: " .. tostring(kv.mode)
end

-- Steam friends list (CoopNet writes coopnet_friends.txt every 2 s). Friends running
-- RE7 Co-op show a Connect button; connecting also shows up on their side as an invite
-- (Steam rich presence), which they accept with one click.
friends = { list = {}, t = -100, show_all = false, dismissed = {} }

function read_friends()
    if os.clock() - friends.t < 2 or fs.read == nil then return end
    friends.t = os.clock()
    local text = fs.read("coopnet_friends.txt")
    if text == nil then return end
    local list = {}
    for line in text:gmatch("[^\r\n]+") do
        local id, flags, ver, name = line:match("^(%d+)\t(%S+)\t(%S+)\t(.*)$")
        if id then
            list[#list + 1] = { id = id, name = name, version = ver ~= "-" and ver or nil,
                in_re7 = flags:find("R") ~= nil, coop = flags:find("C") ~= nil, invites = flags:find("I") ~= nil }
        end
    end
    -- Invites first, then co-op running, then RE7, then everyone else; by name inside each.
    local function rank(f) return f.invites and 0 or f.coop and 1 or f.in_re7 and 2 or 3 end
    table.sort(list, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return a.name:lower() < b.name:lower()
    end)
    friends.list = list
end

local function current_peer_id()
    local kv = net.kv or {}
    return kv.mode == "steam" and kv.peer and kv.peer:match("^steam:(%d+)$") or nil
end

-- A friend who is inviting us and isn't who we're already connected to.
function pending_invite()
    local peer = current_peer_id()
    for _, f in ipairs(friends.list) do
        if f.invites and f.id ~= peer and not friends.dismissed[f.id] then return f end
    end
    return nil
end

-- The chapter list needs GameManager; retry at most every 5 s while it's empty.
function ensure_chapter_list()
    if chapters.list and #chapters.list > 0 then return end
    if chapters.list_t and os.clock() - chapters.list_t < 5 then return end
    chapters.list_t = os.clock()
    chapters.list = list_chapter_jumps()
end

function chapter_name(v)
    if v == nil then return "?" end
    ensure_chapter_list()
    for _, e in ipairs(chapters.list) do if e.value == v then return e.name end end
    return tostring(v)
end

local function connect_to(f)
    send_command("steam " .. f.id)
    friends.dismissed[f.id] = nil
end

local function friend_row(f, i)
    local peer = current_peer_id()
    local label = f.name
    if f.id == peer then
        label = label .. "  (connected)"
    elseif f.coop then
        label = label .. "  (RE7 Co-op " .. tostring(f.version) .. ")"
    elseif f.in_re7 then
        label = label .. "  (in RE7, co-op not running)"
    end
    if f.coop and f.version and net.kv and net.kv.version and f.version ~= net.kv.version then
        label = label .. "  - different version, update both to the same"
    end
    if f.id ~= peer then
        if imgui.button((f.invites and "Accept" or "Connect") .. "##fr" .. i) then connect_to(f) end
        imgui.same_line()
    end
    imgui.text(label)
end

local function draw_friend_list()
    read_friends()
    local inv = pending_invite()
    if inv then
        local msg = inv.name .. " wants to play co-op with you."
        if imgui.text_colored then imgui.text_colored(msg, 0xFF7FFF8C) else imgui.text(msg) end
        if imgui.button("Accept##invite") then connect_to(inv) end
        imgui.same_line()
        if imgui.button("Not now##invite") then friends.dismissed[inv.id] = true end
    end
    imgui.text("Your Steam friends in RE7 Co-op:")
    local shown = 0
    for i, f in ipairs(friends.list) do
        if f.coop or friends.show_all or f.id == current_peer_id() then
            friend_row(f, i)
            shown = shown + 1
        end
    end
    if shown == 0 then
        imgui.text("  Nobody yet. Your friend needs to start RE7 Co-op too; they'll appear here.")
    end
    local c, v = imgui.checkbox("Show all online friends", friends.show_all)
    if c then friends.show_all = v end
    if friends.show_all then
        imgui.text("Connecting to a friend who isn't running RE7 Co-op yet invites them for when they start it.")
    end
end

local function draw_steamid_connect()
    local kv = net.kv or {}
    local me = kv.steamSelf
    if me and me ~= "0" then
        imgui.text("Your SteamID: " .. me)
        imgui.same_line()
        if imgui.button("Copy##myid") then sdk.copy_to_clipboard(me) log("connect: copied own SteamID") end
    else
        imgui.text("Your SteamID: (Steam not ready yet)")
    end
    local changed, v = imgui.input_text("Friend's SteamID", connect_ui.friend)
    if changed then connect_ui.friend = v:gsub("%s", "") end
    local valid = connect_ui.friend:match("^7656119%d%d%d%d%d%d%d%d%d%d$") ~= nil
    if imgui.button("Connect to friend") then
        if valid then send_command("steam " .. connect_ui.friend)
        else log("connect: not a SteamID64 (17 digits starting 7656119)") end
    end
    if connect_ui.friend ~= "" and not valid then imgui.text("That doesn't look like a SteamID64 (17 digits starting 7656119).") end
end

-- Join friend: jump to the friend's chapter. No automatic teleport afterwards: with
-- the bot (whose positions aren't real ground) it landed outside the map, and RE7
-- streams areas in, so warping across a chapter can land somewhere not loaded yet.
-- "Teleport to my friend" stays a manual button for when you're close.
join = { msg = "-" }

function join_friend()
    local last = net.history[#net.history]
    local fresh = last ~= nil and (os.clock() - last.t) < (NET_TIMEOUT or 2)
    if not fresh or net.peer_chapter == nil then join.msg = "no friend connected" return end
    if net.peer_chapter == local_chapter() then join.msg = "you're already in the same chapter" return end
    chapters.list_t = nil
    ensure_chapter_list()
    local target
    for _, e in ipairs(chapters.list) do if e.value == net.peer_chapter then target = e end end
    if target == nil then join.msg = "can't jump to the friend's chapter (" .. tostring(net.peer_chapter) .. ")" return end
    local busy = jump_busy()
    if busy then join.msg = "not yet: " .. busy return end
    jump_to_chapter(target)
    join.msg = "going to " .. target.name .. " (start of the chapter)"
    log("join: " .. join.msg)
end

-- Following into VHS tapes. Each tape is a chapter of its own (FF000, FF030, FF040,
-- FF050 = ChapterNo 7, 10, 11, 12), so whoever puts a tape in is alone in it (2026-11-02).
-- When the friend goes from our chapter into a tape, jump after them once we're in control.
-- Never out of a tape: a jump lands at a chapter's start, which would undo where we were;
-- the tape ends and returns us the normal way.
TAPE_CHAPTERS = { [7] = true, [10] = true, [11] = true, [12] = true }
local follow = { was_together = false, want_t = nil, done_for = nil }
re.on_frame(function()
    local now = os.clock()
    if now - (follow.check_t or 0) < 1 then return end
    follow.check_t = now
    local last = net.history[#net.history]
    local fresh = last ~= nil and (now - last.t) < (NET_TIMEOUT or 2)
    local mine, theirs = local_chapter(), net.peer_chapter
    if not fresh or theirs == nil or mine == nil then follow.want_t = nil return end
    if theirs == mine then follow.was_together, follow.want_t, follow.done_for = true, nil, nil return end
    if settings and settings.follow_tapes == false then return end
    if not (follow.was_together and TAPE_CHAPTERS[theirs] and not TAPE_CHAPTERS[mine]) then return end
    if follow.done_for == theirs then return end
    if local_cutscene() then follow.want_t = nil return end
    follow.want_t = follow.want_t or now
    if now - follow.want_t < 4 then return end
    follow.done_for = theirs
    log("follow: friend went into tape chapter " .. chapter_name(theirs) .. "; following")
    join_friend()
end)

re.on_frame(function()
    read_friends()   -- also feeds the on-screen invite line
end)

local function draw_connect_body()
    local kv = net.kv or {}
    imgui.text("Status: " .. connection_text())
    draw_friend_list()
    local last = net.history[#net.history]
    if (kv.mode == "steam" or kv.mode == "bot") and last ~= nil and (os.clock() - last.t) < (NET_TIMEOUT or 2) then
        imgui.text("Friend's chapter: " .. chapter_name(net.peer_chapter) .. "   yours: " .. chapter_name(local_chapter()))
        if imgui.button("Go to my friend's chapter") then join_friend() end
        imgui.same_line()
        imgui.text(join.msg)
    end
    if imgui.tree_node("Connect with a SteamID instead") then
        local ok, err = pcall(draw_steamid_connect)
        imgui.tree_pop()
        if not ok then imgui.text("error: " .. tostring(err)) end
    end
    if imgui.button("Test with bot") then send_command("bot") end
    if kv.mode == "bot" then
        imgui.same_line()
        imgui.text("(the bot is on: it walks around you)")
    end
    if kv.lastCommand and kv.lastCommand ~= "-" then imgui.text("Last change: " .. kv.lastCommand) end

    if imgui.separator then imgui.separator() end
    -- Saving: off by default. On: the game saves normally; CoopNet backs the save
    -- folder up now and at every launch (Steam Cloud shares saves with the real install).
    local schanged, sv = imgui.checkbox("Allow saving (your saves are backed up automatically)", settings.allow_saving)
    if schanged then
        settings.allow_saving = sv
        save_settings()
        if sv then send_command("backup allow") end
        log("settings: allow_saving = " .. tostring(sv))
    end
    if settings.allow_saving then
        imgui.text("Saving is ON. Steam Cloud shares these saves with your normal RE7 install.")
    else
        imgui.text("Saving is OFF: progress made in this session will not be kept.")
    end
    imgui.text("Last save backup: " .. tostring(kv.lastBackup or "-") .. " (" .. tostring(kv.backups or 0) .. " kept)")
    if imgui.button("Back up saves now") then send_command("backup manual") end
    imgui.same_line()
    -- CoopNet copies the co-op logs (SteamIDs, names and user name blanked) into a zip on
    -- the desktop; the result shows on the "Last change" line.
    if imgui.button("Make a bug report (zip on your desktop)") then send_command("report") end

    if imgui.separator then imgui.separator() end
    local hchanged, hv = imgui.checkbox("On-screen status", settings.hud)
    if hchanged then settings.hud = hv save_settings() end
    imgui.same_line()
    local nchanged, nv = imgui.checkbox("Nameplate over your friend", settings.nameplate)
    if nchanged then settings.nameplate = nv save_settings() end
    imgui.same_line()
    local fchanged, fv = imgui.checkbox("Friend's footsteps", settings.footsteps ~= false)
    if fchanged then settings.footsteps = fv save_settings() end
    -- Story cutscenes and progress follow whichever player reaches them first.
    local sc, sv = imgui.checkbox("Share story (cutscenes and progress, experimental)", settings.share_story == true)
    if sc then settings.share_story = sv save_settings() end
    local wc, wv = imgui.checkbox("Show your friend's weapon (experimental)", settings.show_weapon ~= false)
    if wc then settings.show_weapon = wv save_settings() pcall(show_friend_weapon_again) end
    local tc, tv = imgui.checkbox("Follow my friend into VHS tapes", settings.follow_tapes ~= false)
    if tc then settings.follow_tapes = tv save_settings() end
    local ic, iv = imgui.checkbox("Share interactions (fridge, van, switches; experimental)", settings.share_interactions ~= false)
    if ic then settings.share_interactions = iv save_settings() end
    local pc, pv = imgui.checkbox("Share pushed objects (chairs, bottles; experimental)", settings.share_physics ~= false)
    if pc then settings.share_physics = pv save_settings() end
    if imgui.button("Teleport to my friend") then teleport_to_friend() end
end

-- Chapter switcher (testing) ---------------------------------------------------------
-- RE7's own chapter jump: app.GameManager.getChapterJumpDataKey(ChapterNo) names the
-- jump target, chapterJumpRequest(name, hideLoadingUI, closeName) goes there. A debug
-- jump can leave story flags oddly set, so it is refused while saving is allowed.
chapters = { list = nil, last = "-" }

function list_chapter_jumps()
    local gm = sdk.get_managed_singleton("app.GameManager")
    local td = sdk.find_type_definition("app.GameManager.ChapterNo")
    local out = {}
    if gm == nil or td == nil then chapters.last = "GameManager not ready" return out end
    for _, f in ipairs(td:get_fields() or {}) do
        if f:is_static() then
            local value = safe(f.get_data, f, nil)
            local key = value ~= nil and safe(gm.call, gm, "getChapterJumpDataKey", value)
            if key and tostring(key) ~= "" then
                out[#out + 1] = { name = f:get_name(), value = value, key = tostring(key) }
            end
        end
    end
    log("chapters: " .. #out .. " jump targets")
    if not chapters.dumped then
        chapters.dumped = true
        for _, e in ipairs(out) do log(string.format("  chapter %s = %s -> %s", e.name, tostring(e.value), e.key)) end
    end
    return out
end

-- One jump at a time: back-to-back requests while a jump is still loading (21:02,
-- seven jumps in 50 s) left the game's chapter flow half-switched (cutscenes heard
-- but not shown, player outside the map). Refuse until the last jump has finished
-- and the player has been back in control for a while.
JUMP_SETTLE = 10   -- s of control after a jump before another is allowed

function jump_busy()
    local gm = sdk.get_managed_singleton("app.GameManager")
    if gm and safe(gm.get_field, gm, "RequestChapterJump") then return "a chapter jump is still loading" end
    if chapters.jump_t and (respawn_t == nil or respawn_t < chapters.jump_t) and os.clock() - chapters.jump_t < 120 then
        return "waiting for the last jump to finish loading"
    end
    if respawn_t and os.clock() - respawn_t < JUMP_SETTLE and chapters.jump_t then
        return string.format("let the chapter settle (%d s)", math.ceil(JUMP_SETTLE - (os.clock() - respawn_t)))
    end
    return nil
end

function jump_to_chapter(e)
    local busy = jump_busy()
    if busy then
        chapters.last = "not yet: " .. busy
        log("chapters: refused " .. e.name .. " (" .. busy .. ")")
        return
    end
    if settings.allow_saving then
        -- A test jump must never be saved over a real save: switch saving off, give
        -- coop_saveguard (re-reads every 2 s) time to see it, then jump.
        settings.allow_saving = false
        save_settings()
        chapters.pending, chapters.pending_t = e, os.clock() + 2.5
        chapters.last = "saving switched OFF for the test jump; jumping to " .. e.name .. " in 2 s"
        log("chapters: " .. chapters.last)
        return
    end
    local gm = sdk.get_managed_singleton("app.GameManager")
    local ok, err = pcall(gm.call, gm, "chapterJumpRequest(System.String, System.Boolean, System.String)", e.key, false, "")
    if ok then chapters.jump_t = os.clock() end
    chapters.last = ok and ("jumping to " .. e.name .. " (" .. e.key .. ")") or ("ERR " .. tostring(err))
    log("chapters: " .. chapters.last)
end

re.on_frame(function()
    if chapters.pending and os.clock() >= chapters.pending_t then
        local e = chapters.pending
        chapters.pending = nil
        jump_to_chapter(e)
    end
end)

local function draw_chapter_switcher()
    if chapters.list == nil or imgui.button("Refresh chapter list") then chapters.list = list_chapter_jumps() end
    if settings.allow_saving then
        if imgui.text_colored then
            imgui.text_colored("Saving is ON: choosing a chapter switches saving OFF first.", 0xFF6B6BFF)
        else
            imgui.text("!! Saving is ON: choosing a chapter switches saving OFF first.")
        end
    end
    imgui.text("Jump straight to a chapter (testing only; nothing is saved):")
    for i, e in ipairs(chapters.list) do
        if imgui.button(e.name .. "##ch" .. i) then jump_to_chapter(e) end
        if i % 4 ~= 0 and i < #chapters.list then imgui.same_line() end
    end
    if #chapters.list == 0 then imgui.text("(no jump targets reported yet; load into the game and Refresh)") end
    imgui.text("Current chapter: " .. tostring(local_chapter()) .. "   Last: " .. chapters.last)
end

-- Lobby: who's here and how each player looks to the other -------------------------
-- Every playable character in RE7 has the same set of pieces RE7 draws only for the
-- player's shadow, on Ethan's skeleton (so Ethan's animations fit them all):
--   ShadowBody plXX01, ShadowLowerBody plXX02, ShadowHead plXX50, ShadowHandL/R.
-- In the plain game those pieces are incomplete (the heads have no real face: Mia's
-- came out black, 2026-11-02). The Nexus mod "Third Person Full Model Placeholders"
-- (RE7 mod 86, loose files) replaces them with complete models under the same paths,
-- so with it installed the same choice shows a full character; CoopNet reports it as
-- fullModels=1. Its file list gave the DLC paths: Chris ch8 pl1000, Joe ch9 pl9000,
-- Zoe pl3400, Clancy (DLC) pl3100.
-- "Default" is whoever the friend is playing right now. Your pick goes to the friend
-- as "look <key>" and is re-sent every 15 s.
-- Pieces are keyed by the Shadow* owner they replace; mdf defaults to the mesh path.
local P = "Character/Player/"
CHARACTERS = {
    { key = "default", name = "Default (who you're playing)" },
    { key = "ethan", name = "Ethan", pieces = {
        ShadowBody = { mesh = P .. "pl0000/pl0001/pl0001" },
        ShadowLowerBody = { mesh = P .. "pl0000/pl0002/pl0002" },
        ShadowHead = { mesh = P .. "pl0000/pl0050/pl0050" },
        ShadowHandL = { mesh = P .. "pl0000/pl0000/pl0021" },
        ShadowHandR = { mesh = P .. "pl0000/pl0000/pl0010" } } },
    -- pl0051 is the head RE7 uses in a few events (Pl0000Head); may show his face.
    { key = "ethan_face", name = "Ethan (event head)", pieces = {
        ShadowBody = { mesh = P .. "pl0000/pl0001/pl0001" },
        ShadowLowerBody = { mesh = P .. "pl0000/pl0002/pl0002" },
        ShadowHead = { mesh = P .. "pl0000/pl0051/pl0051" },
        ShadowHandL = { mesh = P .. "pl0000/pl0000/pl0021" },
        ShadowHandR = { mesh = P .. "pl0000/pl0000/pl0010" } } },
    { key = "mia", name = "Mia", pieces = {
        ShadowBody = { mesh = P .. "pl2000/pl2001/pl2001" },
        ShadowLowerBody = { mesh = P .. "pl2000/pl2002/pl2002" },
        ShadowHead = { mesh = P .. "pl2000/pl2050/pl2050" },
        ShadowHandL = { mesh = P .. "pl2000/pl2000/pl2020", mdf = P .. "pl2000/pl2000/pl2020_light" },
        ShadowHandR = { mesh = P .. "pl2000/pl2000/pl2010", mdf = P .. "pl2000/pl2000/pl2010_light" },
        -- The mod lays Mia out its own way (pl2001 clothes, pl2002 head, pl2020 hair) and
        -- ships pl2023 too; without it her chest and left hand were missing.
        ShadowExtra = { mesh = P .. "pl2000/pl2023/pl2023", full_only = true } } },
    { key = "mia_ship", name = "Mia (ship)", pieces = {
        ShadowBody = { mesh = P .. "pl2100/pl2101/pl2101" },
        ShadowLowerBody = { mesh = P .. "pl2100/pl2102/pl2102" },
        ShadowHead = { mesh = P .. "pl2100/pl2150/pl2150" },
        ShadowHandL = { mesh = P .. "pl2100/pl2100/pl2120" },
        ShadowHandR = { mesh = P .. "pl2100/pl2100/pl2110" } } },
    { key = "clancy", name = "Clancy", pieces = {
        ShadowBody = { mesh = P .. "pl3000/pl3001/pl3001" },
        ShadowLowerBody = { mesh = P .. "pl3000/pl3002/pl3002" },
        ShadowHead = { mesh = P .. "pl3000/pl3050/pl3050" },
        ShadowHandL = { mesh = P .. "pl3000/pl3000/pl3020", mdf = P .. "pl3000/pl3000/em3020" },
        ShadowHandR = { mesh = P .. "pl3000/pl3000/pl3010", mdf = P .. "pl3000/pl3000/em3010" } } },
    -- Below: paths from the full-model mod's file list, not yet seen loaded in this game.
    { key = "zoe", name = "Zoe", lift = 0.04, pieces = {
        ShadowBody = { mesh = P .. "pl3400/pl3401/pl3401" },
        ShadowLowerBody = { mesh = P .. "pl3400/pl3402/pl3402" },
        ShadowHead = { mesh = P .. "pl3400/pl3450/pl3450" },
        ShadowHandL = { mesh = P .. "pl3400/pl3400/pl3420" },
        ShadowHandR = { mesh = P .. "pl3400/pl3400/pl3410" } } },
    -- Chris's and Joe's hands and Chris's head follow the plXX10 / plXX20 / plXX50 pattern
    -- of the others; not in the mod's list, so unconfirmed.
    { key = "chris", name = "Chris (DLC)", pieces = {
        ShadowBody = { mesh = "ch8/" .. P .. "pl1000/pl1001/pl1001" },
        ShadowLowerBody = { mesh = "ch8/" .. P .. "pl1000/pl1002/pl1002" },
        ShadowHead = { mesh = "ch8/" .. P .. "pl1000/pl1050/pl1050" },
        ShadowHandL = { mesh = "ch8/" .. P .. "pl1000/pl1000/pl1020" },
        ShadowHandR = { mesh = "ch8/" .. P .. "pl1000/pl1000/pl1010" } } },
    -- Joe: the game's own files animate; the mod's stood in a T-pose, so he's left out of
    -- MODDED. His hands aren't at pl9000/pl9010 (loads empty); these are guesses, tried in
    -- order until one loads with materials.
    { key = "joe", name = "Joe (DLC)", pieces = {
        ShadowBody = { mesh = "ch9/" .. P .. "pl9000/pl9001/pl9001" },
        ShadowLowerBody = { mesh = "ch9/" .. P .. "pl9000/pl9002/pl9002" },
        ShadowHead = { mesh = "ch9/" .. P .. "pl9000/pl9050/pl9050" },
        ShadowHandR = { mesh = "ch9/" .. P .. "pl9000/pl9010/pl9010", alts = {
            "ch9/" .. P .. "pl9000/pl9000/pl9011", "ch9/" .. P .. "pl9000/pl9003/pl9003",
            "ch9/" .. P .. "pl9000/pl9000/pl9030", "ch9/" .. P .. "pl9000/pl9030/pl9030" } },
        ShadowHandL = { mesh = "ch9/" .. P .. "pl9000/pl9020/pl9020", alts = {
            "ch9/" .. P .. "pl9000/pl9000/pl9021", "ch9/" .. P .. "pl9000/pl9004/pl9004",
            "ch9/" .. P .. "pl9000/pl9000/pl9040", "ch9/" .. P .. "pl9000/pl9040/pl9040" } } } },
}
lobby = { friend_look = "default", sent_t = -100, sent_look = nil }

-- Files the full-model mod provides. "Use full models.cmd" moves them to natives\stm\coop\
-- (so the player's own first-person body stays the game's: with the mod's, the camera sat
-- inside Ethan's head), and its bodies already include the head (the game's shadow head
-- on top showed black on Mia and off-place on Zoe).
local MODDED = {}
for _, p in ipairs({ "pl0000/pl0001/pl0001", "pl0000/pl0002/pl0002",
        "pl2000/pl2001/pl2001", "pl2000/pl2002/pl2002", "pl2000/pl2000/pl2020",
        "pl2100/pl2101/pl2101", "pl2100/pl2102/pl2102", "pl2100/pl2100/pl2110", "pl2100/pl2100/pl2120",
        "pl3000/pl3001/pl3001", "pl3000/pl3002/pl3002", "pl3100/pl3101/pl3101", "pl3100/pl3102/pl3102",
        "pl3400/pl3401/pl3401", "pl3400/pl3402/pl3402", "pl3400/pl3400/pl3410", "pl3400/pl3400/pl3420" }) do
    MODDED[P .. p] = true
end
MODDED["ch8/" .. P .. "pl1000/pl1001/pl1001"], MODDED["ch8/" .. P .. "pl1000/pl1002/pl1002"] = true, true
MODDED[P .. "pl2000/pl2023/pl2023"] = true

local function full_models() return net.kv ~= nil and net.kv.fullModels == "1" end

function character_by_key(key)
    for _, c in ipairs(CHARACTERS) do if c.key == key then return c end end
    return CHARACTERS[1]
end

local function load_holders(mesh, mdf)
    local r = sdk.create_resource("via.render.MeshResource", mesh .. ".mesh")
    r:add_ref()
    local h = r:create_holder("via.render.MeshResourceHolder")
    h:add_ref()
    local mr = sdk.create_resource("via.render.MeshMaterialResource", (mdf or mesh) .. ".mdf2")
    mr:add_ref()
    local mh = mr:create_holder("via.render.MeshMaterialResourceHolder")
    mh:add_ref()
    return h, mh
end

load_holders_global = load_holders   -- for the guessed-piece retries in the parts loop

-- Called by assemble_from with the local player's Shadow* pieces: dress them as the
-- friend's chosen character. Each piece the character has replaces the local piece of
-- the same name (a piece the local player lacks is added, borrowing the body's
-- skeleton like the head does); local pieces the character doesn't have are dropped.
function dress_as_friend_choice(shadow)
    local c = character_by_key(lobby.friend_look)
    if c.pieces == nil then lobby.dressed_full = nil return shadow end
    local by_owner, template = {}, nil
    for _, e in ipairs(shadow) do
        by_owner[e.owner] = e
        if not e.is_root and template == nil then template = e end
    end
    if by_owner.ShadowBody == nil then log("lobby: no ShadowBody to dress; keeping the default") return shadow end
    local out = {}
    local full = full_models() and c.pieces.ShadowBody and MODDED[c.pieces.ShadowBody.mesh]
    for _, owner in ipairs({ "ShadowBody", "ShadowLowerBody", "ShadowHead", "ShadowHandL", "ShadowHandR", "ShadowExtra" }) do
        local pc = c.pieces[owner]
        if full and owner == "ShadowHead" then pc = nil end   -- the full body has its head
        if pc and pc.full_only and not full then pc = nil end
        if pc and full_models() and MODDED[pc.mesh] then
            pc = { mesh = "coop/" .. pc.mesh }                 -- the mod's file, with its own material
        end
        if pc then
            local e = by_owner[owner]
            if e == nil then
                local t = template or by_owner.ShadowBody
                e = { owner = owner, go = t.go, mask = t.mask, mask_n = t.mask_n, is_root = false,
                    same_joints = true, parent_joint = nil }
            end
            local ok, h, mh = pcall(load_holders, pc.mesh, pc.mdf)
            if ok and h and mh then
                e.holder, e.mholder, e.path = h, mh, pc.mesh .. ".mesh"
                e.alts = pc.alts
                e.src = nil   -- the material variables to copy belong to the local character
                -- ...and so does the parts on/off pattern: Ethan's (parts 1, 10, 11 off) hid
                -- Mia's eyes and chest and Zoe's feet. A dressed piece shows all its parts.
                e.mask, e.mask_n = {}, 0
                out[#out + 1] = e
            else
                log("lobby: couldn't load " .. pc.mesh .. ": " .. tostring(h))
            end
        end
    end
    if #out == 0 or out[1].owner ~= "ShadowBody" then
        log("lobby: " .. c.name .. " has no body that loads; keeping the default")
        return shadow
    end
    lobby.dressed_full = full_models()
    log(string.format("lobby: friend dressed as %s (%d pieces, full-model mod %s)", c.name, #out,
        (net.kv and net.kv.fullModels == "1") and "installed" or "not installed"))
    return out
end

local function send_look()
    if coop_send_event == nil then return end
    lobby.sent_look = settings.look or "default"
    lobby.sent_t = os.clock()
    coop_send_event("look " .. lobby.sent_look)
end

-- Incoming "look" (coop_enemies.lua passes every event here first).
-- The friend's weapon in their character's hand. Our side: the drawn weapon model under the
-- player (GameObjects named wpNNNN...) goes out as "weapon <mesh> <mdf>" when it changes, "-"
-- for none. Their side: the same model on a prefab instance hung on the right-hand weapon
-- joint (R_Wep) of the friend's body. Untested (first build, 2026-11-03): "Show your friend's
-- weapon" switches it off.
held = { sent = nil, sent_t = -100, got = nil, part = nil }

local function local_weapon()
    local player = get_player()
    if player == nil then return "-" end
    -- Walk the player's children (no references kept: this runs every second).
    local found = "-"
    local function visit(go, depth)
        if found ~= "-" or depth > 8 then return end
        local name = tostring(safe(go.call, go, "get_Name") or "")
        if name:match("^wp%d%d%d%d") and not name:find("Light") and safe(go.call, go, "get_Draw") then
            local m = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
            local h = m and safe(m.call, m, "getMesh")
            local mh = m and safe(m.call, m, "get_Material")
            local mp = h and safe(h.call, h, "get_ResourcePath")
            local mdf = mh and safe(mh.call, mh, "get_ResourcePath")
            if mp and mdf then
                found = tostring(mp):gsub("%.mesh$", "") .. " " .. tostring(mdf):gsub("%.mdf2$", "")
                held.local_go = go
                return
            end
        end
        local tr = safe(go.call, go, "get_Transform")
        local child = tr and safe(tr.call, tr, "get_Child")
        while child ~= nil and found == "-" do
            local cgo = safe(child.call, child, "get_GameObject")
            if cgo then visit(cgo, depth + 1) end
            child = safe(child.call, child, "get_Next")
        end
    end
    visit(player, 0)
    return found
end

local function drop_held()
    if held.part then
        pcall(function() held.part:call("get_Transform"):call("set_Parent", nil) end)
        pcall(held.part.call, held.part, "set_DrawSelf", false)
        held.part = nil
    end
end

local function show_held()
    drop_held()
    if held.got == nil or held.got == "-" or (settings and settings.show_weapon == false) then return end
    local mesh, mdf = held.got:match("^(%S+) (%S+)$")
    local root
    for _, q in ipairs(parts) do if q.is_root then root = q end end
    if mesh == nil or root == nil or prefab == nil then return end
    local rp = root.go:call("get_Transform"):call("get_Position")
    local go = prefab:call("instantiate(via.vec3)", rp)
    if go == nil then return end
    local h, mh = load_holders(mesh, mdf)
    local m = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    go:call("set_DrawSelf", true)
    go:call("set_UpdateSelf", true)
    m:call("setMesh", h)
    m:call("set_Material", mh)
    m:call("set_DrawDefault", true)
    m:call("set_Enabled", false)
    m:call("set_Enabled", true)
    local tr = go:call("get_Transform")
    tr:call("set_Parent", root.go:call("get_Transform"))
    tr:call("set_SameJointsConstraint", false)
    tr:call("set_ParentJoint", "R_Wep")
    tr:call("set_LocalPosition", Vector3f.new(0, 0, 0))
    tr:call("set_LocalRotation", Quaternion.new(1, 0, 0, 0))
    held.part = go
    log("weapon: friend holds " .. mesh)
end
function show_friend_weapon_again() show_held() end

re.on_frame(function()
    local now = os.clock()
    if now - (held.check_t or 0) < 1 then return end
    held.check_t = now
    local kv = net.kv or {}
    if (kv.mode == "steam" or kv.mode == "bot") and coop_send_event then
        local w = local_weapon()
        if w ~= held.sent or now - held.sent_t > 20 then
            if w ~= held.sent and w ~= "-" and held.local_go then
                -- For weapon sounds later: what the held weapon is made of (logged once per weapon).
                local names = {}
                for _, c in ipairs(safe(function() return held.local_go:call("get_Components"):get_elements() end) or {}) do
                    names[#names + 1] = c:get_type_definition():get_full_name()
                end
                log("weapon: holding " .. w .. "; components: " .. table.concat(names, ", "))
            end
            held.sent, held.sent_t = w, now
            coop_send_event("weapon " .. w)
        end
    end
    -- The friend's body was rebuilt (load, look change): put the weapon back, once per body.
    local root
    for _, q in ipairs(parts) do if q.is_root then root = q.go end end
    if held.got and held.got ~= "-" and root and root ~= held.root_go then
        held.root_go = root
        held.part = nil   -- went with the old body
        pcall(show_held)
    end
end)

function coop_lobby_on_event(text)
    local w = text:match("^weapon (.+)$")
    if w then
        if w ~= held.got then
            held.got = w
            local ok, err = pcall(show_held)
            if not ok then log("weapon ERR " .. tostring(err)) end
        end
        return true
    end
    local key = text:match("^look (%S+)")
    if key == nil then return false end
    if key ~= lobby.friend_look then
        lobby.friend_look = key
        log("lobby: friend picked " .. character_by_key(key).name)
        if #parts > 0 then pcall(build_ethan) end
    end
    return true
end

re.on_frame(function()
    local kv = net.kv or {}
    -- Right after a script reset the status isn't read yet, so a ghost dressed then used the
    -- plain files: redress once we know whether the full models are installed.
    if kv.fullModels ~= nil and lobby.dressed_full ~= nil and lobby.dressed_full ~= full_models()
            and #parts > 0 and os.clock() - (lobby.redress_t or -100) > 5 then
        lobby.redress_t = os.clock()
        log("lobby: full-model state now known; dressing again")
        pcall(build_ethan)
    end
    if kv.mode ~= "steam" and kv.mode ~= "bot" then return end
    local last = net.history[#net.history]
    if last == nil or os.clock() - last.t > 2 then return end
    if lobby.sent_look ~= (settings.look or "default") or os.clock() - lobby.sent_t > 15 then pcall(send_look) end
end)

local function draw_lobby()
    local kv = net.kv or {}
    local last = net.history[#net.history]
    local fresh = last ~= nil and (os.clock() - last.t) < (NET_TIMEOUT or 2)
    local me = (kv.steamName and kv.steamName ~= "") and kv.steamName or "You"
    local friend = (kv.peerName and kv.peerName ~= "") and kv.peerName or "your friend"
    imgui.text("Player 1: " .. me .. " (you), chapter " .. chapter_name(local_chapter()))
    local names, idx = {}, 1
    for i, c in ipairs(CHARACTERS) do
        names[#names + 1] = c.name
        if c.key == (settings.look or "default") then idx = i end
    end
    if kv.fullModels == "1" then
        imgui.text("Full character models: installed (Third Person Full Model Placeholders)")
    elseif kv.fullModels == "off" then
        imgui.text("Full character models: copied in, but REFramework's Loose File Loader is off.")
        imgui.text("  Close the game and double-click \"Use full models.cmd\" (in the coop-re7 download).")
    elseif kv.fullModels == "move" then
        imgui.text("Full character models: copied in but not set up (your own view may show the inside")
        imgui.text("  of the head). Close the game and double-click \"Use full models.cmd\".")
    else
        imgui.text("Full character models: not installed. Without them characters other than Default")
        imgui.text("  may lack a face. Both players can install the Nexus mod")
        imgui.text("  \"Third Person Full Model Placeholders\" (RE7 mod 86) into their co-op folder.")
    end
    local changed, v = imgui.combo("You appear to your friend as", idx, names)
    if changed and CHARACTERS[v] then
        settings.look = CHARACTERS[v].key
        save_settings()
        pcall(send_look)
    end
    if kv.mode == "bot" then
        imgui.text("Player 2: the test bot, appears as " .. character_by_key(lobby.friend_look).name)
    elseif fresh then
        imgui.text("Player 2: " .. friend .. ", chapter " .. chapter_name(net.peer_chapter) ..
            ", appears as " .. character_by_key(lobby.friend_look).name)
        if net.peer_chapter ~= local_chapter() then
            imgui.text("  In another chapter: click Go to my friend's chapter (below) to join them.")
        end
    else
        imgui.text("Player 2: nobody yet. Invite a friend under Connect, saving and display.")
    end
    if fresh and net.peer_chapter ~= local_chapter() and imgui.button("Go to my friend's chapter##lobby") then
        pcall(join_friend)
    end
    -- Test the looks alone: dress the bot as any character.
    if kv.mode == "bot" then
        imgui.text("Dress the bot as:")
        for _, c in ipairs(CHARACTERS) do
            imgui.same_line()
            if imgui.button(c.name .. "##botlook") then coop_lobby_on_event("look " .. c.key) end
        end
    end
end

-- Floating "RE7 Co-op" window (shown while the REFramework menu is open) ------------
coop_window = { open = true }

local function section(title, fn)
    if imgui.collapsing_header then
        if imgui.collapsing_header(title) then
            local ok, err = pcall(fn)
            if not ok then imgui.text("error: " .. tostring(err)) end
        end
    elseif imgui.tree_node(title) then
        local ok, err = pcall(fn)
        imgui.tree_pop()
        if not ok then imgui.text("error: " .. tostring(err)) end
    end
end

local function draw_testing()
    if imgui.button("Test with bot") then send_command("bot") end
    imgui.same_line()
    if imgui.button("Rebuild Ethan") then pcall(build_ethan) end
    imgui.same_line()
    if imgui.button("Teleport to my friend") then teleport_to_friend() end
    -- Cutscene fast-forward (testing): the whole game runs 8x while a cutscene plays,
    -- so every scripted step still happens; normal speed returns when it ends.
    if imgui.button("Fast-forward this cutscene") then fast_forward(true) end
    imgui.same_line()
    local fc, fv = imgui.checkbox("Fast-forward every cutscene", settings.ff_cutscenes == true)
    if fc then settings.ff_cutscenes = fv save_settings() end
    if imgui.button("Reload last save") then request_reload() end
    if reload_msg then imgui.same_line() imgui.text(reload_msg) end
    imgui.same_line()
    if reload.running then
        if imgui.button("Stop reload test") then reload.running = false end
        imgui.text(string.format("Reload test: round %d/%d, %s, passed %d, failed %d",
            reload.round, reload.total, reload.stage, reload.pass or 0, reload.fail or 0))
    elseif imgui.button("Run reload test (10x)") then
        start_reload_test()
    end
    imgui.text(string.format("Ghost rebuilds: %d   stance %s   direction %s   clip %s", ghost_gen,
        tostring(anim.stance or "-"), tostring(anim.dir or "-"), anim.playing and anim.playing.name or "-"))
    -- Enemy sync (coop_enemies.lua): the bot takes down the nearest awake enemy.
    if enemy_sync_status then
        imgui.text(enemy_sync_status())
        if imgui.button("Bot: take down the nearest enemy") then enemy_test_msg = enemy_sync_bot_kill_nearest() end
        imgui.same_line()
        if imgui.button("Bot: hit it for 25%") then enemy_test_msg = enemy_sync_bot_kill_nearest(0.25) end
        if enemy_test_msg then imgui.same_line() imgui.text(enemy_test_msg) end
        if revive_test_fatal_hit then
            if imgui.button("Take a fatal hit (you go down; the bot revives you)") then enemy_test_msg = revive_test_fatal_hit() end
        end
        if story_sync_status then
            imgui.text(story_sync_status())
            if imgui.button("Bot: trigger the next story cutscene") then enemy_test_msg = story_sync_bot_next() end
        end
        if world_sync_status then
            imgui.text(world_sync_status())
            if imgui.button("Bot: open nearest door") then enemy_test_msg = world_sync_bot("open") end
            imgui.same_line()
            if imgui.button("Bot: unlock nearest locked door") then enemy_test_msg = world_sync_bot("unlock") end
            imgui.same_line()
            if imgui.button("Bot: take nearest supply") then enemy_test_msg = world_sync_bot("took") end
            if imgui.button("Bot: smash nearest box") then enemy_test_msg = world_sync_bot("break") end
            imgui.same_line()
            if imgui.button("Bot: open/shut nearest drawer") then enemy_test_msg = world_sync_bot("drawer") end
        end
        if enemy_move_status then
            imgui.text(enemy_move_status())
            if imgui.button("Record nearest enemy (6 s)") then enemy_test_msg = enemy_move_record(6) end
            imgui.same_line()
            if imgui.button("Replay it with its AI off") then enemy_test_msg = enemy_move_replay() end
            if enemy_move_test_handoff then
                if imgui.button("Hand nearest enemy to the bot") then enemy_test_msg = enemy_move_test_handoff() end
                imgui.same_line()
                if imgui.button("Bot hands it back") then enemy_test_msg = enemy_move_bot_hands_back() end
            end
        end
    end
    local bc, bv = imgui.checkbox("Bot: use a non-English test name", bot_test_name)
    if bc then bot_test_name = bv end
    -- Test "Join my friend" alone: the bot claims a different chapter until reset.
    -- Bot movement: follow our own path (stays on real ground) or the old test circle.
    local kvb = net.kv or {}
    if kvb.mode == "bot" then
        if imgui.button("Bot: follow me") then send_command("botmode follow") end
        imgui.same_line()
        if imgui.button("Bot: walk in a circle") then send_command("botmode circle") end
        imgui.same_line()
        if imgui.button("Bot: stay here") then send_command("botmode stay") end
        imgui.same_line()
        imgui.text("Bot is: " .. tostring(kvb.botExpect or "-"))
    end
    if imgui.button("Bot: pretend to be in another chapter") then
        ensure_chapter_list()
        -- The next story chapter after ours (Chapter0 is the prologue tape: skip it),
        -- or the one before when we're in the last.
        local here, pick = local_chapter(), nil
        for _, e in ipairs(chapters.list or {}) do
            if e.name:match("^Chapter[1-9]$") and e.value ~= here then
                if e.value > here and (pick == nil or pick.value < here or e.value < pick.value) then pick = e
                elseif e.value < here and (pick == nil or (pick.value < here and e.value > pick.value)) then pick = e end
            end
        end
        if pick then
            send_command("botchapter " .. tostring(pick.value))
            join.msg = "the bot now claims " .. pick.name
            log("bot: claims " .. pick.name)
        end
    end
    imgui.same_line()
    if imgui.button("Bot: back to my chapter") then send_command("botchapter -1") end
    if imgui.tree_node("Chapter switcher") then
        local ok, err = pcall(draw_chapter_switcher)
        imgui.tree_pop()
        if not ok then log("chapter switcher ERR " .. tostring(err)) end
    end
end

re.on_draw_ui(function()
    local ok, err = pcall(function()
        local c, v = imgui.checkbox("Show the RE7 Co-op window", coop_window.open)
        if c then coop_window.open = v end
    end)
    if not coop_window.open or not imgui.begin_window then return end
    -- end_window must run after every begin_window, even if the body fails.
    if imgui.begin_window("RE7 Co-op", true, 0) then
        local ok, err = pcall(function()
            imgui.text("Status: " .. connection_text())
            section("Lobby", draw_lobby)
            section("Connect, saving and display", draw_connect_body)
            section("Testing", draw_testing)
            imgui.text("Advanced and debug controls: Script Generated UI > coop_dummy (ghost body test)")
        end)
        if not ok and not coop_window.err then coop_window.err = true log("window ERR " .. tostring(err)) end
    end
    imgui.end_window()
end)

-- Warp next to the other player (when you've got separated). Same chapter only.
TELEPORT_MAX = 40   -- m
bot_test_name = false
BOT_TEST_NAME = "Тест 测试 テスト 테스트 Ünï"

function teleport_to_friend()
    if dummy == nil or #parts == 0 or ghost_hidden then log("teleport: no friend to go to") return false end
    if net.peer_chapter and net.peer_chapter ~= local_chapter() then log("teleport: friend is in another chapter") return false end
    local player = get_player()
    local mc = player and player:call("getComponent(System.Type)", sdk.typeof("app.MovementController"))
    if mc == nil then log("teleport: no MovementController") return false end
    -- Land where the friend stood about a second ago: ground they actually walked on.
    -- A fixed sideways offset could be inside a wall; collision pushes us apart after.
    local g = dummy:call("get_Transform"):call("get_Position")
    local target = Vector3f.new(g.x, g.y, g.z)
    local now = os.clock()
    for i = #net.history, 1, -1 do
        local h = net.history[i]
        if h.t <= now - net.delay - 1.0 then target = h.pos break end
    end
    -- RE7 streams areas in around the player: a long warp can land where nothing is
    -- loaded yet. Only short hops (same area); otherwise walk towards them.
    local pp = player:call("get_Transform"):call("get_Position")
    local dist = math.sqrt((target.x - pp.x) ^ 2 + (target.y - pp.y) ^ 2 + (target.z - pp.z) ^ 2)
    if dist > TELEPORT_MAX then
        join.msg = string.format("friend is %d m away: too far to teleport safely, walk closer", math.floor(dist))
        log("teleport: refused, " .. join.msg)
        return false
    end
    local pq = player:call("get_Transform"):call("get_Rotation")
    local ok, err = pcall(mc.call, mc, "warp(via.vec3, via.Quaternion)", target, pq)
    join.msg = ok and "teleported next to your friend" or "teleport failed"
    log("teleport: " .. (ok and "warped next to friend" or ("ERR " .. tostring(err))))
    return ok
end

local function draw_connect_panel()
    if not connect_ui.opened then
        connect_ui.opened = true
        if imgui.set_next_item_open then pcall(imgui.set_next_item_open, true) end
    end
    if imgui.tree_node("Connect") then
        local ok, err = pcall(draw_connect_body)   -- tree_pop must run even if the body fails
        imgui.tree_pop()
        if not ok and not connect_ui.err then connect_ui.err = true log("connect panel ERR " .. tostring(err)) end
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("coop_dummy (ghost body test)") then return end
    draw_connect_panel()
    imgui.text("Showing: " .. current)
    if dummy_mesh == nil then
        imgui.text("waiting for the dummy to spawn...")
    else
        local fchanged, fv = imgui.checkbox("Move the ghost (source: " ..
            (net.enabled and "network" or ("my own path, " .. DELAY .. " s behind")) .. ")", follow)
        if fchanged then follow = fv log("follow = " .. tostring(fv)) end
        local nchanged, nv = imgui.checkbox("Drive ghost from NETWORK (CoopNet plugin)", net.enabled)
        if nchanged then
            net.enabled = nv
            net.history, net.last_in_seq, net.offset = {}, -1, nil
            log("net.enabled = " .. tostring(nv))
        end
        if net.enabled then
            if imgui.button("Delay 3 s (echo test)") then net.delay = 3.0 log("net.delay = 3.0") end
            imgui.same_line()
            if imgui.button("Delay 0.15 s (live)") then net.delay = 0.15 log("net.delay = 0.15") end
            imgui.text(string.format("net: delay %.2f s, %d samples, last seq %d, offset %s",
                net.delay, #net.history, net.last_in_seq, net.offset and string.format("%.3f", net.offset) or "-"))
            imgui.text("CoopNet: " .. net.stats)
            local lchanged, lv = imgui.checkbox("Head look v3 (turns off by itself if the walk freezes)", look.enabled)
            if lchanged then look.enabled = lv log("look.enabled = " .. tostring(lv)) end
        end
        if #parts > 0 then
            local all = parts_mode == "all"
            local pchanged, pv = imgui.checkbox("Show ALL mesh parts (variants overlap)", all)
            if pchanged then
                parts_mode = pv and "all" or "source"
                for _, part in ipairs(parts) do apply_mask(part) end
                log("parts_mode = " .. parts_mode)
            end
        end
        if anim.ready then
            imgui.text(string.format("Animation: %d clips. Playing: %s | WALK=%s IDLE=%s", #anim.clips,
                anim.playing and anim.playing.name or "-", anim.walk and anim.walk.name or "unset",
                anim.idle and anim.idle.name or "unset"))
            local achanged, av = imgui.checkbox("Auto: walk when moving, idle when still", anim.auto)
            if achanged then anim.auto = av log("anim auto = " .. tostring(av)) end
            imgui.text(string.format("ghost speed %.2f m/s, stance %s, direction %s, clip %s, playback x%.2f", anim.speed or 0,
                anim.stance or "-", anim.dir or "-", anim.playing and anim.playing.name or "-", anim.rate or 1))
            local rchanged, rv = imgui.slider_float("Walk clip natural speed (m/s)", anim.walk_ref, 0.5, 3.0)
            if rchanged then anim.walk_ref = rv end
            if imgui.tree_node("Clips (walk/idle/wait/run/move/stand)") then
                local shown = 0
                for i, c in ipairs(anim.clips) do
                    local ln = c.name:lower()
                    if shown < 60 and (ln:find("walk") or ln:find("idle") or ln:find("wait") or ln:find("run")
                        or ln:find("move") or ln:find("stand") or ln:find("loop")) then
                        shown = shown + 1
                        if imgui.button(c.name .. "##play" .. i) then
                            anim.auto = false  -- a manual pick sticks; Auto would override it
                            log("anim auto = false (manual clip)")
                            play_clip(c)
                        end
                        imgui.same_line()
                        if imgui.button("WALK##w" .. i) then anim.walk = c log("walk = " .. c.name) play_clip(c) end
                        imgui.same_line()
                        if imgui.button("IDLE##i" .. i) then anim.idle = c log("idle = " .. c.name) play_clip(c) end
                    end
                end
                if shown == 0 then imgui.text("(no matching names; see coop_motions.txt)") end
                imgui.tree_pop()
            end
        end
        local changed, v = imgui.checkbox("Copy my pose onto it", copy_pose)
        if changed then copy_pose = v log("copy_pose = " .. tostring(v)) end
        if imgui.button("Dummy animation OFF") then set_motion_enabled(false) log("dummy Motion disabled") end
        imgui.same_line()
        if imgui.button("Dummy animation ON") then set_motion_enabled(true) log("dummy Motion enabled") end
        if imgui.button("Move it next to me") then
            local p = get_player():call("get_Transform"):call("get_Position")
            dummy:call("get_Transform"):call("set_Position", Vector3f.new(p.x + 1.5, p.y, p.z))
            log("moved dummy next to player")
        end
        local cchanged, cv = imgui.checkbox(string.format("Collide with the other player (%d pushes)", collide and collide.pushes or 0),
            collide and collide.enabled)
        if cchanged and collide then collide.enabled = cv log("collide.enabled = " .. tostring(cv)) end
        if imgui.tree_node("Tests") then
            if imgui.button("Reload last save") then request_reload() end
            if reload.running then
                imgui.same_line()
                if imgui.button("Stop reload test") then reload.running = false log("reload test stopped") end
                imgui.text(string.format("Reload test: round %d/%d, %s, passed %d, failed %d",
                    reload.round, reload.total, reload.stage, reload.pass or 0, reload.fail or 0))
            else
                imgui.same_line()
                if imgui.button(string.format("Run reload test (%dx, every %d s)", reload.total, reload.every)) then
                    start_reload_test()
                end
            end
            imgui.text(string.format("Ghost rebuilds so far: %d%s", ghost_gen, ghost_hidden and " (hidden: no data)" or ""))
            imgui.tree_pop()
        end
        -- The ghost builds itself as Ethan; this only redoes it (e.g. after a load).
        if imgui.button("Rebuild Ethan") then
            local ok, err = pcall(build_ethan)
            if not ok then log("rebuild Ethan ERR " .. tostring(err)) end
        end
        if imgui.tree_node("Other characters (debug)") then
            for i, c in ipairs(candidates) do
                local short = c.mesh:match("([^/]+)%.mesh$") or c.mesh
                if c.mesh:find("Enemy") and imgui.button("Assemble full character of " .. short .. "##asm" .. i) then
                    parts_mode = "source"
                    anim_from_player = false
                    local ok, err = pcall(assemble_from, c)
                    if not ok then log("assemble ERR " .. tostring(err)) end
                end
            end
            imgui.text("Single models loaded in this area:")
            for i, c in ipairs(candidates) do
                local short = c.mesh:match("([^/]+)%.mesh$") or c.mesh
                if imgui.button(string.format("%d. %s##one%d", i, short, i)) then
                    local ok, err = pcall(apply_model, dummy_mesh, c)
                    current = c.mesh
                    log("picker: applied " .. c.mesh .. " -> " .. (ok and "ok" or ("ERR " .. tostring(err))))
                end
            end
            imgui.tree_pop()
        end
    end
    imgui.tree_pop()
end)

function apply_model(mesh, model)
    local holder = model.holder
    if holder == nil then
        local r = sdk.create_resource("via.render.MeshResource", model.mesh)
        r:add_ref()
        holder = r:create_holder("via.render.MeshResourceHolder")
        holder:add_ref()
    end
    mesh:call("setMesh", holder)
    local mholder = model.mholder
    if mholder == nil and model.mdf then
        local r = sdk.create_resource("via.render.MeshMaterialResource", model.mdf)
        r:add_ref()
        mholder = r:create_holder("via.render.MeshMaterialResourceHolder")
        mholder:add_ref()
    end
    if mholder then mesh:call("set_Material", mholder) end
    -- rebuild the render instance and show every part of the new mesh
    mesh:call("set_Enabled", false)
    mesh:call("set_Enabled", true)
    local n = tonumber(safe(mesh.call, mesh, "getPartsEnableCount") or 0) or 0
    for i = 0, n - 1 do safe(mesh.call, mesh, "setPartsEnable", i, true) end
end

local model = nil
local phase, frames, t0 = "wait", 0, 0

-- Survive loads, deaths and area changes -------------------------------------------
-- Those recreate the player object and unload the folder the ghost lives in, so
-- watch for a new player (or a destroyed ghost) and run the spawn sequence again.
ghost_gen = 0            -- bumps on every rebuild; the reload test watches it

function respawn_ghost(reason)
    log("respawn: " .. reason)
    local destroy = sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)")
    for _, p in ipairs(parts) do pcall(destroy.call, destroy, nil, p.go) end
    if dummy then pcall(destroy.call, destroy, nil, dummy) end
    parts, dummy, dummy_mesh, candidates = {}, nil, nil, {}
    anim.motion, anim.ready, anim.clips, anim.playing = nil, false, {}, nil
    anim.walk, anim.idle, anim.set, anim.poll_until, anim.verify_at = nil, nil, nil, nil, nil
    anim.last_verify_frame, anim.fail_streak, anim.retries, anim.body_q = nil, 0, 0, nil
    if look2 then look2.list, look2.jobj = nil, nil end
    ghost_hidden = false
    phase, frames = "wait", 0
    ghost_gen = ghost_gen + 1
    respawn_t = os.clock()
end

-- Any playable character (Pl0000 Ethan, the videotape characters...). During a
-- load RE7 first shows a temporary loading-scene player; assemble_from skips any
-- player without a Shadow body, so that one never gets a ghost.
local function player_is_ethan(player)
    local name = tostring(safe(player.call, player, "get_Name") or "")
    return name:find("^Pl%d") ~= nil
end

local watch = { addr = nil, t = 0 }
re.on_frame(function()
    local now = os.clock()
    if now - watch.t < 0.5 then return end
    watch.t = now
    local player = get_player()
    local addr = player and safe(player.get_address, player)
    if addr == nil then return end                         -- loading screen: wait
    if watch.addr and addr ~= watch.addr then
        watch.addr = addr
        respawn_ghost("player object changed (load, death or area change)")
        return
    end
    watch.addr = addr
    -- Ghost torn down underneath us (its folder unloaded)?
    if phase == "done" and #parts > 0 then
        local alive = safe(parts[1].go.call, parts[1].go, "get_Name")
        if alive == nil then respawn_ghost("ghost objects were destroyed") end
    end
end)

-- Reload test -----------------------------------------------------------------------
-- Loads the save the session started from (what Continue does) and checks the ghost
-- comes back: rebuilt, a clip bound and advancing, network still flowing. Loading
-- only reads; coop_saveguard keeps blocking the autosave that follows a load.
-- Results: reframework/data/coop_reload_test.txt
-- timeout 180: on this PC a load passes through a temporary loading-scene player for
-- ~80 s before the real one appears (first run: rebuilds took 7-8 s, 90 s was too tight).
reload = { running = false, round = 0, total = 10, every = 45, timeout = 180, stage = "idle", lines = {} }

reload_msg = nil
function request_reload()
    -- After a chapter jump the load first tries an internal save the save guard blocks, and
    -- the game sits on the loading icon for good (2026-11-02). Restarting is the way back.
    if chapters and chapters.jump_t then
        reload_msg = "Not after a chapter jump: restart the game and pick Continue instead"
        log("reload: refused after a chapter jump")
        return false
    end
    reload_msg = nil
    local sdm = sdk.get_managed_singleton("app.SaveDataManager")
    if sdm == nil then log("reload: no SaveDataManager") return false end
    local slot = tonumber(safe(sdm.get_field, sdm, "LoadSlotNo") or -1) or -1
    if slot < 0 then slot = tonumber(safe(sdm.get_field, sdm, "SaveSlotNo") or 0) or 0 end
    local ok, err = pcall(sdm.call, sdm, "loadFileAutoRequest(System.Int32, System.Boolean, System.Boolean, System.Boolean)",
        slot, false, false, false)
    log(string.format("reload: loadFileAutoRequest(slot %d) -> %s", slot, ok and "requested" or ("ERR " .. tostring(err))))
    return ok
end

local function reload_note(s)
    reload.lines[#reload.lines + 1] = os.date("%H:%M:%S ") .. s
    fs.write("coop_reload_test.txt", table.concat(reload.lines, "\n"))
    log("reload test: " .. s)
end

function start_reload_test()
    reload.running, reload.round, reload.stage, reload.lines = true, 0, "next", {}
    reload.pass, reload.fail = 0, 0
    reload_note(string.format("start: %d rounds, one every %d s", reload.total, reload.every))
end

re.on_frame(function()
    if not reload.running then return end
    local now = os.clock()
    if reload.stage == "next" then
        if reload.round >= reload.total then
            reload.running, reload.stage = false, "idle"
            reload_note(string.format("DONE: %d passed, %d failed", reload.pass, reload.fail))
            return
        end
        reload.round = reload.round + 1
        reload.gen0, reload.seq0, reload.t = ghost_gen, net.last_in_seq, now
        if request_reload() then reload.stage = "loading" else reload.stage = "wait"; reload.fail = reload.fail + 1 end
    elseif reload.stage == "loading" then
        local rebuilt = ghost_gen > reload.gen0
        local pieces = #parts >= 5
        local animating = anim.bound_t ~= nil and anim.bound_t > reload.t
        local flowing = net.last_in_seq > reload.seq0 and not ghost_hidden
        if rebuilt and pieces and animating and flowing then
            reload.pass = reload.pass + 1
            local appear = (respawn_t and respawn_t > reload.t) and respawn_t or reload.t
            reload_note(string.format("round %d PASS: load %.1f s, ghost back %.1f s after the player appeared",
                reload.round, appear - reload.t, now - appear))
            reload.stage, reload.t = "wait", now
        elseif now - reload.t > reload.timeout then
            reload.fail = reload.fail + 1
            reload_note(string.format("round %d FAIL after %d s: rebuilt=%s pieces=%d animating=%s flowing=%s",
                reload.round, reload.timeout, tostring(rebuilt), #parts, tostring(animating), tostring(flowing)))
            reload.stage, reload.t = "wait", now
        end
    elseif reload.stage == "wait" and now - reload.t > reload.every then
        reload.stage = "next"
    end
end)

-- Hide the ghost when the other player's data stops (disconnect, alt-tab, crash)
-- and show him again when it resumes.
-- Cutscene fast-forward (testing) ----------------------------------------------------
FF_SPEED = 8.0
local ff = { on = false }
local function scene_obj()
    return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end
function fast_forward(on)
    local sc = scene_obj()
    if sc == nil then return end
    if on and not local_cutscene() then log("fast-forward: no cutscene playing") return end
    pcall(sc.call, sc, "set_TimeScale", on and FF_SPEED or 1.0)
    ff.on = on
    log("fast-forward: " .. (on and "on" or "off"))
end
re.on_frame(function()
    local playing = local_cutscene()
    if ff.on and not playing then fast_forward(false)
    elseif not ff.on and playing and settings and settings.ff_cutscenes then fast_forward(true) end
end)

-- A cutscene video cut short (story sharing, chapter jumps) can leave MenuManager's
-- "full-screen movie playing" flag on, and with it on the pause menu never opens. Clear it
-- once nothing has been playing and the player has been in control for 5 s.
local movie_flag = { since = nil }
re.on_frame(function()
    local mm = sdk.get_managed_singleton("app.MenuManager")
    local stuck = mm ~= nil and safe(mm.call, mm, "get_IsPlayInGameFullScreenMovie") == true
        and not local_cutscene() and safe(mm.call, mm, "isCanInteract") == true
    if not stuck then movie_flag.since = nil return end
    local now = os.clock()
    movie_flag.since = movie_flag.since or now
    if now - movie_flag.since < 5.0 then return end
    movie_flag.since = nil
    if not pcall(mm.call, mm, "set_IsPlayInGameFullScreenMovie", false) then
        pcall(mm.set_field, mm, "<IsPlayInGameFullScreenMovie>k__BackingField", false)
    end
    log("cleared a stuck full-screen movie flag (pause menu works again)")
end)

NET_TIMEOUT = 2.0
CUTSCENE_DEBOUNCE = 0.5   -- s an event must run before the ghost hides (no flicker on tiny events)
ghost_hidden = false
cutscene_now = false      -- our own cutscene state, also sent to the other player (STANCE_CUTSCENE)
local cs = { since = nil, check_t = 0 }
re.on_frame(function()
    -- Our own cutscene state (checked 10x a second, debounced).
    local now = os.clock()
    if now - cs.check_t > 0.1 then
        cs.check_t = now
        local running = local_cutscene()
        if running then cs.since = cs.since or now else cs.since = nil end
        local want = cs.since ~= nil and (now - cs.since) >= CUTSCENE_DEBOUNCE
        if want ~= cutscene_now then
            cutscene_now = want
            log(string.format("cutscene: %s (%d running events)", want and "started" or "ended", cutscene_events or 0))
        end
    end
    if not net.enabled or #parts == 0 then return end
    local last = net.history[#net.history]
    local stale = (last == nil) or (now - last.t > NET_TIMEOUT + net.delay)
    -- Hide him while we watch a cutscene, and while *they* are in one (their character
    -- is being moved by their cutscene, which would look odd here).
    -- From the newest sample, not anim.flags: that is only refreshed while the ghost
    -- animates, so once hidden for "their cutscene" it never saw the cutscene end.
    local theirs = last ~= nil and last.flags ~= nil and (last.flags & STANCE_CUTSCENE) ~= 0
    local hide = stale or cutscene_now or theirs
    if hide ~= ghost_hidden then
        ghost_hidden = hide
        for _, p in ipairs(parts) do pcall(p.go.call, p.go, "set_DrawSelf", not hide) end
        local why = stale and "no data for 2 s" or cutscene_now and "you're in a cutscene" or theirs and "they're in a cutscene" or ""
        log(hide and ("ghost hidden: " .. why) or "ghost shown")
        cs.apply_t = now
    elseif now - (cs.apply_t or 0) > 0.5 then
        -- Re-apply twice a second: a hide right after a rebuild was undone by the build
        -- steps that switch every piece on, leaving a frozen, nameless Ethan on screen.
        cs.apply_t = now
        for _, p in ipairs(parts) do pcall(p.go.call, p.go, "set_DrawSelf", not ghost_hidden) end
    end
end)

-- Nameplate with the distance; when the friend is off screen (behind a wall still counts
-- as on screen), a pointer at the screen edge: "<" left, ">" right, "v" behind you.
function friend_marker(name, p)
    local player = get_player()
    local pp = player and player:call("get_Transform"):call("get_Position")
    local d = pp and math.sqrt((p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2 + (p.z - pp.z) ^ 2)
    local label = d and string.format("%s  %d m", name, math.floor(d + 0.5)) or name
    local head = Vector3f.new(p.x, p.y + 2.0, p.z)
    local sok, sp = pcall(draw.world_to_screen, head)
    if not sok then draw.world_text(label, head, 0xFFFFFFFF) return end   -- no projection: plain nameplate
    local w, h = 1920, 1080
    local ok, size = pcall(imgui.get_display_size)
    if ok and size then w, h = size.x, size.y end
    if sp and sp.x >= 0 and sp.x <= w and sp.y >= 0 and sp.y <= h then
        draw.world_text(label, head, 0xFFFFFFFF)
        return
    end
    if pp == nil or (settings and settings.hud == false) then return end
    -- Which way to turn: the friend's direction against the player's facing (the right-hand
    -- side is -X in RE7's local space).
    local tr = player:call("get_Transform")
    local f, x = tr:call("get_AxisZ"), tr:call("get_AxisX")
    local vx, vz = p.x - pp.x, p.z - pp.z
    local ahead = vx * f.x + vz * f.z
    local right = -(vx * x.x + vz * x.z)
    if ahead < 0 and math.abs(right) < -ahead then
        draw.text("v " .. label .. " (behind you)", w / 2 - 80, h - 60, 0xFF7FE6FF)
    elseif right > 0 then
        draw.text(label .. " >", w - 220, h / 2, 0xFF7FE6FF)
    else
        draw.text("< " .. label, 20, h / 2, 0xFF7FE6FF)
    end
end

re.on_frame(function()
    frames = frames + 1
    if phase == "wait" then
        if get_player() and frames > 60 and player_is_ethan(get_player()) then
            local vr = sdk.get_managed_singleton("app.vr.VrManager")
            prefab = vr and vr:get_field("DummyPlayerPrefab")
            if prefab == nil then log("FAIL: VrManager.DummyPlayerPrefab is nil") phase = "done" return end
            log("prefab: " .. tostring(safe(prefab.call, prefab, "get_Path")))
            local existing = vr:get_field("_DummyPlayer")
            log("VrManager._DummyPlayer before spawn: " .. tostring(existing and existing:call("get_Name")))
            safe(prefab.call, prefab, "set_Standby", true)
            phase, t0 = "standby", os.clock()
        end
    elseif phase == "standby" then
        local ready = safe(prefab.call, prefab, "get_Ready")
        if ready or os.clock() - t0 > 10 then
            local p = get_player():call("get_Transform"):call("get_Position")
            local pos = Vector3f.new(p.x + 2.0, p.y, p.z)
            local go, err = safe(prefab.call, prefab, "instantiate(via.vec3)", pos)
            if go == nil then
                log("FAIL instantiate(via.vec3): " .. tostring(err))
                go, err = safe(prefab.call, prefab, "instantiate(via.vec3, via.Folder)", pos, get_player():call("get_Folder"))
            end
            if go == nil then log("FAIL instantiate: " .. tostring(err)) phase = "done" return end
            dummy = go
            log(string.format("instantiated at %.2f %.2f %.2f (ready=%s)", pos.x, pos.y, pos.z, tostring(ready)))
            phase, t0 = "spawned", os.clock()
        end
    elseif phase == "spawned" and os.clock() - t0 > 3 then
        -- give async resources a moment, then record what we got
        dump_tree(dummy, 0, { n = 200 })
        -- The prefab spawns hidden; VR mode shows it via updateDummyPlayer() only
        -- during VR events. Turn it on ourselves.
        safe(dummy.call, dummy, "set_DrawSelf", true)
        safe(dummy.call, dummy, "set_UpdateSelf", true)
        local mesh = safe(dummy.call, dummy, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        if mesh then
            safe(mesh.call, mesh, "set_Enabled", true)
            safe(mesh.call, mesh, "set_DrawDefault", true)
            local n = tonumber(safe(mesh.call, mesh, "getPartsEnableCount") or 0) or 0
            for i = 0, n - 1 do safe(mesh.call, mesh, "setPartsEnable", i, true) end
            log("enabled DrawSelf, UpdateSelf, mesh and " .. n .. " parts")
        end
        phase, t0 = "shown", os.clock()
    elseif phase == "shown" and os.clock() - t0 > 2 then
        dump_tree(dummy, 0, { n = 200 })
        -- Compare materials with the live player, then take the player's.
        local mesh = dummy:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        local pmesh = get_player():call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        local function mats(m)
            local n = tonumber(safe(m.call, m, "get_MaterialNum") or 0) or 0
            local out = {}
            for i = 0, n - 1 do out[#out + 1] = tostring(safe(m.call, m, "getMaterialName", i)) end
            local h = safe(m.call, m, "get_Material")
            return n, table.concat(out, ","), tostring(h and safe(h.call, h, "get_ResourcePath"))
        end
        log(string.format("dummy materials: %d [%s] mdf=%s", mats(mesh)))
        log(string.format("player materials: %d [%s] mdf=%s", mats(pmesh)))
        local _, err = safe(mesh.call, mesh, "set_Material", pmesh:call("get_Material"))
        log("copied player material: " .. (err and ("ERR " .. tostring(err)) or "ok"))
        dummy_mesh = mesh
        phase, t0 = "material", os.clock()
    elseif phase == "material" and os.clock() - t0 > 2 then
        log(string.format("after copy: MaterialReady=%s ReadyToDraw=%s",
            tostring(safe(dummy_mesh.call, dummy_mesh, "get_MaterialReady")),
            tostring(safe(dummy_mesh.call, dummy_mesh, "get_ReadyToDraw"))))
        -- Don't auto-swap: list loaded models in the REFramework menu and let the
        -- owner try them one by one (see re.on_draw_ui below).
        candidates = find_full_model()
        log("picker ready with " .. #candidates .. " models (REFramework menu > coop_dummy)")
        phase = "done"
        -- The co-op ghost is always Ethan: build him from the player's Shadow set
        -- as soon as the stand-in body is ready, no button needed.
        local ok, err = pcall(build_ethan)
        if not ok then log("auto Ethan ERR " .. tostring(err)) end
    elseif phase == "swapped" and os.clock() - t0 > 3 then
        log(string.format("after swap: MaterialReady=%s ReadyToDraw=%s parts=%s",
            tostring(safe(dummy_mesh.call, dummy_mesh, "get_MaterialReady")),
            tostring(safe(dummy_mesh.call, dummy_mesh, "get_ReadyToDraw")),
            tostring(safe(dummy_mesh.call, dummy_mesh, "getPartsEnableCount"))))
        phase = "done"
    end

    -- Pose the dummy's skeleton from the player's every frame.
    if dummy and copy_pose and (phase == "material" or phase == "done") then
        local ptr = get_player() and get_player():call("get_Transform")
        local dtr = safe(dummy.call, dummy, "get_Transform")
        if ptr and dtr then
            local _, err = safe(dtr.call, dtr, "copyJointsLocalMatrix", ptr)
            if err and not pose_err_logged then pose_err_logged = true log("pose copy error: " .. tostring(err)) end
        end
    end

    if dummy then
        local p = safe(function() return dummy:call("get_Transform"):call("get_Position") end)
        if p then
            -- Nameplate over the other player's head (their Steam name; "Bot" in bot mode).
            if not ghost_hidden and #parts > 0 and settings and settings.nameplate ~= false then
                local kv = net.kv or {}
                local name = (kv.mode == "bot") and (bot_test_name and BOT_TEST_NAME or "Bot")
                    or ((kv.peerName and kv.peerName ~= "") and kv.peerName or "Friend")
                pcall(friend_marker, name, p)
            end
            if frames % 120 == 0 then
                fs.write("coop_dummy_state.txt", string.format("dummy: %.3f %.3f %.3f", p.x, p.y, p.z))
            end
        end
    end
end)

-- Head look v2: through the Motion component, not behind its back. v1 wrote
-- via.Joint world rotations before rendering, which made RE7 stop animating the
-- skeleton and let the turns accumulate. Here, right after the engine's motion
-- update, each joint starts from this frame's animated local pose
-- (getCalculatedLocalRotation), gets the look turn conjugated into its parent's
-- space, and is written with Motion.setLocalRotation. No accumulation possible.
look2 = { list = nil, fired = 0, reported = false, t0 = os.clock() }   -- global: respawn_ghost (earlier) resets it

local function look2_joints(m)
    local go = m:call("get_GameObject")
    local tr = go:call("get_Transform")
    local arr = tr:call("get_Joints")
    local neck, head
    for _, j in ipairs((arr and arr:get_elements()) or {}) do
        local n = tostring(safe(j.call, j, "get_Name")):lower()
        if neck == nil and n:find("neck") then neck = j end
        if head == nil and n:find("head") and not n:find("end") then head = j end
    end
    local list = {}
    for _, e in ipairs({ { neck, 0.4 }, { head, 0.6 } }) do
        if e[1] then
            local idx = m:call("getJointIndexByNameHash", e[1]:call("get_NameHash"))
            list[#list + 1] = { idx = idx, share = e[2], name = tostring(e[1]:call("get_Name")) }
        end
    end
    log("look v2: " .. #list .. " joints: " .. table.concat((function()
        local t = {} for _, e in ipairs(list) do t[#t + 1] = e.name .. "#" .. tostring(e.idx) end return t end)(), ", "))
    return list
end

local function apply_look_motion()
    local m = anim.motion
    if m == nil then return end
    if look2.list == nil then look2.list = look2_joints(m) end
    local root_q = m:call("get_GameObject"):call("get_Transform"):call("get_Rotation")
    local bq = { x = root_q.x, y = root_q.y, z = root_q.z, w = root_q.w }
    local yaw = math.max(-1.2, math.min(1.2, look.yaw))
    local pitch = math.max(-0.7, math.min(0.7, look.pitch))
    local rx, ry, rz = qrot_v(bq, 1, 0, 0)
    for _, e in ipairs(look2.list) do
        if e.idx and e.idx >= 0 then
            local pidx = m:call("getParentJointIndex", e.idx)
            local pw = m:call("getWorldRotation", pidx)
            local al = m:call("getCalculatedLocalRotation", e.idx)
            local P = { x = pw.x, y = pw.y, z = pw.z, w = pw.w }
            local A = { x = al.x, y = al.y, z = al.z, w = al.w }
            local D = qmul_l(axis_q(0, 1, 0, yaw * e.share), axis_q(rx, ry, rz, -pitch * e.share))
            -- new_local = conj(P) * D * P * A  (world-space turn D, expressed in parent space)
            local n = qmul_l(qmul_l(qmul_l({ x = -P.x, y = -P.y, z = -P.z, w = P.w }, D), P), A)
            m:call("setLocalRotation", e.idx, Quaternion.new(n.w, n.x, n.y, n.z))
            if e.name:lower():find("head") then
                local rb = m:call("getLocalRotation", e.idx)
                look2.last = string.format("yaw %.2f pitch %.2f | anim %.3f %.3f %.3f %.3f | set %.3f %.3f %.3f %.3f | readback %.3f %.3f %.3f %.3f",
                    look.yaw, look.pitch, A.x, A.y, A.z, A.w, n.x, n.y, n.z, n.w, rb.x, rb.y, rb.z, rb.w)
            end
        end
    end
end

-- What the Head joint holds once drawing starts (after our v3 write).
re.on_application_entry("PrepareRendering", function()
    if not (look.enabled and look2.list and anim.motion) then return end
    local now = os.clock()
    if now - (look2.diag_t or 0) < 60 then return end   -- was 2 s: half of every log
    look2.diag_t = now
    pcall(function()
        local tr = anim.motion:call("get_GameObject"):call("get_Transform")
        local hj = tr:call("getJointByName", "Head")
        local lr = hj and hj:call("get_LocalRotation")
        log("look v2 diag: " .. tostring(look2.last) ..
            (lr and string.format(" | at render %.3f %.3f %.3f %.3f", lr.x, lr.y, lr.z, lr.w) or " | at render: no Head joint"))
    end)
end)

-- v2 diagnostics (19:00): setLocalRotation in the UpdateMotion hook is accepted
-- (readback matches) but by render time the Head joint is back to the plain
-- animated pose: Motion writes its own result into the skeleton afterwards.
-- So the hook only counts; the write happens at PrepareRendering (below).
re.on_application_entry("UpdateMotion", function()
    look2.fired = look2.fired + 1
end)

-- v3: write the joints last, just before drawing. The base is Motion's freshly
-- calculated pose for this frame (not what the joint holds now), so even if the
-- engine skips a frame the turn can't accumulate the way v1 did.
local function apply_look_render()
    local m = anim.motion
    if m == nil then return end
    if look2.list == nil then look2.list = look2_joints(m) end
    local tr = m:call("get_GameObject"):call("get_Transform")
    if look2.jobj == nil then
        look2.jobj = {}
        for _, e in ipairs(look2.list) do look2.jobj[e.idx] = tr:call("getJointByName", e.name) end
    end
    local rq = tr:call("get_Rotation")
    local bq = { x = rq.x, y = rq.y, z = rq.z, w = rq.w }
    local yaw = math.max(-1.2, math.min(1.2, look.yaw))
    local pitch = math.max(-0.7, math.min(0.7, look.pitch))
    local rx, ry, rz = qrot_v(bq, 1, 0, 0)
    for _, e in ipairs(look2.list) do
        local j = look2.jobj[e.idx]
        if j and e.idx >= 0 then
            local pidx = m:call("getParentJointIndex", e.idx)
            local pw = m:call("getWorldRotation", pidx)
            local al = m:call("getCalculatedLocalRotation", e.idx)
            local P = { x = pw.x, y = pw.y, z = pw.z, w = pw.w }
            local A = { x = al.x, y = al.y, z = al.z, w = al.w }
            local D = qmul_l(axis_q(0, 1, 0, yaw * e.share), axis_q(rx, ry, rz, -pitch * e.share))
            local n = qmul_l(qmul_l(qmul_l({ x = -P.x, y = -P.y, z = -P.z, w = P.w }, D), P), A)
            j:call("set_LocalRotation", Quaternion.new(n.w, n.x, n.y, n.z))
            if e.name:lower():find("head") then
                look2.last = string.format("yaw %.2f pitch %.2f | anim %.3f %.3f %.3f %.3f | set %.3f %.3f %.3f %.3f",
                    look.yaw, look.pitch, A.x, A.y, A.z, A.w, n.x, n.y, n.z, n.w)
            end
        end
    end
end

re.on_pre_application_entry("PrepareRendering", function()
    if not (look.enabled and net.enabled and follow and anim.ready) then return end
    local ok, err = pcall(apply_look_render)
    if not ok and not look.err then look.err = true log("look v3 ERR " .. tostring(err)) end
end)

re.on_frame(function()
    if not look2.reported and os.clock() - look2.t0 > 3 then
        look2.reported = true
        log("look v2: UpdateMotion hook fired " .. look2.fired .. " times in 3 s" ..
            (look2.fired == 0 and " (hook name not valid in RE7?)" or ""))
    end
end)

-- Footsteps ----------------------------------------------------------------------
-- The ghost has no sound components. The local player's app.FootEffectController has
-- callSE(SETriggerTypeEnum, position, materialID), which plays Ethan's footstep at any
-- position; SETarget picks the walk/jog/crouch sound set. One step per stride travelled.
-- The ground material is ours (the friend's isn't sent), close enough nearby.
STEP_STRIDE = { walk = 0.75, jog = 1.05, crouch = 0.6 }
STEP_TARGET = { walk = 0, jog = 1, crouch = 2 }   -- SETriggerTargetEnum Player/PlayerJog/PlayerCrouch
local steps = { last = nil, dist = 0, left = true, err = false }

re.on_frame(function()
    if not (settings and settings.footsteps ~= false) or dummy == nil or ghost_hidden or #parts == 0 then
        steps.last = nil
        return
    end
    local ok, err = pcall(function()
        local p = dummy:call("get_Transform"):call("get_Position")
        local last = steps.last
        steps.last = Vector3f.new(p.x, p.y, p.z)
        if last == nil then return end
        local d = math.sqrt((p.x - last.x) ^ 2 + (p.z - last.z) ^ 2)
        if d > 2 then steps.dist = 0 return end   -- a rebuild or teleport, not walking
        local stance = anim.stance
        local stride = STEP_STRIDE[stance]
        if stride == nil then steps.dist = 0 return end
        steps.dist = steps.dist + d
        if steps.dist < stride then return end
        steps.dist = steps.dist - stride
        local player = get_player()
        local fe = player and player:call("getComponent(System.Type)", sdk.typeof("app.FootEffectController"))
        if fe == nil then return end
        local before = fe:get_field("SETarget")
        fe:set_field("SETarget", STEP_TARGET[stance])
        fe:call("callSE(app.FootEffectController.SETriggerTypeEnum, via.vec3, System.UInt32)",
            steps.left and 0 or 1, steps.last, fe:get_field("MaterialID"))
        fe:set_field("SETarget", before)
        steps.left = not steps.left
    end)
    if not ok and not steps.err then steps.err = true log("footsteps ERR " .. tostring(err)) end
end)

-- On-screen status ------------------------------------------------------------------
-- A few lines in the top-left corner, visible without opening the REFramework menu:
-- connection and ping, the friend's chapter when it differs, mod-version trouble,
-- and whether saving is on.
local hud = { bad_prev = 0, bad_t = -100, err = false }

local function hud_lines()
    local kv = net.kv or {}
    local out = {}
    local last = net.history[#net.history]
    local fresh = last ~= nil and (os.clock() - last.t) < (NET_TIMEOUT or 2)
    local ping = net.ping and string.format(" - %d ms", math.floor(net.ping * 1000 + 0.5)) or ""
    if kv.mode == "bot" then
        out[#out + 1] = { "Co-op: bot test" .. ping, 0xFFFFD27F }
    elseif kv.mode == "steam" and (kv.peer == nil or kv.peer == "steam:0") then
        out[#out + 1] = { "Co-op: not connected (press Insert, RE7 Co-op window)", 0xFF9EB7FF }
    elseif fresh then
        local who = (kv.peerName and kv.peerName ~= "") and kv.peerName or "your friend"
        out[#out + 1] = { "Co-op: connected to " .. who .. ping, 0xFF7FFF8C }
    else
        out[#out + 1] = { "Co-op: waiting for your friend...", 0xFF7FE6FF }
    end
    local inv = pending_invite and pending_invite()
    if inv then
        out[#out + 1] = { inv.name .. " invited you to co-op: press Insert, then Accept in the RE7 Co-op window", 0xFF7FFF8C }
    end
    if fresh and anim.flags and (anim.flags & STANCE_CUTSCENE) ~= 0 then
        out[#out + 1] = { "Friend is watching a cutscene", 0xFF7FE6FF }
    end
    if fresh and net.peer_chapter and net.peer_chapter ~= local_chapter() then
        out[#out + 1] = { string.format("Friend is in %s (you're in %s): Go to my friend's chapter in the RE7 Co-op window",
            chapter_name(net.peer_chapter), chapter_name(local_chapter())), 0xFF7FE6FF }
    end
    -- Packets we can't decode usually mean the other player runs another mod version.
    local bad = tonumber(kv.bad or 0) or 0
    if bad > hud.bad_prev then hud.bad_t = os.clock() end
    hud.bad_prev = bad
    if os.clock() - hud.bad_t < 10 then
        out[#out + 1] = { "Friend's packets don't match: check you both have the same coop-re7 version", 0xFF6B6BFF }
    end
    local em = enemy_sync_hud and enemy_sync_hud()
    if em then out[#out + 1] = { em, 0xFF7FE6FF } end
    local wd = world_sync_hud and world_sync_hud()
    if wd then out[#out + 1] = { wd, 0xFF7FE6FF } end
    local sy = story_sync_hud and story_sync_hud()
    if sy then out[#out + 1] = { sy, 0xFF7FE6FF } end
    if revive_hud then
        local rt, rc = revive_hud()
        if rt then out[#out + 1] = { rt, rc } end
    end
    out[#out + 1] = { settings.allow_saving and "Saving: on (backed up)" or "Saving: off", 0xFFBFBFBF }
    return out
end

re.on_frame(function()
    if not (settings and settings.hud) then return end
    local ok, err = pcall(function()
        for i, l in ipairs(hud_lines()) do draw.text(l[1], 16, 16 + (i - 1) * 18, l[2]) end
    end)
    if not ok and not hud.err then hud.err = true log("hud ERR " .. tostring(err)) end
end)

-- Player-vs-ghost collision ------------------------------------------------------
-- The other player's own game keeps them out of walls; here we only stop the
-- local player walking through the ghost. If we overlap a capsule around him,
-- push the local player out along the line between us, via
-- app.MovementController.warp(pos, rot) so RE7's character controller stays in
-- sync (setting the transform directly gets undone).
COLLIDE_RADIUS = 0.6     -- m, both bodies combined
COLLIDE_HEIGHT = 1.7     -- m, vertical overlap that counts as touching
collide = { enabled = true, pushes = 0, err = false }   -- global: the menu (defined earlier) reads it

re.on_frame(function()
    if not (collide.enabled and follow and dummy) or #parts == 0 then return end
    local ok, err = pcall(function()
        local player = get_player()
        if player == nil or ghost_hidden then return end
        -- Only push while the local player is actually walking: never during
        -- cutscenes, loads or scripted moves (a warp there can strand the player).
        local pm = player_movement(player)
        if pm == nil or not safe(pm.call, pm, "get_isMove") then return end
        local ptr = player:call("get_Transform")
        local p = ptr:call("get_Position")
        local g = dummy:call("get_Transform"):call("get_Position")
        if math.abs(p.y - g.y) > COLLIDE_HEIGHT then return end
        local dx, dz = p.x - g.x, p.z - g.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d >= COLLIDE_RADIUS then return end
        if d < 1e-3 then dx, dz, d = 1, 0, 1 end   -- exactly inside: pick a side
        local push = COLLIDE_RADIUS - d
        local np = Vector3f.new(p.x + dx / d * push, p.y, p.z + dz / d * push)
        local mc = player:call("getComponent(System.Type)", sdk.typeof("app.MovementController"))
        if mc == nil then return end
        mc:call("warp(via.vec3, via.Quaternion)", np, ptr:call("get_Rotation"))
        collide.pushes = collide.pushes + 1
        if collide.pushes == 1 then log(string.format("collide: first push %.2f m (warp ok)", push)) end
    end)
    if not ok and not collide.err then collide.err = true log("collide ERR " .. tostring(err)) end
end)

re.on_script_reset(function()
    local destroy = sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)")
    if dummy and destroy then pcall(destroy.call, destroy, nil, dummy) end
    for _, part in ipairs(parts) do if destroy then pcall(destroy.call, destroy, nil, part.go) end end
end)

log("coop_dummy loaded")
