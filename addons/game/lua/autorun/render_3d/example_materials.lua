local assets = import("goluwa/assets.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local DEFAULT_TEXTURE_WIDTH = 256
local DEFAULT_TEXTURE_HEIGHT = 128
-- the texture channels a showcase material can have, and whether they hold colors
local CHANNELS = {
	{key = "Albedo", srgb = true},
	{key = "Metallic", srgb = false},
	{key = "Roughness", srgb = false},
	{key = "Specular", srgb = false},
	{key = "Normal", srgb = false},
	{key = "Height", srgb = false},
}

local function build_default_sampler()
	return {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	}
end

local function build_texture_paths(material_path)
	local stem = material_path:match("([^/]+)%.lua$") or material_path:match("([^/]+)$")
	local root = "textures/examples/material_showcase/" .. stem
	local paths = {}

	for _, channel in ipairs(CHANNELS) do
		paths[channel.key] = root .. "_" .. channel.key:lower() .. ".lua"
	end

	return paths
end

-- the material and its textures are only built once something loads them
local function register_material(entry)
	local config = entry.config
	local paths = build_texture_paths(entry.path)

	for _, channel in ipairs(CHANNELS) do
		local shader = config[channel.key]

		if shader then
			-- the entry's texture options, what the caller asked for on top
			local defaults = entry.textures and entry.textures[channel.key] or {}

			assets.RegisterVirtualTexture(paths[channel.key], function(_, options)
				local request = options.config

				local function get(key, fallback)
					if request[key] ~= nil then return request[key] end

					if defaults[key] ~= nil then return defaults[key] end

					return fallback
				end

				local texture = Texture.New{
					width = get("width", DEFAULT_TEXTURE_WIDTH),
					height = get("height", DEFAULT_TEXTURE_HEIGHT),
					format = get("format", "r8g8b8a8_unorm"),
					mip_map_levels = get("mip_map_levels", 1),
					anisotropy = get("anisotropy", 0),
					srgb = get("srgb", channel.srgb),
					sampler = get("sampler", build_default_sampler()),
				}
				texture:Shade(shader, {header = config.Shared})
				return texture
			end)
		end
	end

	local material
	assets.RegisterVirtualAsset(
		entry.path,
		{
			category = "materials",
			kind = "lua",
			load = function()
				if not material then
					material = Material.New(config)
					material:SetName(entry.name)

					for _, channel in ipairs(CHANNELS) do
						if config[channel.key] then
							material["Set" .. channel.key .. "Texture"](material, assets.GetTexture(paths[channel.key], {config = {srgb = channel.srgb}}))
						end
					end
				end

				return material
			end,
		}
	)
end

local shared = [[
		#define PI 3.14159265359
		#define saturate(x) clamp(x, 0.0, 1.0)
		#define MOD3 vec3(.1031,.11369,.13787)

		vec3 hash33(vec3 p3) {
			p3 = fract(p3 * MOD3);
			p3 += dot(p3, p3.yxz+19.19);
			return -1.0 + 2.0 * fract(vec3((p3.x + p3.y)*p3.z, (p3.x+p3.z)*p3.y, (p3.y+p3.z)*p3.x));
		}

		float perlin_noise(vec3 p) {
			vec3 pi = floor(p);
			vec3 pf = p - pi;
			vec3 w = pf * pf * (3.0 - 2.0 * pf);
			return mix(
				mix(mix(dot(pf - vec3(0, 0, 0), hash33(pi + vec3(0, 0, 0))), 
						dot(pf - vec3(1, 0, 0), hash33(pi + vec3(1, 0, 0))), w.x),
					mix(dot(pf - vec3(0, 0, 1), hash33(pi + vec3(0, 0, 1))), 
						dot(pf - vec3(1, 0, 1), hash33(pi + vec3(1, 0, 1))), w.x), w.z),
				mix(mix(dot(pf - vec3(0, 1, 0), hash33(pi + vec3(0, 1, 0))), 
						dot(pf - vec3(1, 1, 0), hash33(pi + vec3(1, 1, 0))), w.x),
					mix(dot(pf - vec3(0, 1, 1), hash33(pi + vec3(0, 1, 1))), 
						dot(pf - vec3(1, 1, 1), hash33(pi + vec3(1, 1, 1))), w.x), w.z), w.y);
		}

		float fbm(vec3 p) {
			float f = 0.0;
			float a = 0.5;
			for (int i = 0; i < 4; i++) {
				f += a * perlin_noise(p);
				p = p * 2.02 + 11.31;
				a *= 0.5;
			}
			return f;
		}

		vec3 getTriplanar(vec3 position, vec3 normal) {
			return vec3(perlin_noise(position * 0.2));
		}

		void pixarONB(vec3 n, out vec3 b1, out vec3 b2){
			float sign_ = n.z >= 0.0 ? 1.0 : -1.0;
			float a = -1.0 / (sign_ + n.z);
			float b = n.x * n.y * a;
			b1 = vec3(1.0 + sign_ * n.x * n.x * a, sign_ * b, -sign_ * n.x);
			b2 = vec3(b, sign_ + n.y * n.y * a, -n.y);
		}

		vec3 getDetailNormal(vec3 p, vec3 normal, float m) {
			vec3 tangent, bitangent;
			pixarONB(normal, tangent, bitangent);
			
			float EPS = 5e-3;
			float strength = 0.02;
			
			float h = length(getTriplanar(12.0 * p, normal));
			float hT = length(getTriplanar(12.0 * (p + tangent * EPS), normal));
			float hB = length(getTriplanar(12.0 * (p + bitangent * EPS), normal));
			
			vec3 delTangent = (tangent * EPS + normal * m * strength * hT) - (normal * m * strength * h);
			vec3 delBitangent = (bitangent * EPS + normal * m * strength * hB) - (normal * m * strength * h);
			vec3 worldNormal = normalize(cross(delTangent, delBitangent));
			
			return vec3(
				dot(worldNormal, tangent),
				dot(worldNormal, bitangent),
				dot(worldNormal, normal)
			);
		}

		vec3 get_equirect_dir(vec2 uv) {
			float phi = (0.75 - uv.x) * 2.0 * 3.14159265359;
			float theta = uv.y * 3.14159265359;
			return vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));
		}
		#define p (get_equirect_dir(uv) * 3.0)
		#define n get_equirect_dir(uv)
]]
-- sand and snow tile over 1024 texels, each texel a grain or a facet. noise is periodic in uv so the
-- textures wrap, and the normal is the height's gradient
local grain_shared = [[
	#define TEXELS 1024.0

	float hash12(vec2 p) {
		vec3 p3 = fract(vec3(p.xyx) * 0.1031);
		p3 += dot(p3, p3.yzx + 33.33);
		return fract((p3.x + p3.y) * p3.z);
	}

	vec2 hash22(vec2 p) {
		vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
		p3 += dot(p3, p3.yzx + 33.33);
		return fract((p3.xx + p3.yz) * p3.zy);
	}

	// value noise repeating every period cells
	float noise(vec2 p, vec2 period) {
		vec2 i = floor(p);
		vec2 f = fract(p);
		vec2 u = f * f * (3.0 - 2.0 * f);
		return mix(
			mix(hash12(mod(i, period)), hash12(mod(i + vec2(1.0, 0.0), period)), u.x),
			mix(hash12(mod(i + vec2(0.0, 1.0), period)), hash12(mod(i + vec2(1.0, 1.0), period)), u.x),
			u.y
		);
	}

	float fbm(vec2 uv, float period, int octaves) {
		float sum = 0.0;
		float amplitude = 0.5;

		for (int i = 0; i < octaves; i++) {
			sum += noise(uv * period, vec2(period)) * amplitude;
			period *= 2.0;
			amplitude *= 0.5;
		}

		return sum / (1.0 - amplitude * 2.0);
	}

	vec4 height_to_normal(float h, float hu, float hv, float strength) {
		return vec4(normalize(vec3((h - hu) * strength, (h - hv) * strength, 1.0)) * 0.5 + 0.5, 1.0);
	}

	// a texel's grain tilted up to max_slope in a random direction
	vec3 grain_normal(vec2 uv, float seed, float max_slope) {
		vec2 r = hash22(floor(uv * TEXELS) + seed) * 2.0 - 1.0;
		return normalize(vec3(r * max_slope, 1.0));
	}

	// a fraction of the texels are smooth facets: a fresh quartz face, a mica
	// flake, an ice crystal, each catching the sun at its own angle
	bool is_facet(vec2 uv, float fraction) {
		return hash12(floor(uv * TEXELS) + 71.3) < fraction;
	}

	// a facet's normal, anywhere within 60 degrees of the surface's
	vec3 facet_normal(vec2 uv) {
		vec2 r = hash22(floor(uv * TEXELS) + 13.7);
		float cos_theta = mix(1.0, 0.5, r.x);
		float phi = r.y * 6.2831853;
		return vec3(vec2(cos(phi), sin(phi)) * sqrt(1.0 - cos_theta * cos_theta), cos_theta);
	}

	// wind ripples a few cm apart, a gentle windward slope and a steep lee
	float sand_height(vec2 uv) {
		float x = uv.y * 30.0 + fbm(uv, 3.0, 4) * 4.0;
		float t = fract(x);
		return (t < 0.75 ? t / 0.75 : (1.0 - t) / 0.25) * 0.5 + fbm(uv, 12.0, 4) * 0.5;
	}

	// wind crust over soft drifts
	float snow_height(vec2 uv) {
		return fbm(uv, 4.0, 6);
	}
]]
-- a grain or a facet per texel, sampled nearest and without mips: filtering would average the facets'
-- normals away and their glints with them. far away the texels alias and TAA averages them over
-- frames, as the eye does grains smaller than it can resolve, leaving the brightest glints
local GRAIN_TEXTURE = {
	width = 1024,
	height = 1024,
	sampler = {
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	},
}
local DETAIL_TEXTURE = {
	width = 1024,
	height = 1024,
	mip_map_levels = "auto",
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "repeat",
		wrap_t = "repeat",
	},
}
-- how deep the snow's drifts are in texture units, 2.4 cm on the 2.4 m tile. its normal map shades
-- them with the same depth
local SNOW_HEIGHT_SCALE = 0.01
local showcase_materials = {
	{
		path = "materials/examples/polished_gold.lua",
		name = "Polished Gold",
		config = {
			Shared = shared,
			Albedo = "return vec4(1.022, 0.782, 0.344, 1.0);",
			Metallic = "return vec4(1.0);",
			Roughness = "return vec4(0.05);",
			Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/satin_silver.lua",
		name = "Satin Silver",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
			Metallic = "return vec4(1.0);",
			Roughness = "return vec4(0.2);",
			Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/rose_copper.lua",
		name = "Rose Copper",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.955, 0.637, 0.538, 1.0);",
			Metallic = "return vec4(1.0);",
			Roughness = "return vec4(0.3);",
			Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/neon_green_gloss.lua",
		name = "Neon Green Gloss",
		config = {
			Shared = shared,
			Albedo = "return vec4(0, 1, 0, 1.0);",
			Metallic = "return vec4(0.0);",
			Roughness = "return vec4(0.00);",
			Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/red_enamel.lua",
		name = "Red Enamel",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.875, 0.125, 0.0, 1.0);",
			Metallic = "return vec4(0.0);",
			Roughness = "return vec4(0.05);",
			Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		},
	},
	{
		path = "materials/examples/patina_blend.lua",
		name = "Patina Blend",
		config = {
			Shared = shared,
			Albedo = [[
				float m = smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n)));

				return mix(
					vec4(0.0125, 0.2625, 0.3125, 1.0),
					vec4(1.022, 0.782, 0.344, 1.0),
					m
				);
			]],
			Metallic = "return vec4(smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n))));",
			Roughness = [[
				float m = smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n)));
				float r = mix(
					length(getTriplanar(12.0*p, n)),
					0.25 * saturate(length(getTriplanar(1.0*p, n))),
					m
				);
				return vec4(clamp(r, 0.05, 0.999));
			]],
			Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/soft_silver.lua",
		name = "Soft Silver",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
			Metallic = "return vec4(1.0);",
			Roughness = "return vec4(1.0 / 3.0);",
			Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/hazard_stripe.lua",
		name = "Hazard Stripe",
		config = {
			Shared = shared,
			Albedo = [[
				return vec4(mix(vec3(0.0625), vec3(1.0, 0.8125, 0.125), 
					smoothstep(0.0, 0.2, sin(5.8*p.y + 5.8*p.z))), 1.0);
			]],
			Metallic = "return vec4(0.0);",
			Roughness = "return vec4(1.0 / 3.0);",
			Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		},
	},
	{
		path = "materials/examples/blue_ceramic.lua",
		name = "Blue Ceramic",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.1125, 0.4125, 1.0, 1.0);",
			Metallic = "return vec4(0.0);",
			Roughness = "return vec4(2.0 / 3.0);",
			Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/pearlescent_copper.lua",
		name = "Pearlescent Copper",
		config = {
			Shared = shared,
			Albedo = [[
				float weight = length(getTriplanar(8.0*(p.xxx+p.yyy+p.zzz), n));
				return vec4(saturate(0.6 + max(0.2, weight)) * vec3(0.955, 0.637, 0.538), 1.0);
			]],
			Metallic = "return vec4(1.0);",
			Roughness = "return vec4(0.3);",
			Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		},
	},
	{
		path = "materials/examples/weathered_steel.lua",
		name = "Weathered Steel",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.91, 0.92, 0.92, 1.0);",
			Metallic = "return vec4(1.0);",
			Roughness = [[
				float large_wear = perlin_noise(p * 2.0) * 0.5 + 0.5;
				float medium_wear = perlin_noise(p * 6.0) * 0.5 + 0.5;
				float fine_detail = perlin_noise(p * 20.0) * 0.5 + 0.5;
				float roughness = mix(0.05, 0.6, large_wear * 0.6 + medium_wear * 0.3 + fine_detail * 0.1);
				return vec4(roughness);
			]],
			Normal = "return vec4(getDetailNormal(p, n, 0.3) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/brushed_aluminum.lua",
		name = "Brushed Aluminum",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
			Metallic = "return vec4(1.0);",
			Roughness = [[
				float streaks = sin(p.x * 40.0 + perlin_noise(p * 8.0) * 2.0) * 0.5 + 0.5;
				float base_rough = 0.15;
				float roughness = base_rough + streaks * 0.25;
				return vec4(roughness);
			]],
			Normal = "return vec4(getDetailNormal(p, n, 0.15) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/smudged_chrome.lua",
		name = "Smudged Chrome",
		config = {
			Shared = shared,
			Albedo = "return vec4(0.91, 0.92, 0.92, 1.0);",
			Metallic = "return vec4(1.0);",
			Roughness = [[
				float smudge1 = smoothstep(0.3, 0.7, perlin_noise(p * 3.0 + vec3(0.0)));
				float smudge2 = smoothstep(0.2, 0.6, perlin_noise(p * 4.0 + vec3(5.0)));
				float smudges = max(smudge1, smudge2 * 0.7);
				return vec4(mix(0.02, 0.4, smudges));
			]],
			Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		},
	},
	{
		path = "materials/examples/aged_copper.lua",
		name = "Aged Copper",
		config = {
			Shared = shared,
			Albedo = [[
				float age = smoothstep(0.3, 0.7, perlin_noise(p * 4.0) * 0.5 + 0.5);
				vec3 fresh = vec3(0.955, 0.637, 0.538);
				vec3 aged = vec3(0.4, 0.65, 0.55);
				return vec4(mix(fresh, aged, age * 0.3), 1.0);
			]],
			Metallic = "return vec4(1.0);",
			Roughness = [[
				float age = perlin_noise(p * 4.0) * 0.5 + 0.5;
				float detail = perlin_noise(p * 15.0) * 0.5 + 0.5;
				return vec4(mix(0.1, 0.7, age * 0.8 + detail * 0.2));
			]],
			Normal = "return vec4(getDetailNormal(p, n, 0.4) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/hybrid_surface.lua",
		name = "Hybrid Surface",
		config = {
			Shared = shared,
			Albedo = [[
				float is_metal = step(0.0, n.y);
				vec3 plastic_color = vec3(0.8, 0.1, 0.1);
				vec3 metal_color = vec3(0.91, 0.92, 0.92);
				return vec4(mix(metal_color, plastic_color, is_metal), 1.0);
			]],
			Metallic = [[
				return vec4(step(0.0, n.y));
			]],
			Roughness = [[
				float roughness = smoothstep(-1.0, 1.0, n.x);
				return vec4(mix(0.02, 0.95, roughness));
			]],
			Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		},
	},
	{
		path = "materials/examples/black_rubber.lua",
		name = "Black Rubber",
		config = {
			Shared = shared,
			Albedo = [[
					float s = perlin_noise(p * 24.0) * 0.5 + 0.5;
					return vec4(vec3(0.05) + 0.02 * s, 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float s = perlin_noise(p * 10.0) * 0.5 + 0.5;
					return vec4(0.86 + 0.08 * s);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.35) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/gym_rubber.lua",
		name = "Gym Rubber (Blue)",
		config = {
			Shared = shared,
			Albedo = [[
					float s = perlin_noise(p * 20.0) * 0.5 + 0.5;
					return vec4(mix(vec3(0.02, 0.05, 0.11), vec3(0.06, 0.11, 0.20), s), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float s = perlin_noise(p * 10.0) * 0.5 + 0.5;
					return vec4(0.82 + 0.08 * s);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.3) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/grass.lua",
		name = "Grass",
		config = {
			Grass = true,
			Shared = shared,
			Albedo = [[
					float f = fbm(p * 3.0) * 0.5 + 0.5;
					float tuft = perlin_noise(p * 18.0) * 0.5 + 0.5;
					vec3 base = mix(vec3(0.06, 0.18, 0.04), vec3(0.28, 0.42, 0.10), f);
					return vec4(base * (0.85 + 0.3 * tuft), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float s = perlin_noise(p * 8.0) * 0.5 + 0.5;
					return vec4(0.72 + 0.12 * s);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.9) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/wood_oak.lua",
		name = "Wood (Oak)",
		config = {
			Shared = shared,
			Albedo = [[
					float r = length(p - vec3(0.0, -3.5, 0.0));
					float rings = sin((r * 1.2 + fbm(p * 1.5) * 1.5) * 3.0) * 0.5 + 0.5;
					rings = smoothstep(0.25, 0.75, rings);
					vec3 light = vec3(0.72, 0.55, 0.35);
					vec3 dark = vec3(0.42, 0.29, 0.17);
					return vec4(mix(light, dark, rings), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float r = length(p - vec3(0.0, -3.5, 0.0));
					float rings = sin((r * 1.2 + fbm(p * 1.5) * 1.5) * 3.0) * 0.5 + 0.5;
					return vec4(0.48 + 0.15 * smoothstep(0.25, 0.75, rings));
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.5) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/galvanized_steel.lua",
		name = "Galvanized Steel",
		config = {
			Shared = shared,
			Albedo = [[
					float m = fbm(p * 6.0) * 0.5 + 0.5;
					return vec4(mix(vec3(0.55, 0.58, 0.60), vec3(0.75, 0.78, 0.80), m), 1.0);
				]],
			Metallic = "return vec4(1.0);",
			Roughness = [[
					float m = fbm(p * 6.0) * 0.5 + 0.5;
					return vec4(0.22 + 0.3 * m);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.25) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/plastic_bin.lua",
		name = "Plastic (Matte Gray)",
		config = {
			Shared = shared,
			Albedo = [[
					float mottle = perlin_noise(p * 6.0) * 0.5 + 0.5;
					float speck = step(0.93, perlin_noise(p * 45.0) * 0.5 + 0.5);
					vec3 base = mix(vec3(0.55, 0.58, 0.60), vec3(0.68, 0.70, 0.72), mottle);
					return vec4(base + 0.15 * speck, 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float m = perlin_noise(p * 6.0) * 0.5 + 0.5;
					return vec4(0.34 + 0.06 * m);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.3) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/rock.lua",
		name = "Rock",
		config = {
			Shared = shared,
			Albedo = [[
					float f = fbm(p * 2.0) * 0.5 + 0.5;
					return vec4(mix(vec3(0.30, 0.28, 0.26), vec3(0.45, 0.41, 0.35), f), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float f = fbm(p * 2.0) * 0.5 + 0.5;
					return vec4(0.8 + 0.15 * f);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/gravel.lua",
		name = "Gravel",
		config = {
			Shared = shared,
			Albedo = [[
					float n1 = perlin_noise(p * 12.0) * 0.5 + 0.5;
					float n2 = perlin_noise(p * 28.0 + vec3(7.0)) * 0.5 + 0.5;
					float n = 0.6 * n1 + 0.4 * n2;
					vec3 base = mix(vec3(0.18, 0.17, 0.16), vec3(0.50, 0.48, 0.45), n);
					return vec4(base, 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float n = 0.6 * (perlin_noise(p * 12.0) * 0.5 + 0.5) + 0.4 * (perlin_noise(p * 28.0 + vec3(7.0)) * 0.5 + 0.5);
					return vec4(0.8 + 0.12 * n);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.8) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/rusted_iron.lua",
		name = "Rusted Iron",
		config = {
			Shared = shared,
			Albedo = [[
					float rust = smoothstep(0.0, 0.45, fbm(p * 2.5));
					float blotch = perlin_noise(p * 12.0) * 0.5 + 0.5;
					vec3 steel = vec3(0.55, 0.56, 0.57);
					vec3 rustc = vec3(0.42, 0.20, 0.08) * (0.7 + 0.6 * blotch);
					return vec4(mix(steel, rustc, rust), 1.0);
				]],
			Metallic = [[
					return vec4(1.0 - smoothstep(0.0, 0.45, fbm(p * 2.5)));
				]],
			Roughness = [[
					float rust = smoothstep(0.0, 0.45, fbm(p * 2.5));
					float blotch = perlin_noise(p * 12.0) * 0.5 + 0.5;
					return vec4(mix(0.3, 0.9, rust) + 0.05 * blotch);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.4) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/concrete.lua",
		name = "Concrete",
		config = {
			Shared = shared,
			Albedo = [[
					float mottle = fbm(p * 3.0) * 0.5 + 0.5;
					float crack = 1.0 - smoothstep(0.0, 0.05, abs(fbm(p * 1.2)));
					vec3 base = mix(vec3(0.48, 0.48, 0.46), vec3(0.62, 0.62, 0.60), mottle);
					return vec4(mix(base, vec3(0.25), crack * 0.8), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float m = fbm(p * 3.0) * 0.5 + 0.5;
					return vec4(0.82 + 0.1 * m);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.5) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/soil.lua",
		name = "Soil",
		config = {
			Shared = shared,
			Albedo = [[
					float f = fbm(p * 3.0) * 0.5 + 0.5;
					return vec4(mix(vec3(0.16, 0.11, 0.06), vec3(0.32, 0.22, 0.13), f), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float f = fbm(p * 3.0) * 0.5 + 0.5;
					return vec4(0.92 + 0.06 * f);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.9) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		-- dry sand: grains of quartz, feldspar and a few dark ones, a smooth quartz or mica facet among
		-- them here and there
		path = "materials/examples/sand.lua",
		name = "Sand",
		textures = {
			Albedo = DETAIL_TEXTURE,
			Roughness = GRAIN_TEXTURE,
			Specular = GRAIN_TEXTURE,
			Normal = GRAIN_TEXTURE,
		},
		config = {
			Shared = grain_shared,
			Albedo = [[
				float r = hash12(floor(uv * TEXELS) + 3.1);
				vec3 grain = vec3(0.42, 0.33, 0.22) * mix(0.75, 1.2, hash12(floor(uv * TEXELS) + 9.4));
				grain = r < 0.07 ? vec3(0.07, 0.06, 0.05) : r > 0.9 ? vec3(0.62, 0.58, 0.52) : grain;
				return vec4(grain * mix(0.85, 1.1, fbm(uv, 6.0, 4)), 1.0);
			]],
			Metallic = "return vec4(0.0);",
			Roughness = "return vec4(is_facet(uv, 0.05) ? 0.15 : 0.9);",
			Specular = "return vec4(is_facet(uv, 0.05) ? 1.0 : 0.5);",
			SpecularMultiplier = 2,
			Normal = [[
				vec2 e = vec2(1.0 / TEXELS, 0.0);
				float h = sand_height(uv);
				vec3 ripples = height_to_normal(h, sand_height(uv + e.xy), sand_height(uv + e.yx), 4.0).xyz * 2.0 - 1.0;
				vec3 grain = is_facet(uv, 0.05) ? facet_normal(uv) : grain_normal(uv, 0.0, 0.3);
				return vec4(normalize(vec3(ripples.xy + grain.xy, ripples.z)) * 0.5 + 0.5, 1.0);
			]],
		},
	},
	{
		-- snow: ice grains, bright and mostly rough, with the odd crystal face catching the sun. ice's F0
		-- is 0.018
		path = "materials/examples/snow.lua",
		name = "Snow",
		textures = {
			Albedo = DETAIL_TEXTURE,
			Roughness = GRAIN_TEXTURE,
			Normal = GRAIN_TEXTURE,
			Height = DETAIL_TEXTURE,
		},
		config = {
			Shared = grain_shared,
			Albedo = "return vec4(vec3(0.9, 0.92, 0.94) * mix(0.95, 1.02, fbm(uv, 20.0, 4)), 1.0);",
			Metallic = "return vec4(0.0);",
			Roughness = "return vec4(is_facet(uv, 0.08) ? 0.1 : mix(0.6, 0.8, hash12(floor(uv * TEXELS))));",
			SpecularMultiplier = 0.45,
			-- the drifts the normal map shades, parallax mapped around the surface
			Height = "return vec4(snow_height(uv));",
			HeightScale = SNOW_HEIGHT_SCALE,
			HeightMidlevel = 0.5,
			-- the drifts' slope is the height's per texel times the texels in one texture unit times the depth
			Normal = [[
				vec2 e = vec2(1.0 / TEXELS, 0.0);
				float h = snow_height(uv);
				vec3 drifts = height_to_normal(h, snow_height(uv + e.xy), snow_height(uv + e.yx), TEXELS * ]] .. string.format("%.6f", SNOW_HEIGHT_SCALE) .. [[).xyz * 2.0 - 1.0;
				vec3 grain = is_facet(uv, 0.08) ? facet_normal(uv) : grain_normal(uv, 5.0, 0.15);
				return vec4(normalize(vec3(drifts.xy + grain.xy, drifts.z)) * 0.5 + 0.5, 1.0);
			]],
		},
	},
	{
		path = "materials/examples/asphalt.lua",
		name = "Asphalt",
		config = {
			Shared = shared,
			Albedo = [[
					float f = fbm(p * 8.0) * 0.5 + 0.5;
					float speck = step(0.8, perlin_noise(p * 35.0) * 0.5 + 0.5) * 0.5;
					return vec4(vec3(0.055 + 0.02 * f) + vec3(0.02) * speck, 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float f = fbm(p * 8.0) * 0.5 + 0.5;
					return vec4(0.7 + 0.15 * f);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.5) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		-- the water film rain leaves, render3d/surface_weather.lua lays its clearcoat over whatever gets
		-- wet. shown here on asphalt, darkened as its pores soak it up
		path = "materials/examples/rain.lua",
		name = "Rain",
		config = {
			Shared = shared,
			Albedo = [[
					float f = fbm(p * 8.0) * 0.5 + 0.5;
					float speck = step(0.8, perlin_noise(p * 35.0) * 0.5 + 0.5) * 0.5;
					return vec4((vec3(0.055 + 0.02 * f) + vec3(0.02) * speck) * 0.5, 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float f = fbm(p * 8.0) * 0.5 + 0.5;
					return vec4(0.7 + 0.15 * f);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.5) * 0.5 + 0.5, 1.0);",
			-- a film broken up by the drops landing in it
			Clearcoat = 1,
			ClearcoatRoughness = 0.08,
		},
	},
	{
		path = "materials/examples/carbon_fiber.lua",
		name = "Carbon Fiber",
		config = {
			Shared = shared,
			Albedo = [[
					vec2 g = p.xy * 14.0;
					float weave = sin(g.x) * sin(g.y);
					float id = mod(floor(g.x) + floor(g.y), 2.0);
					float shade = mix(0.85, 1.15, weave) * mix(0.9, 1.0, id);
					return vec4(vec3(0.045) * shade, 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float weave = sin(p.x * 14.0) * sin(p.y * 14.0);
					return vec4(0.28 + 0.08 * (0.5 - 0.5 * weave));
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.5) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/leather.lua",
		name = "Leather",
		config = {
			Shared = shared,
			Albedo = [[
					float f = fbm(p * 4.0) * 0.5 + 0.5;
					return vec4(mix(vec3(0.30, 0.18, 0.09), vec3(0.47, 0.30, 0.15), f), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float f = fbm(p * 4.0) * 0.5 + 0.5;
					return vec4(0.45 + 0.25 * f);
				]],
			Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		},
	},
	{
		path = "materials/examples/mossy_rock.lua",
		name = "Mossy Rock",
		config = {
			Shared = shared,
			Albedo = [[
					float m = smoothstep(-0.15, 0.35, fbm(p * 2.5));
					vec3 rock = mix(vec3(0.30, 0.28, 0.26), vec3(0.45, 0.41, 0.35), fbm(p * 3.0) * 0.5 + 0.5);
					vec3 moss = vec3(0.13, 0.34, 0.08) * (0.8 + 0.4 * (perlin_noise(p * 12.0) * 0.5 + 0.5));
					return vec4(mix(rock, moss, m), 1.0);
				]],
			Metallic = "return vec4(0.0);",
			Roughness = [[
					float m = smoothstep(-0.15, 0.35, fbm(p * 2.5));
					return vec4(mix(0.85, 0.95, m));
				]],
			Normal = "return vec4(getDetailNormal(p, n, 0.9) * 0.5 + 0.5, 1.0);",
		},
	},
}

for _, entry in ipairs(showcase_materials) do
	register_material(entry)
end

return showcase_materials
