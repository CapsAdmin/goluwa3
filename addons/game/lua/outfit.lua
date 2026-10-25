local prefab = import("goluwa/entities/prefab.lua")
local pvars = import("goluwa/cli/pvars.lua")
local vfs = import("goluwa/vfs.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local outfit_source = import("lua/outfit_source.lua")
local eye_pose = import("lua/eye_pose.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local outfit = {}
outfit.CustomName = "player_outfit"
outfit.DefaultName = "player_outfit_default"
local selected = pvars.Setup2{
	key = "cl_outfit",
	category = "Game",
	group = "Player",
	default = outfit.CustomName,
	help = "prefab used as your player outfit: player_outfit is the editable custom one, player_outfit_default the generated eye, player_outfit_source a source player model",
}
local selected_model = pvars.Setup2{
	key = "cl_outfit_model",
	category = "Game",
	group = "Player",
	default = outfit_source.Model,
	help = "source player model used when cl_outfit is player_outfit_source",
}
local head_camera = pvars.Setup2{
	key = "cl_outfit_head_camera",
	category = "Game",
	group = "Player",
	default = false,
	help = "the view and the aim origin follow the head of a source outfit instead of the eye point of the capsule, within two capsule radii of it",
}
local head_vertical = pvars.Setup2{
	key = "cl_outfit_head_vertical",
	category = "Game",
	group = "Player",
	default = true,
	help = "the head camera follows the vertical movement of the head too (crouching, walking, idle sway), off keeps the height of the capsule eye",
}
local head_smoothing = pvars.Setup2{
	key = "cl_outfit_head_smoothing",
	category = "Game",
	group = "Player",
	default = 0.05,
	min = 0,
	max = 0.5,
	help = "time constant in seconds that smooths the head camera, 0 follows the head exactly",
}
local head_forward = pvars.Setup2{
	key = "cl_outfit_head_forward",
	category = "Game",
	group = "Player",
	default = 0.08,
	min = 0,
	max = 0.3,
	help = "meters the head camera sits in front of the head bone along the view, the bone is the middle of the head and the eyes are in front of it",
}
local head_near = pvars.Setup2{
	key = "cl_outfit_head_near",
	category = "Game",
	group = "Player",
	default = 0.05,
	min = 0.001,
	max = 0.3,
	help = "near plane in meters while the head camera is on, it replaces the normal one so it can be much closer, what is closer than this to the camera is not drawn",
}

function outfit.GetHeadEye()
	return head_forward:Get(), head_near:Get()
end

function outfit.GetHeadCamera()
	return head_camera:Get(), head_vertical:Get(), head_smoothing:Get()
end

function outfit.GetLocalName()
	return selected:Get()
end

function outfit.GetLocalInputs()
	if selected:Get() == outfit_source.Name then
		return {Model = selected_model:Get()}
	end
end

outfit.EyeScript = [=[
local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local aim_pose = import("lua/aim_pose.lua")
local META = objects.CreateTemplate("outfit_eye")
local scratch = Quat(0, 0, 0, 1)

local function place(node, from, to)
	local transform = node.transform
	transform:SetPosition(Vec3((from.m30 + to.m30) * 0.5, (from.m31 + to.m31) * 0.5, (from.m32 + to.m32) * 0.5))
	aim_pose.SetBetween(scratch, 0, 1, 0, to.m30 - from.m30, to.m31 - from.m31, to.m32 - from.m32)
	transform:SetRotation(scratch:Copy())
end

function META:Initialize()
	local prefab = self.Owner:GetParent().prefab
	local nodes = {eye = prefab:GetNode("eye")}
	self.head_visuals = {nodes.eye.visual, prefab:GetNode("iris").visual, prefab:GetNode("pupil").visual}
	self.sides = {}

	for i, name in ipairs({"l", "r"}) do
		for _, part in ipairs({"arm_upper", "arm_lower", "hand", "leg_upper", "leg_lower", "foot"}) do
			nodes[part .. "_" .. name] = prefab:GetNode(part .. "_" .. name)
		end

		self.sides[i] = name
	end

	self.nodes = nodes
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	if not self.player then
		local node = self.Owner:GetParent():GetParent()

		while node:IsValid() and not node.player_avatar do
			node = node:GetParent()
		end

		if not node:IsValid() then return end

		self.player = node
	end

	local player = self.player
	local avatar = player.player_avatar
	local bones = player.procedural_pose:GetBones()
	local nodes = self.nodes
	local neck = bones.neck
	nodes.eye.transform:SetPosition(Vec3(neck.m30, neck.m31, neck.m32))
	nodes.eye.transform:SetRotation(neck:GetRotation())
	if self.head_hidden ~= avatar.first_person then
		self.head_hidden = avatar.first_person

		for _, visual in ipairs(self.head_visuals) do
			visual:SetViewHidden(avatar.first_person)
		end
	end

	for _, name in ipairs(self.sides) do
		local upperarm, forearm, hand = bones["upperarm_" .. name], bones["forearm_" .. name], bones["hand_" .. name]

		place(nodes["arm_upper_" .. name], upperarm, forearm)
		place(nodes["arm_lower_" .. name], forearm, hand)
		nodes["hand_" .. name].transform:SetPosition(Vec3(hand.m30, hand.m31, hand.m32))
		local thigh, calf, foot = bones["thigh_" .. name], bones["calf_" .. name], bones["foot_" .. name]
		place(nodes["leg_upper_" .. name], thigh, calf)
		place(nodes["leg_lower_" .. name], calf, foot)
		nodes["foot_" .. name].transform:SetPosition(Vec3(foot.m30, foot.m31, foot.m32))
		nodes["foot_" .. name].transform:SetRotation(foot:GetRotation())
	end
end

return META:Register()
]=]

function outfit.GetName(owner_id)
	return "outfit_" .. owner_id:gsub("[^%w_%-%. ]", "_")
end

function outfit.Exists(name)
	return prefab.definitions[name] ~= nil or vfs.IsFile(prefab.GetPath(name))
end

function outfit.GetDefault()
	local hue = math.random()
	local limb_material = {Color = Color.FromHSV(hue, 0.55, 0.9), Roughness = 0.5, Metallic = 0}
	local R = eye_pose.EyeRadius
	local entities = {
		{guid = "root", components = {}},
		{
			guid = "eye",
			parent = "root",
			properties = {Name = "eye"},
			components = {
				transform = {},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = R},
					MaterialConfig = {Color = Color(0.95, 0.94, 0.92, 1), Roughness = 0.15, Metallic = 0},
				},
			},
		},
		{
			guid = "iris",
			parent = "eye",
			properties = {Name = "iris"},
			components = {
				transform = {Position = FORWARD * R * 0.88, Scale = Vec3(1, 1, 0.25)},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = R * 0.55},
					MaterialConfig = {Color = Color.FromHSV(hue, 0.8, 0.8), Roughness = 0.2, Metallic = 0},
				},
			},
		},
		{
			guid = "pupil",
			parent = "eye",
			properties = {Name = "pupil"},
			components = {
				transform = {Position = FORWARD * R * 0.94, Scale = Vec3(1, 1, 0.25)},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = R * 0.26},
					MaterialConfig = {Color = Color(0.02, 0.02, 0.02, 1), Roughness = 0.1, Metallic = 0},
				},
			},
		},
		{
			guid = "rig",
			parent = "root",
			properties = {Name = "rig"},
			components = {transform = {}, script = {Source = outfit.EyeScript}},
		},
	}

	for _, side in ipairs({"l", "r"}) do
		local parts = {
			{"arm_upper", eye_pose.ArmLength * 0.5},
			{"arm_lower", eye_pose.ArmLength * 0.5},
			{"leg_upper", eye_pose.LegLength * 0.5},
			{"leg_lower", eye_pose.LegLength * 0.5},
		}

		for _, part in ipairs(parts) do
			entities[#entities + 1] = {
				guid = part[1] .. "_" .. side,
				parent = "root",
				properties = {Name = part[1] .. "_" .. side},
				components = {
					transform = {},
					model = {
						ModelPath = "models/capsule.lua",
						ModelOptions = {radius = eye_pose.LimbRadius, height = part[2] + eye_pose.LimbRadius * 2},
						MaterialConfig = limb_material,
					},
				},
			}
		end

		entities[#entities + 1] = {
			guid = "hand_" .. side,
			parent = "root",
			properties = {Name = "hand_" .. side},
			components = {
				transform = {},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = eye_pose.LimbRadius * 2.2},
					MaterialConfig = limb_material,
				},
			},
		}
		entities[#entities + 1] = {
			guid = "foot_" .. side,
			parent = "root",
			properties = {Name = "foot_" .. side},
			components = {
				transform = {Scale = Vec3(1, 0.6, 1.8)},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = eye_pose.FootHeight * 1.6},
					MaterialConfig = limb_material,
				},
			},
		}
	end

	return {inputs = {}, entities = entities}
end

function outfit.Ensure(name)
	if not outfit.Exists(name) then
		prefab.Register(name, outfit.GetDefault())
		prefab.Save(name)
	end

	prefab.Get(name).local_only = true
end

function outfit.LoadLocal()
	local name = outfit.GetLocalName()
	outfit.Ensure(name)
	return name, outfit.GetLocalInputs()
end

prefab.Register(outfit.DefaultName, outfit.GetDefault()).builtin = true
return outfit
