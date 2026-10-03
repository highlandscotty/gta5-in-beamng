// BeamNG side: read the GTA frame from shared memory, slide/scale it (billboard, never foreshortened) from the camera pose it was
// rendered at to the pose of the BeamNG frame being displayed, and feed it to the GtaOverlay effect. Also caps BeamNG's frame rate
// ([GTABRIDGE] FpsCap in ReShade.ini, default 60) so GTA gets enough GPU time to keep up, and reports the measured latency back to Lua.
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
#include <reshade.hpp>
#include <string.h>
#include <xmmintrin.h>
#include "common.h"
using namespace reshade::api;
extern "C" { int _fltused = 0; }   // no CRT: the linker wants this once floats are used
#include <stdio.h>
static void L(const char *m) { reshade::log::message(reshade::log::level::info, m); }

#define TEX_W 1920
#define TEX_H 1080
static HANDLE g_map; static PipeHeader *g_pipe;
static uint32_t g_lastFrame = 0xFFFFFFFFu;
static uint32_t g_pix[TEX_W * TEX_H];


// ---- small math (no CRT) ----
static float sq(float x) { return x <= 0.f ? 0.f : _mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(x))); }
static float fa(float x) { return x < 0.f ? -x : x; }
static float tn(float x) { float x2 = x * x; return x * (135135.f + x2 * (-17325.f + x2 * (378.f - x2))) / (135135.f + x2 * (-62370.f + x2 * (3150.f - 28.f * x2))); }
static double nowSec() {
	static double inv = 0; LARGE_INTEGER c; QueryPerformanceCounter(&c);
	if (inv == 0) { LARGE_INTEGER q; QueryPerformanceFrequency(&q); inv = 1.0 / (double)q.QuadPart; }
	return (double)c.QuadPart * inv;
}

// ---- camera pose: the BeamNG Lua side sends to UDP 127.0.0.1:47202 every frame
//   Q|px|py|pz|fx|fy|fz|fovBeam|fovGta|zc|feetX|feetY|feetZ | qx|qy|qz|qfx|qfy|qfz|qfeetX|qfeetY|qfeetZ
// first block = camera and Michael as BeamNG shows them now; second block = the (predicted) pose that was sent to GTA, i.e. what the frame GTA
// renders will have been drawn from. The ring holds the second block, g_new the first. ----
struct PoseRec { double t; double p[3]; float f[3]; float fovB, fovG, zc; double feet[3]; uint32_t tick; };
// BeamNG frame counter, handed to GTA through the pipe together with a wake-up (common.h, TICK_EVENT): GTA draws one frame per tick and
// marks it with the tick that set it off, so the pose it was drawn from is known exactly (the one Lua sent in the frame before that tick).
static uint32_t g_bt; static HANDLE g_ev; static unsigned g_paired; static int g_poseLag;
static SOCKET g_us = INVALID_SOCKET; static bool g_usTried;
static PoseRec g_ring[128]; static unsigned g_rn;
static PoseRec g_old, g_new, g_prev; static bool g_haveOld, g_haveNew, g_havePrev;   // g_prev: the camera one BeamNG frame before g_new
static float g_sun[3];        // unit vector towards the sun (BeamNG world), 0 = unknown
static float g_poseLead = 0.f; // [GTABRIDGE] PoseLead: frames to extrapolate the camera direction. 0 since Lua reads the camera inside BeamNG's camera update (it used to see the previous frame's and this was 1)
#define HC 0.97f   // typical height of the silhouette's centroid above the soles (m): start value, and what the latency match assumes
static float g_obsX, g_obsY, g_obsAsp = 1.7778f; static bool g_obsOK;   // centroid of Michael's silhouette in the latest GTA frame (texture uv)
static float g_obsBotX, g_obsBotY;   // his lowest point (the planted foot) in that frame
static float g_obsTopX, g_obsTopY;   // the top of his head in that frame
static float g_hc = HC;              // measured centroid height: peak-held, so it is the planted-foot value and a lifted foot shows as lifted
static float g_air;                  // how far GTA says he is off the ground (jump), metres
static float g_shade[4];              // BeamNG's own shadows on him and on the ground under his shadow (see the shader)
static float g_waterH;               // depth of BeamNG's water over the ground under him (0 = dry)
static float g_ghost = 1.f;          // how solid he is drawn: below 1 while one of BeamNG's wheel menus is up (he is pasted over BeamNG's picture, menus included)
static float g_bodyH, g_bodyMode;    // body-centre height from GTA's skeleton; mode 1 = getting into / sitting in a car (feet not on the ground)
// Michael's joints (BeamNG world) for the shadow: 18 of GTA's plus two toes; g_skT = when they arrived
static double g_sk[20][3], g_skT = -1e9;
// the body as capsules: joint, joint, radius (m). The last three are filled in specially (head, feet).
static const struct { int a, b; float r; } CAPS[20] = {
	{0,1,0.150f},{1,2,0.140f},{2,3,0.070f},                                   // hips-chest, chest-neck, neck
	{2,4,0.060f},{4,5,0.060f},{5,6,0.050f},{6,7,0.045f},                      // left collar, upper arm, forearm, hand
	{2,8,0.060f},{8,9,0.060f},{9,10,0.050f},{10,11,0.045f},                   // right
	{0,12,0.090f},{12,13,0.080f},{13,14,0.058f},                              // left hip, thigh, shin
	{0,15,0.090f},{15,16,0.080f},{16,17,0.058f},                              // right
	{3,3,0.105f},{14,18,0.050f},{17,19,0.050f} };                             // head (extended past the head joint), feet
static float g_age = 0.08f;   // seconds between "GTA rendered this frame" and "it is shown": recovered from where Michael appears in the frame

static double num(const char *&q) {   // "-123.456" up to the next '|'
	while (*q == ' ') q++;
	bool neg = false; if (*q == '-') { neg = true; q++; }
	double v = 0, sc = 0.1; bool dot = false;
	for (; *q && *q != '|'; q++) {
		if (*q >= '0' && *q <= '9') { if (dot) { v += (*q - '0') * sc; sc *= 0.1; } else v = v * 10.0 + (*q - '0'); }
		else if (*q == '.' && !dot) dot = true; else break;
	}
	while (*q && *q != '|') q++;
	if (*q == '|') q++;
	return neg ? -v : v;
}

// drain the pose socket into the ring; true if a packet arrived
static bool pumpPoses() {
	if (g_us == INVALID_SOCKET) {
		if (g_usTried) return false;
		g_usTried = true;
		WSADATA wd; if (WSAStartup(0x0202, &wd)) return false;
		g_us = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); if (g_us == INVALID_SOCKET) return false;
		u_long nb = 1; ioctlsocket(g_us, FIONBIO, &nb);
		sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = (u_short)((47202 >> 8) | ((47202 & 255) << 8)); a.sin_addr.s_addr = 0x0100007Fu;
		if (bind(g_us, (sockaddr *)&a, sizeof a)) { closesocket(g_us); g_us = INVALID_SOCKET; return false; }
	}
	bool got = false; char buf[1024];
	for (int k = 0; k < 64; k++) {
		int n = recvfrom(g_us, buf, sizeof buf - 1, 0, nullptr, nullptr);
		if (n < 0 && WSAGetLastError() == 10054) continue;   // WSAECONNRESET: an earlier sendto() hit a closed port; harmless
		if (n <= 2) break;
		buf[n] = 0;
		if (buf[0] == 'S' && buf[1] == '|') {   // S|x|y|z * 20: his joints
			const char *s = buf + 2;
			for (int i = 0; i < 20; i++) for (int j = 0; j < 3; j++) g_sk[i][j] = num(s);
			g_skT = nowSec(); continue;
		}
		if (buf[0] != 'Q' || buf[1] != '|') continue;
		if (buf[2] == 'h') { g_haveNew = false; continue; }   // "Q|hide": the player just took the wheel, drop Michael now
		const char *q = buf + 2; PoseRec c, r;
		for (int i = 0; i < 3; i++) c.p[i] = num(q);
		for (int i = 0; i < 3; i++) c.f[i] = (float)num(q);
		c.fovB = (float)num(q); c.fovG = (float)num(q); c.zc = (float)num(q);
		for (int i = 0; i < 3; i++) c.feet[i] = num(q);
		r = c;   // no predicted block (old Lua): the rendered pose is the current one
		if (*q) {
			for (int i = 0; i < 3; i++) r.p[i] = num(q);
			for (int i = 0; i < 3; i++) r.f[i] = (float)num(q);
			for (int i = 0; i < 3; i++) r.feet[i] = num(q);
		}
			if (*q) for (int i = 0; i < 3; i++) g_sun[i] = (float)num(q);
			g_air = *q ? (float)num(q) : 0.f;
			g_bodyH = *q ? (float)num(q) : 0.f;
			g_bodyMode = *q ? (float)num(q) : 0.f;
			g_waterH = *q ? (float)num(q) : 0.f;
			for (int i = 0; i < 4; i++) g_shade[i] = *q ? (float)num(q) : 0.f;
			g_ghost = *q ? (float)num(q) : 1.f;
			c.t = r.t = nowSec(); c.tick = r.tick = g_bt;
			if (g_haveNew && c.t - g_new.t > 0.004) { g_prev = g_new; g_havePrev = true; }   // the two packets of one frame arrive together: keep last frame's
			g_ring[g_rn & 127] = r; g_rn++; g_new = c; g_haveNew = true; got = true;
	}
	return got;
}

// zero-roll camera basis (what GTA's scripted camera uses: yaw + pitch only)
static void basis(const float *f, float *F, float *R, float *U) {
	float l = sq(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
	if (l < 1e-6f) { F[0] = 0; F[1] = 1; F[2] = 0; R[0] = 1; R[1] = 0; R[2] = 0; U[0] = 0; U[1] = 0; U[2] = 1; return; }
	for (int i = 0; i < 3; i++) F[i] = f[i] / l;
	float rl = sq(F[0] * F[0] + F[1] * F[1]);
	if (rl < 1e-4f) { R[0] = 1; R[1] = 0; R[2] = 0; } else { R[0] = F[1] / rl; R[1] = -F[0] / rl; R[2] = 0; }
	U[0] = R[1] * F[2] - R[2] * F[1]; U[1] = R[2] * F[0] - R[0] * F[2]; U[2] = R[0] * F[1] - R[1] * F[0];
}

// where Michael's feet land in the GTA frame (uv, y down) if the frame was rendered from pose r
static bool projFeet(const PoseRec &r, float aspG, float &u, float &v) {
	float F[3], R[3], U[3]; basis(r.f, F, R, U);
	float rx = (float)(r.feet[0] - r.p[0]), ry = (float)(r.feet[1] - r.p[1]), rz = (float)(r.feet[2] + HC - r.p[2]);   // body centre, to compare with the silhouette centroid
	float z = rx * F[0] + ry * F[1] + rz * F[2]; if (z < 0.2f) return false;
	float x = rx * R[0] + ry * R[1] + rz * R[2], y = rx * U[0] + ry * U[1] + rz * U[2];
	float th = tn(r.fovG * 0.5f * 0.0174533f);
	u = 0.5f + x / z / (2.f * th * aspG); v = 0.5f - y / z / (2.f * th);
	return true;
}

static void setF(effect_runtime *rt, const char *name, const float *v, size_t n) {
	effect_uniform_variable h = rt->find_uniform_variable("GtaOverlay.fx", name);
	if (h.handle) rt->set_uniform_value_float(h, v, n);
}

// tell the Lua side how old the GTA frame is when shown, so it can aim the GTA camera that far ahead
static void sendAge(float age) {
	if (g_us == INVALID_SOCKET) return;
	char m[24]; int n = _snprintf(m, sizeof m, "A|%d", (int)(age * 1000.f + 0.5f));
	sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = (u_short)((47201 >> 8) | ((47201 & 255) << 8)); a.sin_addr.s_addr = 0x0100007Fu;
	sendto(g_us, m, n, 0, (sockaddr *)&a, sizeof a);
}

// D3DKMT scheduling priority class: 0 idle, 1 below normal, 2 normal, 3 above normal, 4 high, 5 realtime. Lowering our own is always allowed.
static void gpuPrio(int cls) {
	HMODULE g = LoadLibraryA("gdi32.dll"); if (!g) return;
	typedef long (__stdcall *Fn)(HANDLE, int);
	Fn f = (Fn)GetProcAddress(g, "D3DKMTSetProcessSchedulingPriorityClass"); if (!f) { L("beam_overlay: no D3DKMTSetProcessSchedulingPriorityClass"); return; }
	long st = f(GetCurrentProcess(), cls);
	char m[96]; _snprintf(m, sizeof m, "beam_overlay: GPU priority class %d -> status 0x%08lX", cls, (unsigned long)st); L(m);
}

// frame cap: BeamNG at ~125 fps starves GTA of GPU time (GTA fell to ~16 fps, which is what made the sprite lag). High-resolution waitable timer + short spin.
static int g_cap = -1; static HANDLE g_tmr; static double g_next;
static void limitFps() {
	if (g_cap < 0) {
		g_cap = 60; char b[16]; size_t n = 15;
		if (reshade::get_config_value(nullptr, "GTABRIDGE", "FpsCap", b, &n)) { int v = 0; for (const char *c = b; *c >= '0' && *c <= '9'; c++) v = v * 10 + (*c - '0'); g_cap = v; }
char m[64]; _snprintf(m, sizeof m, "beam_overlay: FpsCap=%d", g_cap); L(m);
		// [GTABRIDGE] GpuPriority: BeamNG's own GPU priority (2 = normal, 1 = below normal, -1 = leave alone). GTA asks for "high", so it
		// still goes first; BeamNG no longer has to stand behind everything else on the PC as well (it used to be 1, from the time GTA
		// ran flat out and needed the room).
		int gp = 2; n = 15;
		if (reshade::get_config_value(nullptr, "GTABRIDGE", "GpuPriority", b, &n)) { gp = 0; bool neg = (b[0] == '-'); for (const char *c = b + (neg ? 1 : 0); *c >= '0' && *c <= '9'; c++) gp = gp * 10 + (*c - '0'); if (neg) gp = -gp; }
if (gp >= 0) gpuPrio(gp);
		n = 15;
		if (reshade::get_config_value(nullptr, "GTABRIDGE", "PoseLead", b, &n)) { const char *c = b; g_poseLead = (float)num(c); }
		n = 15;   // PoseLag: set to 1 if GTA turns out to draw from the camera pose of one frame earlier than the one it was sent last
		if (reshade::get_config_value(nullptr, "GTABRIDGE", "PoseLag", b, &n)) { const char *c = b; g_poseLag = (int)num(c); }
	}
	if (g_cap <= 0) return;
	double now = nowSec();
	if (g_next == 0) g_next = now;
	g_next += 1.0 / g_cap;
	if (g_next < now) g_next = now;   // running late: don't try to catch up
	double rem = g_next - now;
	if (rem > 0.0015) {
		if (!g_tmr) g_tmr = CreateWaitableTimerExW(nullptr, nullptr, 0x2 /*HIGH_RESOLUTION*/, 0x1F0003);
		if (g_tmr) { LARGE_INTEGER due; due.QuadPart = -(LONGLONG)((rem - 0.0015) * 1e7); SetWaitableTimer(g_tmr, &due, 0, nullptr, nullptr, FALSE); WaitForSingleObject(g_tmr, 50); }
		else Sleep((DWORD)((rem - 0.002) * 1000.0));
	}
	while (nowSec() < g_next) _mm_pause();
}

static effect_runtime *g_main;   // BeamNG opens extra windows (console, editors) with their own ReShade runtime: only the first (game window) is fed
static void on_destroy_runtime(effect_runtime *rt) { if (rt == g_main) g_main = nullptr; }

static void on_begin_effects(effect_runtime *rt, command_list *, resource_view, resource_view)
{
	if (!g_main) g_main = rt;
	if (rt != g_main) return;
	static unsigned calls = 0, pushed = 0; ++calls;
	char b[240];
	if (calls == 1 || calls % 300 == 0) {
		static double lt = 0; static uint32_t lf = 0; double tn_ = nowSec(); uint32_t cf = g_pipe ? g_pipe->frame : 0;
		float gfps = (lt > 0 && tn_ > lt) ? (float)((cf - lf) / (tn_ - lt)) : 0.f; lt = tn_; lf = cf;
		_snprintf(b, sizeof b, "beam_overlay: calls=%u pipe=%d sock=%d pushed=%u paired=%u frame=%u %ux%u age=%.0fms ring=%u gtaFps=%.1f", calls, g_pipe ? 1 : 0, g_us != INVALID_SOCKET ? 1 : 0, pushed, g_paired, cf, g_pipe ? g_pipe->slot[g_pipe->latest % PIPE_SLOTS].width : 0, g_pipe ? g_pipe->slot[g_pipe->latest % PIPE_SLOTS].height : 0, g_age * 1000.f, g_rn, gfps); L(b);
	}

	// 1) camera poses sent by Lua since the last frame -> ring
	pumpPoses();

	// 2) new GTA frame? Read straight out of the newest finished slot (GTA is writing a different one). Skipped while hidden.
	if (!g_pipe) {
		g_map = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, PIPE_NAME);
		if (g_map) g_pipe = (PipeHeader *)MapViewOfFile(g_map, FILE_MAP_ALL_ACCESS, 0, 0, PIPE_SIZE);
	}
	bool show = g_haveNew && nowSec() - g_new.t < 0.4;   // Lua stops sending poses when Michael is not on foot (in a vehicle, not engaged)
	if (g_pipe && show) {
		uint32_t si = g_pipe->latest % PIPE_SLOTS; const PipeSlot *sl = &g_pipe->slot[si];
		uint32_t s0 = sl->seq, fr = sl->frame, tag = sl->tick;
		if (!(s0 & 1) && fr != 0 && fr != g_lastFrame) {
			uint32_t w = sl->width, h = sl->height, bgr = sl->bgr;
			if (w && h && (uint64_t)w * h * 4 <= PIPE_MAX_BYTES) {
				const uint32_t *srcpx = (const uint32_t *)PIPE_PIXELS(g_pipe, si);
				double tA = nowSec();
				static uint32_t xmap[TEX_W]; static uint32_t xmapW = 0;   // nearest-neighbour scale to the fixed effect texture
				if (xmapW != w) { for (uint32_t x = 0; x < TEX_W; x++) xmap[x] = x * w / TEX_W; xmapW = w; }
				static uint32_t rowN[TEX_H], rowX[TEX_H]; memset(rowN, 0, sizeof rowN); memset(rowX, 0, sizeof rowX);   // per-row sprite pixel count / sum of x
				uint32_t minx = TEX_W, maxx = 0, miny = TEX_H, maxy = 0;   // bounding box of the keyed sprite (alpha > 0)
				for (uint32_t y = 0; y < TEX_H; y++) {
					const uint32_t *row = srcpx + (uint64_t)(y * h / TEX_H) * w;
					uint32_t *dst = g_pix + y * TEX_W;
					for (uint32_t x = 0; x < TEX_W; x++) {
						uint32_t p = row[xmap[x]];
						if (bgr) p = (p & 0xFF00FF00u) | ((p & 0xFF) << 16) | ((p >> 16) & 0xFF);
						dst[x] = p;
						if (p >> 24) { if (x < minx) minx = x; if (x > maxx) maxx = x; if (y < miny) miny = y; if (y > maxy) maxy = y; rowN[y]++; rowX[y] += x; }
					}
				}
				if (sl->seq == s0) {   // the slot was not recycled under us (it would take GTA two more frames to get back to it)
					g_lastFrame = fr;
					float aw = (float)w / (float)h;
					bool sprite = maxx >= minx && maxy >= miny + 20;
					// centroid of the silhouette: unlike the lowest foot or the bounding box it barely moves through a walk/run cycle
					float lx = 0.f, ly = 0.f; bool cenOK = false;
					if (sprite) {
						uint64_t sn = 0, sx = 0, sy = 0;
						for (uint32_t y = miny; y <= maxy; y++) { sn += rowN[y]; sx += rowX[y]; sy += (uint64_t)rowN[y] * y; }
						if (sn) { lx = (float)((double)sx / (double)sn) / TEX_W; ly = (float)((double)sy / (double)sn) / TEX_H; cenOK = true; }
						uint64_t bn = 0, bx = 0;   // lowest few rows = the planted foot
						for (uint32_t y = maxy; y + 4 > maxy && y >= miny; y--) { bn += rowN[y]; bx += rowX[y]; if (y == 0) break; }
						g_obsBotX = bn ? (float)((double)bx / (double)bn) / TEX_W : lx; g_obsBotY = (float)(maxy + 1) / TEX_H;
						uint64_t tn2 = 0, tx2 = 0;   // top few rows = the crown of his head
						for (uint32_t y = miny; y < miny + 5 && y <= maxy; y++) { tn2 += rowN[y]; tx2 += rowX[y]; }
						g_obsTopX = tn2 ? (float)((double)tx2 / (double)tn2) / TEX_W : lx; g_obsTopY = (float)miny / TEX_H;
					}
					g_obsOK = sprite && cenOK;
					g_obsX = lx; g_obsY = ly; g_obsAsp = aw;
					static float fh = 0.f; static bool had = false;   // smoothed body height (GTA texture uv)
					if (sprite) { float nh = (float)(maxy - miny) / TEX_H; if (!had) { fh = nh; had = true; } else fh += (nh - fh) * 0.4f; }
					else { had = false; fh = 0.f; }
					setF(rt, "BodyH", &fh, 1);
					setF(rt, "GtaAspect", &aw, 1);

					// which camera pose was this frame rendered from? GTA in step with BeamNG says so itself (see g_bt)
					bool paired = false;
					if (tag) {
						for (unsigned k = 0; k < 128 && k < g_rn; k++) {
							const PoseRec &r = g_ring[(g_rn - 1 - k) & 127];
							if (r.tick + 1 + (uint32_t)g_poseLag != tag) { if (r.tick + 1 + (uint32_t)g_poseLag < tag) break; continue; }
							g_old = r; g_haveOld = true; paired = true; g_paired++;
							float age = (float)(tA - r.t);
							g_age += (age - g_age) * 0.2f; if (g_age < 0.01f) g_age = 0.01f; if (g_age > 0.15f) g_age = 0.15f;
							break;
						}
					}
					// otherwise (GTA free-running): the one under which Michael's body lands where it appears
					if (!paired && g_rn > 4) {
						bool whole = sprite && cenOK && minx > 2 && maxx < TEX_W - 3 && miny > 2 && maxy < TEX_H - 3;
						if (whole) {
							float bestE = 1e9f, worstE = 0.f; int bestK = -1;
							for (unsigned k = 0; k < 128 && k < g_rn; k++) {
								const PoseRec &r = g_ring[(g_rn - 1 - k) & 127];
								float age = (float)(tA - r.t); if (age > 0.3f) break;
								float u, v; if (!projFeet(r, aw, u, v)) continue;
								float e = fa(u - lx) + fa(v - ly) + 0.02f * fa(age - 0.04f);   // tiny prior resolves ties (camera at rest)
								if (e < bestE) { bestE = e; bestK = (int)k; }
								if (e > worstE) worstE = e;
							}
							if (bestK >= 0 && bestE < 0.06f && worstE - bestE > 0.1f) {   // only when the camera moved enough for the match to mean something
								float age = (float)(tA - g_ring[(g_rn - 1 - bestK) & 127].t);
								g_age += (age - g_age) * 0.1f; if (g_age < 0.02f) g_age = 0.02f; if (g_age > 0.15f) g_age = 0.15f;
							}
						}
						double want = tA - g_age; double bd = 1e9; int bi = -1;
						for (unsigned k = 0; k < 128 && k < g_rn; k++) {
							double d = g_ring[(g_rn - 1 - k) & 127].t - want; if (d < 0) d = -d;
							if (d < bd) { bd = d; bi = (int)k; }
						}
						if (bi >= 0) { g_old = g_ring[(g_rn - 1 - bi) & 127]; g_haveOld = true; }
					}
					rt->update_texture(rt->find_texture_variable("GtaOverlay.fx", "GtaTex"), TEX_W, TEX_H, g_pix);
					pushed++;
				}
			}
		}
	}

	// GTA's turn: this frame's picture has been taken, it may draw the next one
	++g_bt;
	if (g_pipe) {
		g_pipe->beamTick = g_bt;
		if (!g_ev) g_ev = CreateEventA(nullptr, FALSE, FALSE, TICK_EVENT);
		if (g_ev) SetEvent(g_ev);
	}

	// 3) every BeamNG frame: place the sprite. Michael is a billboard that always faces the camera. Where his body centre is in the GTA
	// frame is MEASURED (silhouette centroid); that point is mapped to where his body centre really is in the BeamNG view now. Size follows
	// the ratio of camera distances (straight-line, which stays put while the camera orbits). Camera poses are otherwise only a fallback.
	float showF = show ? 1.f : 0.f; setF(rt, "Show", &showF, 1);
	if (show && g_haveOld && g_haveNew) {
		static double tPrev = 0; double tNow = nowSec();
		float dtf = tPrev > 0 ? (float)(tNow - tPrev) : 0.016f; tPrev = tNow; if (dtf > 0.1f) dtf = 0.1f;
		float OF[3], OR[3], OU[3], NF[3], NR[3], NU[3];
		// The direction Lua reads is what BeamNG rendered one frame earlier (the mouse is applied after Lua ran), which left him trailing
		// the ground during fast sweeps. Carry the direction forward by PoseLead frames at the current turn rate.
		float nf[3] = { g_new.f[0], g_new.f[1], g_new.f[2] };
		if (g_havePrev && g_poseLead != 0.f && g_new.t - g_prev.t < 0.1) for (int i = 0; i < 3; i++) nf[i] += (g_new.f[i] - g_prev.f[i]) * g_poseLead;
		basis(g_old.f, OF, OR, OU); basis(nf, NF, NR, NU);
		// Which point of him is pinned where. On foot: the centre of his silhouette, at the measured height g_hc above the ground
		// (plus any jump). Getting into / sitting in a car his feet are on the car floor and the silhouette is folded up, so instead
		// the top of his head is pinned to where GTA's skeleton says the top of his head is (Lua sends that point and its height).
		// Knocked down / climbing (mode 3): the centre of his outline is pinned to the centre of GTA's skeleton.
		bool skel = g_bodyMode > 0.5f && g_bodyH > 0.02f;        // any mode where GTA's skeleton, not the picture, says how high he is
		bool seated = skel && (g_bodyMode < 2.5f || g_bodyMode > 3.5f);   // modes 1, 2, 4: pin the top of his head
		float hcU = skel ? g_bodyH : g_hc, airU = skel ? 0.f : g_air;
		// (both include how far he is off the ground: up on a truck the missing height made him look far from the old camera, and so huge)
		float rO[3] = { (float)(g_old.feet[0] - g_old.p[0]), (float)(g_old.feet[1] - g_old.p[1]), (float)(g_old.feet[2] + hcU + airU - g_old.p[2]) };
		float rN[3] = { (float)(g_new.feet[0] - g_new.p[0]), (float)(g_new.feet[1] - g_new.p[1]), (float)(g_new.feet[2] + hcU + airU - g_new.p[2]) };
		float Z = rO[0] * OF[0] + rO[1] * OF[1] + rO[2] * OF[2];
		float D = rN[0] * NF[0] + rN[1] * NF[1] + rN[2] * NF[2];
		float lO = sq(rO[0] * rO[0] + rO[1] * rO[1] + rO[2] * rO[2]), lN = sq(rN[0] * rN[0] + rN[1] * rN[1] + rN[2] * rN[2]);
		float TG = tn(g_old.fovG * 0.5f * 0.0174533f);
		if (lO > 0.3f && D > 0.1f) {
			static float S = 1.f; S += (lN / lO - S) * 0.3f;   // light smoothing: the pose pick behind lO can hop between GTA frames
			float mo[2];
			if (g_obsOK && seated) { mo[0] = (g_obsTopX - 0.5f) * 2.f * TG * g_obsAsp; mo[1] = (0.5f - g_obsTopY) * 2.f * TG; }
			else if (g_obsOK) { mo[0] = (g_obsX - 0.5f) * 2.f * TG * g_obsAsp; mo[1] = (0.5f - g_obsY) * 2.f * TG; }
			else if (Z > 0.3f) { mo[0] = (rO[0] * OR[0] + rO[1] * OR[1] + rO[2] * OR[2]) / Z; mo[1] = (rO[0] * OU[0] + rO[1] * OU[1] + rO[2] * OU[2]) / Z; }
			else { mo[0] = 0.f; mo[1] = 0.f; }
			// How high his centroid sits above his lowest point, as seen (so camera pitch is already in it). Peak-held with a slow
			// decay: with a foot planted this is the true value and the foot lands on the ground; in the air phase of a stride the
			// measured value is smaller and the difference shows up as the foot being off the ground, instead of the body bobbing.
			float dz = rN[2] / lN, cph = sq(1.f - dz * dz); if (cph < 0.35f) cph = 0.35f;   // cos of the camera's elevation above him
			if (g_obsOK && !skel) {
				float botY = (0.5f - g_obsBotY) * 2.f * TG;
				float cand = (mo[1] - botY) * lO / cph; if (cand < 0.7f) cand = 0.7f; if (cand > 1.1f) cand = 1.1f;
				float dec = g_hc - 0.3f * dtf; g_hc = cand > dec ? cand : dec;
			}
			float mn[2] = { (rN[0] * NR[0] + rN[1] * NR[1] + rN[2] * NR[2]) / D, (rN[0] * NU[0] + rN[1] * NU[1] + rN[2] * NU[2]) / D };
			float CO[2] = { mo[0] - mn[0] * S, mo[1] - mn[1] * S };
			float T[2] = { tn(g_new.fovB * 0.5f * 0.0174533f), TG };
			float fT[2] = { 0.f, -1.f };   // the ground under him in the current view (tan space)
			float rF[3] = { rN[0], rN[1], rN[2] - hcU - airU };
			float zf = rF[0] * NF[0] + rF[1] * NF[1] + rF[2] * NF[2];
			if (zf > 0.1f) { fT[0] = (rF[0] * NR[0] + rF[1] * NR[1] + rF[2] * NR[2]) / zf; fT[1] = (rF[0] * NU[0] + rF[1] * NU[1] + rF[2] * NU[2]) / zf; }
			setF(rt, "CardS", &S, 1); setF(rt, "CardO", CO, 2); setF(rt, "ZNew", &D, 1); setF(rt, "TanH", T, 2); setF(rt, "FeetT", fT, 2);
			// door open / inside a car: let the car body hide him (1); seated with the door shut, so behind glass (2)
			float inCar = g_bodyMode > 3.5f ? 2.f : (g_bodyMode > 1.5f && g_bodyMode < 2.5f) ? 1.f : 0.f;
			setF(rt, "InCar", &inCar, 1);
			float waterH = inCar > 0.5f ? 0.f : g_waterH; setF(rt, "WaterH", &waterH, 1);
			setF(rt, "Shade", g_shade, 4);
			setF(rt, "Ghost", &g_ghost, 1);
			// cast shadow: everything in camera space (right, up, forward), metres. His body is handed to the shader as capsules built
			// on GTA's joints; the shader asks, for every piece of ground or car on screen, whether one of them is between it and the sun.
			float sunC[3] = { g_sun[0] * NR[0] + g_sun[1] * NR[1] + g_sun[2] * NR[2], g_sun[0] * NU[0] + g_sun[1] * NU[1] + g_sun[2] * NU[2], g_sun[0] * NF[0] + g_sun[1] * NF[1] + g_sun[2] * NF[2] };
			float upC[3] = { NR[2], NU[2], NF[2] };
			float feetC[3] = { rF[0] * NR[0] + rF[1] * NR[1] + rF[2] * NR[2], rF[0] * NU[0] + rF[1] * NU[1] + rF[2] * NU[2], zf };
			setF(rt, "SunC", sunC, 3); setF(rt, "UpC", upC, 3); setF(rt, "FeetC", feetC, 3);
			float capN = (nowSec() - g_skT < 0.3 && inCar < 0.5f) ? 1.f : 0.f;
			if (capN > 0.5f) {
				static float capA[80], capB[80];
				float J[20][3];   // joints in camera space
				for (int i = 0; i < 20; i++) {
					float d[3] = { (float)(g_sk[i][0] - g_new.p[0]), (float)(g_sk[i][1] - g_new.p[1]), (float)(g_sk[i][2] - g_new.p[2]) };
					J[i][0] = d[0] * NR[0] + d[1] * NR[1] + d[2] * NR[2]; J[i][1] = d[0] * NU[0] + d[1] * NU[1] + d[2] * NU[2]; J[i][2] = d[0] * NF[0] + d[1] * NF[1] + d[2] * NF[2];
				}
				for (int i = 0; i < 20; i++) {
					const float *a = J[CAPS[i].a], *b = J[CAPS[i].b];
					for (int k = 0; k < 3; k++) { capA[i * 4 + k] = a[k]; capB[i * 4 + k] = b[k]; }
					if (i == 17) for (int k = 0; k < 3; k++) capB[i * 4 + k] = J[3][k] + (J[3][k] - J[2][k]) * 0.9f;   // head: on past the head joint
					capA[i * 4 + 3] = CAPS[i].r; capB[i * 4 + 3] = 0.f;
				}
				float capC[3] = { (J[0][0] + J[2][0]) * 0.5f, (J[0][1] + J[2][1]) * 0.5f, (J[0][2] + J[2][2]) * 0.5f };
				setF(rt, "CapA", capA, 80); setF(rt, "CapB", capB, 80); setF(rt, "CapC", capC, 3);
			}
			setF(rt, "CapN", &capN, 1);
		}
	}

	// 4) tell Lua the measured latency a few times a second; then hold the frame rate (after the uniforms, so they match this frame)
	if (calls % 15 == 0) sendAge(g_age);
	limitFps();
}

extern "C" __declspec(dllexport) const char *NAME = "GTA overlay";
extern "C" __declspec(dllexport) const char *DESCRIPTION = "Feeds the shared-memory GTA frame into the GtaOverlay effect, re-projected to the current camera.";

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID)
{
	if (reason == DLL_PROCESS_ATTACH) {
		if (!reshade::register_addon(h)) return FALSE;
		reshade::register_event<reshade::addon_event::reshade_begin_effects>(on_begin_effects);
		reshade::register_event<reshade::addon_event::destroy_effect_runtime>(on_destroy_runtime);
	} else if (reason == DLL_PROCESS_DETACH) {
		reshade::unregister_addon(h);
	}
	return TRUE;
}
