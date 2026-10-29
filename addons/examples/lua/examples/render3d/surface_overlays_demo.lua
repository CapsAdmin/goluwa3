local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local demo = {}
local COLUMNS = 3
local SPACING = 1.7
local CYCLE = 9
local SHOWN = 6
local STAGGER = 0.35
local KINDS = {
	"crystallize",
	"void_rift",
	"gilded",
	"aegis",
	"radiant",
	"blight",
	"storm",
	"prismatic",
	"runes",
}
test_scene.Reset{sun = {elevation = test_scene.GetNumber("OVERLAYS_SUN", -6), azimuth = 200}}
test_scene.Ground{
	size = 60,
	material = shapes.Material{Color = Color(0.16, 0.16, 0.18, 1), Roughness = 0.85},
}
local key = Entity.New{Name = "overlay_key_light", Parent = test_scene.GetRoot()}
key:AddComponent("transform")
key.transform:SetPosition(Vec3(0, 3.5, 2.5))
local key_light = key:AddComponent("light_point")
key_light:SetColor(Color(0.75, 0.82, 1, 1))
key_light:SetLumen(900)
local MATERIALS = {
	{
		name = "opaque",
		x = -3.2,
		material = shapes.Material{Color = Color(0.55, 0.56, 0.6, 1), Roughness = 0.5, Metallic = 0},
	},
	{
		name = "glass",
		x = 3.2,
		material = shapes.Material{
			Color = Color(1, 1, 1, 1),
			Roughness = 0.02,
			Metallic = 0,
			Refraction = 1,
			IndexOfRefraction = 1.5,
			RefractionThickness = 1.2,
		},
	},
}
local spheres = {}

for _, group in ipairs(MATERIALS) do
	for i, kind in ipairs(KINDS) do
		local column = (i - 1) % COLUMNS
		local row = math.floor((i - 1) / COLUMNS)
		local sphere = shapes.Sphere{
			Name = "overlay_" .. group.name .. "_" .. kind,
			Parent = test_scene.GetRoot(),
			Position = Vec3(group.x + (column - (COLUMNS - 1) / 2) * SPACING, 0.8, -row * SPACING),
			Radius = 0.7,
			Material = group.material,
			RigidBody = false,
			Collision = false,
		}
		spheres[#spheres + 1] = {entity = sphere, kind = kind, shown = false, index = i}
	end
end

local start = system.GetElapsedTime()

event.AddListener("Update", "surface_overlays_demo", function()
	local time = system.GetElapsedTime() - start

	for i, item in ipairs(spheres) do
		local phase = (time - (item.index - 1) * STAGGER) % CYCLE

		if phase < SHOWN then
			if not item.shown then
				item.shown = true
				surface_overlays.Add(item.entity.visual, item.kind, {Duration = SHOWN - phase})
			end
		else
			item.shown = false
		end
	end
end)

return demo
