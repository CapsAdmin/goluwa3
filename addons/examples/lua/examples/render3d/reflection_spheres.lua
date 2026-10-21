local steam = import("goluwa/steam/steam.lua")
local input = import("goluwa/input.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local pvars = import("goluwa/cli/pvars.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")
local info = list.find(steam.GetGames(), function(game)
	return game.appid == 17300
end)
assert(info, "Crysis 1 not found")
local objects = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local W, D, H, T = 16, 20, 10, 0.2

local function matte(r, g, b)
	return shapes.Material{Roughness = 0.9, Metallic = 0, ColorMultiplier = Color(r, g, b, 1)}
end

local function box(name, position, size, material)
	return shapes.Box{
		Name = name,
		Position = position,
		Size = size,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local floor_material = shapes.Material{
	Roughness = 0.7,
	Metallic = 0,
	AlbedoTexture = Material.SRGBTexture(info.game_dir .. "Game/Textures.pak/Textures/Terrain/Detail/plains_grass_green.dds"),
	ColorMultiplier = Color(0.6, 0.9, 0.35, 1),
	BaseTextureTransformU = Vec4(W / 2, 0, 0, 0),
	BaseTextureTransformV = Vec4(0, D / 2, 0, 0),
}
box(
	"reflection_floor",
	Vec3(0, -T / 2, 0),
	Vec3(W + 2 * T, T, D + 2 * T),
	floor_material
)
box(
	"reflection_wall_red",
	Vec3(-W / 2 - T / 2, H / 2, 0),
	Vec3(T, H, D),
	matte(0.85, 0.08, 0.08)
)
box(
	"reflection_wall_blue",
	Vec3(W / 2 + T / 2, H / 2, 0),
	Vec3(T, H, D),
	matte(0.08, 0.15, 0.85)
)
box(
	"reflection_wall_yellow",
	Vec3(0, H / 2, D / 2 + T / 2),
	Vec3(W, H, T),
	matte(0.9, 0.75, 0.1)
)
box(
	"reflection_wall_green",
	Vec3(0, H / 2, -D / 2 - T / 2),
	Vec3(W, H, T),
	matte(0.1, 0.65, 0.2)
)
local sphere_material = shapes.Material{Roughness = 0.15, Metallic = 1, ColorMultiplier = Color(0.95, 0.95, 0.95, 1)}
shapes.Sphere{
	Name = "reflection_sphere",
	Position = Vec3(0, 1.4, 0),
	Radius = 1.2,
	Material = sphere_material,
	Collision = false,
	RigidBody = false,
}
local plane_material = shapes.Material{Roughness = 0, Metallic = 1, ColorMultiplier = Color(1, 1, 1, 1)}
box("reflection_mirror", Vec3(0, 0.01, -3.4), Vec3(3, 0.02, 3), plane_material)
local ROUGHNESS_SPEED = 0.5
local roughness = 0.15
local gi_blend = true
local gi_threshold = 0.5
local end_was_down = false
local last_time = system.GetTime()

event.AddListener("Update", "reflection_sphere_roughness", function()
	local now = system.GetTime()
	local dt = now - last_time
	last_time = now
	local change = (input.IsKeyDown("pageup") and 1 or 0) - (input.IsKeyDown("pagedown") and 1 or 0)
	local end_down = input.IsKeyDown("end")

	if end_down and not end_was_down then
		gi_blend = not gi_blend

		if gi_blend then
			pvars.SetSession("reflection_gi_threshold", gi_threshold)
		else
			gi_threshold = ibl.GetReflectionGIRange()
			pvars.SetSession("reflection_gi_threshold", 1)
		end
	end

	end_was_down = end_down

	if change ~= 0 then
		roughness = math.clamp(roughness + change * ROUGHNESS_SPEED * dt, 0, 1)
		sphere_material:SetRoughnessMultiplier(roughness)
		plane_material:SetRoughnessMultiplier(roughness)
	end
end)

event.AddListener("Draw2D", "reflection_sphere_roughness_text", function()
	debug_draw.DrawTextBlock(
		{
			string.format("roughness %.2f", roughness),
			"pageup / pagedown to change",
			gi_blend and
			string.format("gi blend from roughness %.2f (end to toggle)", (ibl.GetReflectionGIRange())) or
			string.format(
				"gi blend off, traced at every roughness (end to turn it back on at %.2f)",
				gi_threshold
			),
		},
		16,
		16,
		{title_color = Color(1, 1, 1, 1), text_color = Color(0.8, 0.8, 0.85, 1)}
	)
end)

local kinds = {
	"Bushes/RoundLeafBush/Round_Leaf_Bush_med_bright_green.cgf",
	"Bushes/RoundLeafBush/Round_Leaf_Bush_big_bright_green.cgf",
	"Bushes/RoundLeafBush/Round_Leaf_Bush_med_yellow.cgf",
	"Bushes/TallBush/Tall_Bush_a.cgf",
	"Bushes/TallBush/Tall_Bush_b.cgf",
	"Bushes/GreenFernBush/Green_Fern_Bush_a.cgf",
	"Bushes/GreenFernBush/Green_Fern_Bush_c.cgf",
	"Plants/big_leave_plant/big_leave_plant_med_a.cgf",
	"Plants/big_leave_plant/big_leave_plant_med_flower_a.cgf",
	"Trees/Palm_Tree/Palm_Tree_large_a.cgf",
	"Trees/Palm_Tree/Palm_Tree_large_c.cgf",
}
local COUNT = 70
local golden = math.pi * (3 - math.sqrt(5))
local grass_kinds = {
	"Plants/jungle_grass/junglegrass_big_a.cgf",
	"Plants/jungle_grass/junglegrass_big_b.cgf",
	"Plants/jungle_grass/junglegrass_med_a.cgf",
	"Plants/jungle_grass/junglegrass_med_b.cgf",
	"Plants/jungle_grass/junglegrass_patch_a.cgf",
}
local GRASS_COUNT = 220

for i = 1, GRASS_COUNT do
	local x = ((i * 0.7548776662) % 1 - 0.5) * (W - 1)
	local z = ((i * 0.5698402910) % 1 - 0.5) * (D - 1)

	if x * x + z * z > 2.2 * 2.2 and not (z < 0 and math.abs(x) < 1.5) then
		local ent = Entity.New{Name = "reflection_grass_" .. i, Parent = Entity.World}
		local transform = ent:AddComponent("transform")
		transform:SetPosition(Vec3(x, 0, z))
		transform:SetRotation(QuatDeg3(0, i * 137, 0))
		ent:AddComponent("visual")
		ent.visual:SetModelPath(objects .. grass_kinds[i % #grass_kinds + 1])
	end
end

for i = 1, COUNT do
	local angle = i * golden
	local distance = 3 + 4.5 * ((i * 0.618034) % 1)
	local x, z = math.cos(angle) * distance, math.sin(angle) * distance

	if not (z < 0 and math.abs(x) < 1.8) then
		local ent = Entity.New{Name = "reflection_plant_" .. i, Parent = Entity.World}
		local transform = ent:AddComponent("transform")
		transform:SetPosition(Vec3(x, 0, z))
		transform:SetRotation(QuatDeg3(0, i * 67, 0))
		ent:AddComponent("visual")
		ent.visual:SetModelPath(objects .. kinds[i % #kinds + 1])
	end
end

weather.SetSunDirection(Vec3(0.35, 0.8, 0.25):GetNormalized())

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 2.2, -7))
	cam:SetAngles(Deg3(0, 180, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.player_movement:SetEyePosition(cam:GetPosition())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
