local ffi = require("ffi")
local threads = import("goluwa/bindings/threads.lua")
local event = import("goluwa/event.lua")
local mix = import("goluwa/audio/mix.lua")
local module = {}

function module.Attach(audio)
	local function stop_main_backend()
		if audio.main_audio_buffer then
			audio.main_audio_buffer.stop()
			audio.main_audio_buffer = nil
			audio.main_config = nil
		end

		event.RemoveListener("Update", "audio_main_thread_driver")

		if audio.backend_mode == "main" then
			audio.backend_mode = "none"
			audio.state.debug_worker_stage = 0
		end
	end

	local function start_main_backend()
		if audio.main_audio_buffer then return true end

		local audio_buffer = import("goluwa/bindings/audio_buffer.lua")
		audio.state.debug_worker_stage = 101
		audio_buffer.callback = function(out_buffer, num_samples)
			mix.MixOutputBuffer(audio.state, out_buffer, num_samples)
		end
		local config = audio_buffer.start{
			sample_rate = 44100,
			buffer_size = 512,
			channels = 2,
		}
		audio.state.debug_worker_stage = 102
		audio.main_audio_buffer = audio_buffer
		audio.main_config = config
		audio.backend_mode = "main"

		event.AddListener("Update", "audio_main_thread_driver", function()
			if audio.backend_mode ~= "main" or not audio.main_audio_buffer then return end

			audio.state.debug_worker_stage = 103
			audio.main_audio_buffer.update()
			audio.state.debug_worker_stage = 104
		end)

		return true
	end

	local function mixer_worker(shared_state_ptr)
		local ffi = require("ffi")
		local mix_mod = import("goluwa/audio/mix.lua")
		local state = ffi.cast("MixerState*", shared_state_ptr)
		state.debug_worker_stage = 1
		local audio_buffer = import("goluwa/bindings/audio_buffer.lua")
		state.debug_worker_stage = 2
		ffi.cdef(audio.mixer_state_cdef)
		state.debug_worker_stage = 3
		audio_buffer.start{
			sample_rate = 44100,
			buffer_size = 512,
			channels = 2,
		}
		state.debug_worker_stage = 4

		function audio_buffer.callback(out_buffer, num_samples)
			mix_mod.MixOutputBuffer(state, out_buffer, num_samples)
		end

		while not state.shutdown do
			state.debug_worker_stage = 5
			audio_buffer.update()
		end

		state.debug_worker_stage = 6
		audio_buffer.stop()
		state.debug_worker_stage = 7
	end

	function audio.GetDebugState()
		local thread_status = audio.thread and
			audio.thread.input_data and
			audio.thread.input_data.status or
			nil
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

		local ok, thread_or_err = pcall(threads.new, mixer_worker)

		if ok and thread_or_err then
			audio.thread = thread_or_err
			audio.thread:run(audio.state, true)
			audio.backend_mode = "thread"
		else
			start_main_backend()
			return
		end

		import("goluwa/timer.lua").Delay(0.1, function()
			if
				audio.thread and
				audio.thread.input_data and
				audio.thread.input_data.status == threads.STATUS_ERROR
			then
				local ok2, err = audio.thread:join()

				if not ok2 and err then
					logn("Audio mixer thread initialization error: ", err)
				end

				audio.thread = nil
				start_main_backend()
			end
		end)
	end

	function audio.Shutdown()
		audio.initialized = false
		stop_main_backend()

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

		if audio.backend_mode == "thread" and audio.thread == nil then
			start_main_backend()
		elseif audio.backend_mode == "none" and next(audio.active_sounds) ~= nil then
			start_main_backend()
		end
	end)

	event.AddListener("ShutDown", "audio_shutdown", function()
		audio.Shutdown()
	end)

	return audio
end

return module
