-- gtaBridge: BeamNG <-> GTA V bridge (BeamNG side)
--
-- GTA V (running in the background with the BeamBridge script) owns the character:
-- its on-foot controls, animation, combat, ragdoll. This extension
--   * receives the ped state + skeleton from GTA over UDP and drives BeamNG's walking
--     character (the "unicycle") so the body is rendered/lit/collided by BeamNG,
--   * sends the BeamNG camera direction to GTA so GTA's movement is camera-relative,
--   * sends nearby BeamNG vehicles (oriented boxes) and the ground height under the ped
--     to GTA, which turns them into invisible collision proxies.
--
-- Console usage (press ~ in BeamNG):
--   extensions.gtaBridge.start()      open the UDP link
--   extensions.gtaBridge.align()      map the current GTA ped position onto where you stand now
--   extensions.gtaBridge.engage()     start driving the walker from GTA
--   extensions.gtaBridge.disengage()
--   extensions.gtaBridge.status()
--   extensions.gtaBridge.set("yawDeg", 90)   (see cfg below for keys)

local M = {}
local logTag = "gtaBridge"

local socket = require("socket.socket") -- LuaSocket, same module BeamNG's own tcpServer.lua uses

local cfgPath = "/settings/gtaBridge.json"
local cfg = {
  host = "127.0.0.1",
  gtaPort = 47200,       -- GTA script listens here
  listenPort = 47201,    -- we listen here
  yawDeg = 0,            -- rotation GTA world -> BeamNG world (degrees, CCW)
  ox = 0, oy = 0, oz = 0,-- translation GTA world -> BeamNG world (applied after rotation)
  anchorX = 5000, anchorY = 5000, anchorZ = 60, -- where in GTA the pinned ped lives: open ocean far SW of the map, no city/traffic to stream
  compose = true,        -- ReShade composite mode: GTA renders Michael from BeamNG's camera and the frame is pasted in; no BeamNG body/puppet
  fovMul = 1.0,          -- GTA vertical FOV = BeamNG FOV * this (tune if Michael looks too big/small)
  syncTime = true,       -- GTA clock follows BeamNG time of day
  swim = true,           -- where BeamNG's water is deeper than he can stand, GTA swims him (and the part of him under water is faded in the picture)
  walls = true,          -- walls and fences near him are stood up in GTA as invisible barriers: they stop him, and Space vaults / climbs the ones he can
  bodySpeed = 2.0,       -- ... but only while a car near him moves faster than this (m/s); next to parked cars it is put away
  bodyNear = 15,         -- "near" (m)
  bodyCollide = true,    -- an invisible physical Michael in BeamNG (vehicles/gta_body): cars that hit him dent, glass breaks, wheels ride over him
cars = true,           -- BeamNG vehicles near Michael also exist in GTA (invisible stand-ins): he bumps into them and can get in
  carRadius = 40,        -- metres around Michael
  carMax = 6,            -- at most this many, nearest first
enterAnim = true,
  headTop = 0.17,        -- top of Michael's head above GTA's head bone (m); raise/lower if he sits a little low/high in cars
  doorPush = 80,         -- extra push on BeamNG's door when Michael opens it (N, on top of the car's own small pop) ...
  doorPushTime = 0.4,    -- ... for this long (s)
  doorHold = 30,         -- gentle push that keeps it open against the stop afterwards (so it neither bounces shut nor re-latches)
  wheelSlowMo = 0.2,     -- how slowly both games run while the weapon wheel is up (1 = full speed)
  wheelGhost = 0.3,      -- how solid Michael stays while one of BeamNG's wheels is drawn over him (0 = gone, 1 = fully there, covering it)
  bullets = true,        -- his shots land in BeamNG: a mark where they hit and a small push on the car they hit
  bulletRange = 300,     -- metres
  bulletPush = 6,        -- what one bullet gives the panel it hits, newton-seconds (0 = none; a real pistol round is about 3)
  bulletHoles = 80,      -- how many bullet marks are kept (the oldest go first)
  holeSize = 0.018,      -- radius of a mark, m
  tracer = 0.12,         -- how long the streak from the gun to where the shot lands stays, seconds (0 = none)
  wheelHold = 0.18,      -- Tab held this long brings the wheel up; let go sooner and it is a tap: fists, or back to the last gun
  busDoorForce = 150,    -- city bus: extra pull on each front door cylinder while he gets in (N); its own spring opens the doors far too slowly
  doorPull = 130,        -- short pull when he shuts it ...
  doorPullTime = 0.35,   -- ... for this long (s)      -- F: Michael walks to the door and gets in (GTA animation) before BeamNG switches to driving
  runPace = 1.5,         -- how fast Michael moves with W: GTA move blend (1 = walk, 2 = GTA's normal run, 3 = sprint)
  sprintPace = 2.5,      -- ... with Shift held
  sunFlip = false,       -- set true if Michael's shadow points the opposite way to BeamNG's own shadows
  predict = true,        -- aim GTA's camera ahead by the measured pipeline latency so Michael's picture arrives roughly in sync with the BeamNG camera
  predictGain = 0.8,     -- 1 = full extrapolation, lower = calmer (less overshoot when the mouse stops)
  autoEngage = true,     -- engage() by itself once a level is loaded and GTA is streaming (no console needed; console + ReShade + overlays can crash BeamNG)
  usePuppet = true,      -- real Michael mesh on a puppet vehicle; false = old cylinder mannequin
  renderBody = true,     -- draw the character as lit BeamNG scene objects (art/shapes/gtaBridge)
  flipQuat = false,      -- set true if the body segments are rotated the wrong way
  sendVehicles = false,  -- BeamNG vehicles -> GTA collision proxies (only useful for bullets; the BeamNG walker already collides natively)
  vehicleRadius = 120,   -- only send vehicles this close to the walker (BeamNG metres)
  vehicleHz = 30,
  maxVehicles = 40,
  drawSkeleton = false,  -- green debug skeleton + red head marker
  usePlatform = true,    -- GTA keeps an invisible platform under the ped so it has ground contact
  staleTimeout = 1.5,
  thirdPerson = true,    -- GTA-style chase camera around Michael (mouse looks, camera follows)
  camDist = 3.2,         -- metres behind the head
  camShoulder = 0.45,    -- metres to the right (over-the-shoulder)
  camHeight = 0.2,       -- metres above the head joint
  camPivotRate = 12,     -- pivot follow stiffness (higher = tighter)
  camPushOut = 3,        -- how slowly the camera eases back out after a wall pop-in
}

local udp
local running = false
local engaged = false
local yawRad = 0
local seq = 0
local lastVehSend = 0
local ped = { fresh = false, t = 0 }
local slow = 1   -- how fast GTA is running: below 1 only while the weapon wheel is up (his speeds are per GTA second)
local stat = { frames = 0, pkts = 0, t = 0, puppetN = 0, puppetT = 0, puppetRate = 0 }
local restDumped = false
local walkerId

-- ---------------------------------------------------------------- helpers

local function applyConfig()
  yawRad = math.rad(cfg.yawDeg)
end

local function loadConfig()
  local ok, data = pcall(jsonReadFile, cfgPath)
  if ok and type(data) == "table" then
    for k, v in pairs(data) do
      if cfg[k] ~= nil and k ~= "anchorX" and k ~= "anchorY" and k ~= "anchorZ" and k ~= "drawSkeleton" and k ~= "compose" then cfg[k] = v end
    end
  end
  applyConfig()
end

local function saveConfig()
  pcall(jsonWriteFile, cfgPath, cfg, true)
end

local function rotZ(x, y, a)
  local c, s = math.cos(a), math.sin(a)
  return c * x - s * y, s * x + c * y
end

local function gtaToBeam(x, y, z)
  local rx, ry = rotZ(x, y, yawRad)
  return rx + cfg.ox, ry + cfg.oy, z + cfg.oz
end

local function beamToGta(x, y, z)
  local rx, ry = rotZ(x - cfg.ox, y - cfg.oy, -yawRad)
  return rx, ry, z - cfg.oz
end

local function dirToBeam(x, y, z)
  local rx, ry = rotZ(x, y, yawRad)
  return rx, ry, z
end

local function dirToGta(x, y, z)
  local rx, ry = rotZ(x, y, -yawRad)
  return rx, ry, z
end

-- split on a single-character separator, keeping empty fields
local function split(s, sep)
  local out, n, start = {}, 0, 1
  while true do
    local i = string.find(s, sep, start, true)
    n = n + 1
    if not i then
      out[n] = string.sub(s, start)
      break
    end
    out[n] = string.sub(s, start, i - 1)
    start = i + 1
  end
  return out
end

local function send(str)
  if not udp then return end
  pcall(udp.sendto, udp, str, cfg.host, cfg.gtaPort)
end

-- rotation matrix columns (right, forward, up) -> quaternion x,y,z,w
local function quatFromBasis(rx, ry, rz, fx, fy, fz, ux, uy, uz)
  local m00, m01, m02 = rx, fx, ux
  local m10, m11, m12 = ry, fy, uy
  local m20, m21, m22 = rz, fz, uz
  local tr = m00 + m11 + m22
  local x, y, z, w
  if tr > 0 then
    local s = math.sqrt(tr + 1) * 2
    w = 0.25 * s; x = (m21 - m12) / s; y = (m02 - m20) / s; z = (m10 - m01) / s
  elseif m00 > m11 and m00 > m22 then
    local s = math.sqrt(1 + m00 - m11 - m22) * 2
    w = (m21 - m12) / s; x = 0.25 * s; y = (m01 + m10) / s; z = (m02 + m20) / s
  elseif m11 > m22 then
    local s = math.sqrt(1 + m11 - m00 - m22) * 2
    w = (m02 - m20) / s; x = (m01 + m10) / s; y = 0.25 * s; z = (m12 + m21) / s
  else
    local s = math.sqrt(1 + m22 - m00 - m11) * 2
    w = (m10 - m01) / s; x = (m02 + m20) / s; y = (m12 + m21) / s; z = 0.25 * s
  end
  return x, y, z, w
end

-- ---------------------------------------------------------------- GTA -> BeamNG

-- 18 skeleton points, GTA order (see BeamBridge.cs): pelvis, spine3, neck, head,
-- L clavicle/upper/fore/hand, R clavicle/upper/fore/hand, L thigh/calf/foot, R thigh/calf/foot
local bones = {
  {1, 2}, {2, 3}, {3, 4},
  {3, 5}, {5, 6}, {6, 7}, {7, 8},
  {3, 9}, {9, 10}, {10, 11}, {11, 12},
  {1, 13}, {13, 14}, {14, 15},
  {1, 16}, {16, 17}, {17, 18},
}

local skHist = {}   -- the last few skeletons GTA sent: { t, sk, gx, gy, gz }
-- How old a packet from GTA is when it is read. GTA stamps each with its own clock; (read time - stamp) is the two clocks' offset plus
-- however long the packet waited to be read, and the smallest of the last couple of seconds is the offset alone (near enough: a constant
-- error only moves him by a constant amount). Without this every packet counted as brand new, though some were a whole GTA frame old:
-- at a run that is 7 cm, forwards and back, from one BeamNG frame to the next.
local clk = {}
local function packetAge(now, gt)
  clk[#clk + 1] = now - gt
  if #clk > 120 then table.remove(clk, 1) end
  local least = math.huge
  for i = 1, #clk do least = math.min(least, clk[i]) end
  return math.min(0.1, now - gt - least)
end

-- >>> checked by tools/check_guns.lua
-- What he carries, in the order the GTA script holds them (its Loadout list). slot = where each sits in the weapon wheel, the same
-- places as in GTA's: pistol at the top, SMG top right, rifle right, fists at the bottom, shotgun bottom left. (BeamNG numbers its
-- wheel 1 left, 3 up, 5 right, 7 down, the even numbers in between.) icon = a file in ui/modules/apps/RadialMenu/mods_icons.
local LOADOUT = {
  { hash = 0xA2719263, name = "Unarmed", slot = 7, icon = "gta_unarmed.svg" },
  { hash = 0x1B06D571, name = "Pistol", slot = 3, icon = "gta_pistol.svg" },
  { hash = 0x2BE6766B, name = "SMG", slot = 4, icon = "gta_smg.svg" },
  { hash = 0x83BF0278, name = "Carbine Rifle", slot = 5, icon = "gta_rifle.svg" },
  { hash = 0x1D073A89, name = "Pump Shotgun", slot = 8, icon = "gta_shotgun.svg", pellets = 6 },
}
local WEAPON = {}   -- the same, by GTA's weapon id
for _, w in ipairs(LOADOUT) do WEAPON[w.hash] = w end
-- <<< checked
local lastWeapon

local function parsePed(f)
  -- P|seq|x|y|z|heading|vx|vy|vz|flags|weapon|health|sk(54 floats csv)|GTA's clock
  ped.seq = tonumber(f[2]) or 0
  stat.pkts = stat.pkts + 1
  ped.gx, ped.gy, ped.gz = tonumber(f[3]) or 0, tonumber(f[4]) or 0, tonumber(f[5]) or 0
  ped.heading = tonumber(f[6]) or 0
  ped.vx, ped.vy, ped.vz = tonumber(f[7]) or 0, tonumber(f[8]) or 0, tonumber(f[9]) or 0
  ped.flags = tonumber(f[10]) or 0
  ped.weapon = (tonumber(f[11]) or 0) % 4294967296
  if ped.weapon ~= lastWeapon then
    if lastWeapon and WEAPON[ped.weapon] then pcall(ui_message, WEAPON[ped.weapon].name, 2, "gtaBridgeWeapon") end
    lastWeapon = ped.weapon
  end
  ped.health = tonumber(f[12]) or 0
  local sk = {}
  if f[13] and f[13] ~= "" then
    local n = 0
    for v in string.gmatch(f[13], "[^,]+") do
      n = n + 1
      sk[n] = tonumber(v) or 0
    end
  end
  -- how many shots he has fired so far, counted by GTA: the new ones are owed a bullet in BeamNG (tick)
  local shots = tonumber(f[15])
  if shots and ped.shots and shots > ped.shots then ped.shotsDue = math.min(8, (ped.shotsDue or 0) + shots - ped.shots) end
  ped.shots = shots or ped.shots
  local now = socket.gettime()
  local gt = tonumber(f[14])
  if gt then now = now - packetAge(now, gt) end   -- when it was made, on this side's clock
  ped.sk = sk
  ped.t = now
  if #sk >= 54 then
    skHist[#skHist + 1] = { t = now, sk = sk, gx = ped.gx, gy = ped.gy, gz = ped.gz }
    if #skHist > 24 then table.remove(skHist, 1) end
  end
  ped.fresh = true
end

local leadSec = 0.05   -- smoothed pipeline latency reported by the add-on
local function pump()
  if not udp then return end
  for _ = 1, 64 do
    local data = udp:receive()
    if not data then break end
    if data:sub(1, 2) == "P|" then
      parsePed(split(data, "|"))
    elseif data:sub(1, 2) == "D|" then   -- GTA's script reporting something it did
      log("I", logTag, "gta: " .. data:sub(3))
    elseif data:sub(1, 2) == "A|" then   -- from the ReShade add-on: how old GTA's picture is when shown (ms)
      local ms = tonumber(data:sub(3))
      if ms then leadSec = leadSec * 0.9 + math.max(0.02, math.min(0.1, ms / 1000)) * 0.1 end
    end
  end
  if ped.fresh and socket.gettime() - ped.t > cfg.staleTimeout then
    ped.fresh = false
  end
end

local function getWalker()
  local walk = extensions.gameplay_walk
  if not walk then return nil end
  return walk.getCurrentUnicycle()
end

local function ensureWalker(bx, by, bz)
  extensions.load("gameplay_walk")
  local walk = extensions.gameplay_walk
  if not walk then
    log("E", logTag, "gameplay_walk extension not available")
    return nil
  end
  if not walk.isWalking() then
    walk.setWalkingMode(true, vec3(bx, by, bz), nil, true)
  end
  return walk.getCurrentUnicycle()
end

-- BeamNG's walker (the player's own unicycle, moved by BeamNG's collision and terrain) is the source of
-- truth for where the character stands. GTA gets its feet position every frame and pins the ped to it.
local walkerFeet = vec3()
local walkerHave = false
local needOffset = false
-- After the offset is chosen GTA still has to put the ped on the anchor (T). Until he is really there his reported position is
-- somewhere else entirely, so nothing that depends on it runs: no picture, no shadow, no physical body, no F.
local arriveT          -- when T was sent; nil once he has arrived
local bodyHoldT = 0    -- the physical body stays parked until then (a moment longer than the picture: a car he bails out of rolls past first)
local function settled() return not needOffset and not arriveT end
local tpCheck, tpSent, tpTries = false, 0, 0   -- keep resending T until GTA's ped is actually at the anchor
local offsetAt = 0   -- engage(): the freshly spawned walker reports (0,0,0) for a moment, so wait before anchoring

local function moveVeh(u, pos)
  local ok, r = pcall(u.getRotation, u)
  if ok and r then
    return pcall(u.setPositionRotation, u, pos.x, pos.y, pos.z, r.x, r.y, r.z, r.w)
  end
  return pcall(u.setPositionRotation, u, pos.x, pos.y, pos.z, 0, 0, 0, 1)
end
local lastGround
local dbgT = 0

-- ---- water: how high BeamNG's water stands over a spot (nil = none there) ----
-- ponytail: oceans (WaterPlane) and box-shaped lakes (WaterBlock, taken as unrotated) only; rivers are not water yet
local waters
local function findWaters()
  waters = {}
  for _, cls in ipairs({ "WaterPlane", "WaterBlock" }) do
    for _, name in ipairs(scenetree.findClassObjects(cls) or {}) do
      local ok, p, s = pcall(function() local o = scenetree.findObject(name) return o:getPosition(), o:getScale() end)
      if ok and p and cls == "WaterPlane" then
        waters[#waters + 1] = { z = p.z }
        log("I", logTag, string.format("water: %s '%s' at height %.2f", cls, tostring(name), p.z))
      elseif ok and p and s then
        -- the surface is at the object's own height (the box hangs below it): taking the top of the box had him "swimming" on the
        -- dry ground around a quarry pond, metres above the water
        waters[#waters + 1] = { z = p.z, x0 = p.x - s.x * 0.5, x1 = p.x + s.x * 0.5, y0 = p.y - s.y * 0.5, y1 = p.y + s.y * 0.5 }
        log("I", logTag, string.format("water: %s '%s' centre (%.1f, %.1f, %.2f) size (%.1f, %.1f, %.2f)", cls, tostring(name), p.x, p.y, p.z, s.x, s.y, s.z))
      else
        log("W", logTag, string.format("water: could not read %s '%s': %s", cls, tostring(name), tostring(p)))
      end
    end
  end
  if #waters == 0 then log("I", logTag, "water: none found on this map") end
end
local function waterAt(x, y)
  if not cfg.swim then return nil end
  if not waters then findWaters() end
  local best
  for _, w in ipairs(waters) do
    if (not w.x0 or (x >= w.x0 and x <= w.x1 and y >= w.y0 and y <= w.y1)) and (not best or w.z > best) then best = w.z end
  end
  return best
end
local walkerWater   -- over where he is now
local FOOT = { { 0.2, 0 }, { -0.2, 0 }, { 0, 0.2 }, { 0, -0.2 } }   -- his footprint, for the ground rays
local dropN = 0
local function readWalker()
  local u = getWalker()
  if not u then walkerHave = false return nil end
  walkerId = u:getID()
  local p = u:getPosition()
  if not needOffset and ped.fresh and lastGround then
    -- GTA drives: the walker is only a camera carrier, dragged to wherever the GTA ped is.
    -- BeamNG supplies height: ground under the ped's XY (static collision), sent back to GTA.
    -- GTA reports ~30-60 times a second; carry the ped along its velocity in between so he (and the camera on him) moves every BeamNG frame, not in steps
    local ex = slow * math.max(0, math.min(0.08, socket.gettime() - ped.t))
    local bx, by = gtaToBeam(ped.gx + (ped.vx or 0) * ex, ped.gy + (ped.vy or 0) * ex, ped.gz)
    -- BeamNG's ground under him: the highest thing under his footprint that he could be standing on, i.e. not more than a step
    -- above his feet (his real feet, from GTA: in a jump, on top of something, or falling they are not at the old ground). Four
    -- rays, not one: he only goes over an edge when all of him is past it, and one ray slipping through a seam in the map cannot
    -- drop him. A drop also has to be there three times running before it counts. GTA then lets him fall (see zoff there).
    local feet = lastGround
    -- (not in the middle of a climb or vault: the wall he is going over must not become the ground for those few frames)
    if settled() and ped.gz and math.floor((ped.flags or 0) / 64) % 2 == 0 then
      feet = ped.gz + cfg.oz - 1.0
      if math.floor((ped.flags or 0) / 65536) % 2 == 1 then feet = ped.gz + cfg.oz - 0.5   -- swimming: he lies flat at the surface, the bottom is whatever is under that
      elseif ped.sk and #ped.sk >= 54 then
        -- His lowest joint is what touches (an ankle, 10 cm above the sole; knocked down, whatever he lies on). "A metre under his
        -- middle" was wrong whenever he was not upright: crouched on top of a wall he had just climbed, his feet were put 40 cm
        -- inside it, so its top never became his ground and he dropped through as soon as he stepped off the edge.
        local low = math.huge
        for i = 3, 54, 3 do low = math.min(low, ped.sk[i]) end
        feet = low + cfg.oz - ((ped.flags or 0) % 2 == 1 and 0.05 or 0.10)
      end
    end
    local best
    for i = 1, 4 do
      local ok, d = pcall(castRayStatic, vec3(bx + FOOT[i][1], by + FOOT[i][2], feet + 0.9), vec3(0, 0, -1), 80)
      if ok and d and d < 80 then
        local g = feet + 0.9 - d
        if g <= feet + 0.45 and (not best or g > best) then best = g end
      end
    end
    if best then
      if best >= lastGround - 0.6 then
        lastGround, dropN = best, 0
      else
        dropN = dropN + 1
        if dropN >= 3 then lastGround, dropN = best, 0 end
      end
    end
    walkerFeet:set(bx, by, lastGround)
    walkerWater = waterAt(bx, by)
    local tgt = vec3(bx, by, lastGround - 1.6)   -- third person: roller sunk under the road, hidden
    local okc, gname = pcall(core_camera.getActiveGlobalCameraName)
    if okc and not gname and ped.sk and #ped.sk >= 12 then
      -- first person: the walk camera sits at the walker's driver node, so park the walker such that
      -- the camera lands at Michael's eyes (head joint, a little forward and up)
      local hx, hy, hz = gtaToBeam(ped.sk[10], ped.sk[11], ped.sk[12])
      local h = math.rad(ped.heading or 0)
      local fx, fy = rotZ(-math.sin(h), math.cos(h), yawRad)
      local okn, n = pcall(function()
        local cn = core_camera.getDriverData(u)
        return vec3(u:getNodePosition(cn or 0))
      end)
      tgt = vec3(hx + fx * 0.12, hy + fy * 0.12, hz + 0.07) - (okn and n or vec3(0, 0, 1.6))
    end
    moveVeh(u, tgt)
    if socket.gettime() - dbgT > 2 then
      dbgT = socket.gettime()
      local gp = u:getPosition()
      log("I", logTag, string.format("dbg fpv=%s ground=%.2f walker=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f) globalCam=%s",
        tostring(okc and not gname), lastGround, gp.x, gp.y, gp.z, tgt.x, tgt.y, tgt.z, tostring(gname)))
    end
    pcall(u.setMeshAlpha, u, 0, "", false)   -- BeamNG re-fades it each frame; we win by running after
    walkerHave = true
    return u
  end
  local gz = p.z
  local ok, d = pcall(castRayStatic, vec3(p.x, p.y, p.z + 3), vec3(0, 0, -1), 14)   -- from above: the walker may be parked below the road
  if ok and d and d < 14 then gz = p.z + 3 - d end
  walkerFeet:set(p.x, p.y, gz)
  walkerWater = waterAt(p.x, p.y)
  lastGround = gz
  walkerHave = true
  return u
end

-- choose the GTA<->BeamNG offset so the walker's current spot is the GTA anchor
local function computeOffset()
  if not readWalker() then return false end
  local rx, ry = rotZ(cfg.anchorX, cfg.anchorY, yawRad)
  cfg.ox = walkerFeet.x - rx
  cfg.oy = walkerFeet.y - ry
  cfg.oz = walkerFeet.z - cfg.anchorZ
  saveConfig()
  log("I", logTag, string.format("anchored: offset = %.2f, %.2f, %.2f", cfg.ox, cfg.oy, cfg.oz))
  return true
end

local function sendWalker()
  if not (engaged and readWalker()) then return end
  local gx, gy, gz = beamToGta(walkerFeet.x, walkerFeet.y, walkerFeet.z)
  seq = seq + 1
  send(string.format("W|%d|%.3f|%.3f|%.3f|%.3f", seq, gx, gy, gz, walkerWater and (walkerWater - cfg.oz) or -9999))
end

-- ---- body: lit, shadow-casting BeamNG scene objects (TSStatic) posed from GTA's skeleton ----
-- Nothing special is needed for lighting: any object in the scene goes through BeamNG's normal
-- deferred pass. Only debugDrawer lines (the green skeleton) skip it.
local limbShape = "/art/shapes/gtaBridge/limb.dae"
local ballShape = "/art/shapes/gtaBridge/ball.dae"
-- thickness per entry of `bones`
local thickness = {0.30, 0.26, 0.10,  0.09, 0.10, 0.09, 0.07,  0.09, 0.10, 0.09, 0.07,  0.12, 0.14, 0.10,  0.12, 0.14, 0.10}
local segs, head = {}, nil
local bodyErr
local puppetId, puppetLoadedAt, puppetErr   -- the streamed GTA character is a fixed-node "puppet" vehicle (see vehicles/gta_puppet)

local function newObj(shape, name)
  local o = createObject("TSStatic")
  if not o then return nil end
  o:setField("shapeName", 0, shape)
  o:setField("collisionType", 0, "None")
  o:registerObject(name)
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(o) end
  return o
end

-- ---- a physical Michael in BeamNG ----
-- An invisible, mesh-less vehicle (vehicles/gta_body): 14 nodes weighing what he weighs, pulled towards GTA's joints by a bounded
-- force (lua/vehicle/extensions/gtaBody.lua). A car that hits him hits 95 kg: panels dent, glass breaks, wheels ride over him.
local bodyId, bodySpawnT, bodyLoaded, bodyParked
local function bodyVeh()
  local v = bodyId and be:getObjectByID(bodyId)
  if v then return v end
  for i = 0, be:getObjectCount() - 1 do
    local o = be:getObject(i)
    local ok, jb = pcall(o.getJBeamFilename, o)
    if ok and jb == "gta_body" then bodyId = o:getId() return o end
  end
  bodyId = nil
end
local function parkBody()   -- out of the way (held high in the air) while he is in a car
  local v = bodyVeh()
  if v and bodyLoaded and not bodyParked then
    v:queueLuaCommand("gtaBody.park()")
    bodyParked = true
  end
end
local function deleteBody()
  local v = bodyVeh()
  if v then pcall(v.delete, v) end
  bodyId, bodySpawnT, bodyLoaded, bodyParked = nil, nil, nil, nil
end

local findPuppets
local spawnedAt = 0
local function destroyBody()
  deleteBody()
  for _, o in pairs(segs) do pcall(o.delete, o) end
  if head then pcall(head.delete, head) end
  segs, head = {}, nil
  if puppetId then
    local v = be:getObjectByID(puppetId)
    if v then pcall(v.delete, v) end
    puppetId, puppetLoadedAt = nil, nil
  end
  for _, o in ipairs(findPuppets()) do pcall(o.delete, o) end
  spawnedAt = 0
end

local function place(o, cx, cy, cz, qx, qy, qz, qw, sx, sy, sz)
  local ok = pcall(o.setPosRot, o, cx, cy, cz, qx, qy, qz, qw)
  if not ok then
    local ok2, err = pcall(function()
      local m = QuatF(qx, qy, qz, qw):getMatrix()
      m:setPosition(Point3F(cx, cy, cz))
      o:setTransform(m)
    end)
    if not ok2 and bodyErr ~= err then bodyErr = err; log("E", logTag, "cannot pose body object: " .. tostring(err)) end
  end
  o.scale = vec3(sx, sy, sz)
end

local function skeletonPoints()
  if not (ped.fresh and ped.sk and #ped.sk >= 54) then return nil end
  -- GTA's newest joints, carried along with him to this moment exactly as his position is (readWalker): the camera hangs on his head,
  -- and it and the picture of him must not disagree about where he is
  local ex = slow * math.max(0, math.min(0.08, socket.gettime() - ped.t))
  local dx, dy = (ped.vx or 0) * ex, (ped.vy or 0) * ex
  local pts, sk = {}, ped.sk
  for i = 1, 18 do
    local o = (i - 1) * 3
    pts[i] = vec3(gtaToBeam(sk[o + 1] + dx, sk[o + 2] + dy, sk[o + 3]))
  end
  return pts
end

local function drawBody(pts)
  if not cfg.renderBody then return end
  for i, b in ipairs(bones) do
    local o = segs[i]
    if not o then
      o = newObj(limbShape, "gtaBridge_seg" .. i)
      segs[i] = o
    end
    if o then
      local a, c = pts[b[1]], pts[b[2]]
      local d = c - a
      local len = d:length()
      if len > 1e-4 then
        d = d / len
        local up = vec3(0, 0, 1)
        if math.abs(d.z) > 0.98 then up = vec3(1, 0, 0) end
        local right = d:cross(up):normalized()
        up = right:cross(d)
        local qx, qy, qz, qw = quatFromBasis(right.x, right.y, right.z, d.x, d.y, d.z, up.x, up.y, up.z)
        if cfg.flipQuat then qx, qy, qz = -qx, -qy, -qz end
        local m = (a + c) * 0.5
        place(o, m.x, m.y, m.z, qx, qy, qz, qw, thickness[i], len, thickness[i])
      end
    end
  end
  head = head or newObj(ballShape, "gtaBridge_head")
  if head then
    local h = pts[4]
    place(head, h.x, h.y, h.z, 0, 0, 0, 1, 0.22, 0.22, 0.22)
  end
end

-- Michael's real mesh is a flexbody on a vehicle whose nodes sit on GTA's skeleton points. BeamNG draws and
-- deforms it in its normal lit/shadowed pass; each frame the nodes are moved to the streamed joints.
findPuppets = function()   -- spawnNewVehicle can return nil before the vehicle exists: find by model instead
  local list = {}
  for i = 0, be:getObjectCount() - 1 do
    local o = be:getObject(i)
    local ok, hit = pcall(function()
      local n = tostring(o:getField("name", "") or "")
      return o.jbeam == "gta_puppet" or o:getJBeamFilename() == "gta_puppet" or n:find("gtaPuppet", 1, true)
    end)
    if o and ok and hit then list[#list + 1] = o end
  end
  return list
end
local function drawPuppet(pts)
  local v = puppetId and be:getObjectByID(puppetId)
  if not v then
    local all = findPuppets()
    for i = 2, #all do pcall(all[i].delete, all[i]) end   -- kill duplicates from earlier spawn loops
    if all[1] then
      puppetId, puppetLoadedAt = all[1]:getId(), puppetLoadedAt or socket.gettime()
      return
    end
    puppetId = nil
    if spawnedAt > 0 then return end   -- spawn ONCE per engage; never retry (cleared in destroyBody)
    spawnedAt = socket.gettime()
    local ok, res = pcall(function()
      local o = sanitizeVehicleSpawnOptions("gta_puppet", {vehicleName = "gtaPuppet", autoEnterVehicle = false})
      o.pos, o.rot = pts[1], quat(0, 0, 0, 1)
      return core_vehicles.spawnNewVehicle(o.model, o)
    end)
    if ok and res then
      puppetId = res:getId()
      puppetLoadedAt = socket.gettime()
      log("I", logTag, "spawned gta_puppet vehicle id " .. tostring(puppetId))
    elseif not ok and puppetErr ~= res then
      puppetErr = res
      log("E", logTag, "cannot spawn gta_puppet: " .. tostring(res))
    end
    return
  end
  if puppetLoadedAt then
    if socket.gettime() - puppetLoadedAt < 1.0 then return end   -- let the vehicle finish spawning
    v:queueLuaCommand("extensions.load('gtaPuppet')")
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)   -- identity rotation: node offsets are world offsets
    puppetLoadedAt = nil
    return
  end
  if (v:getPosition() - pts[1]):length() > 25 then   -- re-centre rarely (every re-centre resets the vehicle and hitches the animation)
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)
    return
  end
  local t = {}
  for i = 1, 18 do t[#t + 1] = string.format("%.3f,%.3f,%.3f", pts[i].x, pts[i].y, pts[i].z) end
  v:queueLuaCommand("gtaPuppet.set('" .. table.concat(t, ",") .. "')")
end

-- GTA-style third person camera: BeamNG's free camera supplies the mouse look (rotation); we pin its
-- position each frame behind Michael's head, pulled in if a wall is in the way.
local cam = {}
-- Runs inside BeamNG's own camera update (onCameraPreRender, below), on the rotation the mouse has given the camera for THIS frame.
-- It used to run a step earlier, on last frame's rotation: the camera turned at once but only swung round him a frame later, so
-- while the mouse was moving he slid off his spot on the screen and back.
local function chaseCam(pts, cd)
  if not cfg.thirdPerson then return end
  local fwd = quat(cd.res.rot) * vec3(0, 1, 0)
  local right = fwd:cross(vec3(0, 0, 1)):normalized()
  -- GTA camThirdPersonCamera, simplified: damped base pivot -> orbit offset (shoulder) -> orbit distance
  -- -> collision (pop in instantly, push out slowly). Numbers are guesses; GTA's live in metadata XML.
  local now = os.clock()
  local dt = math.min(0.1, now - (cam.t or now)); cam.t = now
  local goal = pts[4] + vec3(0, 0, cfg.camHeight)
  if not cam.pivot or (cam.pivot - goal):length() > 5 then cam.pivot = goal; cam.dist = cfg.camDist end
  cam.pivot = cam.pivot + (goal - cam.pivot) * (1 - math.exp(-dt * cfg.camPivotRate))
  local pivot = cam.pivot + right * cfg.camShoulder
  local wantDist = cfg.camDist
  local ok, d = pcall(castRayStatic, pivot, -fwd, wantDist + 0.3)
  if ok and d and d < wantDist + 0.3 then wantDist = math.max(0.4, d - 0.3) end
  if wantDist < cam.dist then cam.dist = wantDist                                  -- pop in
  else cam.dist = cam.dist + (wantDist - cam.dist) * (1 - math.exp(-dt * cfg.camPushOut)) end -- ease out
  cam.pos = pivot - fwd * cam.dist
  -- While he swims the camera stays above the water: from below, GTA's picture of him is all sea (and nothing can cut it away).
  if walkerWater and math.floor((ped.flags or 0) / 65536) % 2 == 1 then cam.pos.z = math.max(cam.pos.z, walkerWater + 0.3) end
  cd.res.pos:set(cam.pos)               -- what this frame is drawn from
  core_camera.setPosition(0, cam.pos)   -- and where BeamNG's free camera carries on from next frame
end

local function drawSkeleton(pts)
  if not cfg.drawSkeleton then return end
  local col = ColorF(0.1, 1, 0.3, 1)
  for _, b in ipairs(bones) do
    debugDrawer:drawLine(pts[b[1]], pts[b[2]], col)
  end
  debugDrawer:drawSphere(pts[4], 0.08, ColorF(1, 0.2, 0.2, 1))
end

-- ---------------------------------------------------------------- BeamNG -> GTA


-- K (pose for GTA's scripted camera) + Q (same pose for the BeamNG ReShade add-on, UDP 47202), sent after the chase camera has settled this frame.
-- GTA's picture reaches the screen leadSec late, so K carries the camera extrapolated leadSec ahead (constant yaw/pitch rate and velocity over the last
-- ~0.08 s); the add-on then only has to nudge the sprite by the small remainder.
-- Q|px|py|pz|fx|fy|fz|fovBeam|fovGta|zc|feetX|feetY|feetZ | predicted px|py|pz|fx|fy|fz|feetX|feetY|feetZ | sunX|sunY|sunZ | air | bodyH | bodyMode | water | shade x4 | how solid   (BeamNG coordinates)
local hist = {}   -- {t, yaw, pitch, px, py, pz, fx, fy, fz}
local function predictPose(now, p, f)
  local yaw, pitch = math.atan2(f.x, f.y), math.asin(math.max(-1, math.min(1, f.z)))
  local n = #hist
  if n == 0 or now - hist[n].t > 0.004 then
    hist[n + 1] = { t = now, yaw = yaw, pitch = pitch, px = p.x, py = p.y, pz = p.z, fx = walkerFeet.x, fy = walkerFeet.y, fz = walkerFeet.z }
    if n + 1 > 60 then table.remove(hist, 1) end
    n = #hist
  end
  local ref
  for i = n, 1, -1 do
    if now - hist[i].t >= 0.06 then ref = hist[i] break end
  end
  local lead = (cfg.predict and ref) and math.min(0.08, leadSec) * cfg.predictGain or 0   -- GTA runs at 100+ fps now: the real delay is a few frames
  if not ref or lead <= 0 then return p, f, walkerFeet end
  local dt = now - ref.t
  if dt > 0.3 then return p, f, walkerFeet end
  local dyaw = yaw - ref.yaw
  if dyaw > math.pi then dyaw = dyaw - 2 * math.pi elseif dyaw < -math.pi then dyaw = dyaw + 2 * math.pi end
local function lim(x) return math.max(-0.5, math.min(0.5, x)) end   -- never aim more than ~30 degrees ahead
  local yawP = yaw + lim(dyaw / dt * lead)
  local pitchP = math.max(-1.45, math.min(1.45, pitch + lim((pitch - ref.pitch) / dt * lead)))
  local cp = math.cos(pitchP)
  local fP = vec3(math.sin(yawP) * cp, math.cos(yawP) * cp, math.sin(pitchP))
  local k = lead / dt
  local dpx, dpy, dpz = (p.x - ref.px) * k, (p.y - ref.py) * k, (p.z - ref.pz) * k
  local dl = math.sqrt(dpx * dpx + dpy * dpy + dpz * dpz)
  if dl > 3 then dpx, dpy, dpz = dpx * 3 / dl, dpy * 3 / dl, dpz * 3 / dl end
  local feetP = vec3(walkerFeet.x + (walkerFeet.x - ref.fx) * k, walkerFeet.y + (walkerFeet.y - ref.fy) * k, walkerFeet.z)
  -- a straight-line step leaves the orbit circle (camera drifts away -> Michael rendered smaller): pull it back to the current distance from him
  local cx, cy, cz = feetP.x, feetP.y, feetP.z + 1
  local ox, oy, oz = p.x + dpx - cx, p.y + dpy - cy, p.z + dpz - cz
  local r0 = math.sqrt((p.x - walkerFeet.x) ^ 2 + (p.y - walkerFeet.y) ^ 2 + (p.z - walkerFeet.z - 1) ^ 2)
  local r1 = math.sqrt(ox * ox + oy * oy + oz * oz)
  local g = (r1 > 0.05) and r0 / r1 or 1
  local pP = vec3(cx + ox * g, cy + oy * g, cz + oz * g)
  return pP, fP, feetP
end

-- unit vector towards the sun (BeamNG world) from the sky object's azimuth/elevation, for Michael's cast shadow; nil at night / when unknown
local sunObj, sunT, sunV, sunLogT = nil, 0, nil, 0
local function sunDir()
  local now = socket.gettime()
  if now - sunT < 0.5 then return sunV end
  sunT = now
  local ok = pcall(function()
    if not sunObj then
      local names = scenetree.findClassObjects("ScatterSky")
      sunObj = names and names[1] and scenetree.findObject(names[1]) or nil
    end
    local az, el = sunObj and tonumber(sunObj.azimuth), sunObj and tonumber(sunObj.elevation)
    if az and el then
      local a, e = math.rad(az), math.rad(el)
      -- Torque convention: azimuth 0 = +Y, clockwise seen from above; elevation up from the horizon (may pass 90)
      local x, y, z = math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e)
      if cfg.sunFlip then x, y = -x, -y end
      sunV = z > 0.03 and { x, y, z } or nil
      if now - sunLogT > 10 then
        sunLogT = now
        log("I", logTag, string.format("sun azimuth=%.1f elevation=%.1f dir=(%.2f,%.2f,%.2f)", az, el, x, y, z))
      end
    else
      sunV = nil
    end
  end)
  if not ok then sunObj, sunV = nil, nil end
  return sunV
end

-- Michael's joints in BeamNG's world, for his shadow and his physical body: the pose he had when the picture now on screen was
-- taken (leadSec ago), carried to where he stands now. 18 of GTA's joints plus two toes (GTA only reports ankles).
local function bodyPoints()
  if not settled() or not (ped.fresh and ped.gx and #skHist > 0) then return nil end
  local now = socket.gettime()
  local e
  for i = #skHist, 1, -1 do
    e = skHist[i]
    if e.t <= now - leadSec then break end
  end
  local ex = slow * math.max(0, math.min(0.08, now - ped.t))
  local dx, dy, dz = ped.gx + (ped.vx or 0) * ex - e.gx, ped.gy + (ped.vy or 0) * ex - e.gy, ped.gz - e.gz
  local pts, sk = {}, e.sk
  for i = 1, 18 do
    local o = (i - 1) * 3
    pts[i] = vec3(gtaToBeam(sk[o + 1] + dx, sk[o + 2] + dy, sk[o + 3] + dz))
  end
  local tx, ty, tz = 0, 0, 0
  if (ped.flags or 0) % 2 == 0 then   -- on his feet: toes point where he faces (knocked down, the foot is just a ball at the ankle)
    local h = math.rad(ped.heading or 0)
    tx, ty = rotZ(-math.sin(h), math.cos(h), yawRad)
    tx, ty, tz = tx * 0.17, ty * 0.17, -0.05
  end
  pts[19] = pts[15] + vec3(tx, ty, tz)
  pts[20] = pts[18] + vec3(tx, ty, tz)
  return pts
end

-- BeamNG's own shadows, as far as its solid world casts them (rays towards the sun; trees and cars are not in it):
-- on him (legs, head) and on the ground his shadow falls on (at his feet, where the shadow of his head lands). 1 = in shadow.
local shade, shadeT = { 0, 0, 0, 0 }, 0
local function updateShade(sv)
  local now = socket.gettime()
  local k = math.min(1, (now - shadeT) / 0.12); shadeT = now   -- eased, so he does not flick dark at a shadow's edge
  local t = { 0, 0, 0, 0 }
  if sv and sv[3] > 0.03 then
    local x, y, g = walkerFeet.x, walkerFeet.y, walkerFeet.z
    local c = ped.fresh and ped.gz and (ped.gz + cfg.oz) or (g + 1)
    local flat = math.sqrt(sv[1] * sv[1] + sv[2] * sv[2])
    local reach = math.min(4, 1.7 * flat / sv[3])
    local fx, fy = flat > 0.001 and -sv[1] / flat * reach or 0, flat > 0.001 and -sv[2] / flat * reach or 0
    local from = { vec3(x, y, c - 0.6), vec3(x, y, c + 0.7), vec3(x, y, g + 0.08), vec3(x + fx, y + fy, g + 0.08) }
    for i = 1, 4 do
      local ok, d = pcall(castRayStatic, from[i], vec3(sv[1], sv[2], sv[3]), 300)
      if ok and d and d < 300 then t[i] = 1 end
    end
  end
  for i = 1, 4 do shade[i] = shade[i] + (t[i] - shade[i]) * k end
end

-- cd: BeamNG's camera data for the frame about to be drawn (from onCameraPreRender): exactly what is rendered. Without it (any
-- camera that is not the free one) the camera is read back from BeamNG, which is the previous frame's.
local function sendPose(cd)
  if not engaged then return end
  local p = cd and vec3(cd.res.pos) or (cam.pos and os.clock() - (cam.t or -1) < 0.25) and cam.pos or (core_camera.getPosition and core_camera.getPosition())
  local q = cd and quat(cd.res.rot) or core_camera.getQuat and core_camera.getQuat()
  if not p or not q then return end
  local f = q * vec3(0, 1, 0)
  local okf, fov = pcall(core_camera.getFovDeg)
  if cd and cd.res.fov then okf, fov = true, cd.res.fov end
  fov = (okf and fov and fov > 1) and fov or 60
  local pP, fP, feetP = p, f, walkerFeet
  if walkerHave then pP, fP, feetP = predictPose(socket.gettime(), p, f) end
  local px, py, pz = beamToGta(pP.x, pP.y, pP.z)
  local gx, gy, gz = dirToGta(fP.x, fP.y, fP.z)
  seq = seq + 1
  send(string.format("K|%d|%.4f|%.4f|%.4f|%.5f|%.5f|%.5f|%.3f", seq, px, py, pz, gx, gy, gz, fov * cfg.fovMul))
  if udp and walkerHave and settled() then
    local zc = (walkerFeet.x - p.x) * f.x + (walkerFeet.y - p.y) * f.y + (walkerFeet.z + 1.0 - p.z) * f.z
    local sv = sunDir() or { 0, 0, 0 }
    updateShade(sv)
    -- how far GTA's ped is above where he stands (a jump): the sprite is lifted by this, the shadow stays on the ground
    local air = 0
    if ped.fresh and ped.gz then air = math.max(0, math.min(300, ped.gz - (walkerFeet.z - cfg.oz) - 1.0 - 0.06)) end
    -- where his body centre is above the ground according to GTA's skeleton (head, chest, hips, calves). On foot the picture
    -- itself is measured instead; getting into / sitting in a car (bodyMode 1) his feet are not on the ground, so this is used.
    local bodyH, bodyMode, bodyAt = 0, 0, nil
    if ped.fresh and ped.sk and #ped.sk >= 54 then
      local g0 = walkerFeet.z - cfg.oz
      local sk = ped.sk
      bodyH = 0.10 * sk[12] + 0.30 * sk[6] + 0.30 * sk[3] + 0.15 * sk[42] + 0.15 * sk[51] - g0
      local fl = ped.flags or 0
      if math.floor(fl / 2048) % 2 == 1 or math.floor(fl / 32768) % 2 == 1 then bodyMode = 1 end
      if math.floor(fl / 2048) % 2 == 1 or (bodyMode == 1 and math.floor(fl / 16384) % 2 == 1) then bodyMode = 2 end   -- door open / inside: the car hides him like a driver
      if bodyMode > 0 then
        -- Getting into / sitting in a car the overlay pins the top of his head (not his body centre) to where GTA's skeleton has it:
        -- send the point on the ground under his head and how high the top of his head is above it. (GTA's "ped position" of someone
        -- in a car is not under his body, and a seated silhouette's centre says little about where he is.)
        local hx, hy = gtaToBeam(sk[10], sk[11], 0)
        bodyAt = vec3(hx, hy, walkerFeet.z)
        bodyH = sk[12] - g0 + cfg.headTop
        -- seated with the door shut again: from here on he is only ever seen through glass (which BeamNG's depth does not contain)
        if math.floor(fl / 2048) % 2 == 1 and math.floor(fl / 16384) % 2 == 0 then bodyMode = 4 end
      elseif fl % 2 == 1 or math.floor(fl / 64) % 2 == 1 or math.floor(fl / 65536) % 2 == 1 or sk[12] - sk[3] < 0.4 then
        -- Knocked down (ragdoll), climbing, or anything else where he is not upright (head less than 0.4 m above his hips): his
        -- feet are not what he stands on, so the overlay pins the centre of his outline to the centre of GTA's skeleton instead.
        bodyMode = 3
        local wx = 0.10 * sk[10] + 0.30 * sk[4] + 0.30 * sk[1] + 0.15 * sk[40] + 0.15 * sk[49]
        local wy = 0.10 * sk[11] + 0.30 * sk[5] + 0.30 * sk[2] + 0.15 * sk[41] + 0.15 * sk[50]
        if math.floor(fl / 65536) % 2 == 1 and walkerWater then
          -- Swimming, GTA's picture holds only what is above the water of him (the rest is cut away with GTA's sea). So the middle
          -- of that outline belongs on the middle of the joints that are above BeamNG's water (the head counts three times: it is
          -- most of what shows).
          local sx, sy, sz, n = 0, 0, 0, 0
          for i = 1, 52, 3 do
            if sk[i + 2] + cfg.oz > walkerWater - 0.05 then
              local w = i == 10 and 3 or 1
              sx, sy, sz, n = sx + sk[i] * w, sy + sk[i + 1] * w, sz + sk[i + 2] * w, n + w
            end
          end
          if n > 0 then wx, wy, bodyH = sx / n, sy / n, sz / n - g0 end
        end
        local bx, by = gtaToBeam(wx, wy, 0)
        bodyAt = vec3(bx, by, walkerFeet.z)
      end
    end
    local wf, wfP = bodyAt or walkerFeet, bodyAt or feetP
    pcall(udp.sendto, udp, string.format("Q|%.4f|%.4f|%.4f|%.5f|%.5f|%.5f|%.3f|%.3f|%.3f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.5f|%.5f|%.5f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.3f|%.3f|%d|%.3f|%.2f|%.2f|%.2f|%.2f|%.2f",
      p.x, p.y, p.z, f.x, f.y, f.z, fov, fov * cfg.fovMul, zc, wf.x, wf.y, wf.z,
      pP.x, pP.y, pP.z, fP.x, fP.y, fP.z, wfP.x, wfP.y, wfP.z, sv[1], sv[2], sv[3], air, bodyH, bodyMode,
      -- how deep the water is here; negative while he swims (the overlay then shows him under the surface from GTA's own picture of
      -- its sea, instead of fading the part of a wader that is below the waterline)
      walkerWater and math.max(0, walkerWater - walkerFeet.z) * (math.floor((ped.flags or 0) / 65536) % 2 == 1 and -1 or 1) or 0,
      shade[1], shade[2], shade[3], shade[4],
      -- BeamNG's wheel menus are part of its picture and he is pasted over that: drawn in full he would stand in front of them
      (core_quickAccess and core_quickAccess.isEnabled()) and cfg.wheelGhost or 1), cfg.host, 47202)
    local pts = (bodyMode == 0 or bodyMode == 3) and bodyPoints()
    if pts then   -- S: his joints, for the shadow
      local t = {}
      for i = 1, 20 do t[i] = string.format("%.3f|%.3f|%.3f", pts[i].x, pts[i].y, pts[i].z) end
      pcall(udp.sendto, udp, "S|" .. table.concat(t, "|"), cfg.host, 47202)
    end
  end
end

local lastTimeSend = 0
local function sendCamera()
  if not engaged then return end
  local f = core_camera and core_camera.getForward and core_camera.getForward()
  if not f then return end
  local gx, gy, gz = dirToGta(f.x, f.y, f.z)
  seq = seq + 1
  send(string.format("C|%d|%.4f|%.4f|%.4f", seq, gx, gy, gz))
  -- L: BeamNG time of day -> GTA clock (BeamNG time 0 = noon)
  local nowS = socket.gettime()
  if cfg.syncTime and nowS - (lastTimeSend or 0) > 2 then
    lastTimeSend = nowS
    local okt, tod = pcall(function() return core_environment.getTimeOfDay() end)
    if okt and tod and tod.time then
      send(string.format("L|%d|%.3f", seq, ((tod.time + 0.5) % 1) * 24))
    end
  end
end

-- Which GTA vehicle stands in for a BeamNG one. First the BeamNG model itself, then what its config says it is ("Body Style" in the
-- vehicle selector), then - on the GTA side - whatever is closest in size. Props and anything without a match by size are left out.
local gtaByModel = {
  atv = "blazer", autobello = "panto", barstow = "vigero", bastion = "buffalo", bluebuck = "emperor", bolide = "infernus",
  burnside = "tornado", bx = "futo", citybus = "bus", covet = "blista", dumptruck = "tiptruck", etk800 = "schafter2", etkc = "zion",
  etki = "oracle", fullsize = "stanier", hopper = "mesa", lansdale = "minivan", legran = "ingot", md_series = "mule",
  midsize = "primo", midtruck = "benson", miramar = "regina", moonhawk = "sabregt", nine = "tornado", pessima = "premier",
  pickup = "bison", pigeon = "panto", racetruck = "hauler", roamer = "granger", rockbouncer = "bfinjection", sbr = "elegy2",
  scintilla = "cheetah", simple_traffic = "asea", sunburst2 = "sultan", us_semi = "phantom", utv = "bfinjection", van = "burrito3",
  vivace = "blista", wendover = "ruiner", wigeon = "panto", wl40 = "bulldozer",
  dryvan = "trailers", tanker = "tanker", flatbed = "trflat", tiltdeck = "trflat", containerTrailer = "docktrailer",
}
-- body styles that say more than the model does (a van chassis with a box, a pickup that is an ambulance, ...); checked in order
local gtaByStyleFirst = {
  { "ambulance", "ambulance" }, { "fire", "firetruk" }, { "box truck", "mule" }, { "box", "mule" }, { "cement", "mixer" }, { "mixer", "mixer" },
  { "dump", "tiptruck" }, { "tow", "towtruck" }, { "rollback", "flatbed" }, { "flatbed", "flatbed" }, { "garbage", "trash" },
  { "bus", "bus" }, { "limo", "stretch" },
}
-- for vehicles the table above does not know (mods)
local gtaByStyle = {
  { "semi", "phantom" }, { "minivan", "minivan" }, { "van", "burrito3" }, { "pickup", "bison" }, { "suv", "granger" },
  { "wagon", "ingot" }, { "estate", "ingot" }, { "hatch", "blista" }, { "convertible", "zion2" }, { "roadster", "zion2" },
  { "coupe", "zion" }, { "sedan", "premier" }, { "saloon", "premier" }, { "supercar", "cheetah" }, { "sports", "elegy2" },
  { "buggy", "bfinjection" }, { "atv", "blazer" }, { "quad", "blazer" }, { "motorcycle", "bati" }, { "bike", "bati" },
}
local carInfo = {}   -- vehicle id -> { key = jbeam .. config, model = GTA name or "", skip = true for props }
local function carFor(veh, id)
  local jb = veh:getJBeamFilename()
  local key = jb .. "|" .. tostring(veh.partConfig)
  local ci = carInfo[id]
  if ci and ci.key == key then return ci end
  ci = { key = key, model = "" }
  carInfo[id] = ci
  local typ, style = "", ""
  pcall(function()
    local d = core_vehicles.getVehicleDetails(id)
    local m, c = d.model or {}, d.configs or {}
    typ = string.lower(tostring(m.Type or ""))
    style = string.lower(tostring(c["Body Style"] or m["Body Style"] or ""))
  end)
  if typ == "prop" then ci.skip = true return ci end
  for _, e in ipairs(gtaByStyleFirst) do
    if style:find(e[1], 1, true) then ci.model = e[2] break end
  end
  if ci.model == "" then ci.model = gtaByModel[jb] or "" end
  if ci.model == "" then
    for _, e in ipairs(gtaByStyle) do
      if style:find(e[1], 1, true) then ci.model = e[2] break end
    end
  end
  if ci.model == "" and typ == "trailer" then ci.skip = true end   -- an unknown trailer by size would become some random car
  log("I", logTag, string.format("car %d: %s (type '%s', body '%s') -> GTA '%s'%s", id, jb, typ, style, ci.model, ci.skip and " (not mirrored)" or ""))
  return ci
end

local function sendWorld()
  if not (engaged and cfg.cars and walkerHave) then return end
  local center = walkerFeet
  local list = {}
  for _, veh in ipairs(getAllVehicles()) do
    local id = veh:getID()
    local jb = veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and veh:getActive() and be:getObjectOOBBIsInitialized(id) and not carFor(veh, id).skip then
      local c = vec3(be:getObjectOOBBCenterXYZ(id))
      local dist = c:distance(center)
      if dist <= cfg.carRadius then
        list[#list + 1] = { veh = veh, id = id, c = c, dist = dist }
      end
    end
  end
  table.sort(list, function(a, b) return a.dist < b.dist end)

  for i = 1, math.min(#list, cfg.carMax) do
    local e = list[i]
    local veh, id = e.veh, e.id
    local dir = vec3(veh:getDirectionVector()):normalized()
    local up = vec3(veh:getDirectionVectorUp()):normalized()
    local right = dir:cross(up):normalized()
    up = right:cross(dir):normalized()

    -- half extents of the OOBB projected on the vehicle's own axes
    local hx, hy, hz = 0, 0, 0
    for a = 0, 2 do
      local ax = vec3(be:getObjectOOBBHalfAxisXYZ(id, a))
      hx = hx + math.abs(ax:dot(right))
      hy = hy + math.abs(ax:dot(dir))
      hz = hz + math.abs(ax:dot(up))
    end

    local cx, cy, cz = beamToGta(e.c.x, e.c.y, e.c.z)
    local rx, ry, rz = dirToGta(right.x, right.y, right.z)
    local fx, fy, fz = dirToGta(dir.x, dir.y, dir.z)
    local ux, uy, uz = dirToGta(up.x, up.y, up.z)
    local qx, qy, qz, qw = quatFromBasis(rx, ry, rz, fx, fy, fz, ux, uy, uz)
    -- Speed, averaged over about 0.15 s: a big diesel shaking at idle reads as half a metre a second back and forth, and GTA
    -- took the parked bus for a moving one (and threw him off it when he touched it).
    local ci, tv = carFor(veh, id), socket.gettime()
    local vx, vy, vz = veh:getVelocityXYZ()
    local k = math.min(1, (tv - (ci.vt or 0)) / 0.15)
    ci.vt, ci.vx, ci.vy, ci.vz = tv, (ci.vx or vx) + (vx - (ci.vx or vx)) * k, (ci.vy or vy) + (vy - (ci.vy or vy)) * k, (ci.vz or vz) + (vz - (ci.vz or vz)) * k
    vx, vy, vz = dirToGta(ci.vx, ci.vy, ci.vz)

    -- where this car's driver's eyes are (its driver camera node): GTA places its stand-in so Michael's eyes land exactly there
    local has, dgx, dgy, dgz = 0, 0, 0, 0
    pcall(function()
      local dn = core_camera.getDriverData(veh)
      if dn then
        local dp = veh:getPosition() + veh:getNodePosition(dn)
        dgx, dgy, dgz = beamToGta(dp.x, dp.y, dp.z)
        has = 1
      end
    end)
    send(string.format("V|%d|%.3f|%.3f|%.3f|%.5f|%.5f|%.5f|%.5f|%.3f|%.3f|%.3f|%.2f|%.2f|%.2f|%s|%d|%.3f|%.3f|%.3f",
      id, cx, cy, cz, qx, qy, qz, qw, hx, hy, hz, vx, vy, vz, carFor(veh, id).model, has, dgx, dgy, dgz))
  end
end

-- ---------------------------------------------------------------- lifecycle

local function closeSocket()
  if udp then pcall(udp.close, udp) end
  udp = nil
end

local function start()
  if running then return true end
  local u = socket.udp()
  local ok, err = u:setsockname("127.0.0.1", cfg.listenPort)
  if not ok then
    log("E", logTag, "could not bind UDP port " .. tostring(cfg.listenPort) .. ": " .. tostring(err))
    pcall(u.close, u)
    return false
  end
  u:settimeout(0)
  udp = u
  running = true
  log("I", logTag, "listening on 127.0.0.1:" .. cfg.listenPort .. ", sending to " .. cfg.host .. ":" .. cfg.gtaPort)
  return true
end

local function stop()
  engaged = false
  running = false
  closeSocket()
  destroyBody()
  ped.fresh = false
  log("I", logTag, "stopped")
end

-- Re-anchor: map the walker's current spot onto the GTA anchor (done automatically by engage()).
local function align()
  needOffset = true
  return true
end

-- Move the character to wherever the BeamNG camera is looking down at: fly the free camera over the
-- spot, call extensions.gtaBridge.here(). GTA ped keeps its own world; only the mapping offset changes.
local function here()
  if not ped.fresh then log("W", logTag, "here(): no GTA data") return false end
  local c = core_camera.getPosition()
  local ok, d = pcall(castRayStatic, vec3(c.x, c.y, c.z), vec3(0, 0, -1), 2000)
  local gz = (ok and d and d < 2000) and (c.z - d) or c.z
  local rx, ry = rotZ(ped.gx, ped.gy, yawRad)
  cfg.ox, cfg.oy = c.x - rx, c.y - ry
  cfg.oz = gz - (ped.gz - 1.0)    -- ped origin is ~1 m above its feet
  lastGround = gz
  saveConfig()
  log("I", logTag, string.format("character moved to %.1f, %.1f, %.1f", c.x, c.y, gz))
  return true
end

local manualOff, autoAt = false, nil
local function engage()
  manualOff = false
  if not running and not start() then return false end
  if not getWalker() then
    local pv = getPlayerVehicle(0)
    local p = pv and pv:getPosition() or core_camera.getPosition()
    ensureWalker(p.x, p.y, p.z)
  end
  engaged = true
  restDumped = false
  lastGround = nil
  waters = nil   -- (looked up again: another map, or the first look came too early)
  needOffset = true -- offset is computed once the walker exists and has been placed
  offsetAt = socket.gettime() + 1.0
  send(string.format("M|platform|%d", cfg.usePlatform and 1 or 0))
  log("I", logTag, "engaged")
  return true
end

local function disengage()
  engaged = false
  manualOff = true   -- stay off until engage() is called again
  local u = getWalker()
  if u and lastGround then
    local p = u:getPosition()
    moveVeh(u, vec3(p.x, p.y, lastGround + 0.3))
    pcall(u.setMeshAlpha, u, 1, "", false)
  end
  destroyBody()
  log("I", logTag, "disengaged")
end

local function set(key, value)
  if cfg[key] == nil then
    log("W", logTag, "unknown setting " .. tostring(key))
    return false
  end
  cfg[key] = value
  applyConfig()
  saveConfig()
  if key == "usePlatform" and engaged then
    send(string.format("M|platform|%d", value and 1 or 0))
  end
  return true
end

local function status()
  local s = string.format("running=%s engaged=%s gtaData=%s offset=(%.1f,%.1f,%.1f) yaw=%.1f",
    tostring(running), tostring(engaged), tostring(ped.fresh), cfg.ox, cfg.oy, cfg.oz, cfg.yawDeg)
  log("I", logTag, s)
  return s
end

local lastErr
-- On foot, Tab is Michael's (the weapon wheel): what BeamNG has on that key is held back until he is in a car again
local tabHeld
local function holdTab(on)
  if on == tabHeld or not core_input_actionFilter then return end
  tabHeld = on
  core_input_actionFilter.setGroup("gtaBridgeOnFoot", { "switch_next_vehicle", "switch_previous_vehicle", "switch_next_vehicle_multiseat", "toggle_minimap" })
  core_input_actionFilter.addAction(0, "gtaBridgeOnFoot", on)
end

-- >>> checked by tools/check_guns.lua
-- ---- the weapon wheel ----
-- BeamNG's own radial menu, on a level of its own, held open by Tab as GTA's wheel is. BeamNG's Lua cannot read a key, so the GTA
-- script reports Tab (a bit in his state packet). The menu slows BeamNG down while it is up, as it does for BeamNG's own wheel,
-- and GTA is told to run as slowly. Letting go of Tab takes the weapon the pointer is at; a click on one takes it too.
-- A tap on Tab (let go before the wheel is up) puts the gun away, or takes the last one out again, as in GTA.
local WHEEL = "/root/gtaBridge/weapons/"
local wheel, tabWas   -- wheel: a table while Tab holds it open
local tabT, lastGun = 0, 1   -- when Tab went down; the gun he last had out (its place in GTA's list, pistol to begin with)

-- Which of the wheel's items the pointer is at, by its direction from the hub alone (it need not be on the button). dx, dy: the
-- pointer from the hub, to the right and up, in window heights. items: as BeamNG lays them out, .position and .size in turns,
-- clockwise from the left. Inside the hub: none.
local function wheelPick(items, dx, dy)
  if dx * dx + dy * dy < 0.07 * 0.07 then return end
  local a = (0.5 - math.atan2(dy, dx) / (2 * math.pi)) % 1
  for i, it in ipairs(items) do
    if it.position and it.size then
      local d = math.abs(a - it.position % 1)
      if math.min(d, 1 - d) <= it.size / 2 then return i end
    end
  end
end

-- the mouse pointer in BeamNG's window: across and down as 0..1, then the window's width over its height. nil while it is hidden.
local function pointer()
  local c = scenetree.findObject("Canvas")
  local p = c and c:getCursorPos()
  if not p or (p.x == -1 and p.y == -1) then return end
  local w, h = c:getWindowClientSizeXY()
  local ox, oy = c:clientToScreenXY(Point2I(0, 0))
  if not (w and h and ox and oy) or w <= 0 or h <= 0 then return end
  return (p.x - ox) / w, (p.y - oy) / h, w / h
end

local function updateWheel(tab)
  local qa = core_quickAccess
  if not qa then return end
  local now = socket.gettime()
  local inHand = WEAPON[ped.weapon]
  for i = 2, #LOADOUT do if LOADOUT[i] == inHand then lastGun = i - 1 end end
  if tab and not tabWas then tabT = now end
  if tab and not wheel and now - tabT >= cfg.wheelHold then
    -- (entered again each time: BeamNG gathers its menus once at start-up, which can be before this extension was loaded)
    qa.addEntry({ level = WHEEL, uniqueID = "gtaBridgeWeapons", generator = function(entries)
      for i, w in ipairs(LOADOUT) do
        table.insert(entries, { title = w.name, icon = w.icon, startSlot = w.slot, endSlot = w.slot, ignoreAsRecentAction = true,
          color = ped.weapon == w.hash and "var(--bng-orange)" or nil,   -- the one in his hands
          onSelect = function() send("M|weapon|" .. (i - 1)) return { "hide" } end })
      end
    end })
    qa.setSlowMoFactor(cfg.wheelSlowMo)
    qa.setEnabled(true, WHEEL)
    wheel = {}
  elseif wheel then
    if qa.isEnabled() then wheel.seen = true elseif wheel.seen then wheel.shut = true end   -- shut: a weapon was clicked (or Esc) with Tab still down
    if not wheel.x then wheel.x, wheel.y = pointer() end   -- where the pointer first shows
    if not tab then
      local ui, x, y, aspect = qa.getUiData(), pointer()
      -- (only if the pointer has been moved: where it happened to be lying when the wheel came up picks nothing)
      if not wheel.shut and qa.isEnabled() and ui and ui.currentLevel == WHEEL and ui.items and x and wheel.x
        and math.abs(x - wheel.x) + math.abs(y - wheel.y) > 0.01 then
        local i = wheelPick(ui.items, (x - 0.5) * aspect, 0.55 - y)   -- BeamNG draws the hub 55% of the way down the window
        if i then qa.selectItem(i, true, 1) end   -- BeamNG's own "this one was clicked": the weapon's onSelect above
      end
      if not wheel.shut then qa.setEnabled(false) end
      qa.resetSlowMoFactor()
      wheel = nil
    end
  elseif tabWas and not tab then
    send("M|weapon|" .. (inHand == LOADOUT[1] and lastGun or 0))   -- a tap
  end
  tabWas = tab
  local s = (wheel and not wheel.shut) and cfg.wheelSlowMo or 1
  if s ~= slow then slow = s; send(string.format("M|slow|%.2f", s)) end
end

-- ---- bullets ----
-- GTA fires the gun (the animation, the sound, the flash); where the shot lands is BeamNG's business. For each shot GTA reports,
-- a ray goes out along the middle of BeamNG's picture, which is where he aims. What it meets first gets a small dark disc, and if
-- that is a car, a shove on the panel it hit. The map is searched here; a car is a soft body only its own Lua can search, so
-- every car on the line is sent the ray, and answers (bulletReply). There a window breaks and lets the shot through, and a tire
-- goes flat; neither is left with a mark.
-- ponytail: each car answers for itself, so a shot marks every car on its line, not only the first. Chain them if it shows.
local BULLET = "extensions.load('gtaBullet') gtaBullet.hit(%f, %f, %f, %f, %f, %f, %f, %f, %d)"   -- lua/vehicle/extensions/gtaBullet.lua
local holes, pending, shotSeq = {}, {}, 0   -- the marks; shots some car has yet to answer for

local function addHole(h)
  holes[#holes + 1] = h
  if #holes > cfg.bulletHoles then table.remove(holes, 1) end
end

-- Where a ray meets the map: how far along, and which way the surface faces there. That comes from two more rays a centimetre
-- to the side and above: three points of the surface. Where they disagree (an edge), the mark simply faces the shooter.
local function hitStatic(o, d, range)
  local ok, t = pcall(castRayStatic, o, d, range)
  if not ok or not t or t >= range then return end
  local r = d:cross(vec3(0, 0, 1))
  if r:length() < 1e-3 then r = vec3(1, 0, 0) end
  r = r:normalized() * 0.01
  local u = r:cross(d)
  local n = -d
  local ok1, t1 = pcall(castRayStatic, o + r, d, range)
  local ok2, t2 = pcall(castRayStatic, o + u, d, range)
  if ok1 and ok2 and t1 and t2 and math.abs(t1 - t) < 0.3 and math.abs(t2 - t) < 0.3 then
    n = (r + d * (t1 - t)):cross(u + d * (t2 - t)):normalized()   -- (r x u is -d: this one always faces the shooter too)
  end
  return t, n
end

local function fireBullet(o, d)
  local t, n = hitStatic(o, d, cfg.bulletRange)
  local wall = t and { p = o + d * t, n = n } or nil
  local reach, waiting = t or cfg.bulletRange, 0
  shotSeq = shotSeq + 1
  pending[shotSeq - 100] = nil   -- (a car that was removed before it answered)
  for _, veh in ipairs(getAllVehicles()) do
    local id, jb = veh:getID(), veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and jb ~= "gta_puppet" and veh:getActive() and be:getObjectOOBBIsInitialized(id) then
      -- only the cars whose box the ray enters before it reaches the map
      local near, far = intersectsRay_OBB(o, d, vec3(be:getObjectOOBBCenterXYZ(id)), vec3(be:getObjectOOBBHalfAxisXYZ(id, 0)),
        vec3(be:getObjectOOBBHalfAxisXYZ(id, 1)), vec3(be:getObjectOOBBHalfAxisXYZ(id, 2)))
      if near < reach and far > 0 then
        waiting = waiting + 1
        -- (2000: the force is for one physics step, and BeamNG takes 2000 of them a second)
        veh:queueLuaCommand(string.format(BULLET, o.x, o.y, o.z, d.x, d.y, d.z, reach, cfg.bulletPush * 2000, shotSeq))
      end
    end
  end
  if waiting > 0 then pending[shotSeq] = { wall = wall, waiting = waiting }
  elseif wall then addHole(wall) end
  return o + d * reach   -- where the streak from the gun ends
end

-- a car's answer: where it was hit (its id, the three corners of the panel and the hit's place between them); its id alone: it
-- stopped the shot but takes no mark (a tire); nothing: the shot missed it, or went clean through its windows
local function bulletReply(shot, vehId, a, b, c, u, v)
  local s = pending[shot]
  if not s then return end
  s.waiting = s.waiting - 1
  if vehId then
    s.hit = true
    if a then addHole({ veh = vehId, a = a, b = b, c = c, u = u, v = v }) end
  end
  if s.waiting <= 0 then
    if not s.hit and s.wall then addHole(s.wall) end   -- it went past every car: the map behind them has it
    pending[shot] = nil
  end
end

-- Where a mark is now: the point, which way the surface faces, and how far it may lie under what is drawn there. On a car it
-- rides on the three corners of the panel that was hit, so it travels (and bends) with the car.
-- ponytail: that panel is the car's collision skin, which can lie a centimetre or two under the paint. The mark is a flat disc,
-- so it is drawn that much nearer the eye, along the line of sight (where it looks no different), instead of being made thick
-- enough to poke through. A true decal on a car's own mesh is not something BeamNG's Lua can make.
local function holeAt(h)
  if not h.veh then return h.p, h.n, 0.006 end
  local veh = be:getObjectByID(h.veh)
  if not veh then return end
  local a, b, c = vec3(veh:getNodePosition(h.a)), vec3(veh:getNodePosition(h.b)), vec3(veh:getNodePosition(h.c))
  return vec3(veh:getPosition()) + a * h.u + b * h.v + c * (1 - h.u - h.v), (c - a):cross(b - c):normalized(), 0.03
end
-- <<< checked

local tracers = {}   -- the streaks of the last shots: { from, to, when }

local function drawHoles()
  local eye = core_camera.getPosition()
  eye = eye and vec3(eye)
  local col = ColorF(0.02, 0.02, 0.02, 1)
  for _, h in ipairs(holes) do
    local p, n, under = holeAt(h)
    if p then
      local to = eye and eye - p
      if to and to:length() > under * 2 then p = p + to * (under / to:length()) end
      debugDrawer:drawCylinder(p - n * 0.0005, p + n * 0.0005, cfg.holeSize, col)   -- a millimetre thick: a flat spot
    end
  end
  -- the streaks: thin, pale, and gone in a moment
  local now = socket.gettime()
  for i = #tracers, 1, -1 do
    local t = tracers[i]
    local left = 1 - (now - t.t) / math.max(cfg.tracer, 0.001)
    if left <= 0 then table.remove(tracers, i)
    else debugDrawer:drawCylinder(t.a, t.b, 0.006, ColorF(1, 0.95, 0.8, 0.35 * left)) end
  end
end

-- n shots just fired (a shotgun's is several pellets, spread a little). hand: where his gun hand is, for the streak.
local function shoot(n, hand)
  local cp, q = core_camera.getPosition(), core_camera.getQuat()
  if not (cp and q) then return end
  cp = vec3(cp)
  local f = quat(q) * vec3(0, 1, 0)
  -- from level with him on the camera's line, not from the camera: what stands between the camera and him is not in the line of fire
  local o = cp + f * math.max(0, (vec3(walkerFeet.x, walkerFeet.y, walkerFeet.z + 1.4) - cp):dot(f))
  local pellets = WEAPON[ped.weapon] and WEAPON[ped.weapon].pellets or 1
  for _ = 1, n * pellets do
    local d = pellets == 1 and f or (f + vec3(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 0.07):normalized()
    local to = fireBullet(o, d)
    -- the streak runs from the muzzle (a hand's length ahead of his gun hand) to where the map stops the shot. Where a car is
    -- in the way the far end is behind it, out of sight.
    if hand and cfg.tracer > 0 then tracers[#tracers + 1] = { a = hand + f * 0.35, b = to, t = socket.gettime() } end
  end
end

local function guard(f, ...)
  local ok, err = pcall(f, ...)
  if not ok and err ~= lastErr then
    lastErr = err
    log("E", logTag, tostring(err))
  end
end

-- In a vehicle (F next to a car, or Tab to another one) Michael is parked: no sprite, BeamNG's own camera, GTA holds him still on his
-- platform. Back on foot (F) the bridge re-anchors at the new spot, exactly like a fresh engage.
local riding, rideMsgT, paceT = false, 0, 0

-- ---- getting into a car ----
-- F (BeamNG's "enter/exit vehicle") is rerouted while Michael is on foot next to a car: GTA plays its own get-in animation on
-- the invisible stand-in, BeamNG's driver door opens when GTA's does, and only once he sits does BeamNG switch to driving.
local entering   -- { id, t, active, door, seatedAt }
local origToggle
-- side: "l" or "r", the front door GTA opened (he gets in from whichever side he is standing on)
local function doorCmd(veh, phase, side)   -- "open" (unlatch + push), "hold" (keep it open), "close" (pull + latch)
  veh:queueLuaCommand(string.format([[
    local phase = "%s"
    -- a bus: its doors are air-powered, all of them on one pair of valves (1 = air in, doors shut; -1 = air out, doors free).
    -- (Not through the bus's own "toggle doors": on this install that function is an older one that fails.)
    local air = controller.getController("doors")
    if air and air.setBeamGroupsValveState then
      air.setBeamGroupsValveState({ "frontDoors", "rearDoors" }, phase == "close" and 1 or -1)
      -- That only lets the air out; what then opens the doors is a very weak spring, so they creep. Help it while he gets
      -- in: draw the two ends of each front door's cylinder together (the air pushes them apart to shut the door).
      if phase ~= "close" then
        local nm = beamstate.nodeNameMap
        for _, p in ipairs({ { "fdb5r", "fdb1l" }, { "fdb6r", "fdb2l" }, { "fdb5l", "fdb1r" }, { "fdb6l", "fdb2r" } }) do
          local a, b = nm[ p[1] ], nm[ p[2] ]   -- (spaced: two closing brackets together would end this block of text)
          if a and b then obj:applyForceTime(b, a, %d, 0.3) end
        end
      end
      phase = "bus"
    end
    -- latch controllers are named like door_FL_coupler / door_L_coupler: compare letters only
    local want, found, seen = { "doorf%scoupler", "door%scoupler" }, nil, {}
    for _, c in pairs(controller.getControllersByType("advancedCouplerControl") or {}) do
      local n = string.lower(tostring(c.name or "")):gsub("[^%%a]", "")
      seen[#seen + 1] = tostring(c.name)
      for i, w in ipairs(want) do
        if n == w and (not found or i < found.i) then found = { c = c, i = i } end
      end
    end
    if phase == "bus" then
    elseif found then
      -- the latch's two nodes (door side, body side): the car's own pop-open force acts between them, ours is added the same way
      local n1, n2
      pcall(function()
        local r = tableFromHeaderTable(v.data[found.c.name].couplerNodes)[1]
        local c2 = type(r.cid2) == "table" and r.cid2[1] or r.cid2
        n1 = beamstate.nodeNameMap[r.forceCid1 or r.cid1]
        n2 = beamstate.nodeNameMap[r.forceCid2 or c2]
      end)
      if phase == "open" then found.c.detachGroup() elseif phase == "close" then found.c.tryAttachGroupImpulse() end
      if n1 and n2 then obj:applyForceTime(n2, n1, %d, %.2f) end
    else
      log("W", "gtaBridge", "no front door latch on that side among: " .. table.concat(seen, ", "))
    end
  ]], phase, cfg.busDoorForce, side, side,
    phase == "open" and -cfg.doorPush or phase == "hold" and -cfg.doorHold or cfg.doorPull,
    phase == "open" and cfg.doorPushTime or phase == "hold" and 0.3 or cfg.doorPullTime))
end
-- The car he is standing at. Any car: BeamNG's own on-foot check deliberately leaves out traffic and parked cars (they are on
-- its walking blacklist whatever "enable switching to NPC vehicles" says), so the bridge looks for itself.
local function carAtHand()
  if not walkerHave then return nil end
  local p = vec3(walkerFeet.x, walkerFeet.y, walkerFeet.z + 0.9)
  local best, bestD = nil, 1.5
  for _, veh in ipairs(getAllVehicles()) do
    local id = veh:getID()
    local jb = veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and veh:getActive() and be:getObjectOOBBIsInitialized(id) and not carFor(veh, id).skip then
      local d = p - vec3(be:getObjectOOBBCenterXYZ(id))
      for a = 0, 2 do   -- take off what lies inside the box along each of its axes: what is left is the way to its surface
        local ax = vec3(be:getObjectOOBBHalfAxisXYZ(id, a))
        local len = ax:length()
        if len > 1e-4 then
          local u = ax / len
          d = d - u * math.max(-len, math.min(len, d:dot(u)))
        end
      end
      local dist = d:length()
      if dist < bestD then best, bestD = veh, dist end
    end
  end
  return best
end
-- A traffic or parked car he is taking becomes an ordinary car: its driver stops, BeamNG stops managing (respawning, teleporting) it.
local function takeOver(veh)
  local id = veh:getID()
  pcall(function() if extensions.gameplay_traffic then extensions.gameplay_traffic.removeTraffic(id, true) end end)
  pcall(function() if extensions.gameplay_parking then extensions.gameplay_parking.removeVehicle(id) end end)
  pcall(extensions.gameplay_walk.removeVehicleFromBlacklist, id)
  veh.playerUsable = true
end

local toggleT = 0
local function bridgeToggle()
  local w = extensions.gameplay_walk
  local now = socket.gettime()
  -- already on his way in; or a second F right behind the first (after getting out it sent him straight back at the car he had
  -- just left: GTA's ped grabbed the door of the rolling car and hung there for 12 s)
  if entering or now - toggleT < 0.7 then return end
  toggleT = now
  if engaged and not riding and not settled() then return end   -- just got out: GTA's ped is not in place yet
  local veh = engaged and not riding and carAtHand() or (w and w.getVehicleInFront and w.getVehicleInFront())
  if veh and veh:getJBeamFilename() == "gta_body" then return end
  if engaged and cfg.enterAnim and cfg.cars and not riding and veh and ped.fresh and w.isWalking() then
    takeOver(veh)
    entering = { id = veh:getID(), t = socket.gettime() }
    send(string.format("E|%d", entering.id))
    return
  end
  -- BeamNG refuses to let you out above walking pace; GTA lets you bail out of a moving car, so force it
  if engaged and riding and w and w.setWalkingMode then return w.setWalkingMode(true, nil, nil, true) end
  if origToggle then return origToggle() end
end
local function patchWalk()
  local w = extensions.gameplay_walk
  if w and w.toggleWalkingMode ~= bridgeToggle then
    origToggle = w.toggleWalkingMode
    w.toggleWalkingMode = bridgeToggle
  end
end
local function unpatchWalk()
  local w = extensions.gameplay_walk
  if w and origToggle and w.toggleWalkingMode == bridgeToggle then w.toggleWalkingMode = origToggle end
end
local function getIn(veh)
  pcall(function()
    veh:queueLuaCommand('ai.setMode("disabled")')   -- (a traffic car's driver was told to stop when he grabbed the door: now it is the player's)
    extensions.hook("onBeforeWalkingModeToggled", false, veh:getID())
    extensions.gameplay_walk.getInVehicle(veh)
  end)
end
local function updateEntering()
  if not entering then return end
  local veh = getObjectByID(entering.id)
  if not veh then entering = nil return end
  local now = socket.gettime()
  local fl = ped.flags or 0
  local inVeh = math.floor(fl / 2048) % 2 == 1
  local doorOpen = math.floor(fl / 16384) % 2 == 1
  if math.floor(fl / 32768) % 2 == 1 then entering.active = true end
  if doorOpen and not entering.door then
    entering.door = true
    entering.holdT = now + cfg.doorPushTime
    entering.side = math.floor(fl / 131072) % 2 == 1 and "r" or "l"   -- GTA's doors: 0 front left, 1 front right, 2 and 3 behind them
    log("I", logTag, "GTA opened the " .. (entering.side == "r" and "right" or "left") .. " door: opening BeamNG's")
    doorCmd(veh, "open", entering.side)
  end
  if entering.door and not entering.closed and now >= entering.holdT then
    entering.holdT = now + 0.25
    doorCmd(veh, "hold", entering.side)
  end
  if inVeh and not entering.seatedAt then entering.seatedAt = now end
  if entering.seatedAt and not entering.logged and now - entering.seatedAt > 1.0 and ped.sk and #ped.sk >= 54 then
    entering.logged = true   -- how well does his head sit on the BeamNG driver's eye point?
    pcall(function()
      local dn = core_camera.getDriverData(veh)
      local dp = veh:getPosition() + veh:getNodePosition(dn)
      local hx, hy, hz = gtaToBeam(ped.sk[10], ped.sk[11], ped.sk[12])
      log("I", logTag, string.format("seated: BeamNG driver eyes (%.2f, %.2f, %.2f), GTA head (%.2f, %.2f, %.2f), ground %.2f",
        dp.x, dp.y, dp.z, hx, hy, hz, walkerFeet.z))
    end)
  end
  if entering.seatedAt then
    if entering.door and not entering.closed and now - entering.seatedAt > 0.3 then
      entering.closed = true
      doorCmd(veh, "close", entering.side)
    end
    if now - entering.seatedAt > 1.3 then entering = nil getIn(veh) end
  elseif not entering.active and now - entering.t > 1.0 then
    -- GTA has no stand-in for this car (too far down the list, or the script is not running): plain BeamNG enter
    entering = nil
    getIn(veh)
  elseif entering.active and math.floor(fl / 32768) % 2 == 0 and now - entering.t > 1.0 then
    -- he gave up (the player walked away, or GTA timed out)
    if entering.door then doorCmd(veh, "close", entering.side) end
    entering = nil
  end
end
-- ---- walls and fences ----
-- GTA has none of BeamNG's buildings. Ten times a second rays go out around him at knee and at waist height; where one hits, more
-- rays find out how high the thing is: clear at chest height (low: he vaults it), clear above his head (up to about 2.3 m: he can
-- pull himself up), or not (a wall). GTA is told a point on it, how high its top is and which way it runs (from the neighbouring
-- hits), nearest first, and stands invisible barriers there (O packet).
local obsT = 0
local SOLID = 9   -- "top" sent for something too high to climb
local function wallsNearby()
  if not (cfg.walls and settled() and ped.fresh and lastGround and walkerHave) then return end
  local now = socket.gettime()
  if now - obsT < 0.1 then return end
  obsT = now
  local g = walkerFeet.z
  local o = vec3(walkerFeet.x, walkerFeet.y, g)
  local N, R = 12, 2.5
  local down = vec3(0, 0, -1)
  local function ahead(z, dir, range)   -- how far it is to something at this height (nil: nothing within range)
    local ok, d = pcall(castRayStatic, vec3(o.x, o.y, g + z), dir, range)
    if ok and d and d < range then return d end
  end
  local function topAt(x, y, from)   -- how high whatever is under this spot stands, looking down from `from` above his ground
    local ok, d = pcall(castRayStatic, vec3(x, y, g + from), down, from)
    if ok and d and d < from then return from - d end
  end
  local function turned(dir, a)
    local c, sn = math.cos(a), math.sin(a)
    return vec3(dir.x * c - dir.y * sn, dir.x * sn + dir.y * c, 0)
  end
  local list = {}
  for i = 1, N do
    local dir = turned(vec3(1, 0, 0), (i - 1) * 2 * math.pi / N)
    local d1, d2 = ahead(0.35, dir, R), ahead(1.1, dir, R)
    local d = d1 and d2 and math.min(d1, d2) or d1 or d2
    local z = (d1 and d == d1) and 0.35 or 1.1   -- the height of the ray that found it
    if d and d > 0.35 then   -- (closer than that he is already in it: a barrier appearing around him would throw him)
      local p = o + dir * d
      -- Which way it runs: two more rays just either side. Nothing there at about the same distance means a narrow thing (a
      -- hydrant, a post, a sign): no barrier for those, they are far smaller than one.
      local da, db = ahead(z, turned(dir, -0.14), d + 0.5), ahead(z, turned(dir, 0.14), d + 0.5)
      local t = da and db and (turned(dir, 0.14) * db - turned(dir, -0.14) * da)
      if t and t:length() > 0.02 then
        t = t:normalized()
        -- How far it goes each way along that line (up to a metre): the barrier is two metres long, so it needs at least a
        -- metre of wall to stand for, and at a wall's end it is slid along so that it does not stick out past it.
        local function reach(sign)
          local r = 0
          for _, step in ipairs({ 0.5, 1.0 }) do
            local v = p + t * (sign * step) - o
            local len = v:length()
            local dd = ahead(z, v / len, len + 0.3)
            if dd and dd > len - 0.3 then r = step else break end
          end
          return r
        end
        local L, Rr = reach(-1), reach(1)
        if L + Rr >= 1.0 then
          local bx, by = p.x + dir.x * 0.08, p.y + dir.y * 0.08
          local top
          if not ahead(1.45, dir, d + 0.4) then
            top = topAt(bx, by, 1.45) or 1.0   -- (a fence too thin for a ray to land on: call it a metre)
            -- a step he just walks up; and stairs or a steep bank go on rising behind the first hit: neither is something to vault
            local behind = topAt(p.x + dir.x * 0.5, p.y + dir.y * 0.5, 1.45)
            if top < 0.45 or (behind and behind > top + 0.12) then top = nil end
          elseif not ahead(2.5, dir, d + 0.4) then
            top = topAt(bx, by, 2.5) or 2.0    -- chest to head height: he can still pull himself up
            if top > 2.3 then top = SOLID end
          else
            top = SOLID
          end
          -- (not for a wall he is already rubbing along: a barrier appearing against him would throw him)
          if top and math.abs(t.x * (p.y - o.y) - t.y * (p.x - o.x)) > 0.3 then
            local c = p + t * ((Rr - L) / 2)
            local gx, gy, gz = beamToGta(c.x, c.y, g + top)
            local tx, ty = dirToGta(t.x, t.y, 0)
            list[#list + 1] = { d = d, s = string.format("%.2f|%.2f|%.2f|%.3f|%.3f", gx, gy, gz, tx, ty) }
          end
        end
      end
    end
  end
  if #list == 0 then return end
  table.sort(list, function(x, y) return x.d < y.d end)
  local out = {}
  for i = 1, math.min(#list, 16) do out[i] = list[i].s end
  send("O|" .. #out .. "|" .. table.concat(out, "|"))
end

local BODY_PTS = { 1, 2, 3, 4, 6, 7, 8, 10, 11, 12, 14, 15, 17, 18 }   -- the joints that carry a node (same order as gtaBody.lua)
local bodyWantT = 0
local function carMovingNear(c)
  for _, veh in ipairs(getAllVehicles()) do
    local jb = veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and veh:getActive() and veh:getPosition():distance(c) < cfg.bodyNear
      and vec3(veh:getVelocity()):length() > cfg.bodySpeed then
      return true
    end
  end
  return false
end
local function updateBody()
  if not cfg.bodyCollide then return end
  local fl = ped.flags or 0
  local now = socket.gettime()
  local inCar = entering or math.floor(fl / 2048) % 2 == 1 or math.floor(fl / 32768) % 2 == 1
  local pts = not inCar and now > bodyHoldT and bodyPoints() or nil
  -- The body is only out while a car near him is actually moving: that is when it has something to do (take the hit). Next to a
  -- parked car it adds nothing and breaks things (standing by the door, climbing on the roof), so it stays put away.
  if pts and bodyLoaded then
    if carMovingNear(pts[1]) then bodyWantT = now end
    if now - bodyWantT > 1.5 then pts = nil end
  end
  local v = bodyVeh()
  if not v then
    if bodySpawnT or not pts then return end   -- one attempt per engage
    bodySpawnT = socket.gettime()
    local ok, res = pcall(function()
      local o = sanitizeVehicleSpawnOptions("gta_body", { vehicleName = "gtaBody", autoEnterVehicle = false })
      o.pos, o.rot = pts[1], quat(0, 0, 0, 1)
      return core_vehicles.spawnNewVehicle(o.model, o)
    end)
    log(ok and "I" or "E", logTag, ok and "spawned Michael's physical body (gta_body)" or ("cannot spawn gta_body: " .. tostring(res)))
    return
  end
  bodySpawnT = bodySpawnT or socket.gettime()
  if socket.gettime() - bodySpawnT < 1.0 then return end   -- let it finish spawning
  if not bodyLoaded then
    if not pts then return end
    v.playerUsable = false   -- not something F or Tab should offer
    pcall(extensions.gameplay_walk.addVehicleToBlacklist, v:getID())
    v:queueLuaCommand("extensions.load('gtaBody')")
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)   -- identity rotation: node offsets are world offsets
    bodyLoaded = true
    return
  end
  if not pts then parkBody() return end
  bodyParked = false
  if (v:getPosition() - pts[1]):length() > 40 then   -- keep its origin near him (a reset, but of a 20-node vehicle)
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)
    return
  end
  local vx, vy = rotZ(ped.vx or 0, ped.vy or 0, yawRad)
  local t = { string.format("%.2f,%.2f,%.2f", vx, vy, ped.vz or 0) }
  for i, k in ipairs(BODY_PTS) do t[i + 1] = string.format("%.3f,%.3f,%.3f", pts[k].x, pts[k].y, pts[k].z) end
  v:queueLuaCommand("gtaBody.set('" .. table.concat(t, ",") .. "')")
end

local function tick()
  pump()
  local pv = be:getPlayerVehicleID(0)
  if ((puppetId and pv == puppetId) or (bodyId and pv == bodyId)) and extensions.gameplay_walk then
    pcall(extensions.gameplay_walk.setWalkingMode, true, nil, nil, true)   -- the puppet / body is never the player's vehicle (Tab can land on it)
  end
  stat.frames = stat.frames + 1
  local nowS = socket.gettime()
  if nowS - stat.t >= 3 then
    if engaged then
      log("I", logTag, string.format("stat beamFrames/s=%.0f gtaPackets/s=%.0f puppetUpdates/s=%.0f",
        stat.frames / (nowS - stat.t), stat.pkts / (nowS - stat.t), stat.puppetRate))
    end
    stat.frames, stat.pkts, stat.t = 0, 0, nowS
  end
  -- one-time dump of Michael's idle pose in his own frame (right, forward, up): ground truth for the puppet rest pose
  if engaged and not restDumped and ped.fresh and ped.sk and #ped.sk >= 54 and (ped.flags or 0) % 16 == 0
     and math.abs(ped.vx) + math.abs(ped.vy) < 0.05 then
    restDumped = true
    local h = math.rad(ped.heading or 0)
    local fx, fy, rx_, ry_ = -math.sin(h), math.cos(h), math.cos(h), math.sin(h)
    local t = {}
    for i = 1, 18 do
      local dx, dy, dz = ped.sk[i * 3 - 2] - ped.gx, ped.sk[i * 3 - 1] - ped.gy, ped.sk[i * 3] - ped.gz
      t[#t + 1] = string.format("{%.3f,%.3f,%.3f}", dx * rx_ + dy * ry_, dx * fx + dy * fy, dz)
    end
    log("I", logTag, "restdump " .. table.concat(t, ","))
  end
  if cfg.autoEngage and not engaged and not manualOff and ped.fresh and getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    autoAt = autoAt or (nowS + 3)   -- let the level settle first
    if nowS >= autoAt then autoAt = nil guard(engage) end
  else
    autoAt = nil
  end
  local onFoot = true
  local afoot = engaged and getWalker() ~= nil
  holdTab(afoot)
  guard(updateWheel, afoot and not entering and ped.fresh and math.floor((ped.flags or 0) / 524288) % 2 == 1)
  if (ped.shotsDue or 0) > 0 then
    local n = ped.shotsDue
    ped.shotsDue = 0
    if afoot and cfg.bullets then
      local pts = skeletonPoints()
      guard(shoot, n, pts and pts[12])   -- (12: his right hand)
    end
  end
  if engaged then
    local nowR = socket.gettime()
    if nowR - paceT > 2 then   -- (said again every two seconds: a lost message must not leave GTA at the wrong pace, or in slow motion)
      paceT = nowR
      send(string.format("M|pace|%.2f|%.2f", cfg.runPace, cfg.sprintPace))
      send(string.format("M|slow|%.2f", slow))
    end
    patchWalk()
    onFoot = getWalker() ~= nil
    if onFoot then updateEntering() else entering = nil end
    if not onFoot then
      if not riding then
        riding = true
        log("I", logTag, "player is in a vehicle: Michael parked")
        parkBody()
        pcall(udp.sendto, udp, "Q|hide", cfg.host, 47202)   -- gone this very frame (not when the overlay notices the poses stopped)
        if commands.isFreeCamera() then pcall(commands.setGameCamera) end
        -- Tab (unlike F) leaves the walker lying under the road where the bridge kept it: remove it, BeamNG makes a new one on exit
        local u = walkerId and getObjectByID(walkerId)
        if u and u:getJBeamFilename() == "unicycle" and u:getActive() then pcall(function() u:delete() end) end
        walkerId = nil
        walkerHave = false
      end
      if nowR - rideMsgT > 0.5 then rideMsgT = nowR; send("M|ride|1") end
      if lastGround then   -- W keeps his platform under him in GTA
        local gx, gy, gz = beamToGta(walkerFeet.x, walkerFeet.y, walkerFeet.z)
        seq = seq + 1
        send(string.format("W|%d|%.3f|%.3f|%.3f", seq, gx, gy, gz))
      end
    elseif riding then
      riding = false
      send("M|ride|0")
      needOffset = true
      offsetAt = nowR + 0.5
      lastGround = nil
      cam.pivot = nil
      hist = {}
      log("I", logTag, "player is on foot again: re-anchoring Michael")
    end
  end
  if engaged and onFoot then
    if needOffset and socket.gettime() < offsetAt then
      -- waiting for the new walker to be placed
    elseif needOffset and computeOffset() then
      needOffset = false
      -- GTA owns the ped's XY, so the anchor mapping alone never moves him: tell GTA to put him on the anchor (open ocean)
      send(string.format("T|%d|%.2f|%.2f|%.2f", seq, cfg.anchorX, cfg.anchorY, cfg.anchorZ))
      tpCheck, tpSent, tpTries = true, socket.gettime(), 0
      arriveT = socket.gettime()
    end
    if arriveT and ped.fresh and ped.gx then
      local there = math.abs(ped.gx - cfg.anchorX) + math.abs(ped.gy - cfg.anchorY) < 3 and math.floor((ped.flags or 0) / 2048) % 2 == 0
      if there or socket.gettime() - arriveT > 3 then   -- (3 s: never keep him hidden for good if GTA does not answer)
        arriveT = nil
        bodyHoldT = socket.gettime() + 1.0
      end
    end
    if tpCheck and not needOffset and ped.fresh and ped.gx then
      if math.abs(ped.gx - cfg.anchorX) + math.abs(ped.gy - cfg.anchorY) < 200 then
        tpCheck = false
      elseif socket.gettime() - tpSent > 0.5 and tpTries < 20 then
        tpTries = tpTries + 1
        tpSent = socket.gettime()
        send(string.format("T|%d|%.2f|%.2f|%.2f", seq, cfg.anchorX, cfg.anchorY, cfg.anchorZ))
      end
    end
    if not needOffset then guard(sendWalker) end
    guard(sendCamera)
    if engaged then
      local pts = skeletonPoints()
      if pts then
        guard(drawSkeleton, pts)
        if not cfg.compose then guard(cfg.usePuppet and drawPuppet or drawBody, pts) end
        if cfg.thirdPerson then
          if not commands.isFreeCamera() then commands.setFreeCamera() end
          pcall(core_camera.setSpeed, 2)   -- WASD must not fly the camera away from him
        end
      end
      guard(sendPose)
      guard(updateBody)
      guard(wallsNearby)
    end
  end
  local now = socket.gettime()
  if now - lastVehSend >= 1 / cfg.vehicleHz then
    lastVehSend = now
    guard(sendWorld)
  end
end

-- never let a bridge bug throw into BeamNG's frame loop: log it once and carry on
local function onUpdate(dtReal, dtSim)
  if not running then return end
  guard(tick)
end

local function onPreRender()
  if engaged and running and not riding and not commands.isFreeCamera() then guard(sendPose) end
  if #holes > 0 or #tracers > 0 then guard(drawHoles) end
end

-- BeamNG calls this from inside its camera update, once the free camera has its rotation for this frame and before the frame is drawn
local function onCameraPreRender(cd)
  if not (engaged and running and not riding and cd and cd.res) then return end
  guard(function()
    local pts = skeletonPoints()
    if pts then chaseCam(pts, cd) end
    sendPose(cd)
  end)
end

local function onExtensionLoaded()
  loadConfig()
  start() -- listening is harmless; nothing moves until engage()
end

local function onExtensionUnloaded()
  holdTab(false)
  unpatchWalk()
  stop()
end

local function puppetStat(n)   -- called by the puppet vehicle every 300 updates
  local now = socket.gettime()
  if stat.puppetT > 0 and now > stat.puppetT then stat.puppetRate = (n - stat.puppetN) / (now - stat.puppetT) end
  stat.puppetN, stat.puppetT = n, now
end

local function onClientEndMission()
  sunObj = nil
  engaged = false
  manualOff = false
  destroyBody()
  for i = #holes, 1, -1 do holes[i] = nil end
end

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onCameraPreRender = onCameraPreRender
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onClientEndMission

M.start = start
M.stop = stop
M.align = align
M.here = here
M.engage = engage
M.disengage = disengage
M.set = set
M.status = status
M.puppetStat = puppetStat
M.bulletReply = bulletReply

return M
