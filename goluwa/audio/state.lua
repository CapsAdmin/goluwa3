local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local audio = {}
audio.SLOT_COUNT = 32
audio.MAX_TAPS = 8
audio.BAND_COUNT = 3
audio.BUS_COUNT = 2
audio.CUE_GROUPS = 6
audio.CUE_GROUP_HEIGHT = 0.7
audio.distance_model = "inverse"
audio.listener_position = Vec3(0, 0, 0)
audio.listener_forward = Vec3(0, 0, -1)
audio.listener_up = Vec3(0, 1, 0)
audio.doppler_factor = 1
audio.speed_of_sound = 343.3
audio.ear_distance = 0.18
audio.reference_loudness = -18
audio.backend_mode = "none"
audio.initialized = false
audio.DISTANCE_MODE_IDS = {
	none = 0,
	inverse = 1,
	inverse_clamped = 2,
	linear = 3,
	linear_clamped = 4,
	exponent = 5,
	exponent_clamped = 6,
}
local slot_t = ffi.typeof(
	[[
	struct {
		void* buffer;
		uint32_t buffer_len;
		double playback_pos;
		float volume;
		float pitch;
		float sample_rate;
		uint8_t channels;
		bool looping;
		bool active;
		bool paused;
		bool spatial;
		bool draining;
		uint32_t start_serial;
		uint32_t param_serial;
		double param_time;
		float ear_delay[2];
		float ear_rate[2];
		float ear_gain[6];
		float ear_filter_frequency[6];
		float ear_filter_gain[6];
		float ear_filter_q[3];
		float tap_delay[$];
		float tap_rate[$];
		float tap_gain[$];
		float tap_height[$];
		float tap_front[$];
		float tap_band[3];
		float send[$];
	}
]],
	audio.MAX_TAPS * 2,
	audio.MAX_TAPS * 2,
	audio.MAX_TAPS * 2,
	audio.MAX_TAPS,
	audio.MAX_TAPS,
	audio.BUS_COUNT
)
local bus_t = ffi.typeof([[
	struct {
		float t60[3];
		float predelay;
		float scale;
		float diffusion;
	}
]])
audio.mixer_state_t = ffi.typeof(
	[[
	struct {
		$ slots[$];
		$ buses[$];
		float cue_frequency[$];
		float cue_gain[$];
		float cue_q[3];
		float master_volume;
		uint32_t sample_rate;
		double clock_offset;
		uint64_t mixed_frames;
		uint32_t debug_worker_stage;
		uint64_t debug_mix_callbacks;
		float debug_output_peak_left;
		float debug_output_peak_right;
		float debug_mix_seconds;
		bool shutdown;
	}
]],
	slot_t,
	audio.SLOT_COUNT,
	bus_t,
	audio.BUS_COUNT,
	audio.CUE_GROUPS * 3,
	audio.CUE_GROUPS * 3
)
audio.mixer_state_ptr_t = ffi.typeof("$*", audio.mixer_state_t)

function audio.CreateMixerState()
	local state = audio.mixer_state_t()
	state.master_volume = 1
	state.sample_rate = 44100

	for i = 0, audio.CUE_GROUPS * 3 - 1 do
		state.cue_frequency[i] = 1000
	end

	for i = 0, 2 do
		state.cue_q[i] = 1
	end

	for i = 0, audio.BUS_COUNT - 1 do
		state.buses[i].t60[0] = 0.5
		state.buses[i].t60[1] = 0.5
		state.buses[i].t60[2] = 0.5
		state.buses[i].predelay = 0.01
		state.buses[i].scale = 1
		state.buses[i].diffusion = 1
	end

	return state
end

audio.state = audio.CreateMixerState()
audio.active_sounds = {}
return audio
