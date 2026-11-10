-- MX Bikes Tracks in BeamNG: in-game side.
-- Announces the MX Bikes track when one loads, and runs Melty's test mode when
-- Melty's bridge has put its test file in the user folder.
local M = {}
local logTag = 'mxbikesTracks'

local TRACKS_FILE = '/mxbikes_tracks/tracks.json'
local TEST_FILE = '/settings/mxbikes_tracks/melty_test.json'
local CHECKS_FILE = '/settings/mxbikes_tracks/checks.txt'

local tracks = {}
local trackById = {}
local test = nil          -- table from Melty's test file while a test runs
local checkLines = {}
local reported = {}
local t = 0
local pollAt = 0
local phase = 'wait'      -- wait -> loading -> settle -> drive -> done
local phaseAt = 0
local testLevel = nil
local startPos = nil
local stateAt = 0
local STATE_FILE = '/settings/mxbikes_tracks/state.json'

local function report(name, ok, why)
  if reported[name] then return end
  reported[name] = true
  local line = (ok and 'pass ' or 'fail ') .. name .. ((not ok and why) and (': ' .. why) or '')
  table.insert(checkLines, line)
  writeFile(CHECKS_FILE, table.concat(checkLines, '\n') .. '\n')
  log('I', logTag, 'Melty check: ' .. line)
end

local function loadTracks()
  local data = jsonReadFile(TRACKS_FILE)
  tracks = type(data) == 'table' and data or {}
  trackById = {}
  for _, tr in ipairs(tracks) do trackById[tr.id] = tr end
  log('I', logTag, 'MX Bikes tracks available in BeamNG: ' .. #tracks)
end

local function currentTrack()
  local mis = getMissionFilename() or ''
  local id = mis:match('/levels/(mxb_[^/]+)/') or mis:match('levels/(mxb_[^/]+)/')
  return id and trackById[id], id
end

local function pickTestLevel()
  local preferred = { 'mxb_motocross_club_club', 'mxb_motocross_forest_forest', 'mxb_widowmaker_widowmaker' }
  local available = {}
  for _, id in ipairs(preferred) do if trackById[id] then table.insert(available, id) end end
  if #available > 0 then return available[((tonumber(test and test.run) or 1) - 1) % #available + 1] end
  if #tracks == 0 then return nil end
  local seed = (test and tonumber(test.seed)) or 1
  return tracks[(math.floor(seed) % #tracks) + 1].id
end

local function levelKnown(id)
  if not core_levels or not core_levels.getLevelByName then return true end
  return core_levels.getLevelByName(id) ~= nil
end

local function onExtensionLoaded()
  loadTracks()
end

local function onWorldReadyState(state)
  if state ~= 2 then return end
  local tr = currentTrack()
  if tr then
    guihooks.trigger('Message', { ttl = 10, msg = 'MX Bikes track: ' .. tostring(tr.name) .. '. Pick any car and send it!', icon = 'flag', category = 'mxbikesTracks' })
  end
end

local function updateTest(dt)
  local veh = be and be:getPlayerVehicle(0)
  if phase == 'wait' then
    if #tracks == 0 then loadTracks() end
    if #tracks == 0 then
      if t > 60 then report('tracks-built', false, 'no tracks in tracks.json'); phase = 'done' end
      return
    end
    testLevel = pickTestLevel()
    if not levelKnown(testLevel) then
      if t > 60 then report('tracks-built', false, 'level ' .. tostring(testLevel) .. ' not in level list'); phase = 'done' end
      return
    end
    report('tracks-built', true)
    if getMissionFilename() ~= '' and select(2, currentTrack()) == testLevel then
      phase = 'loading'; phaseAt = t; return
    end
    if t < 8 then return end -- let the main menu settle
    if not freeroam_freeroam then extensions.load('freeroam_freeroam') end
    local ok = freeroam_freeroam and freeroam_freeroam.startFreeroamByName(testLevel)
    log('I', logTag, 'test: starting ' .. tostring(testLevel) .. ' -> ' .. tostring(ok))
    phase = 'loading'; phaseAt = t
  elseif phase == 'loading' then
    local _, id = currentTrack()
    if id == testLevel and scenetree.findObject('theTerrain') and veh then
      report('level-loaded', true)
      -- Use a stock vehicle for the unattended check, independent of the creator's
      -- last custom car, ignition state, or realistic/manual gearbox preferences.
      core_vehicles.replaceVehicle('pickup', {config = 'vehicles/pickup/d15_4wd_A.pc'})
      phase = 'prepare'; phaseAt = t
    elseif t - phaseAt > 150 then
      report('level-loaded', false, 'level ' .. tostring(testLevel) .. ' did not load with a car in 150 s (mission ' .. tostring(getMissionFilename()) .. ')')
      phase = 'done'
    end
  elseif phase == 'prepare' then
    if not veh or t - phaseAt < 5 then return end
    veh:queueLuaCommand('controller.mainController.setGearboxMode("arcade"); electrics.setIgnitionLevel(3); input.event("parkingbrake", 0, FILTER_DIRECT); input.event("clutch", 0, FILTER_DIRECT)')
    phase = 'settle'; phaseAt = t
  elseif phase == 'settle' then
    if not veh then return end
    if t - phaseAt < 10 then return end
    local pos = veh:getPosition()
    local h = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)
    if h and math.abs(pos.z - h) < 3 then
      report('car-on-track', true)
    else
      report('car-on-track', false, 'car z ' .. tostring(pos.z) .. ' terrain ' .. tostring(h))
    end
    startPos = vec3(pos)
    veh:queueLuaCommand('input.event("parkingbrake", 0, FILTER_DIRECT) input.event("brake", 0, FILTER_DIRECT) input.event("throttle", 0.6, FILTER_DIRECT)')
    phase = 'drive'; phaseAt = t
  elseif phase == 'drive' then
    if not veh then return end
    local d = veh:getPosition():distance(startPos)
    if d > 15 then
      report('car-drives', true)
      veh:queueLuaCommand('input.event("throttle", 0, FILTER_DIRECT) input.event("brake", 0, FILTER_DIRECT)')
      phase = 'done'
    elseif t - phaseAt > 25 then
      report('car-drives', false, 'moved only ' .. string.format('%.1f', d) .. ' m in 25 s')
      veh:queueLuaCommand('input.event("throttle", 0, FILTER_DIRECT)')
      phase = 'done'
    else
      -- keep the throttle held (a gear change or reset can drop it)
      veh:queueLuaCommand('input.event("throttle", 0.6, FILTER_DIRECT)')
    end
  end
end

local function onUpdate(dtReal)
  t = t + (dtReal or 0)
  if t >= pollAt then
    pollAt = t + 1
    local current = nil
    if FS:fileExists(TEST_FILE) then
      current = jsonReadFile(TEST_FILE)
    end
    if current and math.abs(os.time() - (tonumber(current.mxbBridgeHeartbeat) or 0)) <= 8 then
      if not test then
        test = current
        log('I', logTag, 'Melty test mode: run ' .. tostring(test.run) .. ' of ' .. tostring(test.runs))
        checkLines = {}; reported = {}; phase = 'wait'
      else
        test = current
      end
    elseif test and (math.abs(os.time() - (tonumber(test.mxbBridgeHeartbeat) or 0)) > 8 or not FS:fileExists(TEST_FILE)) then
      local veh = be and be:getPlayerVehicle(0)
      if veh then veh:queueLuaCommand('input.event("throttle", 0, FILTER_DIRECT); input.event("brake", 0, FILTER_DIRECT)') end
      test = nil
    end
  end
  if test and phase ~= 'done' then
    local ok, err = pcall(updateTest, dtReal)
    if not ok then log('E', logTag, 'test step failed: ' .. tostring(err)) end
  end
  if test and t >= stateAt then
    stateAt = t + 1
    local veh = be and be:getPlayerVehicle(0)
    local pos = veh and veh:getPosition()
    local state = {phase = phase, level = testLevel, maps = #tracks, originalScenery = scenetree.findObject('mxb_original_scenery') ~= nil, checks = checkLines}
    if pos then state.position = {x = pos.x, y = pos.y, z = pos.z} end
    if veh then state.speed = veh:getVelocity():length() end
    jsonWriteFile(STATE_FILE, state, true)
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate
M.status = function() return { tracks = #tracks, test = test ~= nil, phase = phase, level = testLevel, checks = checkLines } end

return M
