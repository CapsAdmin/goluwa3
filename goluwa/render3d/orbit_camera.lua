local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("render3d_orbit_camera")
local ROTATE_SPEED = 0.01
local ZOOM_STEP = 1.15
local MAX_PITCH = 1.5
META:GetSet("Yaw", math.pi / 4)
META:GetSet("Pitch", -0.25)
META:GetSet("Distance", 3)
META:GetSet("Target", nil)
META:GetSet("FOV", math.rad(35))
META:GetSet("Radius", 1)

function META.New(camera)
	local self = META:CreateObject()
	self.camera = camera
	self.Target = Vec3(0, 0, 0)
	self.home = {}
	return self
end

function META:Fit(center, radius, aspect)
	local half = self.FOV / 2
	half = math.min(half, math.atan(math.tan(half) * aspect))
	self.Target = center:Copy()
	self.Radius = radius
	self.Distance = radius / math.sin(half) * 1.1
	local home = self.home
	home.yaw, home.pitch, home.distance = self.Yaw, self.Pitch, self.Distance
	home.target = self.Target:Copy()
end

function META:Reset()
	local home = self.home
	self.Yaw, self.Pitch, self.Distance = home.yaw, home.pitch, home.distance
	self.Target = home.target:Copy()
end

function META:Rotate(dx, dy)
	self.Yaw = self.Yaw + dx * ROTATE_SPEED
	self.Pitch = math.clamp(self.Pitch + dy * ROTATE_SPEED, -MAX_PITCH, MAX_PITCH)
end

function META:GetViewOffset()
	local cos_pitch = math.cos(self.Pitch)
	return Vec3(math.sin(self.Yaw) * cos_pitch, -math.sin(self.Pitch), math.cos(self.Yaw) * cos_pitch)
end

function META:Zoom(steps)
	self.Distance = math.clamp(self.Distance * ZOOM_STEP ^ steps, self.Radius * 0.2, self.Radius * 50)
end

function META:Pan(dx, dy, viewport_height)
	local rotation = self.camera:GetRotation()
	local per_pixel = 2 * self.Distance * math.tan(self.FOV / 2) / viewport_height
	self.Target = self.Target - rotation:GetRight() * (
			dx * per_pixel
		) + rotation:GetUp() * (
			dy * per_pixel
		)
end

function META:Apply()
	local camera = self.camera
	local rotation = Quat()
	rotation:Identity()
	rotation:RotateYaw(self.Yaw)
	rotation:RotatePitch(self.Pitch)
	camera:SetRotation(rotation)
	camera:SetPosition(self.Target - rotation:GetForward() * self.Distance)
	camera:SetFOV(self.FOV)
	camera:SetNearZ(math.max(self.Distance * 0.01, 0.01))
	camera:SetFarZ((self.Distance + self.Radius) * 4)
end

META:Register()
return META
