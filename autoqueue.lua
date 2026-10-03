--[[
Queue-T for VLC
Automatically queues later episodes from the current video's folder.

Copyright (c) 2026 AutoQueue contributors
Licensed under the MIT License. See LICENSE.
]]

local VERSION = "1.0.0"
local SIMILARITY = 0.25
local SAME_EXTENSION_ONLY = true

local VIDEO_EXTENSIONS = {
  mp4 = true, mkv = true, avi = true, mov = true, webm = true,
  m4v = true, wmv = true, flv = true, ts = true, mpg = true, mpeg = true,
}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function log(message)
  vlc.msg.info("[Queue-T] " .. tostring(message))
end

local function uri_decode(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function uri_encode(value)
  return (value:gsub("[^%w%-%._~]", function(character)
    return string.format("%%%02X", character:byte())
  end))
end

local function split_extension(filename)
  local base, extension = filename:match("^(.*)%.([^%.]+)$")
  if not base then return filename, "" end
  return base, extension:lower()
end

local function numbers_of(value)
  local numbers = {}
  for number in value:gmatch("%d+") do
    numbers[#numbers + 1] = tonumber(number)
  end
  return numbers
end

local function season_number_from_directory(name)
  local number = name:lower():match("^season%s*(%d+)")
      or name:lower():match("^s(%d+)$")
  return number and tonumber(number) or nil
end

local function episode_less(first, second)
  local first_numbers = numbers_of(first)
  local second_numbers = numbers_of(second)

  for index = 1, math.min(#first_numbers, #second_numbers) do
    if first_numbers[index] ~= second_numbers[index] then
      return first_numbers[index] < second_numbers[index]
    end
  end

  if #first_numbers ~= #second_numbers then
    return #first_numbers < #second_numbers
  end

  return first:lower() < second:lower()
end

local function template(value)
  return (value:lower():gsub("%d+", "#"):gsub("%s+", " "))
end

local function similar(first, second)
  first = template(first)
  second = template(second)
  if first == second then return true end

  local common_length = math.min(#first, #second)
  local prefix_length = 0
  while prefix_length < common_length
      and first:byte(prefix_length + 1) == second:byte(prefix_length + 1) do
    prefix_length = prefix_length + 1
  end

  local suffix_length = 0
  while suffix_length < common_length - prefix_length
      and first:byte(#first - suffix_length) == second:byte(#second - suffix_length) do
    suffix_length = suffix_length + 1
  end

  return (prefix_length + suffix_length) / math.max(#first, #second) >= SIMILARITY
end

local function list_directory(directory)
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

  return nil, last_error or "VLC could not list the directory"
end

local function playlist_uris()
  local uris = {}

  local function walk(node)
    if node.path then
      uris[uri_decode(node.path):lower()] = true
    end
    if node.children then
      for _, child in ipairs(node.children) do
        walk(child)
      end
    end
  end

  local ok, playlist = pcall(vlc.playlist.get, "playlist")
  if not ok then
    return nil, "could not read the playlist: " .. tostring(playlist)
  end
  if playlist then walk(playlist) end

  return uris
end

local function handle(uri)
  log("now playing: " .. tostring(uri))
  if not uri or uri:sub(1, 7) ~= "file://" then
    log("skipping non-file URI")
    return
  end

  local directory_uri, encoded_name = uri:match("^(.*/)([^/]*)$")
  if not directory_uri then
    log("could not split file URI into folder and filename")
    return
  end

  local name = uri_decode(encoded_name)
  local base, extension = split_extension(name)
  if not VIDEO_EXTENSIONS[extension] then
    log("not a supported video extension: " .. extension)
    return
  end

  local directory
  if uri:sub(1, 8) == "file:///" then
    directory = uri_decode(directory_uri:sub(9))
    if not IS_WINDOWS then directory = "/" .. directory end
  else
    directory = "//" .. uri_decode(directory_uri:sub(8))
  end

  local entries, directory_error = list_directory(directory)
  if not entries then
    log("could not read folder " .. directory .. ": " .. directory_error)
    return
  end
  log("folder: " .. directory .. " (" .. #entries .. " entries)")

  local trimmed_directory = directory:gsub("[/\\]+$", "")
  local parent_directory = trimmed_directory:match("^(.*)[/\\][^/\\]+$")
  local parent_uri, encoded_folder_name = directory_uri:match("^(.*)/([^/]*)/$")
  local current_season = season_number_from_directory(uri_decode(encoded_folder_name or ""))
  local season_folders = {
    {
      directory = directory,
      uri = directory_uri,
      season = current_season,
      entries = entries,
    },
  }

  if current_season and parent_directory and parent_uri then
    local sibling_names, parent_error = list_directory(parent_directory)
    if not sibling_names then
      log("could not inspect sibling season folders: " .. parent_error)
    else
      for _, folder_name in ipairs(sibling_names) do
        local season = season_number_from_directory(folder_name)
        if season and season > current_season then
          local season_directory = parent_directory .. "/" .. folder_name
          local season_entries, season_error = list_directory(season_directory)
          if season_entries then
            season_folders[#season_folders + 1] = {
              directory = season_directory,
              uri = parent_uri .. "/" .. uri_encode(folder_name) .. "/",
              season = season,
              entries = season_entries,
            }
          else
            log("could not read season folder " .. season_directory .. ": " .. season_error)
          end
        end
      end
    end
  end

  local later_episodes = {}
  local video_count = 0
  local similar_count = 0
  for _, season_folder in ipairs(season_folders) do
    for _, filename in ipairs(season_folder.entries) do
      local candidate_base, candidate_extension = split_extension(filename)
      if not (season_folder.directory == directory and filename == name)
          and VIDEO_EXTENSIONS[candidate_extension]
          and (not SAME_EXTENSION_ONLY or candidate_extension == extension) then
        video_count = video_count + 1
        if similar(base, candidate_base) then
          similar_count = similar_count + 1
          if (current_season and season_folder.season > current_season)
              or episode_less(base, candidate_base) then
            later_episodes[#later_episodes + 1] = {
              file = filename,
              base = candidate_base,
              season = season_folder.season,
              uri = season_folder.uri,
            }
          end
        end
      end
    end
  end

  table.sort(later_episodes, function(first, second)
    if first.season ~= second.season then
      return first.season < second.season
    end
    return episode_less(first.base, second.base)
  end)

  log("checked " .. video_count .. " video files; " .. similar_count ..
      " matched the name; " .. #later_episodes .. " come after the current episode")

  local existing, playlist_error = playlist_uris()
  if not existing then
    log("ERROR: " .. playlist_error)
    return
  end

  local to_add = {}
  local already_queued = 0
  for _, episode in ipairs(later_episodes) do
    local episode_uri = episode.uri .. uri_encode(episode.file)
    if existing[uri_decode(episode_uri):lower()] then
      already_queued = already_queued + 1
    else
      to_add[#to_add + 1] = { path = episode_uri, name = episode.file }
      log("queueing: " .. episode.file)
    end
  end

  if #to_add == 0 then
    log("nothing to queue: " .. #later_episodes .. " later matching episodes, " ..
        already_queued .. " already in the playlist")
    return
  end

  local ok, added = pcall(vlc.playlist.enqueue, to_add)
  if not ok then
    log("ERROR: playlist.enqueue failed: " .. tostring(added))
  elseif type(added) == "number" then
    log("playlist accepted " .. added .. " of " .. #to_add .. " queued files")
  else
    log("playlist.enqueue returned: " .. tostring(added))
  end
end

log("Queue-T " .. VERSION .. " loaded")
local last_uri
while true do
  local ok, item = pcall(vlc.input.item)
  if ok and item then
    local uri_ok, uri = pcall(function()
      return item:uri()
    end)
    if uri_ok and uri and uri ~= last_uri then
      last_uri = uri
      local handled, handle_error = pcall(handle, uri)
      if not handled then
        log("ERROR: " .. tostring(handle_error))
      end
    end
  end

  local wait_ok, wait_error = pcall(vlc.misc.mwait, vlc.misc.mdate() + 500000)
  if not wait_ok then
    if wait_error ~= "Interrupted." then
      log("ERROR: wait failed: " .. tostring(wait_error))
    end
    break
  end
end
