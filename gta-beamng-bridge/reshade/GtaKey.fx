// GTA side: alpha = depth key (Michael is the only thing nearer than KeyMax). No debug views: a stale "mask" setting in the preset turned the whole BeamNG frame black.
// Swimming, GTA's sea is near him too and it is in the depth buffer. A flat surface seen by a camera that does not roll has the
// same depth all along a screen row, and he never fills a whole row: so the farthest of a few points spread along the row is the
// water there, and only what is clearly nearer than that is him. The water itself gets alpha 0 and a mark, the lowest bit of blue
// (0 on everything else): BeamNG's overlay uses the marked pixels around his body to show him under the surface.
// ponytail: assumes no camera roll and flat water (the script turns GTA's waves off) and a camera above the surface
#include "ReShade.fxh"
uniform float KeyMax < ui_type = "slider"; ui_min = 0.0005; ui_max = 0.5; ui_step = 0.0005; ui_label = "Key depth (linear, 1 = far plane)"; > = 0.061;
uniform float WaterTol < ui_type = "slider"; ui_min = 0.0; ui_max = 0.2; ui_step = 0.005; ui_label = "Swimming: how much nearer than the water a pixel must be to be Michael (raise if specks of water show, lower if he is eaten at the waterline)"; > = 0.08;

// raw depth as nearness (1 = at the camera, 0 = infinitely far)
float Near(float2 uv)
{
	float d = tex2Dlod(ReShade::DepthBuffer, float4(uv, 0, 0)).x;
#if RESHADE_DEPTH_INPUT_IS_REVERSED
	return d;
#else
	return 1.0 - d;
#endif
}
// the same linear depth GetLinearizedDepth gives, from a nearness
float Lin(float n)
{
	float d = 1.0 - n;
	return d / (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - d * (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - 1.0));
}
float4 PS_Key(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float n = Near(uv);
	bool key = Lin(n) < KeyMax, sea = false;
	float w = 1.0, s[6];
	for (int i = 0; i < 6; i++) { s[i] = Near(float2(0.02 + 0.192 * i, uv.y)); w = min(w, s[i]); }
	// (water is level: at least three of the six agree with the farthest. With the camera pushed right up to him on land the six
	// are all on his body, at different depths, and nothing may be cut out of him then.)
	int same = 0;
	for (int j = 0; j < 6; j++) if (s[j] <= w * (1.0 + 0.5 * WaterTol)) same++;
	// (1 - w / n is how high the pixel stands above the water, as a fraction of the camera's own height above it)
	sea = key && same >= 3 && n <= w * (1.0 + WaterTol);
	key = key && !sea;
	float3 c = tex2D(ReShade::BackBuffer, uv).rgb;
	c.b = (floor((c.b * 255.0 + 0.5) * 0.5) * 2.0 + (sea ? 1.0 : 0.0)) / 255.0;
	return float4(c, key ? 1.0 : 0.0);
}
technique GtaKey { pass { VertexShader = PostProcessVS; PixelShader = PS_Key; } }
