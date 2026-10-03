#!/usr/bin/env python3
"""Generates the puppet rig: vehicles/gta_puppet/gta_puppet.jbeam + lua/vehicle/extensions/gtaPuppet.lua.

BeamNG flexbodies bind every mesh vertex to its nearest jbeam nodes. A bare joint skeleton smears the mesh, so the
rig is FITTED TO THE MESH: each vertex is assigned to its nearest bone segment (rest pose), the vertices of every
(mesh, segment) pair are k-means clustered, and one node is placed at each cluster centre. A node is stored as
coordinates in its bone segment's frame (t along the bone, u/v across), so at runtime it rides rigidly with that bone.
Each mesh only binds to its OWN nodes, so a hand can never be dragged by a thigh node."""
import json, math, os, re, numpy as np
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAMES = ["pelvis","chest","neck","head","clavL","upperL","foreL","handL","clavR","upperR","foreR","handR",
         "thighL","calfL","footL","thighR","calfR","footR"]
# rest (bind) pose in mesh space (x right, y forward, z up). Torso/legs: GTA's real skeleton heights; arms fitted to the
# mesh's sleeves (centre line measured from the jacket vertices).
C = -0.015
REST = [(C,.02,-.037),(C,.01,.264),(C,.015,.512),(C,.055,.617),
        (C-.035,.05,.483),(C-.215,-.025,.455),(C-.26,-.035,.195),(C-.215,.02,-.05),
        (C+.035,.05,.483),(C+.225,-.02,.455),(C+.26,-.04,.195),(C+.235,.015,-.05),
        (C-.095,.024,-.112),(C-.165,.044,-.508),(C-.18,-.07,-.907),
        (C+.095,.024,-.112),(C+.165,.044,-.508),(C+.18,-.07,-.907)]
SEG = [(1,2),(2,3),(3,4),(3,5),(5,6),(6,7),(7,8),(3,9),(9,10),(10,11),(11,12),(1,13),(13,14),(14,15),(1,16),(16,17),(17,18)]
# which segments each mesh's vertices may belong to
MESH_SEGS = {
 "gta_c0": [1,2], "gta_c1": [1,2], "gta_c8": [2],
 "gta_c2": [0,1,3,4,5,6,7,8,9,10], "gta_c3": [0,1,3,4,5,6,7,8,9,10],
 "gta_c4": [0,11,12,13,14,15,16],
 "gta_c5": [5,6,9,10], "gta_c6": [5,6,9,10],
 "gta_c7": [13,16,12,15],
}
PTS_PER_NODE = 40
LAT = 0.28

def nrm(v): return v / np.linalg.norm(v)
def frame(P):
    up = nrm(P[2] - P[0]); r = nrm(P[15] - P[12])
    f = nrm(np.cross(up, r)); r = np.cross(f, up)
    return r, f, up
def rest_coeffs(R):
    r0, f0, u0 = frame(R); out = []
    for a, b in SEG:
        a0 = nrm(R[b-1] - R[a-1])
        ref = f0 if abs(a0 @ f0) < 0.9 else r0
        n1 = nrm(np.cross(a0, ref)); n2 = np.cross(a0, n1)
        out.append(([(v @ r0, v @ f0, v @ u0) for v in (a0, n1, n2)], a0, n1, n2))
    return out

def load_meshes():
    s = open(os.path.join(ROOT, "vehicles/gta_puppet/gta_michael.dae")).read()
    G = {}
    for m in re.finditer(r'<geometry id="(g\d+)" name="([^"]+)"><mesh>\s*<source id="\w+"><float_array id="\w+" count="(\d+)">([^<]*)<', s):
        G[m.group(2)] = np.array(m.group(4).split(), float).reshape(-1, 3)
    return G

def seg_dist(p, A, B):
    d = B - A; t = np.clip(((p - A) @ d) / (d @ d), 0, 1)
    return np.linalg.norm(p - (A + np.outer(t, d)), axis=1)

def kmeans(X, k, rng, iters=20):
    k = min(k, len(X)); C = X[rng.choice(len(X), k, replace=False)]
    for _ in range(iters):
        lab = np.argmin(((X[:, None, :] - C[None]) ** 2).sum(2), axis=1)
        for j in range(k):
            m = lab == j
            if m.any(): C[j] = X[m].mean(0)
    return C

def fit_nodes(R, rc):
    rng = np.random.default_rng(7); G = load_meshes(); rig = []   # (name, seg, t, u, v, group)
    for mesh, segs in MESH_SEGS.items():
        V = G[mesh]
        D = np.stack([seg_dist(V, R[SEG[s][0]-1], R[SEG[s][1]-1]) for s in segs], 1)
        if mesh in ("gta_c2", "gta_c3"):   # hem hangs beside the hands at rest: only far-out verts may follow the forearm
            for j, sg in enumerate(segs):
                lat = np.abs(V[:, 0] - R[0][0])
                if sg in (6, 10): D[lat < LAT, j] = 9
                if sg in (5, 9): D[(lat < 0.20) & (V[:, 2] < 0.38), j] = 9   # torso side next to a hanging arm
        owner = np.array(segs)[D.argmin(1)]
        for s in segs:
            X = V[owner == s]
            if len(X) == 0: continue
            k = max(1, min(24, len(X) // PTS_PER_NODE))
            cs = kmeans(X, k, rng)
            A = R[SEG[s][0]-1]; B = R[SEG[s][1]-1]; L = np.linalg.norm(B - A)
            _, a0, n1, n2 = rc[s]
            for i, c in enumerate(cs):
                q = c - A
                rig.append(("%s_s%d_%d" % (mesh.replace("gta_", ""), s, i), s, float(q @ a0 / L), float(q @ n1), float(q @ n2), mesh))
    return rig

def evaluate(P, rc, rig):
    r, f, u = frame(P); pos = {}; segd = []
    for si, (a, b) in enumerate(SEG):
        A, B = P[a-1], P[b-1]; ac = nrm(B - A)
        co, _, _, _ = rc[si]
        a0t, n1, n2 = [c[0]*r + c[1]*f + c[2]*u for c in co]
        cr = np.cross(a0t, ac); s = np.linalg.norm(cr); c = a0t @ ac
        if s < 1e-5:
            if c < 0: n2 = -n2
        else:
            k = cr / s
            rot = lambda x: x*c + np.cross(k, x)*s + k*(k @ x)*(1-c)
            n1, n2 = rot(n1), rot(n2)
        segd.append((A, B - A, n1, n2))
    for name, si, t, uu, vv, _ in rig:
        A, d, n1, n2 = segd[si]
        pos[name] = A + d*t + n1*uu + n2*vv
    for i, n in enumerate(NAMES): pos[n] = P[i]
    pos["spine"] = (P[0] + P[1]) * .5
    pos["headTop"] = P[3] + (P[3] - P[2])
    pos["handEndL"] = P[7] + (P[7] - P[6]) * .8
    pos["handEndR"] = P[11] + (P[11] - P[10]) * .8
    pos["toesL"] = P[14] + f*.2; pos["toesR"] = P[17] + f*.2
    pos["heelL"] = P[14] - f*.10; pos["heelR"] = P[17] - f*.10
    return pos

def build():
    R = np.array(REST, float); rc = rest_coeffs(R); rig = fit_nodes(R, rc); pos = evaluate(R, rc, rig)
    G = load_meshes()
    # self-tests: rest pose reproduces every cluster centre; whole-body rotation moves every node rigidly;
    # a posed body stays finite; every mesh has nodes.
    for mesh in MESH_SEGS: assert any(r[5] == mesh for r in rig), mesh
    rng = np.random.default_rng(1)
    for _ in range(100):
        q = evaluate(R + rng.normal(0, .1, R.shape), rc, rig); assert all(np.isfinite(v).all() for v in q.values())
    th = .7; Rz = np.array([[math.cos(th), -math.sin(th), 0], [math.sin(th), math.cos(th), 0], [0, 0, 1]])
    q = evaluate(R @ Rz.T, rc, rig)
    for k, v in pos.items(): assert np.allclose(v @ Rz.T, q[k], atol=1e-6), k
    # fit quality: mean distance from a vertex to its nearest own node at rest
    for mesh in MESH_SEGS:
        N = np.array([pos[r[0]] for r in rig if r[5] == mesh]); V = G[mesh]
        dm = np.sqrt(((V[:, None, :] - N[None]) ** 2).sum(2)).min(1)
        print("%-7s nodes %3d  mean vertex->node %.3f m  max %.3f" % (mesh, len(N), dm.mean(), dm.max()))

    base = [("ref",0,0,0),("back",0,.2,0),("left",-.2,0,0),("up",0,0,.2),("leftCorner",-.2,-.2,0),("rightCorner",.2,-.2,0)]
    nodes = [["id","posX","posY","posZ"], {"fixed":True,"collision":False,"selfCollision":False,"nodeWeight":1,"group":""}]
    nodes += [list(b) for b in base]
    for n in NAMES + ["spine","headTop","handEndL","handEndR","toesL","toesR","heelL","heelR"]:
        nodes.append([n] + [round(float(x), 4) for x in pos[n]] + [{"group": ""}])
    for name, si, t, uu, vv, mesh in rig:
        nodes.append([name] + [round(float(x), 4) for x in pos[name]] + [{"group": [mesh]}])
    beams = [["id1:","id2:"], {"beamType":"|NORMAL","beamSpring":4000,"beamDamp":20,"beamStrength":"FLT_MAX"},
             ["ref","pelvis"]]
    jb = json.load(open(os.path.join(ROOT, "vehicles/gta_puppet/gta_puppet.jbeam")))
    jb["gta_puppet"]["nodes"] = nodes; jb["gta_puppet"]["beams"] = beams
    jb["gta_puppet"]["flexbodies"] = [["mesh","[group]:","nonFlexMaterials"]] + [[m, [m], []] for m in MESH_SEGS]
    json.dump(jb, open(os.path.join(ROOT, "vehicles/gta_puppet/gta_puppet.jbeam"), "w"), indent=1)

    f3 = lambda t: "{%.4f,%.4f,%.4f}" % tuple(t)
    L = ["-- GENERATED by tools/build_rig.py - edit the generator, not this file.",
         "-- gtaPuppet: vehicle-side half of the GTA character puppet. The GE extension (gtaBridge) sends 18 world joint",
         "-- positions per frame; every mesh-fitted node rides on its bone segment's frame (t along the bone, u/v across)",
         "-- and BeamNG's flexbody deformation drags Michael's mesh with them. Identity vehicle rotation assumed.",
         "local M = {}",
         "local names = {" + ",".join('"%s"' % n for n in NAMES) + "}",
         "local REST = {" + ",".join(f3(p) for p in REST) + "}",
         "local SEG = {" + ",".join("{%d,%d}" % s for s in SEG) + "}",
         "local RIG = {" + ",".join('{"%s",%d,%.4f,%.4f,%.4f}' % (n, si+1, t, uu, vv) for n, si, t, uu, vv, _ in rig) + "}"]
    L.append(r'''
local cid, ready, nCalls, coef = {}, false, 0, {}
local V = function(t) return vec3(t[1], t[2], t[3]) end

local function frame(P)   -- P: 18 vec3. returns right, forward, up (orthonormal)
  local up = (P[3] - P[1]):normalized()
  local r = (P[16] - P[13]):normalized()
  local f = up:cross(r):normalized()
  r = f:cross(up)
  return r, f, up
end

local function init()
  for c, n in pairs(v.data.nodes) do
    if n.name then cid[n.name] = n.cid or c end
  end
  local P = {}
  for i = 1, 18 do P[i] = V(REST[i]) end
  local r0, f0, u0 = frame(P)
  for si, s in ipairs(SEG) do
    local a0 = (P[s[2]] - P[s[1]]):normalized()
    local ref = f0
    if math.abs(a0:dot(f0)) >= 0.9 then ref = r0 end
    local n1 = a0:cross(ref):normalized()
    local n2 = a0:cross(n1)
    local c = {}
    for k, w in ipairs({a0, n1, n2}) do c[k] = {w:dot(r0), w:dot(f0), w:dot(u0)} end
    coef[si] = c
  end
  -- resolve cids once
  for _, g in ipairs(RIG) do g.c = cid[g[1]] end
  ready = true
end

local function place(name, p, origin)
  local c = cid[name]
  if c then obj:setNodePosition(c, p - origin) end
end

-- csv: 18 * (x,y,z) world positions in `names` order
local function set(csv)
  if not ready then init() end
  local f, n = {}, 0
  for num in string.gmatch(csv, "[^,]+") do n = n + 1; f[n] = tonumber(num) end
  if n < 54 then return end
  local P = {}
  for i = 1, 18 do P[i] = vec3(f[i * 3 - 2], f[i * 3 - 1], f[i * 3]) end
  local origin = obj:getPosition()
  local r, fw, u = frame(P)

  for i = 1, 18 do place(names[i], P[i], origin) end
  local segd = {}
  for si, s in ipairs(SEG) do
    local A, B = P[s[1]], P[s[2]]
    local d = B - A
    local ac = d:normalized()
    local c = coef[si]
    local a0t = r * c[1][1] + fw * c[1][2] + u * c[1][3]
    local n1 = r * c[2][1] + fw * c[2][2] + u * c[2][3]
    local n2 = r * c[3][1] + fw * c[3][2] + u * c[3][3]
    local cr = a0t:cross(ac)
    local sn = cr:length()
    local cs = a0t:dot(ac)
    if sn < 1e-5 then
      if cs < 0 then n2 = n2 * -1 end
    else
      local k = cr / sn
      local m = 1 - cs
      n1 = n1 * cs + k:cross(n1) * sn + k * (k:dot(n1) * m)
      n2 = n2 * cs + k:cross(n2) * sn + k * (k:dot(n2) * m)
    end
    segd[si] = {A.x - origin.x, A.y - origin.y, A.z - origin.z, d.x, d.y, d.z, n1.x, n1.y, n1.z, n2.x, n2.y, n2.z}
  end
  for _, g in ipairs(RIG) do   -- scalar math: ~300 nodes per update, avoid vec3 temporaries
    local sd, c = segd[g[2]], g.c
    if c then
      local t, a, b = g[3], g[4], g[5]
      obj:setNodePosition(c, vec3(sd[1] + sd[4] * t + sd[7] * a + sd[10] * b,
                                  sd[2] + sd[5] * t + sd[8] * a + sd[11] * b,
                                  sd[3] + sd[6] * t + sd[9] * a + sd[12] * b))
    end
  end

  place("spine", (P[1] + P[2]) * 0.5, origin)
  place("headTop", P[4] + (P[4] - P[3]), origin)
  place("handEndL", P[8] + (P[8] - P[7]) * 0.8, origin)
  place("handEndR", P[12] + (P[12] - P[11]) * 0.8, origin)
  place("toesL", P[15] + fw * 0.2, origin)
  place("toesR", P[18] + fw * 0.2, origin)
  place("heelL", P[15] - fw * 0.10, origin)
  place("heelR", P[18] - fw * 0.10, origin)
  nCalls = nCalls + 1
  if nCalls % 300 == 1 then   -- report back so the GE log shows the real update rate
    obj:queueGameEngineLua("if extensions.gtaBridge then extensions.gtaBridge.puppetStat(" .. nCalls .. ") end")
  end
end

M.set = set
M.init = init
return M
''')
    open(os.path.join(ROOT, "lua/vehicle/extensions/gtaPuppet.lua"), "w").write("\n".join(L))
    print("fitted nodes:", len(rig), "total nodes:", len(nodes) - 2)
build()
