local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local physics_sounds = import("lua/autorun/audio/physics_sounds.lua")
local MAX_DISTANCE = 50
local MAX_ROLL_SPEED = 5
local MAX_SLIP_SPEED = 4
local MASS = 20
local DRUM_SIZE = 0.625
local PAD_SIZE = 240
local UP = Vec3(0, 1, 0)
local surfaces = physics_sounds.GetSurfaces()
local entity_a = {}
local entity_b = {}
local sim = {
	playing = false,
	surface_a = "wood_box",
	surface_b = "concrete",
	size_a = 1,
	size_b = 1,
	rate = 0.5,
	speed = 6,
	randomness = 2,
	rolling = 0,
	sliding = 0,
	right = 0,
	forward = 10,
	next_impact = 0,
}

local function get_position()
	local camera = render3d.GetCamera()
	local rotation = camera:GetRotation()
	local forward = rotation:GetForward()
	forward.y = 0
	forward:Normalize()
	return camera:GetPosition() + forward:GetCross(UP) * sim.right + forward * sim.forward
end

event.AddListener("Update", "impact_sound_panel", function()
	if not sim.playing then return end

	local now = system.GetElapsedTime()
	local position = get_position()

	if sim.rolling > 0 or sim.sliding > 0 then
		local roll = sim.rolling * MAX_ROLL_SPEED
		local slip = sim.sliding * MAX_SLIP_SPEED
		event.Call(
			"Contact",
			{
				Entity = entity_a,
				Other = entity_b,
				Surface = sim.surface_b,
				Size = sim.size_b * DRUM_SIZE,
				Position = position,
				Normal = UP,
				Slip = slip,
				Roll = roll,
				Rolling = true,
				Mass = MASS,
			}
		)
		event.Call(
			"Contact",
			{
				Entity = entity_b,
				Other = entity_a,
				Surface = sim.surface_a,
				Size = sim.size_a * DRUM_SIZE,
				Position = position,
				Normal = UP * -1,
				Slip = slip,
				Roll = roll,
				Rolling = false,
				Mass = MASS,
			}
		)
	end

	if now < sim.next_impact then return end

	sim.next_impact = now + math.random() * sim.rate
	local speed = math.max(sim.speed + math.randomf(-sim.randomness, sim.randomness), 0)
	event.Call(
		"Impact",
		{
			Entity = entity_b,
			Other = entity_a,
			Kind = "physics",
			Surface = sim.surface_a,
			Size = sim.size_a * DRUM_SIZE,
			Position = position,
			Normal = UP,
			Speed = speed,
			Mass = MASS,
		}
	)
	event.Call(
		"Impact",
		{
			Entity = entity_a,
			Other = entity_b,
			Kind = "physics",
			Surface = sim.surface_b,
			Size = sim.size_b * DRUM_SIZE,
			Position = position,
			Normal = UP * -1,
			Speed = speed,
			Mass = MASS,
		}
	)
end)

local Knob = react.Component(
	|props| -> do
		local value, set_value = react.UseState(props.Value)
		return ui.Column{layout = {GrowWidth = 1, ChildGap = 2, AlignmentX = "stretch"}}{
			ui.Text{Text = string.format("%s: %.2f", props.Label, value), IgnoreMouseInput = true},
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
local SurfaceDropdown = react.Component(
	|props| -> ui.Row{layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center", AlignmentX = "start"}}{
		ui.Text{Text = props.Label, IgnoreMouseInput = true},
		ui.Dropdown{
			Options = surfaces,
			Value = props.Value,
			Searchable = true,
			OnSelect = |value| -> props.OnChange(value),
		},
	}
)
local ImpactSoundContent = react.Component(
	||-> do
		local playing, set_playing = react.UseState(sim.playing)
		local right, set_right = react.UseState(sim.right)
		local forward, set_forward = react.UseState(sim.forward)
		return ui.Column{Padding = "M", layout = {GrowWidth = 1, ChildGap = 8, AlignmentX = "stretch"}}{
			SurfaceDropdown{
				Label = "A",
				Value = sim.surface_a,
				OnChange = |value| -> do
					sim.surface_a = value
				end,
			},
			SurfaceDropdown{
				Label = "B",
				Value = sim.surface_b,
				OnChange = |value| -> do
					sim.surface_b = value
				end,
			},
			Knob{
				Label = "size A (oil drum = 1, pitch = 1 / size)",
				Min = 0.25,
				Max = 4,
				Value = sim.size_a,
				OnChange = |value| -> do
					sim.size_a = value
				end,
			},
			Knob{
				Label = "size B",
				Min = 0.25,
				Max = 4,
				Value = sim.size_b,
				OnChange = |value| -> do
					sim.size_b = value
				end,
			},
			Knob{
				Label = "impact rate",
				Min = 0,
				Max = 1,
				Value = sim.rate,
				OnChange = |value| -> do
					sim.rate = value
				end,
			},
			Knob{
				Label = "velocity",
				Min = 0,
				Max = 20,
				Value = sim.speed,
				OnChange = |value| -> do
					sim.speed = value
				end,
			},
			Knob{
				Label = "velocity randomness",
				Min = 0,
				Max = 10,
				Value = sim.randomness,
				OnChange = |value| -> do
					sim.randomness = value
				end,
			},
			Knob{
				Label = "sliding",
				Min = 0,
				Max = 1,
				Value = sim.sliding,
				OnChange = |value| -> do
					sim.sliding = value
				end,
			},
			Knob{
				Label = "rolling",
				Min = 0,
				Max = 1,
				Value = sim.rolling,
				OnChange = |value| -> do
					sim.rolling = value
				end,
			},
			ui.Text{
				Text = string.format("position: %.1f m right, %.1f m forward", right, forward),
				IgnoreMouseInput = true,
			},
			ui.Slider{
				Mode = "2d",
				Min = Vec2(-MAX_DISTANCE, MAX_DISTANCE),
				Max = Vec2(MAX_DISTANCE, -MAX_DISTANCE),
				Value = Vec2(sim.right, sim.forward),
				Size = Vec2(PAD_SIZE, PAD_SIZE),
				layout = {MinSize = Vec2(PAD_SIZE, PAD_SIZE)},
				OnChange = |value| -> do
					local length = value:GetLength()

					if length > MAX_DISTANCE then value = value * (MAX_DISTANCE / length) end

					sim.right, sim.forward = value.x, value.y
					set_right(value.x)
					set_forward(value.y)
				end,
			},
			ui.Button{
				Text = playing and "Pause" or "Play",
				Mode = "outline",
				OnClick = ||-> do
					sim.playing = not sim.playing
					sim.next_impact = 0
					set_playing(sim.playing)
				end,
			},
		}
	end
)
local ImpactSoundView = react.Component(
	||-> do
		local shown, set_shown = react.UseState(true)
		return ui.Window{
			Title = "IMPACT SOUNDS",
			Pinnable = true,
			Padding = "none",
			Size = Vec2(320, 780),
			Position = Vec2(0, 104),
			OnVisibilityChanged = |_, visible| -> set_shown(visible),
		}{shown and ImpactSoundContent{}}
	end
)
desktop.RegisterProgram{
	Name = "Impact sounds",
	Icon = "physics",
	Positioned = true,
	Content = ImpactSoundContent,
	Create = function()
		return react.Mount(ImpactSoundView{}, Panel.World):GetEntity()
	end,
}
