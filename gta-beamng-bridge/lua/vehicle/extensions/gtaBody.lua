-- gtaBody: vehicle-side half of Michael's physical body in BeamNG (GE half: updateBody in gtaBridge.lua).
-- Each node is a real mass (95 kg in all: a heavy-set man; the nodeWeights in gta_body.jbeam scale it). Every few physics steps
-- a node is steered towards its joint of
-- GTA's skeleton: it is asked to move as the joint moves, plus a closing speed towards it, and the push that makes it do so is
-- capped per node at F_NEAR (a hand may be whipped about, the trunk only leaned with). So it keeps up with him in free space
-- but cannot shove a car; what a car feels when it hits him is his mass, nothing added. Further than E_FREE from its joint
-- something is holding it: the push drops to a sixth, so it trails him without pressing on that; beyond SNAP (he was thrown,
-- teleported or parked) it is put there.
local M = {}
local NAMES = { "pelvis", "chest", "neck", "head", "upperL", "foreL", "handL", "upperR", "foreR", "handR", "calfL", "footL", "calfR", "footR" }
local KE, V_CLOSE = 10, 2.5       -- closing speed asked for per metre of error (1/s), and its limit (m/s)
local KV = 40                     -- how hard a speed error is corrected (1/s)
local F_NEAR, A_MAX = 200, 60     -- cap on the push per node (N), and on the acceleration that gives a light node (m/s^2)
local FREE = 1 / 6                -- how much of it is left once the node is held back
local E_FREE, SNAP = 0.30, 1.5    -- metres
local EVERY = 4                   -- act every 4th physics step (500 Hz)
local cid, mass, acap = {}, {}, {}
local tgt, tv, raw = {}, {}, {}   -- per node: where its joint is now, how fast the joint moves, and the joint as last received
local pedVel = vec3(0, 0, 0)
local ready, step, clock, rawClock, age = false, 0, 0, -1, 0

local function init()
  local byName = {}
  for c, n in pairs(v.data.nodes) do
    if n.name then byName[n.name] = n.cid or c end
  end
  for i, name in ipairs(NAMES) do
    cid[i] = byName[name]
    mass[i] = cid[i] and obj:getNodeMass(cid[i]) or 5
    acap[i] = math.min(A_MAX, F_NEAR / mass[i])
  end
  ready = true
  enablePhysicsStepHook()
end

-- csv: his velocity (3 numbers), then the joints in NAMES order (x,y,z each); world coordinates
local function set(csv)
  if not ready then init() end
  local f, n = {}, 0
  for num in string.gmatch(csv, "[^,]+") do n = n + 1; f[n] = tonumber(num) end
  if n < 3 + #NAMES * 3 then return end
  local o = obj:getPosition()
  pedVel:set(f[1], f[2], f[3])
  local dtSet = clock - rawClock
  local diff = raw[1] and dtSet > 0.004 and dtSet < 0.15   -- two updates close together: the joints' own speeds can be measured
  for i = 1, #NAMES do
    local p = vec3(f[i * 3 + 1] - o.x, f[i * 3 + 2] - o.y, f[i * 3 + 3] - o.z)
    local jv = pedVel
    if diff then
      jv = (p - raw[i]) / dtSet
      if jv:squaredLength() > 400 then jv = pedVel end   -- over 20 m/s is a jump in the data, not a movement
    end
    tgt[i], tv[i], raw[i] = p, vec3(jv.x, jv.y, jv.z), vec3(p.x, p.y, p.z)
  end
  rawClock, age = clock, 0
end

-- he is in a car: hold the body 150 m up, out of everything's way
local function park()
  if not ready then init() end
  for i = 1, #NAMES do tgt[i], tv[i] = vec3(i * 0.3, 0, 150), vec3(0, 0, 0) end
  raw, age = {}, 0
end

local function capped(x, y, z, cap)
  local a = math.sqrt(x * x + y * y + z * z)
  if a > cap then
    local k = cap / a
    return x * k, y * k, z * k
  end
  return x, y, z
end

local function onPhysicsStep(dt)
  clock = clock + dt
  step = step + 1
  if step % EVERY ~= 0 or not tgt[1] then return end
  local h = dt * EVERY
  age = age + h
  local adv = age < 0.1 and h or 0   -- between updates the joints carry on at their speed (but not for long if the updates stop)
  for i = 1, #NAMES do
    local c, t, jv = cid[i], tgt[i], tv[i]
    if c then
      t.x, t.y, t.z = t.x + jv.x * adv, t.y + jv.y * adv, t.z + jv.z * adv
      local p = obj:getNodePosition(c)
      local ex, ey, ez = t.x - p.x, t.y - p.y, t.z - p.z
      local d2 = ex * ex + ey * ey + ez * ez
      if d2 > SNAP * SNAP then
        obj:setNodePosition(c, t)
      else
        local nv = obj:getNodeVelocityVector(c)
        local cx, cy, cz = capped(ex * KE, ey * KE, ez * KE, V_CLOSE)   -- wanted speed = the joint's + closing in on it
        local ax, ay, az = capped((jv.x + cx - nv.x) * KV, (jv.y + cy - nv.y) * KV, (jv.z + cz - nv.z) * KV,
          d2 > E_FREE * E_FREE and acap[i] * FREE or acap[i])
        local m = mass[i] * EVERY   -- one push stands in for EVERY steps
        obj:applyForceVector(c, vec3(ax * m, ay * m, (az + 9.81) * m))   -- + his own weight, so he does not sag
      end
    end
  end
end

local function onReset()
  tgt, raw = {}, {}   -- the origin just moved: wait for the next set()
end

M.set = set
M.park = park
M.onPhysicsStep = onPhysicsStep
M.onReset = onReset
return M
