local Color = import("goluwa/structs/color.lua")
local Material = import("goluwa/render3d/material.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Entity = import("goluwa/ecs/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "heightmap_pom_showcase_scene"
local CUBE_SIZE = Vec3(2.35, 2.35, 2.35)
local CUBE_SUBDIVISIONS = {x = 12, y = 12, z = 12}
local SPHERE_RADIUS = 1.15
local WITNESS_BAR_SIZE = Vec3(0.16, 3.0, 0.16)
local shared = [[
		#define saturate(x) clamp(x, 0.0, 1.0)

		float hash21(vec2 p) {
			p = fract(p * vec2(123.34, 345.45));
			p += dot(p, p + 34.345);
			return fract(p.x * p.y);
		}

		vec2 brick_coords(vec2 uv) {
			vec2 tiled = uv * vec2(5.5, 8.0);
			tiled.x += mod(floor(tiled.y), 2.0) * 0.5;
			return tiled;
		}

		float brick_mask(vec2 uv) {
			vec2 local = fract(brick_coords(uv));
			vec2 dist = abs(local - 0.5);
			float mortar = smoothstep(0.43, 0.49, max(dist.x, dist.y));
			return 1.0 - mortar;
		}

		float height_pattern(vec2 uv) {
			vec2 tiled = brick_coords(uv);
			vec2 cell = floor(tiled);
			vec2 local = fract(tiled);
			vec2 dist = abs(local - 0.5);
			float brick = brick_mask(uv);
			float bevel = 1.0 - smoothstep(0.18, 0.48, max(dist.x, dist.y));
			float chip = hash21(cell * 1.73 + floor(local * 5.0));
			float pits = smoothstep(0.74, 0.98, hash21(cell * 2.41 + floor(local * 9.0)));
			float edge_wear = smoothstep(0.24, 0.48, max(dist.x, dist.y));
			float body_variation = mix(0.82, 1.06, chip);
			float crater = pits * 0.22 * (1.0 - edge_wear);
			return saturate(brick * bevel * body_variation - crater);
		}
]]

local function make_texture(shader)
	return shapes.Texture(shader, shared)
end

local height_texture = make_texture([[return vec4(vec3(height_pattern(uv)), 1.0);]])
local albedo_texture = make_texture([[
		float mask = brick_mask(uv);
		float h = height_pattern(uv);
		vec3 mortar = vec3(0.16, 0.17, 0.18);
		vec3 brick_a = vec3(0.47, 0.19, 0.14);
		vec3 brick_b = vec3(0.62, 0.28, 0.20);
		vec2 cell = floor(brick_coords(uv));
		float blend = hash21(cell * 0.71);
		vec3 brick = mix(brick_a, brick_b, blend);
		brick *= mix(0.72, 1.08, h);
		brick *= mix(0.93, 1.07, hash21(cell * 1.93 + 3.1));
		return vec4(mix(mortar, brick, mask), 1.0);
]])
local normal_texture = make_texture([[
		vec2 eps = vec2(1.0 / 1024.0, 1.0 / 1024.0);
		float hl = height_pattern(uv - vec2(eps.x, 0.0));
		float hr = height_pattern(uv + vec2(eps.x, 0.0));
		float hd = height_pattern(uv - vec2(0.0, eps.y));
		float hu = height_pattern(uv + vec2(0.0, eps.y));
		vec3 n = normalize(vec3((hl - hr) * 4.0, (hd - hu) * 4.0, 1.0));
		return vec4(n * 0.5 + 0.5, 1.0);
]])
local roughness_texture = make_texture([[
		float mask = brick_mask(uv);
		float h = height_pattern(uv);
		float roughness = mix(0.92, 0.58 + (1.0 - h) * 0.22, mask);
		return vec4(vec3(roughness), 1.0);
]])
local witness_material = Material.New()
witness_material:SetColorMultiplier(Color(0.82, 0.9, 0.98, 1.0))
witness_material:SetRoughnessMultiplier(0.18)
witness_material:SetMetallicMultiplier(0.0)

local function make_panel_material(config)
	local material = Material.New()
	material:SetAlbedoTexture(albedo_texture)
	material:SetRoughnessTexture(roughness_texture)
	material:SetNormalTexture(normal_texture)
	material:SetMetallicMultiplier(0.0)
	material:SetRoughnessMultiplier(1.0)

	if config.HeightScale and config.HeightScale > 0 then
		material:SetHeightTexture(height_texture)
		material:SetHeightScale(config.HeightScale)
		material:SetHeightCenter(config.HeightCenter or 0.5)
		material:SetHeightLayers(config.HeightLayers or 24)
		material:SetTessellationFactor(config.TessellationFactor or 12)
	end

	return material
end

local function panel_rotation()
	return Quat():SetAngles(Deg3(0, 0, 0))
end

local function freeze_entity(ent)
	if not ent or not ent.IsValid or not ent:IsValid() then return ent end

	if ent.HasComponent and ent:HasComponent("rigid_body") then
		ent:RemoveComponent("rigid_body")
	end

	ent.PhysicsNoCollision = true
	return ent
end

local function freeze_shape_result(ent)
	return freeze_entity(ent)
end

local function spawn_cube(root, name, position, material)
	local ent = shapes.Box{
		Parent = root,
		Name = name,
		Position = position,
		Rotation = panel_rotation(),
		Size = CUBE_SIZE,
		Subdivisions = CUBE_SUBDIVISIONS,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
	return freeze_shape_result(ent)
end

local function spawn_witness_bar(root, name, position)
	local ent = shapes.Box{
		Parent = root,
		Name = name,
		Position = position,
		Rotation = panel_rotation(),
		Size = WITNESS_BAR_SIZE,
		Material = witness_material,
		Collision = false,
		RigidBody = false,
	}
	return freeze_shape_result(ent)
end

local function spawn_sphere(root, name, position, material)
	local ent = shapes.Sphere{
		Parent = root,
		Name = name,
		Position = position,
		Radius = SPHERE_RADIUS,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
	return freeze_shape_result(ent)
end

local function spawn_light(root)
	local light = Entity.New{
		Parent = root,
		Name = "heightmap_pom_showcase_light",
	}
	light:AddComponent("transform")
	light.transform:SetRotation(Quat():SetAngles(Deg3(42, -28, 0)))
	light:AddComponent(
		"light",
		{
			LightType = "directional",
			Color = Color(1.0, 0.97, 0.92, 1.0),
			Intensity = 1.8,
			CastShadows = false,
		}
	)
	return light
end

local function frame_camera()
	local camera = render3d.GetCamera and render3d.GetCamera()

	if not camera then return end

	camera:SetPosition(Vec3(0, 2.6, 10.5))
	camera:SetAngles(Deg3(0, 0, 0))
	camera:SetFOV(math.rad(75))
	camera:SetNearZ(0.05)
	camera:SetFarZ(2048)
end

local root = Entity.World:Ensure{
	Key = ROOT_KEY,
	Name = ROOT_KEY,
}
root:RemoveChildren()
spawn_light(root)
spawn_sphere(
	root,
	"heightmap_pom_showcase_sphere_flat",
	Vec3(-4.8, 4.8, 0),
	make_panel_material{}
)
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_sphere_flat_witness",
	Vec3(-4.8, 4.8, SPHERE_RADIUS - 0.03)
)
spawn_sphere(
	root,
	"heightmap_pom_showcase_sphere_pom_low",
	Vec3(-1.6, 4.8, 0),
	make_panel_material{HeightScale = 0.04, HeightLayers = 12, TessellationFactor = 8}
)
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_sphere_low_witness",
	Vec3(-1.6, 4.8, SPHERE_RADIUS - 0.03)
)
spawn_sphere(
	root,
	"heightmap_pom_showcase_sphere_pom_mid",
	Vec3(1.6, 4.8, 0),
	make_panel_material{HeightScale = 0.08, HeightLayers = 24, TessellationFactor = 12}
)
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_sphere_mid_witness",
	Vec3(1.6, 4.8, SPHERE_RADIUS - 0.03)
)
spawn_sphere(
	root,
	"heightmap_pom_showcase_sphere_pom_high",
	Vec3(4.8, 4.8, 0),
	make_panel_material{HeightScale = 0.14, HeightLayers = 40, TessellationFactor = 18}
)
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_sphere_high_witness",
	Vec3(4.8, 4.8, SPHERE_RADIUS - 0.03)
)
spawn_cube(root, "heightmap_pom_showcase_flat", Vec3(-4.8, 1.7, 0), make_panel_material{})
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_flat_witness",
	Vec3(-4.8, 1.7, CUBE_SIZE.z * 0.5 - 0.03)
)
spawn_cube(
	root,
	"heightmap_pom_showcase_pom_low",
	Vec3(-1.6, 1.7, 0),
	make_panel_material{HeightScale = 0.04, HeightLayers = 12, TessellationFactor = 8}
)
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_low_witness",
	Vec3(-1.6, 1.7, CUBE_SIZE.z * 0.5 - 0.03)
)
spawn_cube(
	root,
	"heightmap_pom_showcase_pom_mid",
	Vec3(1.6, 1.7, 0),
	make_panel_material{HeightScale = 0.08, HeightLayers = 24, TessellationFactor = 12}
)
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_mid_witness",
	Vec3(1.6, 1.7, CUBE_SIZE.z * 0.5 - 0.03)
)
spawn_cube(
	root,
	"heightmap_pom_showcase_pom_high",
	Vec3(4.8, 1.7, 0),
	make_panel_material{HeightScale = 0.14, HeightLayers = 40, TessellationFactor = 18}
)
spawn_witness_bar(
	root,
	"heightmap_pom_showcase_high_witness",
	Vec3(4.8, 1.7, CUBE_SIZE.z * 0.5 - 0.03)
)
frame_camera()
logn("loaded scene: heightmap_pom_showcase")
