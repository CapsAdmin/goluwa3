local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("lua/shapes.lua")
local Texture = import("goluwa/render/texture.lua")
-- probe visibility rays leave hard dark crescents on the spheres
import("goluwa/render3d/ddgi.lua").VISIBILITY_RAYS = 0
local root = Entity.New{Name = "pbr_parameters"}
local COLUMNS = 9
local SPACING = 1.2
local RADIUS = 0.45
-- height fields and noise for the textures below, which are 1024 texels a
-- side. noise is periodic in uv so it wraps around the spheres' seam. the
-- normal map is the height's gradient, so the same height can drive roughness too
local shared = [[
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

	// hemispherical dents of hammered metal, the distance to the nearest
	// hammer blow squared
	float dents_height(vec2 uv) {
		vec2 p = uv * 14.0;
		vec2 i = floor(p);
		vec2 f = fract(p);
		float d = 1e9;

		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec2 o = vec2(x, y);
				vec2 r = o + hash22(mod(i + o, 14.0)) * 0.8 + 0.1 - f;
				d = min(d, dot(r, r));
			}
		}

		return d;
	}

	// brushing leaves fine grooves along u, a texel or two apart
	float brushed_height(vec2 uv) {
		return noise(vec2(uv.x * 6.0, uv.y * 900.0), vec2(6.0, 900.0)) * 0.7 + noise(vec2(uv.x * 48.0, uv.y * 300.0), vec2(48.0, 300.0)) * 0.3;
	}

	// straight scratches of random length, direction and depth
	float scratches_height(vec2 uv) {
		float groove = 0.0;

		for (int i = 0; i < 90; i++) {
			vec2 r = hash22(vec2(i, 3.7));
			vec2 s = hash22(vec2(i, 11.3));
			// most go roughly one way, as from wiping
			float angle = s.x < 0.7 ? 0.2 + s.x * 0.5 : s.x * 9.0;
			vec2 dir = vec2(cos(angle), sin(angle));
			vec2 d = fract(uv - r + 0.5) - 0.5;
			float t = clamp(dot(d, dir), 0.0, mix(0.03, 0.4, s.y * s.y));
			float width = mix(0.0005, 0.0015, hash12(vec2(i, 5.1)));
			groove = max(groove, smoothstep(width, 0.0, length(d - dir * t)) * mix(0.3, 1.0, hash12(vec2(i, 9.9))));
		}

		return 1.0 - groove;
	}

	// 0 paint, 1 primer at the chip's edge, 2 bare steel
	float paint_wear(vec2 uv) {
		float n = fbm(uv, 5.0, 7);
		return smoothstep(0.6, 0.61, n) + smoothstep(0.635, 0.645, n);
	}

	// round bumps a few pixels apart once the sphere is a few meters away
	float fine_bumps_height(vec2 uv) {
		vec2 cell = fract(uv * 48.0) - 0.5;
		return sqrt(max(1.0 - dot(cell, cell) / 0.2, 0.0));
	}

	// ridges along u, 2 cm apart on a 3.2 m sheet
	float corrugated_height(vec2 uv) {
		return 0.5 + 0.5 * sin(uv.y * 6.2831853 * 160.0);
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

	// a pointed ellipse along v, x across it from -1 to 1
	float leaf_mask(vec2 uv) {
		vec2 p = (vec2(uv.x, 1.0 - uv.y) - 0.5) * 2.0;
		float half_width = 0.85 * pow(max(1.0 - p.y * p.y, 0.0), 0.8) * (1.0 - 0.25 * p.y);
		return step(abs(p.x), half_width) * step(p.y, 0.92) + step(abs(p.x), 0.02) * step(0.9, p.y);
	}

	// the midrib and the side veins running out from it towards the tip
	float leaf_veins(vec2 uv) {
		vec2 p = (vec2(uv.x, 1.0 - uv.y) - 0.5) * 2.0;
		float midrib = smoothstep(0.025, 0.01, abs(p.x));
		float side = smoothstep(0.08, 0.02, abs(fract(p.y * 5.0 - abs(p.x) * 3.0) - 0.5)) * smoothstep(0.02, 0.1, abs(p.x));
		return max(midrib, side * 0.6);
	}
]]

local function normal_map(height_function, strength)
	return (
		[[
		vec2 e = vec2(1.0 / TEXELS, 0.0);
		float h = %s(uv);
		return height_to_normal(h, %s(uv + e.xy), %s(uv + e.yx), %s);
	]]
	):format(height_function, height_function, height_function, strength)
end

-- a grain or a facet per texel, sampled nearest and without mips: filtering
-- would average the facets' normals away and their glints with them. far away
-- the texels alias and TAA averages them over frames, as the eye does grains
-- smaller than it can resolve, leaving the brightest glints
local function grain_texture(glsl)
	local tex = Texture.New{
		width = 1024,
		height = 1024,
		format = "r8g8b8a8_unorm",
		image = {
			usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
	tex:Shade(glsl, {custom_declarations = shared})
	return tex
end

local function material(config)
	config.Shared = shared
	return shapes.Material(config)
end

local function sphere(x, z, mat)
	shapes.Sphere{
		Parent = root,
		Position = Vec3(x, RADIUS, z),
		Radius = RADIUS,
		Material = mat,
		RigidBody = false,
	}
end

-- a row of spheres from t = 0 on the left to t = 1 on the right
local function sweep(z, build)
	for i = 0, COLUMNS - 1 do
		sphere((i - (COLUMNS - 1) / 2) * SPACING, z, build(i / (COLUMNS - 1)))
	end
end

-- a floor tile and a sphere on it
local function tile(x, z, tile_mat, sphere_mat)
	shapes.Box{
		Parent = root,
		Position = Vec3(x, 0.01, z),
		Size = Vec3(2.4, 0.02, 2.4),
		Material = tile_mat,
		RigidBody = false,
	}
	shapes.Sphere{
		Parent = root,
		Position = Vec3(x, 0.02 + RADIUS, z),
		-- the u seam faces the viewer otherwise
		Rotation = QuatDeg3(0, 180, 0),
		Radius = RADIUS,
		Material = sphere_mat or tile_mat,
		RigidBody = false,
	}
end

-- a standing panel with a tile in front of it reflecting the panel and a sphere on the tile, all with the material
local function swatch(x, mat)
	shapes.Box{
		Parent = root,
		Position = Vec3(x, 1.2, -10.5),
		Size = Vec3(2.4, 2.4, 0.1),
		Material = mat,
		RigidBody = false,
	}
	tile(x, -8.6, mat)
end

shapes.Box{
	Name = "floor",
	Parent = root,
	Position = Vec3(0, -0.5, -3),
	Size = Vec3(30, 1, 24),
	Material = material{Color = Color(0.5, 0.5, 0.5, 1), Roughness = 0.8, Metallic = 0},
	RigidBody = false,
}

-- dielectric roughness
sweep(0, function(t)
	return material{Color = Color(0.6, 0.08, 0.06, 1), Roughness = t, Metallic = 0}
end)

-- metal roughness
sweep(-1.2, function(t)
	return material{Color = Color(1, 0.78, 0.34, 1), Roughness = t, Metallic = 1}
end)

-- metallic at a fixed roughness
sweep(-2.4, function(t)
	return material{Color = Color(0.95, 0.64, 0.54, 1), Roughness = 0.25, Metallic = t}
end)

-- dielectric F0 from water's 0.02 to 0.08 on black, only the reflection is left
sweep(-3.6, function(t)
	return material{
		Color = Color(0, 0, 0, 1),
		Roughness = 0.15,
		Metallic = 0,
		SpecularMultiplier = math.lerp(0.5, 2, t),
	}
end)

-- albedo from black to white on a rough dielectric
sweep(-4.8, function(t)
	return material{Color = Color(t, t, t, 1), Roughness = 0.6, Metallic = 0}
end)

-- glass roughness, clear to frosted
sweep(-6, function(t)
	return material{
		Color = Color(1, 1, 1, 1),
		Roughness = t,
		Metallic = 0,
		Refraction = 1,
		IndexOfRefraction = 1.5,
	}
end)

-- roughness across u on chrome
swatch(
	-8.75,
	material{
		Color = Color(0.95, 0.95, 0.95, 1),
		Roughness = "return vec4(uv.x);",
		Metallic = 1,
	}
)
-- metallic across u on gold
swatch(
	-6.25,
	material{
		Color = Color(1, 0.78, 0.34, 1),
		Roughness = 0.3,
		Metallic = "return vec4(uv.x);",
	}
)
-- metallic across u, roughness across v
swatch(
	-3.75,
	material{
		Color = Color(0.9, 0.9, 0.9, 1),
		Roughness = "return vec4(uv.y);",
		Metallic = "return vec4(uv.x);",
	}
)
-- chipped paint over steel, red primer at the chips' edges
swatch(
	-1.25,
	material{
		Color = [[
			float wear = paint_wear(uv);
			vec3 paint = vec3(0.05, 0.12, 0.3) * mix(0.85, 1.1, fbm(uv, 40.0, 3));
			return vec4(mix(mix(paint, vec3(0.3, 0.07, 0.04), min(wear, 1.0)), vec3(0.56, 0.57, 0.58), max(wear - 1.0, 0.0)), 1.0);
		]],
		Metallic = "return vec4(max(paint_wear(uv) - 1.0, 0.0));",
		Roughness = [[
			float wear = paint_wear(uv);
			return vec4(mix(mix(0.35, 0.5, fbm(uv, 24.0, 4)), mix(0.6, 0.3, wear - 1.0), step(0.5, wear)));
		]],
		-- the paint stands a little above the primer and the steel
		Normal = normal_map("-paint_wear", "3.0"),
	}
)
-- hammered steel, the dents getting deeper across u
swatch(
	1.25,
	material{
		Color = Color(0.56, 0.57, 0.58, 1),
		Roughness = "return vec4(mix(0.2, 0.35, fbm(uv, 16.0, 4)));",
		Metallic = 1,
		Normal = normal_map("dents_height", "mix(1.0, 40.0, uv.x)"),
	}
)
-- brushed aluminium, grooves along u
swatch(
	3.75,
	material{
		Color = Color(0.91, 0.92, 0.92, 1),
		Metallic = 1,
		Roughness = "return vec4(mix(0.2, 0.35, brushed_height(uv)));",
		Normal = normal_map("brushed_height", "2.0"),
	}
)
-- scratched and smudged copper, the scratches expose rougher bright metal
swatch(
	6.25,
	material{
		Color = "return vec4(vec3(0.95, 0.64, 0.54) * mix(0.75, 1.0, fbm(uv, 6.0, 5)), 1.0);",
		Metallic = 1,
		Roughness = "return vec4(mix(mix(0.15, 0.4, fbm(uv, 8.0, 6)), 0.5, 1.0 - scratches_height(uv)));",
		Normal = normal_map("scratches_height", "20.0"),
	}
)
-- dielectric specular map from none to twice the usual F0 across u on black
swatch(
	8.75,
	material{
		Color = Color(0.02, 0.02, 0.02, 1),
		Roughness = 0.2,
		Metallic = 0,
		Specular = "return vec4(uv.x);",
		SpecularMultiplier = 2,
	}
)
-- in front: materials made of many small grains and facets, and ones light goes through
local FRONT = 3.2
-- dry sand: grains of quartz, feldspar and a few dark ones, a smooth quartz or
-- mica facet among them here and there
tile(
	-5,
	FRONT,
	material{
		Color = [[
			float r = hash12(floor(uv * TEXELS) + 3.1);
			vec3 grain = vec3(0.42, 0.33, 0.22) * mix(0.75, 1.2, hash12(floor(uv * TEXELS) + 9.4));
			grain = r < 0.07 ? vec3(0.07, 0.06, 0.05) : r > 0.9 ? vec3(0.62, 0.58, 0.52) : grain;
			return vec4(grain * mix(0.85, 1.1, fbm(uv, 6.0, 4)), 1.0);
		]],
		Metallic = 0,
		Roughness = grain_texture("return vec4(is_facet(uv, 0.05) ? 0.15 : 0.9);"),
		Specular = grain_texture("return vec4(is_facet(uv, 0.05) ? 1.0 : 0.5);"),
		SpecularMultiplier = 2,
		Normal = grain_texture([[
			vec2 e = vec2(1.0 / TEXELS, 0.0);
			float h = sand_height(uv);
			vec3 ripples = height_to_normal(h, sand_height(uv + e.xy), sand_height(uv + e.yx), 4.0).xyz * 2.0 - 1.0;
			vec3 grain = is_facet(uv, 0.05) ? facet_normal(uv) : grain_normal(uv, 0.0, 0.3);
			return vec4(normalize(vec3(ripples.xy + grain.xy, ripples.z)) * 0.5 + 0.5, 1.0);
		]]),
	}
)
-- snow: ice grains, bright and mostly rough, with the odd crystal face
-- catching the sun. ice's F0 is 0.018
tile(
	-2.5,
	FRONT,
	material{
		Color = "return vec4(vec3(0.9, 0.92, 0.94) * mix(0.95, 1.02, fbm(uv, 20.0, 4)), 1.0);",
		Metallic = 0,
		Roughness = grain_texture("return vec4(is_facet(uv, 0.08) ? 0.1 : mix(0.6, 0.8, hash12(floor(uv * TEXELS))));"),
		SpecularMultiplier = 0.45,
		Normal = grain_texture([[
			vec2 e = vec2(1.0 / TEXELS, 0.0);
			float h = snow_height(uv);
			vec3 drifts = height_to_normal(h, snow_height(uv + e.xy), snow_height(uv + e.yx), 6.0).xyz * 2.0 - 1.0;
			vec3 grain = is_facet(uv, 0.08) ? facet_normal(uv) : grain_normal(uv, 5.0, 0.15);
			return vec4(normalize(vec3(drifts.xy + grain.xy, drifts.z)) * 0.5 + 0.5, 1.0);
		]]),
	}
)
-- the glass balls sit on a tiled floor to show what they bend
local grid = material{
	Color = [[
		vec2 line = step(0.95, fract(uv * 12.0));
		return vec4(vec3(mix(0.6, 0.05, max(line.x, line.y))), 1.0);
	]],
	Roughness = 0.6,
	Metallic = 0,
}
-- green bottle glass
tile(
	0,
	FRONT,
	grid,
	material{
		Color = Color(0.3, 0.65, 0.35, 1),
		Roughness = 0.02,
		Metallic = 0,
		Refraction = 1,
		IndexOfRefraction = 1.52,
	}
)
-- diamond
tile(
	2.5,
	FRONT,
	grid,
	material{
		Color = Color(1, 1, 1, 1),
		Roughness = 0.002,
		Metallic = 0,
		Refraction = 1,
		IndexOfRefraction = 2.42,
	}
)
-- a leaf standing on its stem, the sun shows through it from behind and lights its veins
shapes.Box{
	Parent = root,
	Position = Vec3(5, 0.8, FRONT),
	Size = Vec3(0.9, 1.5, 0.002),
	Material = material{
		Color = [[
			vec3 leaf = mix(vec3(0.05, 0.14, 0.02), vec3(0.16, 0.25, 0.06), leaf_veins(uv)) * mix(0.85, 1.1, fbm(uv, 8.0, 4));
			return vec4(leaf, leaf_mask(uv));
		]],
		AlphaTest = true,
		Roughness = 0.45,
		Metallic = 0,
		-- the veins are thicker and let less through
		DiffuseTransmission = 0.5,
		Transmission = "return vec4(1.0 - leaf_veins(uv) * 0.6);",
		TransmissionColor = Color(0.55, 1, 0.1, 1),
		TransmissionScattering = 0.6,
	},
	RigidBody = false,
}
-- on the right: glossy detail a pixel or smaller from a few meters away, where
-- sampling one normal per pixel catches or misses the highlight and it
-- flickers as the view moves (see get_antialiased_roughness in model_pipeline.lua)
local ALIAS_X = 9.5
-- chrome ball bearings
local bearing = material{Color = Color(0.95, 0.95, 0.95, 1), Roughness = 0.05, Metallic = 1}

for x = 0, 29 do
	for z = 0, 29 do
		shapes.Sphere{
			Parent = root,
			Position = Vec3(ALIAS_X - 2.2 + x * 0.04, 0.01, 2.2 - z * 0.04),
			Radius = 0.01,
			Material = bearing,
			RigidBody = false,
			CastShadows = false,
		}
	end
end

-- a grill of thin glossy steel pipes
local pipe = material{Color = Color(0.56, 0.57, 0.58, 1), Roughness = 0.1, Metallic = 1}

for i = 0, 59 do
	shapes.Capsule{
		Parent = root,
		Position = Vec3(ALIAS_X + 1.2, 0.005, 2.2 - i * 0.02),
		Rotation = QuatDeg3(0, 0, 90),
		Radius = 0.005,
		Height = 1.6,
		Material = pipe,
		RigidBody = false,
		CastShadows = false,
	}
end

-- corrugated glossy sheet. far away its mips flatten the ridges into a mirror,
-- which the antialiasing can't see
shapes.Box{
	Parent = root,
	Position = Vec3(ALIAS_X + 1.5, 0.01, -3),
	Size = Vec3(3.2, 0.02, 3.2),
	Material = material{
		Color = Color(0.9, 0.9, 0.9, 1),
		Roughness = 0.1,
		Metallic = 1,
		Normal = normal_map("corrugated_height", "4.0"),
	},
	RigidBody = false,
}
-- glossy black spheres with fine bumps, further and further back
local bumpy = material{
	Color = Color(0.04, 0.04, 0.04, 1),
	Roughness = 0.1,
	Metallic = 0,
	Normal = normal_map("fine_bumps_height", "20.0"),
}

for i, z in ipairs{0, -6, -12} do
	shapes.Sphere{
		Parent = root,
		Position = Vec3(ALIAS_X + 4, 0.3, z),
		Radius = 0.3,
		Material = bumpy,
		RigidBody = false,
	}
end
