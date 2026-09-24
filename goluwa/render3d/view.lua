local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local View = objects.CreateTemplate("render3d_view")
local commands = import("goluwa/cli/commands.lua")
local active = {}
local activation_serial = 0
local camera_setters = {}

for _, name in ipairs{"Position", "Rotation", "FOV", "NearZ", "FarZ", "OrthoMode", "OrthoHalfHeight"} do
	View:GetSet(name, nil, {callback = "OnCameraPropertyChanged"})
	camera_setters[name] = "Set" .. name
end

View:GetSet("Priority", 0, {callback = "OnPriorityChanged"})
View:GetSet("ExposureLock", false)
View:GetSet("ExposureCompensation", false)
View:GetSet("LocalExposure", false)

local function sort_active(a, b)
	if a.Priority ~= b.Priority then return a.Priority > b.Priority end

	return a.activation_serial > b.activation_serial
end

local function apply_winner()
	table.sort(active, sort_active)

	if active[1] then active[1]:ApplyToCamera(render3d.GetMainCamera()) end
end

function View.GetActive()
	return active[1]
end

function View.New(config)
	local self = View:CreateObject()
	local camera = render3d.GetMainCamera()
	self.Position = camera:GetPosition():Copy()
	self.Rotation = camera:GetRotation():Copy()
	self.FOV = camera:GetFOV()
	self.NearZ = camera:GetNearZ()
	self.FarZ = camera:GetFarZ()
	self.OrthoMode = camera:GetOrthoMode()
	self.OrthoHalfHeight = camera:GetOrthoHalfHeight()

	if config then
		for key, value in pairs(config) do
			self["Set" .. key](self, value)
		end
	end

	return self
end

function View:ApplyToCamera(camera)
	for name, setter in pairs(camera_setters) do
		camera[setter](camera, self[name])
	end
end

function View:OnCameraPropertyChanged(name, old, new)
	if active[1] == self then
		local camera = render3d.GetMainCamera()
		camera[camera_setters[name]](camera, new)
	end
end

function View:OnPriorityChanged()
	if self:IsActive() then apply_winner() end
end

function View:IsActive()
	return self.activation_serial ~= nil
end

function View:IsRendered()
	return active[1] == self
end

function View:Activate()
	activation_serial = activation_serial + 1

	if not self:IsActive() then list.insert(active, self) end

	self.activation_serial = activation_serial
	apply_winner()
	return self
end

function View:Deactivate()
	if not self:IsActive() then return self end

	list.remove_value(active, self)
	self.activation_serial = nil
	apply_winner()
	return self
end

function View:OnRemove()
	self:Deactivate()
end

event.AddListener(
	"PreRenderPass",
	"render3d_view",
	function()
		if active[1] then active[1]:ApplyToCamera(render3d.GetMainCamera()) end
	end,
	{priority = 100}
)

commands.Add("copyview", function()
	local clipboard = import("goluwa/bindings/clipboard.lua")
	local cam = active[1]
	local str = ""
	str = str .. "pos = " .. tostring(cam.Position) .. "\n"
	str = str .. "ang = " .. tostring(cam.Rotation:GetAngles()) .. "\n"
	str = str .. "fov = " .. tostring(cam.FOV) .. "\n"
	clipboard.Set(str)
end)

return View:Register()
