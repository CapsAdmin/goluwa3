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
	table.sort(skyboxes, |a, b|-> a.Text < b.Text)
end

local state = {
	skybox = DEFAULT_SKYBOX,
	intensity = atmosphere.GetSkyboxIntensity(),
	sun_elevation = 40.494648,
	sun_azimuth = 348.145752,
}

local function select_skybox(path)
	for _, entry in ipairs(skyboxes) do
		if entry.Value == path then
			state.skybox = path
			atmosphere.SetSkybox(entry.texture)
			atmosphere.SetSkyboxIntensity(state.intensity * entry.exposure)
			return
		end
	end

	error("unknown skybox " .. path)
end

local function set_intensity(intensity)
	state.intensity = intensity
	select_skybox(state.skybox)
end

local function update_sun()
	local pitch, yaw = math.rad(state.sun_elevation), math.rad(state.sun_azimuth)
	weather.SetTimeScale(0)
	weather.SetSunDirection(Vec3(math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw)))
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

select_skybox(DEFAULT_SKYBOX)
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
		return ui.Column{Padding = "M", layout = {GrowWidth = 1, ChildGap = 8, AlignmentX = "stretch"}}{
		ui.Dropdown{
			Options = skyboxes,
			Value = state.skybox,
			Searchable = true,
			layout = {GrowWidth = 1},
			OnSelect = |value| -> select_skybox(value),
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
			Key = "blend" .. tostring(as_is),
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
		Size = Vec2(360, 600),
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
