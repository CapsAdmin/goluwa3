local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local View = RENDER_3D and import("goluwa/render3d/view.lua")
local players = import("lua/players.lua")
local META = objects.CreateTemplate("tool_camera")
META.Network = {
	Target = {"string", 0.5, "reliable"},
	Direction = {"vec3", 0.5, "reliable"},
}
META:StartStorable()
META:GetSet("Target", "")
META:GetSet("Direction", Vec3(0, 0, -1))
META:EndStorable()
local BODY = {Color = Color(0.12, 0.12, 0.14, 1), Roughness = 0.5, Metallic = 0.3}
local LENS = {Color = Color(0.05, 0.1, 0.2, 1), Roughness = 0.05, Metallic = 0.9}
local CHEST = 0.7
local MIN_DISTANCE = 0.05
local look = Quat()
local eye = Vec3()
local view
local view_camera

function META:Initialize()
	self:AddGlobalEvent("LateUpdate")

	if RENDER_3D then
		self.pivot = Entity.New{Name = "pivot", Parent = self.Owner, Transient = true, transform = {}}
		Entity.New{
			Name = "body",
			Parent = self.pivot,
			Transient = true,
			transform = {},
			model = {
				ModelPath = "models/box.lua",
				ModelOptions = {size = Vec3(0.18, 0.14, 0.12)},
				MaterialConfig = BODY,
			},
		}
		Entity.New{
			Name = "lens",
			Parent = self.pivot,
			Transient = true,
			transform = {Position = Vec3(0, 0, -0.08)},
			model = {
				ModelPath = "models/box.lua",
				ModelOptions = {size = Vec3(0.08, 0.08, 0.05)},
				MaterialConfig = LENS,
			},
		}
	end
end

function META:OnRemove()
	if view_camera == self then META.Release() end
end

function META:GetTargetEntity()
	if self.Target == "" then return nil end

	local entity = objects.GetObjectByGUID(self.Target)

	if entity:IsValid() then return entity end
end

function META:GetViewPosition()
	return self.Owner.transform:GetPosition() + Vec3(0, 0.02, 0)
end

function META:GetViewDirection()
	local target = self:GetTargetEntity()

	if not target then return self.Direction end

	local transform = target.transform
	eye:CopyFrom(
		(
				transform:GetRenderPositionRotation() or
				transform:GetPosition()
			) + target.character_movement:GetViewOffset() * CHEST
	)
	eye:Sub(self:GetViewPosition())

	if eye:GetLength() < MIN_DISTANCE then return self.Direction end

	return eye:GetNormalized()
end

function META:OnLateUpdate()
	if self.pivot then
		self.pivot.transform:SetRotation(look:SetLookDirection(self:GetViewDirection()))
	end
end

function META.Release()
	if view_camera and view_camera:IsValid() then
		view_camera.Owner.visibility:RemoveHider("camera_view")
	end

	if view then
		view:Remove()
		view = nil
	end

	view_camera = nil
end

if RENDER_3D then
	event.AddListener("KeyInput", "tool_camera", function(key, press)
		if not press or key ~= "numpad_0" then return end

		if view then
			META.Release()
			return true
		end

		local local_player = players.GetLocal()
		local newest

		for _, camera in ipairs(META.Instances) do
			if camera:IsValid() and camera.Owner:GetOwnedBy() == players.GetClient(local_player) then
				newest = camera
			end
		end

		if not newest then return end

		view_camera = newest
		newest.Owner:EnsureComponent("visibility"):AddHider("camera_view")
		view = View.New{Priority = 50, HidePlayer = false, KeepControls = true}:Activate()
		return true
	end)

	event.AddListener("LateUpdate", "tool_camera", function()
		if not view then return end

		view:SetPosition(view_camera:GetViewPosition())
		view:SetRotation(look:SetLookDirection(view_camera:GetViewDirection()):Copy())
	end)
end

return META:Register()
