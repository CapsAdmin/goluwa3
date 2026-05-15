local prototype = import("goluwa/prototype.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = prototype.CreateTemplate("player_input")
META:GetSet("Mode", "fly")
META:GetSet("Rotation", Quat(0, 0, 0, 1))
META:GetSet("Pitch", 0)
META:GetSet("FOV", math.rad(90))
META:GetSet("MouseSensitivity", 1.5)
META:GetSet("ArrowLookSpeed", 1)
META:GetSet("MinPitch", -math.pi / 2 + 0.01)
META:GetSet("MaxPitch", math.pi / 2 - 0.01)
META:GetSet("MinFOV", math.rad(0.1))
META:GetSet("MaxFOV", math.rad(175))
META:GetSet("MouseDivisor", 2)
META:GetSet("SprintMultiplier", 1.75)
META:GetSet("CrouchMultiplier", 0.45)
META:GetSet("SuperMultiplier", 3)

function META:SetRotation(rotation)
	self.Rotation = rotation:Copy()
end

function META:Initialize()
	self:SetRotation(self.Rotation or Quat():Identity())
	self.look_delta = Vec2()
	self.look_nudge = Vec2()
	self.move_local = Vec3()
	self.mouse_trapped = false
	self.roll_mode = false
	self.crouching = false
	self.speed_multiplier = 1
	self.jump_pressed = false
	self:ApplyMode(self.Mode)
	self:AddGlobalEvent("Update", {priority = 100})
end

function META:KeyInput(key, press)
	if not press or not self:IsReceivingInput() then return end

	if key == "space" then
		self.jump_pressed = true
	elseif key == "v" then
		self:OnCameraToggleMode()
	elseif key == "r" then
		self:Reset()
	end
end

function META:OnFirstCreated()
	event.AddListener(
		"KeyInput",
		"ecs_player_input_system",
		function(key, press)
			for _, player_input in ipairs(META.Instances or {}) do
				if player_input and player_input:IsValid() and player_input:IsReceivingInput() then
					if player_input:KeyInput(key, press) then return true end
				end
			end
		end,
		{priority = 100}
	)
end

function META:OnLastRemoved()
	event.RemoveListener("KeyInput", "ecs_player_input_system")
end

function META:OnCameraToggleMode()
	if self.Mode == "fly" then
		self:SetMode("walk")
	else
		self:SetMode("fly")
	end
end

function META:SetMode(mode)
	self.Mode = mode
	self:ApplyMode(mode)
end

function META:ApplyMode(mode)
	local owner = self.Owner
	local camera = owner.camera

	if camera and mode ~= "walk" then camera:SetViewOffset(Vec3()) end

	owner:CallLocalEvent("OnCameraModeChanged", mode)
end

function META:Reset()
	self:SetRotation(Quat():Identity())
	self.Pitch = 0
	self.FOV = math.rad(90)
end

function META:SyncFromCamera(camera)
	if not camera then return end

	self:SetRotation(camera:GetRotation():Copy())
	self:SetFOV(camera:GetFOV())
	local forward = self.Rotation:GetForward()
	self.Pitch = math.asin(math.clamp(forward.y, -1, 1))
end

function META:GetForward()
	return self.Rotation:GetForward()
end

function META:GetRight()
	return self.Rotation:GetRight()
end

function META:GetUp()
	return self.Rotation:GetUp()
end

function META:IsReceivingInput()
	local camera = self.Owner and self.Owner.camera
	return camera and camera.GetActive and camera:GetActive() or false
end

function META:GetSpeedMultiplier(crouching)
	if input.IsKeyDown("left_shift") and crouching then
		return self.SuperMultiplier
	elseif input.IsKeyDown("left_shift") then
		return self.SprintMultiplier
	elseif crouching then
		return self.CrouchMultiplier
	end

	return 1
end

function META:OnUpdate(dt)
	if not self:IsReceivingInput() then return end

	self.crouching = input.IsKeyDown("left_control") or input.IsKeyDown("right_control")
	self.look_delta = system.GetWindow():GetMouseDelta() / self.MouseDivisor
	self.look_nudge = Vec2()
	self.move_local = Vec3()
	self.mouse_trapped = system.GetWindow():GetMouseTrapped()
	self.roll_mode = input.IsMouseDown("button_2")
	self.speed_multiplier = self:GetSpeedMultiplier(self.crouching)

	if input.IsKeyDown("left") then
		self.look_nudge.x = self.look_nudge.x - dt
	elseif input.IsKeyDown("right") then
		self.look_nudge.x = self.look_nudge.x + dt
	end

	if input.IsKeyDown("up") then
		self.look_nudge.y = self.look_nudge.y - dt
	elseif input.IsKeyDown("down") then
		self.look_nudge.y = self.look_nudge.y + dt
	end

	if input.IsKeyDown("w") then self.move_local.z = self.move_local.z + 1 end

	if input.IsKeyDown("s") then self.move_local.z = self.move_local.z - 1 end

	if input.IsKeyDown("a") then self.move_local.x = self.move_local.x - 1 end

	if input.IsKeyDown("d") then self.move_local.x = self.move_local.x + 1 end

	if input.IsKeyDown("z") then self.move_local.y = self.move_local.y - 1 end

	if input.IsKeyDown("x") then self.move_local.y = self.move_local.y + 1 end

	self.Owner:CallLocalEvent("OnBeforeCameraInputUpdate", dt, self)
	self.Owner:CallLocalEvent("OnCameraInputUpdate", dt, self)
	self.jump_pressed = false
end

function META:OnCameraInputUpdate(dt)
	if not self.mouse_trapped then return end

	local rotation = self:GetRotation():Copy()
	local mouse_delta = (self.look_delta + self.look_nudge * self.ArrowLookSpeed) * self.MouseSensitivity
	mouse_delta = mouse_delta * (self.FOV / 175)

	if self.roll_mode then
		rotation:RotateRoll(mouse_delta.x)
		self:SetRotation(rotation)
		self:SetFOV(
			math.clamp(self.FOV + mouse_delta.y * 10 * (self.FOV / math.pi), self.MinFOV, self.MaxFOV)
		)
		return
	end

	local new_pitch = math.clamp(self.Pitch + mouse_delta.y, self.MinPitch, self.MaxPitch)
	local pitch_delta = new_pitch - self.Pitch
	self.Pitch = new_pitch
	local yaw_quat = Quat():Identity()
	yaw_quat:RotateYaw(-mouse_delta.x)
	rotation = (yaw_quat * rotation):GetNormalized()
	rotation:RotatePitch(-pitch_delta)
	self:SetRotation(rotation)
end

return META:Register()
