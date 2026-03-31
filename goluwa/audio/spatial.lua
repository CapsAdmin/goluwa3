local Vec3 = import("goluwa/structs/vec3.lua")
local spatial = {}

function spatial.compute_distance_attenuation(
	distance_model_id,
	distance,
	reference_distance,
	max_distance,
	rolloff_factor,
	distance_mode_ids
)
	reference_distance = math.max(reference_distance or 1, 0.0001)
	max_distance = math.max(max_distance or reference_distance, reference_distance)
	rolloff_factor = math.max(rolloff_factor or 1, 0)

	if distance_model_id == distance_mode_ids.none then return 1 end

	local effective_distance = math.max(distance, reference_distance)
	local clamped = distance_model_id == distance_mode_ids.inverse_clamped or
		distance_model_id == distance_mode_ids.linear_clamped or
		distance_model_id == distance_mode_ids.exponent_clamped

	if clamped then
		effective_distance = math.clamp(effective_distance, reference_distance, max_distance)
	end

	if
		distance_model_id == distance_mode_ids.inverse or
		distance_model_id == distance_mode_ids.inverse_clamped
	then
		return reference_distance / (
				reference_distance + rolloff_factor * (
					effective_distance - reference_distance
				)
			)
	end

	if
		distance_model_id == distance_mode_ids.linear or
		distance_model_id == distance_mode_ids.linear_clamped
	then
		if max_distance <= reference_distance then return 1 end

		return math.clamp(
			1 - (
					rolloff_factor * (
						effective_distance - reference_distance
					) / (
						max_distance - reference_distance
					)
				),
			0,
			1
		)
	end

	if effective_distance <= reference_distance then return 1 end

	return math.pow(effective_distance / reference_distance, -rolloff_factor)
end

function spatial.compute_cone_attenuation(
	listener_position,
	source_position,
	source_direction,
	inner_cone_angle,
	outer_cone_angle,
	outer_cone_gain
)
	inner_cone_angle = math.clamp(tonumber(inner_cone_angle) or 360, 0, 360)
	outer_cone_angle = math.clamp(tonumber(outer_cone_angle) or 360, 0, 360)
	outer_cone_angle = math.max(outer_cone_angle, inner_cone_angle)
	outer_cone_gain = math.clamp(tonumber(outer_cone_gain) or 0, 0, 1)

	if inner_cone_angle >= 360 and outer_cone_angle >= 360 then return 1 end

	local direction = Vec3.FromValue(source_direction)

	if direction:IsZero() then return 1 end

	direction = direction:GetNormalized()
	local to_listener = Vec3.FromValue(listener_position) - Vec3.FromValue(source_position)

	if to_listener:IsZero() then return 1 end

	to_listener = to_listener:GetNormalized()
	local dot = math.clamp(direction:GetDot(to_listener), -1, 1)
	local angle = math.deg(math.acos(dot))
	local inner_half = inner_cone_angle * 0.5
	local outer_half = outer_cone_angle * 0.5

	if angle <= inner_half then return 1 end

	if angle >= outer_half then return outer_cone_gain end

	if outer_half <= inner_half then return outer_cone_gain end

	local fraction = (angle - inner_half) / (outer_half - inner_half)
	return 1 + ((outer_cone_gain - 1) * fraction)
end

function spatial.compute_doppler_pitch(
	listener_position,
	listener_velocity,
	source_position,
	source_velocity,
	speed_of_sound,
	doppler_factor
)
	speed_of_sound = math.max(tonumber(speed_of_sound) or 343.3, 0.0001)
	doppler_factor = math.max(tonumber(doppler_factor) or 1, 0)

	if doppler_factor == 0 then return 1 end

	local direction = Vec3.FromValue(listener_position) - Vec3.FromValue(source_position)

	if direction:IsZero() then return 1 end

	direction = direction:GetNormalized()
	local listener_velocity_vec = Vec3.FromValue(listener_velocity)
	local source_velocity_vec = Vec3.FromValue(source_velocity)
	local listener_radial = direction:GetDot(listener_velocity_vec)
	local source_radial = direction:GetDot(source_velocity_vec)
	local velocity_limit = speed_of_sound / doppler_factor
	listener_radial = math.clamp(listener_radial, -velocity_limit, velocity_limit)
	source_radial = math.clamp(source_radial, -velocity_limit, velocity_limit)
	local numerator = speed_of_sound - (doppler_factor * listener_radial)
	local denominator = speed_of_sound - (doppler_factor * source_radial)

	if math.abs(denominator) < 0.0001 then
		denominator = denominator < 0 and -0.0001 or 0.0001
	end

	return math.clamp(numerator / denominator, 0.25, 4)
end

function spatial.compute_spatial_mix_data(
	listener_position,
	listener_orientation,
	distance_model_id,
	source_position,
	reference_distance,
	max_distance,
	rolloff_factor,
	distance_mode_ids
)
	local listener_vec = Vec3.FromValue(listener_position)
	local source_vec = Vec3.FromValue(source_position)
	local rel = source_vec - listener_vec
	local distance = rel:GetLength()
	local attenuation = spatial.compute_distance_attenuation(
		distance_model_id,
		distance,
		reference_distance,
		max_distance,
		rolloff_factor,
		distance_mode_ids
	)
	local forward = Vec3(listener_orientation[1], listener_orientation[2], listener_orientation[3])
	local up = Vec3(listener_orientation[4], listener_orientation[5], listener_orientation[6])

	if not forward:IsZero() then forward = forward:GetNormalized() end

	if not up:IsZero() then up = up:GetNormalized() end

	local right = forward:GetCross(up)

	if not right:IsZero() then
		right = right:GetNormalized()
	else
		right = Vec3(1, 0, 0)
	end

	local pan = 0

	if distance > 0.0001 then
		pan = math.clamp(rel:GetNormalized():GetDot(right), -1, 1)
	end

	return {
		distance = distance,
		attenuation = attenuation,
		cone_gain = 1,
		doppler_pitch = 1,
		pan = pan,
		left_gain = math.sqrt(0.5 * (1 - pan)),
		right_gain = math.sqrt(0.5 * (1 + pan)),
	}
end

function spatial.Attach(audio)
	function audio.sync_listener_state()
		audio.state.listener_position_x = audio.listener_position[1]
		audio.state.listener_position_y = audio.listener_position[2]
		audio.state.listener_position_z = audio.listener_position[3]
		audio.state.listener_velocity_x = audio.listener_velocity[1]
		audio.state.listener_velocity_y = audio.listener_velocity[2]
		audio.state.listener_velocity_z = audio.listener_velocity[3]
		audio.state.listener_forward_x = audio.listener_orientation[1]
		audio.state.listener_forward_y = audio.listener_orientation[2]
		audio.state.listener_forward_z = audio.listener_orientation[3]
		audio.state.listener_up_x = audio.listener_orientation[4]
		audio.state.listener_up_y = audio.listener_orientation[5]
		audio.state.listener_up_z = audio.listener_orientation[6]
		audio.state.doppler_factor = audio.doppler_factor
		audio.state.speed_of_sound = audio.speed_of_sound
		audio.state.distance_model = audio.DISTANCE_MODE_IDS[audio.distance_model] or audio.DISTANCE_MODE_IDS.inverse
	end

	audio._spatial = spatial
	audio._ComputeSpatialMixData = function(sound)
		local data = spatial.compute_spatial_mix_data(
			audio.listener_position,
			audio.listener_orientation,
			audio.DISTANCE_MODE_IDS[audio.distance_model] or audio.DISTANCE_MODE_IDS.inverse,
			sound:GetPosition(),
			sound:GetReferenceDistance(),
			sound:GetMaxDistance(),
			sound:GetRolloffFactor(),
			audio.DISTANCE_MODE_IDS
		)
		data.cone_gain = spatial.compute_cone_attenuation(
			audio.listener_position,
			sound:GetPosition(),
			sound:GetDirection(),
			sound:GetInnerConeAngle(),
			sound:GetOuterConeAngle(),
			sound:GetOuterConeGain()
		)
		data.doppler_pitch = spatial.compute_doppler_pitch(
			audio.listener_position,
			audio.listener_velocity,
			sound:GetPosition(),
			sound:GetVelocity(),
			audio.speed_of_sound,
			audio.doppler_factor
		)
		data.total_gain = data.attenuation * data.cone_gain
		return data
	end
	audio.sync_listener_state()
	return audio
end

return spatial
