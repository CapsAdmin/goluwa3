local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local water = import("goluwa/render3d/water.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local ROUGHNESS_STEP = 0.05
local NEAR_Z = -14
local FAR_Z = -20000
local PLATE = 10
local PLATE_X = {mirror = -11, glass = 0, water = 11}

if _G.reflection_test then _G.reflection_test.root:Remove() end

local test = {}
_G.reflection_test = test
test.root = Entity.New{Name = "reflection_test"}
test.roughness = 0.1
weather.SetTimeScale(0)
weather.SetSunDirection(Vec3(0.2, 0.55, 0.8):GetNormalized())
render3d.SetOceanEnabled(false)
weather.SetGroundFogVisibility(10 ^ 3.5)

local function material(r, g, b, extra)
	return shapes.Material(table.merge({Color = Color(r, g, b, 1), Roughness = 0.8, Metallic = 0}, extra or {}))
end

local function box(name, pos, size, mat)
	return shapes.Box{
		Name = name,
		Parent = test.root,
		Position = pos,
		Size = size,
		Material = mat,
		Collision = false,
		RigidBody = false,
	}
end

local function grid_wall(name, z, half_width, base, height, spacing, line, panel_mat, line_mat)
	box(name .. "_panel", Vec3(0, base + height / 2, z - line), Vec3(half_width * 2, height, line), panel_mat)

	for x = -half_width, half_width, spacing do
		box(name .. "_v" .. x, Vec3(x, base + height / 2, z), Vec3(line, height, line), line_mat)
	end

	for y = 0, height, spacing do
		box(name .. "_h" .. y, Vec3(0, base + y, z), Vec3(half_width * 2, line, line), line_mat)
	end
end

grid_wall("near", NEAR_Z, 120, 0, 4, 1, 0.08, material(0.02, 0.03, 0.05), material(0.1, 0.8, 0.9))
grid_wall("far", FAR_Z, 60000, 3000, 9000, 1000, 80, material(0.05, 0.02, 0.04), material(1, 0.1, 0.6))
box("glass_floor", Vec3(PLATE_X.glass, -1.2, 0), Vec3(PLATE, 0.2, PLATE), material(0.04, 0.04, 0.05))
box("mirror_floor", Vec3(PLATE_X.mirror, -1.2, 0), Vec3(PLATE, 0.2, PLATE), material(0.04, 0.04, 0.05))

test.mirror_material = material(0.95, 0.95, 1, {Metallic = 1, Roughness = 1})
test.mirror = box("mirror", Vec3(PLATE_X.mirror, -0.1, 0), Vec3(PLATE, 0.2, PLATE), test.mirror_material)
test.glass_material = material(1, 1, 1, {Roughness = 1, Refraction = 1, IndexOfRefraction = 1.5, RefractionThickness = 0.02})
test.glass = box("glass", Vec3(PLATE_X.glass, 0, 0), Vec3(PLATE, 0.02, PLATE), test.glass_material)
test.water = Entity.New{
	Name = "reflection_test_water",
	Parent = test.root,
	transform = {Position = Vec3(PLATE_X.water, 0, 0)},
	water_volume = {
		Size = Vec3(PLATE, 4, PLATE),
		Absorption = water.presets.lake.Absorption:Copy(),
		ParticleScattering = water.presets.lake.ParticleScattering:Copy(),
		WaveHeight = 0,
		Foam = 0,
	},
}
box("pool_floor", Vec3(PLATE_X.water, -3.6, 0), Vec3(PLATE + 0.4, 0.2, PLATE + 0.4), material(0.5, 0.45, 0.35))

local strip_material = material(0.15, 0.3, 0.1)

for i = -16, 16 do
	box("strip" .. i, Vec3(i * 1.1 + 0.3 * math.sin(i * 1.7), 6, 12), Vec3(0.03 + 0.015 * (i % 3), 7, 0.02), strip_material)
end

function test.SetRoughness(roughness)
	test.roughness = math.clamp(roughness, 0, 1)
	test.mirror_material:SetRoughnessMultiplier(test.roughness)
	test.glass_material:SetRoughnessMultiplier(test.roughness)
	test.water.water_volume:SetRoughness(test.roughness * test.roughness)
	logn("roughness ", test.roughness, " (alpha ", test.roughness * test.roughness, ")")
end

event.AddListener("KeyInput", "reflection_test", function(key, press)
	if not press then return end

	if key == "pageup" then
		test.SetRoughness(test.roughness + ROUGHNESS_STEP)
	elseif key == "pagedown" then
		test.SetRoughness(test.roughness - ROUGHNESS_STEP)
	end
end)

commands.Add("reflection_test_roughness=number", test.SetRoughness)
test.views = {
	{name = "all three from above", pos = Vec3(0, 8, 22), target = Vec3(0, -1, -8)},
	{name = "low, grazing", pos = Vec3(0, 2.4, 20), target = Vec3(0, 1.0, -20)},
	{name = "the mirror", pos = Vec3(-11, 2.6, 12), target = Vec3(-11, 1.0, -20)},
	{name = "the glass", pos = Vec3(0, 2.6, 12), target = Vec3(0, 1.0, -20)},
	{name = "the water", pos = Vec3(11, 2.6, 12), target = Vec3(11, 1.0, -20)},
}

function test.GetView(index)
	local view = test.views[index]
	local dir = (view.target - view.pos):GetNormalized()

	return {
		Position = view.pos,
		Rotation = QuatDeg3(math.deg(math.asin(dir.y)), math.deg(math.atan2(-dir.x, -dir.z)), 0),
		FOV = math.rad(70),
	}
end

commands.Add("reflection_test_view=number[0]", function(index)
	if test.view then
		test.view:Remove()
		test.view = nil
	end

	if index == 0 then
		for i, view in ipairs(test.views) do
			logn(i, ": ", view.name)
		end

		return
	end

	test.view = View.New(table.merge({Priority = 100}, test.GetView(index))):Activate()
end)

test.SetRoughness(test.roughness)

function test.Remove()
	event.RemoveListener("KeyInput", "reflection_test")

	if test.view then test.view:Remove() end

	test.root:Remove()
	_G.reflection_test = nil
end

return test
