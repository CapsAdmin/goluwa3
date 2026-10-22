local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local interactives = {}
local DOOR_SCRIPT = [[
local objects = import("goluwa/objects/objects.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local network = import("goluwa/network/network.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("interactive_door")

function META:Initialize()
	self:AddGlobalEvent("Update")
	self.angle = 0
	self.solid = true
	self.pivot = self.Owner:GetNode("pivot")
	self.body = self.Owner:EnsureComponent(
		"rigid_body",
		{
			Shape = CompoundShape.New({
				{Shape = BoxShape.New(Vec3(1, 2.1, 0.08)), Position = Vec3(0.55, 1.05, 0)},
				{Shape = BoxShape.New(Vec3(0.1, 2.1, 0.16)), Position = Vec3(-0.05, 1.05, 0)},
			}),
			MotionType = "static",
		}
	)
end

function META:OnUsed(user)
	if network.HasAuthority() then
		local door = self.Owner:GetPrefab().prefab
		door:SetInput("Open", not door:GetInput("Open"))
	end

	return true
end

function META:OnUpdate(dt)
	local door = self.Owner:GetPrefab().prefab
	local open = door:GetInput("Open")
	local target = open and door:GetInput("Angle") or 0
	self.angle = self.angle + (target - self.angle) * math.min(dt * 5, 1)
	self.pivot.transform:SetRotation(Quat():SetAngles(Deg3(0, self.angle, 0)))
	self.Owner.usable:SetPrompt(open and "close" or "open")

	if self.solid == open then
		self.solid = not open
		self.body:SetCollisionMask(self.solid and -1 or 0)
	end
end

return META:Register()
]]
local LAMP_SCRIPT = [[
local objects = import("goluwa/objects/objects.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("interactive_lamp")

function META:Initialize()
	self:AddGlobalEvent("Update")
	self.light = self.Owner:GetNode("bulb").light_point
	self.level = 1
	self.Owner:EnsureComponent(
		"rigid_body",
		{
			Shape = CompoundShape.New({
				{Shape = BoxShape.New(Vec3(0.4, 1.7, 0.4)), Position = Vec3(0, 0.85, 0)},
			}),
			MotionType = "static",
		}
	)
end

function META:OnUsed(user)
	if network.HasAuthority() then
		local lamp = self.Owner:GetPrefab().prefab
		lamp:SetInput("On", not lamp:GetInput("On"))
	end

	return true
end

function META:OnUpdate(dt)
	local lamp = self.Owner:GetPrefab().prefab
	local on = lamp:GetInput("On")
	self.level = self.level + ((on and 1 or 0) - self.level) * math.min(dt * 8, 1)
	self.light:SetLumen(lamp:GetInput("Lumen") * self.level)
	self.Owner.usable:SetPrompt(on and "turn off" or "turn on")
end

return META:Register()
]]
prefab.Register(
		"interactive_door",
		{
			inputs = {
				{Name = "Open", Type = "boolean", Default = false, Targets = {}},
				{Name = "Angle", Type = "number", Default = 100, Min = 0, Max = 170, Targets = {}},
			},
			entities = {
				{
					guid = "root",
					components = {usable = {Prompt = "open"}, script = {Source = DOOR_SCRIPT}},
				},
				{
					guid = "pivot",
					parent = "root",
					properties = {Name = "pivot"},
					components = {transform = {}},
				},
				{
					guid = "leaf",
					parent = "pivot",
					properties = {Name = "leaf"},
					components = {
						transform = {Position = Vec3(0.55, 1.05, 0)},
						model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(1, 2.1, 0.08)}},
					},
				},
				{
					guid = "post",
					parent = "root",
					properties = {Name = "post"},
					components = {
						transform = {Position = Vec3(-0.05, 1.05, 0)},
						model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(0.1, 2.1, 0.16)}},
					},
				},
			},
		}
	).builtin = true
prefab.Register(
		"interactive_lamp",
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
					components = {usable = {Prompt = "turn off"}, script = {Source = LAMP_SCRIPT}},
				},
				{
					guid = "base",
					parent = "root",
					properties = {Name = "base"},
					components = {
						transform = {Position = Vec3(0, 0.025, 0)},
						model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(0.4, 0.05, 0.4)}},
					},
				},
				{
					guid = "pole",
					parent = "root",
					properties = {Name = "pole"},
					components = {
						transform = {Position = Vec3(0, 0.75, 0)},
						model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(0.06, 1.4, 0.06)}},
					},
				},
				{
					guid = "bulb",
					parent = "root",
					properties = {Name = "bulb"},
					components = {
						transform = {Position = Vec3(0, 1.55, 0)},
						model = {ModelPath = "models/sphere.lua", ModelOptions = {radius = 0.15}},
						light_point = {Range = 3000, OcclusionMap = false},
					},
				},
			},
		}
	).builtin = true
interactives.Names = {"door", "lamp"}

function interactives.GetPrefabName(name)
	return "interactive_" .. name
end

function interactives.Spawn(name, position, yaw)
	return Entity.New{
		Name = name,
		Transient = false,
		transform = {Position = position:Copy(), Rotation = QuatFromAxis(yaw, Vec3(0, 1, 0))},
		prefab = {Path = interactives.GetPrefabName(name)},
		network = SERVER and {} or nil,
	}
end

return interactives
