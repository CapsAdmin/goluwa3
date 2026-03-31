local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local window = import("goluwa/window.lua")
local shapes = import("lua/shapes.lua")
local UPDATE_ID = "scene_audio_spatial_bee_update"
local DRAW2D_ID = "scene_audio_spatial_bee_hud"
local state = rawget(_G, "__audio_spatial_bee_scene") or {}
_G.__audio_spatial_bee_scene = state

local function remove_entity(ent)
	if ent and ent.IsValid and ent:IsValid() then ent:Remove() end
end

if state.source then
	state.source:Stop()

	if state.source.Remove then state.source:Remove() end
end

event.RemoveListener("Update", UPDATE_ID)
event.RemoveListener("Draw2D", DRAW2D_ID)
remove_entity(state.bee_ent)
remove_entity(state.anchor_ent)
remove_entity(state.ground_ent)

if state.marker_ents then
	for _, ent in ipairs(state.marker_ents) do
		remove_entity(ent)
	end
end

local sample_rate = 48000
local duration = 2.0
local frame_count = math.floor(sample_rate * duration)
local samples = ffi.new("float[?]", frame_count)

for i = 0, frame_count - 1 do
	local t = i / sample_rate
	local wingbeat = 0.56 + 0.44 * (0.5 + 0.5 * math.sin(t * math.pi * 2 * 26.0))
	local body = math.sin(t * math.pi * 2 * 196.0) * 0.70 + math.sin(t * math.pi * 2 * 392.0) * 0.20 + math.sin(t * math.pi * 2 * 588.0) * 0.10
	local shimmer = math.sin(t * math.pi * 2 * 12.0) * 0.08
	samples[i] = (body * wingbeat + shimmer) * 0.18
end

audio.Initialize()
audio.SetDistanceModel("inverse_clamped")
audio.SetDopplerFactor(1.0)
audio.SetSpeedOfSound(343.3)
local ground_material = shapes.Material{Color = Color(0.18, 0.16, 0.14, 1), Roughness = 0.95, Metallic = 0}
local anchor_material = shapes.Material{Color = Color(0.92, 0.82, 0.22, 1), Roughness = 0.35, Metallic = 0.1}
local bee_material = shapes.Material{Color = Color(0.08, 0.08, 0.08, 1), Roughness = 0.45, Metallic = 0.05}
local orbit_material = shapes.Material{Color = Color(0.95, 0.58, 0.14, 1), Roughness = 0.75, Metallic = 0}
local center = Vec3(0, 2.1, -6)
state.ground_ent = shapes.Box{
	Name = "audio_spatial_bee_ground",
	Position = center + Vec3(0, -1.6, 0),
	Size = Vec3(18, 1.0, 18),
	Material = ground_material,
	RigidBody = {MotionType = "static", Friction = 0.9, Restitution = 0},
}
state.anchor_ent = shapes.Sphere{
	Name = "audio_spatial_bee_anchor",
	Position = center,
	Radius = 0.22,
	Material = anchor_material,
	Collision = false,
	PhysicsNoCollision = true,
}
state.marker_ents = {}

for i = 1, 12 do
	local angle = ((i - 1) / 12) * math.pi * 2
	local pos = center + Vec3(math.cos(angle) * 4.5, -0.7, math.sin(angle) * 4.5)
	state.marker_ents[i] = shapes.Box{
		Name = "audio_spatial_bee_orbit_marker",
		Position = pos,
		Size = Vec3(0.18, 0.18, 0.18),
		Material = orbit_material,
		Collision = false,
		PhysicsNoCollision = true,
	}
end

state.bee_ent, state.bee_body = shapes.Sphere{
	Name = "audio_spatial_bee_visual",
	Position = center + Vec3(4.5, 0.3, 0),
	Radius = 0.14,
	Material = bee_material,
	Collision = false,
	PhysicsNoCollision = true,
	RigidBody = {
		MotionType = "dynamic",
		AutomaticMass = false,
		Mass = 0.08,
		GravityScale = 0,
		LinearDamping = 1.8,
		AngularDamping = 8,
		CollisionEnabled = false,
		CanSleep = false,
		MaxLinearSpeed = 24,
	},
}
state.source = audio.CreateSource{
	data = samples,
	samples = frame_count,
	channels = 1,
	sample_rate = sample_rate,
}
state.source:SetLooping(true)
state.source:SetGain(0.55)
state.source:SetReferenceDistance(1.25)
state.source:SetMaxDistance(28)
state.source:SetRolloffFactor(1.15)
state.source:SetCone(80, 220, 0.25)

if state.bee_body and state.bee_body.GetPosition then
	state.source:SetPosition(state.bee_body:GetPosition())
	state.source:SetVelocity(state.bee_body:GetVelocity())
	state.source:SetDirection(Vec3(1, 0, 0))
end

state.source:Play()
state.center = center
state.start_time = system.GetElapsedTime()
state.last_listener_pos = nil
state.last_bee_target_pos = nil
state.font = state.font or fonts.GetDefaultFont()

event.AddListener("Update", UPDATE_ID, function(dt)
	local cam = render3d.GetCamera()

	if cam and cam.GetPosition then
		local cam_pos = cam:GetPosition():Copy()
		local listener_velocity = Vec3()

		if state.last_listener_pos and dt and dt > 0 then
			listener_velocity = (cam_pos - state.last_listener_pos) * (1 / dt)
		end

		state.last_listener_pos = cam_pos:Copy()
		audio.SetListenerPosition(cam_pos.x, cam_pos.y, cam_pos.z)
		audio.SetListenerVelocity(listener_velocity.x, listener_velocity.y, listener_velocity.z)

		if cam.GetRotation then
			local rotation = cam:GetRotation()
			local forward = rotation:GetForward()
			local up = rotation:GetUp()
			audio.SetListenerOrientation(forward.x, forward.y, forward.z, up.x, up.y, up.z)
		end
	end

	local t = system.GetElapsedTime() - state.start_time
	local orbit_radius = 4.5 + math.sin(t * 0.53) * 0.35
	local angle = t * 0.95
	local target_bee_pos = state.center + Vec3(
			math.cos(angle) * orbit_radius,
			0.35 + math.sin(t * 3.2) * 0.55,
			math.sin(angle) * (orbit_radius * 0.72)
		)
	local target_bee_velocity = Vec3()

	if state.last_bee_target_pos and dt and dt > 0 then
		target_bee_velocity = (target_bee_pos - state.last_bee_target_pos) * (1 / dt)
	end

	state.last_bee_target_pos = target_bee_pos:Copy()
	local bee_pos = target_bee_pos
	local bee_velocity = target_bee_velocity

	if
		state.bee_body and
		state.bee_body.GetPosition and
		state.bee_body.GetVelocity and
		dt and
		dt > 0
	then
		local current_pos = state.bee_body:GetPosition():Copy()
		local current_velocity = state.bee_body:GetVelocity():Copy()
		local position_error = target_bee_pos - current_pos
		local desired_velocity = target_bee_velocity + position_error * 3.5
		local desired_speed = desired_velocity:GetLength()

		if desired_speed > 12 then
			desired_velocity = desired_velocity / desired_speed * 12
		end

		local response = math.min(dt * 9, 1)
		local impulse = (desired_velocity - current_velocity) * (state.bee_body:GetMass() * response)
		state.bee_body:ApplyImpulse(impulse)
		bee_pos = state.bee_body:GetPosition():Copy()
		bee_velocity = state.bee_body:GetVelocity():Copy()
	end

	local speed = bee_velocity:GetLength()
	local bee_dir = speed > 0.0001 and (bee_velocity / speed) or Vec3(1, 0, 0)
	state.source:SetPosition(bee_pos)
	state.source:SetVelocity(bee_velocity)
	state.source:SetDirection(bee_dir)
	state.source:SetPitch(0.96 + math.sin(t * 5.7) * 0.05 + math.sin(t * 13.0) * 0.02)

	if state.source and not state.source:IsPlaying() then state.source:Play() end

	if (math.floor(t * 0.5) % 2) == 0 then
		state.source:SetCone(80, 220, 0.25)
	else
		state.source:SetCone(45, 160, 0.15)
	end

	state.source:SetOuterConeGain(0.18 + math.sin(t * 0.8) * 0.05)
end)

event.AddListener("Draw2D", DRAW2D_ID, function()
	local font = state.font or fonts.GetDefaultFont()

	if not font or not state.source then return end

	state.font = font
	local sample_info = state.source:GetCurrentSampleInfo()
	local spatial = audio._ComputeSpatialMixData(state.source)
	local debug_state = audio.GetDebugState()
	local listener_x, listener_y, listener_z = audio.GetListenerPosition()
	local source_pos = state.source:GetPosition()
	local sample_left, sample_right = state.source:GetCurrentSampleStereoVolume()
	local sample_value = state.source:GetCurrentSampleValue()
	local sample_volume = state.source:GetCurrentSampleVolume()
	local bee_speed = state.bee_body and
		state.bee_body.GetVelocity and
		state.bee_body:GetVelocity():GetLength() or
		0
	local mixer_peak = math.max(debug_state.output_peak_left or 0, debug_state.output_peak_right or 0)
	local win_w, _ = window.GetSize():Unpack()
	local panel_x = 16
	local panel_y = 16
	local panel_w = math.min(420, win_w - 32)
	local panel_h = 224
	local meter_w = panel_w - 24
	local meter_h = 12
	local meter_fill = math.min(math.abs(sample_volume) * 280, 1)
	local left_fill = math.min(math.abs(sample_left) * 280, 1)
	local right_fill = math.min(math.abs(sample_right) * 280, 1)
	local mixer_fill = math.min(math.abs(mixer_peak) * 280, 1)
	local hud = string.format(
		"audio_spatial_bee\nstate: %s  slot: %s  idx: %d  window: %d\nraw sample: %+0.4f  raw peak: %0.4f\nmixed peak: %0.4f  stereo: L %+0.4f  R %+0.4f\ndistance: %0.2f  attenuation: %0.3f  cone: %0.3f\ndoppler: %0.3f  total gain: %0.3f\nbackend: %s  thread: %s  stage: %d  callbacks: %d  output peak: %0.4f\nlistener: %0.2f %0.2f %0.2f\nsource:   %0.2f %0.2f %0.2f  speed: %0.2f",
		state.source:IsPlaying() and
			"playing" or
			(
				state.source:IsPaused() and
				"paused" or
				"stopped"
			),
		tostring(state.source.slot or "-"),
		sample_info.index or 0,
		sample_info.window or 0,
		sample_value,
		sample_info.raw_peak or 0,
		sample_volume,
		sample_left,
		sample_right,
		spatial.distance or 0,
		spatial.attenuation or 0,
		spatial.cone_gain or 0,
		spatial.doppler_pitch or 0,
		(sample_info.total_gain or 0),
		tostring(debug_state.backend_mode),
		tostring(debug_state.thread_status),
		debug_state.worker_stage or 0,
		debug_state.mix_callbacks or 0,
		mixer_peak,
		listener_x,
		listener_y,
		listener_z,
		source_pos.x,
		source_pos.y,
		source_pos.z,
		bee_speed
	)
	render2d.SetTexture(nil)
	render2d.SetColor(0.04, 0.05, 0.06, 0.82)
	render2d.DrawRect(panel_x, panel_y, panel_w, panel_h)
	render2d.SetColor(0.96, 0.77, 0.18, 0.95)
	render2d.DrawRect(panel_x, panel_y, panel_w, 3)
	render2d.SetColor(0.16, 0.17, 0.20, 0.95)
	render2d.DrawRect(panel_x + 12, panel_y + 156, meter_w, meter_h)
	render2d.DrawRect(panel_x + 12, panel_y + 176, meter_w, meter_h)
	render2d.DrawRect(panel_x + 12, panel_y + 196, meter_w, meter_h)
	render2d.DrawRect(panel_x + 12, panel_y + 216, meter_w, meter_h)
	render2d.SetColor(0.91, 0.72, 0.19, 1)
	render2d.DrawRect(panel_x + 12, panel_y + 156, meter_w * meter_fill, meter_h)
	render2d.SetColor(0.42, 0.80, 0.36, 1)
	render2d.DrawRect(panel_x + 12, panel_y + 176, meter_w * left_fill, meter_h)
	render2d.SetColor(0.28, 0.63, 0.94, 1)
	render2d.DrawRect(panel_x + 12, panel_y + 196, meter_w * right_fill, meter_h)
	render2d.SetColor(0.88, 0.43, 0.31, 1)
	render2d.DrawRect(panel_x + 12, panel_y + 216, meter_w * mixer_fill, meter_h)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText(hud, panel_x + 12, panel_y + 10)

	if debug_state.thread_error then
		font:DrawText(debug_state.thread_error, panel_x + 12, panel_y + panel_h + 8)
	end

	font:DrawText("src", panel_x + panel_w - 24, panel_y + 153)
	font:DrawText("L", panel_x + panel_w - 18, panel_y + 173)
	font:DrawText("R", panel_x + panel_w - 18, panel_y + 193)
	font:DrawText("mix", panel_x + panel_w - 26, panel_y + 213)
end)

logn("loaded scene: audio_spatial_bee")
