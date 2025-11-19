-- Generated from wayland protocol
local ffi = require('ffi')

-- Global table to keep listener callbacks alive (prevent GC)
local listeners_registry = {}

ffi.cdef[[
// Protocol: wayland
struct wl_display {};
extern const struct wl_interface wl_display_interface;
struct wl_registry {};
extern const struct wl_interface wl_registry_interface;
struct wl_callback {};
extern const struct wl_interface wl_callback_interface;
struct wl_compositor {};
extern const struct wl_interface wl_compositor_interface;
struct wl_shm_pool {};
extern const struct wl_interface wl_shm_pool_interface;
struct wl_shm {};
extern const struct wl_interface wl_shm_interface;
struct wl_buffer {};
extern const struct wl_interface wl_buffer_interface;
struct wl_data_offer {};
extern const struct wl_interface wl_data_offer_interface;
struct wl_data_source {};
extern const struct wl_interface wl_data_source_interface;
struct wl_data_device {};
extern const struct wl_interface wl_data_device_interface;
struct wl_data_device_manager {};
extern const struct wl_interface wl_data_device_manager_interface;
struct wl_shell {};
extern const struct wl_interface wl_shell_interface;
struct wl_shell_surface {};
extern const struct wl_interface wl_shell_surface_interface;
struct wl_surface {};
extern const struct wl_interface wl_surface_interface;
struct wl_seat {};
extern const struct wl_interface wl_seat_interface;
struct wl_pointer {};
extern const struct wl_interface wl_pointer_interface;
struct wl_keyboard {};
extern const struct wl_interface wl_keyboard_interface;
struct wl_touch {};
extern const struct wl_interface wl_touch_interface;
struct wl_output {};
extern const struct wl_interface wl_output_interface;
struct wl_region {};
extern const struct wl_interface wl_region_interface;
struct wl_subcompositor {};
extern const struct wl_interface wl_subcompositor_interface;
struct wl_subsurface {};
extern const struct wl_interface wl_subsurface_interface;
struct wl_fixes {};
extern const struct wl_interface wl_fixes_interface;
enum wl_display_error {
	WL_DISPLAY_ERROR_INVALID_OBJECT = 0,
	WL_DISPLAY_ERROR_INVALID_METHOD = 1,
	WL_DISPLAY_ERROR_NO_MEMORY = 2,
	WL_DISPLAY_ERROR_IMPLEMENTATION = 3,
};
enum wl_shm_error {
	WL_SHM_ERROR_INVALID_FORMAT = 0,
	WL_SHM_ERROR_INVALID_STRIDE = 1,
	WL_SHM_ERROR_INVALID_FD = 2,
};
enum wl_shm_format {
	WL_SHM_FORMAT_ARGB8888 = 0,
	WL_SHM_FORMAT_XRGB8888 = 1,
	WL_SHM_FORMAT_C8 = 0x20203843,
	WL_SHM_FORMAT_RGB332 = 0x38424752,
	WL_SHM_FORMAT_BGR233 = 0x38524742,
	WL_SHM_FORMAT_XRGB4444 = 0x32315258,
	WL_SHM_FORMAT_XBGR4444 = 0x32314258,
	WL_SHM_FORMAT_RGBX4444 = 0x32315852,
	WL_SHM_FORMAT_BGRX4444 = 0x32315842,
	WL_SHM_FORMAT_ARGB4444 = 0x32315241,
	WL_SHM_FORMAT_ABGR4444 = 0x32314241,
	WL_SHM_FORMAT_RGBA4444 = 0x32314152,
	WL_SHM_FORMAT_BGRA4444 = 0x32314142,
	WL_SHM_FORMAT_XRGB1555 = 0x35315258,
	WL_SHM_FORMAT_XBGR1555 = 0x35314258,
	WL_SHM_FORMAT_RGBX5551 = 0x35315852,
	WL_SHM_FORMAT_BGRX5551 = 0x35315842,
	WL_SHM_FORMAT_ARGB1555 = 0x35315241,
	WL_SHM_FORMAT_ABGR1555 = 0x35314241,
	WL_SHM_FORMAT_RGBA5551 = 0x35314152,
	WL_SHM_FORMAT_BGRA5551 = 0x35314142,
	WL_SHM_FORMAT_RGB565 = 0x36314752,
	WL_SHM_FORMAT_BGR565 = 0x36314742,
	WL_SHM_FORMAT_RGB888 = 0x34324752,
	WL_SHM_FORMAT_BGR888 = 0x34324742,
	WL_SHM_FORMAT_XBGR8888 = 0x34324258,
	WL_SHM_FORMAT_RGBX8888 = 0x34325852,
	WL_SHM_FORMAT_BGRX8888 = 0x34325842,
	WL_SHM_FORMAT_ABGR8888 = 0x34324241,
	WL_SHM_FORMAT_RGBA8888 = 0x34324152,
	WL_SHM_FORMAT_BGRA8888 = 0x34324142,
	WL_SHM_FORMAT_XRGB2101010 = 0x30335258,
	WL_SHM_FORMAT_XBGR2101010 = 0x30334258,
	WL_SHM_FORMAT_RGBX1010102 = 0x30335852,
	WL_SHM_FORMAT_BGRX1010102 = 0x30335842,
	WL_SHM_FORMAT_ARGB2101010 = 0x30335241,
	WL_SHM_FORMAT_ABGR2101010 = 0x30334241,
	WL_SHM_FORMAT_RGBA1010102 = 0x30334152,
	WL_SHM_FORMAT_BGRA1010102 = 0x30334142,
	WL_SHM_FORMAT_YUYV = 0x56595559,
	WL_SHM_FORMAT_YVYU = 0x55595659,
	WL_SHM_FORMAT_UYVY = 0x59565955,
	WL_SHM_FORMAT_VYUY = 0x59555956,
	WL_SHM_FORMAT_AYUV = 0x56555941,
	WL_SHM_FORMAT_NV12 = 0x3231564e,
	WL_SHM_FORMAT_NV21 = 0x3132564e,
	WL_SHM_FORMAT_NV16 = 0x3631564e,
	WL_SHM_FORMAT_NV61 = 0x3136564e,
	WL_SHM_FORMAT_YUV410 = 0x39565559,
	WL_SHM_FORMAT_YVU410 = 0x39555659,
	WL_SHM_FORMAT_YUV411 = 0x31315559,
	WL_SHM_FORMAT_YVU411 = 0x31315659,
	WL_SHM_FORMAT_YUV420 = 0x32315559,
	WL_SHM_FORMAT_YVU420 = 0x32315659,
	WL_SHM_FORMAT_YUV422 = 0x36315559,
	WL_SHM_FORMAT_YVU422 = 0x36315659,
	WL_SHM_FORMAT_YUV444 = 0x34325559,
	WL_SHM_FORMAT_YVU444 = 0x34325659,
	WL_SHM_FORMAT_R8 = 0x20203852,
	WL_SHM_FORMAT_R16 = 0x20363152,
	WL_SHM_FORMAT_RG88 = 0x38384752,
	WL_SHM_FORMAT_GR88 = 0x38385247,
	WL_SHM_FORMAT_RG1616 = 0x32334752,
	WL_SHM_FORMAT_GR1616 = 0x32335247,
	WL_SHM_FORMAT_XRGB16161616F = 0x48345258,
	WL_SHM_FORMAT_XBGR16161616F = 0x48344258,
	WL_SHM_FORMAT_ARGB16161616F = 0x48345241,
	WL_SHM_FORMAT_ABGR16161616F = 0x48344241,
	WL_SHM_FORMAT_XYUV8888 = 0x56555958,
	WL_SHM_FORMAT_VUY888 = 0x34325556,
	WL_SHM_FORMAT_VUY101010 = 0x30335556,
	WL_SHM_FORMAT_Y210 = 0x30313259,
	WL_SHM_FORMAT_Y212 = 0x32313259,
	WL_SHM_FORMAT_Y216 = 0x36313259,
	WL_SHM_FORMAT_Y410 = 0x30313459,
	WL_SHM_FORMAT_Y412 = 0x32313459,
	WL_SHM_FORMAT_Y416 = 0x36313459,
	WL_SHM_FORMAT_XVYU2101010 = 0x30335658,
	WL_SHM_FORMAT_XVYU12_16161616 = 0x36335658,
	WL_SHM_FORMAT_XVYU16161616 = 0x38345658,
	WL_SHM_FORMAT_Y0L0 = 0x304c3059,
	WL_SHM_FORMAT_X0L0 = 0x304c3058,
	WL_SHM_FORMAT_Y0L2 = 0x324c3059,
	WL_SHM_FORMAT_X0L2 = 0x324c3058,
	WL_SHM_FORMAT_YUV420_8BIT = 0x38305559,
	WL_SHM_FORMAT_YUV420_10BIT = 0x30315559,
	WL_SHM_FORMAT_XRGB8888_A8 = 0x38415258,
	WL_SHM_FORMAT_XBGR8888_A8 = 0x38414258,
	WL_SHM_FORMAT_RGBX8888_A8 = 0x38415852,
	WL_SHM_FORMAT_BGRX8888_A8 = 0x38415842,
	WL_SHM_FORMAT_RGB888_A8 = 0x38413852,
	WL_SHM_FORMAT_BGR888_A8 = 0x38413842,
	WL_SHM_FORMAT_RGB565_A8 = 0x38413552,
	WL_SHM_FORMAT_BGR565_A8 = 0x38413542,
	WL_SHM_FORMAT_NV24 = 0x3432564e,
	WL_SHM_FORMAT_NV42 = 0x3234564e,
	WL_SHM_FORMAT_P210 = 0x30313250,
	WL_SHM_FORMAT_P010 = 0x30313050,
	WL_SHM_FORMAT_P012 = 0x32313050,
	WL_SHM_FORMAT_P016 = 0x36313050,
	WL_SHM_FORMAT_AXBXGXRX106106106106 = 0x30314241,
	WL_SHM_FORMAT_NV15 = 0x3531564e,
	WL_SHM_FORMAT_Q410 = 0x30313451,
	WL_SHM_FORMAT_Q401 = 0x31303451,
	WL_SHM_FORMAT_XRGB16161616 = 0x38345258,
	WL_SHM_FORMAT_XBGR16161616 = 0x38344258,
	WL_SHM_FORMAT_ARGB16161616 = 0x38345241,
	WL_SHM_FORMAT_ABGR16161616 = 0x38344241,
	WL_SHM_FORMAT_C1 = 0x20203143,
	WL_SHM_FORMAT_C2 = 0x20203243,
	WL_SHM_FORMAT_C4 = 0x20203443,
	WL_SHM_FORMAT_D1 = 0x20203144,
	WL_SHM_FORMAT_D2 = 0x20203244,
	WL_SHM_FORMAT_D4 = 0x20203444,
	WL_SHM_FORMAT_D8 = 0x20203844,
	WL_SHM_FORMAT_R1 = 0x20203152,
	WL_SHM_FORMAT_R2 = 0x20203252,
	WL_SHM_FORMAT_R4 = 0x20203452,
	WL_SHM_FORMAT_R10 = 0x20303152,
	WL_SHM_FORMAT_R12 = 0x20323152,
	WL_SHM_FORMAT_AVUY8888 = 0x59555641,
	WL_SHM_FORMAT_XVUY8888 = 0x59555658,
	WL_SHM_FORMAT_P030 = 0x30333050,
};
enum wl_data_offer_error {
	WL_DATA_OFFER_ERROR_INVALID_FINISH = 0,
	WL_DATA_OFFER_ERROR_INVALID_ACTION_MASK = 1,
	WL_DATA_OFFER_ERROR_INVALID_ACTION = 2,
	WL_DATA_OFFER_ERROR_INVALID_OFFER = 3,
};
enum wl_data_source_error {
	WL_DATA_SOURCE_ERROR_INVALID_ACTION_MASK = 0,
	WL_DATA_SOURCE_ERROR_INVALID_SOURCE = 1,
};
enum wl_data_device_error {
	WL_DATA_DEVICE_ERROR_ROLE = 0,
	WL_DATA_DEVICE_ERROR_USED_SOURCE = 1,
};
enum wl_data_device_manager_dnd_action {
	WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE = 0,
	WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY = 1,
	WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE = 2,
	WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK = 4,
};
enum wl_shell_error {
	WL_SHELL_ERROR_ROLE = 0,
};
enum wl_shell_surface_resize {
	WL_SHELL_SURFACE_RESIZE_NONE = 0,
	WL_SHELL_SURFACE_RESIZE_TOP = 1,
	WL_SHELL_SURFACE_RESIZE_BOTTOM = 2,
	WL_SHELL_SURFACE_RESIZE_LEFT = 4,
	WL_SHELL_SURFACE_RESIZE_TOP_LEFT = 5,
	WL_SHELL_SURFACE_RESIZE_BOTTOM_LEFT = 6,
	WL_SHELL_SURFACE_RESIZE_RIGHT = 8,
	WL_SHELL_SURFACE_RESIZE_TOP_RIGHT = 9,
	WL_SHELL_SURFACE_RESIZE_BOTTOM_RIGHT = 10,
};
enum wl_shell_surface_transient {
	WL_SHELL_SURFACE_TRANSIENT_INACTIVE = 0x1,
};
enum wl_shell_surface_fullscreen_method {
	WL_SHELL_SURFACE_FULLSCREEN_METHOD_DEFAULT = 0,
	WL_SHELL_SURFACE_FULLSCREEN_METHOD_SCALE = 1,
	WL_SHELL_SURFACE_FULLSCREEN_METHOD_DRIVER = 2,
	WL_SHELL_SURFACE_FULLSCREEN_METHOD_FILL = 3,
};
enum wl_surface_error {
	WL_SURFACE_ERROR_INVALID_SCALE = 0,
	WL_SURFACE_ERROR_INVALID_TRANSFORM = 1,
	WL_SURFACE_ERROR_INVALID_SIZE = 2,
	WL_SURFACE_ERROR_INVALID_OFFSET = 3,
	WL_SURFACE_ERROR_DEFUNCT_ROLE_OBJECT = 4,
};
enum wl_seat_capability {
	WL_SEAT_CAPABILITY_POINTER = 1,
	WL_SEAT_CAPABILITY_KEYBOARD = 2,
	WL_SEAT_CAPABILITY_TOUCH = 4,
};
enum wl_seat_error {
	WL_SEAT_ERROR_MISSING_CAPABILITY = 0,
};
enum wl_pointer_error {
	WL_POINTER_ERROR_ROLE = 0,
};
enum wl_pointer_button_state {
	WL_POINTER_BUTTON_STATE_RELEASED = 0,
	WL_POINTER_BUTTON_STATE_PRESSED = 1,
};
enum wl_pointer_axis {
	WL_POINTER_AXIS_VERTICAL_SCROLL = 0,
	WL_POINTER_AXIS_HORIZONTAL_SCROLL = 1,
};
enum wl_pointer_axis_source {
	WL_POINTER_AXIS_SOURCE_WHEEL = 0,
	WL_POINTER_AXIS_SOURCE_FINGER = 1,
	WL_POINTER_AXIS_SOURCE_CONTINUOUS = 2,
	WL_POINTER_AXIS_SOURCE_WHEEL_TILT = 3,
};
enum wl_pointer_axis_relative_direction {
	WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL = 0,
	WL_POINTER_AXIS_RELATIVE_DIRECTION_INVERTED = 1,
};
enum wl_keyboard_keymap_format {
	WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP = 0,
	WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 = 1,
};
enum wl_keyboard_key_state {
	WL_KEYBOARD_KEY_STATE_RELEASED = 0,
	WL_KEYBOARD_KEY_STATE_PRESSED = 1,
	WL_KEYBOARD_KEY_STATE_REPEATED = 2,
};
enum wl_output_subpixel {
	WL_OUTPUT_SUBPIXEL_UNKNOWN = 0,
	WL_OUTPUT_SUBPIXEL_NONE = 1,
	WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB = 2,
	WL_OUTPUT_SUBPIXEL_HORIZONTAL_BGR = 3,
	WL_OUTPUT_SUBPIXEL_VERTICAL_RGB = 4,
	WL_OUTPUT_SUBPIXEL_VERTICAL_BGR = 5,
};
enum wl_output_transform {
	WL_OUTPUT_TRANSFORM_NORMAL = 0,
	WL_OUTPUT_TRANSFORM_90 = 1,
	WL_OUTPUT_TRANSFORM_180 = 2,
	WL_OUTPUT_TRANSFORM_270 = 3,
	WL_OUTPUT_TRANSFORM_FLIPPED = 4,
	WL_OUTPUT_TRANSFORM_FLIPPED_90 = 5,
	WL_OUTPUT_TRANSFORM_FLIPPED_180 = 6,
	WL_OUTPUT_TRANSFORM_FLIPPED_270 = 7,
};
enum wl_output_mode {
	WL_OUTPUT_MODE_CURRENT = 0x1,
	WL_OUTPUT_MODE_PREFERRED = 0x2,
};
enum wl_subcompositor_error {
	WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE = 0,
	WL_SUBCOMPOSITOR_ERROR_BAD_PARENT = 1,
};
enum wl_subsurface_error {
	WL_SUBSURFACE_ERROR_BAD_SURFACE = 0,
};
]]

local output_table = {}

-- Interface: wl_display
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_object",
						summary = "server couldn't find object",
						value = "0",
					},
					[2] = {
						name = "invalid_method",
						summary = "method doesn't exist on the specified interface or malformed request",
						value = "1",
					},
					[3] = {
						name = "no_memory",
						summary = "server is out of memory",
						value = "2",
					},
					[4] = {
						name = "implementation",
						summary = "implementation error in compositor",
						value = "3",
					},
				},
				name = "error",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "object_id",
						type = "object",
					},
					[2] = {
						name = "code",
						type = "uint",
					},
					[3] = {
						name = "message",
						type = "string",
					},
				},
				name = "error",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "id",
						type = "uint",
					},
				},
				name = "delete_id",
				since = 1,
			},
		},
		name = "wl_display",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_callback",
						name = "callback",
						type = "new_id",
					},
				},
				name = "sync",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_registry",
						name = "registry",
						type = "new_id",
					},
				},
				name = "get_registry",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: sync
	function meta:sync(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: get_registry
	function meta:get_registry(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_display*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_display'] = meta
	ffi.metatype('struct wl_display', meta)
end

-- Interface: wl_registry
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "name",
						type = "uint",
					},
					[2] = {
						name = "interface",
						type = "string",
					},
					[3] = {
						name = "version",
						type = "uint",
					},
				},
				name = "global",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "name",
						type = "uint",
					},
				},
				name = "global_remove",
				since = 1,
			},
		},
		name = "wl_registry",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						name = "name",
						type = "uint",
					},
					[2] = {
						allow_null = false,
						name = "id",
						type = "new_id",
					},
				},
				name = "bind",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: bind
	function meta:bind(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_registry*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_registry'] = meta
	ffi.metatype('struct wl_registry', meta)
end

-- Interface: wl_callback
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "callback_data",
						type = "uint",
					},
				},
				name = "done",
				since = 1,
			},
		},
		name = "wl_callback",
		requests = {
		},
		version = 1,
	}

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_callback*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_callback'] = meta
	ffi.metatype('struct wl_callback', meta)
end

-- Interface: wl_compositor
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
		},
		name = "wl_compositor",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_surface",
						name = "id",
						type = "new_id",
					},
				},
				name = "create_surface",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_region",
						name = "id",
						type = "new_id",
					},
				},
				name = "create_region",
				since = 1,
			},
		},
		version = 6,
	}

	-- Request: create_surface
	function meta:create_surface(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: create_region
	function meta:create_region(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_compositor*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_compositor'] = meta
	ffi.metatype('struct wl_compositor', meta)
end

-- Interface: wl_shm_pool
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
		},
		name = "wl_shm_pool",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_buffer",
						name = "id",
						type = "new_id",
					},
					[2] = {
						allow_null = false,
						name = "offset",
						type = "int",
					},
					[3] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
					[5] = {
						allow_null = false,
						name = "stride",
						type = "int",
					},
					[6] = {
						allow_null = false,
						name = "format",
						type = "uint",
					},
				},
				name = "create_buffer",
				since = 1,
			},
			[2] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						name = "size",
						type = "int",
					},
				},
				name = "resize",
				since = 1,
			},
		},
		version = 2,
	}

	-- Request: create_buffer
	function meta:create_buffer(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[6]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: resize
	function meta:resize(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_shm_pool*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_shm_pool'] = meta
	ffi.metatype('struct wl_shm_pool', meta)
end

-- Interface: wl_shm
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_format",
						summary = "buffer format is not known",
						value = "0",
					},
					[2] = {
						name = "invalid_stride",
						summary = "invalid size or stride during pool or buffer creation",
						value = "1",
					},
					[3] = {
						name = "invalid_fd",
						summary = "mmapping the file descriptor failed",
						value = "2",
					},
				},
				name = "error",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "argb8888",
						summary = "32-bit ARGB format, [31:0] A:R:G:B 8:8:8:8 little endian",
						value = "0",
					},
					[10] = {
						name = "argb4444",
						summary = "16-bit ARGB format, [15:0] A:R:G:B 4:4:4:4 little endian",
						value = "0x32315241",
					},
					[100] = {
						name = "p016",
						summary = "2x2 subsampled Cr:Cb plane 16 bits per channel",
						value = "0x36313050",
					},
					[101] = {
						name = "axbxgxrx106106106106",
						summary = "[63:0] A:x:B:x:G:x:R:x 10:6:10:6:10:6:10:6 little endian",
						value = "0x30314241",
					},
					[102] = {
						name = "nv15",
						summary = "2x2 subsampled Cr:Cb plane",
						value = "0x3531564e",
					},
					[103] = {
						name = "q410",
						value = "0x30313451",
					},
					[104] = {
						name = "q401",
						value = "0x31303451",
					},
					[105] = {
						name = "xrgb16161616",
						summary = "[63:0] x:R:G:B 16:16:16:16 little endian",
						value = "0x38345258",
					},
					[106] = {
						name = "xbgr16161616",
						summary = "[63:0] x:B:G:R 16:16:16:16 little endian",
						value = "0x38344258",
					},
					[107] = {
						name = "argb16161616",
						summary = "[63:0] A:R:G:B 16:16:16:16 little endian",
						value = "0x38345241",
					},
					[108] = {
						name = "abgr16161616",
						summary = "[63:0] A:B:G:R 16:16:16:16 little endian",
						value = "0x38344241",
					},
					[109] = {
						name = "c1",
						summary = "[7:0] C0:C1:C2:C3:C4:C5:C6:C7 1:1:1:1:1:1:1:1 eight pixels/byte",
						value = "0x20203143",
					},
					[11] = {
						name = "abgr4444",
						summary = "16-bit ABGR format, [15:0] A:B:G:R 4:4:4:4 little endian",
						value = "0x32314241",
					},
					[110] = {
						name = "c2",
						summary = "[7:0] C0:C1:C2:C3 2:2:2:2 four pixels/byte",
						value = "0x20203243",
					},
					[111] = {
						name = "c4",
						summary = "[7:0] C0:C1 4:4 two pixels/byte",
						value = "0x20203443",
					},
					[112] = {
						name = "d1",
						summary = "[7:0] D0:D1:D2:D3:D4:D5:D6:D7 1:1:1:1:1:1:1:1 eight pixels/byte",
						value = "0x20203144",
					},
					[113] = {
						name = "d2",
						summary = "[7:0] D0:D1:D2:D3 2:2:2:2 four pixels/byte",
						value = "0x20203244",
					},
					[114] = {
						name = "d4",
						summary = "[7:0] D0:D1 4:4 two pixels/byte",
						value = "0x20203444",
					},
					[115] = {
						name = "d8",
						summary = "[7:0] D",
						value = "0x20203844",
					},
					[116] = {
						name = "r1",
						summary = "[7:0] R0:R1:R2:R3:R4:R5:R6:R7 1:1:1:1:1:1:1:1 eight pixels/byte",
						value = "0x20203152",
					},
					[117] = {
						name = "r2",
						summary = "[7:0] R0:R1:R2:R3 2:2:2:2 four pixels/byte",
						value = "0x20203252",
					},
					[118] = {
						name = "r4",
						summary = "[7:0] R0:R1 4:4 two pixels/byte",
						value = "0x20203452",
					},
					[119] = {
						name = "r10",
						summary = "[15:0] x:R 6:10 little endian",
						value = "0x20303152",
					},
					[12] = {
						name = "rgba4444",
						summary = "16-bit RBGA format, [15:0] R:G:B:A 4:4:4:4 little endian",
						value = "0x32314152",
					},
					[120] = {
						name = "r12",
						summary = "[15:0] x:R 4:12 little endian",
						value = "0x20323152",
					},
					[121] = {
						name = "avuy8888",
						summary = "[31:0] A:Cr:Cb:Y 8:8:8:8 little endian",
						value = "0x59555641",
					},
					[122] = {
						name = "xvuy8888",
						summary = "[31:0] X:Cr:Cb:Y 8:8:8:8 little endian",
						value = "0x59555658",
					},
					[123] = {
						name = "p030",
						summary = "2x2 subsampled Cr:Cb plane 10 bits per channel packed",
						value = "0x30333050",
					},
					[13] = {
						name = "bgra4444",
						summary = "16-bit BGRA format, [15:0] B:G:R:A 4:4:4:4 little endian",
						value = "0x32314142",
					},
					[14] = {
						name = "xrgb1555",
						summary = "16-bit xRGB format, [15:0] x:R:G:B 1:5:5:5 little endian",
						value = "0x35315258",
					},
					[15] = {
						name = "xbgr1555",
						summary = "16-bit xBGR 1555 format, [15:0] x:B:G:R 1:5:5:5 little endian",
						value = "0x35314258",
					},
					[16] = {
						name = "rgbx5551",
						summary = "16-bit RGBx 5551 format, [15:0] R:G:B:x 5:5:5:1 little endian",
						value = "0x35315852",
					},
					[17] = {
						name = "bgrx5551",
						summary = "16-bit BGRx 5551 format, [15:0] B:G:R:x 5:5:5:1 little endian",
						value = "0x35315842",
					},
					[18] = {
						name = "argb1555",
						summary = "16-bit ARGB 1555 format, [15:0] A:R:G:B 1:5:5:5 little endian",
						value = "0x35315241",
					},
					[19] = {
						name = "abgr1555",
						summary = "16-bit ABGR 1555 format, [15:0] A:B:G:R 1:5:5:5 little endian",
						value = "0x35314241",
					},
					[2] = {
						name = "xrgb8888",
						summary = "32-bit RGB format, [31:0] x:R:G:B 8:8:8:8 little endian",
						value = "1",
					},
					[20] = {
						name = "rgba5551",
						summary = "16-bit RGBA 5551 format, [15:0] R:G:B:A 5:5:5:1 little endian",
						value = "0x35314152",
					},
					[21] = {
						name = "bgra5551",
						summary = "16-bit BGRA 5551 format, [15:0] B:G:R:A 5:5:5:1 little endian",
						value = "0x35314142",
					},
					[22] = {
						name = "rgb565",
						summary = "16-bit RGB 565 format, [15:0] R:G:B 5:6:5 little endian",
						value = "0x36314752",
					},
					[23] = {
						name = "bgr565",
						summary = "16-bit BGR 565 format, [15:0] B:G:R 5:6:5 little endian",
						value = "0x36314742",
					},
					[24] = {
						name = "rgb888",
						summary = "24-bit RGB format, [23:0] R:G:B little endian",
						value = "0x34324752",
					},
					[25] = {
						name = "bgr888",
						summary = "24-bit BGR format, [23:0] B:G:R little endian",
						value = "0x34324742",
					},
					[26] = {
						name = "xbgr8888",
						summary = "32-bit xBGR format, [31:0] x:B:G:R 8:8:8:8 little endian",
						value = "0x34324258",
					},
					[27] = {
						name = "rgbx8888",
						summary = "32-bit RGBx format, [31:0] R:G:B:x 8:8:8:8 little endian",
						value = "0x34325852",
					},
					[28] = {
						name = "bgrx8888",
						summary = "32-bit BGRx format, [31:0] B:G:R:x 8:8:8:8 little endian",
						value = "0x34325842",
					},
					[29] = {
						name = "abgr8888",
						summary = "32-bit ABGR format, [31:0] A:B:G:R 8:8:8:8 little endian",
						value = "0x34324241",
					},
					[3] = {
						name = "c8",
						summary = "8-bit color index format, [7:0] C",
						value = "0x20203843",
					},
					[30] = {
						name = "rgba8888",
						summary = "32-bit RGBA format, [31:0] R:G:B:A 8:8:8:8 little endian",
						value = "0x34324152",
					},
					[31] = {
						name = "bgra8888",
						summary = "32-bit BGRA format, [31:0] B:G:R:A 8:8:8:8 little endian",
						value = "0x34324142",
					},
					[32] = {
						name = "xrgb2101010",
						summary = "32-bit xRGB format, [31:0] x:R:G:B 2:10:10:10 little endian",
						value = "0x30335258",
					},
					[33] = {
						name = "xbgr2101010",
						summary = "32-bit xBGR format, [31:0] x:B:G:R 2:10:10:10 little endian",
						value = "0x30334258",
					},
					[34] = {
						name = "rgbx1010102",
						summary = "32-bit RGBx format, [31:0] R:G:B:x 10:10:10:2 little endian",
						value = "0x30335852",
					},
					[35] = {
						name = "bgrx1010102",
						summary = "32-bit BGRx format, [31:0] B:G:R:x 10:10:10:2 little endian",
						value = "0x30335842",
					},
					[36] = {
						name = "argb2101010",
						summary = "32-bit ARGB format, [31:0] A:R:G:B 2:10:10:10 little endian",
						value = "0x30335241",
					},
					[37] = {
						name = "abgr2101010",
						summary = "32-bit ABGR format, [31:0] A:B:G:R 2:10:10:10 little endian",
						value = "0x30334241",
					},
					[38] = {
						name = "rgba1010102",
						summary = "32-bit RGBA format, [31:0] R:G:B:A 10:10:10:2 little endian",
						value = "0x30334152",
					},
					[39] = {
						name = "bgra1010102",
						summary = "32-bit BGRA format, [31:0] B:G:R:A 10:10:10:2 little endian",
						value = "0x30334142",
					},
					[4] = {
						name = "rgb332",
						summary = "8-bit RGB format, [7:0] R:G:B 3:3:2",
						value = "0x38424752",
					},
					[40] = {
						name = "yuyv",
						summary = "packed YCbCr format, [31:0] Cr0:Y1:Cb0:Y0 8:8:8:8 little endian",
						value = "0x56595559",
					},
					[41] = {
						name = "yvyu",
						summary = "packed YCbCr format, [31:0] Cb0:Y1:Cr0:Y0 8:8:8:8 little endian",
						value = "0x55595659",
					},
					[42] = {
						name = "uyvy",
						summary = "packed YCbCr format, [31:0] Y1:Cr0:Y0:Cb0 8:8:8:8 little endian",
						value = "0x59565955",
					},
					[43] = {
						name = "vyuy",
						summary = "packed YCbCr format, [31:0] Y1:Cb0:Y0:Cr0 8:8:8:8 little endian",
						value = "0x59555956",
					},
					[44] = {
						name = "ayuv",
						summary = "packed AYCbCr format, [31:0] A:Y:Cb:Cr 8:8:8:8 little endian",
						value = "0x56555941",
					},
					[45] = {
						name = "nv12",
						summary = "2 plane YCbCr Cr:Cb format, 2x2 subsampled Cr:Cb plane",
						value = "0x3231564e",
					},
					[46] = {
						name = "nv21",
						summary = "2 plane YCbCr Cb:Cr format, 2x2 subsampled Cb:Cr plane",
						value = "0x3132564e",
					},
					[47] = {
						name = "nv16",
						summary = "2 plane YCbCr Cr:Cb format, 2x1 subsampled Cr:Cb plane",
						value = "0x3631564e",
					},
					[48] = {
						name = "nv61",
						summary = "2 plane YCbCr Cb:Cr format, 2x1 subsampled Cb:Cr plane",
						value = "0x3136564e",
					},
					[49] = {
						name = "yuv410",
						summary = "3 plane YCbCr format, 4x4 subsampled Cb (1) and Cr (2) planes",
						value = "0x39565559",
					},
					[5] = {
						name = "bgr233",
						summary = "8-bit BGR format, [7:0] B:G:R 2:3:3",
						value = "0x38524742",
					},
					[50] = {
						name = "yvu410",
						summary = "3 plane YCbCr format, 4x4 subsampled Cr (1) and Cb (2) planes",
						value = "0x39555659",
					},
					[51] = {
						name = "yuv411",
						summary = "3 plane YCbCr format, 4x1 subsampled Cb (1) and Cr (2) planes",
						value = "0x31315559",
					},
					[52] = {
						name = "yvu411",
						summary = "3 plane YCbCr format, 4x1 subsampled Cr (1) and Cb (2) planes",
						value = "0x31315659",
					},
					[53] = {
						name = "yuv420",
						summary = "3 plane YCbCr format, 2x2 subsampled Cb (1) and Cr (2) planes",
						value = "0x32315559",
					},
					[54] = {
						name = "yvu420",
						summary = "3 plane YCbCr format, 2x2 subsampled Cr (1) and Cb (2) planes",
						value = "0x32315659",
					},
					[55] = {
						name = "yuv422",
						summary = "3 plane YCbCr format, 2x1 subsampled Cb (1) and Cr (2) planes",
						value = "0x36315559",
					},
					[56] = {
						name = "yvu422",
						summary = "3 plane YCbCr format, 2x1 subsampled Cr (1) and Cb (2) planes",
						value = "0x36315659",
					},
					[57] = {
						name = "yuv444",
						summary = "3 plane YCbCr format, non-subsampled Cb (1) and Cr (2) planes",
						value = "0x34325559",
					},
					[58] = {
						name = "yvu444",
						summary = "3 plane YCbCr format, non-subsampled Cr (1) and Cb (2) planes",
						value = "0x34325659",
					},
					[59] = {
						name = "r8",
						summary = "[7:0] R",
						value = "0x20203852",
					},
					[6] = {
						name = "xrgb4444",
						summary = "16-bit xRGB format, [15:0] x:R:G:B 4:4:4:4 little endian",
						value = "0x32315258",
					},
					[60] = {
						name = "r16",
						summary = "[15:0] R little endian",
						value = "0x20363152",
					},
					[61] = {
						name = "rg88",
						summary = "[15:0] R:G 8:8 little endian",
						value = "0x38384752",
					},
					[62] = {
						name = "gr88",
						summary = "[15:0] G:R 8:8 little endian",
						value = "0x38385247",
					},
					[63] = {
						name = "rg1616",
						summary = "[31:0] R:G 16:16 little endian",
						value = "0x32334752",
					},
					[64] = {
						name = "gr1616",
						summary = "[31:0] G:R 16:16 little endian",
						value = "0x32335247",
					},
					[65] = {
						name = "xrgb16161616f",
						summary = "[63:0] x:R:G:B 16:16:16:16 little endian",
						value = "0x48345258",
					},
					[66] = {
						name = "xbgr16161616f",
						summary = "[63:0] x:B:G:R 16:16:16:16 little endian",
						value = "0x48344258",
					},
					[67] = {
						name = "argb16161616f",
						summary = "[63:0] A:R:G:B 16:16:16:16 little endian",
						value = "0x48345241",
					},
					[68] = {
						name = "abgr16161616f",
						summary = "[63:0] A:B:G:R 16:16:16:16 little endian",
						value = "0x48344241",
					},
					[69] = {
						name = "xyuv8888",
						summary = "[31:0] X:Y:Cb:Cr 8:8:8:8 little endian",
						value = "0x56555958",
					},
					[7] = {
						name = "xbgr4444",
						summary = "16-bit xBGR format, [15:0] x:B:G:R 4:4:4:4 little endian",
						value = "0x32314258",
					},
					[70] = {
						name = "vuy888",
						summary = "[23:0] Cr:Cb:Y 8:8:8 little endian",
						value = "0x34325556",
					},
					[71] = {
						name = "vuy101010",
						summary = "Y followed by U then V, 10:10:10. Non-linear modifier only",
						value = "0x30335556",
					},
					[72] = {
						name = "y210",
						summary = "[63:0] Cr0:0:Y1:0:Cb0:0:Y0:0 10:6:10:6:10:6:10:6 little endian per 2 Y pixels",
						value = "0x30313259",
					},
					[73] = {
						name = "y212",
						summary = "[63:0] Cr0:0:Y1:0:Cb0:0:Y0:0 12:4:12:4:12:4:12:4 little endian per 2 Y pixels",
						value = "0x32313259",
					},
					[74] = {
						name = "y216",
						summary = "[63:0] Cr0:Y1:Cb0:Y0 16:16:16:16 little endian per 2 Y pixels",
						value = "0x36313259",
					},
					[75] = {
						name = "y410",
						summary = "[31:0] A:Cr:Y:Cb 2:10:10:10 little endian",
						value = "0x30313459",
					},
					[76] = {
						name = "y412",
						summary = "[63:0] A:0:Cr:0:Y:0:Cb:0 12:4:12:4:12:4:12:4 little endian",
						value = "0x32313459",
					},
					[77] = {
						name = "y416",
						summary = "[63:0] A:Cr:Y:Cb 16:16:16:16 little endian",
						value = "0x36313459",
					},
					[78] = {
						name = "xvyu2101010",
						summary = "[31:0] X:Cr:Y:Cb 2:10:10:10 little endian",
						value = "0x30335658",
					},
					[79] = {
						name = "xvyu12_16161616",
						summary = "[63:0] X:0:Cr:0:Y:0:Cb:0 12:4:12:4:12:4:12:4 little endian",
						value = "0x36335658",
					},
					[8] = {
						name = "rgbx4444",
						summary = "16-bit RGBx format, [15:0] R:G:B:x 4:4:4:4 little endian",
						value = "0x32315852",
					},
					[80] = {
						name = "xvyu16161616",
						summary = "[63:0] X:Cr:Y:Cb 16:16:16:16 little endian",
						value = "0x38345658",
					},
					[81] = {
						name = "y0l0",
						summary = "[63:0]   A3:A2:Y3:0:Cr0:0:Y2:0:A1:A0:Y1:0:Cb0:0:Y0:0  1:1:8:2:8:2:8:2:1:1:8:2:8:2:8:2 little endian",
						value = "0x304c3059",
					},
					[82] = {
						name = "x0l0",
						summary = "[63:0]   X3:X2:Y3:0:Cr0:0:Y2:0:X1:X0:Y1:0:Cb0:0:Y0:0  1:1:8:2:8:2:8:2:1:1:8:2:8:2:8:2 little endian",
						value = "0x304c3058",
					},
					[83] = {
						name = "y0l2",
						summary = "[63:0]   A3:A2:Y3:Cr0:Y2:A1:A0:Y1:Cb0:Y0  1:1:10:10:10:1:1:10:10:10 little endian",
						value = "0x324c3059",
					},
					[84] = {
						name = "x0l2",
						summary = "[63:0]   X3:X2:Y3:Cr0:Y2:X1:X0:Y1:Cb0:Y0  1:1:10:10:10:1:1:10:10:10 little endian",
						value = "0x324c3058",
					},
					[85] = {
						name = "yuv420_8bit",
						value = "0x38305559",
					},
					[86] = {
						name = "yuv420_10bit",
						value = "0x30315559",
					},
					[87] = {
						name = "xrgb8888_a8",
						value = "0x38415258",
					},
					[88] = {
						name = "xbgr8888_a8",
						value = "0x38414258",
					},
					[89] = {
						name = "rgbx8888_a8",
						value = "0x38415852",
					},
					[9] = {
						name = "bgrx4444",
						summary = "16-bit BGRx format, [15:0] B:G:R:x 4:4:4:4 little endian",
						value = "0x32315842",
					},
					[90] = {
						name = "bgrx8888_a8",
						value = "0x38415842",
					},
					[91] = {
						name = "rgb888_a8",
						value = "0x38413852",
					},
					[92] = {
						name = "bgr888_a8",
						value = "0x38413842",
					},
					[93] = {
						name = "rgb565_a8",
						value = "0x38413552",
					},
					[94] = {
						name = "bgr565_a8",
						value = "0x38413542",
					},
					[95] = {
						name = "nv24",
						summary = "non-subsampled Cr:Cb plane",
						value = "0x3432564e",
					},
					[96] = {
						name = "nv42",
						summary = "non-subsampled Cb:Cr plane",
						value = "0x3234564e",
					},
					[97] = {
						name = "p210",
						summary = "2x1 subsampled Cr:Cb plane, 10 bit per channel",
						value = "0x30313250",
					},
					[98] = {
						name = "p010",
						summary = "2x2 subsampled Cr:Cb plane 10 bits per channel",
						value = "0x30313050",
					},
					[99] = {
						name = "p012",
						summary = "2x2 subsampled Cr:Cb plane 12 bits per channel",
						value = "0x32313050",
					},
				},
				name = "format",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "format",
						type = "uint",
					},
				},
				name = "format",
				since = 1,
			},
		},
		name = "wl_shm",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_shm_pool",
						name = "id",
						type = "new_id",
					},
					[2] = {
						allow_null = false,
						name = "fd",
						type = "fd",
					},
					[3] = {
						allow_null = false,
						name = "size",
						type = "int",
					},
				},
				name = "create_pool",
				since = 1,
			},
			[2] = {
				args = {
				},
				name = "release",
				since = 2,
				type = "destructor",
			},
		},
		version = 2,
	}

	-- Request: create_pool
	function meta:create_pool(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[3]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: release
	function meta:release(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_shm*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_shm'] = meta
	ffi.metatype('struct wl_shm', meta)
end

-- Interface: wl_buffer
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
			[1] = {
				args = {
				},
				name = "release",
				since = 1,
			},
		},
		name = "wl_buffer",
		requests = {
			[1] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
		},
		version = 1,
	}

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_buffer*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_buffer'] = meta
	ffi.metatype('struct wl_buffer', meta)
end

-- Interface: wl_data_offer
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_finish",
						summary = "finish request was called untimely",
						value = "0",
					},
					[2] = {
						name = "invalid_action_mask",
						summary = "action mask contains invalid values",
						value = "1",
					},
					[3] = {
						name = "invalid_action",
						summary = "action argument has an invalid value",
						value = "2",
					},
					[4] = {
						name = "invalid_offer",
						summary = "offer doesn't accept this request",
						value = "3",
					},
				},
				name = "error",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "mime_type",
						type = "string",
					},
				},
				name = "offer",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "source_actions",
						type = "uint",
					},
				},
				name = "source_actions",
				since = 3,
			},
			[3] = {
				args = {
					[1] = {
						name = "dnd_action",
						type = "uint",
					},
				},
				name = "action",
				since = 3,
			},
		},
		name = "wl_data_offer",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
					[2] = {
						allow_null = true,
						name = "mime_type",
						type = "string",
					},
				},
				name = "accept",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						name = "mime_type",
						type = "string",
					},
					[2] = {
						allow_null = false,
						name = "fd",
						type = "fd",
					},
				},
				name = "receive",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[4] = {
				args = {
				},
				name = "finish",
				since = 3,
			},
			[5] = {
				args = {
					[1] = {
						allow_null = false,
						name = "dnd_actions",
						type = "uint",
					},
					[2] = {
						allow_null = false,
						name = "preferred_action",
						type = "uint",
					},
				},
				name = "set_actions",
				since = 3,
			},
		},
		version = 3,
	}

	-- Request: accept
	function meta:accept(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[3]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: receive
	function meta:receive(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Request: finish
	function meta:finish(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 3, args_array)
		end
	end

	-- Request: set_actions
	function meta:set_actions(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 4, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_data_offer*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_data_offer'] = meta
	ffi.metatype('struct wl_data_offer', meta)
end

-- Interface: wl_data_source
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_action_mask",
						summary = "action mask contains invalid values",
						value = "0",
					},
					[2] = {
						name = "invalid_source",
						summary = "source doesn't accept this request",
						value = "1",
					},
				},
				name = "error",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "mime_type",
						type = "string",
					},
				},
				name = "target",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "mime_type",
						type = "string",
					},
					[2] = {
						name = "fd",
						type = "fd",
					},
				},
				name = "send",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "cancelled",
				since = 1,
			},
			[4] = {
				args = {
				},
				name = "dnd_drop_performed",
				since = 3,
			},
			[5] = {
				args = {
				},
				name = "dnd_finished",
				since = 3,
			},
			[6] = {
				args = {
					[1] = {
						name = "dnd_action",
						type = "uint",
					},
				},
				name = "action",
				since = 3,
			},
		},
		name = "wl_data_source",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						name = "mime_type",
						type = "string",
					},
				},
				name = "offer",
				since = 1,
			},
			[2] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						name = "dnd_actions",
						type = "uint",
					},
				},
				name = "set_actions",
				since = 3,
			},
		},
		version = 3,
	}

	-- Request: offer
	function meta:offer(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: set_actions
	function meta:set_actions(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_data_source*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_data_source'] = meta
	ffi.metatype('struct wl_data_source', meta)
end

-- Interface: wl_data_device
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "role",
						summary = "given wl_surface has another role",
						value = "0",
					},
					[2] = {
						name = "used_source",
						summary = "source has already been used",
						value = "1",
					},
				},
				name = "error",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						interface = "wl_data_offer",
						name = "id",
						type = "new_id",
					},
				},
				name = "data_offer",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
					[3] = {
						name = "x",
						type = "fixed",
					},
					[4] = {
						name = "y",
						type = "fixed",
					},
					[5] = {
						interface = "wl_data_offer",
						name = "id",
						type = "object",
					},
				},
				name = "enter",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "leave",
				since = 1,
			},
			[4] = {
				args = {
					[1] = {
						name = "time",
						type = "uint",
					},
					[2] = {
						name = "x",
						type = "fixed",
					},
					[3] = {
						name = "y",
						type = "fixed",
					},
				},
				name = "motion",
				since = 1,
			},
			[5] = {
				args = {
				},
				name = "drop",
				since = 1,
			},
			[6] = {
				args = {
					[1] = {
						interface = "wl_data_offer",
						name = "id",
						type = "object",
					},
				},
				name = "selection",
				since = 1,
			},
		},
		name = "wl_data_device",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "wl_data_source",
						name = "source",
						type = "object",
					},
					[2] = {
						allow_null = false,
						interface = "wl_surface",
						name = "origin",
						type = "object",
					},
					[3] = {
						allow_null = true,
						interface = "wl_surface",
						name = "icon",
						type = "object",
					},
					[4] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
				},
				name = "start_drag",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "wl_data_source",
						name = "source",
						type = "object",
					},
					[2] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
				},
				name = "set_selection",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "release",
				since = 2,
				type = "destructor",
			},
		},
		version = 3,
	}

	-- Request: start_drag
	function meta:start_drag(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[6]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: set_selection
	function meta:set_selection(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[3]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: release
	function meta:release(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_data_device*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_data_device'] = meta
	ffi.metatype('struct wl_data_device', meta)
end

-- Interface: wl_data_device_manager
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = true,
				entries = {
					[1] = {
						name = "none",
						summary = "no action",
						value = "0",
					},
					[2] = {
						name = "copy",
						summary = "copy action",
						value = "1",
					},
					[3] = {
						name = "move",
						summary = "move action",
						value = "2",
					},
					[4] = {
						name = "ask",
						summary = "ask action",
						value = "4",
					},
				},
				name = "dnd_action",
			},
		},
		events = {
		},
		name = "wl_data_device_manager",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_data_source",
						name = "id",
						type = "new_id",
					},
				},
				name = "create_data_source",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_data_device",
						name = "id",
						type = "new_id",
					},
					[2] = {
						allow_null = false,
						interface = "wl_seat",
						name = "seat",
						type = "object",
					},
				},
				name = "get_data_device",
				since = 1,
			},
		},
		version = 3,
	}

	-- Request: create_data_source
	function meta:create_data_source(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: get_data_device
	function meta:get_data_device(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_data_device_manager*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_data_device_manager'] = meta
	ffi.metatype('struct wl_data_device_manager', meta)
end

-- Interface: wl_shell
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "role",
						summary = "given wl_surface has another role",
						value = "0",
					},
				},
				name = "error",
			},
		},
		events = {
		},
		name = "wl_shell",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_shell_surface",
						name = "id",
						type = "new_id",
					},
					[2] = {
						allow_null = false,
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
				},
				name = "get_shell_surface",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: get_shell_surface
	function meta:get_shell_surface(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_shell*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_shell'] = meta
	ffi.metatype('struct wl_shell', meta)
end

-- Interface: wl_shell_surface
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = true,
				entries = {
					[1] = {
						name = "none",
						summary = "no edge",
						value = "0",
					},
					[2] = {
						name = "top",
						summary = "top edge",
						value = "1",
					},
					[3] = {
						name = "bottom",
						summary = "bottom edge",
						value = "2",
					},
					[4] = {
						name = "left",
						summary = "left edge",
						value = "4",
					},
					[5] = {
						name = "top_left",
						summary = "top and left edges",
						value = "5",
					},
					[6] = {
						name = "bottom_left",
						summary = "bottom and left edges",
						value = "6",
					},
					[7] = {
						name = "right",
						summary = "right edge",
						value = "8",
					},
					[8] = {
						name = "top_right",
						summary = "top and right edges",
						value = "9",
					},
					[9] = {
						name = "bottom_right",
						summary = "bottom and right edges",
						value = "10",
					},
				},
				name = "resize",
			},
			[2] = {
				bitfield = true,
				entries = {
					[1] = {
						name = "inactive",
						summary = "do not set keyboard focus",
						value = "0x1",
					},
				},
				name = "transient",
			},
			[3] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "default",
						summary = "no preference, apply default policy",
						value = "0",
					},
					[2] = {
						name = "scale",
						summary = "scale, preserve the surface's aspect ratio and center on output",
						value = "1",
					},
					[3] = {
						name = "driver",
						summary = "switch output mode to the smallest mode that can fit the surface, add black borders to compensate size mismatch",
						value = "2",
					},
					[4] = {
						name = "fill",
						summary = "no upscaling, center on output and add black borders to compensate size mismatch",
						value = "3",
					},
				},
				name = "fullscreen_method",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
				},
				name = "ping",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "edges",
						type = "uint",
					},
					[2] = {
						name = "width",
						type = "int",
					},
					[3] = {
						name = "height",
						type = "int",
					},
				},
				name = "configure",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "popup_done",
				since = 1,
			},
		},
		name = "wl_shell_surface",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
				},
				name = "pong",
				since = 1,
			},
			[10] = {
				args = {
					[1] = {
						allow_null = false,
						name = "class_",
						type = "string",
					},
				},
				name = "set_class",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_seat",
						name = "seat",
						type = "object",
					},
					[2] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
				},
				name = "move",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_seat",
						name = "seat",
						type = "object",
					},
					[2] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
					[3] = {
						allow_null = false,
						name = "edges",
						type = "uint",
					},
				},
				name = "resize",
				since = 1,
			},
			[4] = {
				args = {
				},
				name = "set_toplevel",
				since = 1,
			},
			[5] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_surface",
						name = "parent",
						type = "object",
					},
					[2] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[3] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "flags",
						type = "uint",
					},
				},
				name = "set_transient",
				since = 1,
			},
			[6] = {
				args = {
					[1] = {
						allow_null = false,
						name = "method",
						type = "uint",
					},
					[2] = {
						allow_null = false,
						name = "framerate",
						type = "uint",
					},
					[3] = {
						allow_null = true,
						interface = "wl_output",
						name = "output",
						type = "object",
					},
				},
				name = "set_fullscreen",
				since = 1,
			},
			[7] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_seat",
						name = "seat",
						type = "object",
					},
					[2] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
					[3] = {
						allow_null = false,
						interface = "wl_surface",
						name = "parent",
						type = "object",
					},
					[4] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[5] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
					[6] = {
						allow_null = false,
						name = "flags",
						type = "uint",
					},
				},
				name = "set_popup",
				since = 1,
			},
			[8] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "wl_output",
						name = "output",
						type = "object",
					},
				},
				name = "set_maximized",
				since = 1,
			},
			[9] = {
				args = {
					[1] = {
						allow_null = false,
						name = "title",
						type = "string",
					},
				},
				name = "set_title",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: pong
	function meta:pong(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: move
	function meta:move(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: resize
	function meta:resize(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[3]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Request: set_toplevel
	function meta:set_toplevel(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 3, args_array)
		end
	end

	-- Request: set_transient
	function meta:set_transient(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 4, args_array)
		end
	end

	-- Request: set_fullscreen
	function meta:set_fullscreen(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[6].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[6].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					5,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					5,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 5, args_array)
		end
	end

	-- Request: set_popup
	function meta:set_popup(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[6]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[7].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[7].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					6,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					6,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 6, args_array)
		end
	end

	-- Request: set_maximized
	function meta:set_maximized(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[8].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[8].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					7,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					7,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 7, args_array)
		end
	end

	-- Request: set_title
	function meta:set_title(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[9].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[9].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					8,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					8,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 8, args_array)
		end
	end

	-- Request: set_class
	function meta:set_class(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[10].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[10].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					9,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					9,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 9, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_shell_surface*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_shell_surface'] = meta
	ffi.metatype('struct wl_shell_surface', meta)
end

-- Interface: wl_surface
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_scale",
						summary = "buffer scale value is invalid",
						value = "0",
					},
					[2] = {
						name = "invalid_transform",
						summary = "buffer transform value is invalid",
						value = "1",
					},
					[3] = {
						name = "invalid_size",
						summary = "buffer size is invalid",
						value = "2",
					},
					[4] = {
						name = "invalid_offset",
						summary = "buffer offset is invalid",
						value = "3",
					},
					[5] = {
						name = "defunct_role_object",
						summary = "surface was destroyed before its role object",
						value = "4",
					},
				},
				name = "error",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						interface = "wl_output",
						name = "output",
						type = "object",
					},
				},
				name = "enter",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						interface = "wl_output",
						name = "output",
						type = "object",
					},
				},
				name = "leave",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						name = "factor",
						type = "int",
					},
				},
				name = "preferred_buffer_scale",
				since = 6,
			},
			[4] = {
				args = {
					[1] = {
						name = "transform",
						type = "uint",
					},
				},
				name = "preferred_buffer_transform",
				since = 6,
			},
		},
		name = "wl_surface",
		requests = {
			[1] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[10] = {
				args = {
					[1] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
					[3] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
				},
				name = "damage_buffer",
				since = 4,
			},
			[11] = {
				args = {
					[1] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
				},
				name = "offset",
				since = 5,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "wl_buffer",
						name = "buffer",
						type = "object",
					},
					[2] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[3] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
				},
				name = "attach",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
					[3] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
				},
				name = "damage",
				since = 1,
			},
			[4] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_callback",
						name = "callback",
						type = "new_id",
					},
				},
				name = "frame",
				since = 1,
			},
			[5] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "wl_region",
						name = "region",
						type = "object",
					},
				},
				name = "set_opaque_region",
				since = 1,
			},
			[6] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "wl_region",
						name = "region",
						type = "object",
					},
				},
				name = "set_input_region",
				since = 1,
			},
			[7] = {
				args = {
				},
				name = "commit",
				since = 1,
			},
			[8] = {
				args = {
					[1] = {
						allow_null = false,
						name = "transform",
						type = "int",
					},
				},
				name = "set_buffer_transform",
				since = 2,
			},
			[9] = {
				args = {
					[1] = {
						allow_null = false,
						name = "scale",
						type = "int",
					},
				},
				name = "set_buffer_scale",
				since = 3,
			},
		},
		version = 6,
	}

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: attach
	function meta:attach(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: damage
	function meta:damage(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Request: frame
	function meta:frame(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 3, args_array)
		end
	end

	-- Request: set_opaque_region
	function meta:set_opaque_region(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 4, args_array)
		end
	end

	-- Request: set_input_region
	function meta:set_input_region(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[6].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[6].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					5,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					5,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 5, args_array)
		end
	end

	-- Request: commit
	function meta:commit(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[7].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[7].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					6,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					6,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 6, args_array)
		end
	end

	-- Request: set_buffer_transform
	function meta:set_buffer_transform(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[8].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[8].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					7,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					7,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 7, args_array)
		end
	end

	-- Request: set_buffer_scale
	function meta:set_buffer_scale(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[9].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[9].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					8,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					8,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 8, args_array)
		end
	end

	-- Request: damage_buffer
	function meta:damage_buffer(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[10].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[10].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					9,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					9,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 9, args_array)
		end
	end

	-- Request: offset
	function meta:offset(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[11].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[11].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					10,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					10,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 10, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_surface*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_surface'] = meta
	ffi.metatype('struct wl_surface', meta)
end

-- Interface: wl_seat
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = true,
				entries = {
					[1] = {
						name = "pointer",
						summary = "the seat has pointer devices",
						value = "1",
					},
					[2] = {
						name = "keyboard",
						summary = "the seat has one or more keyboards",
						value = "2",
					},
					[3] = {
						name = "touch",
						summary = "the seat has touch devices",
						value = "4",
					},
				},
				name = "capability",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "missing_capability",
						summary = "get_pointer, get_keyboard or get_touch called on seat without the matching capability",
						value = "0",
					},
				},
				name = "error",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "capabilities",
						type = "uint",
					},
				},
				name = "capabilities",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "name",
						type = "string",
					},
				},
				name = "name",
				since = 2,
			},
		},
		name = "wl_seat",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_pointer",
						name = "id",
						type = "new_id",
					},
				},
				name = "get_pointer",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_keyboard",
						name = "id",
						type = "new_id",
					},
				},
				name = "get_keyboard",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_touch",
						name = "id",
						type = "new_id",
					},
				},
				name = "get_touch",
				since = 1,
			},
			[4] = {
				args = {
				},
				name = "release",
				since = 5,
				type = "destructor",
			},
		},
		version = 10,
	}

	-- Request: get_pointer
	function meta:get_pointer(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: get_keyboard
	function meta:get_keyboard(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: get_touch
	function meta:get_touch(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Request: release
	function meta:release(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 3, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_seat*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_seat'] = meta
	ffi.metatype('struct wl_seat', meta)
end

-- Interface: wl_pointer
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "role",
						summary = "given wl_surface has another role",
						value = "0",
					},
				},
				name = "error",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "released",
						summary = "the button is not pressed",
						value = "0",
					},
					[2] = {
						name = "pressed",
						summary = "the button is pressed",
						value = "1",
					},
				},
				name = "button_state",
			},
			[3] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "vertical_scroll",
						summary = "vertical axis",
						value = "0",
					},
					[2] = {
						name = "horizontal_scroll",
						summary = "horizontal axis",
						value = "1",
					},
				},
				name = "axis",
			},
			[4] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "wheel",
						summary = "a physical wheel rotation",
						value = "0",
					},
					[2] = {
						name = "finger",
						summary = "finger on a touch surface",
						value = "1",
					},
					[3] = {
						name = "continuous",
						summary = "continuous coordinate space",
						value = "2",
					},
					[4] = {
						name = "wheel_tilt",
						summary = "a physical wheel tilt",
						value = "3",
					},
				},
				name = "axis_source",
			},
			[5] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "identical",
						summary = "physical motion matches axis direction",
						value = "0",
					},
					[2] = {
						name = "inverted",
						summary = "physical motion is the inverse of the axis direction",
						value = "1",
					},
				},
				name = "axis_relative_direction",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
					[3] = {
						name = "surface_x",
						type = "fixed",
					},
					[4] = {
						name = "surface_y",
						type = "fixed",
					},
				},
				name = "enter",
				since = 1,
			},
			[10] = {
				args = {
					[1] = {
						name = "axis",
						type = "uint",
					},
					[2] = {
						name = "value120",
						type = "int",
					},
				},
				name = "axis_value120",
				since = 8,
			},
			[11] = {
				args = {
					[1] = {
						name = "axis",
						type = "uint",
					},
					[2] = {
						name = "direction",
						type = "uint",
					},
				},
				name = "axis_relative_direction",
				since = 9,
			},
			[2] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
				},
				name = "leave",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						name = "time",
						type = "uint",
					},
					[2] = {
						name = "surface_x",
						type = "fixed",
					},
					[3] = {
						name = "surface_y",
						type = "fixed",
					},
				},
				name = "motion",
				since = 1,
			},
			[4] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						name = "time",
						type = "uint",
					},
					[3] = {
						name = "button",
						type = "uint",
					},
					[4] = {
						name = "state",
						type = "uint",
					},
				},
				name = "button",
				since = 1,
			},
			[5] = {
				args = {
					[1] = {
						name = "time",
						type = "uint",
					},
					[2] = {
						name = "axis",
						type = "uint",
					},
					[3] = {
						name = "value",
						type = "fixed",
					},
				},
				name = "axis",
				since = 1,
			},
			[6] = {
				args = {
				},
				name = "frame",
				since = 5,
			},
			[7] = {
				args = {
					[1] = {
						name = "axis_source",
						type = "uint",
					},
				},
				name = "axis_source",
				since = 5,
			},
			[8] = {
				args = {
					[1] = {
						name = "time",
						type = "uint",
					},
					[2] = {
						name = "axis",
						type = "uint",
					},
				},
				name = "axis_stop",
				since = 5,
			},
			[9] = {
				args = {
					[1] = {
						name = "axis",
						type = "uint",
					},
					[2] = {
						name = "discrete",
						type = "int",
					},
				},
				name = "axis_discrete",
				since = 5,
			},
		},
		name = "wl_pointer",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
					[2] = {
						allow_null = true,
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
					[3] = {
						allow_null = false,
						name = "hotspot_x",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "hotspot_y",
						type = "int",
					},
				},
				name = "set_cursor",
				since = 1,
			},
			[2] = {
				args = {
				},
				name = "release",
				since = 3,
				type = "destructor",
			},
		},
		version = 10,
	}

	-- Request: set_cursor
	function meta:set_cursor(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[5]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: release
	function meta:release(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_pointer*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_pointer'] = meta
	ffi.metatype('struct wl_pointer', meta)
end

-- Interface: wl_keyboard
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "no_keymap",
						summary = "no keymap; client must understand how to interpret the raw keycode",
						value = "0",
					},
					[2] = {
						name = "xkb_v1",
						summary = "libxkbcommon compatible, null-terminated string; to determine the xkb keycode, clients must add 8 to the key event keycode",
						value = "1",
					},
				},
				name = "keymap_format",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "released",
						summary = "key is not pressed",
						value = "0",
					},
					[2] = {
						name = "pressed",
						summary = "key is pressed",
						value = "1",
					},
					[3] = {
						name = "repeated",
						summary = "key was repeated",
						value = "2",
					},
				},
				name = "key_state",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "format",
						type = "uint",
					},
					[2] = {
						name = "fd",
						type = "fd",
					},
					[3] = {
						name = "size",
						type = "uint",
					},
				},
				name = "keymap",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
					[3] = {
						name = "keys",
						type = "array",
					},
				},
				name = "enter",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
				},
				name = "leave",
				since = 1,
			},
			[4] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						name = "time",
						type = "uint",
					},
					[3] = {
						name = "key",
						type = "uint",
					},
					[4] = {
						name = "state",
						type = "uint",
					},
				},
				name = "key",
				since = 1,
			},
			[5] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						name = "mods_depressed",
						type = "uint",
					},
					[3] = {
						name = "mods_latched",
						type = "uint",
					},
					[4] = {
						name = "mods_locked",
						type = "uint",
					},
					[5] = {
						name = "group",
						type = "uint",
					},
				},
				name = "modifiers",
				since = 1,
			},
			[6] = {
				args = {
					[1] = {
						name = "rate",
						type = "int",
					},
					[2] = {
						name = "delay",
						type = "int",
					},
				},
				name = "repeat_info",
				since = 4,
			},
		},
		name = "wl_keyboard",
		requests = {
			[1] = {
				args = {
				},
				name = "release",
				since = 3,
				type = "destructor",
			},
		},
		version = 10,
	}

	-- Request: release
	function meta:release(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_keyboard*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_keyboard'] = meta
	ffi.metatype('struct wl_keyboard', meta)
end

-- Interface: wl_touch
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						name = "time",
						type = "uint",
					},
					[3] = {
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
					[4] = {
						name = "id",
						type = "int",
					},
					[5] = {
						name = "x",
						type = "fixed",
					},
					[6] = {
						name = "y",
						type = "fixed",
					},
				},
				name = "down",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "serial",
						type = "uint",
					},
					[2] = {
						name = "time",
						type = "uint",
					},
					[3] = {
						name = "id",
						type = "int",
					},
				},
				name = "up",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						name = "time",
						type = "uint",
					},
					[2] = {
						name = "id",
						type = "int",
					},
					[3] = {
						name = "x",
						type = "fixed",
					},
					[4] = {
						name = "y",
						type = "fixed",
					},
				},
				name = "motion",
				since = 1,
			},
			[4] = {
				args = {
				},
				name = "frame",
				since = 1,
			},
			[5] = {
				args = {
				},
				name = "cancel",
				since = 1,
			},
			[6] = {
				args = {
					[1] = {
						name = "id",
						type = "int",
					},
					[2] = {
						name = "major",
						type = "fixed",
					},
					[3] = {
						name = "minor",
						type = "fixed",
					},
				},
				name = "shape",
				since = 6,
			},
			[7] = {
				args = {
					[1] = {
						name = "id",
						type = "int",
					},
					[2] = {
						name = "orientation",
						type = "fixed",
					},
				},
				name = "orientation",
				since = 6,
			},
		},
		name = "wl_touch",
		requests = {
			[1] = {
				args = {
				},
				name = "release",
				since = 3,
				type = "destructor",
			},
		},
		version = 10,
	}

	-- Request: release
	function meta:release(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_touch*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_touch'] = meta
	ffi.metatype('struct wl_touch', meta)
end

-- Interface: wl_output
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "unknown",
						summary = "unknown geometry",
						value = "0",
					},
					[2] = {
						name = "none",
						summary = "no geometry",
						value = "1",
					},
					[3] = {
						name = "horizontal_rgb",
						summary = "horizontal RGB",
						value = "2",
					},
					[4] = {
						name = "horizontal_bgr",
						summary = "horizontal BGR",
						value = "3",
					},
					[5] = {
						name = "vertical_rgb",
						summary = "vertical RGB",
						value = "4",
					},
					[6] = {
						name = "vertical_bgr",
						summary = "vertical BGR",
						value = "5",
					},
				},
				name = "subpixel",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "normal",
						summary = "no transform",
						value = "0",
					},
					[2] = {
						name = "90",
						summary = "90 degrees counter-clockwise",
						value = "1",
					},
					[3] = {
						name = "180",
						summary = "180 degrees counter-clockwise",
						value = "2",
					},
					[4] = {
						name = "270",
						summary = "270 degrees counter-clockwise",
						value = "3",
					},
					[5] = {
						name = "flipped",
						summary = "180 degree flip around a vertical axis",
						value = "4",
					},
					[6] = {
						name = "flipped_90",
						summary = "flip and rotate 90 degrees counter-clockwise",
						value = "5",
					},
					[7] = {
						name = "flipped_180",
						summary = "flip and rotate 180 degrees counter-clockwise",
						value = "6",
					},
					[8] = {
						name = "flipped_270",
						summary = "flip and rotate 270 degrees counter-clockwise",
						value = "7",
					},
				},
				name = "transform",
			},
			[3] = {
				bitfield = true,
				entries = {
					[1] = {
						name = "current",
						summary = "indicates this is the current mode",
						value = "0x1",
					},
					[2] = {
						name = "preferred",
						summary = "indicates this is the preferred mode",
						value = "0x2",
					},
				},
				name = "mode",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "x",
						type = "int",
					},
					[2] = {
						name = "y",
						type = "int",
					},
					[3] = {
						name = "physical_width",
						type = "int",
					},
					[4] = {
						name = "physical_height",
						type = "int",
					},
					[5] = {
						name = "subpixel",
						type = "int",
					},
					[6] = {
						name = "make",
						type = "string",
					},
					[7] = {
						name = "model",
						type = "string",
					},
					[8] = {
						name = "transform",
						type = "int",
					},
				},
				name = "geometry",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						name = "flags",
						type = "uint",
					},
					[2] = {
						name = "width",
						type = "int",
					},
					[3] = {
						name = "height",
						type = "int",
					},
					[4] = {
						name = "refresh",
						type = "int",
					},
				},
				name = "mode",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "done",
				since = 2,
			},
			[4] = {
				args = {
					[1] = {
						name = "factor",
						type = "int",
					},
				},
				name = "scale",
				since = 2,
			},
			[5] = {
				args = {
					[1] = {
						name = "name",
						type = "string",
					},
				},
				name = "name",
				since = 4,
			},
			[6] = {
				args = {
					[1] = {
						name = "description",
						type = "string",
					},
				},
				name = "description",
				since = 4,
			},
		},
		name = "wl_output",
		requests = {
			[1] = {
				args = {
				},
				name = "release",
				since = 3,
				type = "destructor",
			},
		},
		version = 4,
	}

	-- Request: release
	function meta:release(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_output*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_output'] = meta
	ffi.metatype('struct wl_output', meta)
end

-- Interface: wl_region
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
		},
		name = "wl_region",
		requests = {
			[1] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
					[3] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
				},
				name = "add",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
					[3] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
				},
				name = "subtract",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: add
	function meta:add(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: subtract
	function meta:subtract(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_region*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_region'] = meta
	ffi.metatype('struct wl_region', meta)
end

-- Interface: wl_subcompositor
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "bad_surface",
						summary = "the to-be sub-surface is invalid",
						value = "0",
					},
					[2] = {
						name = "bad_parent",
						summary = "the to-be sub-surface parent is invalid",
						value = "1",
					},
				},
				name = "error",
			},
		},
		events = {
		},
		name = "wl_subcompositor",
		requests = {
			[1] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_subsurface",
						name = "id",
						type = "new_id",
					},
					[2] = {
						allow_null = false,
						interface = "wl_surface",
						name = "surface",
						type = "object",
					},
					[3] = {
						allow_null = false,
						interface = "wl_surface",
						name = "parent",
						type = "object",
					},
				},
				name = "get_subsurface",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: get_subsurface
	function meta:get_subsurface(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[3]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_subcompositor*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_subcompositor'] = meta
	ffi.metatype('struct wl_subcompositor', meta)
end

-- Interface: wl_subsurface
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "bad_surface",
						summary = "wl_surface is not a sibling or the parent",
						value = "0",
					},
				},
				name = "error",
			},
		},
		events = {
		},
		name = "wl_subsurface",
		requests = {
			[1] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						name = "x",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
				},
				name = "set_position",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_surface",
						name = "sibling",
						type = "object",
					},
				},
				name = "place_above",
				since = 1,
			},
			[4] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_surface",
						name = "sibling",
						type = "object",
					},
				},
				name = "place_below",
				since = 1,
			},
			[5] = {
				args = {
				},
				name = "set_sync",
				since = 1,
			},
			[6] = {
				args = {
				},
				name = "set_desync",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: set_position
	function meta:set_position(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Request: place_above
	function meta:place_above(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[3].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					2,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 2, args_array)
		end
	end

	-- Request: place_below
	function meta:place_below(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[4].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					3,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 3, args_array)
		end
	end

	-- Request: set_sync
	function meta:set_sync(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[5].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					4,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 4, args_array)
		end
	end

	-- Request: set_desync
	function meta:set_desync(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[6].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[6].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					5,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					5,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 5, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_subsurface*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_subsurface'] = meta
	ffi.metatype('struct wl_subsurface', meta)
end

-- Interface: wl_fixes
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
		},
		name = "wl_fixes",
		requests = {
			[1] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "wl_registry",
						name = "registry",
						type = "object",
					},
				},
				name = "destroy_registry",
				since = 1,
			},
		},
		version = 1,
	}

	-- Request: destroy
	function meta:destroy(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[1].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					0,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 0, args_array)
		end
	end

	-- Request: destroy_registry
	function meta:destroy_registry(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[2].args) do
			if arg.type == 'new_id' then
				if not arg.interface then
					local target_iface = args[arg_idx]
					local target_ver = args[arg_idx + 1]
					arg_idx = arg_idx + 2
					if target_iface then
						args_array[array_idx].s = target_iface.name
						args_array[array_idx + 1].u = tonumber(target_ver)
						args_array[array_idx + 2].n = 0
						-- Extract pointer if it's a table with .ptr field
						new_id_interface = target_iface.ptr or target_iface
						version_for_generic = tonumber(target_ver)
					end
					array_idx = array_idx + 3
				else
					args_array[array_idx].n = 0
					array_idx = array_idx + 1
				end
			elseif arg.type == 'fixed' then
				local val = args[arg_idx] or 0
				arg_idx = arg_idx + 1
				args_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)
				array_idx = array_idx + 1
			elseif arg.type == 'object' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil
				array_idx = array_idx + 1
			elseif arg.type == 'array' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].a = ffi.cast('struct wl_array*', val)
				array_idx = array_idx + 1
			elseif arg.type == 'string' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].s = val
				array_idx = array_idx + 1
			elseif arg.type == 'fd' then
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				args_array[array_idx].h = tonumber(val)
				array_idx = array_idx + 1
			else
				local val = args[arg_idx]
				arg_idx = arg_idx + 1
				if arg.type == 'uint' then
					args_array[array_idx].u = tonumber(val)
				else
					args_array[array_idx].i = tonumber(val)
				end
				array_idx = array_idx + 1
			end
		end

		-- Call appropriate marshal function
		if has_new_id then
			if generic_new_id then
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.C[new_id_interface .. '_interface']
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					1,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 1, args_array)
		end
	end

	-- Helper to create listener
	function meta:add_listener(callbacks, data)
		local count = #iface.events
		local listener = ffi.new('void*[' .. count .. ']')
		local ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))
		listeners_registry[ptr_key] = listeners_registry[ptr_key] or {}
		table.insert(listeners_registry[ptr_key], listener)
		table.insert(listeners_registry[ptr_key], callbacks)

		for i, evt in ipairs(iface.events) do
			local cb = callbacks[evt.name]
			if cb then
				local sig_args = {'void*', 'struct wl_proxy*'}
				for _, arg in ipairs(evt.args) do
					if arg.type == 'int' then
						table.insert(sig_args, 'int32_t')
					elseif arg.type == 'uint' then
						table.insert(sig_args, 'uint32_t')
					elseif arg.type == 'fixed' then
						table.insert(sig_args, 'wl_fixed_t')
					elseif arg.type == 'string' then
						table.insert(sig_args, 'const char*')
					elseif arg.type == 'object' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'new_id' then
						table.insert(sig_args, 'struct wl_proxy*')
					elseif arg.type == 'array' then
						table.insert(sig_args, 'struct wl_array*')
					elseif arg.type == 'fd' then
						table.insert(sig_args, 'int32_t')
					end
				end

				local sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'
				local cb_func = ffi.cast(sig, function(data, proxy, ...)
					local args = {...}
					local lua_args = {}
					local arg_idx = 1

					proxy = ffi.cast('struct wl_fixes*', proxy)

					for _, arg in ipairs(evt.args) do
						local val = args[arg_idx]
						arg_idx = arg_idx + 1

						if arg.type == 'fixed' then
							val = tonumber(val) / 256.0
						elseif arg.type == 'string' then
							val = ffi.string(val)
						elseif arg.type == 'object' or arg.type == 'new_id' then
							if arg.interface then
								val = ffi.cast('struct ' .. arg.interface .. '*', val)
							end
						end

						table.insert(lua_args, val)
					end

					cb(data, proxy, unpack(lua_args))
				end)
				listener[i - 1] = cb_func
				table.insert(listeners_registry[ptr_key], cb_func)
			end
		end

		ffi.C.wl_proxy_add_listener(
			ffi.cast('struct wl_proxy*', self),
			ffi.cast('void(**)(void)', listener),
			ffi.cast('void*', data)
		)
	end

	output_table['wl_fixes'] = meta
	ffi.metatype('struct wl_fixes', meta)
end

return output_table
