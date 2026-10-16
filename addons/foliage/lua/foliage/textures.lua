-- the procedural textures of the foliage, drawn on the gpu by Texture:Shade. a texture is a kind (the picture: bark,
-- leaves, a rock...) and a config, every key of which is a constant in the shader (color_* keys are srgb colors and
-- become linear vec3, style is a #define, the rest floats), so the same seed and config draw the same texture. a
-- kind draws every channel of its material from one function of the uv, `Surface surface_at(vec2 uv)`:
--
--   albedo: the color and the coverage in alpha (srgb). cutout kinds are alpha tested, their mips keep the coverage
--     (render/cutout_texture.lua)
--   normal: tangent space from the height
--   roughness: the perceptual roughness in one channel, for RoughnessTexture
--   transmission: how much light goes through, for TransmissionTexture
--
-- textures.Register(path, kind, config) makes a virtual texture asset of it, assets.GetTexture(path) draws it the
-- first time it is asked for, with the keys of the request's config over the registered ones
local ffi = require("ffi")
local assets = import("goluwa/assets.lua")
local Texture = import("goluwa/render/texture.lua")
local cutout_texture = import("goluwa/render/cutout_texture.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local textures = {}
textures.kinds = {}
local COMMON = glsl_common.GetHashGLSL() .. [[
#define PI 3.14159265359
#define TAU 6.28318530718

struct Surface {
	vec3 albedo;
	float alpha;
	float height;
	float roughness;
	float transmission;
};

Surface surface(vec3 albedo, float alpha, float height, float roughness, float transmission) {
	Surface s;
	s.albedo = albedo;
	s.alpha = alpha;
	s.height = height;
	s.roughness = roughness;
	s.transmission = transmission;
	return s;
}

// integer hashes of the cell and the seed, so every gpu draws the same picture from the same seed
float hash1(ivec2 c) { return pcg_unorm(pcg3d(uvec3(uvec2(c), SEED)).x); }
vec2 hash2(ivec2 c) { return vec2(pcg3d(uvec3(uvec2(c), SEED)).xy >> 8u) * (1.0 / 16777216.0); }
float hash1(ivec3 c) { return pcg_unorm(pcg4d(uvec4(uvec3(c), SEED)).x); }
vec3 hash3(ivec3 c) { return vec3(pcg4d(uvec4(uvec3(c), SEED)).xyz >> 8u) * (1.0 / 16777216.0); }

// the n-th random number of stream s, for laying out the things in a picture
float rand(int s, int n) { return pcg_unorm(pcg4d(uvec4(uint(s), uint(n), SEED, 40503u)).x); }

ivec2 wrap(ivec2 c, ivec2 period) { return ((c % period) + period) % period; }

vec2 grad2(ivec2 c) {
	float a = hash1(c) * TAU;
	return vec2(cos(a), sin(a));
}

// gradient noise repeating every period cells, about -1 to 1
float gnoise(vec2 p, ivec2 period) {
	vec2 i = floor(p);
	vec2 f = p - i;
	ivec2 c = ivec2(i);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = dot(grad2(wrap(c, period)), f);
	float b = dot(grad2(wrap(c + ivec2(1, 0), period)), f - vec2(1.0, 0.0));
	float d = dot(grad2(wrap(c + ivec2(0, 1), period)), f - vec2(0.0, 1.0));
	float e = dot(grad2(wrap(c + ivec2(1, 1), period)), f - vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(d, e, u.x), u.y) * 1.4142;
}

float gnoise(vec2 p) { return gnoise(p, ivec2(1 << 20)); }

float fbm(vec2 p, ivec2 period, int octaves) {
	float sum = 0.0;
	float amplitude = 0.5;
	float norm = 0.0;

	for (int i = 0; i < octaves; i++) {
		sum += gnoise(p + vec2(float(i * 17), float(i * 31)), period) * amplitude;
		norm += amplitude;
		p *= 2.0;
		period *= 2;
		amplitude *= 0.5;
	}

	return sum / norm;
}

float fbm(vec2 p, int octaves) { return fbm(p, ivec2(1 << 20), octaves); }

// the distance to the nearest and the second nearest point of a jittered grid, and a number of the nearest cell
vec3 voronoi(vec2 p, ivec2 period, float jitter) {
	ivec2 c = ivec2(floor(p));
	vec2 f = p - vec2(c);
	float f1 = 8.0;
	float f2 = 8.0;
	float id = 0.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 o = ivec2(x, y);
			ivec2 cell = wrap(c + o, period);
			vec2 point = vec2(o) + 0.5 + (hash2(cell) - 0.5) * jitter;
			float d = length(point - f);

			if (d < f1) {
				f2 = f1;
				f1 = d;
				id = hash1(cell + ivec2(7, 13));
			} else if (d < f2) {
				f2 = d;
			}
		}
	}

	return vec3(f1, f2, id);
}

vec3 grad3(ivec3 c) {
	return normalize(hash3(c) * 2.0 - 1.0 + vec3(0.0001));
}

float gnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = p - i;
	ivec3 c = ivec3(i);
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float n000 = dot(grad3(c), f);
	float n100 = dot(grad3(c + ivec3(1, 0, 0)), f - vec3(1, 0, 0));
	float n010 = dot(grad3(c + ivec3(0, 1, 0)), f - vec3(0, 1, 0));
	float n110 = dot(grad3(c + ivec3(1, 1, 0)), f - vec3(1, 1, 0));
	float n001 = dot(grad3(c + ivec3(0, 0, 1)), f - vec3(0, 0, 1));
	float n101 = dot(grad3(c + ivec3(1, 0, 1)), f - vec3(1, 0, 1));
	float n011 = dot(grad3(c + ivec3(0, 1, 1)), f - vec3(0, 1, 1));
	float n111 = dot(grad3(c + ivec3(1, 1, 1)), f - vec3(1, 1, 1));
	return mix(
		mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
		mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y),
		u.z
	) * 1.6;
}

float fbm3(vec3 p, int octaves) {
	float sum = 0.0;
	float amplitude = 0.5;
	float norm = 0.0;

	for (int i = 0; i < octaves; i++) {
		sum += gnoise3(p + vec3(float(i) * 17.3)) * amplitude;
		norm += amplitude;
		p *= 2.03;
		amplitude *= 0.5;
	}

	return sum / norm;
}

vec3 voronoi3(vec3 p) {
	ivec3 c = ivec3(floor(p));
	vec3 f = p - vec3(c);
	float f1 = 8.0;
	float f2 = 8.0;
	float id = 0.0;

	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				ivec3 o = ivec3(x, y, z);
				vec3 point = vec3(o) + hash3(c + o);
				float d = length(point - f);

				if (d < f1) {
					f2 = f1;
					f1 = d;
					id = hash1(c + o + ivec3(11, 3, 5));
				} else if (d < f2) {
					f2 = d;
				}
			}
		}
	}

	return vec3(f1, f2, id);
}

// the distance from p to the segment a b, and where along it (0 to 1) the nearest point is
vec2 segment(vec2 p, vec2 a, vec2 b) {
	vec2 ab = b - a;
	float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);
	return vec2(length(p - a - ab * t), t);
}

vec2 bezier(vec2 a, vec2 b, vec2 c, float t) {
	return mix(mix(a, b, t), mix(b, c, t), t);
}

// how much of a pixel a shape covers, from its signed distance in pixels (positive inside)
float coverage(float distance_in_pixels) {
	return clamp(distance_in_pixels + 0.5, 0.0, 1.0);
}

vec3 vary(vec3 color, float amount, float r) {
	return color * (1.0 + (r * 2.0 - 1.0) * amount);
}

// what the cutout kinds paint on, premultiplied, so the edges of a shape keep its own color and not what is under it
struct Canvas {
	vec3 color;
	float alpha;
	float height;
	float roughness;
	float transmission;
};

Canvas canvas() {
	Canvas c;
	c.color = vec3(0.0);
	c.alpha = 0.0;
	c.height = 0.0;
	c.roughness = 0.0;
	c.transmission = 0.0;
	return c;
}

void paint(inout Canvas c, vec3 color, float cover, float height, float roughness, float transmission) {
	c.color = color * cover + c.color * (1.0 - cover);
	c.alpha = cover + c.alpha * (1.0 - cover);
	c.height = height * cover + c.height * (1.0 - cover);
	c.roughness = roughness * cover + c.roughness * (1.0 - cover);
	c.transmission = transmission * cover + c.transmission * (1.0 - cover);
}

// the height is of what is painted, not a slope down to the clear texels around it (the normal map leaves those out)
Surface finish(Canvas c) {
	float a = max(c.alpha, 1e-4);
	return surface(c.color / a, c.alpha, c.height / a, c.roughness / a, c.transmission / a);
}
]]
-- the tangent space normal of a kind, from its height unless it has its own (CUSTOM_NORMAL)
local NORMAL = [[
#ifndef CUSTOM_NORMAL
vec3 surface_normal(vec2 uv) {
	vec2 e = 1.0 / SIZE;
	Surface s = surface_at(uv);
	Surface sx = surface_at(uv + vec2(e.x, 0.0));
	Surface sy = surface_at(uv + vec2(0.0, e.y));
	// a cutout's edge is where the leaf ends, not a slope, so a clear neighbour is as high as the texel
	float hx = sx.alpha < 0.5 ? s.height : sx.height;
	float hy = sy.alpha < 0.5 ? s.height : sy.height;
	return normalize(vec3((s.height - hx) / e.x * BUMP, (s.height - hy) / e.y * BUMP, 1.0));
}
#endif
]]
local MAIN = {
	albedo = [[
vec4 shade(vec2 uv, vec3 dir) {
	Surface s = surface_at(uv);
	return vec4(max(s.albedo, vec3(0.0)), clamp(s.alpha, 0.0, 1.0));
}
]],
	normal = [[
vec4 shade(vec2 uv, vec3 dir) {
	return vec4(surface_normal(uv) * 0.5 + 0.5, 1.0);
}
]],
	roughness = [[
vec4 shade(vec2 uv, vec3 dir) {
	Surface s = surface_at(uv);
	// the clear texels of a cutout have the kind's roughness, so the mips do not take the edges to 0
	return vec4(clamp(s.alpha > 0.0 ? s.roughness : ROUGHNESS, 0.0, 1.0), 0.0, 0.0, 1.0);
}
]],
	transmission = [[
vec4 shade(vec2 uv, vec3 dir) {
	return vec4(vec3(clamp(surface_at(uv).transmission, 0.0, 1.0)), 1.0);
}
]],
}
-- a kind: glsl (defines surface_at), defaults (every key the kind reads, a config can only set these), cutout (the
-- albedo is alpha tested), wrap (the sampler repeats)
function textures.AddKind(name, kind)
	assert(kind.glsl and kind.defaults, name .. " needs glsl and defaults")
	textures.kinds[name] = kind
end

local function srgb_to_linear(c)
	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

local BUILTIN_KEYS = {seed = true, width = true, height = true}

local function build_constants(kind_name, kind, config)
	local lines = {
		("const uint SEED = %uu;"):format(config.seed % 2147483648),
		("const vec2 SIZE = vec2(%d.0, %d.0);"):format(config.width, config.height),
	}
	local keys = {}

	for key in pairs(config) do
		if not BUILTIN_KEYS[key] then
			if kind.defaults[key] == nil then
				error(("unknown %s texture key %s"):format(kind_name, tostring(key)), 4)
			end

			keys[#keys + 1] = key
		end
	end

	table.sort(keys)

	for _, key in ipairs(keys) do
		local value = config[key]
		local name = key:upper()

		if key == "style" then
			lines[#lines + 1] = ("#define STYLE %d"):format(value)
		elseif type(value) == "table" then
			assert(#value == 3, kind_name .. "." .. key .. " is a color of 3 numbers")
			local r, g, b = value[1], value[2], value[3]

			if key:starts_with("color") then
				r, g, b = srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)
			end

			lines[#lines + 1] = ("const vec3 %s = vec3(%.6f, %.6f, %.6f);"):format(name, r, g, b)
		elseif type(value) == "boolean" then
			lines[#lines + 1] = ("const bool %s = %s;"):format(name, tostring(value))
		else
			lines[#lines + 1] = ("const float %s = %.6f;"):format(name, value)
		end
	end

	return table.concat(lines, "\n") .. "\n"
end

-- a config with every key, the kind's defaults under the given ones
function textures.Resolve(kind_name, config)
	local kind = assert(textures.kinds[kind_name], "unknown foliage texture kind " .. tostring(kind_name))
	local out = {seed = 1, width = kind.width or 512, height = kind.height or 512}

	for key, value in pairs(kind.defaults) do
		out[key] = value
	end

	for key, value in pairs(config) do
		out[key] = value
	end

	return out, kind
end

-- the shader of a kind without its main, with surface_at and surface_normal, for drawing it some other way (previews)
function textures.GetSource(kind_name, config)
	local resolved, kind = textures.Resolve(kind_name, config)
	return build_constants(kind_name, kind, resolved) .. COMMON .. kind.glsl .. NORMAL, resolved
end

do
	local REPEAT = {
		min_filter = "linear",
		mag_filter = "linear",
		mipmap_mode = "linear",
		wrap_s = "repeat",
		wrap_t = "repeat",
		anisotropy = 8,
	}
	local CLAMP = {
		min_filter = "linear",
		mag_filter = "linear",
		mipmap_mode = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
		anisotropy = 8,
	}

	-- draws one channel (albedo, normal, roughness or transmission) of a kind
	function textures.Build(kind_name, channel, config)
		local resolved, kind = textures.Resolve(kind_name, config)
		local main = assert(MAIN[channel], "unknown foliage texture channel " .. tostring(channel))
		local glsl = build_constants(kind_name, kind, resolved) .. COMMON .. kind.glsl .. NORMAL .. main
		local width, height = resolved.width, resolved.height
		local srgb = channel == "albedo"

		if kind.cutout and channel == "albedo" then
			local canvas = Texture.New{
				width = width,
				height = height,
				format = "r8g8b8a8_srgb",
				mip_map_levels = 1,
				sampler = CLAMP,
			}
			canvas:Shade(glsl)
			local downloaded = canvas:Download()
			canvas:Remove()
			local pixels = ffi.new("uint8_t[?]", width * height * 4)
			ffi.copy(pixels, downloaded.pixels, width * height * 4)
			return cutout_texture.New(
				pixels,
				width,
				height,
				{tile_width = width / (resolved.atlas or 1), sampler = kind.wrap and REPEAT or CLAMP}
			)
		end

		local texture = Texture.New{
			width = width,
			height = height,
			format = srgb and "r8g8b8a8_srgb" or channel == "roughness" and "r8_unorm" or "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			sampler = kind.wrap and REPEAT or CLAMP,
		}
		texture:Shade(glsl)
		return texture
	end
end

-- a virtual texture asset of one channel of a kind
function textures.Register(path, kind_name, channel, config)
	textures.Resolve(kind_name, config)
	assets.RegisterVirtualTexture(path, function(_, options)
		local request = options and options.config
		local merged = {}

		for key, value in pairs(config) do
			merged[key] = value
		end

		if request then
			for key, value in pairs(request) do
				-- assets.GetTexture adds srgb, the format of a channel is its own
				if key ~= "srgb" then merged[key] = value end
			end
		end

		return textures.Build(kind_name, channel, merged)
	end)
	return path
end


textures.AddKind(
	"bark",
	{
		wrap = true,
		defaults = {
			-- 0 furrowed ridges (oak, willow), 1 flaking plates (pine), 2 birch, 3 palm rings, 4 smooth
			style = 0,
			plates_u = 9,
			plates_v = 2,
			warp = 0.6,
			crack_width = 0.22,
			rings = 14,
			color_crack = {0.1, 0.08, 0.06},
			color_bark = {0.34, 0.29, 0.24},
			color_ridge = {0.5, 0.46, 0.41},
			color_lichen = {0.55, 0.6, 0.4},
			lichen = 0.25,
			roughness = 0.85,
			bump = 0.02,
		},
		glsl = [[
Surface surface_at(vec2 uv) {
	float detail = fbm(uv * 16.0, ivec2(16), 4);
	vec3 albedo;
	float height;
	float roughness = ROUGHNESS;

#if STYLE == 0 || STYLE == 1
	ivec2 period = ivec2(int(PLATES_U), int(PLATES_V));
	vec2 q = uv * vec2(period);
	q.x += fbm(uv * vec2(3.0, 2.0), ivec2(3, 2), 4) * WARP;
	q.y += fbm(uv * vec2(2.0, 3.0) + 5.0, ivec2(2, 3), 3) * WARP * 0.3;
#if STYLE == 1
	// ragged plate outlines
	q += vec2(fbm(uv * vec2(14.0, 10.0), ivec2(14, 10), 3), fbm(uv * vec2(10.0, 14.0) + 3.0, ivec2(10, 14), 3)) * 0.22;
#endif
	vec3 cells = voronoi(q, period, 0.95);
	float edge = cells.y - cells.x;
	float plate = smoothstep(0.0, CRACK_WIDTH, edge);
	// rounded ridges, highest in the middle of a plate
	float ridge = sqrt(smoothstep(0.0, CRACK_WIDTH * 3.5, edge));
#if STYLE == 1
	// plates in layers: the grey outer layer has flaked off in patches and shows the red one under it. the fissures
	// between the plates are of all widths
	float fissure_width = CRACK_WIDTH * (0.35 + 0.9 * (fbm(uv * vec2(9.0, 5.0), ivec2(9, 5), 3) * 0.5 + 0.5));
	plate = smoothstep(0.0, fissure_width, edge);
	float flaked = smoothstep(0.05, 0.25, fbm(uv * vec2(12.0, 16.0) + cells.z * 13.0, ivec2(12, 16), 4) + (cells.z - 0.5) * 0.5);
	float layers = gnoise(vec2(uv.x * 40.0, uv.y * 30.0), ivec2(40, 30)) * 0.5 + 0.5;
	height = plate * (0.4 + 0.35 * ridge - 0.12 * flaked + 0.08 * layers) + detail * 0.05;
	albedo = mix(COLOR_RIDGE * (0.75 + 0.2 * layers + 0.3 * cells.z) * (0.9 + 0.2 * detail), COLOR_BARK * (0.8 + 0.4 * cells.z), flaked);
	albedo = mix(COLOR_CRACK, albedo, plate);
#else
	// streaks along the ridges and cross cracks that break them up
	float streaks = gnoise(vec2(uv.x * 70.0, uv.y * 6.0), ivec2(70, 6)) * 0.5 + 0.5;
	float cross_crack = smoothstep(0.75, 0.95, abs(gnoise(vec2(uv.x * 30.0, uv.y * 9.0), ivec2(30, 9))));
	float tone = cells.z * 0.5 + streaks * 0.5;
	height = plate * (0.35 + 0.65 * ridge) * (0.8 + 0.2 * cells.z) - cross_crack * 0.3 * plate + streaks * 0.08 + detail * 0.06;
	albedo = mix(COLOR_BARK, COLOR_RIDGE, ridge * tone);
	albedo = mix(COLOR_CRACK, albedo, smoothstep(0.0, CRACK_WIDTH * 2.0, edge) * (1.0 - cross_crack * 0.7));
#endif
	roughness = mix(1.0, ROUGHNESS, plate);
#elif STYLE == 2
	// white bark with dashes of dark lenticels and black fissured patches, more of them low on the trunk
	ivec2 grid = ivec2(4, 26);
	vec2 q = uv * vec2(grid);
	q.y += gnoise(uv * vec2(3.0, 2.0), ivec2(3, 2)) * 0.6;
	ivec2 cell = ivec2(floor(q));
	vec2 local = fract(q) - 0.5;
	ivec2 wrapped = wrap(cell, grid);
	float r1 = hash1(wrapped);
	float r2 = hash1(wrapped + ivec2(31, 7));
	float r3 = hash1(wrapped + ivec2(5, 17));
	local.x -= (r3 - 0.5) * 0.5;
	local.y -= (r2 - 0.5) * 0.4;
	float dash_length = mix(0.06, 0.4, r1 * r1);
	float dash = (1.0 - smoothstep(dash_length - 0.04, dash_length, abs(local.x))) * (1.0 - smoothstep(0.03, 0.09, abs(local.y) + local.x * local.x * 0.15));
	dash *= step(0.3, r2);
	float patch_noise = fbm(uv * vec2(3.0, 6.0) + 2.0, ivec2(3, 6), 5) + 0.3 * gnoise(uv * vec2(24.0, 10.0), ivec2(24, 10));
	float fissure = smoothstep(0.22, 0.32, patch_noise);
	float peel = fbm(vec2(uv.x * 2.0, uv.y * 24.0), ivec2(2, 24), 3) * 0.5 + 0.5;
	albedo = mix(COLOR_BARK, COLOR_RIDGE, smoothstep(0.55, 0.8, peel) * 0.7) * (0.93 + 0.07 * detail);
	albedo = mix(albedo, COLOR_CRACK, max(dash * 0.9, fissure * (0.85 + 0.15 * detail)));
	height = 0.5 - dash * 0.15 - fissure * (0.25 + 0.25 * (detail * 0.5 + 0.5)) + detail * 0.03;
	roughness = mix(ROUGHNESS, 0.95, max(dash, fissure));
#elif STYLE == 3
	// rings where the old fronds were, each its own: a little tilted, scalloped by the scars of the leaf bases, wider or
	// narrower, and fibres along the trunk
	float base = uv.y * RINGS + fbm(uv * vec2(4.0, 1.0), ivec2(4, 1), 3) * 0.15;
	int ring_index = int(floor(base));
	ivec2 ring_cell = wrap(ivec2(ring_index, 0), ivec2(int(RINGS), 1));
	float r1 = hash1(ring_cell);
	float r2 = hash1(ring_cell + ivec2(0, 7));
	float scallop = pow(abs(sin((uv.x * 5.0 + r1) * PI)), 0.7) * 0.25 * r2;
	float tilt = sin((uv.x + r2) * TAU) * 0.08 * (r1 - 0.5);
	float ring = fract(base + scallop + tilt);
	float width = mix(0.1, 0.25, r1);
	float groove = 1.0 - smoothstep(0.0, width, ring) * smoothstep(1.0, 1.0 - width * 0.6, ring);
	float scar = smoothstep(0.5, 0.95, ring) * (0.5 + 0.5 * r2);
	float fibres = gnoise(vec2(uv.x * 64.0, uv.y * 6.0), ivec2(64, 6)) * 0.5 + 0.5;
	height = (1.0 - groove) * (0.6 + 0.25 * fibres) - scar * 0.15 + detail * 0.05;
	albedo = mix(COLOR_CRACK, mix(COLOR_BARK, COLOR_RIDGE, fibres * 0.6 + scar * 0.3), 1.0 - groove * 0.85);
	roughness = mix(ROUGHNESS, 1.0, groove);
#else
	// smooth with mottling and a few fine rings
	float mottle = fbm(uv * vec2(4.0, 6.0), ivec2(4, 6), 5) * 0.5 + 0.5;
	float line = smoothstep(0.92, 1.0, abs(gnoise(vec2(uv.x * 3.0, uv.y * 30.0), ivec2(3, 30))));
	albedo = mix(COLOR_BARK, COLOR_RIDGE, mottle) * (0.95 + 0.05 * detail);
	albedo = mix(albedo, COLOR_CRACK, line * 0.5);
	height = 0.5 + detail * 0.05 - line * 0.1;
	roughness = ROUGHNESS + (mottle - 0.5) * 0.15 + line * 0.1;
#endif

	float lichen = smoothstep(1.0 - LICHEN, 1.0 - LICHEN + 0.2, fbm(uv * vec2(4.0, 3.0) + 9.0, ivec2(4, 3), 5) * 0.5 + 0.5);
	lichen *= smoothstep(0.2, 0.5, height);
	albedo = mix(albedo, COLOR_LICHEN * (0.8 + 0.4 * (detail * 0.5 + 0.5)), lichen);
	height += lichen * 0.08;
	return surface(albedo, 1.0, height, mix(roughness, 0.95, lichen), 0.0);
}
]],
	}
)
-- a twig of leaves on a card, or an atlas of a few in a row (atlas tiles side by side, each square). the twig goes up
-- from the bottom middle (v 0), the leaves are alternate along it and one is at its tip. the leaf is a width profile
-- along its midrib, pow(x, shape_base) * pow(1 - x, shape_tip), cut by lobes and teeth
textures.AddKind(
	"leaves",
	{
		cutout = true,
		width = 1024,
		height = 256,
		defaults = {
			atlas = 4,
			leaf_count = 7,
			leaf_length = 0.42,
			leaf_width = 0.42,
			leaf_angle = 0.8,
			leaf_angle_variation = 0.2,
			shape_base = 0.6,
			shape_tip = 0.9,
			lobes = 0,
			lobe_depth = 0,
			teeth = 0,
			serration = 0,
			curl = 0.1,
			petiole = 0.04,
			twig_length = 0.8,
			twig_width = 0.012,
			twig_bend = 0.15,
			-- 1 a single leaf filling the tile, for litter and lily pads
			single = 0,
			veins = 7,
			vein_slope = 1.2,
			vein_width = 0.03,
			color_dark = {0.12, 0.24, 0.05},
			color_light = {0.3, 0.46, 0.1},
			color_vein = {0.4, 0.5, 0.2},
			color_twig = {0.28, 0.2, 0.13},
			color_variation = {0.48, 0.48, 0.14},
			variation = 0.1,
			brightness_variation = 0.15,
			-- berries hanging among the leaves
			berries = 0,
			berry_size = 0.035,
			color_berry = {0.7, 0.05, 0.08},
			roughness = 0.55,
			bump = 0.006,
		},
		glsl = [[
float leaf_profile(float x) {
	float norm = pow(SHAPE_BASE / (SHAPE_BASE + SHAPE_TIP), SHAPE_BASE) * pow(SHAPE_TIP / (SHAPE_BASE + SHAPE_TIP), SHAPE_TIP);
	float w = LEAF_WIDTH * 0.5 * pow(clamp(x, 0.0, 1.0), SHAPE_BASE) * pow(clamp(1.0 - x, 0.0, 1.0), SHAPE_TIP) / norm;

	if (LOBES > 0.0) {
		// narrow sinuses between broad round lobes
		float sinus = pow(0.5 + 0.5 * cos((x - 0.1) * LOBES * TAU), 6.0);
		w *= 1.0 - LOBE_DEPTH * sinus * smoothstep(0.1, 0.3, x) * smoothstep(1.0, 0.75, x);
	}

	if (TEETH > 0.0) w *= 1.0 - SERRATION * fract(x * TEETH);

	return w;
}

// the leaf in its own frame: x along the midrib from the base (0) to the tip (1), y across, both in leaf lengths
void draw_leaf(inout Canvas canvas, vec2 p, vec2 base, vec2 dir, float len, float side, int id, float pixel) {
	vec2 d = p - base;
	vec2 across = vec2(-dir.y, dir.x);
	float x = dot(d, dir) / len;
	float y = dot(d, across) / len;
	y -= CURL * side * x * x;

	if (x < -0.05 || x > 1.05) return;

	float w = leaf_profile(x);
	float inside = coverage((w - abs(y)) * len / pixel) * step(0.0, x) * step(x, 1.0);

	if (inside <= 0.0) return;

	float r = rand(id, 3);
	float r2 = rand(id, 4);
	float mottle = fbm(vec2(x, y) * 7.0 + vec2(float(id) * 3.7), 4) * 0.5 + 0.5;
	vec3 c = mix(COLOR_DARK, COLOR_LIGHT, mottle * 0.6 + x * 0.2);
	c = mix(c, COLOR_VARIATION, step(r2, VARIATION) * (0.5 + 0.5 * rand(id, 5)) * (0.6 + 0.4 * mottle));
	c = vary(c, BRIGHTNESS_VARIATION, r);
	float rel = abs(y) / max(w, 1e-4);
	float vein_w = VEIN_WIDTH * (1.0 - x * 0.75);
	float midrib = 1.0 - smoothstep(vein_w * 0.4, vein_w, abs(y));
	// the side veins leave the midrib towards the tip
	float vein_coord = (x - abs(y) * VEIN_SLOPE) * VEINS;
	float vein_dist = min(fract(vein_coord), 1.0 - fract(vein_coord));
	float vein = (1.0 - smoothstep(0.0, 0.07, vein_dist)) * step(0.0, vein_coord);
	vein *= smoothstep(1.0, 0.7, rel) * smoothstep(1.0, 0.85, x);
	c = mix(c, COLOR_VEIN, max(midrib * 0.75, vein * 0.3));
	// a little darker at the very margin
	c *= mix(1.0, 0.8, smoothstep(0.85, 1.0, rel));
	float h = 0.6 - rel * rel * 0.3 - midrib * 0.25 - vein * 0.08 + mottle * 0.03;
	// the blade is waxy, the veins less so
	paint(canvas, c, inside, h, ROUGHNESS + max(midrib, vein) * 0.2 + (1.0 - mottle) * 0.05, 1.0 - midrib * 0.5 - vein * 0.2);
}

void draw_line(inout Canvas canvas, vec2 p, vec2 a, vec2 b, float width_a, float width_b, vec3 color, float pixel) {
	vec2 st = segment(p, a, b);
	float width = mix(width_a, width_b, st.y);
	float cover = coverage((width - st.x) / pixel);

	if (cover > 0.0) paint(canvas, color, cover, 0.7 - st.x / max(width, 1e-4) * 0.3, 0.8, 0.0);
}

Surface surface_at(vec2 uv) {
	float tiles = ATLAS;
	int tile = int(floor(uv.x * tiles));
	vec2 p = vec2(fract(uv.x * tiles), uv.y);
	float pixel = 1.0 / SIZE.y;
	int stream = tile * 101;
	Canvas canvas = canvas();

	if (SINGLE > 0.5) {
		float angle = (rand(stream, 1) - 0.5) * 0.5;
		vec2 dir = vec2(sin(angle), cos(angle));
		vec2 base = vec2(0.5, 0.5) - dir * 0.42;
		draw_line(canvas, p, base - dir * 0.06, base + dir * 0.1, TWIG_WIDTH, TWIG_WIDTH * 0.7, COLOR_TWIG, pixel);
		draw_leaf(canvas, p, base, dir, 0.86, 1.0, stream, pixel);
		return finish(canvas);
	}

	vec2 a = vec2(0.5, 0.0);
	vec2 c = vec2(0.5 + (rand(stream, 2) - 0.5) * TWIG_BEND * 2.0, TWIG_LENGTH);
	vec2 b = mix(a, c, 0.5) + vec2((rand(stream, 1) - 0.5) * TWIG_BEND, 0.0);
	vec3 twig_color = COLOR_TWIG * (0.85 + 0.15 * gnoise(p * 60.0));

	for (int i = 0; i < 8; i++) {
		float t0 = float(i) / 8.0;
		float t1 = float(i + 1) / 8.0;
		draw_line(canvas, p, bezier(a, b, c, t0), bezier(a, b, c, t1), TWIG_WIDTH * (1.0 - t0 * 0.6), TWIG_WIDTH * (1.0 - t1 * 0.6), twig_color, pixel);
	}

	int count = int(LEAF_COUNT);

	for (int i = 0; i < count; i++) {
		int id = stream + i * 7 + 1;
		bool terminal = i == count - 1;
		float t = terminal ? 1.0 : mix(0.22, 0.95, float(i) / max(float(count - 1), 1.0));
		vec2 attach = bezier(a, b, c, t);
		vec2 tangent = normalize(bezier(a, b, c, min(t + 0.01, 1.0)) - bezier(a, b, c, max(t - 0.01, 0.0)));
		float side = (i % 2 == 0) ? 1.0 : -1.0;
		float angle = terminal ? (rand(id, 0) - 0.5) * 0.3 : side * (LEAF_ANGLE + (rand(id, 0) - 0.5) * 2.0 * LEAF_ANGLE_VARIATION);
		vec2 dir = vec2(tangent.x * cos(angle) - tangent.y * sin(angle), tangent.x * sin(angle) + tangent.y * cos(angle));
		float len = LEAF_LENGTH * mix(0.75, 1.0, t) * mix(0.85, 1.1, rand(id, 1));
		vec2 base = attach + dir * PETIOLE;
		draw_line(canvas, p, attach, base, TWIG_WIDTH * 0.5, TWIG_WIDTH * 0.35, mix(COLOR_TWIG, COLOR_VEIN, 0.5), pixel);
		draw_leaf(canvas, p, base, dir, len, side, id, pixel);
	}

	for (int i = 0; i < int(BERRIES); i++) {
		int id = stream + 500 + i * 3;
		float t = mix(0.15, 0.85, rand(id, 0));
		vec2 center = bezier(a, b, c, t) + (vec2(rand(id, 1), rand(id, 2)) - 0.5) * vec2(0.16, 0.08);
		float radius = BERRY_SIZE * mix(0.8, 1.2, rand(id, 3));
		float dist = length(p - center) / radius;
		float cover = coverage((1.0 - dist) * radius / pixel);

		if (cover > 0.0) {
			// a highlight up and to the left
			// glossy, the highlight is the lighting's
			vec3 berry = COLOR_BERRY * mix(1.0, 0.7, dist * dist);
			paint(canvas, berry, cover, 1.0 - dist * dist * 0.6, 0.25, 0.1);
		}
	}

	return finish(canvas);
}
]],
	}
)
-- a spray of needles along a twig and two side twigs, the needles pointing forward on both sides
textures.AddKind(
	"needles",
	{
		cutout = true,
		width = 512,
		height = 256,
		defaults = {
			atlas = 2,
			needle_count = 36,
			needle_length = 0.16,
			needle_width = 0.005,
			needle_angle = 0.8,
			twig_width = 0.009,
			color_dark = {0.06, 0.15, 0.07},
			color_light = {0.18, 0.3, 0.13},
			color_twig = {0.32, 0.22, 0.14},
			roughness = 0.6,
			bump = 0.004,
		},
		glsl = [[
void draw_branch(inout Canvas canvas, vec2 p, vec2 a, vec2 b, vec2 c, float scale, int stream, float pixel) {
	for (int i = 0; i < 6; i++) {
		vec2 st = segment(p, bezier(a, b, c, float(i) / 6.0), bezier(a, b, c, float(i + 1) / 6.0));
		float twig = coverage((TWIG_WIDTH * scale - st.x) / pixel);

		if (twig > 0.0) paint(canvas, COLOR_TWIG, twig, 0.5, 0.85, 0.0);
	}

	int count = int(NEEDLE_COUNT * scale);

	for (int i = 0; i < count; i++) {
		float t = (float(i) + rand(stream, i * 3)) / float(count);
		vec2 attach = bezier(a, b, c, t);
		vec2 tangent = normalize(bezier(a, b, c, min(t + 0.02, 1.0)) - bezier(a, b, c, max(t - 0.02, 0.0)));

		for (int s = 0; s < 2; s++) {
			float side = s == 0 ? 1.0 : -1.0;
			float angle = side * NEEDLE_ANGLE * mix(0.8, 1.2, rand(stream, i * 3 + s + 1));
			vec2 dir = vec2(tangent.x * cos(angle) - tangent.y * sin(angle), tangent.x * sin(angle) + tangent.y * cos(angle));
			float len = NEEDLE_LENGTH * mix(0.85, 1.1, rand(stream, i * 5 + s)) * mix(1.0, 0.55, t * t);
			vec2 st = segment(p, attach, attach + dir * len);
			float width = NEEDLE_WIDTH * (1.0 - st.y * 0.6);
			float needle = coverage((width - st.x) / pixel);

			if (needle > 0.0) {
				vec3 color = mix(COLOR_DARK, COLOR_LIGHT, st.y * 0.6 + rand(stream, i * 7 + s) * 0.4);
				paint(canvas, color, needle, 0.7 - st.x / width * 0.3, ROUGHNESS + st.y * 0.1, 0.7);
			}
		}
	}
}

Surface surface_at(vec2 uv) {
	float tiles = ATLAS;
	int tile = int(floor(uv.x * tiles));
	vec2 p = vec2(fract(uv.x * tiles), uv.y);
	float pixel = 1.0 / SIZE.y;
	int stream = tile * 211;
	Canvas canvas = canvas();
	vec2 a = vec2(0.5, 0.0);
	vec2 c = vec2(0.5 + (rand(stream, 1) - 0.5) * 0.2, 0.95);
	vec2 b = vec2(0.5 + (rand(stream, 2) - 0.5) * 0.15, 0.5);

	for (int k = 0; k < 2; k++) {
		float t = mix(0.2, 0.55, rand(stream, 10 + k));
		vec2 start = bezier(a, b, c, t);
		float side = k == 0 ? 1.0 : -1.0;
		vec2 end = start + vec2(side * mix(0.22, 0.32, rand(stream, 12 + k)), mix(0.25, 0.4, rand(stream, 14 + k)));
		draw_branch(canvas, p, start, mix(start, end, 0.5) + vec2(0.0, 0.03), end, 0.7, stream + 50 + k * 50, pixel);
	}

	draw_branch(canvas, p, a, b, c, 1.0, stream + 7, pixel);
	return finish(canvas);
}
]],
	}
)
-- a frond as seen from above: a rachis up the middle and leaflets on both sides angled towards the tip, for palms
-- and ferns. the texture is frond_width wide for a length of 1, which is the shape of the strip it goes on
textures.AddKind(
	"frond",
	{
		cutout = true,
		width = 512,
		height = 1024,
		defaults = {
			frond_width = 0.5,
			leaflets = 55,
			leaflet_length = 0.24,
			leaflet_width = 0.011,
			leaflet_slope = 0.9,
			droop = 0.6,
			lobes = 0,
			lobe_depth = 0,
			base_gap = 0.06,
			rachis_width = 0.008,
			color_dark = {0.1, 0.22, 0.06},
			color_light = {0.3, 0.43, 0.12},
			color_rachis = {0.45, 0.45, 0.22},
			color_tip = {0.55, 0.45, 0.2},
			tip_dry = 0.25,
			roughness = 0.5,
			bump = 0.004,
		},
		glsl = [[
float leaflet_length(float v) {
	return LEAFLET_LENGTH * smoothstep(BASE_GAP, BASE_GAP + 0.2, v) * pow(clamp(1.0 - v, 0.0, 1.0), 0.5) * 1.15;
}

Surface surface_at(vec2 uv) {
	// in lengths of the frond
	vec2 p = vec2((uv.x - 0.5) * FROND_WIDTH, uv.y);
	float pixel = 1.0 / SIZE.y;
	float side = p.x < 0.0 ? 0.0 : 1.0;
	float x = abs(p.x);
	Canvas canvas = canvas();
	float rachis = coverage((RACHIS_WIDTH * (1.0 - p.y * 0.7) - x) / pixel) * step(p.y, 0.995);

	if (rachis > 0.0) paint(canvas, COLOR_RACHIS, rachis, 0.8, ROUGHNESS + 0.2, 0.0);

	float spacing = 1.0 / LEAFLETS;
	// the leaflet through this point started on the rachis at v_start
	float v_start = p.y - x * LEAFLET_SLOPE - DROOP * x * x;
	float nearest = floor(v_start / spacing + 0.5);

	for (int k = -2; k <= 2; k++) {
		float index = nearest + float(k);
		int id = int(index) * 2 + int(side);
		float v0 = index * spacing + (rand(id, 1) - 0.5) * spacing * 0.5;

		if (v0 < 0.0 || v0 > 1.0) continue;

		float len = leaflet_length(v0) * mix(0.85, 1.1, rand(id, 2));

		if (len <= 0.0) continue;

		float t = x / len;
		float line = v0 + x * LEAFLET_SLOPE + DROOP * x * x;
		float across = abs(p.y - line) / sqrt(1.0 + pow(LEAFLET_SLOPE + 2.0 * DROOP * x, 2.0));
		float width = LEAFLET_WIDTH * mix(0.5, 1.0, smoothstep(0.0, 0.15, t)) * pow(max(1.0 - t, 0.0), 0.6);

		if (LOBES > 0.0) width *= 1.0 - LOBE_DEPTH * pow(0.5 + 0.5 * cos(t * LOBES * TAU), 3.0) * smoothstep(0.05, 0.2, t);

		float inside = coverage((width - across) / pixel) * step(t, 1.0);

		if (inside > 0.0) {
			float mottle = fbm(vec2(t * 6.0, float(id) * 0.37), 3) * 0.5 + 0.5;
			vec3 c = mix(COLOR_DARK, COLOR_LIGHT, mottle * 0.6 + rand(id, 5) * 0.4);
			c = mix(c, COLOR_TIP, smoothstep(1.0 - TIP_DRY, 1.0, t) * rand(id, 6));
			float midrib = 1.0 - smoothstep(0.0, width * 0.25 + pixel, across);
			c = mix(c, COLOR_RACHIS, midrib * 0.4);
			// the dry tips are rougher
			paint(canvas, c, inside, 0.6 - across / max(width, 1e-4) * 0.3 - midrib * 0.15, ROUGHNESS + midrib * 0.1 + smoothstep(1.0 - TIP_DRY, 1.0, t) * 0.25, 1.0 - midrib * 0.4);
		}
	}

	return finish(canvas);
}
]],
	}
)
-- the color of grass blades, u across a blade and v from the root (0) to the tip (1). an atlas of a few in a row,
-- each a little different in color, a blade picks one by its u
textures.AddKind(
	"blade",
	{
		width = 256,
		height = 256,
		defaults = {
			atlas = 4,
			color_root = {0.32, 0.36, 0.18},
			color_mid = {0.22, 0.4, 0.09},
			color_tip = {0.36, 0.5, 0.14},
			color_dry = {0.66, 0.58, 0.32},
			dry = 0.2,
			dry_tips = 0.3,
			variation = 0.2,
			roughness = 0.5,
			bump = 0.01,
		},
		glsl = [[
Surface surface_at(vec2 uv) {
	float tiles = ATLAS;
	int tile = int(floor(uv.x * tiles));
	float u = fract(uv.x * tiles);
	float v = uv.y;
	float r = rand(tile, 1);
	vec3 color = mix(COLOR_ROOT, COLOR_MID, smoothstep(0.0, 0.35, v));
	color = mix(color, COLOR_TIP, smoothstep(0.4, 1.0, v));
	color = vary(color, VARIATION, r);
	// some of the variants are dry
	color = mix(color, COLOR_DRY, step(rand(tile, 2), DRY) * 0.8);
	// and the tips dry out
	color = mix(color, COLOR_DRY, smoothstep(1.0 - DRY_TIPS, 1.0, v) * rand(tile, 3));
	float streaks = gnoise(vec2(u * 12.0, v * 2.0) + float(tile) * 9.0);
	color *= 0.92 + 0.08 * streaks;
	float midrib = 1.0 - smoothstep(0.0, 0.12, abs(u - 0.5));
	color = mix(color, color * 1.25 + vec3(0.02), midrib * 0.4);
	// folded along the midrib
	float height = 1.0 - abs(u - 0.5) * 2.0;
	return surface(color, 1.0, height * 0.5 + streaks * 0.02, ROUGHNESS + streaks * 0.06 - midrib * 0.08 + smoothstep(1.0 - DRY_TIPS, 1.0, v) * 0.2, 0.85 - midrib * 0.2);
}
]],
	}
)
-- the heads of grasses, side on: a stem up the middle and spikelets on its upper part. style 0 a loose panicle of
-- hanging spikelets (oat grass), 1 a dense spike (timothy), 2 a feathery plume
textures.AddKind(
	"seed_head",
	{
		cutout = true,
		width = 512,
		height = 256,
		defaults = {
			style = 0,
			atlas = 2,
			spikelets = 20,
			spikelet_length = 0.1,
			spikelet_width = 0.022,
			head_start = 0.45,
			stem_width = 0.006,
			color_stem = {0.45, 0.5, 0.25},
			color_seed = {0.7, 0.62, 0.38},
			color_seed_tip = {0.85, 0.78, 0.55},
			roughness = 0.6,
			bump = 0.004,
		},
		glsl = [[
void draw_seed(inout Canvas canvas, vec2 p, vec2 base, vec2 dir, float len, float width, int id, float pixel) {
	vec2 st = segment(p, base, base + dir * len);
	float w = width * sin(PI * clamp(st.y, 0.0, 1.0)) * 0.5 + width * 0.15;
	float inside = coverage((w - st.x) / pixel);

	if (inside > 0.0) {
		vec3 c = mix(COLOR_SEED, COLOR_SEED_TIP, st.y * 0.7 + rand(id, 1) * 0.3);
		c *= 0.85 + 0.3 * (1.0 - st.x / max(w, 1e-4));
		paint(canvas, c, inside, 0.7 - st.x / max(w, 1e-4) * 0.3, ROUGHNESS, 0.5);
	}
}

void draw_stalk(inout Canvas canvas, vec2 p, vec2 a, vec2 b, float width, float pixel) {
	vec2 st = segment(p, a, b);
	float cover = coverage((width - st.x) / pixel);

	if (cover > 0.0) paint(canvas, COLOR_STEM, cover, 0.5, ROUGHNESS - 0.1, 0.3);
}

Surface surface_at(vec2 uv) {
	float tiles = ATLAS;
	int tile = int(floor(uv.x * tiles));
	vec2 p = vec2(fract(uv.x * tiles), uv.y);
	float pixel = 1.0 / SIZE.y;
	int stream = tile * 307;
	Canvas canvas = canvas();
	vec2 a = vec2(0.5, 0.0);
	vec2 c = vec2(0.5 + (rand(stream, 1) - 0.5) * 0.25, 0.97);
	vec2 b = vec2(0.5 + (rand(stream, 2) - 0.5) * 0.1, 0.5);

	for (int i = 0; i < 8; i++) {
		draw_stalk(canvas, p, bezier(a, b, c, float(i) / 8.0), bezier(a, b, c, float(i + 1) / 8.0), STEM_WIDTH, pixel);
	}

	int count = int(SPIKELETS);

	for (int i = 0; i < count; i++) {
		int id = stream + i * 5 + 3;
		float t = mix(HEAD_START, 1.0, (float(i) + rand(id, 2) * 0.5) / float(count));
		vec2 attach = bezier(a, b, c, t);
		vec2 tangent = normalize(bezier(a, b, c, min(t + 0.01, 1.0)) - bezier(a, b, c, max(t - 0.01, 0.0)));
		float side = (i % 2 == 0) ? 1.0 : -1.0;
		float head = (t - HEAD_START) / (1.0 - HEAD_START);
#if STYLE == 0
		// on thin stalks, hanging out and down
		float angle = side * mix(1.2, 0.5, head);
		vec2 out_dir = vec2(tangent.x * cos(angle) - tangent.y * sin(angle), tangent.x * sin(angle) + tangent.y * cos(angle));
		vec2 tip = attach + out_dir * mix(0.12, 0.03, head) * mix(0.7, 1.2, rand(id, 3));
		draw_stalk(canvas, p, attach, tip, STEM_WIDTH * 0.5, pixel);
		draw_seed(canvas, p, tip, normalize(out_dir * 0.4 + vec2(0.0, -1.0)), SPIKELET_LENGTH, SPIKELET_WIDTH, id, pixel);
#elif STYLE == 1
		float angle = side * 0.35;
		vec2 dir = vec2(tangent.x * cos(angle) - tangent.y * sin(angle), tangent.x * sin(angle) + tangent.y * cos(angle));
		draw_seed(canvas, p, attach - tangent * 0.01, dir, SPIKELET_LENGTH * mix(1.0, 0.6, head * head), SPIKELET_WIDTH, id, pixel);
		draw_seed(canvas, p, attach - tangent * 0.015, vec2(-dir.x, dir.y), SPIKELET_LENGTH * mix(0.9, 0.5, head * head), SPIKELET_WIDTH, id + 1, pixel);
#else
		// fine hairs fanning out
		for (int h = 0; h < 3; h++) {
			float angle = side * (0.3 + 0.35 * float(h)) * mix(0.7, 1.3, rand(id, 10 + h));
			vec2 dir = vec2(tangent.x * cos(angle) - tangent.y * sin(angle), tangent.x * sin(angle) + tangent.y * cos(angle));
			vec2 st = segment(p, attach, attach + dir * SPIKELET_LENGTH * mix(1.0, 0.5, head));
			float hair = coverage((SPIKELET_WIDTH * 0.25 * (1.0 - st.y) - st.x) / pixel) * 0.85;

			if (hair > 0.0) paint(canvas, mix(COLOR_SEED, COLOR_SEED_TIP, st.y), hair, 0.5, 0.9, 0.6);
		}
#endif
	}

	return finish(canvas);
}
]],
	}
)
-- a flower head from above, the petals around the middle and the disc in it. style 1 is a spike of florets side
-- on (lupins), from the bottom of the tile to the top
textures.AddKind(
	"flower",
	{
		cutout = true,
		width = 512,
		height = 256,
		defaults = {
			style = 0,
			atlas = 2,
			petals = 16,
			petal_layers = 1,
			petal_length = 0.46,
			petal_width = 0.13,
			petal_tip = 0.5,
			petal_notch = 0,
			petal_cup = 0.3,
			center = 0.13,
			color_petal = {0.97, 0.97, 0.95},
			color_petal_base = {0.95, 0.93, 0.8},
			color_center = {0.95, 0.68, 0.08},
			color_blotch = {0.08, 0.04, 0.04},
			blotch = 0,
			veins = 0.08,
			roughness = 0.5,
			bump = 0.004,
		},
		glsl = [[
Surface surface_at(vec2 uv) {
	float tiles = ATLAS;
	int tile = int(floor(uv.x * tiles));
	vec2 p = vec2(fract(uv.x * tiles), uv.y);
	float pixel = 1.0 / SIZE.y;
	int stream = tile * 401;
	Canvas canvas = canvas();
#if STYLE == 1
	// florets in a spike, smaller and paler towards the top
	vec2 a = vec2(0.5, 0.0);
	vec2 c = vec2(0.5 + (rand(stream, 1) - 0.5) * 0.1, 1.0);
	vec2 st = segment(p, a, c);
	float stem = coverage((0.008 - st.x) / pixel);

	if (stem > 0.0) paint(canvas, COLOR_CENTER, stem, 0.5, 0.6, 0.2);

	int count = int(PETALS);

	for (int i = 0; i < count; i++) {
		float t = (float(i) + 0.5) / float(count);
		float side = float(i % 3) - 1.0;
		float size = PETAL_LENGTH * mix(1.0, 0.35, t) * mix(0.85, 1.1, rand(stream, i));
		vec2 center = mix(a, c, mix(0.25, 0.97, t)) + vec2(side * size * 0.6, 0.0);
		vec2 q = (p - center) / vec2(size * 0.7, size * 0.5);
		float d = length(q);
		float inside = coverage((1.0 - d) * size * 0.5 / pixel);

		if (inside > 0.0) {
			vec3 col = mix(COLOR_PETAL_BASE, COLOR_PETAL, smoothstep(-0.6, 0.6, q.y));
			col = mix(col, COLOR_CENTER, smoothstep(0.6, 1.0, t) * 0.6);
			col *= 0.8 + 0.25 * (1.0 - d);
			paint(canvas, col, inside, 1.0 - d * 0.6, ROUGHNESS, 0.5);
		}
	}

	return finish(canvas);
#else
	vec2 d = (p - 0.5) * 2.0;
	float r = length(d);
	float theta = atan(d.y, d.x);

	for (int layer = 0; layer < int(PETAL_LAYERS); layer++) {
		float count = PETALS;
		float offset = rand(stream, layer) * TAU + float(layer) * PI / count;
		float layer_scale = 1.0 - float(layer) * 0.18;

		for (int k = -1; k <= 1; k++) {
			float index = floor((theta - offset) / TAU * count + 0.5) + float(k);
			int id = stream + layer * 97 + int(mod(index, count));
			float petal_angle = offset + index / count * TAU + (rand(id, 1) - 0.5) * 0.15;
			float delta = mod(theta - petal_angle + PI, TAU) - PI;
			float len = PETAL_LENGTH * 2.0 * layer_scale * mix(0.88, 1.06, rand(id, 2));
			// along and across the petal, in tile halves
			float x = r * cos(delta);
			float y = r * sin(delta);
			float t = (x - CENTER * 0.5) / max(len - CENTER * 0.5, 1e-4);
			float norm = pow(0.5 / (0.5 + PETAL_TIP), 0.5) * pow(PETAL_TIP / (0.5 + PETAL_TIP), PETAL_TIP);
			float width = PETAL_WIDTH * len * pow(clamp(t, 0.0, 1.0), 0.5) * pow(clamp(1.0 - t, 0.0, 1.0), PETAL_TIP) / norm + 0.008;

			if (PETAL_NOTCH > 0.0) width *= 1.0 - PETAL_NOTCH * smoothstep(0.8, 1.0, t) * (1.0 - smoothstep(0.0, 0.35, abs(y) / max(width, 1e-4)));

			float inside = coverage((width - abs(y)) * 0.5 / pixel) * step(0.0, t) * step(t, 1.0);

			if (inside > 0.0) {
				vec3 col = mix(COLOR_PETAL_BASE, COLOR_PETAL, smoothstep(0.0, 0.5, t));
				col = mix(col, COLOR_BLOTCH, BLOTCH * (1.0 - smoothstep(0.28, 0.42, r + gnoise(d * 6.0) * 0.04)));
				float vein = abs(fract(y / max(width, 1e-4) * 3.0) - 0.5) * 2.0;
				col *= 1.0 - VEINS * smoothstep(0.8, 1.0, vein);
				col = vary(col, 0.06, rand(id, 3));
				col *= mix(1.0, 0.82, smoothstep(0.6, 1.0, abs(y) / max(width, 1e-4)));
				paint(canvas, col * (1.0 - float(layer) * 0.08), inside, 0.4 + t * PETAL_CUP - abs(y) / max(width, 1e-4) * 0.1, ROUGHNESS + vein * 0.05, 0.8);
			}
		}
	}

	// the disc, florets in a fermat spiral
	float disc = coverage((CENTER - r) * 0.5 / pixel);

	if (disc > 0.0) {
		float n = r / CENTER;
		float spiral = sin(theta * 13.0 + n * 40.0) * sin(theta * 8.0 - n * 34.0);
		vec3 col = COLOR_CENTER * (0.75 + 0.25 * spiral) * mix(1.0, 0.7, n * n);
		// the florets of the disc are matte
		paint(canvas, col, disc, 0.9 - n * n * 0.3 + spiral * 0.05, 0.85, 0.1);
	}

	return finish(canvas);
#endif
}
]],
	}
)
-- the faces of a cube laid out in a 3x2 atlas, each texel is the direction through it, so a rock built on a cube
-- sphere (rocks.lua, same faces and layout) has a texture without seams. styles: 0 granite, 1 layered sandstone,
-- 2 basalt, 3 river stone. moss grows on top
textures.AddKind(
	"rock",
	{
		width = 1536,
		height = 1024,
		defaults = {
			style = 0,
			pad = 0.02,
			frequency = 2,
			color_base = {0.45, 0.44, 0.42},
			color_dark = {0.2, 0.2, 0.2},
			color_light = {0.7, 0.68, 0.64},
			color_warm = {0.5, 0.42, 0.34},
			color_lichen = {0.66, 0.64, 0.42},
			color_moss = {0.2, 0.3, 0.08},
			speckle = 0.3,
			grain = 14,
			strata = 9,
			cracks = 0.6,
			lichen = 0.3,
			moss = 0,
			moss_level = 0.35,
			roughness = 0.85,
			bump = 0.006,
		},
		glsl = [[
#define CUSTOM_NORMAL

const vec3 FACE_N[6] = vec3[](vec3(1, 0, 0), vec3(-1, 0, 0), vec3(0, 1, 0), vec3(0, -1, 0), vec3(0, 0, 1), vec3(0, 0, -1));
const vec3 FACE_U[6] = vec3[](vec3(0, 0, -1), vec3(0, 0, 1), vec3(1, 0, 0), vec3(1, 0, 0), vec3(1, 0, 0), vec3(-1, 0, 0));
const vec3 FACE_V[6] = vec3[](vec3(0, 1, 0), vec3(0, 1, 0), vec3(0, 0, -1), vec3(0, 0, 1), vec3(0, 1, 0), vec3(0, 1, 0));

// the face of the atlas a uv is on, and where on it (-1 to 1, beyond in the padding)
int face_of(vec2 uv, out vec2 st) {
	vec2 cell = uv * vec2(3.0, 2.0);
	vec2 tile = min(floor(cell), vec2(2.0, 1.0));
	vec2 local = cell - tile;
	st = ((local - PAD) / (1.0 - 2.0 * PAD)) * 2.0 - 1.0;
	return int(tile.y) * 3 + int(tile.x);
}

vec3 face_direction(int face, vec2 st) {
	vec2 w = tan(clamp(st, -1.4, 1.4) * PI * 0.25);
	return normalize(FACE_N[face] + FACE_U[face] * w.x + FACE_V[face] * w.y);
}

Surface rock_surface(vec3 d) {
	vec3 p = d * FREQUENCY;
	float large = fbm3(p, 5);
	float detail = fbm3(p * 5.0, 4);
	float zones = fbm3(p * 0.5 + 11.0, 3);
	vec3 albedo;
	float height;
	float roughness = ROUGHNESS;
#if STYLE == 1
	float layer = d.y * STRATA + large * 1.2 + gnoise3(p * 0.7) * 0.6;
	float band = fract(layer);
	float band_id = floor(layer);
	float groove = smoothstep(0.0, 0.12, band) * smoothstep(1.0, 0.85, band);
	albedo = mix(COLOR_BASE, COLOR_LIGHT, hash1(ivec2(int(band_id), 3)) * 0.7);
	albedo = mix(albedo, COLOR_WARM, hash1(ivec2(int(band_id), 9)) * 0.6);
	albedo = mix(albedo, COLOR_DARK, (1.0 - groove) * 0.6);
	height = groove * 0.7 + detail * 0.15;
	roughness = ROUGHNESS + (1.0 - groove) * 0.1;
#elif STYLE == 3
	float mottle = large * 0.5 + 0.5;
	albedo = mix(COLOR_DARK, COLOR_BASE, smoothstep(0.25, 0.65, mottle));
	albedo = mix(albedo, COLOR_LIGHT, smoothstep(0.6, 0.85, mottle) * 0.5);
	height = 0.5 + detail * 0.03;
	roughness = ROUGHNESS - 0.1 * mottle;
#else
	albedo = mix(COLOR_DARK, COLOR_BASE, smoothstep(-0.7, 0.3, large));
	albedo = mix(albedo, COLOR_LIGHT, smoothstep(0.3, 0.8, large) * 0.4);
	// only the detail is in the height, the shape is the mesh's and a different noise
	height = 0.5 + detail * 0.15;
	roughness = ROUGHNESS + detail * 0.05;
#endif
	albedo = mix(albedo, albedo * COLOR_WARM / max(COLOR_BASE, vec3(0.01)), smoothstep(0.0, 0.5, zones) * 0.5);
	// crystals or grains, dark and light
	vec3 grain = voronoi3(p * GRAIN);
	albedo = mix(albedo, COLOR_DARK * 0.7, step(0.85, grain.z) * SPECKLE * smoothstep(0.5, 0.2, grain.x));
	albedo = mix(albedo, COLOR_LIGHT, step(grain.z, 0.1) * SPECKLE * 0.7 * smoothstep(0.5, 0.2, grain.x));
	albedo *= 0.88 + 0.12 * detail;
	// cracks, darker and lower
	vec3 cells = voronoi3(p * 1.2 + large * 0.4);
	float crack = (1.0 - smoothstep(0.0, 0.04, cells.y - cells.x)) * CRACKS;
	albedo = mix(albedo, COLOR_DARK * 0.5, crack * 0.85);
	height -= crack * 0.35;
	float lichen = smoothstep(0.62, 0.68, fbm3(p * 1.5 + 7.0, 5) * 0.5 + 0.5 + (LICHEN - 0.5) * 0.3) * step(0.01, LICHEN);
	albedo = mix(albedo, COLOR_LICHEN * (0.85 + 0.3 * detail), lichen * 0.8);
	height += lichen * 0.04;
	float moss = MOSS * smoothstep(MOSS_LEVEL, MOSS_LEVEL + 0.25, d.y + fbm3(d * 2.5 + 3.0, 4) * 0.4);
	float tufts = fbm3(p * 20.0, 3) * 0.5 + 0.5;
	albedo = mix(albedo, COLOR_MOSS * (0.6 + 0.8 * tufts), moss);
	height = mix(height, 0.7 + tufts * 0.15, moss);
	roughness = mix(mix(roughness, 0.95, crack), 1.0, moss);
	return surface(albedo, 1.0, height, roughness, 0.0);
}

Surface surface_at(vec2 uv) {
	vec2 st;
	int face = face_of(uv, st);
	return rock_surface(face_direction(face, st));
}

vec3 surface_normal(vec2 uv) {
	vec2 st;
	int face = face_of(uv, st);
	// a texel in st
	float e = 2.0 / ((1.0 - 2.0 * PAD) * SIZE.y * 0.5);
	float h = rock_surface(face_direction(face, st)).height;
	float hx = rock_surface(face_direction(face, st + vec2(e, 0.0))).height;
	float hy = rock_surface(face_direction(face, st + vec2(0.0, e))).height;
	return normalize(vec3((h - hx) / e * BUMP * 40.0, (h - hy) / e * BUMP * 40.0, 1.0));
}
]],
	}
)
-- a mushroom cap from above (u around, v from the middle to the rim), style 0 red with white warts, 1 brown and
-- smooth, 2 the pale underside with its gills and the stem
textures.AddKind(
	"mushroom",
	{
		wrap = true,
		width = 512,
		height = 256,
		defaults = {
			style = 0,
			warts = 9,
			gills = 90,
			color_cap = {0.75, 0.08, 0.04},
			color_rim = {0.9, 0.45, 0.15},
			color_spot = {0.95, 0.93, 0.85},
			roughness = 0.45,
			bump = 0.01,
		},
		glsl = [[
Surface surface_at(vec2 uv) {
	float mottle = fbm(uv * vec2(8.0, 4.0), ivec2(8, 4), 4) * 0.5 + 0.5;
#if STYLE == 2
	float gill = abs(fract(uv.x * GILLS) - 0.5) * 2.0;
	float fibre = gnoise(vec2(uv.x * 40.0, uv.y * 3.0), ivec2(40, 3)) * 0.5 + 0.5;
	vec3 albedo = mix(COLOR_CAP, COLOR_RIM, smoothstep(0.6, 1.0, gill) * 0.6 + fibre * 0.2);
	return surface(albedo, 1.0, 1.0 - smoothstep(0.7, 1.0, gill) * 0.5, ROUGHNESS + 0.3, 0.0);
#else
	vec3 albedo = mix(COLOR_CAP, COLOR_RIM, smoothstep(0.55, 1.0, uv.y)) * (0.85 + 0.25 * mottle);
	float height = 0.5 + mottle * 0.1;
#if STYLE == 0
	ivec2 period = ivec2(int(WARTS), int(WARTS * 0.5));
	vec3 cells = voronoi(uv * vec2(period), period, 0.8);
	float size = mix(0.38, 0.18, uv.y) * mix(0.6, 1.2, cells.z);
	float spot = 1.0 - smoothstep(size - 0.05, size, cells.x);
	spot *= step(0.25, cells.z) * smoothstep(0.98, 0.85, uv.y);
	albedo = mix(albedo, COLOR_SPOT * (0.9 + 0.1 * mottle), spot);
	height += spot * 0.4;
	return surface(albedo, 1.0, height, mix(ROUGHNESS, 0.85, spot), 0.0);
#else
	return surface(albedo, 1.0, height, ROUGHNESS + (1.0 - mottle) * 0.1, 0.0);
#endif
#endif
}
]],
	}
)
-- the cut end of a log or a stump, rings around the middle, cracks out from it and the bark around
textures.AddKind(
	"end_grain",
	{
		width = 512,
		height = 512,
		defaults = {
			rings = 22,
			color_early = {0.72, 0.58, 0.4},
			color_late = {0.5, 0.36, 0.22},
			color_bark = {0.2, 0.15, 0.1},
			bark = 0.07,
			roughness = 0.8,
			bump = 0.01,
		},
		glsl = [[
Surface surface_at(vec2 uv) {
	vec2 d = (uv - 0.5) * 2.0;
	float r = length(d);
	float theta = atan(d.y, d.x);
	float warp = fbm(d * 2.0, 4) * 0.08;
	float ring = fract((r + warp) * RINGS);
	float late = smoothstep(0.6, 0.95, ring);
	vec3 albedo = mix(COLOR_EARLY, COLOR_LATE, late) * (0.9 + 0.1 * fbm(d * 30.0, 3));
	// the heartwood is darker
	albedo *= mix(0.8, 1.0, smoothstep(0.1, 0.6, r));
	// cracks out from the middle, where a noise around it crosses zero
	float around = theta / TAU + 0.5;
	float crack_noise = abs(gnoise(vec2(around * 7.0, r * 0.8), ivec2(7, 1 << 20)));
	float crack = (1.0 - smoothstep(0.0, 0.015 + r * 0.01, crack_noise)) * smoothstep(0.2, 0.6, r + gnoise(vec2(around * 5.0, 3.0), ivec2(5, 1 << 20)) * 0.3) * smoothstep(1.0 - BARK, 0.75, r);
	albedo = mix(albedo, COLOR_BARK * 0.5, crack);
	float bark = smoothstep(1.0 - BARK - 0.01, 1.0 - BARK, r);
	albedo = mix(albedo, COLOR_BARK * (0.7 + 0.6 * (gnoise(vec2(theta * 20.0, r * 10.0)) * 0.5 + 0.5)), bark);
	return surface(albedo, 1.0, 0.5 - late * 0.05 - crack * 0.4 + bark * 0.2, ROUGHNESS + late * 0.08 + max(crack, bark) * 0.15, 0.0);
}
]],
	}
)
return textures
