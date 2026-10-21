local prefab = import("goluwa/entities/prefab.lua")
local pvars = import("goluwa/cli/pvars.lua")
local vfs = import("goluwa/vfs.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local UNIT = import("goluwa/source_engine/units.lua").meters
local outfit = {}
outfit.EyeRadius = 16 * UNIT
outfit.EyeHeight = 64 * UNIT
outfit.CrouchEyeHeight = 28 * UNIT
outfit.ArmLength = 50 * UNIT
outfit.LegLength = 68 * UNIT
outfit.FootHeight = 2.5 * UNIT
outfit.FootSink = 1 * UNIT
outfit.GroundBound = 12 * UNIT
outfit.LimbRadius = 1.5 * UNIT
outfit.DefaultName = "player_outfit"
local selected = pvars.Setup2{
	key = "cl_outfit",
	category = "Game",
	group = "Player",
	default = outfit.DefaultName,
	help = "prefab used as your player outfit, player_outfit_source is the gmod player model",
}

function outfit.GetLocalName()
	return selected:Get()
end

outfit.EyeScript = [=[
local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics.lua")
local UP = Vec3(0, 1, 0)
local DOWN = Vec3(0, -1, 0)
local STEP_TIME = 0.2
local STEP_LIFT = 4 * UNIT
local GRIPS = {
	weapon_pistol = {right = Vec3(0, -0.07, -0.16)},
	weapon_physgun = {right = Vec3(0, -0.09, -0.16), left = Vec3(0, -0.07, -0.38)},
	weapon_camera = {right = Vec3(0.11, -0.01, -0.22), left = Vec3(-0.11, -0.01, -0.22)},
}
local DEFAULT_GRIPS = {right = Vec3(0, 0, 0)}
local LIMB_PARTS = {"arm_upper", "arm_lower", "hand"}
local META = objects.CreateTemplate("outfit_eye")
local identity = Quat(0, 0, 0, 1)
local zero = Vec3(0, 0, 0)

local function rotation_between(from, to)
	local axis = from:GetCross(to)
	local length = axis:GetLength()
	local dot = from:Dot(to)

	if length < 1e-6 then
		if dot > 0 then return Quat(0, 0, 0, 1) end

		axis = from:GetCross(math.abs(from.x) < 0.9 and Vec3(1, 0, 0) or UP)
		return QuatFromAxis(math.pi, axis:GetNormalized())
	end

	return QuatFromAxis(math.atan2(length, dot), axis / length)
end

local function solve(root, target, length_a, length_b, pole)
	local delta = target - root
	local length = delta:GetLength()
	local direction = length > 1e-5 and delta / length or Vec3(0, -1, 0)
	local dist = math.clamp(length, 1e-3, (length_a + length_b) * 0.999)
	local along = (length_a * length_a - length_b * length_b + dist * dist) / (2 * dist)
	local height = math.sqrt(math.max(length_a * length_a - along * along, 0))
	local bend = (pole - direction * pole:Dot(direction)):GetNormalized()
	return root + direction * along + bend * height, root + direction * dist
end

local function place(node, from, to)
	local transform = node.transform
	transform:SetPosition((from + to) * 0.5)
	transform:SetRotation(rotation_between(UP, (to - from):GetNormalized()))
end

local function ground_foot(foot, player)
	local plane = foot.y - FOOT_HEIGHT
	local hit = physics.instance and physics.RayCast(Vec3(foot.x, plane + GROUND_BOUND, foot.z), DOWN, GROUND_BOUND * 2, player)
	foot.y = (hit and hit.position.y or plane) + FOOT_HEIGHT - FOOT_SINK
	return foot
end

function META:Initialize()
	local prefab = self.Owner:GetParent().prefab
	local nodes = {eye = prefab:GetNode("eye")}
	self.sides = {}

	for i, name in ipairs({"l", "r"}) do
		for _, part in ipairs({"arm_upper", "arm_lower", "hand", "leg_upper", "leg_lower", "foot"}) do
			nodes[part .. "_" .. name] = prefab:GetNode(part .. "_" .. name)
		end

		self.sides[i] = {name = name, sign = i == 1 and -1 or 1}
	end

	self.nodes = nodes
	self.velocity = Vec3(0, 0, 0)
	self.roll = 0
	self.phase = 0
	self:AddGlobalEvent("Update")
end

function META:OnRemove()
	if self.player and self.player:IsValid() then
		self.player.player_avatar:SetOutfitFirstPersonVisible(false)
	end
end

function META:OnUpdate(dt)
	if dt <= 0 then return end

	local instance = self.Owner:GetParent()

	if not self.player then
		local node = instance:GetParent()

		while node:IsValid() and not node.player_avatar do
			node = node:GetParent()
		end

		if node:IsValid() then
			self.player = node
			node.player_avatar:SetOutfitFirstPersonVisible(true)
		end
	end

	local player = self.player
	local avatar = player and player.player_avatar
	local pose = player and player.character_pose
	local view = pose and pose.pitch or identity
	local crouch = pose and pose.crouch_alpha or 0
	local velocity = zero
	local grounded = true
	local grips
	local hide_arms = false
	local weapon_origin

	if player then
		local transform = player.transform
		local _, render_rotation = transform:GetRenderPositionRotation()
		local body = player.rigid_body
		velocity = (render_rotation or transform:GetRotation()):GetConjugated():VecMul(body and body:GetVelocity() or transform:GetRenderVelocity())
		grounded = not body or body:GetGrounded()
		local weapon = avatar.armature and player.weapon_holder and player.weapon_holder:GetActiveWeapon()

		if weapon then
			grips = GRIPS[weapon.prefab.Path] or DEFAULT_GRIPS
			local bone = avatar.armature:GetBoneMatrix("grip_r")
			weapon_origin = Vec3(bone.m30, bone.m31, bone.m32)
			hide_arms = avatar.first_person and weapon.weapon:IsHeldAtEye()
		end
	end

	local smoothed = self.velocity
	smoothed = smoothed + (Vec3(velocity.x, 0, velocity.z) - smoothed) * math.min(dt * 6, 1)
	self.velocity = smoothed
	local speed = smoothed:GetLength()
	self.roll = self.roll + (math.clamp(-smoothed.x * 0.12, -0.6, 0.6) - self.roll) * math.min(dt * 6, 1)
	self.phase = self.phase + dt * speed * 1.5
	local look = view:GetForward()
	local lean = (look + smoothed * 0.05):GetNormalized()
	local rotation = QuatFromAxis(self.roll, lean) * rotation_between(look, lean) * view
	local pupil = Vec3(0, math.lerp(crouch, EYE_HEIGHT, CROUCH_EYE_HEIGHT), 0)
	local center = pupil - lean * EYE_RADIUS
	local nodes = self.nodes
	nodes.eye.transform:SetPosition(center)
	nodes.eye.transform:SetRotation(rotation)
	local world = instance.transform:GetWorldMatrix()
	local world_inverse = instance.transform:GetWorldMatrixInverse()
	local move_dir = speed > 0.1 and smoothed / speed or zero
	local knee_pole = Vec3(lean.x, 0, lean.z)
	local foot_yaw = QuatFromAxis(math.atan2(-lean.x, -lean.z), UP)
	local step_duration = math.max(0.1, 0.22 - speed * 0.015)
	local lead = smoothed * (step_duration * 0.5)
	local trigger = 0.35 * EYE_RADIUS + lead:GetLength() * 1.6
	local swing_amount = math.min(speed / 3, 1) * ARM_LENGTH * 0.7

	if knee_pole:GetLength() < 1e-3 then knee_pole = Vec3(0, 0, -1) end

	for i = 1, 2 do
		local side = self.sides[i]
		local sign = side.sign
		local name = side.name
		local shoulder = center + rotation:VecMul(Vec3(sign * 0.8 * EYE_RADIUS, 0.2 * EYE_RADIUS, 0.56 * EYE_RADIUS))
		local hip = center + rotation:VecMul(Vec3(sign * 0.4 * EYE_RADIUS, -0.75 * EYE_RADIUS, 0.52 * EYE_RADIUS))
		local hang = (rotation:VecMul(Vec3(sign * 0.7, -0.5, 0.3)) + Vec3(sign * 0.35, -0.9, 0.1)):GetNormalized()
		local target
		local follow = 14
		local grip = grips and (sign == 1 and grips.right or grips.left)

		if grip then
			target = weapon_origin + view:VecMul(grip)
			follow = 40
		else
			target = shoulder + hang * (ARM_LENGTH * 0.85) + move_dir * (math.sin(self.phase) * -sign * swing_amount)
		end

		side.hand = side.hand and side.hand + (target - side.hand) * math.min(dt * follow, 1) or target
		local elbow, hand = solve(shoulder, side.hand, ARM_LENGTH * 0.5, ARM_LENGTH * 0.5, rotation:VecMul(Vec3(sign * 0.7, -0.2, 0.7)))
		if side.arms_hidden ~= hide_arms then
			side.arms_hidden = hide_arms

			for _, part in ipairs(LIMB_PARTS) do
				nodes[part .. "_" .. name].visibility:SetVisible(not hide_arms)
			end
		end

		place(nodes["arm_upper_" .. name], shoulder, elbow)
		place(nodes["arm_lower_" .. name], elbow, hand)
		nodes["hand_" .. name].transform:SetPosition(hand)
		local home_local = Vec3(sign * 0.55 * EYE_RADIUS, FOOT_HEIGHT, 0.2 * EYE_RADIUS)
		local home = world:TransformVector(home_local)
		local target_foot = world:TransformVector(home_local + lead)
		local foot

		if not grounded then
			side.planted = world:TransformVector(home_local - smoothed * 0.08)
			side.step_time = nil
			foot = side.planted
		elseif not side.planted or (side.planted - home):GetLength() > LEG_LENGTH * 2 then
			side.planted = ground_foot(target_foot, player)
			side.step_time = nil
			foot = side.planted
		elseif side.step_time then
			side.step_time = side.step_time + dt / step_duration

			if side.step_time >= 1 then
				side.planted = ground_foot(target_foot, player)
				side.step_time = nil
				foot = side.planted
			else
				ground_foot(target_foot, player)
				local t = side.step_time * side.step_time * (3 - 2 * side.step_time)
				foot = side.step_from + (target_foot - side.step_from) * t
				foot.y = foot.y + math.sin(side.step_time * math.pi) * STEP_LIFT
			end
		else
			foot = side.planted
			local gap = math.sqrt((foot.x - target_foot.x) ^ 2 + (foot.z - target_foot.z) ^ 2)
			local other = self.sides[3 - i]

			if gap > trigger and (not other.step_time or gap > trigger * 1.5) then
				side.step_from = foot
				side.step_time = 0
			end
		end

		local knee, ankle = solve(hip, world_inverse:TransformVector(foot), LEG_LENGTH * 0.5, LEG_LENGTH * 0.5, knee_pole)
		place(nodes["leg_upper_" .. name], hip, knee)
		place(nodes["leg_lower_" .. name], knee, ankle)
		nodes["foot_" .. name].transform:SetPosition(ankle)
		nodes["foot_" .. name].transform:SetRotation(foot_yaw)
	end
end

return META:Register()
]=]

function outfit.GetEyeScript()
	return string.format(
		"local UNIT = %.9g\nlocal EYE_RADIUS = %.9g\nlocal EYE_HEIGHT = %.9g\nlocal CROUCH_EYE_HEIGHT = %.9g\nlocal ARM_LENGTH = %.9g\nlocal LEG_LENGTH = %.9g\nlocal FOOT_HEIGHT = %.9g\nlocal FOOT_SINK = %.9g\nlocal GROUND_BOUND = %.9g\n",
		UNIT,
		outfit.EyeRadius,
		outfit.EyeHeight,
		outfit.CrouchEyeHeight,
		outfit.ArmLength,
		outfit.LegLength,
		outfit.FootHeight,
		outfit.FootSink,
		outfit.GroundBound
	) .. outfit.EyeScript
end

function outfit.GetName(owner_id)
	return "outfit_" .. owner_id:gsub("[^%w_%-%. ]", "_")
end

function outfit.Exists(name)
	return prefab.definitions[name] ~= nil or vfs.IsFile(prefab.GetPath(name))
end

function outfit.GetDefault()
	local hue = math.random()
	local limb_material = {Color = Color.FromHSV(hue, 0.55, 0.9), Roughness = 0.5, Metallic = 0}
	local R = outfit.EyeRadius
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
			components = {transform = {}, script = {Source = outfit.GetEyeScript()}},
		},
	}

	for _, side in ipairs({"l", "r"}) do
		local parts = {
			{"arm_upper", outfit.ArmLength * 0.5},
			{"arm_lower", outfit.ArmLength * 0.5},
			{"leg_upper", outfit.LegLength * 0.5},
			{"leg_lower", outfit.LegLength * 0.5},
		}

		for _, part in ipairs(parts) do
			entities[#entities + 1] = {
				guid = part[1] .. "_" .. side,
				parent = "root",
				properties = {Name = part[1] .. "_" .. side},
				components = {
					transform = {},
					visibility = {},
					model = {
						ModelPath = "models/capsule.lua",
						ModelOptions = {radius = outfit.LimbRadius, height = part[2] + outfit.LimbRadius * 2},
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
				visibility = {},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = outfit.LimbRadius * 2.2},
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
					ModelOptions = {radius = outfit.FootHeight * 1.6},
					MaterialConfig = limb_material,
				},
			},
		}
	end

	return {inputs = {}, entities = entities}
end

function outfit.LoadLocal()
	local name = outfit.GetLocalName()

	if not outfit.Exists(name) then
		prefab.Register(name, outfit.GetDefault())
		prefab.Save(name)
	end

	prefab.Get(name).local_only = true
	return name
end

return outfit
