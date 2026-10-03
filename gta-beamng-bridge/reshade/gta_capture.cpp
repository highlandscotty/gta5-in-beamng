// GTA side: after ReShade effects ran, copy the backbuffer to CPU and publish it in shared memory.
// The "GtaKey" effect (reshade-shaders/Shaders/GtaKey.fx) puts a depth mask into the alpha channel.
#define NOMINMAX
#include <windows.h>
#include <reshade.hpp>
#include <string.h>
#include <stdio.h>
#include "common.h"
using namespace reshade::api;
extern "C" { int _fltused = 0; }
static void L(const char *m) { reshade::log::message(reshade::log::level::info, m); }

static HANDLE g_map; static PipeHeader *g_pipe;
static void keepFocus(HWND h);
// Three readback textures in rotation, mapped without waiting (D3D11_MAP_FLAG_DO_NOT_WAIT): the old wait_idle() stalled GTA's CPU on the
// GPU every frame, which with BeamNG hogging the GPU dropped GTA to ~10 fps. A copy is published as soon as the GPU has finished it: normally
// within the same frame, while GTA waits for BeamNG's next frame (see pace()); if not, at the next chance.
static resource g_stage[3]; static bool g_pend[3]; static uint32_t g_tag[3]; static int g_si, g_cur = -1; static uint32_t g_sw, g_sh; static format g_sf;
static uint32_t g_tick, g_relTick;   // g_relTick: the BeamNG frame that set off the GTA frame being drawn now
static uint32_t g_sameFrame, g_late; // statistics: copies published within their own frame / later
static void *g_ctx;                  // ID3D11DeviceContext* (GTA V Legacy is D3D11)
struct MappedSub { void *pData; UINT RowPitch; UINT DepthPitch; };
typedef HRESULT (__stdcall *MapFn)(void *self, void *res, UINT sub, UINT mapType, UINT flags, MappedSub *out);
typedef void (__stdcall *UnmapFn)(void *self, void *res, UINT sub);

// newest finished copy -> shared memory. True once the copy of the frame just drawn (g_cur) is out.
static bool publish()
{
	if (!g_ctx || g_cur < 0) return true;
	void **vt = *(void ***)g_ctx;
	MapFn Map = (MapFn)vt[14]; UnmapFn Unmap = (UnmapFn)vt[15];
	for (int a = 0; a <= 2; a++) {   // newest first
		int j = (g_cur + 3 - a) % 3;
		if (!g_pend[j]) continue;
		MappedSub ms = {};
		if (FAILED(Map(g_ctx, (void *)g_stage[j].handle, 0, 1 /*D3D11_MAP_READ*/, 0x100000 /*DO_NOT_WAIT*/, &ms)) || !ms.pData) continue;
		static uint32_t counter = 0;
		uint32_t w = g_sw, h = g_sh;
		uint32_t si = (g_pipe->latest + 1) % PIPE_SLOTS;   // never the slot the reader may be on
		PipeSlot *sl = &g_pipe->slot[si];
		sl->seq++;
		uint8_t *dst = PIPE_PIXELS(g_pipe, si); const uint8_t *src = (const uint8_t *)ms.pData;
		for (uint32_t y = 0; y < h; y++) memcpy(dst + (size_t)y * w * 4, src + (size_t)y * ms.RowPitch, (size_t)w * 4);
		sl->width = w; sl->height = h;
		sl->bgr = (g_sf == format::b8g8r8a8_unorm || g_sf == format::b8g8r8x8_unorm) ? 1 : 0;
		sl->tick = g_tag[j];
		sl->frame = ++counter;
		sl->seq++;
		g_pipe->frame = counter; g_pipe->latest = si;
		Unmap(g_ctx, (void *)g_stage[j].handle, 0);
		for (int o = a; o <= 2; o++) g_pend[(g_cur + 3 - o) % 3] = false;   // this one is out; never publish an older frame after a newer one
		if (a == 0) g_sameFrame++; else g_late++;
		break;
	}
	return !g_pend[g_cur];
}

static void capture(effect_runtime *rt, command_list *cmd, resource_view rtv, resource_view)
{
	if (!g_pipe) return;
	static bool first = true; if (first) { first = false; L("gta_capture: first finish_effects"); }
	++g_tick;
	if (g_tick < 600) return;   // skip the launcher/loading-screen swapchains; then every frame
	keepFocus((HWND)rt->get_hwnd());
	static DWORD t0 = 0; static uint32_t n0 = 0;   // log GTA's real frame rate every 300 frames
	if (g_tick - 600 == n0 + 300 || t0 == 0) {
		DWORD t1 = GetTickCount();
		if (t0) { char m[128]; _snprintf(m, sizeof m, "gta_capture: %.1f fps, pictures out within their own frame %u, later %u", 300000.0 / (double)(t1 - t0 ? t1 - t0 : 1), g_sameFrame, g_late); L(m); }
		t0 = t1; n0 = g_tick - 600; g_sameFrame = g_late = 0;
	}
	device *dev = rt->get_device();
	resource bb = dev->get_resource_from_view(rtv);
	resource_desc d = dev->get_resource_desc(bb);
	uint32_t w = d.texture.width, h = d.texture.height;
	format f = format_to_default_typed(d.texture.format, 0);
	if ((uint64_t)w * h * 4 > PIPE_MAX_BYTES) return;
	if (g_stage[0].handle == 0 || g_sw != w || g_sh != h || g_sf != f) {
		for (int i = 0; i < 3; i++) { if (g_stage[i].handle) dev->destroy_resource(g_stage[i]); g_stage[i].handle = 0; g_pend[i] = false; }
		L("gta_capture: creating staging textures");
		g_cur = -1;
		for (int i = 0; i < 3; i++)
			if (!dev->create_resource(resource_desc(w, h, 1, 1, f, 1, memory_heap::readback, resource_usage::copy_dest), nullptr, resource_usage::copy_dest, &g_stage[i])) { g_stage[i].handle = 0; L("gta_capture: create staging FAILED"); return; }
		g_sw = w; g_sh = h; g_sf = f;
	}
	cmd->barrier(bb, resource_usage::render_target, resource_usage::copy_source);
	cmd->copy_texture_region(bb, 0, nullptr, g_stage[g_si], 0, nullptr);
	cmd->barrier(bb, resource_usage::copy_source, resource_usage::render_target);
	g_pend[g_si] = true; g_tag[g_si] = g_relTick; g_cur = g_si;
	command_queue *q = rt->get_command_queue();
	q->flush_immediate_command_list();
	g_ctx = (void *)q->get_native();
	g_si = (g_si + 1) % 3;
	publish();
}

// GTA throttles itself to exactly 30 fps whenever its window is not the foreground one (the log showed 30.0 fps even before BeamNG was started,
// 100+ when clicked into). BeamNG has to be the foreground window, so hide focus loss from GTA: swallow the deactivation messages.
// [GTABRIDGE] KeepFocus=0 in GTA's ReShade.ini turns this off.
static WNDPROC g_orig; static HWND g_hw;
static LRESULT CALLBACK focusProc(HWND h, UINT m, WPARAM w, LPARAM l) {
	if ((m == WM_ACTIVATEAPP && !w) || (m == WM_ACTIVATE && LOWORD(w) == WA_INACTIVE) || m == WM_KILLFOCUS) return 0;
	return CallWindowProcW(g_orig, h, m, w, l);
}
static void keepFocus(HWND h) {
	if (g_hw || !h) return;
	g_hw = h;
	char b[8]; size_t n = 7;
	if (reshade::get_config_value(nullptr, "GTABRIDGE", "KeepFocus", b, &n) && b[0] == '0') { L("gta_capture: KeepFocus=0"); return; }
	g_orig = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)focusProc);
	if (!g_orig) { L("gta_capture: could not hook the window"); return; }
	PostMessageW(h, WM_ACTIVATEAPP, 1, 0); PostMessageW(h, WM_ACTIVATE, WA_ACTIVE, 0); PostMessageW(h, WM_SETFOCUS, 0, 0);   // in case focus was already lost
	L("gta_capture: focus-loss messages blocked (full frame rate in the background)");
}

// GTA competes with BeamNG for CPU and GPU: ask for more of both (CPU: high priority class; GPU: D3DKMT class 4/3, which Windows may refuse without admin rights).
static void boost() {
	SetPriorityClass(GetCurrentProcess(), 0x80 /*HIGH_PRIORITY_CLASS*/);
	HMODULE g = LoadLibraryA("gdi32.dll"); if (!g) return;
	typedef long (__stdcall *Fn)(HANDLE, int);
	Fn f = (Fn)GetProcAddress(g, "D3DKMTSetProcessSchedulingPriorityClass"); if (!f) return;
	for (int cls = 4; cls >= 3; cls--) {
		long st = f(GetCurrentProcess(), cls);
		char m[96]; _snprintf(m, sizeof m, "gta_capture: GPU priority class %d -> status 0x%08lX", cls, (unsigned long)st); L(m);
		if (st >= 0) break;
	}
}

static double nowSec() {
	static double inv = 0; LARGE_INTEGER c; QueryPerformanceCounter(&c);
	if (inv == 0) { LARGE_INTEGER q; QueryPerformanceFrequency(&q); inv = 1.0 / (double)q.QuadPart; }
	return (double)c.QuadPart * inv;
}
// Pacing. GTA draws one frame per BeamNG frame: each finished frame is held here until BeamNG's add-on signals that it has started its next
// one (common.h, TICK_EVENT). While it waits, the picture just drawn is handed over as soon as the GPU has it.
// Without BeamNG (not started, in a menu, loading) nothing signals: then GTA runs at 20 fps. [GTABRIDGE] in GTA's ReShade.ini:
// FrameLock=0 goes back to a plain frame cap; FpsCap (default 60, 0 = none) is that cap, and with FrameLock on the most GTA will ever do.
static void pace() {
	static int cap = -1, lock = 1; static HANDLE tmr, ev; static double next, lastRel; static uint32_t seen, waits, timeouts;
	if (cap < 0) {
		cap = 60; char b[16]; size_t n = 15;
		if (reshade::get_config_value(nullptr, "GTABRIDGE", "FpsCap", b, &n)) { int v = 0; for (const char *c = b; *c >= '0' && *c <= '9'; c++) v = v * 10 + (*c - '0'); cap = v; }
		n = 15; if (reshade::get_config_value(nullptr, "GTABRIDGE", "FrameLock", b, &n) && b[0] == '0') lock = 0;
		tmr = CreateWaitableTimerExW(nullptr, nullptr, 0x2 /*HIGH_RESOLUTION*/, 0x1F0003);
		ev = CreateEventA(nullptr, FALSE, FALSE, TICK_EVENT);
		char m[96]; _snprintf(m, sizeof m, "gta_capture: FpsCap=%d FrameLock=%d event=%d timer=%d", cap, lock, ev ? 1 : 0, tmr ? 1 : 0); L(m);
	}
	double t0 = nowSec();
	if (lock && ev && tmr) {
		double minGap = cap > 0 ? 0.9 / cap : 0.0;
		bool out = false;
		for (;;) {
			if (!out) out = publish();
			double now = nowSec();
			if (g_pipe->beamTick != seen && now - lastRel >= minGap) break;   // BeamNG has moved on: draw the next one
			if (now - t0 > 0.05) { timeouts++; break; }                        // BeamNG is not drawing
			LARGE_INTEGER due; due.QuadPart = -5000;                           // look again in 0.5 ms, or at once when BeamNG signals
			SetWaitableTimer(tmr, &due, 0, nullptr, nullptr, FALSE);
			HANDLE hs[2] = { ev, tmr };
			WaitForMultipleObjects(2, hs, FALSE, 5);
		}
		seen = g_relTick = g_pipe->beamTick;
		lastRel = nowSec();
		if (++waits % 600 == 0) { char m[96]; _snprintf(m, sizeof m, "gta_capture: in step with BeamNG, %u of the last 600 frames went without its signal", timeouts); L(m); timeouts = 0; }
		return;
	}
	g_relTick = 0;   // free-running: the pictures carry no BeamNG frame number
	if (cap <= 0) return;
	double now = t0;
	if (next == 0) next = now;
	next += 1.0 / cap;
	if (next < now) next = now;   // running late: don't try to catch up
	double rem = next - now;
	if (rem > 0.0015) {
		if (tmr) { LARGE_INTEGER due; due.QuadPart = -(LONGLONG)((rem - 0.0015) * 1e7); SetWaitableTimer(tmr, &due, 0, nullptr, nullptr, FALSE); WaitForSingleObject(tmr, 50); }
		else Sleep((DWORD)((rem - 0.002) * 1000.0));
	}
	while (nowSec() < next) YieldProcessor();
}
static void on_finish_effects(effect_runtime *rt, command_list *cmd, resource_view rtv, resource_view srgb)
{
	capture(rt, cmd, rtv, srgb);
	if (g_tick >= 600 && g_pipe) pace();   // (not the launcher / loading screens)
}

extern "C" __declspec(dllexport) const char *NAME = "GTA frame capture";
extern "C" __declspec(dllexport) const char *DESCRIPTION = "Publishes the keyed GTA frame to shared memory for the BeamNG overlay.";

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID)
{
	if (reason == DLL_PROCESS_ATTACH) {
		if (!reshade::register_addon(h)) return FALSE;
		g_map = CreateFileMappingA(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, (DWORD)PIPE_SIZE, PIPE_NAME);
		if (g_map) g_pipe = (PipeHeader *)MapViewOfFile(g_map, FILE_MAP_ALL_ACCESS, 0, 0, PIPE_SIZE);
		L(g_pipe ? "gta_capture: pipe mapped" : "gta_capture: PIPE MAP FAILED");
reshade::register_event<reshade::addon_event::reshade_finish_effects>(on_finish_effects);
		boost();
	} else if (reason == DLL_PROCESS_DETACH) {
		reshade::unregister_addon(h);
	}
	return TRUE;
}
