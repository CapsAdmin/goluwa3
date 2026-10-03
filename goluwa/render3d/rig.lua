local ffi = require("ffi")
local skinning = import("goluwa/render3d/skinning.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
-- A rig is a skeleton made visible: it takes a pose, bones moved on top of it and the flex (facial expression)
-- controllers of the model, and skins the vertex arrays it was made for with them on the gpu. none of its interface
-- needs ffi, bones and flexes are named by strings and bone matrices are Matrix44
--   Rig.New(skeleton, parts)   parts is a list of {bind_vertex_buffer, vertex_buffer, skin}: a vertex array of the model,
--                              the vertex array to write the skinned vertices to and the skin (bone weights, flexes)
--   rig:SetPose(pose)          a Pose of the skeleton
--   rig:SetBone(name, matrix, space)  "local" applies the matrix in the space of the bone, on top of the pose.
--                              "model" replaces the matrix of the bone in model space. children follow either
--   rig:GetBone(name)          the final model space Matrix44 of a bone
--   rig:SetFlex(name, value), rig:GetFlex(name), rig:GetFlexNames(), rig:GetFlexRange(name)
--   rig:Update()               computes what changed and queues the skinning
local Rig = {}
Rig.__index = Rig

-- the weight a flex has at a controller weight: zero up to target0 and past target3, one between target1 and target2
local function flex_ramp(weight, target0, target1, target2, target3)
	if weight <= target0 or weight >= target3 then return 0 end

	if weight < target1 then return (weight - target0) / (target1 - target0) end

	if weight <= target2 then return 1 end

	return (target3 - weight) / (target3 - target2)
end

-- Matrix44 has the translation in its last row and transforms row vectors, the matrices of a rig are 3x4 and row major
-- with the translation in the last column
local function write_matrix(m, out, o)
	out[o], out[o + 1], out[o + 2], out[o + 3] = m.m00, m.m10, m.m20, m.m30
	out[o + 4], out[o + 5], out[o + 6], out[o + 7] = m.m01, m.m11, m.m21, m.m31
	out[o + 8], out[o + 9], out[o + 10], out[o + 11] = m.m02, m.m12, m.m22, m.m32
end

function Rig.New(skeleton, parts)
	local self = setmetatable({}, Rig)
	self.skeleton = skeleton
	self.pose = skeleton:NewPose()
	self.matrices = skeleton:CreateMatrices()
	self.world = skeleton:CreateMatrices()
	self.overrides = skeleton:CreateBoneOverrides()
	self.bone_indices = {}
	self.version = 0
	self.dirty = true
	self.needs_skin = false
	self.removed = false

	for i, name in ipairs(skeleton.BoneNames) do
		self.bone_indices[name:lower()] = i - 1
	end

	self.skinned = {}
	local weight_count = 0

	for _, part in ipairs(parts) do
		local count = part.vertex_buffer:GetVertexCount()
		local skinned = {
			vertex_buffer = part.vertex_buffer,
			bind_vertex_buffer = part.bind_vertex_buffer,
			count = count,
			bind_address = part.bind_vertex_buffer:GetBuffer():GetDeviceAddress(),
			destination_address = part.vertex_buffer:GetBuffer():GetDeviceAddress(),
			bones_address = skinning.GetBoneBuffer(part.skin, count):GetDeviceAddress(),
			skin = part.skin,
		}
		local morph = skeleton.Flex and skinning.GetMorphData(part.skin, count)

		if morph then
			skinned.morph = morph
			skinned.morph_active = false
			skinned.weight_offset = weight_count
			weight_count = weight_count + morph.entry_count * 2
		end

		self.skinned[#self.skinned + 1] = skinned
	end

	self.morph_weights = ffi.new("float[?]", math.max(weight_count, 1))
	self.morph_weight_count = weight_count
	local flex = skeleton.Flex

	if flex then
		self.flex_indices = {}
		self.flex_controllers = ffi.new("float[?]", #flex.ControllerNames)
		self.flex_descriptors = ffi.new("float[?]", flex.DescCount)

		for i, name in ipairs(flex.ControllerNames) do
			self.flex_indices[name] = i - 1
		end

		-- the rules of a model give some flexes a weight even with every controller at zero
		self.flex_dirty = true
	end

	return self
end

function Rig:Remove()
	self.removed = true
end

function Rig:SetPose(pose)
	self.pose:Copy(pose)
	self.dirty = true
end

do
	local function get_index(self, name)
		return self.bone_indices[name:lower()] or error("unknown bone " .. name, 3)
	end

	local function set_flag(overrides, flags, index, on)
		local was = overrides.local_set[index] ~= 0 or overrides.model_set[index] ~= 0
		flags[index] = on and 1 or 0
		local now = overrides.local_set[index] ~= 0 or overrides.model_set[index] ~= 0
		overrides.count = overrides.count + (now and 1 or 0) - (was and 1 or 0)
	end

	function Rig:GetBoneNames()
		return self.skeleton.BoneNames
	end

	function Rig:SetBone(name, matrix, space)
		local index = get_index(self, name)
		local overrides = self.overrides

		if space == "local" then
			write_matrix(matrix, overrides.local_data, index * 12)
			set_flag(overrides, overrides.local_set, index, true)
		elseif space == "model" then
			write_matrix(matrix, overrides.model_data, index * 12)
			set_flag(overrides, overrides.model_set, index, true)
		else
			error("space is \"local\" or \"model\", got " .. tostring(space), 2)
		end

		self.dirty = true
	end

	function Rig:ClearBone(name)
		local index = get_index(self, name)
		local overrides = self.overrides
		set_flag(overrides, overrides.local_set, index, false)
		set_flag(overrides, overrides.model_set, index, false)
		self.dirty = true
	end

	function Rig:ClearBones()
		local overrides = self.overrides
		ffi.fill(overrides.local_set, self.skeleton.BoneCount)
		ffi.fill(overrides.model_set, self.skeleton.BoneCount)
		overrides.count = 0
		self.dirty = true
	end

	function Rig:GetBone(name)
		local index = get_index(self, name)

		if self.dirty then self:Compute() end

		local w = self.world
		local o = index * 12
		local m = Matrix44()
		m.m00, m.m10, m.m20, m.m30 = w[o], w[o + 1], w[o + 2], w[o + 3]
		m.m01, m.m11, m.m21, m.m31 = w[o + 4], w[o + 5], w[o + 6], w[o + 7]
		m.m02, m.m12, m.m22, m.m32 = w[o + 8], w[o + 9], w[o + 10], w[o + 11]
		return m
	end
end

function Rig:GetFlexNames()
	return self.skeleton.Flex and self.skeleton.Flex.ControllerNames or {}
end

function Rig:GetFlexRange(name)
	local flex = self.skeleton.Flex
	local index = self.flex_indices[name] or error("unknown flex " .. name, 2)
	return flex.ControllerMin[index + 1], flex.ControllerMax[index + 1]
end

function Rig:GetFlex(name)
	return self.flex_controllers[self.flex_indices[name] or
	error("unknown flex " .. name, 2)]
end

function Rig:SetFlex(name, value)
	self.flex_controllers[self.flex_indices[name] or
	error("unknown flex " .. name, 2)] = value
	self.flex_dirty = true
	self.dirty = true
end

-- the weights of the flex descriptors from the rules of the model, then the weights of every morph entry of the model
function Rig:ComputeFlex()
	self.flex_dirty = false
	self.skeleton.Flex:Compute(self.flex_controllers, self.flex_descriptors)
	local descriptors = self.flex_descriptors
	local weights = self.morph_weights

	for _, skinned in ipairs(self.skinned) do
		local morph = skinned.morph

		if morph then
			local active = false
			local o = skinned.weight_offset

			for i, entry in ipairs(skinned.skin.Flexes) do
				local t = entry.Targets
				local w1 = flex_ramp(descriptors[entry.Desc], t[1], t[2], t[3], t[4])
				-- an entry without a pair has the same weight on both sides
				local w2 = entry.Pair ~= 0 and
					flex_ramp(descriptors[entry.Pair], t[1], t[2], t[3], t[4]) or
					w1
				weights[o + i * 2 - 2] = w1
				weights[o + i * 2 - 1] = w2

				if w1 ~= 0 or w2 ~= 0 then active = true end
			end

			skinned.morph_active = active
		end
	end
end

function Rig:Compute()
	if self.flex_dirty then self:ComputeFlex() end

	self.skeleton:ComputeSkinMatrices(
		self.pose.data,
		self.matrices,
		self.world,
		self.overrides.count > 0 and self.overrides or nil
	)
	self.dirty = false
	self.needs_skin = true
end

-- skinning once more with what was computed last, for when only the vertices need to be rewritten
function Rig:Skin()
	self.needs_skin = false
	self.version = self.version + 1
	skinning.Queue(self)
end

function Rig:Update()
	if self.dirty then self:Compute() end

	if self.needs_skin then self:Skin() end
end

return Rig
