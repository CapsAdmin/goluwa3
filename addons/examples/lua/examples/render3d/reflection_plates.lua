local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")
local root = Entity.New{Name = "reflection_plates"}
local STATIC = {MotionType = "static"}
local SPACING = 2.4
weather.SetSunDirection(Vec3(0.8, 0.55, -0.25):GetNormalized())
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

	float dimples(vec2 uv, float scale) {
		vec2 p = uv * scale;
		vec2 i = floor(p);
		vec2 f = fract(p);
		float d = 1e9;

		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec2 o = vec2(x, y);
				vec2 r = o + hash22(mod(i + o, scale)) * 0.8 + 0.1 - f;
				d = min(d, dot(r, r));
			}
		}

		return d;
	}

	float dirt(vec2 uv) {
		return smoothstep(0.52, 0.6, fbm(uv, 4.0, 5));
	}

	float bumpy_height(vec2 uv) {
		return dimples(uv, 12.0) * 0.6 + fbm(uv, 48.0, 4) * 0.25 + fbm(uv, 6.0, 3) * 0.4;
	}
]]
local normal = [[
	vec2 e = vec2(1.0 / TEXELS, 0.0);
	float h = bumpy_height(uv);
	float hu = bumpy_height(uv + e.xy);
	float hv = bumpy_height(uv + e.yx);
	return vec4(normalize(vec3((h - hu) * 14.0, (h - hv) * 14.0, 1.0)) * 0.5 + 0.5, 1.0);
]]
local gradient_roughness = "return vec4(uv.x);"

local function plate_material(config)
	config.Shared = shared
	config.Color = config.Color or Color(0.9, 0.9, 0.92, 1)
	config.Metallic = config.Metallic or 1
	return shapes.Material(config)
end

local plates = {
	{name = "clear", config = {Roughness = 0}},
	{name = "rough_0_5", config = {Roughness = 0.5}},
	{name = "normal_clear", config = {Roughness = 0, Normal = normal}},
	{name = "normal_rough_0_5", config = {Roughness = 0.5, Normal = normal}},
	{
		name = "normal_varying",
		config = {Roughness = gradient_roughness, Normal = normal},
	},
	{name = "varying", config = {Roughness = gradient_roughness}},
	{
		name = "dirty",
		config = {
			Color = "return vec4(mix(vec3(0.9, 0.9, 0.92), vec3(0.25, 0.18, 0.12), dirt(uv)), 1.0);",
			Roughness = "return vec4(mix(0.05, 0.9, dirt(uv)));",
			Metallic = "return vec4(1.0 - dirt(uv));",
		},
	},
}

for index, plate in ipairs(plates) do
	shapes.Box{
		Name = "plate_" .. plate.name,
		Parent = root,
		Position = Vec3((index - (#plates + 1) / 2) * SPACING, 1.3, 0),
		Rotation = QuatDeg3(22, 0, 0),
		Size = Vec3(2, 2, 0.06),
		Material = plate_material(plate.config),
		RigidBody = STATIC,
	}
end

shapes.Box{
	Name = "floor",
	Parent = root,
	Position = Vec3(0, -0.5, 4),
	Size = Vec3(40, 1, 40),
	Material = shapes.Material{
		Color = [[
			vec2 cell = floor(uv * 40.0);
			float checker = mod(cell.x + cell.y, 2.0);
			return vec4(vec3(mix(0.05, 0.4, checker)), 1.0);
		]],
		Roughness = 0.7,
		Metallic = 0,
	},
	RigidBody = STATIC,
}
shapes.Box{
	Name = "dark_mat",
	Parent = root,
	Position = Vec3((6.5 - (#plates + 1) / 2) * SPACING, 0.005, 2.5),
	Size = Vec3(SPACING * 2, 0.01, 4.5),
	Material = shapes.Material{Color = Color(0.02, 0.02, 0.02, 1), Roughness = 0.9, Metallic = 0},
	RigidBody = STATIC,
}
local ball_colors = {
	Color(1, 0.1, 0.05, 1),
	Color(0.95, 0.85, 0.1, 1),
	Color(0.1, 0.8, 0.2, 1),
	Color(0.05, 0.4, 1, 1),
	Color(0.6, 0.15, 1, 1),
	Color(1, 0.1, 0.6, 1),
}

for index = 1, #ball_colors do
	shapes.Sphere{
		Name = "ball_" .. index,
		Parent = root,
		Position = Vec3((index - (#ball_colors + 1) / 2) * SPACING, 0.5, 2.2),
		Radius = 0.5,
		Material = shapes.Material{
			Color = ball_colors[index],
			Roughness = 0.5,
			Metallic = 0,
		},
		RigidBody = STATIC,
	}
end
