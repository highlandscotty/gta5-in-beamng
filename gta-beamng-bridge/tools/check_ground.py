# Self-check of the ground rule in BeamBridge.3.cs UpdateGround (same numbers, re-stated here):
# GTA's floor is fixed; zoff follows BeamNG's ground; a jump in zoff moves the ped the other way so what BeamNG sees is continuous.
def step(ped_z, zoff, ground, dt, floor=0.0):
    d = (ground - floor) - zoff
    if abs(d) < 0.005: return ped_z, zoff, False
    h = ped_z - floor                      # feet above GTA's floor
    if d < -0.45 or (h > 0.25 and abs(d) > 0.2 and d < h + 0.1):
        return max(ped_z - d, floor), zoff + d, True   # moved the other way (never to below the floor)
    return ped_z, zoff + max(-5 * dt, min(5 * dt, d)), False

dt = 1 / 150
# a) walking up a 30 % slope at 3 m/s: he is never moved, and what BeamNG sees stays within 2 cm of the ground
z, zo, g = 0.0, 0.0, 0.0
for i in range(600):
    g += 0.9 * dt
    z, zo, moved = step(z, zo, g, dt)
    assert not moved and abs((z + zo) - g) < 0.02
# b) the ground drops 3 m (an edge): where BeamNG sees him does not change, and GTA has him 3 m up to fall from
z, zo = 0.0, g
seen = z + zo
z, zo, moved = step(z, zo, g - 3.0, dt)
assert moved and abs((z + zo) - seen) < 1e-9 and abs(z - 3.0) < 1e-9
# c) standing on a 0.9 m barrier when BeamNG's ground comes up to his feet (the wall top): same place in BeamNG, on the floor in GTA
z, zo, g = 0.9, 0.0, 0.0
seen = z + zo
z, zo, moved = step(z, zo, 0.9, dt)
assert moved and abs((z + zo) - seen) < 1e-9 and abs(z) < 1e-9
# d) a kerb (15 cm up) is followed, not jumped: done in about 30 ms
z, zo, t = 0.0, 0.0, 0.0
while abs(zo - 0.15) > 0.005:
    z, zo, moved = step(z, zo, 0.15, dt); t += dt
    assert not moved
assert t < 0.05
# e) the ground rises by a little more than he is above the floor: he ends on the floor, not in it
z, zo, moved = step(2.7, 0.0, 2.76, dt)
assert moved and z == 0.0

# Water (same rule as UpdateGround's swim part; heights of his feet here, so "centre below the surface - 0.2" is feet + 1.0)
def swim(ped_z, zoff, ground, water, swimming, sea=-60.0, floor=0.0):
    depth = water - ground
    if swimming:
        if depth < 0.9:
            nz = ground - floor
            return max(floor, ped_z + zoff - nz), nz, False
        return ped_z, water - sea, True
    if depth > 1.2 and ped_z + 1.0 + zoff < water - 0.2:
        nz = water - sea
        return ped_z + zoff - nz, nz, True
    return ped_z, zoff, False
# f) walking down a beach into the sea (surface at 10) and back: he goes in once past standing depth, at the same height BeamNG
#    saw him at, comes out once in the shallows, and never flips back and forth in between
water, flips, sw, z = 10.0, 0, False, 0.0
path = [10.5 - 0.01 * i for i in range(300)] + [7.5 + 0.01 * i for i in range(300)]
zo = path[0]
for g in path:
    if not sw: zo = g                       # (on foot zoff follows the ground: step() above)
    seen = z + zo
    z2, zo, sw2 = swim(z, zo, g, water, sw)
    if sw2 != sw:
        flips += 1
        if sw2: assert abs((z2 + zo) - seen) < 1e-9 and abs(z2 - (-60 - (water - g))) < 1e-9   # as deep under GTA's sea as under BeamNG's
        else: assert z2 == 0.0 and zo == g                                                      # standing on the floor again
    z, sw = z2, sw2
    if sw: z = -60.0 - 1.3                  # (GTA floats him: feet 1.3 m under its surface)
assert flips == 2 and not sw
print("ok")
