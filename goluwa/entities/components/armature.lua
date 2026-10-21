local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local Rig = import("goluwa/render3d/rig.lua")
local META = objects.CreateTemplate("armature")
META.Is3D = true
META.Skeletons = META.Skeletons or {}
local Floats = ffi.typeof("float[?]")

function META.RegisterSkeleton(name, bones)
	local count = #bones
	local names = {}
	local parents = {}
	local index = {}
	local bind_local = Floats(count * 7)
	local inverse_bind = Floats(count * 12)

	for i, bone in ipairs(bones) do
		names[i] = bone[1]
		index[bone[1]] = i - 1
		parents[i] = bone[2] and assert(index[bone[2]], "bone " .. bone[1] .. " comes before its parent") or -1
		bind_local[(i - 1) * 7 + 6] = 1
		inverse_bind[(i - 1) * 12] = 1
		inverse_bind[(i - 1) * 12 + 5] = 1
		inverse_bind[(i - 1) * 12 + 10] = 1
	end

	META.Skeletons[name] = Skeleton.New{
		BoneNames = names,
		Parents = parents,
		BindLocal = bind_local,
		InverseBind = inverse_bind,
	}
end

META:StartStorable()
META:GetSet(
	"Skeleton",
	"",
	{
		callback = "Rebuild",
		get_enums = function()
			local names = {}

			for name in pairs(META.Skeletons) do
				names[#names + 1] = name
			end

			table.sort(names)
			return names
		end,
	}
)
META:EndStorable()

function META:Initialize()
	self.initialized = true
	self:Rebuild()
end

function META:Rebuild()
	if not self.initialized then return end

	if self.rig then self.rig:Remove() end

	self.rig = nil
	self.matrices = {}

	if self.Skeleton ~= "" then
		self.rig = Rig.New(assert(META.Skeletons[self.Skeleton], "unknown skeleton " .. self.Skeleton), {})
	end

	objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})
end

function META:OnRemove()
	if self.rig then self.rig:Remove() end
end

function META:GetRig()
	return self.rig
end

function META:GetBoneNames()
	return self.rig and self.rig:GetBoneNames() or {}
end

function META:SetBone(name, matrix, space)
	self.rig:SetBone(name, matrix, space)
	self.matrices = {}
end

function META:GetBoneMatrix(name)
	local rig = self.rig

	if not rig or not rig.bone_indices[name:lower()] then return nil end

	local matrix = self.matrices[name]

	if not matrix then
		matrix = rig:GetBone(name)
		self.matrices[name] = matrix
	end

	return matrix
end

return META:Register()
