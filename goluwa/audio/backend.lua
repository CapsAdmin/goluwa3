local ffi = require("ffi")
local threads = import("goluwa/bindings/threads.lua")
local event = import("goluwa/event.lua")
local mix = import("goluwa/audio/mix.lua")
local system = import("goluwa/system.lua")
local module = {}

function module.Attach(audio)
	local mixer_worker_source = [[
		local ffi = require("ffi")
		local input = ...
		local mix_mod = import("goluwa/audio/mix.lua")
		local audio = import("goluwa/audio/state.lua")
		local state = ffi.cast(audio.mixer_state_ptr_t, input)
		state.debug_worker_stage = 1
		local audio_buffer = import("goluwa/bindings/audio_buffer.lua")
		state.debug_worker_stage = 2
		audio_buffer.start{
			sample_rate = 44100,
			buffer_size = 512,
			channels = 2,
		}
		state.debug_worker_stage = 3

		function audio_buffer.callback(out_buffer, num_samples)
			mix_mod.MixOutputBuffer(state, out_buffer, num_samples)
		end

		while not state.shutdown do
			state.debug_worker_stage = 4
			audio_buffer.update()
		end

		state.debug_worker_stage = 5
		audio_buffer.stop()
		state.debug_worker_stage = 6
	]]

	function audio.GetDebugState()
		local thread_status = audio.thread and threads.get_status(audio.thread) or nil
		local thread_error

		if
			thread_status == threads.STATUS_ERROR and
			audio.thread and
			audio.thread.input_data
		then
			local ok, res = pcall(
				threads.pointer_decode,
				audio.thread.input_data.output_buffer,
				audio.thread.input_data.output_buffer_len
			)

			if ok and type(res) == "table" then thread_error = res[2] end
		end

		return {
			thread_started = audio.thread ~= nil,
			thread_status = thread_status,
			thread_error = thread_error,
			backend_mode = audio.backend_mode,
			worker_stage = tonumber(audio.state.debug_worker_stage) or 0,
			mix_callbacks = tonumber(audio.state.debug_mix_callbacks) or 0,
			output_peak_left = tonumber(audio.state.debug_output_peak_left) or 0,
			output_peak_right = tonumber(audio.state.debug_output_peak_right) or 0,
		}
	end

	function audio.Initialize()
		audio.initialized = true
		audio.state.shutdown = false

		if audio.thread or audio.main_audio_buffer then return end

		-- Create audio mixer thread with proper string source
		local ok, thread_or_err = pcall(threads.new, mixer_worker_source)

		if not ok or not thread_or_err then
			error("Failed to create audio mixer thread: " .. tostring(thread_or_err))
		end

		audio.thread = thread_or_err
		audio.thread:run(audio.state, true)
		audio.backend_mode = "thread"

		-- Verify thread started successfully
		import("goluwa/timer.lua").Delay(0.1, function()
			if audio.thread and threads.get_status(audio.thread) == threads.STATUS_ERROR then
				local ok2, err = audio.thread:join()

				if not ok2 and err then
					error("Audio mixer thread failed: " .. tostring(err))
				end

				audio.thread = nil
				error("Audio mixer thread exited with error")
			end
		end)
	end

	function audio.Shutdown()
		audio.initialized = false

		if audio.thread then
			audio.state.shutdown = true
			local ok, err = audio.thread:join()

			if not ok and err then
				error("Audio mixer thread error: " .. tostring(err))
			end

			audio.thread = nil
		end

		audio.backend_mode = "none"
	end

	event.AddListener("Update", "audio_backend_watchdog", function()
		if not audio.initialized then return end

		-- Thread should never be nil once started, but handle gracefully
		if audio.backend_mode == "none" and next(audio.active_sounds) ~= nil then
			error("Audio thread exited unexpectedly while sounds are active")
		end
	end)

	event.AddListener("ShutDown", "audio_shutdown", function()
		audio.Shutdown()
	end)

	return audio
end

return module
