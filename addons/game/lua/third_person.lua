local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local pvars = import("goluwa/cli/pvars.lua")
local physics = import("goluwa/physics.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local raycast = RENDER_3D and import("goluwa/render3d/raycast.lua")
local U = import("goluwa/source_engine/units.lua").meters
local UP = orientation.UP_VECTOR
local FORWARD = orientation.FORWARD_VECTOR
local AIM_DISTANCE = 1000
local MAX_DT = 0.05
local SMOOTH_OFF = 35
local DRAG_SPEED = 0.005
local ZOOM_SPEED = 0.02
local MAX_DRAG_PITCH = 1.5
local THRESHOLD_SCALE = 1 / (500 * U)
local BLOCK_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = true}
local AIM_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
local third_person = {}
local settings = {}
local definitions = {}
local order = {}

local function define(group, key, default, info)
	info = info or {}
	info.key = key == "enabled" and "cl_thirdperson" or "tp_" .. key
	info.default = default
	info.category = "Game"
	info.group = "Third person " .. group
	info.friendly = info.friendly or key:gsub("_", " ")
	info.callback = function(value)
		settings[key] = value
	end
	settings[key] = default
	definitions[key] = info
	order[#order + 1] = key
	pvars.Setup2(info)
end

third_person.Groups = {
	"camera",
	"position",
	"aim",
	"smoothing",
	"collision",
	"targeting",
	"movement",
	"hud",
}
define("camera", "enabled", false, {help = "over the shoulder camera, client side only"})
define(
	"position",
	"pivot",
	"none",
	{
		enums = {"none", "eyepos", "bottom"},
		help = "what the camera orbits: chest, eyes or feet",
	}
)
define("position", "offset_right", 0, {min = -20, max = 20})
define("position", "offset_forward", -144 * U, {min = -30, max = 30})
define("position", "offset_up", 52 * U, {min = -20, max = 20})
define("position", "offset_relative", true, {help = "off: the offset is in world space"})
define(
	"position",
	"follow_pitch",
	true,
	{help = "off: the offset ignores the aim pitch"}
)
define("position", "center_right", 0, {min = -3, max = 3})
define("position", "center_forward", 0, {min = -3, max = 3})
define("position", "center_up", 0, {min = -3, max = 3})
define("position", "near_z", 0.05, {min = 0.01, max = 1})
define(
	"position",
	"relative_near_z",
	false,
	{
		help = "pull the near plane in when something is between the camera and the player",
	}
)
define(
	"position",
	"threshold_enabled",
	false,
	{help = "the camera only follows once the player leaves the radius"}
)
define("position", "threshold_radius", 0, {min = 0, max = 40})
define(
	"aim",
	"aim_lerp",
	100,
	{
		min = 0,
		max = 100,
		help = "0 looks at the player, 50 at what the player sees, 100 along the player's aim",
	}
)
define("aim", "fov", 0, {min = 0, max = 150, help = "degrees, 0 uses the player's fov"})
define(
	"aim",
	"roll_amount",
	0,
	{min = -100, max = 100, help = "roll from sideways velocity"}
)
define(
	"aim",
	"zoom_distance_enabled",
	false,
	{help = "zoom in the further the player is from the camera"}
)
define("aim", "zoom_distance", 1200 * U, {min = 0, max = 100})
define("aim", "zoom_distance_min", 7, {min = 0, max = 75})
define("aim", "angle_pitch", 0, {min = -180, max = 180})
define("aim", "angle_yaw", 0, {min = -180, max = 180})
define("aim", "angle_roll", 0, {min = -180, max = 180})
define(
	"aim",
	"angle_limit",
	false,
	{help = "keep the camera from aiming away from the player"}
)
define(
	"aim",
	"angle_limit_smooth",
	false,
	{help = "limit after smoothing instead of before"}
)
define(
	"smoothing",
	"smooth_origin",
	40,
	{min = 0, max = 40, help = "low is slow, 35 and up is off"}
)
define("smoothing", "smooth_direction", 40, {min = 0, max = 40})
define("smoothing", "smooth_fov", 40, {min = 0, max = 40})
define("collision", "trace_enabled", true)
define(
	"collision",
	"trace_raycast",
	true,
	{
		help = "block the camera with render3d geometry raycasts, off uses a physics sweep",
	}
)
define(
	"collision",
	"trace_margin",
	20 * U,
	{
		min = -2,
		max = 2,
		help = "how far the camera sits in front of the blocking surface",
	}
)
define(
	"collision",
	"trace_down",
	0,
	{min = 0, max = 50, help = "keep the camera this far above the ground"}
)
define(
	"targeting",
	"target_enabled",
	false,
	{help = "aim towards nearby dynamic bodies"}
)
define("targeting", "target_radius", 0, {min = 0, max = 60})
define("targeting", "target_lerp", 0.3, {min = 0, max = 100})
define("targeting", "target_fov", 40, {min = 0, max = 150})
define(
	"movement",
	"rtc_enabled",
	false,
	{
		help = "walk relative to the camera and turn the player towards the walk direction",
	}
)
define("movement", "rtc_yaw_offset", 0, {min = -180, max = 180})
define(
	"movement",
	"rtc_turn_speed",
	0,
	{min = 0, max = 2000, help = "degrees per second"}
)
define("movement", "lock_pitch", false)
define("movement", "walk_focus", false, {help = "look at the player while walking"})
define("hud", "crosshair", true)
define("hud", "crosshair_distance", 600, {min = 1, max = 2000})
define("hud", "hide_hud", false, {help = "hide the weapon hud"})
define("hud", "black_bars", false)
define("hud", "black_bar_amount", 0, {min = 0, max = 5})
third_person.Settings = settings
third_person.Definitions = definitions
third_person.Order = order

local function preset(name, description, values)
	return {Name = name, Description = description, Values = values}
end

third_person.Presets = {
	preset("Valve thirdperson", "mimics valve's thirdperson camera", {}),
	preset(
		"Cinematic",
		"a cinematic camera",
		{
			offset_forward = 0,
			offset_up = 0,
			smooth_origin = 1,
			smooth_direction = 5,
			smooth_fov = 3,
			threshold_enabled = true,
			threshold_radius = 400 * U,
			target_enabled = false,
			target_radius = 400 * U,
			target_lerp = 100,
			trace_down = 30 * U,
			fov = 50,
			angle_limit = true,
			angle_limit_smooth = true,
			near_z = 0.1,
			hide_hud = true,
		}
	),
	preset(
		"Cinematic 2",
		"a cinematic camera that targets nearby bodies",
		{
			offset_forward = 0,
			offset_up = 0,
			pivot = "eyepos",
			smooth_origin = 1,
			smooth_direction = 10,
			smooth_fov = 1,
			threshold_enabled = true,
			threshold_radius = 1000 * U,
			aim_lerp = 5,
			roll_amount = 15,
			zoom_distance_enabled = true,
			zoom_distance = 1000 * U,
			zoom_distance_min = 10,
			fov = 75,
			target_enabled = true,
			target_radius = 400 * U,
			target_lerp = 15,
			trace_down = 100 * U,
			angle_limit = true,
			near_z = 0.1,
			crosshair = false,
			black_bars = true,
			black_bar_amount = 1.8,
			hide_hud = true,
		}
	),
	preset(
		"Slow",
		"a very slow camera",
		{
			offset_forward = 0,
			offset_up = 0,
			pivot = "eyepos",
			smooth_origin = 0.2,
			smooth_direction = 5,
			smooth_fov = 3,
			threshold_enabled = true,
			threshold_radius = 500 * U,
			aim_lerp = 0,
			zoom_distance_enabled = true,
			zoom_distance = 1500 * U,
			zoom_distance_min = 4,
			fov = 75,
			target_enabled = true,
			target_radius = 700 * U,
			target_lerp = 25,
			trace_down = 70 * U,
			angle_limit = true,
			angle_limit_smooth = true,
			near_z = 0.1,
			black_bar_amount = 1.5,
			hide_hud = true,
		}
	),
	preset(
		"Helicopter view",
		"only works well in huge open areas",
		{
			offset_forward = 0,
			offset_up = 0,
			pivot = "eyepos",
			smooth_origin = 1,
			smooth_direction = 1,
			smooth_fov = 2,
			threshold_enabled = true,
			threshold_radius = 10000 * U,
			aim_lerp = 2,
			zoom_distance_enabled = true,
			zoom_distance = 1000 * U,
			zoom_distance_min = 10,
			fov = 75,
			trace_enabled = false,
			trace_down = 2000 * U,
			angle_limit = true,
			near_z = 0.1,
			crosshair = false,
			hide_hud = true,
		}
	),
	preset(
		"Isometric",
		"isometric view",
		{
			offset_right = 9,
			offset_up = 9,
			offset_forward = 9,
			offset_relative = false,
			follow_pitch = false,
			aim_lerp = 0,
			fov = 30,
			smooth_origin = 40,
			smooth_direction = 10,
			trace_enabled = false,
			rtc_enabled = true,
			rtc_turn_speed = 900,
			lock_pitch = true,
			crosshair_distance = 100 * U,
			hide_hud = true,
		}
	),
	preset(
		"Platformer",
		"side view",
		{
			offset_right = 9,
			offset_up = 0,
			offset_forward = 0,
			center_forward = 100 * U,
			center_up = 40 * U,
			offset_relative = false,
			follow_pitch = false,
			aim_lerp = 0,
			fov = 40,
			smooth_origin = 10,
			smooth_direction = 2,
			trace_enabled = false,
			rtc_enabled = true,
			rtc_turn_speed = 900,
			lock_pitch = true,
			crosshair_distance = 100 * U,
			hide_hud = true,
		}
	),
}

function third_person.ApplyPreset(preset)
	for _, key in ipairs(order) do
		if key ~= "enabled" then
			local value = preset.Values[key]

			if value == nil then value = definitions[key].default end

			pvars.Set(definitions[key].key, value)
		end
	end
end

function third_person.IsEnabled()
	return settings.enabled
end

function third_person.IsDefaultHudReplaced(rig)
	return false
end

function third_person.IsHudHidden()
	return settings.enabled and settings.hide_hud
end

local state = {
	origin = Vec3(),
	prev_origin = Vec3(),
	rotation = Quat():Identity(),
	prev_rotation = Quat():Identity(),
	fov = math.rad(90),
	roll = 0,
	near_z = 0.05,
	initialized = false,
	aim_point = Vec3(),
	aim_blocked = false,
	prev_enabled = false,
	walking = false,
	drag_button = nil,
	drag_yaw = 0,
	drag_pitch = 0,
	drag_distance = 1,
}
local pivot = Vec3()
local feet = Vec3()
local target_origin = Vec3()
local aim_point = Vec3()

local function is_static_geometry(entity)
	local body = entity.rigid_body
	return body ~= nil and body:IsStatic()
end

local function is_not_owner(entity, owner)
	return entity ~= owner and not entity:ContainsParent(owner)
end

local function wrap_angle(angle)
	return (angle + math.pi) % (math.pi * 2) - math.pi
end

local function angles_of(direction)
	return math.atan2(-direction.x, -direction.z),
	math.asin(math.clamp(direction.y, -1, 1))
end

local function direction_of(yaw, pitch)
	local flat = math.cos(pitch)
	return Vec3(-math.sin(yaw) * flat, math.sin(pitch), -math.cos(yaw) * flat)
end

local function blocked_distance(from, direction, distance, owner)
	if settings.trace_raycast then
		local hit = raycast.CastClosestSolid(from, direction, distance, is_not_owner, owner)
		return hit and hit.distance
	end

	local hit = physics.Sweep(from, direction * distance, 0.1, owner, is_static_geometry, BLOCK_OPTIONS)
	return hit and hit.distance
end

event.AddListener("MouseInput", "third_person_drag", function(key, press)
	if not settings.enabled then return end

	if press then
		if
			(
				key == "button_1" or
				key == "button_2"
			)
			and
			not system.GetWindow():GetMouseTrapped()
		then
			state.drag_button = key
			state.drag_started = false
		end
	elseif key == state.drag_button then
		state.drag_button = nil
	end
end)

function third_person.Reset(position, rotation, fov)
	state.origin:CopyFrom(position)
	state.prev_origin:CopyFrom(position)
	state.rotation = rotation:Copy()
	state.prev_rotation = rotation:Copy()
	state.fov = fov
	state.roll = 0
	state.initialized = true
end

function third_person.Update(owner, eye, view_offset, aim, aim_fov, velocity, dt)
	dt = math.min(dt, MAX_DT)
	local s = settings

	if not state.initialized or not state.prev_enabled then
		third_person.Reset(eye, aim, aim_fov)
	end

	state.prev_enabled = true
	local aim_forward = aim:VecMul(FORWARD)
	local aim_right = aim:VecMul(orientation.RIGHT_VECTOR)
	local aim_up = aim:VecMul(UP)
	feet:Set(eye.x - view_offset.x, eye.y - view_offset.y, eye.z - view_offset.z)

	if s.pivot == "eyepos" then
		pivot:CopyFrom(eye)
	elseif s.pivot == "bottom" then
		pivot:CopyFrom(feet)
	else
		pivot:Set(feet.x, feet.y + 36 * U, feet.z)
	end

	pivot:Set(
		pivot.x + aim_right.x * s.center_right + aim_forward.x * s.center_forward + aim_up.x * s.center_up,
		pivot.y + aim_right.y * s.center_right + aim_forward.y * s.center_forward + aim_up.y * s.center_up,
		pivot.z + aim_right.z * s.center_right + aim_forward.z * s.center_forward + aim_up.z * s.center_up
	)
	local drag_button = state.drag_button

	if drag_button and not input.IsMouseDown(drag_button) then
		drag_button = nil
		state.drag_button = nil
	end

	if drag_button then
		if not state.drag_started then
			local from_camera = pivot - state.origin
			state.drag_distance = math.max(from_camera:GetLength(), 0.3)
			state.drag_yaw, state.drag_pitch = angles_of(from_camera:GetNormalized())
			state.drag_started = true
		end

		local delta = system.GetWindow():GetMouseDelta()

		if drag_button == "button_1" then
			state.drag_yaw = state.drag_yaw + delta.x * DRAG_SPEED
			state.drag_pitch = math.clamp(state.drag_pitch + delta.y * DRAG_SPEED, -MAX_DRAG_PITCH, MAX_DRAG_PITCH)
		else
			state.drag_distance = math.max(state.drag_distance + delta.y * ZOOM_SPEED, 0.3)
		end

		local direction = direction_of(state.drag_yaw, state.drag_pitch)
		state.origin:Set(
			pivot.x - direction.x * state.drag_distance,
			pivot.y - direction.y * state.drag_distance,
			pivot.z - direction.z * state.drag_distance
		)
		state.prev_origin:CopyFrom(state.origin)
		state.rotation = Quat():SetLookDirection(direction)
		state.prev_rotation = state.rotation
		state.roll = 0
		state.fov = aim_fov
		return state.origin, state.rotation, state.fov, state.near_z
	end

	local prev_origin = state.prev_origin
	local fov = s.fov > 0 and math.rad(s.fov) or aim_fov

	if s.zoom_distance_enabled then
		local distance = (pivot - prev_origin):GetLength()
		local zoom = s.zoom_distance
		fov = math.rad(math.clamp((zoom - distance) / (zoom / 100), s.zoom_distance_min, 75))
	end

	local origin_speed = 1

	if s.threshold_enabled then
		local ratio = (pivot - prev_origin):GetLength() / (s.threshold_radius * 0.5)
		origin_speed = math.clamp(ratio ^ 7 - 0.2, 0, 1)
		target_origin:CopyFrom(pivot)
	else
		local offset

		if s.offset_relative then
			local right, forward, up = aim_right, aim_forward, aim_up

			if not s.follow_pitch then
				forward = Vec3(aim_forward.x, 0, aim_forward.z)
				local length = forward:GetLength()

				if length < 1e-4 then
					forward = Vec3(aim_up.x, 0, aim_up.z):GetNormalized()
				else
					forward = forward / length
				end

				right = Vec3(-forward.z, 0, forward.x)
				up = UP
			end

			offset = right * s.offset_right + forward * s.offset_forward + up * s.offset_up
		else
			offset = Vec3(s.offset_right, s.offset_up, s.offset_forward)
		end

		target_origin:Set(pivot.x + offset.x, pivot.y + offset.y, pivot.z + offset.z)
	end

	local aim_hit = physics.RayCast(eye, aim_forward, AIM_DISTANCE, owner, nil, AIM_OPTIONS)
	aim_point:CopyFrom(eye + aim_forward * (aim_hit and aim_hit.distance or s.crosshair_distance))
	local lerp = s.aim_lerp / 100 * 2
	local to_player = pivot - prev_origin
	local to_player_length = to_player:GetLength()
	to_player = to_player_length > 1e-4 and to_player / to_player_length or aim_forward
	local to_hit = aim_point - target_origin
	local to_hit_length = to_hit:GetLength()
	to_hit = to_hit_length > 1e-4 and to_hit / to_hit_length or aim_forward
	local direction

	if lerp < 1 then
		direction = to_player + (to_hit - to_player) * lerp
	else
		direction = to_hit + (aim_forward - to_hit) * (lerp - 1)
	end

	if s.rtc_enabled and s.walk_focus and state.walking then
		direction = to_player
	end

	local target_fov = fov

	if s.target_enabled then
		local sum = Vec3()
		local count = 0
		local radius = s.target_radius

		for _, body in ipairs(RigidBody.Instances) do
			local entity = body.Owner

			if
				entity ~= owner and
				not body.WorldGeometry and
				not body:IsStatic()
				and
				not entity:ContainsParent(owner)
			then
				local position = body:GetPosition()

				if (position - pivot):GetLength() < radius then
					sum = sum + position
					count = count + 1
				end
			end
		end

		if count > 0 then
			local point = sum / count
			local to_point = point - target_origin
			local length = to_point:GetLength()

			if length > 1e-4 then
				to_point = to_point / length
				local dot = math.max(aim_forward:Dot(to_point), 0)
				local off_center = math.clamp(math.acos(math.min(dot, 1)) / (fov * 0.5 + 1e-4), 0, 1)
				local multiplier = math.clamp(off_center * dot + 0.5, 0.5, 1)
				direction = direction + (to_point - direction) * (multiplier * s.target_lerp / 100)
				target_fov = math.rad(s.target_fov) * multiplier
			end
		end
	end

	local direction_length = direction:GetLength()
	direction = direction_length > 1e-4 and direction / direction_length or aim_forward
	local block_distance
	local trace_origin = target_origin

	if s.trace_enabled and not s.threshold_enabled or s.relative_near_z then
		local to_origin = trace_origin - pivot
		local length = to_origin:GetLength()

		if length > 1e-4 then
			block_distance = blocked_distance(pivot, to_origin / length, length, owner)

			if block_distance and s.trace_enabled and not s.threshold_enabled then
				trace_origin = pivot + to_origin / length * math.max(block_distance - s.trace_margin, 0)
				target_origin:CopyFrom(trace_origin)
			end
		end
	end

	if s.trace_down > 0 then
		local floor = blocked_distance(target_origin, -UP, s.trace_down, owner)

		if floor then target_origin.y = target_origin.y + (s.trace_down - floor) end
	end

	local near_z = s.near_z

	if s.relative_near_z and block_distance then
		near_z = math.max((target_origin - pivot):GetLength() - s.near_z, s.near_z)
		near_z = math.min(near_z, math.max(block_distance, s.near_z))
	end

	if s.angle_limit and not s.angle_limit_smooth then
		direction = third_person.LimitDirection(direction, to_player, fov)
	end

	local target_rotation = Quat():SetLookDirection(direction)
	local origin_k = math.min(dt * s.smooth_origin, 1)
	local direction_k = math.min(dt * s.smooth_direction, 1)
	local fov_k = math.min(dt * s.smooth_fov, 1)

	if s.threshold_enabled then
		origin_k = math.min(
			dt * (
					s.smooth_origin / (
						s.threshold_radius * THRESHOLD_SCALE + 1e-4
					)
				) * origin_speed,
			1
		)
	end

	local origin = state.origin

	if s.smooth_origin < SMOOTH_OFF or s.threshold_enabled then
		origin:Set(
			origin.x + (target_origin.x - origin.x) * origin_k,
			origin.y + (target_origin.y - origin.y) * origin_k,
			origin.z + (target_origin.z - origin.z) * origin_k
		)
	else
		origin:CopyFrom(target_origin)
	end

	if s.smooth_direction < SMOOTH_OFF then
		state.rotation = state.rotation:Interpolate(target_rotation, direction_k)
	else
		state.rotation = target_rotation
	end

	if s.smooth_fov < SMOOTH_OFF then
		state.fov = state.fov + (target_fov - state.fov) * fov_k
	else
		state.fov = target_fov
	end

	local roll = 0

	if s.roll_amount ~= 0 then
		local sideways = velocity:Dot(state.rotation:VecMul(orientation.RIGHT_VECTOR)) / U
		roll = math.rad(math.clamp(-sideways * s.roll_amount / 500, -90, 90))
	end

	if s.smooth_direction < SMOOTH_OFF then
		state.roll = state.roll + (roll - state.roll) * direction_k
	else
		state.roll = roll
	end

	if s.trace_enabled and s.threshold_enabled then
		local to_origin = origin - pivot
		local length = to_origin:GetLength()

		if length > 1e-4 then
			local distance = blocked_distance(pivot, to_origin / length, length, owner)

			if distance then
				origin:CopyFrom(pivot + to_origin / length * math.max(distance - s.trace_margin, 0))
			end
		end
	end

	local rotation = state.rotation

	if s.angle_limit and s.angle_limit_smooth then
		local limited = third_person.LimitDirection(rotation:VecMul(FORWARD), to_player, state.fov)
		rotation = Quat():SetLookDirection(limited)
	end

	rotation = rotation:Copy()
	rotation:RotateYaw(math.rad(s.angle_yaw))
	rotation:RotatePitch(math.rad(s.angle_pitch))
	rotation:RotateRoll(math.rad(s.angle_roll) + state.roll)
	state.prev_origin:CopyFrom(origin)
	state.prev_rotation = rotation
	state.near_z = near_z
	state.aim_point:CopyFrom(aim_point)
	local to_aim = aim_point - origin
	local to_aim_length = to_aim:GetLength()
	state.aim_blocked = to_aim_length > 1e-4 and
		blocked_distance(origin, to_aim / to_aim_length, to_aim_length * 0.96, owner) ~= nil
	return origin, rotation, state.fov, near_z
end

function third_person.LimitDirection(direction, to_player, fov)
	local limit = fov / 3
	local camera_yaw, camera_pitch = angles_of(direction)
	local player_yaw, player_pitch = angles_of(to_player)
	local yaw_limit = limit / (9 / 16)
	local pitch = player_pitch + math.clamp(wrap_angle(camera_pitch - player_pitch), -limit, limit)
	local yaw = player_yaw + math.clamp(wrap_angle(camera_yaw - player_yaw), -yaw_limit, yaw_limit)
	local limited = direction_of(yaw, pitch)
	local away = Vec3(-to_player.x, 0, -to_player.z)
	local away_length = away:GetLength()
	local weight = 0

	if away_length > 1e-4 then
		local flat = Vec3(direction.x, 0, direction.z)
		local flat_length = flat:GetLength()

		if flat_length > 1e-4 then
			weight = math.clamp(flat:Dot(away) / (flat_length * away_length), 0, 1)
		end
	end

	local result = limited + (to_player - limited) * weight
	local length = result:GetLength()
	return length > 1e-4 and result / length or limited
end

function third_person.Disable(rig)
	state.prev_enabled = false
end

function third_person.GetNearZ()
	return state.near_z
end

function third_person.GetCrosshairPoint()
	return state.aim_point, state.aim_blocked
end

function third_person.GetBlackBarHeight()
	if not (settings.enabled and settings.black_bars) then return 0 end

	return math.max(75 - math.deg(state.fov), 0) * settings.black_bar_amount
end

function third_person.ApplyRelativeMovement(player_input, dt)
	local s = settings
	state.walking = false

	if not (s.enabled and s.rtc_enabled) then return end

	local move = player_input.move_local
	local forward_input = move.z
	local side_input = move.x

	if forward_input == 0 and side_input == 0 then return end

	state.walking = true
	local camera_forward = state.prev_rotation:VecMul(FORWARD)
	local flat_length = math.sqrt(camera_forward.x * camera_forward.x + camera_forward.z * camera_forward.z)

	if flat_length < 1e-3 then return end

	local fx, fz = camera_forward.x / flat_length, camera_forward.z / flat_length
	local dx = fx * forward_input + -fz * side_input
	local dz = fz * forward_input + fx * side_input
	local target_yaw = math.atan2(-dx, -dz) + math.rad(s.rtc_yaw_offset)
	local rotation = player_input:GetRotation()
	local forward = rotation:VecMul(FORWARD)
	local yaw, pitch = angles_of(forward)
	local difference = wrap_angle(target_yaw - yaw)
	local step = math.rad(s.rtc_turn_speed) * dt

	if step > 0 and math.abs(difference) > step then
		yaw = yaw + (difference > 0 and step or -step)
	else
		yaw = target_yaw
	end

	local result = Quat():Identity()
	result:RotateYaw(yaw)

	if not s.lock_pitch then result:RotatePitch(pitch) end

	player_input:SetRotation(result)
end

function third_person.AdjustCommand(cmd)
	local s = settings

	if not (s.enabled and s.rtc_enabled) or not state.walking then return end

	cmd.forward = math.min(math.sqrt(cmd.forward * cmd.forward + cmd.side * cmd.side), 1)
	cmd.side = 0
end

return third_person
