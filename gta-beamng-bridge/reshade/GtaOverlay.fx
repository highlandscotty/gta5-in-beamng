// BeamNG side: paste the keyed GTA frame (Michael, rendered from BeamNG's camera a few frames ago) into BeamNG's finished frame.
// He is a camera-facing billboard slid and scaled onto where he stands in the frame being shown, so he stays glued to the ground
// while the camera moves and never looks like a foreshortened flat card.
// Depth occlusion by BeamNG geometry (auto-disabled if BeamNG depth is unusable), soft edge, contact shadow.
#include "ReShade.fxh"

texture GtaTex < source = "GtaPlaceholder.png"; > { Width = 1920; Height = 1080; Format = RGBA8; };
sampler GtaSamp { Texture = GtaTex; AddressU = BORDER; AddressV = BORDER; MinFilter = LINEAR; MagFilter = LINEAR; };
sampler GtaPt { Texture = GtaTex; AddressU = BORDER; AddressV = BORDER; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };   // exact texels: the "this is GTA's sea" mark is one bit

uniform float Scale < ui_type = "slider"; ui_min = 0.1; ui_max = 1.0; ui_label = "Overlay scale (1 = full-screen composite)"; > = 1.0;
uniform bool UseOcclusion < ui_label = "Hide Michael behind BeamNG objects (needs BeamNG depth)"; > = true;
uniform float OccMargin < ui_type = "slider"; ui_min = 0.2; ui_max = 3.0; ui_label = "Occlusion margin (m)"; > = 0.6;
uniform float BeamNear < ui_type = "slider"; ui_min = 0.01; ui_max = 1.0; ui_label = "BeamNG near clip (m)"; > = 0.1;
uniform float3 ShadowColor < ui_type = "color"; ui_label = "Michael's shadow: what is left of the ground's colour (match BeamNG's own shadows; white = no shadow)"; > = float3(0.47, 0.52, 0.62);
uniform float ShadowSoft < ui_type = "slider"; ui_min = 0.2; ui_max = 4.0; ui_label = "Michael's shadow: edge softness"; > = 1.0;
uniform float ColorMul < ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_label = "Michael brightness"; > = 1.0;
uniform float GlassReflect < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Seated in a car: how much of the window glass shows over Michael"; > = 0.35;
uniform bool DepthReversed < ui_label = "BeamNG depth is reversed (near = 1). Leave on; turn off only if he is hidden everywhere"; > = true;
uniform float WaterHide < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "In water: how much of him below the surface is hidden"; > = 0.75;
uniform float UnderShow < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Swimming: how strongly his body shows under the surface"; > = 0.9;
uniform float UnderKey < ui_type = "slider"; ui_min = 0.01; ui_max = 0.2; ui_label = "Swimming: how different from open sea a pixel must be to count as his body (lower shows more of him and more stray water)"; > = 0.05;
uniform int Debug < ui_type = "combo"; ui_items = "Off\0BeamNG depth\0GTA frame\0"; > = 0;
// written every frame by the beam_overlay add-on (identity defaults = no re-projection):
uniform float GtaAspect = 1.7778;
uniform float2 FeetUV = float2(0.5, 0.8);   // Michael's feet in the GTA frame
uniform float BodyH = 0.0;                  // Michael's height in the GTA frame (fraction of its height)
uniform float CardS = 1.0;                   // GTA-frame tan-space = current tan-space * CardS + CardO (set by the add-on)
uniform float2 CardO = float2(0.0, 0.0);
uniform float ZNew = 3.2;                     // Michael's depth along the current view axis (m), for occlusion
uniform float2 TanH = float2(0.577, 0.577);   // tan(vertical fov / 2): x = BeamNG now, y = GTA frame
uniform float2 FeetT = float2(0.0, -1.0);     // his feet in the current view, tan space
// cast shadow (camera space: x right, y up, z forward; metres)
uniform float3 SunC = float3(0.0, 0.0, 0.0);  // unit vector towards the sun (0 = unknown -> soft blob instead)
uniform float3 UpC = float3(0.0, 1.0, 0.0);   // world up
uniform float3 FeetC = float3(0.0, -1.5, 3.2);// the ground under his body centre
uniform float4 CapA[20];                      // his body as capsules on GTA's joints: one end (xyz) and the radius (w) ...
uniform float4 CapB[20];                      // ... and the other end
uniform float3 CapC = float3(0.0, 0.0, 3.2);  // middle of his body (to skip the pixels he cannot shade)
uniform float CapN = 0.0;                     // 1 while the joints are known
uniform float InCar = 0.0;                    // 1 while he is getting into / sitting in a car: tighter occlusion so the car body hides him like a driver; 2 = seated with the door shut
uniform float WaterH = 0.0;                   // how deep the water is where he stands (m above the ground under him); 0 = dry; negative = he is swimming in it
uniform float4 Shade = float4(0.0, 0.0, 0.0, 0.0);   // BeamNG's own shadows (1 = in shadow): on his legs, on his head, on the ground at his feet, on the ground where his head's shadow lands
uniform float Ghost = 1.0;                    // how solid he and his shadow are drawn: below 1 while one of BeamNG's wheel menus is up, so that it shows through him
uniform float Show = 1.0;                     // 0 while Michael is not on foot (in a vehicle / bridge off)

float RawD(float2 uv) { return tex2Dlod(ReShade::DepthBuffer, float4(uv, 0, 0)).x; }

float4 PS_Overlay(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 back = tex2D(ReShade::BackBuffer, uv);
	if (Show < 0.5) return back;
	float ab = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);

	float2 o = uv;
	if (Scale < 0.999) {
		o = (uv - (1.0 - Scale)) / Scale;
		if (o.x < 0.0 || o.y < 0.0 || o.x > 1.0 || o.y > 1.0) return back;
		back.rgb *= 0.6;   // dim the inset so its bounds are visible
	}

// current-view tan-space position of this pixel -> position in the GTA frame (identity when nothing moved)
	float2 sn = float2((o.x * 2.0 - 1.0) * ab * TanH.x, (1.0 - o.y * 2.0) * TanH.x);
	float2 so = sn * CardS + CardO;
	float2 g = float2(0.5 + so.x / (2.0 * TanH.y * GtaAspect), 0.5 - so.y / (2.0 * TanH.y));
	float t = ZNew;

	// BeamNG scene depth -> metres. The convention is fixed: guessing it each frame from "the top of the screen is farther than the
	// bottom" was wrong under any ceiling (garage, tunnel, interior), and then everything hid him.
	bool depthOk = true;
	bool rev = DepthReversed;
	float dn = RawD(uv);
	dn = rev ? dn : 1.0 - dn;                       // 1 = near, 0 = far
	float z = BeamNear / max(dn, 0.0000001);

	if (Debug == 1) {
		return float4(saturate(z / 20.0).xxx, 1.0);
	}
	if (Debug == 2) return float4(tex2Dlod(GtaSamp, float4(g, 0, 0)).rgb, 1.0);

	// sprite with a soft, slightly eroded edge: 3x3 coverage
	float2 px = float2(1.0 / 1920.0, 1.0 / 1080.0);
	float3 acc = float3(0.0, 0.0, 0.0);
	float cnt = 0.0;
	[unroll] for (int j = -1; j <= 1; j++) {
		[unroll] for (int i = -1; i <= 1; i++) {
			float4 s = tex2Dlod(GtaSamp, float4(g + float2(i, j) * px, 0, 0));
			float c = s.a > 0.002 ? 1.0 : 0.0;
			acc += s.rgb * c;
			cnt += c;
		}
	}
	float a = saturate((cnt - 3.0) / 5.0);
	float3 col = acc / max(cnt, 1.0) * ColorMul;

	// objects clearly nearer to the camera than Michael hide him
	float vis = 1.0;
	// in a car the tolerance is tight (anything 12 cm nearer than him hides him: door, pillars, dash, seat back seen from behind)
	if (UseOcclusion && depthOk) vis = InCar > 0.5 ? saturate((z - (t - 0.12)) / 0.15) : saturate((z - (t - OccMargin)) / 0.25);

	// Cast shadow. The piece of the BeamNG scene behind this pixel is rebuilt from BeamNG's depth; from there a ray goes towards the
	// sun, and if it passes through his body (capsules standing on GTA's joints, so the true 3D pose seen from the sun, not the
	// picture's outline) the pixel is in his shadow. It lands on whatever is there (ground, bonnet, roof), starts exactly at his
	// feet, and its edge softens with the distance from him like a real one.
	float3 rgb = back.rgb;
	float sunUp = dot(SunC, UpC);
	if (InCar > 0.5) {
		// inside the car: its own shadow covers him
	}
	else if (CapN > 0.5 && depthOk && sunUp > 0.03 && Scale > 0.999) {
		// depth scale check against a point we know, the ground at his feet (ignored when something else is there: he is up on a car)
		float2 fuv = float2(0.5 + FeetT.x / (2.0 * TanH.x * ab), 0.5 - FeetT.y / (2.0 * TanH.x));
		float zcal = 1.0;
		if (fuv.x > 0.02 && fuv.x < 0.98 && fuv.y > 0.02 && fuv.y < 0.98) {
			float df = RawD(fuv); df = rev ? df : 1.0 - df;
			float zr = FeetC.z / (BeamNear / max(df, 0.0000001));
			if (zr > 0.9 && zr < 1.1) zcal = zr;
		}
		float zc = z * zcal;
		float3 P = float3(sn.x * zc, sn.y * zc, zc);
		float3 rc = P - CapC;
		if (zc < 300.0 && length(rc + SunC * max(-dot(SunC, rc), 0.0)) < 1.5) {
			float sh = 0.0, hq = 0.0;
			for (int k = 0; k < 20; k++) {
				// closest approach of the ray P + s * sun (s >= 0) to the capsule's axis A + t * d (0 <= t <= 1)
				float3 A = CapA[k].xyz, d = CapB[k].xyz - A, r = P - A;
				float dd = dot(d, d), b = dot(d, SunC), c = dot(d, r), f = dot(SunC, r);
				float den = dd - b * b;
				float t = den > 0.00001 ? saturate((c - b * f) / den) : 0.0;
				float s = max(b * t - f, 0.0);
				t = saturate((c + b * s) / max(dd, 0.00001));
				float dist = length(r + SunC * s - d * t);
				// penumbra: crisp where the shadow starts at his feet, wider (and, for thin limbs, fainter) the further it falls from him
				float pen = (0.012 + 0.03 * s) * ShadowSoft;
				float cs = 1.0 - smoothstep(CapA[k].w - pen, CapA[k].w + pen, dist);
				if (cs > sh) { sh = cs; hq = dot(A + d * t - FeetC, UpC); }   // (and how high up him the part casting it is)
			}
			// Ground that already lies in one of BeamNG's shadows gets no sun for him to block: no second, darker shadow on top of it.
			sh *= 1.0 - lerp(Shade.z, Shade.w, saturate(hq / 1.7));
			rgb *= lerp(float3(1.0, 1.0, 1.0), ShadowColor, sh);
		}
	}
	else if (BodyH > 0.01 && FeetT.y > -0.99) {
		// no sun direction or no joints (or night): soft blob under his feet
		float2 f = float2(0.5 + FeetT.x / (2.0 * TanH.x * ab), 0.5 - FeetT.y / (2.0 * TanH.x));
		float k = (TanH.y / TanH.x) / max(CardS, 0.05);
		f.y -= BodyH * 0.02 * k;
		float R = BodyH * 0.32 * k;
		float dx = (o.x - f.x) * ab / R;
		float dy = (o.y - f.y) / (R * 0.35);
		rgb *= lerp(float3(1.0, 1.0, 1.0), ShadowColor, exp(-(dx * dx + dy * dy) * 1.5) * vis * (1.0 - Shade.z));
	}

	// Window glass is not in BeamNG's depth, so it can never cover him. Seated behind a shut door he is dimmed a little and what was
	// on screen there (the pane's tint and reflections over a dark cabin) is laid back over him.
	// ponytail: a flat blend, the same through an open window as through glass; needs a glass mask from BeamNG to do better
	if (InCar > 1.5) col = col * 0.85 + back.rgb * GlassReflect;
	// BeamNG's water is not in its depth either: the part of him below the surface is mostly given back to the water.
	// ponytail: height is taken on the flat card he is drawn on, so a swimmer's legs pointing at the camera count as deeper than they are
	if (WaterH > 0.05) a *= 1.0 - WaterHide * smoothstep(0.05, -0.12, dot(float3(sn * t, t) - FeetC, UpC) - WaterH);
	// Swimming: what is under the surface of him. GTA's picture of its sea (marked by GtaKey) has him in it, seen through the water.
	// His legs and trunk are lifted out of it by how unlike the open sea each pixel is (the sea itself is read off the two ends of the
	// same screen row), in all colours at once, and laid over BeamNG's water as they are: his real body, in GTA's water tint. Only
	// close around his joints, so nothing else in GTA's sea gets in.
	// (Earlier tries: all of GTA's water inside his outline = a stick figure of GTA sea; BeamNG's water scaled per colour channel by
	// GTA's = pink; BeamNG's water only darkened = nothing to see.)
	if (WaterH < -0.05 && CapN > 0.5) {
		float4 sp = tex2Dlod(GtaPt, float4(g, 0, 0));
		float b8 = floor(sp.b * 255.0 + 0.5);
		float3 D = normalize(float3(sn, 1.0));
		if (sp.a < 0.5 && b8 - 2.0 * floor(b8 * 0.5) > 0.5 && length(CapC - D * dot(CapC, D)) < 1.8) {
			float m = 0.0;
			for (int k = 0; k < 20; k++) {
				// closest approach of the line of sight (from the camera, along D) to the capsule's axis: as for the shadow
				float3 A = CapA[k].xyz, d = CapB[k].xyz - A, r = -A;
				float dd = dot(d, d), b = dot(d, D), c = dot(d, r), f = dot(D, r);
				float den = dd - b * b;
				float u = den > 0.00001 ? saturate((c - b * f) / den) : 0.0;
				float s = max(b * u - f, 0.0);
				u = saturate((c + b * s) / max(dd, 0.00001));
				m = max(m, 1.0 - smoothstep(CapA[k].w + 0.05, CapA[k].w + 0.22, length(D * s - A - d * u)));
			}
			float3 sea = lerp(tex2Dlod(GtaSamp, float4(0.02, g.y, 0, 0)).rgb, tex2Dlod(GtaSamp, float4(0.98, g.y, 0, 0)).rgb, g.x);
			float body = smoothstep(UnderKey, UnderKey * 3.0, length(sp.rgb - sea));
			rgb = lerp(rgb, sp.rgb * ColorMul, body * m * UnderShow * vis);
		}
	}
	// He stands in one of BeamNG's shadows: the sun is taken off him the same way it is taken off the ground (legs and head
	// separately, blended up his height, so a shadow's edge crosses him instead of switching him)
	col *= lerp(float3(1.0, 1.0, 1.0), ShadowColor, lerp(Shade.x, Shade.y, saturate(dot(float3(sn * t, t) - FeetC, UpC) / 1.7)));
	rgb = lerp(rgb, col, a * vis);
	return float4(lerp(back.rgb, rgb, Ghost), 1.0);
}
technique GtaOverlay { pass { VertexShader = PostProcessVS; PixelShader = PS_Overlay; } }
