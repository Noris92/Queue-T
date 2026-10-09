--[[
 autobinge.lua  (VLC Lua interface script)

 If the current chapter is named "Credits" (any capitalisation, also
 "End Credits", "Closing credits"...), a countdown shows on screen and after
 5 seconds VLC jumps to the next episode in the playlist.

 To STAY and watch the credits: press PAUSE (space bar or the pause button
 next to the time). Resume afterwards; it will not skip again until the
 credits chapter is left or a new episode starts.

 Works on its own (--lua-intf=autobinge) or as a LuaLoop plugin when
 installed in lua/intf/plugins.

 Debug: Tools > Messages (Ctrl+M), verbosity 2, filter "[autobinge]".
--]]

-- ===================== settings =====================
local CREDITS_DELAY = 5                 -- seconds before jumping to the next episode
local CREDITS_WORDS = { "credit" }      -- chapter name containing any of these = credits
-- ====================================================

local function log(msg) vlc.msg.info("[autobinge] " .. tostring(msg)) end

local osd_chan = nil
local function osd(text)
  if not osd_chan and vlc.osd and vlc.osd.channel_register then
    osd_chan = vlc.osd.channel_register()
  end
  if osd_chan then
    pcall(vlc.osd.message, text, osd_chan, "top", 1300000)
  end
end

local function current_chapter_name()
  local ok, input = pcall(vlc.object.input)
  if not ok or not input then return nil end
  local ok1, cur = pcall(vlc.var.get, input, "chapter")
  if not ok1 or cur == nil then return nil end
  local ok2, values, texts = pcall(vlc.var.get_list, input, "chapter")
  if not ok2 or type(values) ~= "table" then return nil end
  for i, v in ipairs(values) do
    if v == cur then return texts and texts[i] or nil end
  end
  return nil
end

local function is_credits(name)
  if not name then return false end
  local n = name:lower()
  for _, w in ipairs(CREDITS_WORDS) do
    if n:find(w, 1, true) then return true end
  end
  return false
end

local cr = nil  -- state: { start=, cancelled=, last_sec= }

local function on_new_item(uri)
  cr = nil
end

local function tick()
  local name = current_chapter_name()

  if not is_credits(name) then
    cr = nil
    return
  end

  local now = vlc.misc.mdate()
  if not cr then
    cr = { start = now, cancelled = false, last_sec = nil }
    log("credits chapter detected: " .. tostring(name))
  end
  if cr.cancelled then return end

  -- PAUSE = "I want to watch the credits"
  if vlc.playlist.status() == "paused" then
    cr.cancelled = true
    osd("Staying on credits")
    log("skip cancelled by pause")
    return
  end

  local left = CREDITS_DELAY - (now - cr.start) / 1000000
  if left <= 0 then
    cr.cancelled = true -- never fire twice
    log("timeout -> next episode")
    vlc.playlist.next()
    return
  end

  local sec = math.ceil(left)
  if sec ~= cr.last_sec then
    cr.last_sec = sec
    osd("Credits - next episode in " .. sec .. "s (press Pause to stay)")
  end
end

-- ---------- module interface (used by lualoop.lua) ----------
local M = { on_new_item = on_new_item, tick = tick }
if LUALOOP_LAUNCHER then return M end

-- ---------- standalone loop ----------
log("loaded and running (standalone)")
local last_uri = nil
while true do
  local ok, item = pcall(vlc.input.item)
  if ok and item then
    local uri = item:uri()
    if uri and uri ~= last_uri then
      last_uri = uri
      M.on_new_item(uri)
    end
    local ok2, err = pcall(M.tick)
    if not ok2 then log("ERROR: " .. tostring(err)) end
  end
  local wait_ok, wait_error = pcall(vlc.misc.mwait, vlc.misc.mdate() + 250000)
  if not wait_ok then
    if wait_error ~= "Interrupted." then
      log("wait failed: " .. tostring(wait_error))
    end
    break
  end
end
