local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Eyes = objects.CreateTemplate("eyes")
Eyes.Is3D = true
Eyes:GetSet("LookYaw", 0)
Eyes:GetSet("LookPitch", 0)
Eyes:GetSet("LookTarget", nil)
Eyes:GetSet("Blink", 0)
Eyes:GetSet("AutoBlink", false)
Eyes:GetSet("AutoLook", false)
Eyes:GetSet("LookDistance", 15)
Eyes:GetSet("ViewAngle", math.rad(100))
Eyes.TargetSources = Eyes.TargetSources or {}
local BLINK_DURATION = 0.18
local BLINK_INTERVAL_MIN = 2
local BLINK_INTERVAL_MAX = 6
local SCAN_INTERVAL = 0.5
local MAX_YAW = math.rad(35)
local MAX_PITCH = math.rad(25)
local FOLLOW_RATE = 14
local GLANCE_YAW = math.rad(22)
local GLANCE_PITCH = math.rad(8)
local CULL_DISTANCE = 40
local MOVE_EPSILON = 1e-4
local candidates = {}
local up_offset = Vec3(0, 1.6, 0)

local function rotate_by_skin(m, o, x, y, z)
	return m[o] * x + m[o + 1] * y + m[o + 2] * z,
	m[o + 4] * x + m[o + 5] * y + m[o + 6] * z,
	m[o + 8] * x + m[o + 9] * y + m[o + 10] * z
end

function Eyes.AddTargetSource(source)
	Eyes.TargetSources[#Eyes.TargetSources + 1] = source
end

function Eyes.GetTargetPosition(entity)
	local animator = entity.animator
	local rig = animator and animator.rig

	if entity.eyes and rig and rig.skeleton.Eyes then
		local bone = rig.bone_indices[rig.skeleton.Eyes[1].name] * 12
		local world = rig.world
		return entity.transform:GetWorldMatrix():TransformVector(Vec3(world[bone + 3], world[bone + 7], world[bone + 11]))
	end

	return entity.transform:GetWorldPosition() + up_offset
end

function Eyes:Initialize()
	self.blink_time = nil
	self.clock = 0
	self.next_blink = BLINK_INTERVAL_MIN
	self.next_scan = math.random() * SCAN_INTERVAL
	self.next_glance = 0
	self.glance_yaw, self.glance_pitch = 0, 0
	self.glancing = false
	self.angles = {}
end

function Eyes:GetAutoBlinkAmount(dt)
	if self.blink_time then
		self.blink_time = self.blink_time + dt

		if self.blink_time >= BLINK_DURATION then
			self.blink_time = nil
			self.next_blink = self.clock + math.random(BLINK_INTERVAL_MIN * 100, BLINK_INTERVAL_MAX * 100) / 100
			return 0
		end

		return math.sin(self.blink_time / BLINK_DURATION * math.pi)
	end

	if self.clock >= self.next_blink then self.blink_time = 0 end

	return 0
end

function Eyes:ScanTargets(world, forward_x, forward_y, forward_z)
	local ox, oy, oz = world:GetTranslation()
	local best, best_distance = nil, self.LookDistance
	local cos_view = math.cos(self.ViewAngle)
	local count = 0

	for _, source in ipairs(Eyes.TargetSources) do
		count = source(candidates, count)
	end

	for i = 1, count do
		local entity = candidates[i]
		candidates[i] = nil

		if entity ~= self.Owner and entity:IsValid() then
			local position = Eyes.GetTargetPosition(entity)
			local dx, dy, dz = position.x - ox, position.y - oy, position.z - oz
			local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

			if
				distance < best_distance and
				distance > 0.05 and
				(
					dx * forward_x + dy * forward_y + dz * forward_z
				) / distance > cos_view
			then
				best, best_distance = entity, distance
			end
		end
	end

	self.auto_target = best
end

function Eyes:UpdateGlance()
	if self.clock < self.next_glance then return end

	if self.glancing then
		self.glancing = false
		self.glance_yaw, self.glance_pitch = 0, 0
		self.next_glance = self.clock + 1 + math.random() * 3
		return
	end

	local amplitude = self.auto_target and 0.4 or 1
	self.glancing = true
	self.glance_yaw = (math.random() * 2 - 1) * GLANCE_YAW * amplitude
	self.glance_pitch = (math.random() * 2 - 1) * GLANCE_PITCH * amplitude
	self.next_glance = self.clock + 0.4 + math.random() * 1.2
end

function Eyes:Update(dt)
	local owner = self.Owner
	local animator = owner.animator
	local rig = animator and animator.rig

	if not rig or not rig.skeleton.Eyes then return end

	self.clock = self.clock + dt
	local blink = self.Blink

	if self.AutoBlink then blink = math.max(blink, self:GetAutoBlinkAmount(dt)) end

	local visual = owner.visual
	local active = visual and visual.Visible and visual:IsWithinCullDistance()
	local eyes_info = rig.skeleton.Eyes

	if rig ~= self.applied_rig then
		self.applied_rig = rig
		self.applied_blink = nil
		self.angles = {}

		for index in ipairs(eyes_info) do
			self.angles[index] = {0, 0}
		end
	end

	if blink ~= self.applied_blink then
		self.applied_blink = blink

		if rig.flex_indices then rig:SetFlex("blink", blink) end
	end

	if not active then return end

	if rig.dirty then rig:Compute() end

	local world = owner.transform:GetWorldMatrix()
	local inverse = owner.transform:GetWorldMatrixInverse()
	local matrices, bones = rig.matrices, rig.world
	local first = eyes_info[1]
	local head = rig.skeleton.parents[rig.bone_indices[first.name]]
	local head_offset = head * 12
	local manual = self.LookTarget
	local target = manual

	if self.AutoLook then
		self:UpdateGlance()
		local f = first.forward
		local fx = matrices[head_offset] * f[1] + matrices[head_offset + 1] * f[2] + matrices[head_offset + 2] * f[3]
		local fy = matrices[head_offset + 4] * f[1] + matrices[head_offset + 5] * f[2] + matrices[head_offset + 6] * f[3]
		local fz = matrices[head_offset + 8] * f[1] + matrices[head_offset + 9] * f[2] + matrices[head_offset + 10] * f[3]
		local wx = fx * world.m00 + fy * world.m10 + fz * world.m20
		local wy = fx * world.m01 + fy * world.m11 + fz * world.m21
		local wz = fx * world.m02 + fy * world.m12 + fz * world.m22

		if self.clock >= self.next_scan then
			self.next_scan = self.clock + SCAN_INTERVAL
			self:ScanTargets(world, wx, wy, wz)
		end

		if not manual and self.auto_target then
			if self.auto_target:IsValid() then
				target = Eyes.GetTargetPosition(self.auto_target)
			else
				self.auto_target = nil
			end
		end
	end

	local follow = 1 - math.exp(-dt * FOLLOW_RATE)
	local glance_yaw, glance_pitch = 0, 0

	if self.AutoLook and not manual and self.glancing then
		glance_yaw, glance_pitch = self.glance_yaw, self.glance_pitch
	end

	local tx, ty, tz

	if target then
		tx, ty, tz = inverse:TransformVectorUnpacked(target.x, target.y, target.z)
	end

	for index, eye in ipairs(eyes_info) do
		local bone = rig.bone_indices[eye.name] * 12
		local goal_yaw, goal_pitch = math.rad(self.LookYaw), math.rad(self.LookPitch)

		if target then
			local dx, dy, dz = tx - bones[bone + 3], ty - bones[bone + 7], tz - bones[bone + 11]
			local length = math.sqrt(dx * dx + dy * dy + dz * dz)

			if length > 0.01 then
				dx, dy, dz = dx / length, dy / length, dz / length
				local f, u = eye.forward, eye.up
				local rx, ry, rz = f[2] * u[3] - f[3] * u[2], f[3] * u[1] - f[1] * u[3], f[1] * u[2] - f[2] * u[1]
				local ho = head_offset
				local ax, ay, az = rotate_by_skin(matrices, ho, f[1], f[2], f[3])
				local bx, by, bz = rotate_by_skin(matrices, ho, u[1], u[2], u[3])
				local cx, cy, cz = rotate_by_skin(matrices, ho, rx, ry, rz)
				local forward = dx * ax + dy * ay + dz * az
				local upward = dx * bx + dy * by + dz * bz
				local sideways = dx * cx + dy * cy + dz * cz
				goal_yaw = math.atan2(-sideways, forward)
				goal_pitch = math.asin(math.clamp(upward, -1, 1))
			end
		end

		goal_yaw = math.clamp(goal_yaw + glance_yaw, -MAX_YAW, MAX_YAW)
		goal_pitch = math.clamp(goal_pitch + glance_pitch, -MAX_PITCH, MAX_PITCH)
		local angles = self.angles[index]
		local yaw = angles[1] + (goal_yaw - angles[1]) * follow
		local pitch = angles[2] + (goal_pitch - angles[2]) * follow

		if
			math.abs(yaw - angles[1]) > MOVE_EPSILON or
			math.abs(pitch - angles[2]) > MOVE_EPSILON
		then
			angles[1], angles[2] = yaw, pitch
			rig:SetEyeAngles(index, yaw, pitch)
		end
	end
end

function Eyes:OnFirstCreated()
	event.AddListener("Update", "eyes", function(dt)
		for _, eyes in ipairs(Eyes.Instances) do
			eyes:Update(dt)
		end
	end)
end

function Eyes:OnLastRemoved()
	event.RemoveListener("Update", "eyes")
end

return Eyes:Register()
