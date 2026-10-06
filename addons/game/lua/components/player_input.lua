local objects = import("goluwa/objects/objects.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local META = objects.CreateTemplate("player_input")
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
	self.jump_down = false
	self.sprint_down = false
	self.scroll_accum = 0
	self.rotate_accum = Vec2()
	self:RefreshKeys()
	self:AddGlobalEvent("Update", {priority = 100})
end

function META:RefreshKeys()
	local move_local = self.move_local
	move_local.x = (input.IsKeyDown("d") and 1 or 0) - (input.IsKeyDown("a") and 1 or 0)
	move_local.y = (input.IsKeyDown("x") and 1 or 0) - (input.IsKeyDown("z") and 1 or 0)
	move_local.z = (input.IsKeyDown("w") and 1 or 0) - (input.IsKeyDown("s") and 1 or 0)
	self.crouching = input.IsKeyDown("left_control") or input.IsKeyDown("right_control")
	self.sprint_down = input.IsKeyDown("left_shift")
	self.jump_down = input.IsKeyDown("space")
end

function META:KeyInput(key, press)
	self:RefreshKeys()

	if not press or not self:IsReceivingInput() then return end

	if key == "v" then
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
				if player_input and player_input:IsValid() then
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
	local camera = self.Owner.camera
	return camera ~= nil and camera:IsRendered()
end

function META:BuildCommand(cmd)
	local active = self:IsReceivingInput() and self.mouse_trapped
	local BUTTON = usercmd.BUTTON
	local buttons = 0
	cmd.view:CopyFrom(self.Rotation)
	cmd.mode = self.Mode
	cmd.fov = self.FOV

	if self.crouching then buttons = bit.bor(buttons, BUTTON.CROUCH) end

	if self.sprint_down then buttons = bit.bor(buttons, BUTTON.SPRINT) end

	if active then
		buttons = bit.bor(buttons, BUTTON.ACTIVE)
		cmd.forward = self.move_local.z
		cmd.side = self.move_local.x
		cmd.up = self.move_local.y

		if self.jump_down then buttons = bit.bor(buttons, BUTTON.JUMP) end

		if input.IsMouseDown("button_1") then
			buttons = bit.bor(buttons, BUTTON.ATTACK1)
		end

		if input.IsMouseDown("button_2") then
			buttons = bit.bor(buttons, BUTTON.ATTACK2)
		end
	end

	cmd.buttons = buttons
	cmd.scroll = self.scroll_accum
	cmd.rotate_x = self.rotate_accum.x
	cmd.rotate_y = self.rotate_accum.y
	self.scroll_accum = 0
	self.rotate_accum.x = 0
	self.rotate_accum.y = 0
end

function META:OnUpdate(dt)
	if not self:IsReceivingInput() then return end

	self.look_delta = system.GetWindow():GetMouseDelta() / self.MouseDivisor
	self.look_nudge = Vec2()
	local window = system.GetWindow()
	self.mouse_trapped = window:GetMouseTrapped() and not window:HasMouseTrapRequests()
	self.roll_mode = input.IsMouseDown("button_2")

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

	local controller = self.Owner.player_controller

	if input.WasMousePressed("mwheel_down") then
		self.scroll_accum = self.scroll_accum + 1
	elseif input.WasMousePressed("mwheel_up") then
		self.scroll_accum = self.scroll_accum - 1
	end

	if
		controller and
		controller:IsHolding() and
		self.mouse_trapped and
		input.IsMouseDown("button_1") and
		input.IsKeyDown("e")
	then
		local mouse_delta = (self.look_delta + self.look_nudge * self.ArrowLookSpeed) * self.MouseSensitivity
		self.rotate_accum = self.rotate_accum + mouse_delta * (self.FOV / 175)
		self.look_delta = Vec2()
		self.look_nudge = Vec2()
	end

	self:OnCameraInputUpdate(dt)
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
