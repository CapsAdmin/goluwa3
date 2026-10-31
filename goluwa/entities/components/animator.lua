local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local AABB = import("goluwa/structs/aabb.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local Rig = import("goluwa/render3d/rig.lua")
local Animator = objects.CreateTemplate("animator")
Animator.Is3D = true
local BOUNDS_MARGIN = 0.5
local MODEL_BOUNDS_MARGIN = 0.1
local SYNC_SNAP = 0.25
local SYNC_FOLLOW = 10
Animator.LOD_NEAR = 15
Animator.LOD_FAR = 80
Animator.LOD_MIN_RATE = 5
Animator.LOD_SETTLE_INTERVAL = 0.04

function Animator.GetUpdateInterval(distance)
	local t = math.clamp((distance - Animator.LOD_NEAR) / (Animator.LOD_FAR - Animator.LOD_NEAR), 0, 1)
	return t / Animator.LOD_MIN_RATE
end

Animator:StartStorable()
Animator:GetSet(
	"Sequence",
	"",
	{
		get_enums = function(self)
			return self:GetSequenceNames()
		end,
	}
)
Animator:GetSet("Playing", true)
Animator:GetSet("Speed", 1)
Animator:GetSet("Loop", true)
Animator:GetSet("BlendTime", 0.2)
Animator:GetSet(
	"PoseParameter",
	"",
	{
		get_enums = function(self)
			return self:GetPoseParameterNames()
		end,
	}
)
Animator:GetSet("PoseParameterValue", 0)
Animator:EndStorable()
Animator:GetSet("ViewHiddenBones", {})

function Animator:Initialize()
	self.targets = {}
	self.time = 0
	self.pose_parameters = self.pose_parameters or {}
	self.dirty = true
	self.phase = math.random()
end

function Animator:GetSequenceNames()
	local names = {""}

	if self.skeleton then
		for _, clip in ipairs(self.skeleton.Clips) do
			names[#names + 1] = clip.Name
		end
	end

	return names
end

function Animator:SetSequence(name)
	objects.CommitProperty(self, "Sequence", name)
	self.clip_dirty = true
end

function Animator:SetPlaying(playing)
	objects.CommitProperty(self, "Playing", playing)
	self.dirty = true
end

function Animator:Restart()
	self.time = 0
	self.dirty = true
end

function Animator:SetTime(seconds)
	self.time = seconds
	self.dirty = true
end

function Animator:GetTime()
	return self.time
end

function Animator:GetPoseParameterNames()
	local names = {""}

	if self.skeleton then
		for _, name in ipairs(self.skeleton.PoseParameterNames) do
			names[#names + 1] = name
		end
	end

	return names
end

function Animator:SetPoseParameterByName(name, value)
	self.pose_parameters = self.pose_parameters or {}
	self.pose_parameters[name] = value
	self.dirty = true
end

function Animator:GetPoseParameterByName(name)
	return self.pose_parameters[name] or 0
end

function Animator:SetPoseParameter(name)
	objects.CommitProperty(self, "PoseParameter", name)
	self.pose_parameters = self.pose_parameters or {}
	self.PoseParameterValue = self.pose_parameters[name] or 0
end

function Animator:SetPoseParameterValue(value)
	objects.CommitProperty(self, "PoseParameterValue", value)

	if self.PoseParameter ~= "" then
		self.pose_parameters = self.pose_parameters or {}
		self.pose_parameters[self.PoseParameter] = value
		self.dirty = true
	end
end

function Animator:GetClip()
	return self.clip
end

function Animator:GetRig()
	return self.rig
end

function Animator:Unbind()
	if self.rig then self.rig:Remove() end

	for _, target in ipairs(self.targets) do
		if target.primitive:IsValid() then
			target.primitive:SetPolygon3D(target.original)
		end
	end

	self.targets = {}
	self.rig = nil
	self.bone_bounds = nil
	self.bound_bones = nil
	self.core_bones = nil
	self.skeleton = nil
	self.clip = nil
end

function Animator:Bind(skeleton)
	self:Unbind()
	self.skeleton = skeleton
	self.clip_dirty = true
	self.dirty = true

	if not skeleton then return end

	self.pose = skeleton:NewPose()
	self.clip_pose = skeleton:NewPose()
	self.fade_pose = skeleton:NewPose()
	local parts = {}
	local by_skin = {}
	local model_extent = 0

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local primitive = child.visual_primitive
		local polygon = primitive and primitive:GetPolygon3D()

		if polygon and polygon.Skin then
			local aabb = polygon.AABB
			model_extent = math.max(
				model_extent,
				aabb.max_x - aabb.min_x,
				aabb.max_y - aabb.min_y,
				aabb.max_z - aabb.min_z
			)
		end
	end

	local min_margin = model_extent * MODEL_BOUNDS_MARGIN

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local primitive = child.visual_primitive
		local polygon = primitive and primitive:GetPolygon3D()

		if polygon and polygon.Skin then
			local shared = by_skin[polygon.Skin]
			local clone = polygon:CloneDynamic(shared and shared.vertex_buffer)
			local aabb = polygon.AABB
			local margin_x = math.max((aabb.max_x - aabb.min_x) * BOUNDS_MARGIN, min_margin)
			local margin_y = math.max((aabb.max_y - aabb.min_y) * BOUNDS_MARGIN, min_margin)
			local margin_z = math.max((aabb.max_z - aabb.min_z) * BOUNDS_MARGIN, min_margin)
			clone:SetAABB(
				AABB(
					aabb.min_x - margin_x,
					aabb.min_y - margin_y,
					aabb.min_z - margin_z,
					aabb.max_x + margin_x,
					aabb.max_y + margin_y,
					aabb.max_z + margin_z
				)
			)
			primitive:SetPolygon3D(clone)
			self.targets[#self.targets + 1] = {primitive = primitive, original = polygon}

			if not shared then
				local vertex_buffer = clone.mesh.vertex_buffer
				by_skin[polygon.Skin] = {vertex_buffer = vertex_buffer}
				parts[#parts + 1] = {
					bind_vertex_buffer = polygon.mesh.vertex_buffer,
					vertex_buffer = vertex_buffer,
					skin = polygon.Skin,
				}
			end
		end
	end

	self.rig = Rig.New(skeleton, parts)
	local bone_bounds = ffi.new("double[?]", skeleton.BoneCount * 6)

	for bone = 0, skeleton.BoneCount - 1 do
		local o = bone * 6
		bone_bounds[o], bone_bounds[o + 1], bone_bounds[o + 2] = math.huge, math.huge, math.huge
		bone_bounds[o + 3], bone_bounds[o + 4], bone_bounds[o + 5] = -math.huge, -math.huge, -math.huge
	end

	for _, target in ipairs(self.targets) do
		local polygon = target.original
		local indices, weights = polygon.Skin.BoneIndices, polygon.Skin.BoneWeights

		for i, vertex in ipairs(polygon:GetVertices()) do
			local first = (i - 1) * 4
			local bone, best_weight = indices[first], weights[first]

			for j = first + 1, first + 3 do
				if weights[j] > best_weight then bone, best_weight = indices[j], weights[j] end
			end

			local o = bone * 6
			local pos = vertex.pos

			if pos.x < bone_bounds[o] then bone_bounds[o] = pos.x end

			if pos.y < bone_bounds[o + 1] then bone_bounds[o + 1] = pos.y end

			if pos.z < bone_bounds[o + 2] then bone_bounds[o + 2] = pos.z end

			if pos.x > bone_bounds[o + 3] then bone_bounds[o + 3] = pos.x end

			if pos.y > bone_bounds[o + 4] then bone_bounds[o + 4] = pos.y end

			if pos.z > bone_bounds[o + 5] then bone_bounds[o + 5] = pos.z end
		end
	end

	self.bone_bounds = bone_bounds
	self.bound_bones = {}
	self.core_bones = {}
	local top_bone, top = nil, -math.huge

	for bone = 0, skeleton.BoneCount - 1 do
		local o = bone * 6

		if bone_bounds[o] <= bone_bounds[o + 3] then
			table.insert(self.bound_bones, bone)

			if bone_bounds[o + 4] > top then top_bone, top = bone, bone_bounds[o + 4] end
		end
	end

	local bone = top_bone

	while bone and bone >= 0 do
		if bone_bounds[bone * 6] <= bone_bounds[bone * 6 + 3] then
			table.insert(self.core_bones, bone)
		end

		bone = skeleton.parents[bone]
	end

	for _, target in ipairs(self.targets) do
		target.primitive:GetPolygon3D().SkinRig = self.rig
	end

	self:ApplyViewHiddenBones()
end

function Animator:GetWorldAABB(out, core)
	local rig = self.rig

	if rig.dirty then rig:Compute() end

	local m = self.Owner.transform:GetWorldMatrix()
	local m00, m01, m02 = m.m00, m.m01, m.m02
	local m10, m11, m12 = m.m10, m.m11, m.m12
	local m20, m21, m22 = m.m20, m.m21, m.m22
	local matrices, bounds = rig.matrices, self.bone_bounds
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for _, bone in ipairs(core and self.core_bones or self.bound_bones) do
		local b, s = bone * 6, bone * 12
		local cx, cy, cz = (bounds[b] + bounds[b + 3]) * 0.5,
		(bounds[b + 1] + bounds[b + 4]) * 0.5,
		(bounds[b + 2] + bounds[b + 5]) * 0.5
		local ex, ey, ez = (bounds[b + 3] - bounds[b]) * 0.5,
		(bounds[b + 4] - bounds[b + 1]) * 0.5,
		(bounds[b + 5] - bounds[b + 2]) * 0.5
		local s00, s01, s02 = matrices[s], matrices[s + 1], matrices[s + 2]
		local s10, s11, s12 = matrices[s + 4], matrices[s + 5], matrices[s + 6]
		local s20, s21, s22 = matrices[s + 8], matrices[s + 9], matrices[s + 10]
		local px = s00 * cx + s01 * cy + s02 * cz + matrices[s + 3]
		local py = s10 * cx + s11 * cy + s12 * cz + matrices[s + 7]
		local pz = s20 * cx + s21 * cy + s22 * cz + matrices[s + 11]
		local wx = m00 * px + m10 * py + m20 * pz + m.m30
		local wy = m01 * px + m11 * py + m21 * pz + m.m31
		local wz = m02 * px + m12 * py + m22 * pz + m.m32
		local extent_x = math.abs(m00 * s00 + m10 * s10 + m20 * s20) * ex + math.abs(m00 * s01 + m10 * s11 + m20 * s21) * ey + math.abs(m00 * s02 + m10 * s12 + m20 * s22) * ez
		local extent_y = math.abs(m01 * s00 + m11 * s10 + m21 * s20) * ex + math.abs(m01 * s01 + m11 * s11 + m21 * s21) * ey + math.abs(m01 * s02 + m11 * s12 + m21 * s22) * ez
		local extent_z = math.abs(m02 * s00 + m12 * s10 + m22 * s20) * ex + math.abs(m02 * s01 + m12 * s11 + m22 * s21) * ey + math.abs(m02 * s02 + m12 * s12 + m22 * s22) * ez

		if wx - extent_x < min_x then min_x = wx - extent_x end

		if wy - extent_y < min_y then min_y = wy - extent_y end

		if wz - extent_z < min_z then min_z = wz - extent_z end

		if wx + extent_x > max_x then max_x = wx + extent_x end

		if wy + extent_y > max_y then max_y = wy + extent_y end

		if wz + extent_z > max_z then max_z = wz + extent_z end
	end

	if min_x > max_x then return nil end

	out.min_x, out.min_y, out.min_z = min_x, min_y, min_z
	out.max_x, out.max_y, out.max_z = max_x, max_y, max_z
	return out
end

function Animator:SetViewHiddenBones(names)
	self.ViewHiddenBones = names
	self:ApplyViewHiddenBones()
end

function Animator:ApplyViewHiddenBones()
	local rig = self.rig

	if not rig then return end

	local root

	for _, name in ipairs(self.ViewHiddenBones) do
		root = rig.bone_indices[name:lower()]

		if root then break end
	end

	local parents = self.skeleton.parents
	local subtree = {}

	if root then
		for bone = 0, self.skeleton.BoneCount - 1 do
			local ancestor = bone

			while ancestor >= 0 and ancestor ~= root do
				ancestor = parents[ancestor]
			end

			subtree[bone] = ancestor == root
		end
	end

	for _, target in ipairs(self.targets) do
		local skin = target.original.Skin
		local indices, weights = skin.BoneIndices, skin.BoneWeights
		local seen = {}
		local total, inside = 0, 0

		if root then
			for _, vertex in ipairs(target.original:GetIndices()) do
				if not seen[vertex] then
					seen[vertex] = true
					local first = (vertex - 1) * 4
					local best, best_weight = 0, -1

					for i = first, first + 3 do
						if weights[i] > best_weight then best, best_weight = indices[i], weights[i] end
					end

					total = total + 1

					if subtree[best] then inside = inside + 1 end
				end
			end
		end

		target.primitive:SetViewHidden(total > 0 and inside * 2 >= total)
	end
end

function Animator:OnRemove()
	self:Unbind()
end

function Animator:ResolveClip()
	self.clip_dirty = false
	local skeleton = self.skeleton
	local clip = skeleton.ClipsByName[self.Sequence]

	if self.Sequence == "" and not clip then
		for _, candidate in ipairs(skeleton.Clips) do
			if candidate.Name:lower():find("idle", 1, true) then
				clip = candidate

				break
			end
		end

		clip = clip or skeleton.Clips[1]

		if clip then objects.CommitProperty(self, "Sequence", clip.Name) end
	end

	if clip == self.clip then return end

	if self.clip then
		self.time = 0

		if self.BlendTime > 0 then
			self.fade_pose:Copy(self.pose)
			self.fade = 0
		end
	end

	self.clip = clip
end

function Animator:SyncCycle(cycle, dt)
	if self.clip_dirty then self:ResolveClip() end

	local clip = self.clip

	if not clip or clip.Duration <= 0 then return end

	local current = self.time / clip.Duration % 1
	local error = (cycle - current + 0.5) % 1 - 0.5
	local fraction = math.abs(error) > SYNC_SNAP and 1 or math.min(dt * SYNC_FOLLOW, 1)
	self.time = (current + error * fraction) % 1 * clip.Duration
end

function Animator:Settle()
	if (self.settle or 0) == 0 then return end

	self.settle = 0
	skinning.Queue(self.rig)
end

function Animator:Animate(dt)
	local rig = self.rig

	if rig.held then return end

	if self.clip_dirty then self:ResolveClip() end

	local clip = self.clip
	local pose_changed = false

	if not clip then
		if self.dirty then
			self.pose:Reset()
			pose_changed = true
		end
	else
		local advancing = self.Playing and clip.Duration > 0

		if advancing or self.dirty or self.fade then
			pose_changed = true

			if advancing then self.time = self.time + dt * self.Speed end

			local cycle = 0

			if clip.Duration > 0 then
				cycle = self.time / clip.Duration

				if self.Loop and clip.Loop ~= false then
					cycle = cycle % 1
				else
					cycle = math.clamp(cycle, 0, 1)
				end

				self.time = cycle * clip.Duration
			end

			self.clip_pose:Sample(clip, cycle, self.pose_parameters)

			if self.fade then
				self.fade = self.fade + dt / self.BlendTime

				if self.fade >= 1 then
					self.fade = nil
				else
					self.pose:Blend(self.fade_pose, self.clip_pose, self.fade * self.fade * (3 - 2 * self.fade))
				end
			end

			if not self.fade then self.pose:Copy(self.clip_pose) end
		end
	end

	if not (pose_changed or rig.dirty or rig.needs_skin) then
		return self:Settle()
	end

	self.dirty = false

	if pose_changed then rig:SetPose(self.pose) end

	rig:Update()
	self.settle = 1
	self.skin_version = (self.skin_version or 0) + 1
	self.Owner.visual:NotifyGeometryChanged()
end

function Animator:OnFirstCreated()
	event.AddListener("Update", "animators", function(dt)
		local camera = import("goluwa/render3d/render3d.lua").GetCamera():GetPosition()
		local now = system.GetElapsedTime()

		for _, animator in ipairs(Animator.Instances) do
			local visual = animator.Owner.visual

			if visual and visual.Visible then
				if visual.Skeleton ~= animator.skeleton then animator:Bind(visual.Skeleton) end

				if animator.skeleton and animator.targets[1] and visual:IsWithinCullDistance() then
					local m = animator.Owner.transform:GetWorldMatrix()
					local dx, dy, dz = m.m30 - camera.x, m.m31 - camera.y, m.m32 - camera.z
					local interval = Animator.GetUpdateInterval(math.sqrt(dx * dx + dy * dy + dz * dz))
					local bucket = interval > 0 and math.floor(now / interval + animator.phase) or nil

					if bucket == nil or bucket ~= animator.update_bucket then
						animator.update_bucket = bucket
						local elapsed = animator.last_update and now - animator.last_update or dt
						animator.last_update = now
						animator:Animate(elapsed)
					elseif interval > Animator.LOD_SETTLE_INTERVAL then
						animator:Settle()
					end
				end
			end
		end
	end)
end

function Animator:OnLastRemoved()
	event.RemoveListener("Update", "animators")
end

return Animator:Register()
