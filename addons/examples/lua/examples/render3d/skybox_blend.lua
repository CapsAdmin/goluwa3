local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local weather = import("goluwa/render3d/weather.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local material = import("lua/source_loader/source2/material.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local pvars = import("goluwa/cli/pvars.lua")
local skybox_estimate = import("goluwa/render3d/skybox_estimate.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local timer = import("goluwa/timer.lua")
local sky = import("lua/source_loader/sky.lua")
local DEFAULT_SKYBOX = "materials/skybox/colorscript/a3_hotel_street.vmat"
steam.MountSourceGame(assert(steam.FindSourceGame(546560), "half-life: alyx is not installed"))
local skyboxes = {}

do
	local function walk(dir)
		for _, name in ipairs(vfs.Find(dir)) do
			local path = dir .. name

			if name:ends_with(".vmat_c") then
				local info = material.GetInfo(path:sub(1, -3))

				if info.shader == "sky.vfx" and info.textures.g_tSkyTexture then
					skyboxes[#skyboxes + 1] = {
						Text = path:sub(#"materials/skybox/" + 1, -#".vmat_c" - 1),
						Value = info.path,
						texture = info.textures.g_tSkyTexture,
						exposure = 2 ^ (info.floats.g_flBrightnessExposureBias or 0),
					}
				end
			elseif not name:find(".", 1, true) then
				walk(path .. "/")
			end
		end
	end

	walk("materials/skybox/")

	for _, appid in ipairs{220, 4000} do
		local info = steam.FindSourceGame(appid)

		if info then steam.MountSourceGame(info) end
	end

	for _, name in ipairs(sky.Find()) do
		skyboxes[#skyboxes + 1] = {Text = "source 1/" .. name, Value = "source1:" .. name, source1 = name, exposure = 1}
	end

	table.sort(skyboxes, |a, b|-> a.Text < b.Text)
end

local source1_cubes = {}

local state = {
	skybox = DEFAULT_SKYBOX,
	intensity = atmosphere.GetSkyboxIntensity(),
	sun_elevation = 40.494648,
	sun_azimuth = 348.145752,
	cloud_height = 1500,
	cloud_thickness = 1200,
}

-- on_ready runs once the skybox is in place; source 1 skyboxes are assembled from their faces first
local function select_skybox(path, on_ready)
	for _, entry in ipairs(skyboxes) do
		if entry.Value == path then
			state.skybox = path
			state.exposure = entry.exposure
			state.estimate = nil
			atmosphere.SetSkyboxIntensity(state.intensity * entry.exposure)

			if not entry.source1 then
				atmosphere.SetSkybox(entry.texture)
				return on_ready()
			end

			if source1_cubes[entry.source1] then
				atmosphere.SetSkyboxTexture(source1_cubes[entry.source1])
				return on_ready()
			end

			return sky.Load(entry.source1, function(cube)
				source1_cubes[entry.source1] = cube

				if state.skybox ~= path then return end

				atmosphere.SetSkyboxTexture(cube)
				on_ready()
			end)
		end
	end

	error("unknown skybox " .. path)
end

local function set_intensity(intensity)
	state.intensity = intensity
	atmosphere.SetSkyboxIntensity(intensity * state.exposure)
end

local function update_sun()
	local pitch, yaw = math.rad(state.sun_elevation), math.rad(state.sun_azimuth)
	weather.SetTimeScale(0)
	weather.SetSunDirection(Vec3(math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw)))
end

local function estimate()
	local cube = atmosphere.skybox_texture

	if not cube:IsReady() then return "the skybox is still loading" end

	local result = skybox_estimate.Estimate(cube)
	state.estimate = result
	state.sun_elevation = result.fitted_elevation
	state.sun_azimuth = result.sun_azimuth
	update_sun()
	weather.SetAerosolVisibility(result.aerosol_visibility)
	set_intensity(result.intensity / state.exposure)
	return string.format(
		"painted sun %.0f° up%s, fitted %d°, visibility %.0f km, error %.2f",
		result.sun_elevation,
		result.sun_visible and "" or " (not visible)",
		result.fitted_elevation,
		result.aerosol_visibility / 1000,
		result.error
	)
end

local function build_clouds()
	local cube = atmosphere.skybox_texture

	if not cube:IsReady() then return timer.Delay(0.1, build_clouds) end

	local sun = (state.estimate or skybox_estimate.Estimate(cube)).sun_direction
	skybox_estimate.ApplyClouds(cube, sun, state.cloud_height, state.cloud_thickness)
end

local function set_clouds(enabled)
	if enabled then
		local layers = {}

		for i, layer in ipairs(weather.GetCloudLayers()) do
			layers[i] = {}

			for key in pairs(clouds.LAYER_DEFAULTS) do
				layers[i][key] = layer[key]
			end
		end

		state.clouds_restore = {blend = atmosphere.GetSkyboxBlend(), layers = layers}
		atmosphere.SetSkyboxBlend(0)
		build_clouds()
	else
		atmosphere.SetSkyboxBlend(state.clouds_restore.blend)
		skybox_estimate.ClearClouds()
		weather.SetCloudLayers(state.clouds_restore.layers)
		state.clouds_restore = nil
	end
end

local function set_as_is(enabled)
	if enabled then
		state.restore = {
			blend = atmosphere.GetSkyboxBlend(),
			match = atmosphere.GetSkyboxMatch(),
			fog = pvars.Get("r_pass_volumetric_fog"),
		}
		atmosphere.SetSkyboxBlend(1)
		atmosphere.SetSkyboxMatch(0)
		pvars.SetSession("r_pass_volumetric_fog", false)
	else
		atmosphere.SetSkyboxBlend(state.restore.blend)
		atmosphere.SetSkyboxMatch(state.restore.match)
		pvars.SetSession("r_pass_volumetric_fog", state.restore.fog)
		state.restore = nil
	end
end

select_skybox(DEFAULT_SKYBOX, function() end)
update_sun()
local root = Entity.New{Name = "skybox_blend_example"}
shapes.Box{
	Name = "floor",
	Parent = root,
	Position = Vec3(0, -0.15, 0),
	Size = Vec3(40, 0.3, 40),
	Material = shapes.Material{Color = Color(0.5, 0.5, 0.5, 1), Roughness = 0.8, Metallic = 0},
	RigidBody = false,
}
shapes.Sphere{
	Name = "mirror_sphere",
	Parent = root,
	Position = Vec3(-1.5, 1, 0),
	Radius = 1,
	Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.02, Metallic = 1},
	RigidBody = false,
}
shapes.Sphere{
	Name = "diffuse_sphere",
	Parent = root,
	Position = Vec3(1.5, 1, 0),
	Radius = 1,
	Material = shapes.Material{Color = Color(0.8, 0.8, 0.8, 1), Roughness = 0.9, Metallic = 0},
	RigidBody = false,
}
local Knob = react.Component(
	|props| -> do
		local value, set_value = react.UseState(props.Value)
		return ui.Column{layout = {GrowWidth = 1, ChildGap = 2, AlignmentX = "stretch"}}{
			ui.Text{
				Text = string.format(props.Format or "%s: %.2f", props.Label, props.Display and props.Display(value) or value),
				IgnoreMouseInput = true,
			},
			ui.Slider{
				Min = props.Min,
				Max = props.Max,
				Value = props.Value,
				layout = {GrowWidth = 1},
				OnChange = |v| -> do
					set_value(v)
					props.OnChange(v)
				end,
			},
		}
	end
)
local SkyboxContent = react.Component(
	||-> do
		local as_is, set_as_is_state = react.UseState(state.restore ~= nil)
		local report, set_report = react.UseState("")
		local clouds_on, set_clouds_on = react.UseState(state.clouds_restore ~= nil)
		local estimates, set_estimates = react.UseState(0)
		return ui.Column{Padding = "M", layout = {GrowWidth = 1, ChildGap = 8, AlignmentX = "stretch"}}{
		ui.Dropdown{
			Options = skyboxes,
			Value = state.skybox,
			Searchable = true,
			layout = {GrowWidth = 1},
			OnSelect = |value| -> do
				select_skybox(value, function()
					if state.clouds_restore then build_clouds() end
				end)
			end,
		},
		ui.Button{
			Text = "Estimate atmosphere from the skybox",
			Mode = "outline",
			OnClick = ||-> do
				set_report(estimate())
				set_estimates(estimates + 1)
			end,
		},
		ui.Text{Text = report, IgnoreMouseInput = true},
		ui.Checkbox{
			Text = "clouds from the skybox (engine clouds, blend 0)",
			Value = clouds_on,
			OnChange = |checked| -> do
				set_clouds(checked)
				set_clouds_on(checked)
			end,
		},
		Knob{
			Label = "cloud base height (m)",
			Format = "%s: %.0f",
			Min = 300,
			Max = 6000,
			Value = state.cloud_height,
			OnChange = |v| -> do
				state.cloud_height = v

				if state.clouds_restore then build_clouds() end
			end,
		},
		Knob{
			Label = "cloud thickness (m)",
			Format = "%s: %.0f",
			Min = 100,
			Max = 4000,
			Value = state.cloud_thickness,
			OnChange = |v| -> do
				state.cloud_thickness = v

				if state.clouds_restore then build_clouds() end
			end,
		},
		ui.Checkbox{
			Text = "show the skybox as is (blend 1, match 0, no fog pass)",
			Value = as_is,
			OnChange = |checked| -> do
				set_as_is(checked)
				set_as_is_state(checked)
			end,
		},
		Knob{
			Key = "blend" .. tostring(as_is) .. tostring(clouds_on),
			Label = "blend",
			Min = 0,
			Max = 1,
			Value = atmosphere.GetSkyboxBlend(),
			OnChange = atmosphere.SetSkyboxBlend,
		},
		Knob{
			Key = "match" .. tostring(as_is),
			Label = "match (0 raw, 1 brightness from the air)",
			Min = 0,
			Max = 1,
			Value = atmosphere.GetSkyboxMatch(),
			OnChange = atmosphere.SetSkyboxMatch,
		},
		Knob{
			Label = "tint (colour from the air)",
			Min = 0,
			Max = 1,
			Value = atmosphere.GetSkyboxTint(),
			OnChange = atmosphere.SetSkyboxTint,
		},
		Knob{
			Label = "match lod",
			Min = 0,
			Max = 10,
			Value = atmosphere.GetSkyboxMatchLod(),
			OnChange = atmosphere.SetSkyboxMatchLod,
		},
		Knob{
			Key = "intensity" .. estimates,
			Label = "raw intensity",
			Format = "%s: %.0f",
			Min = 1,
			Max = 6,
			Value = math.log10(state.intensity),
			Display = |v| -> 10 ^ v,
			OnChange = |v| -> set_intensity(10 ^ v),
		},
		Knob{
			Label = "skybox yaw",
			Format = "%s: %.0f°",
			Min = -180,
			Max = 180,
			Value = math.deg(atmosphere.GetSkyboxYaw()),
			OnChange = |v| -> atmosphere.SetSkyboxYaw(math.rad(v)),
		},
		Knob{
			Key = "visibility" .. estimates,
			Label = "aerosol visibility (km)",
			Format = "%s: %.1f",
			Min = math.log10(2000),
			Max = math.log10(300000),
			Value = math.log10(weather.GetAerosolVisibility()),
			Display = |v| -> 10 ^ v / 1000,
			OnChange = |v| -> weather.SetAerosolVisibility(10 ^ v),
		},
		Knob{
			Key = "elevation" .. estimates,
			Label = "sun elevation",
			Format = "%s: %.1f°",
			Min = -10,
			Max = 90,
			Value = state.sun_elevation,
			OnChange = |v| -> do
				state.sun_elevation = v
				update_sun()
			end,
		},
		Knob{
			Key = "azimuth" .. estimates,
			Label = "sun azimuth",
			Format = "%s: %.0f°",
			Min = 0,
			Max = 360,
			Value = state.sun_azimuth,
			OnChange = |v| -> do
				state.sun_azimuth = v
				update_sun()
			end,
		},
	}
	end
)
local SkyboxWindow = react.Component(
	||-> ui.Window{
		Title = "SKYBOX BLEND",
		Pinnable = true,
		Padding = "none",
		Size = Vec2(380, 880),
		Position = Vec2(16, 104),
	}{SkyboxContent{}}
)
desktop.RegisterProgram{
	Name = "Skybox blend",
	Icon = "palette",
	Positioned = true,
	Content = SkyboxContent,
	Create = function()
		return react.Mount(SkyboxWindow{}, Panel.World):GetEntity()
	end,
}
desktop.Open("Skybox blend")

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 1.6, 6))
	cam:SetAngles(Deg3(0, 0, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.character_movement:SetEyePosition(cam:GetPosition())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
