local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local BonePose = objects.CreateTemplate("bone_pose")
BonePose.Is3D = true

function BonePose:Initialize()
	self.positions = {}
	self.angles = {}
end

function BonePose:GetBoneNames()
	return self.rig and self.rig:GetBoneNames() or {}
end

function BonePose:GetBonePosition(name)
	return self.positions[name] or Vec3(0, 0, 0)
end

function BonePose:GetBoneAngles(name)
	return self.angles[name] or Ang3(0, 0, 0)
end

function BonePose:Apply(name)
	local position, angles = self.positions[name], self.angles[name]

	if not self.rig then return end

	if not (position or angles) then
		self.rig:ClearBone(name)
		return
	end

	local matrix = Matrix44()

	if angles then matrix:SetAngles(angles) end

	if position then matrix:SetTranslation(position.x, position.y, position.z) end

	self.rig:SetBone(name, matrix, "local")
end

local function is_zero(v)
	return v.x == 0 and v.y == 0 and v.z == 0
end

function BonePose:SetBonePosition(name, position)
	self.positions[name] = not is_zero(position) and position:Copy() or nil
	self:Apply(name)

	if self.property_change_listeners then
		objects.NotifyPropertyListeners(self, {var_name = "bone " .. name .. " position"})
	end
end

function BonePose:SetBoneAngles(name, angles)
	self.angles[name] = not is_zero(angles) and Ang3(angles.x, angles.y, angles.z) or nil
	self:Apply(name)

	if self.property_change_listeners then
		objects.NotifyPropertyListeners(self, {var_name = "bone " .. name .. " angles"})
	end
end

function BonePose:ClearBones()
	for name in pairs(self.positions) do
		self:SetBonePosition(name, Vec3(0, 0, 0))
	end

	for name in pairs(self.angles) do
		self:SetBoneAngles(name, Ang3(0, 0, 0))
	end
end

function BonePose:GetDynamicProperties()
	local out = {}

	for _, name in ipairs(self:GetBoneNames()) do
		out[#out + 1] = {
			var_name = "bone " .. name .. " position",
			type = "vec3",
			default = Vec3(0, 0, 0),
			get = function(bone_pose)
				return bone_pose:GetBonePosition(name)
			end,
			set = function(bone_pose, value)
				bone_pose:SetBonePosition(name, value)
			end,
		}
		out[#out + 1] = {
			var_name = "bone " .. name .. " angles",
			type = "ang3",
			default = Ang3(0, 0, 0),
			get = function(bone_pose)
				return bone_pose:GetBoneAngles(name)
			end,
			set = function(bone_pose, value)
				bone_pose:SetBoneAngles(name, value)
			end,
		}
	end

	return out
end

function BonePose:OnSerialize()
	local positions, angles = {}, {}

	for name, v in pairs(self.positions) do
		positions[name] = {v.x, v.y, v.z}
	end

	for name, v in pairs(self.angles) do
		angles[name] = {v.x, v.y, v.z}
	end

	return {positions = positions, angles = angles}
end

function BonePose:OnDeserialize(data)
	for name, v in pairs(data and data.positions or {}) do
		self:SetBonePosition(name, Vec3(v[1], v[2], v[3]))
	end

	for name, v in pairs(data and data.angles or {}) do
		self:SetBoneAngles(name, Ang3(v[1], v[2], v[3]))
	end
end

function BonePose:Update()
	local animator = self.Owner.animator
	local rig = animator and animator.rig

	if rig == self.rig then return end

	self.rig = rig

	if rig then
		for name in pairs(self.positions) do
			self:Apply(name)
		end

		for name in pairs(self.angles) do
			self:Apply(name)
		end
	end

	objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})
end

function BonePose:OnFirstCreated()
	event.AddListener("Update", "bone_pose", function()
		for _, bone_pose in ipairs(BonePose.Instances) do
			bone_pose:Update()
		end
	end)
end

function BonePose:OnLastRemoved()
	event.RemoveListener("Update", "bone_pose")
end

return BonePose:Register()
