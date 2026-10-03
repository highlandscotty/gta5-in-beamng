-- A bullet from Michael's gun, on the receiving end (see "bullets" in ge/extensions/gtaBridge.lua). A car is a soft body that only
-- its own Lua can search: the bridge sends the shot's line here, this finds where it goes into the car's collision skin, gives the
-- shove there and answers with the spot, so the bridge can draw the mark. Glass breaks and lets the shot through; a tire goes flat.
local M = {}

-- What each triangle of the skin belongs to, where that matters, by its place in v.data.triangles: "g:<deform group>" for a pane of
-- glass, "w:<wheel>" for a tire. Bodywork has no entry. Worked out once, from the car's structure.
local part
local trigger   -- per glass deform group: one of the beams whose bending breaks the pane

-- is this deform group / mesh a window? (lamps have glass too, and break the same way, but stay as they are)
local function glassy(name)
  local n = string.lower(name):gsub("backlight", "rearwindow")   -- "backlight" is the rear window
  if n:find("light") or n:find("lamp") or n:find("signal") or n:find("mirror") or n:find("flasher") or n:find("beacon") then return false end
  return (n:find("glass") or n:find("windshield") or n:find("window") or n:find("sunroof")) ~= nil
end

local function sortParts()
  part, trigger = {}, {}
  local data = v.data
  -- tires: the triangles that hold a wheel's air
  local wheelOf = {}
  for id, w in pairs(data.wheels or {}) do
    if w.pressureGroup then
      wheelOf[w.pressureGroup] = id
      local n = data.pressureGroups and data.pressureGroups[w.pressureGroup]
      if n then wheelOf[n] = id end
    end
  end
  -- glass: a deform group that a glass mesh changes its look on. The pane is the triangles between the ends of the beams that
  -- trigger that group, and only those ends which the part carrying the mesh declares itself: the window's own corners, not the
  -- door or roof next to it (measured on the roamer, pickup and wigeon with tools/glass_rule.py: a door comes out as exactly its window).
  local carrier = {}
  for _, fb in pairs(data.flexbodies or {}) do
    local g = fb.deformGroup
    if type(g) == "string" and glassy(g .. " " .. tostring(fb.mesh)) then
      carrier[g] = carrier[g] or {}
      carrier[g][fb.partPath or ""] = true
    end
  end
  local ends, own = {}, {}
  for _, b in pairs(data.beams or {}) do
    if b.deformSwitches and b.deformGroup then
      for _, g in ipairs(type(b.deformGroup) == "table" and b.deformGroup or { b.deformGroup }) do
        if carrier[g] then
          trigger[g] = trigger[g] or b
          ends[g], own[g] = ends[g] or {}, own[g] or {}
          for _, n in ipairs({ b.id1, b.id2 }) do
            ends[g][n] = true
            local node = data.nodes[n]
            if node and carrier[g][node.partPath or ""] then own[g][n] = true end
          end
        end
      end
    end
  end
  local corners = {}
  for g in pairs(trigger) do
    local n = 0
    for _ in pairs(own[g]) do n = n + 1 end
    -- ponytail: a pane whose part declares no corners of its own gets all the beam ends, which takes in a strip of the bodywork
    -- round it. Tell them apart by the glass mesh itself if that ever shows (nothing in the vehicle's Lua gives its shape).
    corners[g] = n >= 3 and own[g] or ends[g]
  end
  local tris = data.triangles or {}
  for i = 0, tableSizeC(tris) - 1 do
    local t = tris[i]
    local w = t.pressureGroup and wheelOf[t.pressureGroup]
    if w then
      part[i] = "w:" .. w
    else
      for g, c in pairs(corners) do
        if c[t.id1] and c[t.id2] and c[t.id3] then part[i] = "g:" .. g break end
      end
    end
  end
end

-- already broken (by a shot or a crash)? Read from the car's own state, so a reset car is whole again here too.
local function broken(p)
  local name = p:sub(3)
  if p:sub(1, 1) == "g" then return beamstate.deformGroupsTriggerBeam[name] ~= nil end
  local w = wheels.wheels[tonumber(name)]
  return w ~= nil and w.isTireDeflated == true
end

-- ox..oz: where the shot starts (world), dx..dz: its direction, reach: how far it goes before the map stops it (m),
-- push: the shove (N, for one physics step), shot: the bridge's number for it
local function hit(ox, oy, oz, dx, dy, dz, reach, push, shot)
  if not part then sortParts() end
  local o, d = vec3(ox, oy, oz) - obj:getPosition(), vec3(dx, dy, dz)
  local at, gone = {}, {}
  local function corner(n)
    local p = at[n]
    if not p then p = vec3(obj:getNodePosition(n)) at[n] = p end
    return p
  end
  local tris = v.data.triangles or {}
  local count = tableSizeC(tris)
  for _ = 1, 4 do   -- (a shot carries on through the glass it breaks: a few panes in a row at most)
    -- the nearest triangle of the skin the line goes through, leaving out what is broken already
    local best, bu, bv, bt = nil, 0, 0, reach
    for i = 0, count - 1 do
      local p = part[i]
      if p and gone[p] == nil then gone[p] = broken(p) end
      if not (p and gone[p]) then
        local t = tris[i]
        local dist, tu, tv = intersectsRay_Triangle(o, d, corner(t.id1), corner(t.id2), corner(t.id3))
        if dist < bt then best, bu, bv, bt = i, tu, tv, dist end
      end
    end
    if not best then break end
    local t, p = tris[best], part[best]
    -- the shove, shared between the triangle's corners by how near the hit is to each
    local f = d * push
    obj:applyForceVector(t.id1, f * bu)
    obj:applyForceVector(t.id2, f * bv)
    obj:applyForceVector(t.id3, f * (1 - bu - bv))
    if not p then   -- bodywork: the shot stops here and leaves its mark
      obj:queueGameEngineLua(string.format("gtaBridge.bulletReply(%d, %d, %d, %d, %d, %f, %f)", shot, obj:getId(), t.id1, t.id2, t.id3, bu, bv))
      return
    elseif p:sub(1, 1) == "w" then   -- a tire: flat, and the shot stays in it (no mark on a tire)
      beamstate.deflateTire(tonumber(p:sub(3)))
      obj:queueGameEngineLua(string.format("gtaBridge.bulletReply(%d, %d)", shot, obj:getId()))
      return
    end
    -- glass: the pane takes its broken look (with its sound) and throws shards, as when a crash breaks it; the shot goes on
    local g = p:sub(3)
    material.switchBrokenMaterial(trigger[g])
    beamstate.deformGroupsTriggerBeam[g] = beamstate.deformGroupsTriggerBeam[g] or trigger[g].cid
    obj:addParticleByNodesRelative(t.id2, t.id1, 1, 68, 0.2, 15)
    obj:addParticleByNodesRelative(t.id2, t.id1, 1, 69, 0.2, 15)
    gone[p] = true
  end
  obj:queueGameEngineLua(string.format("gtaBridge.bulletReply(%d)", shot))   -- past (or clean through) this car
end

M.hit = hit
return M
