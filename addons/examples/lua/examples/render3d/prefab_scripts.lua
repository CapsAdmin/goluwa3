local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local prefab = import("goluwa/entities/prefab.lua")
local shapes = import("goluwa/render3d/shapes.lua")
-- walk up to the things and press e. a script is lua that returns the functions it wants called: OnCreate, Update(dt), OnRemove and any On* event such as OnUse.
-- self is the entity the script is on, GetPrefab() is the instance it belongs to and GetNode(id) one of its nodes.
-- state that has to be the same everywhere lives in prefab inputs, only whoever has the authority changes them (network.HasAuthority(), true in a standalone game too) and they replicate, the visuals follow them in Update.
local LAMP_SCRIPT = [[
local BoxShape = import("goluwa/physics/shapes/box.lua")
local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local light
local level = 1

function Entity:OnCreate()
	light = self:GetNode("bulb").light_point
	self:EnsureComponent("rigid_body", {Shape = BoxShape.New(Vec3(0.4, 0.8, 0.4)), MotionType = "static"})
end

function Entity:OnUse(user)
	if network.HasAuthority() then
		local lamp = self:GetPrefab().prefab
		lamp:SetInput("On", not lamp:GetInput("On"))
	end

	return true
end

function Entity:Update(dt)
	local lamp = self:GetPrefab().prefab
	level = level + ((lamp:GetInput("On") and 1 or 0) - level) * math.min(dt * 8, 1)
	light:SetLumen(lamp:GetInput("Lumen") * level)
end
]]
local DOOR_SCRIPT = [[
local BoxShape = import("goluwa/physics/shapes/box.lua")
local network = import("goluwa/network/network.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pivot
local body
local angle = 0
local solid = true

function Entity:OnCreate()
	pivot = self:GetNode("pivot")
	-- the collider stays where the closed door is so the doorway can always be used, it only stops being solid while the door is open
	body = self:EnsureComponent(
		"rigid_body",
		{
			Shape = CompoundShape.New({
				{Shape = BoxShape.New(Vec3(1.2, 2.2, 0.08)), Position = Vec3(0.6, 1.1, 0)},
				{Shape = BoxShape.New(Vec3(0.12, 2.2, 0.18)), Position = Vec3(-0.06, 1.1, 0)},
			}),
			MotionType = "static",
		}
	)
end

function Entity:OnUse(user)
	if network.HasAuthority() then
		local door = self:GetPrefab().prefab
		door:SetInput("Open", not door:GetInput("Open"))
	end

	return true
end

function Entity:Update(dt)
	local door = self:GetPrefab().prefab
	local open = door:GetInput("Open")
	local target = open and door:GetInput("Angle") or 0
	angle = angle + (target - angle) * math.min(dt * 5, 1)
	pivot.transform:SetRotation(Quat():SetAngles(Deg3(0, angle, 0)))

	if solid == open then
		solid = not open
		body:SetCollisionMask(solid and -1 or 0)
	end
end
]]
local DISPENSER_SCRIPT = [[
local BoxShape = import("goluwa/physics/shapes/box.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local network = import("goluwa/network/network.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local last_use = 0

function Entity:OnCreate()
	self:EnsureComponent("rigid_body", {Shape = BoxShape.New(Vec3(0.8, 1, 0.8)), MotionType = "static"})
end

function Entity:OnUse(user)
	if network.HasAuthority() and system.GetTime() - last_use > 0.3 then
		last_use = system.GetTime()
		shapes.Box{
			Name = "dispensed crate",
			Position = self.transform:GetPosition() + Vec3(0, 1.4, 0),
			Size = Vec3(0.35, 0.35, 0.35),
			Material = {Color = Color(math.random(), math.random(), math.random(), 1)},
			RigidBody = {Friction = 0.6},
			Network = network.IsStarted(),
		}
	end

	return true
end
]]
local BEACON_SCRIPT = [[
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local system = import("goluwa/system.lua")
local speed = 1

function Entity:OnCreate()
	self:EnsureComponent("rigid_body", {Shape = SphereShape.New(0.25), MotionType = "static"})
end

local function hue(h)
	h = (h % 1) * 6
	return Color(
		math.clamp(math.abs(h - 3) - 1, 0, 1),
		math.clamp(2 - math.abs(h - 2), 0, 1),
		math.clamp(2 - math.abs(h - 4), 0, 1),
		1
	)
end

function Entity:OnUse(user)
	speed = speed == 1 and 4 or 1
	return true
end

function Entity:Update(dt)
	local time = system.GetTime()
	self.light_point:SetColor(hue(time * 0.1 * speed))
	self.light_point:SetLumen(25000 + 15000 * math.sin(time * 5 * speed))
	self:GetNode("ring").transform:SetRotation(Quat():SetAngles(Deg3(0, time * 90 * speed, 0)))
end
]]
prefab.Register(
	"example_lamp",
	{
		inputs = {
			{Name = "On", Type = "boolean", Default = true, Targets = {}},
			{Name = "Lumen", Type = "number", Default = 20000, Min = 0, Targets = {}},
			{
				Name = "Color",
				Type = "color",
				Default = Color(1, 0.8, 0.5, 1),
				Targets = {
					{Node = "bulb", Component = "light_point", Property = "Color"},
					{Node = "bulb", Component = "model", Property = "MaterialConfig", Key = "Color"},
				},
			},
		},
		entities = {
			{
				guid = "root",
				components = {
					model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(0.4, 0.8, 0.4)}},
					script = {Source = LAMP_SCRIPT},
				},
			},
			{
				guid = "bulb",
				parent = "root",
				properties = {Name = "bulb"},
				components = {
					transform = {Position = Vec3(0, 0.6, 0)},
					model = {ModelPath = "models/sphere.lua", ModelOptions = {radius = 0.18}},
					light_point = {Range = 3000, OcclusionMap = false},
				},
			},
		},
	}
)
prefab.Register(
	"example_door",
	{
		inputs = {
			{Name = "Open", Type = "boolean", Default = false, Targets = {}},
			{Name = "Angle", Type = "number", Default = 100, Min = 0, Max = 170, Targets = {}},
		},
		entities = {
			{guid = "root", components = {script = {Source = DOOR_SCRIPT}}},
			{guid = "pivot", parent = "root", properties = {Name = "pivot"}, components = {transform = {}}},
			{
				guid = "leaf",
				parent = "pivot",
				properties = {Name = "leaf"},
				components = {
					transform = {Position = Vec3(0.6, 1.1, 0)},
					model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(1.2, 2.2, 0.08)}},
				},
			},
			{
				guid = "post",
				parent = "root",
				properties = {Name = "post"},
				components = {
					transform = {Position = Vec3(-0.06, 1.1, 0)},
					model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(0.12, 2.2, 0.18)}},
				},
			},
		},
	}
)
prefab.Register(
	"example_dispenser",
	{
		inputs = {},
		entities = {
			{
				guid = "root",
				components = {
					model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(0.8, 1, 0.8)}},
					script = {Source = DISPENSER_SCRIPT},
				},
			},
		},
	}
)
prefab.Register(
	"example_beacon",
	{
		inputs = {},
		entities = {
			{
				guid = "root",
				components = {
					model = {ModelPath = "models/sphere.lua", ModelOptions = {radius = 0.25}},
					light_point = {Range = 3000, OcclusionMap = false},
					script = {Source = BEACON_SCRIPT},
				},
			},
			{
				guid = "ring",
				parent = "root",
				properties = {Name = "ring"},
				components = {
					transform = {},
					model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(0.9, 0.04, 0.12)}},
				},
			},
		},
	}
)
shapes.Box{
	Name = "prefab_scripts_floor",
	Size = Vec3(30, 0.5, 30),
	Position = Vec3(0, -0.25, 0),
	RigidBody = {MotionType = "static"},
}
local placements = {
	{"example_lamp", Vec3(-3, 0.4, 0)},
	{"example_door", Vec3(-1, 0, 0)},
	{"example_dispenser", Vec3(2, 0.5, 0)},
	{"example_beacon", Vec3(4.5, 1.4, 0)},
}

for _, placement in ipairs(placements) do
	local entity = Entity.New{Name = placement[1], prefab = {Path = placement[1]}}
	entity:SetTransient(false)
	entity.transform:SetPosition(placement[2])
end

local camera = render3d.GetCamera()
camera:SetPosition(Vec3(0.5, 1.7, 5))
camera:SetAngles(Deg3(-5, 180, 0))
PLAYER_RIG.transform:SetPosition(camera:GetPosition():Copy())
PLAYER_RIG.player_input:SyncFromCamera(camera)
