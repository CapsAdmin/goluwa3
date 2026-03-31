local ffi = require("ffi")
local spatial = import("goluwa/audio/spatial.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local mix = {}

function mix.MixOutputBuffer(state, out_buffer, num_samples)
	local peak_left = 0
	local peak_right = 0

	for i = 0, num_samples - 1 do
		out_buffer[i] = 0
	end

	local master_volume = state.master_volume

	for i = 0, 31 do
		local s = state.slots[i]

		if s.active and not s.paused then
			local samples = ffi.cast("float*", s.buffer)
			local pos = s.playback_pos
			local listener_position = Vec3(state.listener_position_x, state.listener_position_y, state.listener_position_z)
			local listener_velocity = Vec3(state.listener_velocity_x, state.listener_velocity_y, state.listener_velocity_z)
			local listener_orientation = {
				state.listener_forward_x,
				state.listener_forward_y,
				state.listener_forward_z,
				state.listener_up_x,
				state.listener_up_y,
				state.listener_up_z,
			}
			local source_position = Vec3(s.position_x, s.position_y, s.position_z)
			local source_velocity = Vec3(s.velocity_x, s.velocity_y, s.velocity_z)
			local source_direction = Vec3(s.direction_x, s.direction_y, s.direction_z)
			local distance_model_ids = {
				none = 0,
				inverse = 1,
				inverse_clamped = 2,
				linear = 3,
				linear_clamped = 4,
				exponent = 5,
				exponent_clamped = 6,
			}
			local spatial_mix = spatial.compute_spatial_mix_data(
				listener_position,
				listener_orientation,
				state.distance_model,
				source_position,
				s.reference_distance,
				s.max_distance,
				s.rolloff_factor,
				distance_model_ids
			)
			local attenuation = spatial_mix.attenuation
			local cone_gain = spatial.compute_cone_attenuation(
				listener_position,
				source_position,
				source_direction,
				s.inner_cone_angle,
				s.outer_cone_angle,
				s.outer_cone_gain
			)
			local doppler_pitch = spatial.compute_doppler_pitch(
				listener_position,
				listener_velocity,
				source_position,
				source_velocity,
				state.speed_of_sound,
				state.doppler_factor
			)
			local left_gain = spatial_mix.left_gain
			local right_gain = spatial_mix.right_gain
			local pitch = s.pitch * doppler_pitch
			local vol = s.volume * master_volume * attenuation * cone_gain
			local len = s.buffer_len

			for j = 0, num_samples - 1, 2 do
				local idx = math.floor(pos)

				if idx >= len then
					if s.looping then
						pos = 0
						idx = 0
					else
						s.active = false

						break
					end
				end

				if s.channels == 2 then
					out_buffer[j] = out_buffer[j] + (samples[idx * 2] * vol * left_gain)
					out_buffer[j + 1] = out_buffer[j + 1] + (samples[idx * 2 + 1] * vol * right_gain)
				else
					local sample = samples[idx] * vol
					out_buffer[j] = out_buffer[j] + (sample * left_gain)
					out_buffer[j + 1] = out_buffer[j + 1] + (sample * right_gain)
				end

				pos = pos + pitch
			end

			s.playback_pos = pos
		end
	end

	for i = 0, num_samples - 1, 2 do
		local left = math.abs(out_buffer[i])
		local right = math.abs(out_buffer[i + 1])

		if left > peak_left then peak_left = left end

		if right > peak_right then peak_right = right end
	end

	state.debug_mix_callbacks = state.debug_mix_callbacks + 1
	state.debug_output_peak_left = peak_left
	state.debug_output_peak_right = peak_right
end

return mix
