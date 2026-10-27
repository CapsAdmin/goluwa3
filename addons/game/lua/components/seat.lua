local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("seat")
META:StartStorable()
META:GetSet("Pose", "drive")
META:GetSet("Position", Vec3())
META:GetSet("Rotation", Quat(0, 0, 0, 1))
META:GetSet("EyeHeight", 0.7)
META:GetSet("ExitPosition", Vec3(-1.5, 0, 0))
META:GetSet("HandRight", "")
META:GetSet("HandLeft", "")
META:GetSet("FootRight", "")
META:GetSet("FootLeft", "")
META:GetSet("CameraDistance", 5)
META:GetSet("CameraHeight", 1.5)
META:EndStorable()
META.Occupant = NULL
local EXIT_CLEARANCE = 0.05
local scratch_rotation = Quat()

function META:IsOccupied()
	return self.Occupant:IsValid()
end

function META:GetFrame(position, rotation)
	local transform = self.Owner.transform
	local origin = transform:GetPosition()
	local base = transform:GetRotation()
	local offset = base:VecMul(self.Position)
	position:Set(origin.x + offset.x, origin.y + offset.y, origin.z + offset.z)
	Quat.SetMul(rotation, base, self.Rotation)
	return position, rotation
end

function META:GetRenderFrame(position, rotation)
	local world = self.Owner.transform:GetWorldMatrix()
	local local_position = self.Position
	position:Set(
		world:TransformVectorUnpacked(local_position.x, local_position.y, local_position.z)
	)
	world:GetRotation(scratch_rotation)
	Quat.SetMul(rotation, scratch_rotation, self.Rotation)
	return position, rotation
end

function META:GetLimbNode(name)
	if name == "" then return end

	local node = self.Owner:GetNode(name)

	if node and node:IsValid() then return node end
end

function META:GetEyeOffset(rotation)
	return rotation:VecMul(Vec3(0, self.EyeHeight, 0))
end

local exit_options = {IgnoreRigidBodies = false, IgnoreKinematicBodies = true}

function META:FindExit(character)
	local transform = self.Owner.transform
	local base = transform:GetRotation()
	local start = transform:GetPosition() + base:VecMul(self.Position)
	local movement = character.character_movement
	local radius = movement:GetRadius()
	local height = movement:GetHeight()
	local exit = self.ExitPosition
	local candidates = {
		exit,
		Vec3(-exit.x, exit.y, exit.z),
		Vec3(0, exit.y, exit.z - math.abs(exit.x) * 1.5),
		Vec3(0, exit.y, exit.z + math.abs(exit.x) * 1.5),
	}

	for _, candidate in ipairs(candidates) do
		local target = transform:GetPosition() + base:VecMul(candidate)
		local center = target + Vec3(0, height * 0.5, 0)
		local path = center - start
		local hit = physics.Sweep(start, path, radius, self.Owner, nil, exit_options)

		if not hit then
			local ground = physics.Sweep(center, Vec3(0, -height, 0), radius, self.Owner, nil, exit_options)

			if ground then
				return ground.position + Vec3(0, EXIT_CLEARANCE - radius, 0) + ground.normal * radius
			end

			return target
		end
	end

	return start + Vec3(0, height, 0)
end

function META:Enter(character)
	if self:IsOccupied() or not character.character_pose then return false end

	local pose = character.character_pose
	local current = pose:GetSeat()

	if current:IsValid() then return false end

	self.Occupant = character
	pose:SetSeat(self.Owner)
	self.Owner:CallLocalEvent("OnSeatEntered", character)
	return true
end

function META:Exit()
	local character = self.Occupant

	if not character:IsValid() then return end

	self.Occupant = NULL
	character.character_pose:SetSeat(NULL)
	self.Owner:CallLocalEvent("OnSeatExited", character)
end

function META:OnUsed(user)
	if network.HasAuthority() then self:Enter(user) end

	return true
end

function META:OnRemove()
	if network.HasAuthority() then self:Exit() end
end

return META:Register()
