--[[
  LuaLoop is the single VLC Lua interface that discovers and runs plugins.
  Put each plugin module in lua/intf/plugins as a separate .lua file. A module
  returns a table with optional on_new_item(uri) and tick() functions.
  Debug: Tools > Messages (Ctrl+M), verbosity 2, filter "[lualoop]".
]]

local function log(msg) vlc.msg.info("[lualoop] " .. tostring(msg)) end

LUALOOP_LAUNCHER = true

local sep = package.config:sub(1, 1)

local function candidate_dirs()
  local dirs = {}
  for _, fn in ipairs({ "userdatadir", "datadir" }) do
    if vlc.config and vlc.config[fn] then
      local ok, d = pcall(vlc.config[fn])
      if ok and d then dirs[#dirs + 1] = d end
    end
  end
  return dirs
end

local function list_plugins(directory)
  local listing_functions = {}
  if vlc.net and vlc.net.opendir then
    listing_functions[#listing_functions + 1] = vlc.net.opendir
  end
  if vlc.io and vlc.io.readdir then
    listing_functions[#listing_functions + 1] = vlc.io.readdir
  end

  local last_error
  for _, list in ipairs(listing_functions) do
    local ok, entries = pcall(list, directory)
    if ok and type(entries) == "table" then return entries end
    if not ok then last_error = tostring(entries) end
  end
  return nil, last_error or "VLC could not list the plugin directory"
end

local function plugin_names(entries)
  local names = {}
  for _, entry in ipairs(entries) do
    if type(entry) == "string" then
      local name = entry:match("^([^/\\]+)%.lua$")
      if name and name ~= "" then names[#names + 1] = name end
    end
  end
  table.sort(names, function(first, second)
    return first:lower() < second:lower()
  end)
  return names
end

local function load_plugins()
  local plugins = {}
  local found_directory = false
  local loaded_names = {}
  local first_directory_error
  for _, root in ipairs(candidate_dirs()) do
    local directory = root .. sep .. "lua" .. sep .. "intf" .. sep .. "plugins"
    local entries, err = list_plugins(directory)
    if entries then
      found_directory = true
      local names = plugin_names(entries)
      for _, name in ipairs(names) do
        if not loaded_names[name:lower()] then
          loaded_names[name:lower()] = true
          local path = directory .. sep .. name .. ".lua"
          local chunk, load_error = loadfile(path)
          if not chunk then
            log("could not load " .. path .. ": " .. tostring(load_error))
          else
            local ok, plugin = pcall(chunk)
            if not ok then
              log("failed to run " .. path .. ": " .. tostring(plugin))
            elseif type(plugin) ~= "table" then
              log("ignored " .. path .. ": plugin must return a table")
            elseif type(plugin.on_new_item) ~= "function"
                and type(plugin.tick) ~= "function" then
              log("ignored " .. path .. ": no on_new_item(uri) or tick() function")
            else
              plugins[#plugins + 1] = { name = name, module = plugin }
              log("loaded " .. path)
            end
          end
        end
      end
    elseif err and not first_directory_error then
      first_directory_error = directory .. ": " .. err
    end
  end
  if not found_directory then
    if first_directory_error then
      log("could not inspect plugin directories: " .. first_directory_error)
    else
      log("no plugins directory found; create lua" .. sep .. "intf" .. sep .. "plugins")
    end
  end
  return plugins
end

local plugins = load_plugins()
log(#plugins .. " plugin(s) running")

local last_uri = nil
local waiting_logged = false
local input_error_logged = false
while true do
  local ok, item = pcall(vlc.input.item)
  if not ok then
    if not input_error_logged then
      log("could not read the current VLC input: " .. tostring(item))
      input_error_logged = true
    end
  elseif not item then
    if not waiting_logged then
      log("waiting for a media item")
      waiting_logged = true
    end
  else
    waiting_logged = false
    input_error_logged = false
    local uri_ok, uri = pcall(function()
      return item:uri()
    end)
    if uri_ok and uri and uri ~= last_uri then
      last_uri = uri
      for _, plugin in ipairs(plugins) do
        if plugin.module.on_new_item then
          local ok2, err = pcall(plugin.module.on_new_item, uri)
          if not ok2 then log(plugin.name .. " error: " .. tostring(err)) end
        end
      end
    end
    for _, plugin in ipairs(plugins) do
      if plugin.module.tick then
        local ok3, err3 = pcall(plugin.module.tick)
        if not ok3 then log(plugin.name .. " error: " .. tostring(err3)) end
      end
    end
  end

  local wait_ok, wait_error = pcall(vlc.misc.mwait, vlc.misc.mdate() + 250000)
  if not wait_ok then
    if wait_error ~= "Interrupted." then
      log("wait failed: " .. tostring(wait_error))
    end
    break
  end
end
