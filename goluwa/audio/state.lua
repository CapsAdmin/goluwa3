local ffi = require("ffi")
local audio = {}
audio.distance_model = "inverse"
audio.listener_position = {0, 0, 0}
audio.listener_velocity = {0, 0, 0}
audio.listener_orientation = {0, 0, -1, 0, 1, 0}
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
audio.mixer_state_cdef = [[
    typedef struct {
        void* buffer;
        uint32_t buffer_len;
        float playback_pos;
        float volume;
        float pitch;
        uint8_t channels;
        float position_x;
        float position_y;
        float position_z;
        float velocity_x;
        float velocity_y;
        float velocity_z;
        float direction_x;
        float direction_y;
        float direction_z;
        float inner_cone_angle;
        float outer_cone_angle;
        float outer_cone_gain;
        float reference_distance;
        float max_distance;
        float rolloff_factor;
        bool looping;
        bool active;
        bool paused;
    } SoundState;

    typedef struct {
        SoundState slots[32];
        float master_volume;
        float listener_position_x;
        float listener_position_y;
        float listener_position_z;
        float listener_velocity_x;
        float listener_velocity_y;
        float listener_velocity_z;
        float listener_forward_x;
        float listener_forward_y;
        float listener_forward_z;
        float listener_up_x;
        float listener_up_y;
        float listener_up_z;
        float doppler_factor;
        float speed_of_sound;
        uint8_t distance_model;
        uint32_t debug_worker_stage;
        uint64_t debug_mix_callbacks;
        float debug_output_peak_left;
        float debug_output_peak_right;
        bool shutdown;
    } MixerState;
]]
ffi.cdef(audio.mixer_state_cdef)
audio.mixer_state_t = ffi.typeof("MixerState")
audio.mixer_state_ptr_t = ffi.typeof("MixerState*")
audio.state = ffi.new(audio.mixer_state_t)
audio.state_ref = audio.state
audio.state.master_volume = 1.0
audio.active_sounds = {}
return audio
