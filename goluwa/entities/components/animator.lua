local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local AABB = import("goluwa/structs/aabb.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local Rig = import("goluwa/render3d/rig.lua")
local Animator = objects.CreateTemplate("animator")
Animator.Is3D = true
-- how far past the bind pose bounds an animated mesh may reach before it is frustum culled, as a fraction of its size
local BOUNDS_MARGIN = 0.5
-- animators update every frame within LOD_NEAR meters of the camera and less often the farther they are, down to
-- LOD_MIN_RATE updates per second at LOD_FAR and beyond
Animator.LOD_NEAR = 15
Animator.LOD_FAR = 80
Animator.LOD_MIN_RATE = 5
-- gaps between updates longer than this get a pass that zeroes the motion vectors of the pose
Animator.LOD_SETTLE_INTERVAL = 0.04

-- seconds between updates at a distance, 0 meaning every frame
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
-- the pose parameter the next property edits, sequences blend between their animations by these (move_x, aim_yaw, ...)
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

-- restarts the sequence from its first frame, SetSequence keeps the time when the sequence stays the same
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

-- the rig that skins the model, for what moves bones and faces on top of the animation
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
	-- the primitives of a model share one skin and one vertex array, so they share the buffer that is skinned too
	local by_skin = {}

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local primitive = child.visual_primitive
		local polygon = primitive and primitive:GetPolygon3D()

		if polygon and polygon.Skin then
			local shared = by_skin[polygon.Skin]
			local clone = polygon:CloneDynamic(shared and shared.vertex_buffer)
			local aabb = polygon.AABB
			local margin_x = (aabb.max_x - aabb.min_x) * BOUNDS_MARGIN
			local margin_y = (aabb.max_y - aabb.min_y) * BOUNDS_MARGIN
			local margin_z = (aabb.max_z - aabb.min_z) * BOUNDS_MARGIN
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
end

function Animator:OnRemove()
	self:Unbind()
end

function Animator:ResolveClip()
	self.clip_dirty = false
	local skeleton = self.skeleton
	local clip = skeleton.ClipsByName[self.Sequence]

	if self.Sequence == "" and not clip then
		-- nothing picked yet, start on an idle so adding the component shows something
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

-- skinning once more with the same pose, so the motion since the previous update drops to zero. the bvh has
-- nothing to follow, the pose is the same
function Animator:Settle()
	if (self.settle or 0) == 0 then return end

	self.settle = 0
	skinning.Queue(self.rig)
end

function Animator:Animate(dt)
	local rig = self.rig

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

	-- bones and flexes set on the rig also need the vertices skinned again
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
					-- an animator updates whenever the bucket of the time it is in changes, buckets being as long as its
					-- interval and offset by a phase of its own. a crowd is spread over the interval, and spreads out again
					-- after a hitch (everything finishing loading in one frame, say) with nothing to keep track of
					local bucket = interval > 0 and math.floor(now / interval + animator.phase) or nil

					if bucket == nil or bucket ~= animator.update_bucket then
						animator.update_bucket = bucket
						local elapsed = animator.last_update and now - animator.last_update or dt
						animator.last_update = now
						animator:Animate(elapsed)
					elseif interval > Animator.LOD_SETTLE_INTERVAL then
						-- between updates a few frames apart the motion of the last one is close enough to the truth,
						-- over longer gaps it would smear the model across the screen
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
