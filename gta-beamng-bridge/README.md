# GTA V on foot, inside BeamNG.drive

Your GTA V story-mode character walks around a BeamNG.drive map: GTA's own animation, ragdoll, voice and guns, on BeamNG's
ground, among BeamNG's cars. You play from the BeamNG window with a GTA-style third-person camera.

GTA V runs in the background and draws only the character, from the same viewpoint as BeamNG's camera. That picture is cut
out and pasted into BeamNG's frame every frame, hidden behind whatever BeamNG has in front of him and with a shadow cast on
BeamNG's world. BeamNG tells GTA where the ground, water, walls and nearby cars are, so he stands, swims, climbs and gets
knocked over in the right places.

**This is a hobby project in progress.** Parts of it are rough or untested; see "Known limits".

Nothing of Rockstar's is in this repository. The character is drawn live by your own copy of the game.

## What you need

- **GTA V** (Legacy, DirectX 11), story mode. **Never go online with any of this installed.**
- **BeamNG.drive** (made on 0.39).
- **Script Hook V** and **Script Hook V .NET** (v3) in the GTA folder.
- **ReShade with full add-on support** installed into both games (made on 6.8).
- A PC that can run both games at once.

## Install

| In this repository | Copy to |
|---|---|
| `lua/`, `scripts/`, `ui/`, `vehicles/`, `art/` | `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\gtaBridge\` |
| `reshade/beam_overlay.addon64` | `BeamNG.drive\Bin64\` |
| `reshade/GtaOverlay.fx` | `BeamNG.drive\Bin64\reshade-shaders\Shaders\` |
| `reshade/GtaPlaceholder.png` | `BeamNG.drive\Bin64\reshade-shaders\Textures\` |
| `gta/BeamBridge.3.cs` | `Grand Theft Auto V\scripts\` |
| `reshade/gta_capture.addon64` | `Grand Theft Auto V\` (next to `GTA5.exe`) |
| `reshade/GtaKey.fx` | `Grand Theft Auto V\reshade-shaders\Shaders\` |

Then:

1. In GTA's ReShade turn on the **GtaKey** effect; in BeamNG's turn on **GtaOverlay** (`reshade/preset_*.ini` hold the two lines).
2. In GTA's settings: windowed or borderless, **Pause Game On Focus Loss: off**, and do not mute audio on focus loss.
   Textures high, the rest low: only the character is ever seen.
3. Start GTA and load story mode. Start BeamNG and load a map. The bridge engages by itself once both are running: on foot in BeamNG, you are him.

## Controls (in the BeamNG window)

| | |
|---|---|
| Mouse | look |
| W A S D, Shift | walk, sprint |
| Space | jump, or climb what is in front of him; while aiming: combat roll |
| F | get into / out of the car he is standing at (GTA's animation, BeamNG's door) |
| Hold Tab | weapon wheel (BeamNG's radial menu, weapons where GTA has them); let go on one, or click it |
| Tap Tab | put the gun away / take the last one out |
| Right mouse, left mouse | aim, fire |

Shots land in BeamNG: a streak from the gun, a mark where they hit, a small push on the car, windows break, tires go flat.

## Settings

In BeamNG's console: `extensions.gtaBridge.set("name", value)`. They are saved in `settings/gtaBridge.json`. All of them,
with what they do, are at the top of `lua/ge/extensions/gtaBridge.lua`. A few:

| | |
|---|---|
| `camDist`, `camShoulder`, `camHeight` | the camera |
| `runPace`, `sprintPace` | how fast he moves |
| `bulletPush`, `bulletHoles`, `holeSize`, `tracer` | the bullets |
| `wheelSlowMo`, `wheelHold`, `wheelGhost` | the weapon wheel |
| `swim`, `walls`, `cars`, `bullets` | switch whole features off |

The overlay's look (shadow colour, brightness, water) is in ReShade's own menu in BeamNG, under GtaOverlay.
Frame pacing is in each game's `ReShade.ini` under `[GTABRIDGE]`: `FpsCap`, `FrameLock`, `KeepFocus` (GTA); `FpsCap`,
`GpuPriority`, `PoseLag` (BeamNG).

## How it is put together

| | |
|---|---|
| `lua/ge/extensions/gtaBridge.lua` | BeamNG side: camera, ground / water / walls / cars sent to GTA, doors, weapon wheel, bullets |
| `lua/vehicle/extensions/gtaBullet.lua` | runs inside each car that is shot: finds the hit, breaks glass, pops tires |
| `gta/BeamBridge.3.cs` | GTA side (Script Hook V .NET): moves the character from BeamNG's keys, keeps him on an invisible floor at BeamNG's ground height, sends his pose back |
| `reshade/gta_capture.cpp`, `GtaKey.fx` | GTA: cut the character out of the frame and hand it over through shared memory, in step with BeamNG's frames |
| `reshade/beam_overlay.cpp`, `GtaOverlay.fx` | BeamNG: paste him in, hide him behind what is nearer, cast his shadow |
| `tools/` | self-checks for the maths (`check_*.py`, `check_guns.lua`) and helpers |

The two games talk over UDP on this PC only (ports 47200 to 47202).

**Building the add-ons:** `reshade/*.cpp` are 64-bit DLLs built against ReShade's add-on headers (the `include` folder of
the ReShade source) and renamed to `.addon64`; `beam_overlay` also links `ws2_32`. The ones here were built with clang for
`x86_64-pc-windows-msvc`.

**Self-checks:** `python3 tools/check_ground.py` (and the other `check_*.py`);
`luajit tools/check_guns.lua <BeamNG.drive>/lua/common/mathlib.lua`.

## Known limits

- Both games at once is heavy, and the character's picture arrives a frame or two after BeamNG's; fast mouse turns show it.
- The combat roll, the footstep sound and the muting of GTA's sea and wind are first attempts and may not work on every setup.
- Which part of a car counts as window glass is worked out from the car's structure and is not exact (`tools/glass_rule.py`
  shows it for a given vehicle).
- A shot marks every car on its line, not only the first. Lamps do not break. Bullet marks are flat discs, not real decals.
- Rivers are not water yet (lakes and the sea are). If he is killed outright the bridge does not bring him back.
- While driving a BeamNG car there is no visible driver.
- `vehicles/gta_puppet` is an older way of showing him (a mesh inside BeamNG) and is not used by default. Its model and
  textures come from the game and are not here; `tools/build_rig.py` builds the rig from your own export.

## Not affiliated

Not made or endorsed by Rockstar Games, Take-Two or BeamNG. Script Hook V, Script Hook V .NET and ReShade are other people's
tools: get them from their own pages.
