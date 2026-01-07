-- SMAA Search Texture Generator
-- Based on https://github.com/iryoku/smaa/blob/master/Scripts/SearchTex.py
-- Generates the 64x16 R8 search texture at runtime
local Texture = require("render.texture")
local ffi = require("ffi")
local tex = Texture.New(
	{
		width = 64,
		height = 16,
		format = "r8_unorm",
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
	// Calculates the bilinear fetch for a certain edge combination:
	// e[0]       e[1]
	//
	//          x <-------- Sample position:    (-0.25,-0.125)
	// e[2]       e[3] <--- Current pixel [3]:  (  0.0, 0.0  )
	//
	// lerp(lerp(e0,e1,0.75), lerp(e2,e3,0.75), 0.875)
	float bilinear(ivec4 e) {
		float a = mix(float(e[0]), float(e[1]), 0.75);
		float b = mix(float(e[2]), float(e[3]), 0.75);
		return mix(a, b, 0.875);
	}
	
	// Reverse lookup: given a bilinear value, decode which edges are active
	ivec4 decodeEdges(float val) {
		// The 16 possible edge combinations and their bilinear values
		// We find the closest match
		int best = 0;
		float bestDist = 1000.0;
		for (int i = 0; i < 16; i++) {
			ivec4 e = ivec4((i >> 3) & 1, (i >> 2) & 1, (i >> 1) & 1, i & 1);
			float b = bilinear(e);
			float d = abs(b - val);
			if (d < bestDist) {
				bestDist = d;
				best = i;
			}
		}
		return ivec4((best >> 3) & 1, (best >> 2) & 1, (best >> 1) & 1, best & 1);
	}
	
	// Delta distance to add in the last step of searches to the left:
	int deltaLeft(ivec4 left, ivec4 top) {
		int d = 0;
		
		// If there is an edge at top[3], continue:
		if (top[3] == 1)
			d += 1;
		
		// If we previously found an edge, there is another edge at top[2],
		// and no crossing edges, continue:
		if (d == 1 && top[2] == 1 && left[1] != 1 && left[3] != 1)
			d += 1;
		
		return d;
	}
	
	// Delta distance to add in the last step of searches to the right:
	int deltaRight(ivec4 left, ivec4 top) {
		int d = 0;
		
		// If there is an edge at top[3], and no crossing edges, continue:
		if (top[3] == 1 && left[1] != 1 && left[3] != 1)
			d += 1;
		
		// If we previously found an edge, there is another edge at top[2],
		// and no crossing edges, continue:
		if (d == 1 && top[2] == 1 && left[0] != 1 && left[2] != 1)
			d += 1;
		
		return d;
	}
	
	vec4 shade(vec2 uv, vec3 dir) {
		// Final texture is 64x16, cropped from 66x33
		// Original: left half (0-32) = left search, right half (33-65) = right search
		// Crop: [0,17] to [64,33], then flipped vertically
		
		ivec2 pixel = ivec2(uv * vec2(64.0, 16.0));
		
		// Account for the vertical flip and crop offset
		// Original y range was 17-32, flipped means py=0 -> orig_y=32, py=15 -> orig_y=17
		int orig_y = 32 - pixel.y;
		int orig_x = pixel.x;
		
		// Check if this maps to a valid edge combination
		float e1_coord = float(min(orig_x, 32)) * 0.03125; // 1/32 step
		float e2_coord = float(orig_y) * 0.03125;
		
		// Decode edges from texcoords
		ivec4 left = decodeEdges(e1_coord);
		ivec4 top = decodeEdges(e2_coord);
		
		int delta;
		if (orig_x < 33) {
			// Left search texture
			delta = deltaLeft(left, top);
		} else {
			// Right search texture (x offset by 33)
			delta = deltaRight(left, top);
		}
		
		// Scale by 127/255 to maximize dynamic range (matching Python: val = 127 * delta)
		float val = float(delta) * (127.0 / 255.0);
		
		return vec4(val, 0.0, 0.0, 1.0);
	}
]])
return tex
