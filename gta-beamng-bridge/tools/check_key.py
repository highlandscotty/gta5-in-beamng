# Self-check of GtaKey.fx's water cut: under a camera that does not roll, a flat sea has the same nearness (near / depth) all along a
# screen row, so the farthest of a few points along the row is the water, and a pixel's height over it is (1 - w / n) camera heights.
import math
near, h, pitch, tanh, asp = 0.15, 1.5, math.radians(-20), math.tan(math.radians(30)), 16 / 9
def water(x, y):                                # nearness of the sea at uv (0,0 = top left)
    up = (1 - 2 * y) * tanh * math.cos(pitch) + math.sin(pitch)      # the ray's world-up part: x does not come into it
    return 0.0 if up >= 0 else near * -up / h
for y in [0.1, 0.3, 0.5, 0.7, 0.9, 0.99]:
    w = min(water(x, y) for x in [0.02, 0.2, 0.4, 0.6, 0.8, 0.98])
    for x in [0.1, 0.5, 0.9]:
        assert abs(water(x, y) - w) < 1e-12 and not water(x, y) > w * 1.08      # water: cut
    if w > 0:
        n = w / (1 - 0.10)                      # a point 10 % of the camera's height above the water: kept
        assert n > w * 1.08 and abs((1 - w / n) * h - 0.15) < 1e-9
print("ok")
