local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local View = objects.CreateTemplate("render3d_view")
local commands = import("goluwa/cli/commands.lua")
local active = {}
local activation_serial = 0
local camera_setters = {}

for _, name in ipairs{
	"Position",
	"Rotation",
	"FOV",
	"NearZ",
	"FarZ",
	"Scale",
	"OrthoMode",
	"OrthoHalfHeight",
} do
	View:GetSet(name, nil, {callback = "OnCameraPropertyChanged"})
	camera_setters[name] = "Set" .. name
end

View:GetSet("Priority", 0, {callback = "OnPriorityChanged"})
View:GetSet("HidePlayer", true)
View:GetSet("Ignore", nil)
View:GetSet("HideHud", false)
View:GetSet("KeepControls", false)
View:GetSet("ExposureLock", false)
View:GetSet("ExposureHold", false)
View:GetSet("ExposureCompensation", false)

local function sort_active(a, b)
	if a.Priority ~= b.Priority then return a.Priority > b.Priority end

	return a.activation_serial > b.activation_serial
end

local function apply_winner()
	table.sort(active, sort_active)
	render2d.SetHudHidden("view", active[1] and active[1].HideHud)

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
	self.Scale = camera:GetScale()
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
	local weather = import("goluwa/render3d/weather.lua")
	local clipboard = import("goluwa/bindings/clipboard.lua")
	local engines = import("goluwa/engines.lua")
	local raycast = import("goluwa/render3d/raycast.lua")
	local exposure = import("goluwa/render3d/exposure.lua")
	local post_source = import("goluwa/render3d/post_source.lua")
	local cam = render3d.GetMainCamera()
	local str = ""

	if engines.loaded_map then
		str = str .. "map = " .. engines.loaded_map .. "\n"
	end

	str = str .. "pos = " .. tostring(cam:GetPosition()) .. "\n"
	str = str .. "rot = " .. tostring(cam:GetRotation()) .. "\n"
	str = str .. "fov = " .. tostring(cam:GetFOV()) .. "\n"
	str = str .. string.format("time = %.4f\n", weather.GetTime())
	local latitude, longitude = weather.GetLocation()
	str = str .. string.format("latitude = %.6f\nlongitude = %.6f\n", latitude, longitude)
	local exposure_texture = post_source.GetExposureTexture(true)

	if exposure_texture then
		local view = active[1]
		local current, metered_ev = exposure_texture:Download():GetPixelFloat(0, 0)
		local compensation = view and view.ExposureCompensation or exposure.GetCompensation()
		str = str .. string.format(
				"ev = %.3f\nmetered_ev = %.3f\neye = %s\n",
				exposure.LOG_EXPOSURE_AT_EV0 - math.log(current, 2) + compensation,
				metered_ev,
				tostring(exposure.IsEye())
			)
	end

	local hit = raycast.CastClosestFromCamera(render3d.GetCamera())

	if hit and hit.primitive then
		local visual = hit.primitive.entity.VisualOwner

		if visual then
			local material = visual.MaterialOverride or
				hit.primitive.material or
				render3d.GetDefaultMaterial()
			str = str .. "entity = " .. tostring(visual.Owner) .. "\n"
			str = str .. "model = " .. visual:GetModelPath() .. "\n"
			str = str .. "material = " .. material:GetName() .. "\n"
		end
	end

	clipboard.Set(str)
end)

return View:Register()
