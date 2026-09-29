local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("lua/shapes.lua")
-- probe visibility rays leave hard dark crescents on the spheres
import("goluwa/render3d/ddgi.lua").VISIBILITY_RAYS = 0
local root = Entity.New{Name = "pbr_parameters"}
local COLUMNS = 9
local SPACING = 1.2
local RADIUS = 0.45
-- hemispherical bumps, ridges and scratches as height fields. the normal map is
-- the height's gradient, so the same height can drive roughness too
local shared = [[
	float bumps_height(vec2 uv) {
		vec2 cell = fract(uv * 6.0) - 0.5;
		return sqrt(max(1.0 - dot(cell, cell) / 0.16, 0.0));
	}

	float ridges_height(vec2 uv) {
		return 0.5 + 0.5 * sin(uv.y * 80.0 + sin(uv.x * 6.0) * 2.0);
	}

	float hash12(vec2 p) {
		vec3 p3 = fract(vec3(p.xyx) * 0.1031);
		p3 += dot(p3, p3.yzx + 33.33);
		return fract((p3.x + p3.y) * p3.z);
	}

	// thin grooves along u, one in a few rows
	float scratches_height(vec2 uv) {
		float row = floor(uv.y * 160.0);
		float groove = step(0.8, hash12(vec2(row, 7.0))) * smoothstep(0.5, 0.0, abs(fract(uv.y * 160.0) - 0.5));
		return 1.0 - groove * step(0.3, hash12(vec2(row, floor(uv.x * 4.0))));
	}

	vec4 height_to_normal(float h, float hu, float hv, float strength) {
		return vec4(normalize(vec3((h - hu) * strength, (h - hv) * strength, 1.0)) * 0.5 + 0.5, 1.0);
	}
]]

local function normal_map(height_function, strength)
	return (
		[[
		vec2 e = vec2(1.0 / 1024.0, 0.0);
		float h = %s(uv);
		return height_to_normal(h, %s(uv + e.xy), %s(uv + e.yx), %s);
	]]
	):format(height_function, height_function, height_function, strength)
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

-- a standing panel, a floor tile in front of it reflecting the panel and a sphere on the tile, all with the material
local function swatch(x, mat)
	shapes.Box{
		Parent = root,
		Position = Vec3(x, 1.2, -10.5),
		Size = Vec3(2.4, 2.4, 0.1),
		Material = mat,
		RigidBody = false,
	}
	shapes.Box{
		Parent = root,
		Position = Vec3(x, 0.01, -8.6),
		Size = Vec3(2.4, 0.02, 2.4),
		Material = mat,
		RigidBody = false,
	}
	shapes.Sphere{
		Parent = root,
		Position = Vec3(x, 0.02 + RADIUS, -8.6),
		-- the u seam faces the viewer otherwise
		Rotation = QuatDeg3(0, 180, 0),
		Radius = RADIUS,
		Material = mat,
		RigidBody = false,
	}
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
-- hard metal and dielectric checker with rough and smooth stripes, painted metal
swatch(
	-1.25,
	material{
		Color = Color(0.2, 0.35, 0.8, 1),
		Metallic = "vec2 c = floor(uv * 4.0); return vec4(mod(c.x + c.y, 2.0));",
		Roughness = "return vec4(mix(0.1, 0.7, step(0.5, fract(uv.y * 8.0))));",
	}
)
-- bumps getting steeper across u
swatch(
	1.25,
	material{
		Color = Color(0.8, 0.8, 0.8, 1),
		Roughness = 0.35,
		Metallic = 0,
		Normal = normal_map("bumps_height", "mix(1.0, 40.0, uv.x)"),
	}
)
-- brushed metal, ridges in the normal map and rougher in the troughs
swatch(
	3.75,
	material{
		Color = Color(0.91, 0.92, 0.92, 1),
		Metallic = 1,
		Roughness = "return vec4(mix(0.45, 0.15, ridges_height(uv)));",
		Normal = normal_map("ridges_height", "8.0"),
	}
)
-- scratched copper, the grooves are rough and dielectric grime
swatch(
	6.25,
	material{
		Color = Color(0.95, 0.64, 0.54, 1),
		Metallic = "return vec4(scratches_height(uv));",
		Roughness = "return vec4(mix(0.8, 0.2, scratches_height(uv)));",
		Normal = normal_map("scratches_height", "30.0"),
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
