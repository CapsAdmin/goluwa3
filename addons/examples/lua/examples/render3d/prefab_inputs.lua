local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local prefab = import("goluwa/entities/prefab.lua")
local shapes = import("goluwa/render3d/shapes.lua")
-- a prefab is a tree of entity records plus inputs, each input pushes its value into properties of the nodes it targets
prefab.Register(
	"glow_box",
	{
		inputs = {
			{
				Name = "Size",
				Type = "vec3",
				Default = Vec3(1, 1, 1),
				Targets = {{Node = "root", Component = "model", Property = "ModelOptions", Key = "size"}},
			},
			{
				-- one input, two targets: the color of the light and of the bulb it sits in
				Name = "Glow",
				Type = "color",
				Default = Color(1, 0.6, 0.2, 1),
				Targets = {
					{Node = "bulb", Component = "light_point", Property = "Color"},
					{Node = "bulb", Component = "model", Property = "MaterialConfig", Key = "Color"},
				},
			},
			{
				Name = "Intensity",
				Type = "number",
				Default = 20000,
				Min = 0,
				Targets = {{Node = "bulb", Component = "light_point", Property = "Lumen"}},
			},
		},
		entities = {
			{guid = "root", components = {model = {ModelPath = "models/box.lua"}}},
			{
				guid = "bulb",
				parent = "root",
				properties = {Name = "bulb"},
				components = {
					transform = {Position = Vec3(0, 0.75, 0)},
					model = {ModelPath = "models/sphere.lua", ModelOptions = {radius = 0.2}},
					light_point = {Range = 3000, OcclusionMap = false},
				},
			},
		},
	}
)
shapes.Box{
	Name = "prefab_example_ground",
	Size = Vec3(30, 0.5, 30),
	Position = Vec3(0, -0.25, 0),
	Collision = false,
	RigidBody = false,
}
local instances = {}
local specs = {
	{position = Vec3(-3, 0.5, 0), size = Vec3(1, 1, 1), glow = Color(1, 0.55, 0.2, 1)},
	{position = Vec3(0, 0.75, 0), size = Vec3(1, 1.5, 1), glow = Color(0.3, 0.7, 1, 1)},
	{position = Vec3(3, 0.25, 0), size = Vec3(2, 0.5, 1), glow = Color(0.6, 1, 0.4, 1)},
}

for i, spec in ipairs(specs) do
	local entity = Entity.New{
		Name = "glow_box " .. i,
		prefab = {Path = "glow_box", Inputs = {Size = spec.size, Glow = spec.glow}},
	}
	entity:SetTransient(false)
	entity.transform:SetPosition(spec.position)
	instances[i] = entity
end

local camera = render3d.GetCamera()
camera:SetPosition(Vec3(0, 3, 9))
camera:SetAngles(Deg3(-15, 180, 0))

event.AddListener("Update", "prefab_inputs_example", function()
	local time = system.GetElapsedTime()

	for i, entity in ipairs(instances) do
		entity.prefab:SetInput("Intensity", 20000 * (0.6 + 0.4 * math.sin(time * 2 + i)))
	end
end)
