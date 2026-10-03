-- Self-check for the weapon wheel and the bullets. It runs the marked blocks of the real gtaBridge.lua and the real car-side file
-- (lua/vehicle/extensions/gtaBullet.lua) against BeamNG's own maths library and a made-up world: a leaning wall 20 m ahead and,
-- 10 m ahead, a "car" of one body panel with a window in front of it and a tire beside it.
--   luajit tools/check_guns.lua <BeamNG.drive>/lua/common/mathlib.lua
local here = arg[0]:match("^(.*)[/\\]") or "."
dofile(arg[1])
local src = io.open(here .. "/../lua/ge/extensions/gtaBridge.lua"):read("*a")
local code = {}
for block in src:gmatch("%-%- >>> checked[^\n]*\n(.-)%-%- <<< checked") do code[#code + 1] = block end
assert(#code == 2, "the two marked blocks")
code[#code + 1] = "return { wheelPick = wheelPick, updateWheel = updateWheel, fireBullet = fireBullet, holeAt = holeAt, holes = holes, bulletReply = bulletReply, LOADOUT = LOADOUT, WHEEL = WHEEL }"

local function near(a, b, tol) return math.abs(a - b) < (tol or 1e-4) end

-- ---- what the blocks expect to find around them
cfg = { bulletRange = 300, bulletPush = 6, bulletHoles = 3, wheelSlowMo = 0.2, wheelHold = 0.18 }
local PISTOL, FISTS = 0x1B06D571, 0xA2719263
ped, slow, sent = { weapon = PISTOL }, 1, {}
function send(m) sent[#sent + 1] = m end
local clock = 100
socket = { gettime = function() return clock end }

-- the map: one wall, the plane y - x/2 = 20
function castRayStatic(o, d, range)
  local den = d.y - 0.5 * d.x
  if den <= 0 then return range end
  local t = (20 - (o.y - 0.5 * o.x)) / den
  return (t > 0 and t < range) and t or range
end

-- the car, at (0, 10, 0). Nodes 0-2: a body panel in the plane y = 10. Nodes 3-5: a window half a metre in front of it, whose
-- part ("/car/glass") declares its corners and whose beams trigger the deform group "doorglass_break". Nodes 6-8: a tire, off to
-- the side at x = 5, holding wheel 0's air.
local carPos = vec3(0, 10, 0)
local nodes = {
  [0] = vec3(-1, 0, -1), vec3(1, 0, -1), vec3(0, 0, 1),
  vec3(-1, -0.5, -1), vec3(1, -0.5, -1), vec3(0, -0.5, 1),
  vec3(4, 0, -1), vec3(6, 0, -1), vec3(5, 0, 1),
}
local switch = { deformGroup = "doorglass_break" }
local vdata = {
  nodes = { [0] = {}, {}, {}, { partPath = "/car/glass" }, { partPath = "/car/glass" }, { partPath = "/car/glass" }, {}, {}, {} },
  flexbodies = { [0] = { mesh = "car_doorglass", deformGroup = "doorglass_break", partPath = "/car/glass" },
    { mesh = "car_headlightglass", deformGroup = "headlight_break", partPath = "/car" } },
  beams = { [0] = { id1 = 3, id2 = 4, cid = 0, deformGroup = "doorglass_break", deformSwitches = { switch } },
    { id1 = 4, id2 = 5, cid = 1, deformGroup = "doorglass_break", deformSwitches = { switch } },
    { id1 = 5, id2 = 3, cid = 2, deformGroup = "doorglass_break", deformSwitches = { switch } },
    -- (the window's beams reach the panel's corners as well, as a real pane's reach into the door: that must not make the panel glass)
    { id1 = 3, id2 = 0, cid = 6, deformGroup = "doorglass_break", deformSwitches = { switch } },
    { id1 = 4, id2 = 1, cid = 7, deformGroup = "doorglass_break", deformSwitches = { switch } },
    { id1 = 5, id2 = 2, cid = 8, deformGroup = "doorglass_break", deformSwitches = { switch } },
    { id1 = 0, id2 = 1, cid = 3, deformGroup = "headlight_break", deformSwitches = { { deformGroup = "headlight_break" } } },
    { id1 = 1, id2 = 2, cid = 4, deformGroup = "headlight_break", deformSwitches = { { deformGroup = "headlight_break" } } },
    { id1 = 2, id2 = 0, cid = 5, deformGroup = "headlight_break", deformSwitches = { { deformGroup = "headlight_break" } } } },
  wheels = { [0] = { pressureGroup = "_wheelPressureGroup0" } },
  pressureGroups = { _wheelPressureGroup0 = 0 },
  triangles = { [0] = { id1 = 0, id2 = 1, id3 = 2 }, { id1 = 3, id2 = 4, id3 = 5 }, { id1 = 6, id2 = 7, id3 = 8, pressureGroup = "_wheelPressureGroup0" } },
}
local forces, toGE, did = {}, {}, {}
local carObj = {
  getPosition = function() return carPos end,
  getNodePosition = function(_, n) return nodes[n] end,
  applyForceVector = function(_, n, f) forces[n] = vec3(f) end,
  queueGameEngineLua = function(_, s) toGE[#toGE + 1] = s end,
  addParticleByNodesRelative = function() did.shards = (did.shards or 0) + 1 end,
  getId = function() return 7 end,
}
local carEnv = setmetatable({ obj = carObj, v = { data = vdata },
  tableSizeC = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
  beamstate = { deformGroupsTriggerBeam = {}, deflateTire = function(w) did.flat = w; carEnv_wheels[w].isTireDeflated = true end },
  material = { switchBrokenMaterial = function(b) did.broke = b.deformGroup end },
}, { __index = _G })
carEnv_wheels = { [0] = {} }
carEnv.wheels = { wheels = carEnv_wheels }
carEnv.extensions = { load = function(name)
  if not carEnv[name] then
    local f = assert(loadfile(here .. "/../lua/vehicle/extensions/" .. name .. ".lua"))
    setfenv(f, carEnv)
    carEnv[name] = f()
  end
end }
local veh = {
  getID = function() return 7 end, getJBeamFilename = function() return "pickup" end, getActive = function() return true end,
  getPosition = carObj.getPosition, getNodePosition = carObj.getNodePosition,
  queueLuaCommand = function(_, chunk) setfenv(assert(loadstring(chunk)), carEnv)() end,   -- run it as the car would
}
function getAllVehicles() return { veh } end
be = {
  getObjectOOBBIsInitialized = function() return true end,
  getObjectOOBBCenterXYZ = function() return carPos.x + 2.5, carPos.y, carPos.z end,
  getObjectOOBBHalfAxisXYZ = function(_, _, a) if a == 0 then return 4, 0, 0 elseif a == 1 then return 0, 1, 0 end return 0, 0, 1.5 end,
  getObjectByID = function(_, id) return id == 7 and veh or nil end,
}

-- BeamNG's wheel, as far as the bridge uses it: slots become positions the way quickAccess.lua does it ((slot - 1) / 8, an eighth wide)
local qa = { on = false, calls = {} }
core_quickAccess = qa
function qa.addEntry(e) qa.entry = e end
function qa.setSlowMoFactor(f) qa.slowmo = f end
function qa.resetSlowMoFactor() qa.slowmo = nil end
function qa.setEnabled(on, level) qa.on = on; qa.level = on and level or nil; qa.calls[#qa.calls + 1] = on end
function qa.isEnabled() return qa.on end
function qa.getUiData()
  local items = {}
  qa.entry.generator(items)
  for _, it in ipairs(items) do it.position, it.size = (it.startSlot - 1) / 8, 1 / 8 end
  table.sort(items, function(a, b) return a.position < b.position end)
  qa.items = items
  return { currentLevel = qa.level, items = items }
end
function qa.selectItem(i) local r = qa.items[i].onSelect() if r[1] == "hide" then qa.on = false end end
local cursor = { x = 960, y = 594 }   -- a 1920 x 1080 window: the hub is at 960, 594
Point2I = function(x, y) return { x = x, y = y } end
scenetree = { findObject = function() return {
  getCursorPos = function() return cursor end,
  getWindowClientSizeXY = function() return 1920, 1080 end,
  clientToScreenXY = function() return 0, 0 end } end }

local G = assert(loadstring(table.concat(code, "\n")))()
gtaBridge = { bulletReply = G.bulletReply }
local function answer() for _, s in ipairs(toGE) do assert(loadstring(s))() end toGE = {} end
local function hold(dt) clock = clock + dt; G.updateWheel(true) end   -- Tab down for another dt seconds
local function letGo() clock = clock + 0.02; G.updateWheel(false) end

-- ---- Tab tapped: the gun goes away, and comes back on the next tap; the wheel never shows
hold(0); hold(0.1); letGo()
assert(#sent == 1 and sent[1] == "M|weapon|0" and #qa.calls == 0 and slow == 1, "a tap with a gun out: fists, no wheel, no slow motion")
ped.weapon = FISTS
hold(0); letGo()
assert(sent[2] == "M|weapon|1", "a tap with nothing in his hands: the gun he last had (the pistol)")
ped.weapon = 0x2BE6766B; G.updateWheel(false); ped.weapon = FISTS
hold(0); letGo()
assert(sent[3] == "M|weapon|2", "... which is the SMG once he has had that out")
ped.weapon = PISTOL

-- ---- Tab held: the wheel, every weapon where GTA has it, the empty places picking nothing
sent = {}
hold(0); hold(0.1)
assert(not qa.on, "not yet")
hold(0.1)
assert(qa.on and qa.level == G.WHEEL and qa.slowmo == 0.2 and sent[#sent] == "M|slow|0.20" and slow == 0.2, "Tab held brings the wheel up and slows both games")
local ui = qa.getUiData()
local function at(dx, dy) local i = G.wheelPick(ui.items, dx, dy) return i and ui.items[i].title end
assert(at(0, 0.2) == "Pistol" and at(0.2, 0.2) == "SMG" and at(0.2, 0) == "Carbine Rifle", "top, top right, right")
assert(at(0, -0.2) == "Unarmed" and at(-0.2, -0.2) == "Pump Shotgun", "bottom, bottom left")
assert(at(-0.2, 0) == nil and at(-0.2, 0.2) == nil and at(0.2, -0.2) == nil, "the empty places")
assert(at(0.03, 0.03) == nil, "inside the hub")
for _, it in ipairs(ui.items) do assert((it.color ~= nil) == (it.title == "Pistol"), "the weapon in his hands is the one marked") end

hold(0.1)                                             -- held: the pointer is first seen, at the hub
cursor = { x = 1160, y = 594 }                        -- moved to the right
letGo()
assert(sent[#sent - 1] == "M|weapon|3" and sent[#sent] == "M|slow|1.00" and slow == 1, "letting go takes the rifle and ends the slow motion")
assert(not qa.on and qa.slowmo == nil, "and shuts the wheel")

sent = {}
hold(0); hold(0.2); hold(0.1); letGo()                -- held, pointer not moved (it lies to the right of the hub)
assert(#sent == 2 and sent[1] == "M|slow|0.20" and sent[2] == "M|slow|1.00" and not qa.on, "the wheel shut without moving the pointer picks nothing")

sent = {}
hold(0); hold(0.2); hold(0.1)
qa.selectItem(1)                                      -- a click on a weapon, Tab still down
hold(0.1)
assert(slow == 1 and sent[#sent] == "M|slow|1.00", "a click ends the slow motion at once")
local n, m = #qa.calls, #sent
hold(0.5); letGo()
assert(#qa.calls == n and #sent == m, "and holding on or letting go afterwards does nothing more")

-- ---- bullets
-- at the window: it breaks (no mark on it), the shot goes on into the panel behind and marks that; the wall behind has nothing
local to = G.fireBullet(vec3(0.2, 0, -0.3), vec3(0, 1, 0)); answer()
assert(did.broke == "doorglass_break" and did.shards == 2 and carEnv.beamstate.deformGroupsTriggerBeam.doorglass_break == 0, "the window breaks, once, with its shards")
assert(#G.holes == 1 and G.holes[1].veh == 7 and G.holes[1].a == 0, "the mark is on the panel behind the window, not on the glass or the wall")
local p, nrm, under = G.holeAt(G.holes[1])
assert(near(p.x, 0.2) and near(p.y, 10) and near(p.z, -0.3) and near(math.abs(nrm.y), 1) and under > 0, "where the shot went in")
local sum = forces[0] + forces[1] + forces[2]
assert(near(sum.x, 0) and near(sum.y, 12000, 1e-2) and near(sum.z, 0), "6 newton-seconds, all of it along the shot")
assert(near(to.y, 20.1) and near(to.x, 0.2), "the streak ends where the map stops the shot")
did = {}
G.fireBullet(vec3(0.2, 0, -0.3), vec3(0, 1, 0)); answer()
assert(did.broke == nil and #G.holes == 2, "broken glass is not broken again: the next shot goes straight to the panel")
carPos = vec3(3, 12, 1)                               -- the car drives off: the marks go with it
p = G.holeAt(G.holes[1])
assert(near(p.x, 3.2) and near(p.y, 12) and near(p.z, 0.7), "the mark rides on the car")
carPos = vec3(0, 10, 0)

-- the headlight's deform group has "glass" in its mesh name too, but lamps are left alone: the panel it sits on is bodywork
assert(carEnv.beamstate.deformGroupsTriggerBeam.headlight_break == nil, "a lamp is not a window")

-- at the tire: flat, no mark on it and none on the wall behind; a second shot goes through the flat tire to the wall
G.fireBullet(vec3(5, 0, 0), vec3(0, 1, 0)); answer()
assert(did.flat == 0 and #G.holes == 2, "the tire goes flat and takes no mark")
G.fireBullet(vec3(5, 0, 0), vec3(0, 1, 0)); answer()
assert(#G.holes == 3 and not G.holes[3].veh and near(G.holeAt(G.holes[3]).y, 22.5), "a flat tire stops nothing: the wall has it")

-- through the car's box but past everything in it: the wall has it, facing the shooter along the wall's own slope
G.fireBullet(vec3(2.5, 0, 0), vec3(0, 1, 0)); answer()
assert(#G.holes == 3 and not G.holes[3].veh, "missed the car: the wall is hit (and only the newest marks are kept)")
p, nrm = G.holeAt(G.holes[3])
assert(near(p.x, 2.5) and near(p.y, 21.25) and near(p.z, 0), "where the ray meets the wall")
assert(near(nrm.x, 0.5 / math.sqrt(1.25), 1e-3) and near(nrm.y, -1 / math.sqrt(1.25), 1e-3) and near(nrm.z, 0, 1e-3), "the wall's normal, towards the shooter")

-- nowhere near the car: no car is asked. Into the sky: nothing.
G.fireBullet(vec3(20, 0, 0), vec3(0, 1, 0))
assert(#toGE == 0 and near(G.holeAt(G.holes[3]).y, 30), "a clear shot at the wall")
G.fireBullet(vec3(20, 0, 0), vec3(0, -1, 0))
assert(#G.holes == 3 and near(G.holeAt(G.holes[3]).y, 30), "a shot that hits nothing leaves nothing")
print("ok")
