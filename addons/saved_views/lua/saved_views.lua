local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local luadata = import("goluwa/codecs/luadata.lua")
local loaders = import("goluwa/loaders.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local climate = import("goluwa/render3d/climate.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local View = import("goluwa/render3d/view.lua")
local Shot = import("goluwa/render3d/shot.lua")
local saved_views = {}
local scene_name
local scene_args
local active_view

event.AddListener("SceneLoad", "saved_views", function()
	scene_name = nil
	scene_args = nil
end)

function saved_views.SetSceneName(name, args)
	scene_name = name
	scene_args = args
end

function saved_views.SetScene(args)
	local source = debug.getinfo(2, "S").source
	local name = source:match("^@(.-)%.lua$")
	name = name and (name:match("/lua/(.+)$") or name:match("^lua/(.+)$"))

	if not name then
		error(
			"cannot infer a scene name from " .. source .. ", it is not under a lua directory",
			2
		)
	end

	saved_views.SetSceneName(name, args)
end

function saved_views.GetScene()
	return scene_name or loaders.loaded_map, scene_args
end

local function get_directory()
	return vfs.GetAddonInfo("saved_views").path .. "lua/view_data/"
end

local function get_file_path(scene)
	return get_directory() .. scene:gsub("[^%w_]+", "_") .. ".lua"
end

local function args_equal(a, b)
	a = a or {}
	b = b or {}

	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end

	for k in pairs(b) do
		if a[k] == nil then return false end
	end

	return true
end

function saved_views.GetData(scene)
	local str = fs.read_file(get_file_path(scene))

	if not str then return {scene = scene, views = {}} end

	return assert(luadata.Decode(str))
end

function saved_views.GetAllData()
	local out = {}

	for _, file in ipairs(fs.get_files(get_directory()) or {}) do
		if file:ends_with(".lua") then
			list.insert(out, assert(luadata.Decode(assert(fs.read_file(get_directory() .. file)))))
		end
	end

	table.sort(out, function(a, b)
		return a.scene < b.scene
	end)

	return out
end

function saved_views.FindScene(scene)
	if not scene then
		return saved_views.GetScene() or error("no current scene, give the map name", 0)
	end

	local found

	for _, data in ipairs(saved_views.GetAllData()) do
		if
			data.scene == scene or
			data.scene:match(":(.+)$") == scene or
			data.scene:match("[^/]+$") == scene
		then
			if data.scene == scene then return data.scene end

			if found then
				error("map " .. scene .. " matches both " .. found .. " and " .. data.scene, 0)
			end

			found = data.scene
		end
	end

	return found or error("no saved views for " .. scene, 0)
end

function saved_views.Find(scene, name)
	scene = saved_views.FindScene(scene)
	local entry = saved_views.GetData(scene).views[name] or
		error("no view " .. name .. " in " .. scene, 0)
	return scene, entry
end

function saved_views.GetExposure()
	local texture = post_source.GetExposureTexture(true)

	if not texture then return end

	local current, metered_ev = texture:Download():GetPixelFloat(0, 0)
	local view = View.GetActive()
	local compensation = view and view.ExposureCompensation or exposure.GetCompensation()
	return exposure.LOG_EXPOSURE_AT_EV0 - math.log(current, 2) + compensation,
	metered_ev
end

function saved_views.Capture()
	local camera = render3d.GetMainCamera()
	local latitude, longitude = weather.GetLocation()
	local out = {
		pos = camera:GetPosition():Copy(),
		rot = camera:GetRotation():Copy(),
		fov = camera:GetFOV(),
		time = weather.GetTime(),
		latitude = latitude,
		longitude = longitude,
		ev = (saved_views.GetExposure()),
	}
	local captured_climate = climate.Capture()

	if next(captured_climate) then out.climate = captured_climate end

	local _, args = saved_views.GetScene()
	out.args = args
	return out
end

function saved_views.Save(name, note)
	local scene = saved_views.GetScene() or error("no scene to save a view for", 0)
	local data = saved_views.GetData(scene)
	data.scene = scene
	data.views[name] = saved_views.Capture()
	data.views[name].note = note
	fs.create_directory_recursive(get_directory())
	assert(fs.write_file(get_file_path(scene), luadata.Encode(data, true)))
	return get_file_path(scene)
end

function saved_views.Remove(scene, name)
	scene = saved_views.FindScene(scene)
	local data = saved_views.GetData(scene)
	data.views[name] = nil

	if next(data.views) then
		assert(fs.write_file(get_file_path(scene), luadata.Encode(data, true)))
	else
		assert(fs.remove_file(get_file_path(scene)))
	end
end

function saved_views.EnterScene(scene, args)
	local current, current_args = saved_views.GetScene()

	if current == scene and args_equal(current_args, args) then return end

	if scene:find(":", nil, true) then
		loaders.Load(scene)
		return
	end

	for key, value in pairs(args or {}) do
		process.setenv(key, tostring(value))
	end

	local path = "lua/" .. scene .. ".lua"

	for key in pairs(import.loaded) do
		if key:ends_with(path) then import.loaded[key] = nil end
	end

	import(path)
	scene_name = scene
	scene_args = args
end

function saved_views.ApplyWorld(entry)
	weather.SetTimeScale(0)
	weather.SetLocation(entry.latitude, entry.longitude)
	weather.SetTime(entry.time)
	climate.SetPreset(entry.climate or {}, 0)
end

function saved_views.GetProperties(entry)
	return {
		Position = entry.pos,
		Rotation = entry.rot,
		FOV = entry.fov,
		ExposureLock = entry.ev or false,
	}
end

function saved_views.Apply(scene, name, cb, loaded_quiet)
	local entry
	scene, entry = saved_views.Find(scene, name)
	saved_views.EnterScene(scene, entry.args)
	saved_views.ApplyWorld(entry)

	if not active_view or not active_view:IsValid() then
		active_view = View.New{Priority = 90}
	end

	for key, value in pairs(saved_views.GetProperties(entry)) do
		active_view["Set" .. key](active_view, value)
	end

	active_view:Activate()
	render3d.CutCamera()

	if cb then
		Shot.WaitLoaded(loaded_quiet or 1.5, function()
			cb(active_view, entry)
		end)
	end

	return entry
end

function saved_views.Release()
	if active_view and active_view:IsValid() then active_view:Remove() end

	active_view = nil
end

function saved_views.Format()
	local scene, args = saved_views.GetScene()
	local capture = saved_views.Capture()
	local _, metered_ev = saved_views.GetExposure()
	local str = ""

	if scene then
		str = str .. (scene:find(":", nil, true) and "map = " or "scene = ") .. scene .. "\n"
	end

	if args then
		str = str .. "args = " .. luadata.Encode(args, true):gsub("^return ", ""):trim() .. "\n"
	end

	str = str .. "pos = " .. tostring(capture.pos) .. "\n"
	str = str .. "rot = " .. tostring(capture.rot) .. "\n"
	str = str .. "fov = " .. tostring(capture.fov) .. "\n"
	str = str .. string.format("time = %.4f\n", capture.time)
	str = str .. string.format("latitude = %.6f\nlongitude = %.6f\n", capture.latitude, capture.longitude)

	if capture.ev then
		str = str .. string.format(
				"ev = %.3f\nmetered_ev = %.3f\neye = %s\n",
				capture.ev,
				metered_ev,
				tostring(exposure.IsEye())
			)
	end

	if capture.climate then
		str = str .. "climate = " .. luadata.Encode(capture.climate, true):gsub("^return ", ""):trim() .. "\n"
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

	return str
end

return saved_views
