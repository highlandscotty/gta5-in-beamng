// BeamBridge.cs - GTA V side of the BeamNG <-> GTA V bridge.
// Runs under Script Hook V + ScriptHookVDotNet v3 (drop this file into GTA V\scripts).
// Written in plain C# 5 so SHVDN's runtime compiler accepts it.
//
// GTA keeps running in the background and owns the character (controls, animation, combat, ragdoll).
//   - Every frame it sends the ped state + a 18-point skeleton to BeamNG (UDP 127.0.0.1:47201).
//   - While the BeamNG window is focused it reads your keys/mouse buttons and injects them into
//     GTA's on-foot control system, with the GTA camera aligned to BeamNG's camera.
//   - It receives BeamNG vehicles and the ground height and builds invisible, frozen collision proxies.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using GTA;
using GTA.Math;
using GTA.Native;

public class BeamBridge : Script
{
    // ---- settings -------------------------------------------------------------------------
    const int ListenPort = 47200;          // BeamNG sends here
    const int BeamPort = 47201;            // BeamNG listens here
    const double CameraFreshSeconds = 0.5; // BeamNG camera packets older than this => stop injecting input
    const double ProxyStaleSeconds = 1.0;
    const float VehicleHitMinSpeed = 3.0f; // m/s
    // If the ped walks sideways relative to where the BeamNG camera looks (left/right swapped), set to -1f.
    const float CameraHeadingSign = 1f;

    // Virtual-key codes (change here to rebind). F is left free because BeamNG uses it for "enter/exit vehicle".
    const int VK_LBUTTON = 0x01, VK_RBUTTON = 0x02, VK_TAB = 0x09, VK_SPACE = 0x20;
    const int VK_A = 0x41, VK_D = 0x44, VK_E = 0x45, VK_G = 0x47, VK_Q = 0x51, VK_R = 0x52, VK_S = 0x53, VK_W = 0x57;
    const int VK_LSHIFT = 0xA0, VK_LCONTROL = 0xA2;

    // Skeleton bones sent to BeamNG, in this order (must match gtaBridge.lua).
    static readonly int[] BoneIds = new int[]
    {
        0x2E28, // 1  pelvis
        0x60F2, // 2  spine3
        0x9995, // 3  neck
        0x796E, // 4  head
        0xFCD9, // 5  L clavicle
        0xB1C5, // 6  L upper arm
        0xEEEB, // 7  L forearm
        0x49D9, // 8  L hand
        0x29D2, // 9  R clavicle
        0x9D4D, // 10 R upper arm
        0x6E5C, // 11 R forearm
        0xDEAD, // 12 R hand
        0xE39F, // 13 L thigh
        0xF9BB, // 14 L calf
        0x3779, // 15 L foot
        0xCA72, // 16 R thigh
        0x9000, // 17 R calf
        0xCC4D  // 18 R foot
    };

    static readonly string[] ProxyModelNames = new string[]
    {
        "bati", "panto", "blista", "asea", "baller", "granger", "bison", "mule", "benson", "bus", "phantom"
    };
    const string PlatformModelName = "trflat";

    // ---- win32 ----------------------------------------------------------------------------
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT pt; }
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);

    // ---- state ----------------------------------------------------------------------------
    class Proxy
    {
        public int BeamId;
        public Vehicle Veh;
        public double LastSeen;
        public Vector3 Velocity;
        public double LastHit;
        public float MinZ;
        public string ModelName = "";   // GTA model BeamNG asked for ("" = picked by size)
        public bool SeatKnown, SeatOk;  // driver seat measured / the model has one
        public Vector3 SeatLocal;       // driver seat bone relative to the vehicle origin (right, forward, up)
        public Vector3 Half;            // half the GTA model's width, length, height
        public bool Kinematic;          // BeamNG's car is moving: the stand-in is a real moving body in GTA (not frozen), steered by velocity
        public double Created;
    }

    class Candidate
    {
        public Model Model;
        public Vector3 Size; // x width, y length, z height
        public float MinZ;   // bottom of the model relative to its origin (negative)
    }

    UdpClient rx;
    UdpClient tx;
    IPEndPoint anyEp = new IPEndPoint(IPAddress.Any, 0);
    readonly Dictionary<int, Proxy> proxies = new Dictionary<int, Proxy>();
    readonly List<Candidate> candidates = new List<Candidate>();
    readonly Dictionary<string, Candidate> named = new Dictionary<string, Candidate>();   // models asked for by name (null = not a usable model)
    readonly Stopwatch clock = Stopwatch.StartNew();
    bool modelsReady;

    // The floor is a plain solid object (a shipping container's roof), not a vehicle: GTA gives a knocked-down ped no grip on top of a
    // vehicle (he slides off a truck roof). The trailer stays as the fallback if the prop is missing.
    const string DeckPropName = "prop_container_01a";
    Model deckModel;
    bool deckIsProp, deckLongX;   // deckLongX: the model's long side lies along X
    Vector3 deckMid;              // the model's centre relative to its origin (not every prop's origin is its middle)
    // 7 x 3 of them tile the ground around him (about 17 m x 36 m)
    const int DeckCols = 7, DeckRows = 3;
    readonly Entity[] decks = new Entity[DeckCols * DeckRows];
    readonly Vector3[] deckPos = new Vector3[DeckCols * DeckRows];
    bool decksReady;
    float deckLen = 12f, deckZ;
    float platformWidth = 2.5f;
    Vector3 platformSize;
    bool usePlatform = true;
    // BeamNG's walker is the source of truth for where the ped is (BeamNG collision + terrain).
    // W packet: feet position in GTA coordinates.
    Vector3 walkerFeet;
    double lastWalkerPacket = -999;
    bool pinned;
    const float GroundLift = 0f;            // manual raise of everything (platform self-calibrates now)
    float platCal; int groundedFrames;
    Vector3 tpTarget; bool tpPending;
    const float PedCenterHeight = 1.0f;    // ped origin is ~1m above the ground
    const bool UseVehicleProxies = true;    // BeamNG vehicles near Michael exist in GTA as invisible, frozen stand-ins: he collides with them and can get in

    // ---- BeamNG's ground height ----
    // GTA's floor never moves. BeamNG's ground under him rises and falls as he goes, so the two worlds are kept apart by zoff: every
    // height BeamNG sends has zoff taken off, every height sent back has it added. On a slope only zoff changes (moving the floor
    // under him instead is what made hills stutter: he sank into it and was lifted back three times a second). When the ground drops
    // away under him (an edge), or is already up where he is (he climbed onto something), zoff jumps and he is moved the other way
    // in the same tick: he stays exactly where he is in BeamNG, and GTA lets him fall, or stand, from there.
    float zoff, floorZ; bool floorSet; double zoffHoldUntil = -999, lastGroundTick = -1, zoffJumpAt = -999;
    // Water. BeamNG says how high its water stands where he is (waterZ; -9999 = none). Where that is deeper than he can stand, he is
    // taken down off the floor into GTA's own sea (the anchor is over open ocean), so GTA swims him; zoff then ties GTA's sea surface
    // where he is, waves and all, to BeamNG's flat one. Back in the shallows he is put on the floor again.
    // ponytail: BeamNG's walls and piers do not exist for him while he swims (the barriers stand on the floor, 60 m up)
    float waterZ = -9999f; bool swimming, seaFlat; int calmQuad = -1; double swimDbgAt;
    // GTA's sea is made dead flat while the bridge runs. It has to be: the sea is taken out of his picture as a flat plane (GtaKey.fx),
    // and every wave that stands above that plane stays in as a slab of GTA water around him.
    void FlatSea(bool on)
    {
        Function.Call((Hash)0xB96B00E976BE977FUL, on ? 0f : 1f);   // SET_DEEP_OCEAN_SCALER: the big swell
        Function.Call((Hash)0xC54A08C85AE4D410UL, on ? 1f : 0f);   // WATER_OVERRIDE_SET_STRENGTH: the values below replace the weather's
        if (!on) return;
        Function.Call((Hash)0x405591EC8FD9096DUL, 0f);             // WATER_OVERRIDE_SET_OCEANWAVEAMPLITUDE
        Function.Call((Hash)0xF751B16FB32ABC1DUL, 0f);             // WATER_OVERRIDE_SET_OCEANWAVEMINAMPLITUDE
        Function.Call((Hash)0xB3E6360DDE733E82UL, 0f);             // WATER_OVERRIDE_SET_OCEANWAVEMAXAMPLITUDE
        Function.Call((Hash)0x31727907B2C43C55UL, 0f);             // WATER_OVERRIDE_SET_OCEANNOISEMINAMPLITUDE
        Function.Call((Hash)0xB8F87EAD7533B176UL, 0f);             // WATER_OVERRIDE_SET_SHOREWAVEAMPLITUDE
    }
    // ... and the water he swims in is also marked as calm water, the way GTA's own harbours and lakes are (at most 8 such areas exist)
    void Calm(bool on, Vector3 p)
    {
        if (calmQuad >= 0) { Function.Call((Hash)0xB1252E3E59A82AAFUL, calmQuad); calmQuad = -1; }                               // REMOVE_EXTRA_CALMING_QUAD
        if (on) calmQuad = Function.Call<int>((Hash)0xFDBF4CDBC07E1706UL, p.X - 500f, p.Y - 500f, p.X + 500f, p.Y + 500f, 0f);   // ADD_EXTRA_CALMING_QUAD
    }

    // ---- walls and fences ----
    // BeamNG's buildings and walls are not in GTA. What stands in his way (found by BeamNG's own ray casts, O packets) is stood up
    // here out of invisible road barriers. Up to about head height the top barrier's top is where the wall's top is (with a second
    // one under it when the wall is taller than one barrier), so Space next to it does what it does in GTA: he vaults over it or
    // pulls himself up onto it. Anything higher is just a wall: two barriers stacked from knee height up, and Space only jumps.
    class Barrier { public Entity E, E2; public float PX, PY, X, Y, Top, Heading, Z; public double Seen; public bool Used, Fresh, Solid; }
    static readonly string[] BarrierNames = { "prop_barrier_work05", "prop_barrier_work06a", "prop_mp_barrier_02b" };
    Model barrierModel; bool barrierOk, barrierLongX, barrierTold;
    float barrierTop = 1f, barrierMinZ, barrierHeight = 1f, barrierHalfLen = 1.5f, barrierHalfThick = 0.3f;
    readonly Barrier[] barriers = new Barrier[16];

    Vector3 camForward;
    // K packet: BeamNG's exact camera pose (GTA space). GTA renders from a scripted camera at this pose, so the keyed frame
    // pasted into BeamNG lines up with BeamNG's own view.
    Vector3 kPos, kFwd; float kFov = 50f; double lastK = -999;
    int scriptCam; bool camOn;
    float beamHour = -1f; double lastClockSet = -999; bool weatherSet;
    const bool ShowDebug = false;          // the on-screen BeamBridge subtitle ends up in the streamed frame
    double lastCamPacket = -999;
    double lastDbg;
    bool tasked;
    bool riding;                 // BeamNG player is in a vehicle: Michael waits on his platform, no input
    float runPace = 1.5f;        // move blend ratio for W (1 = walk, 2 = GTA run, 3 = sprint)
    float sprintPace = 2.5f;     // ... with Shift
    bool spaceWas; double jumpAt = -999; bool climbing;
    bool deadTold;

    // ---- guns ----
    // The weapon wheel is BeamNG's (its radial menu): BeamNG's Lua cannot read a key, so this script tells it while Tab is down (a
    // bit in the P packet), it holds its wheel open for as long, and sends back the weapon that was picked (M|weapon|n) and how
    // slowly to run meanwhile (M|slow|f), as GTA's own wheel slows GTA.
    // With a gun out, right mouse aims and left mouse fires at whatever is in the middle of BeamNG's
    // picture: an invisible marker is kept 40 m out along the camera's line of sight and he is tasked to aim at that, so one task
    // follows the camera smoothly (a task aimed at a fixed point would have to be given again, with a twitch, every time it moved).
    // GTA does the animation, the sound and the flash; every shot is counted into the P packet and BeamNG lands it in its own world.
    static readonly string[] Loadout = { "WEAPON_UNARMED", "WEAPON_PISTOL", "WEAPON_SMG", "WEAPON_CARBINERIFLE", "WEAPON_PUMPSHOTGUN" };   // the same list, in the same order, as LOADOUT in gtaBridge.lua
    int weaponIdx, gunMode; bool tabWas, loadoutGiven; Entity aimMarker; double gunTaskAt;
    int wantWeapon = -1, shots; float wantSlow = 1f, slowSet = 1f; double tabAt, shotAt; bool wheelCentred;
    double gunDirX, gunDirY;   // the way he was last told to walk while aiming

    // ---- combat roll ----
    // Space while aiming. GTA has no command for its combat roll (it belongs to the player's own aiming, which the bridge does not
    // use: he is moved by tasks), so the roll's two animations are played one after the other: the dive, then back on his feet.
    // ponytail: the animation names are from memory, not read out of the game's files. If GTA does not know one, "combat roll:
    // GTA is not playing ..." appears in BeamNG's log and the roll ends at once.
    // They carry him along the ground by themselves, in the direction he is walking (forwards if he stands).
    const string RollDict = "move_strafe@roll";
    double rollUntil = -999, rollCheckAt = -999, rollNextAt = -999; string rollClip, rollNext;

    void StartRoll(Ped ped, float mx, float my)
    {
        if (!Function.Call<bool>(Hash.HAS_ANIM_DICT_LOADED, RollDict)) return;   // (asked for every tick in InjectInput)
        // S: backwards. W or nothing: forwards. A or D alone: to that side.
        string way = my > 0f ? "bwd_p{0}_180" : my < 0f ? "fwd_p{0}_00" : mx > 0f ? "fwd_p{0}_90" : mx < 0f ? "fwd_p{0}_-90" : "fwd_p{0}_00";
        string first = "combatroll_" + string.Format(way, 1);
        float len1 = Function.Call<float>(Hash.GET_ANIM_DURATION, RollDict, first);
        Function.Call(Hash.TASK_PLAY_ANIM, ped, RollDict, first, 8f, -8f, -1, 0, 0f, false, false, false);
        rollNext = "combatroll_" + string.Format(way, 2);
        float len2 = Function.Call<float>(Hash.GET_ANIM_DURATION, RollDict, rollNext);
        rollNextAt = Now() + Math.Max(0.2, len1 - 0.05);
        rollUntil = Now() + Math.Max(0.6, Math.Min(2.5, len1 + len2));
        rollClip = first; rollCheckAt = Now() + 0.2;
        gunMode = 0; tasked = false;   // the aim is taken up afresh when he is back on his feet
    }

    // ---- sound ----
    // GTA is heard for him alone: his voice, his steps, his gun. Where GTA has him standing is not where BeamNG has him: the
    // open sea and the wind out at the anchor are silenced, and his steps are made to sound like concrete instead of the
    // steel container that is really under his feet.
    const string QuietScene = "FBI_HEIST_H5_MUTE_AMBIENCE_SCENE";   // one of GTA's own mixes: everything of the surroundings turned down
    const string StepMaterial = "AM_BASE_CONCRETE";
    bool quiet; double quietAt = -999;

    void Quiet(bool on)
    {
        if (on)
        {
            Function.Call(Hash.SET_WIND, 0f);
            Function.Call(Hash.SET_WIND_SPEED, 0f);
            if (Now() - quietAt < 1.0) return;   // the rest once a second is plenty
            quietAt = Now();
            if (!Function.Call<bool>(Hash.IS_AUDIO_SCENE_ACTIVE, QuietScene)) Function.Call(Hash.START_AUDIO_SCENE, QuietScene);
            Function.Call(Hash.OVERRIDE_PLAYER_GROUND_MATERIAL, Function.Call<int>(Hash.GET_HASH_KEY, StepMaterial), true);
            quiet = true;
        }
        else if (quiet)
        {
            Function.Call(Hash.STOP_AUDIO_SCENE, QuietScene);
            Function.Call(Hash.OVERRIDE_PLAYER_GROUND_MATERIAL, Function.Call<int>(Hash.GET_HASH_KEY, StepMaterial), false);
            Function.Call(Hash.SET_WIND, -1f);   // back to what the weather says
            Function.Call(Hash.SET_WIND_SPEED, -1f);
            quiet = false; quietAt = -999;
        }
    }

    // Put the mouse pointer on the hub of BeamNG's wheel, once, as soon as the wheel has given the pointer back (it is hidden while
    // the mouse turns the camera): a flick of the mouse then points at a weapon, as in GTA, wherever the pointer was left before.
    // BeamNG draws the hub in the middle of its window, 55% of the way down. False = the pointer is not showing yet, try again.
    static bool CentreWheelPointer()
    {
        try
        {
            CURSORINFO ci = new CURSORINFO();
            ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
            if (!GetCursorInfo(ref ci) || (ci.flags & 1) == 0 || ci.hCursor == IntPtr.Zero) return false;
            IntPtr w = GetForegroundWindow();
            RECT r; POINT p = new POINT();
            if (!GetClientRect(w, out r) || !ClientToScreen(w, ref p)) return false;
            SetCursorPos(p.X + (r.Right - r.Left) / 2, p.Y + (int)((r.Bottom - r.Top) * 0.55));
        }
        catch (Exception) { }
        return true;
    }

    bool GunTasks(Ped ped, float mx, float my, double camHeading, bool jumping)
    {
        // (not while Tab holds the wheel up: a click on a weapon there is not a shot)
        bool want = weaponIdx > 0 && !swimming && !jumping && !ped.IsRagdoll && !Down(VK_TAB) && (Down(VK_RBUTTON) || Down(VK_LBUTTON)) && kFwd.Length() > 0.1f;
        if (want && (aimMarker == null || !aimMarker.Exists()))
        {
            Model mm = new Model("prop_golf_ball");
            if (!mm.IsLoaded) { mm.Request(); want = false; }
            else
            {
                aimMarker = World.CreateProp(mm, ped.Position, false, false);
                if (aimMarker == null) want = false;
                else
                {
                    aimMarker.IsPersistent = true; aimMarker.IsVisible = false; aimMarker.IsPositionFrozen = true;
                    Function.Call(Hash.SET_ENTITY_COLLISION, aimMarker, false, false);
                }
            }
        }
        if (!want)
        {
            if (gunMode != 0) { Function.Call(Hash.CLEAR_PED_TASKS, ped); gunMode = 0; tasked = false; }
            return false;
        }
        Vector3 fw = kFwd / kFwd.Length();
        Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, aimMarker, kPos.X + fw.X * 40f, kPos.Y + fw.Y * 40f, kPos.Z - zoff + fw.Z * 40f, false, false, false);
        bool shoot = Down(VK_LBUTTON), moving = mx != 0f || my != 0f;
        int mode = 1 + (shoot ? 1 : 0) + (moving ? 2 : 0);
        double dx = 0.0, dy = 0.0;
        if (moving)
        {
            double h = camHeading * Math.PI / 180.0;
            dx = -Math.Sin(h) * -my + Math.Cos(h) * mx; dy = Math.Cos(h) * -my + Math.Sin(h) * mx;
            double len = Math.Sqrt(dx * dx + dy * dy); dx /= len; dy /= len;
        }
        // The task is given again only when something has changed: what he is doing (aiming or firing, standing or walking) or,
        // walking, the way he is to go (by more than about 20 degrees). A new task settles its aim for a moment before the first
        // shot: given again several times a second, as the walking one used to be, he never got to fire at all.
        bool turned = moving && dx * gunDirX + dy * gunDirY < 0.94;
        if (mode != gunMode || turned || Now() - gunTaskAt > (moving ? 8.0 : 2.0))
        {
            int fullAuto = Function.Call<int>(Hash.GET_HASH_KEY, "FIRING_PATTERN_FULL_AUTO");
            bool aimed = gunMode != 0;   // the gun is up already: no settling in again
            if (moving)
            {
                Vector3 p = ped.Position;
                Function.Call(Hash.TASK_GO_TO_COORD_WHILE_AIMING_AT_ENTITY, ped, p.X + (float)dx * 30f, p.Y + (float)dy * 30f, p.Z, aimMarker, 1.0f, shoot, 0.5f, 0f, false, 0, aimed, fullAuto, 20000);
            }
            else if (shoot) Function.Call(Hash.TASK_SHOOT_AT_ENTITY, ped, aimMarker, 3000, fullAuto);
            else Function.Call(Hash.TASK_AIM_GUN_AT_ENTITY, ped, aimMarker, 3000, aimed);
            gunMode = mode; gunTaskAt = Now(); tasked = true; gunDirX = dx; gunDirY = dy;
        }
        return true;
    }
    // getting into a BeamNG car: E|id starts GTA's own enter-vehicle task on that car's stand-in
    bool enterPending; int enterId; double enterAt = -999; bool entering; Vehicle enterVeh;
    Proxy enterProxy; double seatedAt = -999;


    double ragdollUntil = -999;   // a car hit him: Euphoria owns him until then
    // where Michael's eyes are relative to the stand-in's origin once he sits in it (right, forward, up), per GTA model: measured the
    // first time he sits in one. Until then the seat bone plus a typical seat-to-eyes offset is used.
    readonly Dictionary<string, Vector3> eyeByModel = new Dictionary<string, Vector3>();
    static readonly Vector3 DefaultEye = new Vector3(0f, -0.10f, 0.60f);
    uint beamPid;
    double lastFocusCheck = -999;
    bool beamFocused;
    int seq;
    bool announced;

    public BeamBridge()
    {
        try
        {
            rx = new UdpClient(new IPEndPoint(IPAddress.Loopback, ListenPort));
            rx.Client.Blocking = false;
            tx = new UdpClient();
        }
        catch (Exception ex)
        {
            GTA.UI.Screen.ShowSubtitle("BeamBridge: cannot open UDP " + ListenPort + ": " + ex.Message, 6000);
            return;
        }
        Interval = 0;
        Tick += OnTick;
        Aborted += OnAborted;
    }

    // ---- main loop ------------------------------------------------------------------------
    void OnTick(object sender, EventArgs e)
    {
        if (!announced)
        {
            announced = true;
            // (no subtitle: it would be captured into the frame streamed to BeamNG)
        }
        if (!modelsReady) { PrepareModels(); return; }

        Ped ped = Game.Player.Character;
        if (ped == null || !ped.Exists()) return;

        Function.Call(Hash.HIDE_HUD_AND_RADAR_THIS_FRAME);   // keep radar/HUD out of the frame streamed into BeamNG
        ReceiveAll();
        UpdateEnter(ped);
        MovingProxies();
        UpdateGround(ped);
        UpdateBarriers();
        PinPed(ped);
        InjectInput(ped);
        SendState(ped);
        // as slow as BeamNG is while its weapon wheel is up (and back to normal should BeamNG stop talking with the wheel up)
        float slowNow = Now() - lastK > 2.0 ? 1f : wantSlow;
        if (slowNow < 0.999f || slowSet < 0.999f) { Function.Call(Hash.SET_TIME_SCALE, slowNow); slowSet = slowNow; }
        UpdatePlatform(ped);
        UpdateCamera();
        UpdateClock();
        ExpireProxies();
    }

    // The ped's animation/combat is GTA's, but its position is BeamNG's: freeze the ped's physics and
    // place it on the BeamNG walker every frame, so BeamNG collision and hills decide where it stands.
    void PinPed(Ped ped)
    {
        if (tpPending)
        {
            tpPending = false;
            Game.Player.CanControlCharacter = true;
            ped.Task.ClearAllImmediately();
            Function.Call(Hash.REQUEST_COLLISION_AT_COORD, tpTarget.X, tpTarget.Y, tpTarget.Z);
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, tpTarget.X, tpTarget.Y, tpTarget.Z + PedCenterHeight + 0.05f, false, false, false);
            ped.Velocity = Vector3.Zero;
            groundedFrames = 0;
            Dbg("put on the anchor");
            floorZ = tpTarget.Z; floorSet = true; zoff = 0f; swimming = false; Calm(false, Vector3.Zero); zoffHoldUntil = Now() + 0.3;   // the anchor is the floor, and BeamNG's ground starts level with it
            entering = false;       // whatever he was doing is over: a get-in that was still pending kept everything below switched off
            enterPending = false;
        }
        bool fresh = Now() - lastWalkerPacket < 0.5;
        bool justEngaged = fresh && !pinned;
        pinned = fresh;
        ped.IsPositionFrozen = false;   // GTA runs the ped for real: locomotion, Euphoria ragdoll, hit reactions
        Quiet(fresh);
        if (!fresh)
        {
            ped.HasGravity = true;
            if (seaFlat) { FlatSea(false); Calm(false, Vector3.Zero); seaFlat = false; }   // bridge off: GTA gets its waves back
            return;
        }
        // BeamNG's water is flat, so GTA's sea is too: no swell to bob him up and down, and a surface the picture can be cut along
        FlatSea(true); seaFlat = true;
        // nothing but Michael out here: no traffic/peds/parked cars to stream or simulate (raw native hashes: no compile risk)
        Function.Call((Hash)0x95E3D6257B166CF2UL, 0f);          // SET_PED_DENSITY_MULTIPLIER_THIS_FRAME
        Function.Call((Hash)0x245A6883D966D537UL, 0f);          // SET_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME
        Function.Call((Hash)0xB3B3359379FE77D3UL, 0f);          // SET_RANDOM_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME
        Function.Call((Hash)0xEAE6DCC7EEE3DB1DUL, 0f);          // SET_PARKED_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME
        Function.Call((Hash)0x7A556143A1C03898UL, 0f, 0f);      // SET_SCENARIO_PED_DENSITY_MULTIPLIER_THIS_FRAME
        if (justEngaged)
        {
            // engage = hard reset: kills the stuck T-pose / fall state, drops him on the BeamNG ground
            Game.Player.CanControlCharacter = true;
            ped.Task.ClearAllImmediately();
            // keep the ped's own XY (the W packet's XY is stale right after a T teleport and would yank him back); only BeamNG height applies
            if (!floorSet) { floorZ = walkerFeet.Z; floorSet = true; zoff = 0f; }
            swimming = false; Calm(false, Vector3.Zero);
            if (!loadoutGiven)
            {
                loadoutGiven = true;
                for (int i = 1; i < Loadout.Length; i++)
                {
                    int wh = Function.Call<int>(Hash.GET_HASH_KEY, Loadout[i]);
                    Function.Call(Hash.GIVE_WEAPON_TO_PED, ped, wh, 9999, false, false);
                    Function.Call(Hash.SET_PED_INFINITE_AMMO, ped, true, wh);
                }
                Function.Call(Hash.SET_CURRENT_PED_WEAPON, ped, Function.Call<int>(Hash.GET_HASH_KEY, Loadout[0]), true);
                weaponIdx = 0;
            }
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, ped.Position.X, ped.Position.Y, floorZ + PedCenterHeight + 0.05f, false, false, false);
            ped.Velocity = Vector3.Zero;
            ped.HasGravity = true;
        }
        // He goes exactly where the player points him: no steering around the invisible decks and car stand-ins (with decks on both sides
        // that avoidance only let him run along them, in straight lines)
        Function.Call(Hash.SET_PED_STEERS_AROUND_VEHICLES, ped, false);
        Function.Call(Hash.SET_PED_STEERS_AROUND_OBJECTS, ped, false);
        Function.Call(Hash.SET_PED_STEERS_AROUND_PEDS, ped, false);
        if (entering || ped.IsInVehicle()) return;   // GTA's enter-vehicle animation owns his position now
        // Ragdoll is off normally (he used to ragdoll against the platform: squat/arms-out pose) and on whenever a moving car is close,
        // so GTA's own "hit by a vehicle" physics and Euphoria can take him; it stays on until he is back on his feet.
        if (ped.IsRagdoll) ragdollUntil = Now() + 1.5;
        ped.CanRagdoll = Now() < ragdollUntil || MovingProxyNear(ped);
        // He can be hurt, so he grunts, yells and curses the way he does in GTA (a ped that cannot be damaged makes no sound at all),
        // but he cannot be killed: a reserve of health no single blow gets through, topped up again every tick. (A dead Michael
        // would respawn at a hospital on the other side of the map.)
        // ponytail: if something does kill him outright the bridge does not bring him back; needs a resurrect if that ever shows up
        ped.IsInvincible = false;
        Function.Call(Hash.SET_PED_MAX_HEALTH, ped, 9000);
        Function.Call(Hash.SET_ENTITY_HEALTH, ped, 9000);
        Function.Call(Hash.SET_PED_SUFFERS_CRITICAL_HITS, ped, false);
        Function.Call(Hash.SET_PED_DIES_IN_WATER, ped, false);
        Function.Call(Hash.SET_PED_MAX_TIME_UNDERWATER, ped, 100000f);
        Function.Call(Hash.DISABLE_PED_PAIN_AUDIO, ped, false);
        Function.Call(Hash.SET_MAX_WANTED_LEVEL, 0);          // gunfire must not bring the police out here
        if (ped.IsDead && !deadTold) { deadTold = true; Dbg("he was killed outright: GTA will respawn him away from the anchor"); }
        ped.HasGravity = true;    // normal GTA ground contact on the invisible platform (no gravity = permanent fall pose)
        // GTA owns X/Y (its own walking, input, Euphoria); BeamNG owns height (terrain under the ped).
        float tz = floorZ + PedCenterHeight;
        Vector3 pp = ped.Position;
        if (swimming) return;   // no floor under him: GTA's sea has him
        // only rescue him if he is far from the BeamNG ground (fell off the platform / teleported); otherwise
        // leave physics alone so walking, jumping and animation work normally
        // Self-calibrating deck: whatever the trailer model's real dimensions are, once he has stood still on it
        // for a few frames his actual Z says where the deck really is. Move the deck so he stands at tz.
        // (This is the "starts above ground, then drops 1-2 m onto a too-low platform and gets snapped back" loop.)
        // (not next to / on a car, and not around a jump or climb: correcting his height there is what cut the climb animation short)
bool standing = !ped.IsInAir && !ped.IsRagdoll && decksReady && !NearProxy(ped)
&& Now() - jumpAt > 3.0 && !Flag(Hash.IS_PED_CLIMBING, ped) && Now() > ragdollUntil + 2.5 && !NearBarrier(ped, false);   // +2.5: still getting up off the ground
        groundedFrames = (standing && Math.Abs(ped.Velocity.Z) < 0.3f) ? groundedFrames + 1 : 0;
        // (The deck's size is known to a few cm. A bigger "error" is him still dropping after the ground moved, and correcting for that
        // lowered the floor under him: sunk, lifted back, sunk again. So: small corrections only, and none just after the ground jumped.)
        if (groundedFrames > 15 && Math.Abs(tz - pp.Z) > 0.08f && Math.Abs(tz - pp.Z) < (deckIsProp ? 0.15f : 8f) && Now() - zoffJumpAt > 3.0)
        {
            platCal = Math.Max(-8f, Math.Min(8f, platCal + (tz - pp.Z)));
            Dbg(string.Format(CultureInfo.InvariantCulture, "floor height corrected by {0:0.00} (total {1:0.00})", tz - pp.Z, platCal));
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, tz + 0.03f, false, false, false);
            ped.Velocity = Vector3.Zero;
            groundedFrames = 0;
            return;
        }
        // lying on the ground after a hit his centre is well below standing height: that is not "fell through the floor"
        if (pp.Z < tz - (ped.IsRagdoll || Now() < ragdollUntil ? 2.5f : 0.6f) || pp.Z > tz + 300f)
        {
            Dbg(string.Format(CultureInfo.InvariantCulture, "lifted back: z {0:0.00} wanted {1:0.00} decks {2} ragdoll {3}", pp.Z, tz, decksReady, ped.IsRagdoll));
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, tz, false, false, false);
            var v = ped.Velocity; ped.Velocity = new Vector3(v.X, v.Y, 0f);
        }
    }
    const float LeashGain = 5f;   // m/s of correction per metre of error (raise if the ped lags the walker)
    const float LeashSnap = 2.5f; // teleport the ped if it gets this far from the walker

    // Render the world from BeamNG's camera pose (scripted camera) while K packets keep arriving.
    void UpdateCamera()
    {
        if (Now() - lastK < 0.5)
        {
            float len = kFwd.Length();
            if (len < 1e-4f) return;
            Vector3 fw = kFwd / len;
            float yaw = (float)(Math.Atan2(-fw.X, fw.Y) * 180.0 / Math.PI);
            float pitch = (float)(Math.Asin(Math.Max(-1f, Math.Min(1f, fw.Z))) * 180.0 / Math.PI);
            if (scriptCam == 0 || !Function.Call<bool>(Hash.DOES_CAM_EXIST, scriptCam))
            {
                scriptCam = Function.Call<int>(Hash.CREATE_CAM, "DEFAULT_SCRIPTED_CAMERA", true);
                camOn = false;
            }
            Function.Call(Hash.SET_CAM_COORD, scriptCam, kPos.X, kPos.Y, kPos.Z - zoff);
            Function.Call(Hash.SET_CAM_ROT, scriptCam, pitch, 0f, yaw, 2);
            Function.Call(Hash.SET_CAM_FOV, scriptCam, kFov);
            if (!camOn)
            {
                Function.Call(Hash.SET_CAM_ACTIVE, scriptCam, true);
                Function.Call(Hash.RENDER_SCRIPT_CAMS, true, false, 0, true, false);
                camOn = true;
            }
        }
        else if (camOn)
        {
            Function.Call(Hash.RENDER_SCRIPT_CAMS, false, false, 0, true, false);
            camOn = false;
        }
    }

    // GTA's sun follows BeamNG's time of day (clear weather, clock frozen so it only changes when BeamNG's does).
    void UpdateClock()
    {
        if (beamHour < 0f) return;
        double now = Now();
        if (now - lastClockSet < 1.0) return;
        lastClockSet = now;
        int h = ((int)beamHour) % 24;
        int m = ((int)((beamHour - (float)Math.Floor(beamHour)) * 60f)) % 60;
        Function.Call(Hash.PAUSE_CLOCK, true);
        Function.Call(Hash.SET_CLOCK_TIME, h, m, 0);
        if (!weatherSet)
        {
            weatherSet = true;
            Function.Call(Hash.CLEAR_OVERRIDE_WEATHER);
            Function.Call(Hash.SET_WEATHER_TYPE_NOW_PERSIST, "EXTRASUNNY");
        }
    }

    void OnAborted(object sender, EventArgs e)
    {
        if (camOn) { Function.Call(Hash.RENDER_SCRIPT_CAMS, false, false, 0, true, false); camOn = false; }
        Function.Call(Hash.SET_TIME_SCALE, 1f);
        Quiet(false);
        if (scriptCam != 0) { Function.Call(Hash.DESTROY_CAM, scriptCam, false); scriptCam = 0; }
        foreach (KeyValuePair<int, Proxy> kv in proxies)
            if (kv.Value.Veh != null && kv.Value.Veh.Exists()) kv.Value.Veh.Delete();
        proxies.Clear();
        DeleteDecks();
        foreach (Barrier b in barriers)
        {
            if (b == null) continue;
            if (b.E != null && b.E.Exists()) b.E.Delete();
            if (b.E2 != null && b.E2.Exists()) b.E2.Delete();
        }
        if (rx != null) rx.Close();
        if (tx != null) tx.Close();
    }

    double Now() { return clock.Elapsed.TotalSeconds; }

    // ---- models ---------------------------------------------------------------------------
    // Load a few vehicle models once; their real GTA dimensions are measured and the closest one is
    // used as the collision proxy for each BeamNG vehicle.
    void PrepareModels()
    {
        foreach (string name in ProxyModelNames)
        {
            Model m = new Model(name);
            if (!m.IsValid) continue;
            if (!m.Request(3000)) continue;
            Vector3 min, max;
            m.GetDimensions(out min, out max);
            Candidate c = new Candidate();
            c.Model = m;
            c.Size = max - min;
            c.MinZ = min.Z;
            candidates.Add(c);
        }
        Model pm = new Model(DeckPropName);
        deckIsProp = pm.IsValid && pm.Request(3000);
        if (!deckIsProp) pm = new Model(PlatformModelName);
        if (pm.IsValid && pm.Request(3000))
        {
            Vector3 min2, max2;
            pm.GetDimensions(out min2, out max2);
            platformSize = max2; // we need the top of the deck relative to the origin
            deckMid = (min2 + max2) * 0.5f;
            deckLongX = max2.X - min2.X > max2.Y - min2.Y;
            platformWidth = Math.Max(1.5f, Math.Min(max2.X - min2.X, max2.Y - min2.Y));
            deckLen = Math.Max(max2.X - min2.X, max2.Y - min2.Y);
            deckModel = pm;
        }
        foreach (string bn in BarrierNames)
        {
            Model bm = new Model(bn);
            if (!bm.IsValid || !bm.Request(3000)) continue;
            Vector3 bmin, bmax;
            bm.GetDimensions(out bmin, out bmax);
            barrierModel = bm;
            barrierOk = true;
            barrierTop = bmax.Z;
            barrierMinZ = bmin.Z;
            barrierHeight = Math.Max(0.4f, bmax.Z - bmin.Z);
            barrierLongX = bmax.X - bmin.X > bmax.Y - bmin.Y;
            barrierHalfLen = Math.Max(bmax.X - bmin.X, bmax.Y - bmin.Y) * 0.5f;
            barrierHalfThick = Math.Min(bmax.X - bmin.X, bmax.Y - bmin.Y) * 0.5f;
            break;
        }
        LoadEyes();
        modelsReady = true;
    }

    // A GTA model BeamNG asked for by name. False while it is still streaming in (try again next packet); c == null means "no such model".
    bool TryNamed(string name, out Candidate c)
    {
        if (named.TryGetValue(name, out c)) return true;
        Model m = new Model(name);
        if (!m.IsValid) { named[name] = null; return true; }
        if (!m.IsLoaded) { m.Request(); return false; }
        Vector3 min, max;
        m.GetDimensions(out min, out max);
        c = new Candidate();
        c.Model = m;
        c.Size = max - min;
        c.MinZ = min.Z;
        named[name] = c;
        return true;
    }

    Candidate PickCandidate(float width, float length, float height)
    {
        Candidate best = null;
        double bestScore = double.MaxValue;
        foreach (Candidate c in candidates)
        {
            double s = Math.Abs(Math.Log(Math.Max(width, 0.1f) / Math.Max(c.Size.X, 0.1f)))
                     + Math.Abs(Math.Log(Math.Max(length, 0.1f) / Math.Max(c.Size.Y, 0.1f)))
                     + Math.Abs(Math.Log(Math.Max(height, 0.1f) / Math.Max(c.Size.Z, 0.1f)));
            if (s < bestScore) { bestScore = s; best = c; }
        }
        return best;
    }

    // ---- receive --------------------------------------------------------------------------
    static float F(string s)
    {
        float v;
        if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
        return 0f;
    }

    void ReceiveAll()
    {
        try
        {
            int guard = 0;
            while (rx.Available > 0 && guard++ < 128)
            {
                byte[] data = rx.Receive(ref anyEp);
                Handle(Encoding.ASCII.GetString(data));
            }
        }
        catch (Exception) { }
    }

    void Handle(string msg)
    {
        string[] f = msg.Split('|');
        if (f.Length < 2) return;
        switch (f[0])
        {
            case "C": // C|seq|fx|fy|fz   BeamNG camera forward, already in GTA axes
                if (f.Length >= 5)
                {
                    camForward = new Vector3(F(f[2]), F(f[3]), F(f[4]));
                    lastCamPacket = Now();
                }
                break;
            case "W": // W|seq|x|y|z   BeamNG walker feet, in GTA axes
                if (f.Length >= 5)
                {
                    walkerFeet = new Vector3(F(f[2]), F(f[3]), F(f[4]) + GroundLift);
                    waterZ = f.Length >= 6 ? F(f[5]) : -9999f;
                    lastWalkerPacket = Now();
                }
                break;
            case "K": // K|seq|px|py|pz|fx|fy|fz|fov   BeamNG camera pose in GTA axes
                if (f.Length >= 9)
                {
                    kPos = new Vector3(F(f[2]), F(f[3]), F(f[4]));
                    kFwd = new Vector3(F(f[5]), F(f[6]), F(f[7]));
                    kFov = F(f[8]);
                    lastK = Now();
                }
                break;
            case "L": // L|seq|hour   BeamNG time of day
                if (f.Length >= 3) beamHour = F(f[2]);
                break;
            case "T": // T|seq|x|y|z   put the ped here (engage: move him out over the ocean)
                if (f.Length >= 5) { tpTarget = new Vector3(F(f[2]), F(f[3]), F(f[4])); tpPending = true; }
                break;
            case "E": // E|beamVehicleId   get into that car (0 = cancel)
                if (f.Length >= 2) { int.TryParse(f[1], out enterId); enterPending = true; }
                break;
            case "M": // M|platform|0/1   M|ride|0/1   M|pace|run|sprint   M|weapon|n (place in Loadout)   M|slow|f (speed of the game, 1 = normal)
                if (f.Length >= 3 && f[1] == "weapon") { if (!int.TryParse(f[2], out wantWeapon)) wantWeapon = -1; }
                else if (f.Length >= 3 && f[1] == "slow") wantSlow = Math.Max(0.05f, Math.Min(1f, F(f[2])));
                else if (f.Length >= 3 && f[1] == "platform") usePlatform = f[2] == "1";
                else if (f.Length >= 3 && f[1] == "ride") riding = f[2] == "1";
                else if (f.Length >= 4 && f[1] == "pace") { runPace = F(f[2]); sprintPace = F(f[3]); }
                break;
            case "O": // O|n|x|y|top|tx|ty ...   low walls / fences near him: a point on each, the height of its top, the direction it runs
                {
                    int n;
                    if (f.Length >= 2 && int.TryParse(f[1], out n))
                        for (int i = 0; i < n && 2 + i * 5 + 4 < f.Length; i++)
                            UpdateBarrier(F(f[2 + i * 5]), F(f[3 + i * 5]), F(f[4 + i * 5]), F(f[5 + i * 5]), F(f[6 + i * 5]));
                }
                break;
            case "V": // V|id|x|y|z|qx|qy|qz|qw|hx|hy|hz|vx|vy|vz
                if (UseVehicleProxies && f.Length >= 15) UpdateProxy(f);
                break;
        }
    }

    void UpdateProxy(string[] f)
    {
        int id;
        if (!int.TryParse(f[1], out id)) return;
        Vector3 pos = new Vector3(F(f[2]), F(f[3]), F(f[4]) - zoff);
        Quaternion q = new Quaternion(F(f[5]), F(f[6]), F(f[7]), F(f[8]));
        float hx = F(f[9]), hy = F(f[10]), hz = F(f[11]);
        Vector3 vel = new Vector3(F(f[12]), F(f[13]), F(f[14]));

        string wantName = f.Length >= 16 ? f[15] : "";
        // V|...|model|hasDriver|dx|dy|dz : where BeamNG's driver's eyes are (the driver camera node), GTA axes
        bool haveSeat = f.Length >= 20 && f[16] == "1";
        Vector3 drv = haveSeat ? new Vector3(F(f[17]), F(f[18]), F(f[19]) - zoff) : Vector3.Zero;

        Proxy p;
        bool have = proxies.TryGetValue(id, out p);
        if (have && p.ModelName != wantName && !entering && !riding)
        {
            // BeamNG now wants a different stand-in for this car (first packet came before the model was known, or the car was swapped)
            if (p.Veh != null && p.Veh.Exists()) p.Veh.Delete();
            proxies.Remove(id);
            have = false;
        }
        if (!have)
        {
            Candidate c = null;
            if (wantName != "" && !TryNamed(wantName, out c)) return;   // still loading
            if (c == null) c = PickCandidate(hx * 2f, hy * 2f, hz * 2f);
            if (c == null) return;
            Vehicle v = World.CreateVehicle(c.Model, pos, 0f);
            if (v == null) return;
            v.IsPersistent = true;
            v.IsInvincible = true;
            v.IsVisible = false;
            v.IsPositionFrozen = true;
            Function.Call(Hash.SET_VEHICLE_DOORS_LOCKED, v, 10);
            p = new Proxy();
            p.BeamId = id;
            p.Veh = v;
            p.MinZ = c.MinZ;
            p.Half = c.Size * 0.5f;
            p.ModelName = wantName;
            p.Created = Now();
            proxies[id] = p;
        }
        if (p.Veh == null || !p.Veh.Exists()) { proxies.Remove(id); return; }
        // Driver seat relative to the stand-in's origin. Measured from the pose it was left in on an earlier tick, BEFORE it is moved
        // again below: bone positions only catch up with a moved entity at the end of the frame, so measuring right after a move
        // mixed the old pose with the new one (that error is what put Michael half a metre behind and beside the seat).
        if (haveSeat && !p.SeatKnown && !p.Kinematic && Now() - p.Created > 0.4)
        {
            int bi = Function.Call<int>(Hash.GET_ENTITY_BONE_INDEX_BY_NAME, p.Veh, "seat_dside_f");
            if (bi >= 0)
            {
                Vector3 d = Function.Call<Vector3>(Hash.GET_WORLD_POSITION_OF_ENTITY_BONE, p.Veh, bi) - p.Veh.Position;
                p.SeatLocal = new Vector3(Vector3.Dot(d, p.Veh.RightVector), Vector3.Dot(d, p.Veh.ForwardVector), Vector3.Dot(d, p.Veh.UpVector));
                p.SeatOk = p.SeatLocal.Length() < 8f;
            }
            p.SeatKnown = true;
        }
        // pos is the centre of BeamNG's bounding box; a GTA vehicle's origin is not its centre: stand its underside where BeamNG's underside is
        Vector3 target = new Vector3(pos.X, pos.Y, pos.Z - hz - p.MinZ);
        p.Veh.Quaternion = q;
        if (haveSeat)
        {
            // Put the stand-in where its driver's eyes coincide with BeamNG's driver's eyes: then Michael sits exactly where a driver
            // of the BeamNG car sits, and the door he opens is where that seat's door is, whatever the two cars' shapes are.
            Vector3 l;
            bool ok = eyeByModel.TryGetValue(p.ModelName, out l);
            if (!ok && p.SeatOk) { l = p.SeatLocal + DefaultEye; ok = true; }
            if (ok) target = drv - (p.Veh.RightVector * l.X + p.Veh.ForwardVector * l.Y + p.Veh.UpVector * l.Z);
        }
        // A parked car is a frozen object placed exactly. A moving one becomes a real moving body (no gravity: there is no road under
        // it out here) that is steered by velocity, so when it reaches Michael GTA itself sees a vehicle travelling at that speed
        // hitting a pedestrian and reacts the way it does in GTA: shove, stumble, over the bonnet, Euphoria.
        bool mine = p == enterProxy && (entering || Game.Player.Character.IsInVehicle());
        Vector3 off = target - p.Veh.Position;
        // (moving: above a walking pace, and it stays "moving" until it has all but stopped. A parked bus must never count: as a
        // moving body touching him, GTA knocked him flying.)
        float sp = vel.Length();
        if ((p.Kinematic ? sp > 0.5f : sp > 1.0f) && !mine && off.Length() < 3f)
        {
            if (!p.Kinematic)
            {
                p.Veh.IsPositionFrozen = false; p.Veh.HasGravity = false; p.Kinematic = true;
                if ((p.Veh.Position - Game.Player.Character.Position).Length() < 8f)
                    Dbg(string.Format(CultureInfo.InvariantCulture, "car {0} next to him is moving ({1:0.0} m/s): it can knock him over now", id, sp));
            }
            Vector3 pull = off * 6f;                      // towards where it should be ...
            if (pull.Length() > 3f) pull *= 3f / pull.Length();   // ... but never rammed there: held back by him, it used to push harder and harder
            p.Veh.Velocity = vel + pull;
        }
        else
        {
            if (p.Kinematic) { p.Veh.IsPositionFrozen = true; p.Kinematic = false; }
            // NO_OFFSET: the plain position setter treats the point as ground level and lifts the vehicle by its own ride height on top
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, p.Veh, target.X, target.Y, target.Z, false, false, false);
        }
        p.Velocity = vel;
        p.LastSeen = Now();
    }

    void ExpireProxies()
    {
        double now = Now();
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy kp = kv.Value;   // no news of a moving car for a moment (the player got in, or it left the radius): do not let it coast away
            if (kp.Kinematic && now - kp.LastSeen > 0.2 && kp.Veh != null && kp.Veh.Exists()) { kp.Veh.IsPositionFrozen = true; kp.Kinematic = false; }
        }
        if (riding) return;   // he is sitting in one of them: BeamNG stops describing the cars while the player drives
        List<int> dead = null;
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            if (now - kv.Value.LastSeen > ProxyStaleSeconds)
            {
                if (dead == null) dead = new List<int>();
                dead.Add(kv.Key);
            }
        }
        if (dead == null) return;
        foreach (int id in dead)
        {
            Vehicle v = proxies[id].Veh;
            if (v != null && v.Exists()) v.Delete();
            proxies.Remove(id);
        }
    }

    // ---- BeamNG's ground height (see zoff) --------------------------------------------------
    void UpdateGround(Ped ped)
    {
        double now = Now();
        float dt = lastGroundTick < 0 ? 0f : (float)Math.Min(0.1, now - lastGroundTick);
        lastGroundTick = now;
        if (!floorSet || !pinned || now < zoffHoldUntil || entering || ped.IsInVehicle()) return;
        // Never under a climb or vault in progress (nor in the moment after Space, before GTA has started one). But the instant it is
        // over: this used to wait 2.2 s from the key press, by which time he had stepped off the back of the barrier he climbed and
        // dropped to the floor, i.e. through the wall top he should have been standing on.
        if (Flag(Hash.IS_PED_CLIMBING, ped) || (climbing && now - jumpAt < 0.6)) return;
        Vector3 pp = ped.Position;
        float depth = waterZ - walkerFeet.Z;               // BeamNG's water over BeamNG's ground here
        if (swimming)
        {
            if (depth < 0.9f)
            {
                // shallow enough to stand (or the water ended): back onto the floor, at the height he is at
                float nz = walkerFeet.Z - floorZ;
                Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, Math.Max(floorZ + PedCenterHeight, pp.Z + zoff - nz), false, false, false);
                ped.Velocity = Vector3.Zero;
                zoff = nz; swimming = false; zoffJumpAt = now; groundedFrames = 0;
                Calm(false, pp);
                Dbg("out of the water");
            }
            else
            {
                float sea = SeaLevel(pp);
                zoff = waterZ - sea;
                // (for the log: a GTA sea that is really flat reads the same height every time)
                if (now - swimDbgAt > 2.0) { swimDbgAt = now; Dbg(string.Format(CultureInfo.InvariantCulture, "swimming: GTA sea here {0:0.000} (read {1}), he is at {2:0.00}", sea, seaRead, pp.Z)); }
            }
            return;
        }
        if (depth > 1.2f && pp.Z + zoff < waterZ - 0.2f)
        {
            // deeper than he can stand, and he is down in it: into GTA's sea, as deep under its surface as he is under BeamNG's
            float nz = waterZ - SeaLevel(pp);
            Vector3 v = ped.Velocity;
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, pp.Z + zoff - nz, false, false, false);
            ped.Velocity = v;
            zoff = nz; swimming = true;
            Calm(true, new Vector3(pp.X, pp.Y, 0f));
            Dbg(string.Format(CultureInfo.InvariantCulture, "into the water: {0:0.0} m deep, GTA sea at {1:0.00}", depth, waterZ - nz));
            return;
        }
        float d = (walkerFeet.Z - floorZ) - zoff;          // how far BeamNG's ground under him is from where GTA has it
        if (Math.Abs(d) < 0.005f) return;
        // how high his feet are above GTA's floor (his lower ankle, 10 cm above the sole: his middle says nothing when he is crouched)
        float h = Math.Min(Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0x3779, 0f, 0f, 0f).Z,
                           Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0xCC4D, 0f, 0f, 0f).Z) - 0.1f - floorZ;
        if (d < -0.45f || (h > 0.25f && Math.Abs(d) > 0.2f && d < h + 0.1f))
        {
            // the ground fell away (an edge), or is already up where he is: he stays where he is in BeamNG, the floor does not
            Vector3 v = ped.Velocity;
            // (never to below the floor: a rise a little bigger than his height above it used to leave him sunk in it)
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, Math.Max(pp.Z - d, floorZ + PedCenterHeight), false, false, false);
            ped.Velocity = v;
            zoff += d; zoffJumpAt = now; groundedFrames = 0;
            if (d < -2.5f) ragdollUntil = now + 2.5;       // a long way down: let him land like it
            Dbg(string.Format(CultureInfo.InvariantCulture, "ground {0} by {1:0.00} m: he is now {2:0.00} m above it", d < 0f ? "dropped" : "rose", Math.Abs(d), h - d));
        }
        else zoff += Math.Max(-5f * dt, Math.Min(5f * dt, d));   // a slope, a kerb, a step: just follow it
    }

    // GTA's water surface at a spot, waves included (0 = sea level, if it cannot say)
    bool seaRead;   // whether GTA answered the last time
    float SeaLevel(Vector3 p)
    {
        OutputArgument o = new OutputArgument();
        seaRead = Function.Call<bool>((Hash)0xF6829842C06AE524UL, p.X, p.Y, p.Z, o);   // GET_WATER_HEIGHT
        return seaRead ? o.GetResult<float>() : 0f;
    }

    // ---- walls and fences (see Barrier) ------------------------------------------------------
    Entity MakeBarrier(float x, float y)
    {
        if (!barrierModel.IsLoaded) { barrierModel.Request(); return null; }
        Entity e = World.CreateProp(barrierModel, new Vector3(x, y, floorZ - 30f), false, false);
        if (e == null) return null;
        e.IsPersistent = true;
        e.IsInvincible = true;
        e.IsVisible = false;
        Function.Call(Hash.SET_ENTITY_ALPHA, e.Handle, 0, false);
        e.IsPositionFrozen = true;
        return e;
    }

    void UpdateBarrier(float x, float y, float top, float tx, float ty)
    {
        if (!barrierTold)
        {
            barrierTold = true;
            Dbg(barrierOk ? string.Format(CultureInfo.InvariantCulture, "walls: barrier prop is {0:0.0} m long, {1:0.0} m high", barrierHalfLen * 2f, barrierHeight) : "walls: no barrier prop could be loaded");
        }
        if (!barrierOk || !floorSet) return;
        bool solid = top - zoff - floorZ > 5f;   // BeamNG marks "higher than he can reach" with a top far above him
        Barrier free = null;
        for (int i = 0; i < barriers.Length; i++)
        {
            Barrier b = barriers[i];
            if (b == null) { b = new Barrier(); barriers[i] = b; }
            // One barrier per stretch of wall: several rays find the same wall, and a heap of barriers at slightly different angles
            // is not something he can vault cleanly. A barrier already standing within 1.5 m is that wall; it is never moved.
            if (b.Used && b.Solid == solid && (b.PX - x) * (b.PX - x) + (b.PY - y) * (b.PY - y) < 2.25f && (solid || Math.Abs(b.Top - top) < 0.4f))
            {
                b.Seen = Now();
                return;
            }
            if (!b.Used && free == null) free = b;
        }
        if (free == null) return;
        if (free.E == null || !free.E.Exists())
        {
            free.E = MakeBarrier(x, y);
            if (free.E == null) return;
        }
        float hd = (float)(Math.Atan2(-tx, ty) * 180.0 / Math.PI);   // heading of the direction the wall runs in
        // the point is on the face he sees: stand the barrier behind that face, so it never reaches out towards him
        float nx = -ty, ny = tx;
        Vector3 pp = Game.Player.Character.Position;
        if (nx * (x - pp.X) + ny * (y - pp.Y) < 0f) { nx = -nx; ny = -ny; }
        free.Used = true; free.Fresh = true; free.PX = x; free.PY = y; free.Seen = Now();
        free.X = x + nx * barrierHalfThick; free.Y = y + ny * barrierHalfThick; free.Top = top;
        free.Solid = solid;
        free.Heading = barrierLongX ? hd + 90f : hd;
    }

    void UpdateBarriers()
    {
        double now = Now();
        Vector3 pp = Game.Player.Character.Position;
        for (int i = 0; i < barriers.Length; i++)
        {
            Barrier b = barriers[i];
            if (b == null || !b.Used) continue;
            // Never put one away while he is at it. BeamNG stops reporting a wall he is right against or on top of, and taking the
            // barrier out from under a climb took him with it (30 m down, then lifted back: the vault that "stopped").
            float kx = pp.X - b.X, ky = pp.Y - b.Y;
            if (kx * kx + ky * ky < (barrierHalfLen + 1.2f) * (barrierHalfLen + 1.2f)) b.Seen = now;
            bool there = b.E != null && b.E.Exists();
            bool there2 = b.E2 != null && b.E2.Exists();
            if (!there || now - b.Seen > 0.6)   // BeamNG no longer reports a wall there (he has moved on): put it away
            {
                b.Used = false;
                if (there) b.E.Position = new Vector3(b.X, b.Y, floorZ - 30f);
                if (there2) b.E2.Position = new Vector3(b.X, b.Y, floorZ - 34f);
                continue;
            }
            // where the upper barrier's origin goes: a plain wall is stacked from knee height, anything else has its top at the wall's top
            float z = b.Solid ? floorZ + 0.5f + barrierHeight - barrierMinZ : b.Top - zoff - barrierTop;
            bool two = b.Solid || z + barrierMinZ - floorZ > 0.4f;   // room to slip under it: a second one beneath
            if (two && !there2)
            {
                b.E2 = MakeBarrier(b.X, b.Y);
                there2 = b.E2 != null;
                if (there2) b.Fresh = true;
            }
            if (b.Fresh || Math.Abs(z - b.Z) > 0.02f)
            {
                b.E.Position = new Vector3(b.X, b.Y, z);
                b.E.Heading = b.Heading;
                if (there2)
                {
                    b.E2.Position = new Vector3(b.X, b.Y, two ? z - barrierHeight : floorZ - 34f);
                    b.E2.Heading = b.Heading;
                }
                b.Z = z;
                b.Fresh = false;
            }
        }
    }

    // next to a barrier (climbable: only one he could get onto or over)
    bool NearBarrier(Ped ped, bool climbable)
    {
        Vector3 pp = ped.Position;
        for (int i = 0; i < barriers.Length; i++)
        {
            Barrier b = barriers[i];
            if (b == null || !b.Used || (climbable && b.Solid)) continue;
            float dx = pp.X - b.X, dy = pp.Y - b.Y;
            if (dx * dx + dy * dy < (barrierHalfLen + 1.0f) * (barrierHalfLen + 1.0f)) return true;
        }
        return false;
    }

    // ---- ground platform ------------------------------------------------------------------
    // GTA's ground does not match BeamNG's, so an invisible flat trailer is kept under the ped at the
    // BeamNG ground height. Turn off (usePlatform=false in gtaBridge.lua) when both games use the
    // same Los Santos map aligned with gtaBridge.align().
    void UpdatePlatform(Ped ped)
    {
        // The decks stay while he sits in a car and through gaps in BeamNG's packets. With none left GTA streams their model out, and
        // after getting out he fell through where the floor should have been (and was lifted back, over and over) until it had
        // loaded again.
        if (!usePlatform || Now() - lastWalkerPacket > 5.0) { DeleteDecks(); return; }
        if (!pinned || ped.IsInVehicle()) return;
        // A fixed tiling. The ground is divided into squares one deck in size; each deck owns the squares whose column and row numbers
        // leave its own remainders, and stands on whichever of those is inside the window around Michael. So the floor under and
        // around him never moves: only a deck at the far edge of the window hops to the front as he goes.
        // (GTA treats a floor that is moved under a body as a floor travelling at that speed. Following him every tick meant a floor
        // moving exactly as fast as he slid, so nothing ever slowed him down; moving it in steps kicked him along instead.)
        float cw = (deckLongX ? deckLen : platformWidth) * 0.98f, ch = (deckLongX ? platformWidth : deckLen) * 0.98f;   // 2% overlap, no gaps
        int nx = deckLongX ? DeckRows : DeckCols, ny = deckLongX ? DeckCols : DeckRows;
        Vector3 pp = ped.Position;
        int cx = (int)Math.Floor(pp.X / cw), cy = (int)Math.Floor(pp.Y / ch);
        deckZ = floorZ - platformSize.Z + platCal;   // the floor: fixed (BeamNG's ground height is handled by zoff, not by moving it)
        bool all = true;
        for (int i = 0; i < nx; i++)
        {
            for (int j = 0; j < ny; j++)
            {
                int sx = cx - nx / 2 + i, sy = cy - ny / 2 + j;                // a square of the window
                int k = ((sx % nx + nx) % nx) * ny + (sy % ny + ny) % ny;      // the deck that owns it
                Vector3 t = new Vector3((sx + 0.5f) * cw - deckMid.X, (sy + 0.5f) * ch - deckMid.Y, deckZ);
                Entity d = decks[k];
                if (d == null || !d.Exists())
                {
                    d = MakeDeck(t);
                    decks[k] = d;
                    deckPos[k] = new Vector3(0f, 0f, -9999f);
                    if (d == null) { all = false; continue; }
                }
                if ((t - deckPos[k]).Length() > 0.002f) { d.Position = t; d.Heading = 0f; deckPos[k] = t; }
            }
        }
        decksReady = all;
    }

    void DeleteDecks()
    {
        for (int i = 0; i < decks.Length; i++)
        {
            if (decks[i] != null && decks[i].Exists()) decks[i].Delete();
            decks[i] = null;
        }
        decksReady = false;
    }

    Entity MakeDeck(Vector3 at)
    {
        if (!deckModel.IsValid) return null;
        if (!deckModel.IsLoaded) { deckModel.Request(); Dbg("deck model not loaded"); return null; }   // streamed out: ask again
        at.Z -= 20f;   // born well below him (the caller moves it into place this same tick): never spawn a solid box around Michael
        Entity e;
        if (deckIsProp) e = World.CreateProp(deckModel, at, false, false);
        else e = World.CreateVehicle(deckModel, at, 0f);
        if (e == null) return null;
        e.IsPersistent = true;
        e.IsInvincible = true;
        e.IsVisible = false;
        Function.Call(Hash.SET_ENTITY_ALPHA, e.Handle, 0, false);   // belt and braces: never draw/depth-write the deck
        e.IsPositionFrozen = true;
        if (!deckIsProp) Function.Call(Hash.SET_VEHICLE_DOORS_LOCKED, e.Handle, 10);
        return e;
    }

    // ---- input ----------------------------------------------------------------------------
    static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    uint ownPid = (uint)Process.GetCurrentProcess().Id;
    bool BeamNgFocused()
    {
        double now = Now();
        if (now - lastFocusCheck < 0.25) return beamFocused;
        lastFocusCheck = now;
        uint pid = 0;
        try { GetWindowThreadProcessId(GetForegroundWindow(), out pid); } catch (Exception) { }
        beamFocused = pid != 0 && pid != ownPid;   // GTA itself focused => the user plays GTA directly, do not inject
        return beamFocused;
    }

    static void SetControl(Control c, float v)
    {
        Function.Call(Hash.SET_CONTROL_VALUE_NEXT_FRAME, 0, (int)c, v);
    }

    // measured eye positions survive a restart (if GTA's folder is writable)
    const string EyeFile = "scripts\\BeamBridge.eyes2.txt";
    void LoadEyes()
    {
        try
        {
            if (!System.IO.File.Exists(EyeFile)) return;
            foreach (string line in System.IO.File.ReadAllLines(EyeFile))
            {
                string[] a = line.Split('|');
                if (a.Length >= 4) eyeByModel[a[0]] = new Vector3(F(a[1]), F(a[2]), F(a[3]));
            }
        }
        catch (Exception) { }
    }
    void SaveEyes()
    {
        try
        {
            CultureInfo ci = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder();
            foreach (KeyValuePair<string, Vector3> kv in eyeByModel)
                sb.Append(kv.Key).Append('|').Append(kv.Value.X.ToString("F3", ci)).Append('|').Append(kv.Value.Y.ToString("F3", ci)).Append('|').Append(kv.Value.Z.ToString("F3", ci)).Append("\r\n");
            System.IO.File.WriteAllText(EyeFile, sb.ToString());
        }
        catch (Exception) { }
    }

    void UpdateEnter(Ped ped)
    {
        if (enterPending)
        {
            enterPending = false;
            Proxy p;
            if (enterId != 0 && proxies.TryGetValue(enterId, out p) && p.Veh != null && p.Veh.Exists())
            {
                Function.Call(Hash.SET_VEHICLE_DOORS_LOCKED, p.Veh, 1);
                Function.Call((Hash)0xC20E50AA46D09CA8UL, ped, p.Veh, 12000, -1, 1.0f, 1, 0);   // TASK_ENTER_VEHICLE, driver seat
                enterVeh = p.Veh;
                enterProxy = p;
                seatedAt = -999;
                enterAt = Now();
                entering = true;
                tasked = false;
            }
            else
            {
                if (entering) Function.Call(Hash.CLEAR_PED_TASKS, ped);
                entering = false;
            }
        }
        // First time he sits in this kind of car: measure where his eyes really are relative to the stand-in and remember it, so it
        // can be placed to put them exactly on BeamNG's driver's eyes (seat bone + typical offset is only a first guess).
        if (ped.IsInVehicle() && enterProxy != null && enterProxy.Veh != null && enterProxy.Veh.Exists())
        {
            if (seatedAt < 0) seatedAt = Now();
            // 3 s, not right away: he counts as "in the vehicle" while he is still swinging in and reaching for the door, and
            // measuring his head in that moment is what kept leaving him 0.4 m behind and 0.3 m beside the seat
            if (Now() - seatedAt > 3.0 && !eyeByModel.ContainsKey(enterProxy.ModelName))
            {
                Vehicle ev = enterProxy.Veh;
                Vector3 d = Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0x796E, 0f, 0f, 0f) - ev.Position;   // head bone (base of the skull)
                Vector3 e = new Vector3(Vector3.Dot(d, ev.RightVector), Vector3.Dot(d, ev.ForwardVector), Vector3.Dot(d, ev.UpVector) + 0.10f);   // -> eyes
                if (e.Length() < 6f) { eyeByModel[enterProxy.ModelName] = e; SaveEyes(); }
            }
        }
        if (!entering) return;
        if (ped.IsInVehicle()) { entering = false; return; }
        bool moveKey = BeamNgFocused() && (Down(VK_W) || Down(VK_A) || Down(VK_S) || Down(VK_D));
        if ((moveKey && Now() - enterAt > 0.4) || Now() - enterAt > 12.0)
        {
            Function.Call(Hash.CLEAR_PED_TASKS, ped);   // walking away cancels, like in GTA
            entering = false;
        }
    }

    void InjectInput(Ped ped)
    {
        // Only drive GTA when BeamNG is the focused window and has recently sent its camera direction.
        bool foc = BeamNgFocused();
        if (ShowDebug && Now() - lastDbg > 1.0)
        {
            lastDbg = Now();
            GTA.UI.Screen.ShowSubtitle(string.Format("BeamBridge focus={0} cam={1:0.0}s W={2} walker={3} rag={4} air={5} z={6:0.00}/{7:0.00} plat={8}", foc, Now() - lastCamPacket, Down(VK_W), pinned, ped.IsRagdoll, ped.IsInAir, ped.Position.Z, walkerFeet.Z + PedCenterHeight,decksReady ? (deckIsProp ? "prop " : "trailer ") + deckZ.ToString("0.00") : "none"), 1100);
        }
        if (!foc) return;
        if (lastCamPacket < 0) return;   // never got a camera direction yet
        if (riding || entering || ped.IsInVehicle())
        {
            // the keys are driving a BeamNG car (or he is busy getting into one): no walking input
            if (tasked) { Function.Call(Hash.CLEAR_PED_TASKS, ped); tasked = false; }
            return;
        }

        // Align GTA's gameplay camera with BeamNG's camera so movement is camera-relative like in GTA.
        float fx = camForward.X, fy = camForward.Y, fz = Math.Max(-1f, Math.Min(1f, camForward.Z));
        double camHeading = Math.Atan2(-fx, fy) * 180.0 / Math.PI;
        double rel = camHeading - ped.Heading;
        while (rel > 180.0) rel -= 360.0;
        while (rel < -180.0) rel += 360.0;
        float pitch = (float)(Math.Asin(fz) * 180.0 / Math.PI);
        Function.Call(Hash.SET_GAMEPLAY_CAM_RELATIVE_HEADING, (float)(rel * CameraHeadingSign));
        Function.Call(Hash.SET_GAMEPLAY_CAM_RELATIVE_PITCH, pitch, 1.0f);

        float mx = (Down(VK_D) ? 1f : 0f) - (Down(VK_A) ? 1f : 0f);
        float my = (Down(VK_S) ? 1f : 0f) - (Down(VK_W) ? 1f : 0f); // GTA: forward is -1
        if (mx != 0f) SetControl(Control.MoveLeftRight, mx);
        if (my != 0f) SetControl(Control.MoveUpDown, my);
        // Locomotion by task, camera-relative: independent of GTA's window focus / control plumbing.
        // Jump by task (TASK_JUMP): control injection does not reach a ped that is being moved by a task.
        bool sp = Down(VK_SPACE);
        if (!Function.Call<bool>(Hash.HAS_ANIM_DICT_LOADED, RollDict)) Function.Call(Hash.REQUEST_ANIM_DICT, RollDict);
        if (sp && !spaceWas && gunMode != 0 && !swimming && !ped.IsInAir && !ped.IsRagdoll && Now() > rollUntil)
        {
            StartRoll(ped, mx, my);   // aiming: Space is the combat roll, as in GTA
        }
        else if (sp && !spaceWas && !swimming && !ped.IsInAir && !ped.IsRagdoll && Now() - jumpAt > 0.7 && Now() > rollUntil)
        {
            climbing = NearProxy(ped) || NearBarrier(ped, true);
            if (climbing) Function.Call((Hash)0x89D9FCC2435112F1UL, ped, true);                   // TASK_CLIMB: climb / vault / slide over what is in front of him
            else Function.Call((Hash)0x0AE4086104E067B1UL, ped, true, false, false);             // TASK_JUMP
            jumpAt = Now();
            tasked = false;
        }
        spaceWas = sp;
        // do not replace the jump / climb with a walk task
        bool jumping = Now() - jumpAt < (climbing ? 2.2 : 0.4) || Flag(Hash.IS_PED_JUMPING, ped) || Flag(Hash.IS_PED_CLIMBING, ped) || Now() < rollUntil;
        if (rollNext != null && Now() >= rollNextAt)
        {
            Function.Call(Hash.TASK_PLAY_ANIM, ped, RollDict, rollNext, 8f, -8f, -1, 0, 0f, false, false, false);   // the second half
            rollNext = null;
        }
        if (rollClip != null && Now() > rollCheckAt)
        {
            // (said in BeamNG's log if GTA does not know the animation by that name: the roll then ends at once instead of leaving him standing)
            if (!Function.Call<bool>(Hash.IS_ENTITY_PLAYING_ANIM, ped, RollDict, rollClip, 3)) { Dbg("combat roll: GTA is not playing " + rollClip); rollUntil = Now(); rollNext = null; }
            rollClip = null;
        }
        // Tab: BeamNG's wheel is up (see "guns"). Its pointer starts on the hub; a moment is left for the wheel to appear first.
        bool tab = Down(VK_TAB);
        if (tab && !tabWas) { tabAt = Now(); wheelCentred = false; }
        if (tab && !wheelCentred && Now() - tabAt > 0.35) wheelCentred = CentreWheelPointer();   // (BeamNG brings the wheel up after 0.18 s of Tab: sooner is a tap)
        tabWas = tab;
        if (wantWeapon >= 0)
        {
            if (wantWeapon < Loadout.Length && !swimming)
            {
                weaponIdx = wantWeapon;
                Function.Call(Hash.SET_CURRENT_PED_WEAPON, ped, Function.Call<int>(Hash.GET_HASH_KEY, Loadout[weaponIdx]), true);
            }
            wantWeapon = -1;
        }
        if (GunTasks(ped, mx, my, camHeading, jumping)) { }
        else if ((mx != 0f || my != 0f) && !ped.IsRagdoll && !ped.IsInVehicle() && !jumping)
        {
            double h = camHeading * Math.PI / 180.0;                       // camera heading, GTA degrees, 0 = +Y
            double fwdX = -Math.Sin(h), fwdY = Math.Cos(h);                // forward in world
            double rgtX = Math.Cos(h), rgtY = Math.Sin(h);                 // right in world
            double dx = fwdX * -my + rgtX * mx, dy = fwdY * -my + rgtY * mx;
            double len = Math.Sqrt(dx * dx + dy * dy); dx /= len; dy /= len;
            Vector3 p = ped.Position;
            float spd = Down(VK_LSHIFT) ? sprintPace : runPace;
            Function.Call(Hash.TASK_GO_STRAIGHT_TO_COORD, ped, p.X + (float)dx * 6f, p.Y + (float)dy * 6f, p.Z, spd, 400, (float)(Math.Atan2(-dx, dy) * 180.0 / Math.PI), 0.0f);
            tasked = true;
        }
        else if (tasked && !jumping) { Function.Call(Hash.CLEAR_PED_TASKS, ped); tasked = false; }
        if (Down(VK_LSHIFT)) SetControl(Control.Sprint, 1f);
        if (Down(VK_LCONTROL)) SetControl(Control.Duck, 1f);
        if (Down(VK_R)) SetControl(Control.Reload, 1f);
        if (Down(VK_Q)) SetControl(Control.Cover, 1f);
        if (Down(VK_G)) SetControl(Control.Enter, 1f);
        if (Down(VK_E)) SetControl(Control.Context, 1f);
        if (Down(VK_LBUTTON)) SetControl(Control.Attack, 1f);
        if (Down(VK_RBUTTON)) SetControl(Control.Aim, 1f);
    }

    // ---- send state -----------------------------------------------------------------------
    static bool Flag(Hash h, Ped p) { return Function.Call<bool>(h, p); }

    // a line for BeamNG's log (so what GTA did can be read next to what BeamNG did); at most a few a second
    double dbgAt = -999;
    void Dbg(string s)
    {
        if (Now() - dbgAt < 0.25) return;
        dbgAt = Now();
        try { byte[] b = Encoding.ASCII.GetBytes("D|" + s); tx.Send(b, b.Length, "127.0.0.1", BeamPort); } catch (Exception) { }
    }

    void SendState(Ped ped)
    {
        int flags = 0;
        if (Flag(Hash.IS_PED_RAGDOLL, ped)) flags |= 1;
        if (Flag(Hash.IS_PED_SPRINTING, ped)) flags |= 2;
        if (Flag(Hash.IS_PED_RUNNING, ped)) flags |= 4;
        if (Flag(Hash.IS_PED_WALKING, ped)) flags |= 8;
        if (Flag(Hash.IS_PED_JUMPING, ped)) flags |= 16;
        if (Flag(Hash.IS_PED_FALLING, ped)) flags |= 32;
        if (Flag(Hash.IS_PED_CLIMBING, ped)) flags |= 64;
        if (Function.Call<bool>(Hash.IS_PLAYER_FREE_AIMING, Game.Player.Handle)) flags |= 128;
        if (Flag(Hash.IS_PED_SHOOTING, ped))
        {
            flags |= 256;
            // one shot. (The 0.06 s is a guard: should GTA hold this up for more than the one frame of a shot, a held trigger
            // still counts as shots at a gun's pace, not one per frame.)
            if (Now() - shotAt > 0.06) { shots++; shotAt = Now(); }
        }
        if (Down(VK_TAB) && BeamNgFocused()) flags |= 524288;   // Tab is down: BeamNG holds its weapon wheel open
        if (Flag(Hash.IS_PED_RELOADING, ped)) flags |= 512;
        if (Function.Call<bool>(Hash.IS_PED_IN_COVER, ped, false)) flags |= 1024;
        if (ped.IsInVehicle()) flags |= 2048;
        if (ped.IsDead) flags |= 4096;
        if (Flag(Hash.IS_PED_DUCKING, ped)) flags |= 8192;
        if (enterVeh != null && enterVeh.Exists() && (entering || ped.IsInVehicle()))
        {
            // which door he has opened (he uses the one on his side: from the passenger side he slides across). 0 front left,
            // 1 front right, 2 and 3 behind them; the number goes out in two more bits
            for (int door = 0; door < 4; door++)
                if (Function.Call<float>((Hash)0xFE3F9C29F7B32BD5UL, enterVeh, door) > 0.1f) { flags |= 16384 | (door * 131072); break; }   // GET_VEHICLE_DOOR_ANGLE_RATIO
        }
        if (entering) flags |= 32768;
        if (swimming) flags |= 65536;

        int weapon = 0;
        try { weapon = (int)ped.Weapons.Current.Hash; } catch (Exception) { }

        Vector3 pos = ped.Position;
        Vector3 vel = ped.Velocity;
        CultureInfo ci = CultureInfo.InvariantCulture;
        StringBuilder sb = new StringBuilder(512);
        sb.Append("P|").Append(++seq).Append('|')
          .Append(pos.X.ToString("F3", ci)).Append('|').Append(pos.Y.ToString("F3", ci)).Append('|').Append((pos.Z + zoff).ToString("F3", ci)).Append('|')
          .Append(ped.Heading.ToString("F2", ci)).Append('|')
          .Append(vel.X.ToString("F2", ci)).Append('|').Append(vel.Y.ToString("F2", ci)).Append('|').Append(vel.Z.ToString("F2", ci)).Append('|')
          .Append(flags).Append('|').Append(weapon).Append('|').Append(ped.Health).Append('|');

        for (int i = 0; i < BoneIds.Length; i++)
        {
            Vector3 b = Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, BoneIds[i], 0f, 0f, 0f);
            if (i > 0) sb.Append(',');
            sb.Append(b.X.ToString("F3", ci)).Append(',').Append(b.Y.ToString("F3", ci)).Append(',').Append((b.Z + zoff).ToString("F3", ci));
        }
        // when this was true, on this script's clock: BeamNG reads these packets at its own frame rate, some just made and some a
        // GTA frame old, and has to know which to put him exactly where he is by now
        sb.Append('|').Append(Now().ToString("F4", ci));
        sb.Append('|').Append(shots);   // shots fired so far: BeamNG lands the new ones

        try
        {
            byte[] bytes = Encoding.ASCII.GetBytes(sb.ToString());
            tx.Send(bytes, bytes.Length, "127.0.0.1", BeamPort);
        }
        catch (Exception) { }
    }

    // ---- BeamNG vehicle hits ped ------------------------------------------------------------
    // where the ped is in a stand-in's own frame (right, forward, up from its origin)
    static Vector3 LocalTo(Vehicle v, Vector3 world)
    {
        Vector3 d = world - v.Position;
        return new Vector3(Vector3.Dot(d, v.RightVector), Vector3.Dot(d, v.ForwardVector), Vector3.Dot(d, v.UpVector));
    }

    // standing on top of a car stand-in (so his height is the car's business, not the platform's)
    bool OnProxy(Ped ped, float tz)
    {
        if (ped.Position.Z < tz + 0.3f) return false;
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (p.Veh == null || !p.Veh.Exists()) continue;
            Vector3 l = LocalTo(p.Veh, ped.Position);
            if (Math.Abs(l.X) < p.Half.X + 0.3f && Math.Abs(l.Y) < p.Half.Y + 0.3f) return true;
        }
        return false;
    }

    // is a stand-in within reach in front of / around him (then Space climbs or vaults it instead of jumping on the spot)
    bool NearProxy(Ped ped)
    {
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (p.Veh == null || !p.Veh.Exists()) continue;
            Vector3 l = LocalTo(p.Veh, ped.Position);
            if (Math.Abs(l.X) < p.Half.X + 1.6f && Math.Abs(l.Y) < p.Half.Y + 1.6f) return true;
        }
        return false;
    }

    // moving stand-ins must not ride up on the invisible decks Michael walks on (they sit at exactly wheel height)
    void MovingProxies()
    {
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (!p.Kinematic || p.Veh == null || !p.Veh.Exists()) continue;
            foreach (Entity sv in decks)
                if (sv != null && sv.Exists()) Function.Call(Hash.SET_ENTITY_NO_COLLISION_ENTITY, p.Veh, sv.Handle, true);
        }
    }

    // a moving car close enough to hit him soon
    bool MovingProxyNear(Ped ped)
    {
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (!p.Kinematic || p.Veh == null || !p.Veh.Exists()) continue;
            Vector3 l = LocalTo(p.Veh, ped.Position);
            if (Math.Abs(l.X) < p.Half.X + 3f && Math.Abs(l.Y) < p.Half.Y + 3f) return true;
        }
        return false;
    }
}
