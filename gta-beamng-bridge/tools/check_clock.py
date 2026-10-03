# Self-check of packetAge() in gtaBridge.lua (same rule, re-stated): GTA makes a packet every 1/60 s on its own clock, BeamNG reads at
# its own 45 fps on another clock. The age worked out for each packet must match how long it really waited, so that
# position + velocity * age puts him where he truly is at each BeamNG frame.
import random
random.seed(1)
offset = 1234.567            # GTA's clock is this far behind BeamNG's
window, v = [], 4.0          # he runs at 4 m/s
def packet_age(now, gt):
    window.append(now - gt)
    if len(window) > 120: window.pop(0)
    return min(0.1, now - gt - min(window))
worst_naive = worst = 0.0
t_read, n = 0.0, 0
for frame in range(2000):
    t_read += 1 / 45 + random.uniform(-0.003, 0.003)
    k = int((t_read - 0.0005) * 60)                  # newest packet that has arrived (0.5 ms on the wire)
    made = k / 60
    age = packet_age(t_read, made - offset)
    true_x = v * t_read
    if frame > 200:                                  # once the window has seen a freshly made packet
        worst_naive = max(worst_naive, abs(true_x - v * made))
        worst = max(worst, abs(true_x - (v * made + v * age)))
        n += 1
assert worst_naive > 0.05          # without it: more than 5 cm of error that changes from frame to frame
assert worst < 0.006               # with it: within a few millimetres
print("ok  (error at a run: %.1f cm before, %.1f cm now)" % (worst_naive * 100, worst * 100))
