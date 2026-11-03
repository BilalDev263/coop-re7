-- coop_saveguard.lua: controls whether the game may save while the co-op mod runs.
--
-- Saving allowed (coop_dummy menu "Allow saving", coop_settings.json allow_saving):
-- everything goes through; CoopNet.cs backs the save folder up at every launch.
--
-- Saving blocked (the default), mode "write" (default): RE7's save flow runs as
-- normal, so scenes that request an autosave and wait for it to finish carry on
-- (skipping the request left the player stuck in Chapter 3's chair, 2026-10-29),
-- but the final disk write, via.storage.saveService.SaveService.saveSingle, is
-- skipped and reported as done. Menu saves (tape recorders) are refused at the
-- request, since nothing waits on them.
-- Mode "strict" (coop_settings.json save_block_mode = "strict"): every save
-- request is skipped, the original v0.1 behaviour.
--
-- Log: <game>/reframework/data/coop_saveguard_log.txt

local REQUESTS = {
    "saveFileAutoRequest",
    "saveFileMenuRequest",
    "saveFileSystemDataRequest",
    "saveFileExpansionDataRequest",
    "saveFileBirthdayDataRequest",
    "saveFileUniqueDataRequest",
}
local MENU_REQUEST = "saveFileMenuRequest"
-- Internal save paths that bypass the requests above: a chapter jump wrote the save
-- folder with saving OFF (2026-10-29 21:03 and 21:22). Always skipped while blocked.
local INTERNAL = {
    "chapterJumpPlayerSave", "chapterJumpPlayerStampSave", "chapterJumpEnemySave",
    "chapterJumpEnemyStampSave", "folderSave", "saveFileSingle", "saveFileAuto", "saveFileMenu",
    "saveFileSystemData", "saveFileSystemDataCore", "saveFileExpansionData", "saveFileExpansionDataCore",
    "saveFileBirthdayData", "saveFileBirthdayDataCore", "saveFileUniqueData", "saveFileUniqueCore",
    "dataSaveA", "dataSaveB", "dataSaveC", "dataSaveD",
}
local WRITES = { "saveSingle()", "saveSingle(System.Int32)", "saveSlotDialog()" }

local lines = {}
local function log_line(s)
    lines[#lines + 1] = os.date("%H:%M:%S ") .. s
    fs.write("coop_saveguard_log.txt", table.concat(lines, "\n"))
end

-- Re-read the shared settings now and then, so the menu switch applies live.
-- Default is "strict": "write" mode let a chapter jump's save reach disk (21:22).
local allow, mode, next_read = false, "strict", 0
local forced_strict = false   -- set when the disk-write hooks couldn't be installed
local function refresh()
    local now = os.clock()
    if now < next_read then return end
    next_read = now + 2
    local ok, s = pcall(json.load_file, "coop_settings.json")
    -- Caught mid-write (empty file, 33 times in the friend's 2026-11-02 log): keep what we
    -- had instead of flipping saving off for 2 s.
    if not ok or type(s) ~= "table" then return end
    local want = s.allow_saving == true
    local want_mode = (not forced_strict and s.save_block_mode == "write") and "write" or "strict"
    if want ~= allow or want_mode ~= mode then
        allow, mode = want, want_mode
        log_line(allow and "saving ALLOWED (backups by CoopNet)"
            or ("saving BLOCKED (" .. (mode == "strict" and "strict: requests skipped" or "disk writes skipped, save flow runs") .. ")"))
    end
end

local hooked, write_hooked = 0, 0

local t = sdk.find_type_definition("app.SaveDataManager")
if t == nil then
    log_line("ERROR app.SaveDataManager not found; guard NOT active")
    return
end
for _, name in ipairs(REQUESTS) do
    local m = t:get_method(name)
    if m == nil then
        log_line("ERROR method not found: " .. name)
    else
        sdk.hook(m, function(args)
            refresh()
            if allow or (mode == "write" and name ~= MENU_REQUEST) then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            log_line("blocked " .. name)
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(retval) return retval end)
        hooked = hooked + 1
    end
end

-- Disk writes: skipped in "write" mode and reported as success.
local svc = sdk.find_type_definition("via.storage.saveService.SaveService")
local skipping = false
for _, sig in ipairs(WRITES) do
    local m = svc and svc:get_method(sig)
    if m == nil then
        log_line("ERROR write method not found: " .. sig .. " (falling back to strict blocking)")
    else
        sdk.hook(m, function(args)
            refresh()
            if allow or mode ~= "write" then skipping = false return sdk.PreHookResult.CALL_ORIGINAL end
            skipping = true
            log_line("blocked disk write " .. sig .. " (reported as done)")
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(retval)
            if skipping then skipping = false return sdk.to_ptr(1) end   -- "request accepted"
            return retval
        end)
        write_hooked = write_hooked + 1
    end
end
if write_hooked < #WRITES then forced_strict, mode = true, "strict" end   -- never let a write through unguarded

local internal_hooked = 0
for _, name in ipairs(INTERNAL) do
    local m = t:get_method(name)
    if m then
        sdk.hook(m, function(args)
            refresh()
            if allow then return sdk.PreHookResult.CALL_ORIGINAL end
            log_line("blocked internal " .. name)
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(retval) return retval end)
        internal_hooked = internal_hooked + 1
    else
        log_line("note: internal save method not present: " .. name)
    end
end
log_line(string.format("internal save paths hooked: %d/%d", internal_hooked, #INTERNAL))

log_line(string.format("guard active: %d/%d save requests, %d/%d disk writes hooked",
    hooked, #REQUESTS, write_hooked, #WRITES))
refresh()

re.on_frame(function() refresh() end)

re.on_draw_ui(function()
    imgui.text(string.format("coop_saveguard: %d+%d hooks, saves %s", hooked, write_hooked,
        allow and "ALLOWED" or ("BLOCKED (" .. mode .. ")")))
end)
