# Self-check for lua/vehicle/extensions/gtaBody.lua: one node, one axis, same numbers (read from the Lua file).
# Fails if the body stops keeping up with Michael, or starts pushing on cars harder than a person can.
import math, re, os, json
here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "..", "lua", "vehicle", "extensions", "gtaBody.lua")).read()
g = lambda pat: [float(x) for x in re.search(pat, src).groups()]
KE, VC = g(r"KE, V_CLOSE = ([\d.]+), ([\d.]+)"); KV, = g(r"KV = ([\d.]+)")
FN, AM = g(r"F_NEAR, A_MAX = ([\d.]+), ([\d.]+)"); EF, SNAP = g(r"E_FREE, SNAP = ([\d.]+), ([\d.]+)")
a, b = g(r"FREE = ([\d.]+) / ([\d.]+)"); FREE = a / b
EVERY, = g(r"EVERY = (\d+)"); EVERY = int(EVERY); dt = 0.0005
jb = json.load(open(os.path.join(here, "..", "vehicles", "gta_body", "gta_body.jbeam")))["gta_body"]["nodes"]
W = [r[4]["nodeWeight"] for r in jb if isinstance(r, list) and len(r) == 5 and isinstance(r[4], dict)]
cap = lambda a, c: max(-c, min(c, a))

def run(target, m, T=4.0, wall=None, fps=50, v0=0.0):
    AN = min(AM, FN / m); AF = AN * FREE
    step = 0; tgt = target(0); tv = 0.0; raw = tgt; rawt = 0.0; nextset = 0.0; worst = 0.0; imp = 0.0; x = tgt; v = v0
    while step * dt < T:
        step += 1; now = step * dt
        if now >= nextset:   # a BeamNG frame: new joint position, its speed by difference
            p = target(now); tv = (p - raw) / (now - rawt) if now > rawt else 0.0; tgt = p; raw = p; rawt = now; nextset += 1.0 / fps
        a = 0.0
        if step % EVERY == 0:
            tgt += tv * dt * EVERY; e = tgt - x
            if abs(e) > SNAP: x = tgt
            else:
                a = cap((tv + cap(e * KE, VC) - v) * KV, AF if abs(e) > EF else AN) * EVERY
                if wall is not None and x >= wall and a > 0: imp += a * dt * m; a = 0.0   # pressed on the car: this goes into the car (N s)
        v += a * dt; x += v * dt
        if wall is not None and x > wall: x = wall; v = min(v, 0.0)
        if now > T - 1.0: worst = max(worst, abs(target(now) - x))
    return worst, imp

trunk = run(lambda t: 0.05 * math.sin(2 * math.pi * 3 * t) + 4.0 * t, max(W), v0=4.0)[0]   # heaviest node, running with a bob
hand = run(lambda t: 0.3 * math.sin(2 * math.pi * 2 * t) + 4.0 * t, min(W), v0=4.0)[0]     # lightest, swinging 0.3 m at 2 Hz
cold = run(lambda t: 4.0 * t, max(W), T=8.0)[0]                                             # dropped in at rest while he runs
step_ = run(lambda t: 0.0 if t < 0.5 else 0.25, max(W))[0]                                  # a 25 cm jump in the data
imp = sum(run(lambda t: 1.5 * t, m, T=0.9, wall=0.5)[1] for m in W)                         # whole body walking "through" a car
print("%d kg; trunk %.3f m, hand %.3f m, catch-up %.3f m, step %.3f m; leaning on a car: %.0f N on average" % (sum(W), trunk, hand, cold, step_, imp / 0.9))
assert trunk < 0.10 and hand < 0.25 and cold < 0.10 and step_ < 0.01, "the body no longer keeps up with him"
assert imp / 0.9 < 900, "the body pushes on cars harder than a person can"
print("ok")
