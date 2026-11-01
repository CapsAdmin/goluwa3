local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local View = import("goluwa/render3d/view.lua")
local screen_fields = import("goluwa/render3d/screen_fields.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local inventory_menu = import("lua/inventory_menu.lua")
local UP = Vec3(0, 1, 0)
local DISTANCE = 1.15
local LIFT = 0.1
local SHIFT = 0.3
local FOLLOW_SPEED = 6
local HERO_RADIUS = 1.8
local HERO_HOLD_AGE = 0.6
local HERO_RELEASE = 0.4
local view
local field
local view_position = Vec3()
local view_aim = Vec3()

event.AddListener("Update", "inventory_camera", function(dt)
	if not inventory_menu.IsOpen() then
		if view then
			view:Remove()
			view = nil
		end

		if field then
			field.Duration, field.Attack, field.age = HERO_RELEASE, 0.001, 0.001
			field = nil
		end

		return
	end

	local subject = inventory_menu.GetSubject()
	local place = inventory_menu.GetState().place
	local chest = subject.transform:GetPosition() + Vec3(0, subject.character_movement:GetHeight() * 0.6, 0)
	local focus = inventory_menu.GetSocketPosition(subject, place) or chest
	local forward = subject.transform:GetRotation():GetForward()
	forward.y = 0
	forward:Normalize()

	if not view then
		local camera = render3d.GetMainCamera()
		view_position:CopyFrom(camera:GetPosition())
		view_aim:CopyFrom(view_position + camera:GetRotation():GetForward() * 3)
		view = View.New{Priority = 100, HidePlayer = false, FOV = math.rad(50), ExposureHold = true}:Activate()
		field = screen_fields.Add{
			Position = chest,
			Duration = 1000,
			Attack = 0.0003,
			Radius = HERO_RADIUS,
			Expand = false,
			Thickness = 0.2,
			Darken = 0.995,
			Brightness = 0,
		}
	end

	local right = (forward * -1):GetCross(UP):GetNormalized()
	local follow = 1 - math.exp(-dt * FOLLOW_SPEED)
	view_position = view_position:GetLerped(follow, focus + forward * DISTANCE + UP * LIFT)
	view_aim = view_aim:GetLerped(follow, focus - right * SHIFT)
	view:SetPosition(view_position)
	view:SetRotation(Quat():SetLookDirection((view_aim - view_position):GetNormalized()))
	field.position:CopyFrom(chest)
	field.age = math.min(field.age, HERO_HOLD_AGE)
end)
