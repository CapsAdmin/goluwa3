local Vec3 = import("goluwa/structs/vec3.lua")
local objects = import("goluwa/objects/objects.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local camera = import("lua/camera.lua")
local Gizmo = import("lua/gizmo.lua")
local view_camera = {}

function view_camera.Start(view, speed)
	local state = {
		View = view,
		SavedSpeed = camera.speed,
		SavedKeys = {camera.key_up, camera.key_down},
	}
	camera.speed = speed
	camera.key_up, camera.key_down = "e", "q"
	return state
end

function view_camera.Set(state, eye, pitch_degrees, yaw_degrees)
	camera.SetPosition(eye)
	camera.SetRotation(QuatDeg3(pitch_degrees, yaw_degrees, 0))
	camera.pitch = -math.rad(pitch_degrees)
	camera.velocity = Vec3()
	state.View:SetPosition(eye:Copy())
	state.View:SetRotation(camera.GetRotation():Copy())
end

function view_camera.Get()
	local forward = camera.GetRotation():GetForward()
	return camera.GetPosition():Copy(),
	math.deg(math.asin(forward.y)),
	math.deg(math.atan2(-forward.x, -forward.z))
end

function view_camera.Update(state, dt)
	local focused = objects:GetFocusedObject()
	local hovered = MouseInput.GetHoveredObject()
	camera.SetBlockMovement(
		state.BlockMovement == true or
			focused:IsValid() and
			tostring(focused.Type):find("text") ~= nil
	)
	local gizmo = Gizmo.GetStatus()
	camera.SetBlockDragging(
		hovered:IsValid() and
			hovered ~= Panel.World or
			MouseInput.IsPressCapturedByUI() or
			gizmo.active_drag ~= nil or
			gizmo.hovered_handle ~= nil
	)
	camera.Update(dt)
	state.View:SetPosition(camera.GetPosition():Copy())
	state.View:SetRotation(camera.GetRotation():Copy())
end

function view_camera.Stop(state)
	camera.speed = state.SavedSpeed
	camera.key_up, camera.key_down = unpack(state.SavedKeys)
	camera.SetBlockMovement(false)
	camera.SetBlockDragging(false)
end

return view_camera
