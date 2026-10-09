local objects = import("goluwa/objects/objects.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local SceneView = import("goluwa/render3d/scene_view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("render3d_model_preview")
local DEFAULT_VIEW_OFFSET = Vec3(1, 1, 1):GetNormalized()
local aabb_corners = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}
META:GetSet("Width", 256, {callback = "OnSizeChanged"})
META:GetSet("Height", 256, {callback = "OnSizeChanged"})
META:GetSet("Padding", 1.1)
META:GetSet("ViewOffset", DEFAULT_VIEW_OFFSET)

local function populate_aabb_corners(aabb)
	aabb_corners[1].x, aabb_corners[1].y, aabb_corners[1].z = aabb.min_x, aabb.min_y, aabb.min_z
	aabb_corners[2].x, aabb_corners[2].y, aabb_corners[2].z = aabb.min_x, aabb.min_y, aabb.max_z
	aabb_corners[3].x, aabb_corners[3].y, aabb_corners[3].z = aabb.min_x, aabb.max_y, aabb.min_z
	aabb_corners[4].x, aabb_corners[4].y, aabb_corners[4].z = aabb.min_x, aabb.max_y, aabb.max_z
	aabb_corners[5].x, aabb_corners[5].y, aabb_corners[5].z = aabb.max_x, aabb.min_y, aabb.min_z
	aabb_corners[6].x, aabb_corners[6].y, aabb_corners[6].z = aabb.max_x, aabb.min_y, aabb.max_z
	aabb_corners[7].x, aabb_corners[7].y, aabb_corners[7].z = aabb.max_x, aabb.max_y, aabb.min_z
	aabb_corners[8].x, aabb_corners[8].y, aabb_corners[8].z = aabb.max_x, aabb.max_y, aabb.max_z
	return aabb_corners
end

function META.New(config)
	local self = META:CreateObject()
	self.view = SceneView.New{
		OnDrawGeometry = function(cmd)
			self:DrawTarget()
		end,
	}

	if config then
		for k, v in pairs(config) do
			local setter = self["Set" .. k]

			if setter then setter(self, v) else self[k] = v end
		end
	end

	return self
end

function META:OnSizeChanged()
	if not self.view then return end

	self.view:SetWidth(self.Width)
	self.view:SetHeight(self.Height)
end

function META:OnRemove()
	self.view:Remove()
	self.view = nil
	self.target = nil
end

function META:GetView()
	return self.view
end

function META:SetEnvironment(environment)
	self.view:SetEnvironment(environment)
end

function META:SetExposureCompensation(stops)
	self.view:SetExposureCompensation(stops)
end

function META:GetTexture()
	return self.view:GetTexture()
end

function META:Draw(x, y, w, h)
	render2d.PushTexture(self:GetTexture())
	render2d.PushColorUV(0, 1, 1, 0, 0)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopColorUV()
	render2d.PopTexture()
end

function META:SetTarget(visual)
	self.target = visual
end

function META:GetTarget()
	return self.target
end

function META:GetLocalAABB(visual)
	local aabb = visual.AABB

	if aabb.min_x > aabb.max_x then aabb = visual:BuildAABB() end

	return aabb
end

function META:ConfigureCamera(visual)
	local local_aabb = self:GetLocalAABB(visual)
	local world_matrix = visual:GetWorldMatrix()
	local center = world_matrix:TransformVector(
		Vec3(
			(local_aabb.min_x + local_aabb.max_x) / 2,
			(local_aabb.min_y + local_aabb.max_y) / 2,
			(local_aabb.min_z + local_aabb.max_z) / 2
		)
	)
	local forward = (-self:GetViewOffset()):GetNormalized()
	local yaw = math.atan2(-forward.x, -forward.z)
	local pitch = math.asin(math.max(-1, math.min(1, forward.y)))
	local rotation = Quat()
	rotation:Identity()
	rotation:RotateYaw(yaw)
	rotation:RotatePitch(pitch)
	forward = rotation:GetForward()
	local right = rotation:GetRight()
	local up = rotation:GetUp()
	local max_right = 0
	local max_up = 0
	local max_depth = 0
	local aspect = self:GetWidth() / self:GetHeight()

	for _, corner in ipairs(populate_aabb_corners(local_aabb)) do
		local world_pos = world_matrix:TransformVector(corner)
		local offset = world_pos - center
		max_right = math.max(max_right, math.abs(offset:GetDot(right)))
		max_up = math.max(max_up, math.abs(offset:GetDot(up)))
		max_depth = math.max(max_depth, math.abs(offset:GetDot(forward)))
	end

	local half_height = math.max(max_up, max_right / aspect)
	half_height = math.max(half_height * self:GetPadding(), 1e-4)
	local distance = math.max(max_depth + half_height * 2, 1)
	local camera = self.view:GetCamera()
	camera:SetOrthoMode(true)
	camera:SetOrthoHalfHeight(half_height)
	camera:SetNearZ(0.01)
	camera:SetFarZ(distance + max_depth + half_height * 4)
	camera:SetPosition(center - forward * distance)
	camera:SetRotation(rotation)
end

function META:DrawTarget()
	SceneView.DrawVisual(self.target)
end

function META:RenderTarget(visual)
	self:SetTarget(visual)

	if not visual:GetRenderEntries()[1] then
		error("model preview requires a visual with something to draw", 2)
	end

	self:ConfigureCamera(visual)
	self.view:RenderNow()
	return self:GetTexture()
end

function META:Refresh()
	if not self.target then return self:GetTexture() end

	return self:RenderTarget(self.target)
end

META:Register()
return META
