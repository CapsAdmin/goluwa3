-- SMAA Area Texture Generator
-- Based on https://github.com/iryoku/smaa/blob/master/Scripts/AreaTex.py
-- Generates the 160x560 RG8 area texture at runtime
local Texture = require("render.texture")
local ffi = require("ffi")
local tex = Texture.New(
	{
		width = 160,
		height = 560,
		format = "r8g8_unorm",
		image = {
			usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
)
tex:Shade([[
	#define SIZE_ORTHO 16.0
	#define SIZE_DIAG 20.0
	#define SMOOTH_MAX_DISTANCE 32.0

	const float SUBSAMPLE_OFFSETS_ORTHO[7] = float[7](
		0.0, -0.25, 0.25, -0.125, 0.125, -0.375, 0.375
	);

	const vec2 SUBSAMPLE_OFFSETS_DIAG[5] = vec2[5](
		vec2(0.0, 0.0), vec2(0.25, -0.25), vec2(-0.25, 0.25),
		vec2(0.125, -0.125), vec2(-0.125, 0.125)
	);

	const ivec2 EDGES_ORTHO[16] = ivec2[16](
		ivec2(0,0), ivec2(3,0), ivec2(0,3), ivec2(3,3),
		ivec2(1,0), ivec2(4,0), ivec2(1,3), ivec2(4,3),
		ivec2(0,1), ivec2(3,1), ivec2(0,4), ivec2(3,4),
		ivec2(1,1), ivec2(4,1), ivec2(1,4), ivec2(4,4)
	);

	const ivec2 EDGES_DIAG[16] = ivec2[16](
		ivec2(0,0), ivec2(1,0), ivec2(0,2), ivec2(1,2),
		ivec2(2,0), ivec2(3,0), ivec2(2,2), ivec2(3,2),
		ivec2(0,1), ivec2(1,1), ivec2(0,3), ivec2(1,3),
		ivec2(2,1), ivec2(3,1), ivec2(2,3), ivec2(3,3)
	);

	vec2 calcArea(vec2 p1, vec2 p2, float x) {
		vec2 d = p2 - p1;
		if (abs(d.x) < 1e-6) return vec2(0.0);
		
		float x1 = x, x2 = x + 1.0;
		float y1 = p1.y + d.y * (x1 - p1.x) / d.x;
		float y2 = p1.y + d.y * (x2 - p1.x) / d.x;
		
		bool inside = (x1 >= p1.x && x1 < p2.x) || (x2 > p1.x && x2 <= p2.x);
		if (!inside) return vec2(0.0);
		
		bool trap = (sign(y1) == sign(y2)) || abs(y1) < 1e-4 || abs(y2) < 1e-4;
		if (trap) {
			float a = (y1 + y2) * 0.5;
			return a < 0.0 ? vec2(abs(a), 0.0) : vec2(0.0, abs(a));
		}
		float xc = -p1.y * d.x / d.y + p1.x;
		float a1 = (xc > p1.x) ? y1 * fract(xc) * 0.5 : 0.0;
		float a2 = (xc < p2.x) ? y2 * (1.0 - fract(xc)) * 0.5 : 0.0;
		if (abs(a1) > abs(a2))
			return a1 < 0.0 ? vec2(abs(a1), abs(a2)) : vec2(abs(a2), abs(a1));
		return -a2 < 0.0 ? vec2(abs(a1), abs(a2)) : vec2(abs(a2), abs(a1));
	}

	void smoothArea(float d, inout vec2 a1, inout vec2 a2) {
		vec2 b1 = sqrt(a1 * 2.0) * 0.5;
		vec2 b2 = sqrt(a2 * 2.0) * 0.5;
		float p = clamp(d / SMOOTH_MAX_DISTANCE, 0.0, 1.0);
		a1 = mix(b1, a1, p); a2 = mix(b2, a2, p);
	}

	vec2 areaOrtho(int pat, float left, float right, float off) {
		float d = left + right + 1.0;
		float o1 = 0.5 + off, o2 = o1 - 1.0;
		
		if (pat == 0) return vec2(0.0);
		if (pat == 1) return left <= right ? calcArea(vec2(0, o2), vec2(d*0.5, 0), left) : vec2(0);
		if (pat == 2) return left >= right ? calcArea(vec2(d*0.5, 0), vec2(d, o2), left) : vec2(0);
		if (pat == 3) {
			vec2 a1 = calcArea(vec2(0, o2), vec2(d*0.5, 0), left);
			vec2 a2 = calcArea(vec2(d*0.5, 0), vec2(d, o2), left);
			smoothArea(d, a1, a2); return a1 + a2;
		}
		if (pat == 4) return left <= right ? calcArea(vec2(0, o1), vec2(d*0.5, 0), left) : vec2(0);
		if (pat == 5) return vec2(0.0);
		if (pat == 6) {
			if (abs(off) > 0.0) {
				vec2 a1 = calcArea(vec2(0, o1), vec2(d, o2), left);
				vec2 a2 = calcArea(vec2(0, o1), vec2(d*0.5, 0), left) + calcArea(vec2(d*0.5, 0), vec2(d, o2), left);
				return (a1 + a2) * 0.5;
			}
			return calcArea(vec2(0, o1), vec2(d, o2), left);
		}
		if (pat == 7) return calcArea(vec2(0, o1), vec2(d, o2), left);
		if (pat == 8) return left >= right ? calcArea(vec2(d*0.5, 0), vec2(d, o1), left) : vec2(0);
		if (pat == 9) {
			if (abs(off) > 0.0) {
				vec2 a1 = calcArea(vec2(0, o2), vec2(d, o1), left);
				vec2 a2 = calcArea(vec2(0, o2), vec2(d*0.5, 0), left) + calcArea(vec2(d*0.5, 0), vec2(d, o1), left);
				return (a1 + a2) * 0.5;
			}
			return calcArea(vec2(0, o2), vec2(d, o1), left);
		}
		if (pat == 10) return vec2(0.0);
		if (pat == 11) return calcArea(vec2(0, o2), vec2(d, o1), left);
		if (pat == 12) {
			vec2 a1 = calcArea(vec2(0, o1), vec2(d*0.5, 0), left);
			vec2 a2 = calcArea(vec2(d*0.5, 0), vec2(d, o1), left);
			smoothArea(d, a1, a2); return a1 + a2;
		}
		if (pat == 13) return calcArea(vec2(0, o2), vec2(d, o1), left);
		if (pat == 14) return calcArea(vec2(0, o1), vec2(d, o2), left);
		return vec2(0.0); // pat == 15
	}

	float diagSample(vec2 p1, vec2 p2, vec2 p) {
		if (p1 == p2) return 1.0;
		vec2 mid = (p1 + p2) * 0.5;
		float a = p2.y - p1.y, b = p1.x - p2.x;
		float count = 0.0;
		for (int x = 0; x < 30; x++) {
			for (int y = 0; y < 30; y++) {
				vec2 o = vec2(float(x), float(y)) / 29.0;
				if (a * (p.x + o.x - mid.x) + b * (p.y + o.y - mid.y) > 0.0) count += 1.0;
			}
		}
		return count / 900.0;
	}

	vec2 diagCalc(vec2 p1, vec2 p2, float left, vec2 off, int pat) {
		int e1 = EDGES_DIAG[pat].x, e2 = EDGES_DIAG[pat].y;
		vec2 pp1 = (e1 > 0) ? p1 + off : p1;
		vec2 pp2 = (e2 > 0) ? p2 + off : p2;
		float a1 = diagSample(pp1, pp2, vec2(1, 0) + left);
		float a2 = diagSample(pp1, pp2, vec2(1, 1) + left);
		return vec2(1.0 - a1, a2);
	}

	vec2 areaDiag(int pat, float left, float right, vec2 off) {
		float d = left + right + 1.0;
		vec2 dd = vec2(d);
		
		if (pat == 0) return (diagCalc(vec2(1,1), vec2(1,1)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 1) return (diagCalc(vec2(1,0), vec2(0,0)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 2) return (diagCalc(vec2(0,0), vec2(1,0)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 3) return diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat);
		if (pat == 4) return (diagCalc(vec2(1,1), vec2(0,0)+dd, left, off, pat) + diagCalc(vec2(1,1), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 5) return (diagCalc(vec2(1,1), vec2(0,0)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 6) return diagCalc(vec2(1,1), vec2(1,0)+dd, left, off, pat);
		if (pat == 7) return (diagCalc(vec2(1,1), vec2(1,0)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 8) return (diagCalc(vec2(0,0), vec2(1,1)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,1)+dd, left, off, pat)) * 0.5;
		if (pat == 9) return diagCalc(vec2(1,0), vec2(1,1)+dd, left, off, pat);
		if (pat == 10) return (diagCalc(vec2(0,0), vec2(1,1)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 11) return (diagCalc(vec2(1,0), vec2(1,1)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
		if (pat == 12) return diagCalc(vec2(1,1), vec2(1,1)+dd, left, off, pat);
		if (pat == 13) return (diagCalc(vec2(1,1), vec2(1,1)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,1)+dd, left, off, pat)) * 0.5;
		if (pat == 14) return (diagCalc(vec2(1,1), vec2(1,1)+dd, left, off, pat) + diagCalc(vec2(1,1), vec2(1,0)+dd, left, off, pat)) * 0.5;
		return (diagCalc(vec2(1,1), vec2(1,1)+dd, left, off, pat) + diagCalc(vec2(1,0), vec2(1,0)+dd, left, off, pat)) * 0.5;
	}

	vec4 shade(vec2 uv, vec3 dir) {
		vec2 texSize = vec2(160.0, 560.0);
		vec2 px = uv * texSize;
		
		bool isOrtho = px.x < 80.0;
		
		if (isOrtho) {
			int slot = int(floor(px.y / 80.0));
			float off = SUBSAMPLE_OFFSETS_ORTHO[clamp(slot, 0, 6)];
			vec2 loc = mod(px, 80.0);
			int patX = int(floor(loc.x / SIZE_ORTHO));
			int patY = int(floor(loc.y / SIZE_ORTHO));
			
			int pat = -1;
			for (int i = 0; i < 16; i++) {
				if (EDGES_ORTHO[i] == ivec2(patX, patY)) { pat = i; break; }
			}
			if (pat < 0) return vec4(0);
			
			vec2 sub = mod(loc, SIZE_ORTHO);
			return vec4(areaOrtho(pat, sqrt(sub.x), sqrt(sub.y), off), 0, 0);
		} else {
			float dx = px.x - 80.0;
			int slot = int(floor(px.y / 80.0));
			vec2 off = SUBSAMPLE_OFFSETS_DIAG[clamp(slot, 0, 4)];
			vec2 loc = vec2(dx, mod(px.y, 80.0));
			int patX = int(floor(loc.x / SIZE_DIAG));
			int patY = int(floor(loc.y / SIZE_DIAG));
			
			int pat = -1;
			for (int i = 0; i < 16; i++) {
				if (EDGES_DIAG[i] == ivec2(patX, patY)) { pat = i; break; }
			}
			if (pat < 0) return vec4(0);
			
			vec2 sub = mod(loc, SIZE_DIAG);
			return vec4(areaDiag(pat, sub.x, sub.y, off), 0, 0);
		}
	}
]])
return tex
