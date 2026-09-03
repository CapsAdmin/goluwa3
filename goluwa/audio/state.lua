local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local audio = {}
audio.distance_model = "inverse"
audio.listener_position = Vec3(0, 0, 0)
audio.listener_velocity = Vec3(0, 0, 0)
audio.listener_forward = Vec3(0, 0, -1)
audio.listener_up = Vec3(0, 1, 0)
audio.doppler_factor = 1
audio.speed_of_sound = 343.3
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
-- position/velocity/direction are embedded Vec3 cdata (via $ substitution) rather than
-- flat x/y/z floats, so mix.lua can read/pass them without allocating a new Vec3 per callback.
local sound_state_t = ffi.typeof(
	[[
	struct {
		void* buffer;
		uint32_t buffer_len;
		float playback_pos;
		float volume;
		float pitch;
		uint8_t channels;
		$ position;
		$ velocity;
		$ direction;
		float inner_cone_angle;
		float outer_cone_angle;
		float outer_cone_gain;
		float reference_distance;
		float max_distance;
		float rolloff_factor;
		bool looping;
		bool active;
		bool paused;
	}
]],
	Vec3,
	Vec3,
	Vec3
)
audio.mixer_state_t = ffi.typeof(
	[[
	struct {
		$ slots[32];
		float master_volume;
		$ listener_position;
		$ listener_velocity;
		$ listener_forward;
		$ listener_up;
		float doppler_factor;
		float speed_of_sound;
		uint8_t distance_model;
		uint32_t debug_worker_stage;
		uint64_t debug_mix_callbacks;
		float debug_output_peak_left;
		float debug_output_peak_right;
		bool shutdown;
	}
]],
	sound_state_t,
	Vec3,
	Vec3,
	Vec3,
	Vec3
)
audio.mixer_state_ptr_t = ffi.typeof("$*", audio.mixer_state_t)
audio.state = ffi.new(audio.mixer_state_t)
audio.state_ref = audio.state
audio.state.master_volume = 1.0
audio.active_sounds = {}
return audio
