-- Generated from xdg_shell protocol
local ffi = require('ffi')

-- Global table to keep listener callbacks alive (prevent GC)
local listeners_registry = {}

ffi.cdef[[
// Protocol: xdg_shell
struct xdg_wm_base {};
extern const struct wl_interface xdg_wm_base_interface;
struct xdg_positioner {};
extern const struct wl_interface xdg_positioner_interface;
struct xdg_surface {};
extern const struct wl_interface xdg_surface_interface;
struct xdg_toplevel {};
extern const struct wl_interface xdg_toplevel_interface;
struct xdg_popup {};
extern const struct wl_interface xdg_popup_interface;
enum xdg_wm_base_error {
	XDG_WM_BASE_ERROR_ROLE = 0,
	XDG_WM_BASE_ERROR_DEFUNCT_SURFACES = 1,
	XDG_WM_BASE_ERROR_NOT_THE_TOPMOST_POPUP = 2,
	XDG_WM_BASE_ERROR_INVALID_POPUP_PARENT = 3,
	XDG_WM_BASE_ERROR_INVALID_SURFACE_STATE = 4,
	XDG_WM_BASE_ERROR_INVALID_POSITIONER = 5,
	XDG_WM_BASE_ERROR_UNRESPONSIVE = 6,
};
enum xdg_positioner_error {
	XDG_POSITIONER_ERROR_INVALID_INPUT = 0,
};
enum xdg_positioner_anchor {
	XDG_POSITIONER_ANCHOR_NONE = 0,
	XDG_POSITIONER_ANCHOR_TOP = 1,
	XDG_POSITIONER_ANCHOR_BOTTOM = 2,
	XDG_POSITIONER_ANCHOR_LEFT = 3,
	XDG_POSITIONER_ANCHOR_RIGHT = 4,
	XDG_POSITIONER_ANCHOR_TOP_LEFT = 5,
	XDG_POSITIONER_ANCHOR_BOTTOM_LEFT = 6,
	XDG_POSITIONER_ANCHOR_TOP_RIGHT = 7,
	XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT = 8,
};
enum xdg_positioner_gravity {
	XDG_POSITIONER_GRAVITY_NONE = 0,
	XDG_POSITIONER_GRAVITY_TOP = 1,
	XDG_POSITIONER_GRAVITY_BOTTOM = 2,
	XDG_POSITIONER_GRAVITY_LEFT = 3,
	XDG_POSITIONER_GRAVITY_RIGHT = 4,
	XDG_POSITIONER_GRAVITY_TOP_LEFT = 5,
	XDG_POSITIONER_GRAVITY_BOTTOM_LEFT = 6,
	XDG_POSITIONER_GRAVITY_TOP_RIGHT = 7,
	XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT = 8,
};
enum xdg_positioner_constraint_adjustment {
	XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_NONE = 0,
	XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X = 1,
	XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y = 2,
	XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X = 4,
	XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y = 8,
	XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_X = 16,
	XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_Y = 32,
};
enum xdg_surface_error {
	XDG_SURFACE_ERROR_NOT_CONSTRUCTED = 1,
	XDG_SURFACE_ERROR_ALREADY_CONSTRUCTED = 2,
	XDG_SURFACE_ERROR_UNCONFIGURED_BUFFER = 3,
	XDG_SURFACE_ERROR_INVALID_SERIAL = 4,
	XDG_SURFACE_ERROR_INVALID_SIZE = 5,
	XDG_SURFACE_ERROR_DEFUNCT_ROLE_OBJECT = 6,
};
enum xdg_toplevel_error {
	XDG_TOPLEVEL_ERROR_INVALID_RESIZE_EDGE = 0,
	XDG_TOPLEVEL_ERROR_INVALID_PARENT = 1,
	XDG_TOPLEVEL_ERROR_INVALID_SIZE = 2,
};
enum xdg_toplevel_resize_edge {
	XDG_TOPLEVEL_RESIZE_EDGE_NONE = 0,
	XDG_TOPLEVEL_RESIZE_EDGE_TOP = 1,
	XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM = 2,
	XDG_TOPLEVEL_RESIZE_EDGE_LEFT = 4,
	XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT = 5,
	XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT = 6,
	XDG_TOPLEVEL_RESIZE_EDGE_RIGHT = 8,
	XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT = 9,
	XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT = 10,
};
enum xdg_toplevel_state {
	XDG_TOPLEVEL_STATE_MAXIMIZED = 1,
	XDG_TOPLEVEL_STATE_FULLSCREEN = 2,
	XDG_TOPLEVEL_STATE_RESIZING = 3,
	XDG_TOPLEVEL_STATE_ACTIVATED = 4,
	XDG_TOPLEVEL_STATE_TILED_LEFT = 5,
	XDG_TOPLEVEL_STATE_TILED_RIGHT = 6,
	XDG_TOPLEVEL_STATE_TILED_TOP = 7,
	XDG_TOPLEVEL_STATE_TILED_BOTTOM = 8,
	XDG_TOPLEVEL_STATE_SUSPENDED = 9,
	XDG_TOPLEVEL_STATE_CONSTRAINED_LEFT = 10,
	XDG_TOPLEVEL_STATE_CONSTRAINED_RIGHT = 11,
	XDG_TOPLEVEL_STATE_CONSTRAINED_TOP = 12,
	XDG_TOPLEVEL_STATE_CONSTRAINED_BOTTOM = 13,
};
enum xdg_toplevel_wm_capabilities {
	XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU = 1,
	XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE = 2,
	XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN = 3,
	XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE = 4,
};
enum xdg_popup_error {
	XDG_POPUP_ERROR_INVALID_GRAB = 0,
};
]]

local output_table = {}

-- Create complete wl_interface structures
local interfaces = {}
local interface_ptrs = {}
local interface_data = {} -- Keep all C data alive (prevent GC)
local deferred_type_assignments = {} -- For forward references

do
	local data = {}
	local methods = ffi.new('struct wl_message[4]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[0].types = nil
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'create_positioner' + 1)
		ffi.copy(name_str, 'create_positioner')
		local sig_str = ffi.new('char[?]', #'n' + 1)
		ffi.copy(sig_str, 'n')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_positioner'])
		end)
		data['create_positioner_types'] = types
		methods[1].types = types
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['create_positioner_name'] = name_str
		data['create_positioner_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'get_xdg_surface' + 1)
		ffi.copy(name_str, 'get_xdg_surface')
		local sig_str = ffi.new('char[?]', #'no' + 1)
		ffi.copy(sig_str, 'no')
		local types = ffi.new('const struct wl_interface*[2]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_surface'])
		end)
		types[1] = ffi.C.wl_surface_interface
		data['get_xdg_surface_types'] = types
		methods[2].types = types
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['get_xdg_surface_name'] = name_str
		data['get_xdg_surface_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'pong' + 1)
		ffi.copy(name_str, 'pong')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		methods[3].types = nil
		methods[3].name = name_str
		methods[3].signature = sig_str
		data['pong_name'] = name_str
		data['pong_sig'] = sig_str
	end
	local events = ffi.new('struct wl_message[1]')
	data.events = events
	do
		local name_str = ffi.new('char[?]', #'ping' + 1)
		ffi.copy(name_str, 'ping')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		events[0].types = nil
		events[0].name = name_str
		events[0].signature = sig_str
		data['ping_name'] = name_str
		data['ping_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'xdg_wm_base' + 1)
	ffi.copy(name_str, 'xdg_wm_base')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 7
	iface_ptr[0].method_count = 4
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 1
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['xdg_wm_base'] = iface_ptr[0]
	interface_ptrs['xdg_wm_base'] = iface_ptr
	interface_data['xdg_wm_base'] = data
end

do
	local data = {}
	local methods = ffi.new('struct wl_message[10]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[0].types = nil
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_size' + 1)
		ffi.copy(name_str, 'set_size')
		local sig_str = ffi.new('char[?]', #'ii' + 1)
		ffi.copy(sig_str, 'ii')
		methods[1].types = nil
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['set_size_name'] = name_str
		data['set_size_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_anchor_rect' + 1)
		ffi.copy(name_str, 'set_anchor_rect')
		local sig_str = ffi.new('char[?]', #'iiii' + 1)
		ffi.copy(sig_str, 'iiii')
		methods[2].types = nil
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['set_anchor_rect_name'] = name_str
		data['set_anchor_rect_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_anchor' + 1)
		ffi.copy(name_str, 'set_anchor')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		methods[3].types = nil
		methods[3].name = name_str
		methods[3].signature = sig_str
		data['set_anchor_name'] = name_str
		data['set_anchor_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_gravity' + 1)
		ffi.copy(name_str, 'set_gravity')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		methods[4].types = nil
		methods[4].name = name_str
		methods[4].signature = sig_str
		data['set_gravity_name'] = name_str
		data['set_gravity_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_constraint_adjustment' + 1)
		ffi.copy(name_str, 'set_constraint_adjustment')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		methods[5].types = nil
		methods[5].name = name_str
		methods[5].signature = sig_str
		data['set_constraint_adjustment_name'] = name_str
		data['set_constraint_adjustment_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_offset' + 1)
		ffi.copy(name_str, 'set_offset')
		local sig_str = ffi.new('char[?]', #'ii' + 1)
		ffi.copy(sig_str, 'ii')
		methods[6].types = nil
		methods[6].name = name_str
		methods[6].signature = sig_str
		data['set_offset_name'] = name_str
		data['set_offset_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_reactive' + 1)
		ffi.copy(name_str, 'set_reactive')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[7].types = nil
		methods[7].name = name_str
		methods[7].signature = sig_str
		data['set_reactive_name'] = name_str
		data['set_reactive_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_parent_size' + 1)
		ffi.copy(name_str, 'set_parent_size')
		local sig_str = ffi.new('char[?]', #'ii' + 1)
		ffi.copy(sig_str, 'ii')
		methods[8].types = nil
		methods[8].name = name_str
		methods[8].signature = sig_str
		data['set_parent_size_name'] = name_str
		data['set_parent_size_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_parent_configure' + 1)
		ffi.copy(name_str, 'set_parent_configure')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		methods[9].types = nil
		methods[9].name = name_str
		methods[9].signature = sig_str
		data['set_parent_configure_name'] = name_str
		data['set_parent_configure_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'xdg_positioner' + 1)
	ffi.copy(name_str, 'xdg_positioner')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 7
	iface_ptr[0].method_count = 10
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 0
	iface_ptr[0].events = nil
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['xdg_positioner'] = iface_ptr[0]
	interface_ptrs['xdg_positioner'] = iface_ptr
	interface_data['xdg_positioner'] = data
end

do
	local data = {}
	local methods = ffi.new('struct wl_message[5]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[0].types = nil
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'get_toplevel' + 1)
		ffi.copy(name_str, 'get_toplevel')
		local sig_str = ffi.new('char[?]', #'n' + 1)
		ffi.copy(sig_str, 'n')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_toplevel'])
		end)
		data['get_toplevel_types'] = types
		methods[1].types = types
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['get_toplevel_name'] = name_str
		data['get_toplevel_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'get_popup' + 1)
		ffi.copy(name_str, 'get_popup')
		local sig_str = ffi.new('char[?]', #'n?oo' + 1)
		ffi.copy(sig_str, 'n?oo')
		local types = ffi.new('const struct wl_interface*[3]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_popup'])
		end)
		table.insert(deferred_type_assignments, function()
			types[1] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_surface'])
		end)
		table.insert(deferred_type_assignments, function()
			types[2] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_positioner'])
		end)
		data['get_popup_types'] = types
		methods[2].types = types
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['get_popup_name'] = name_str
		data['get_popup_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_window_geometry' + 1)
		ffi.copy(name_str, 'set_window_geometry')
		local sig_str = ffi.new('char[?]', #'iiii' + 1)
		ffi.copy(sig_str, 'iiii')
		methods[3].types = nil
		methods[3].name = name_str
		methods[3].signature = sig_str
		data['set_window_geometry_name'] = name_str
		data['set_window_geometry_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'ack_configure' + 1)
		ffi.copy(name_str, 'ack_configure')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		methods[4].types = nil
		methods[4].name = name_str
		methods[4].signature = sig_str
		data['ack_configure_name'] = name_str
		data['ack_configure_sig'] = sig_str
	end
	local events = ffi.new('struct wl_message[1]')
	data.events = events
	do
		local name_str = ffi.new('char[?]', #'configure' + 1)
		ffi.copy(name_str, 'configure')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		events[0].types = nil
		events[0].name = name_str
		events[0].signature = sig_str
		data['configure_name'] = name_str
		data['configure_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'xdg_surface' + 1)
	ffi.copy(name_str, 'xdg_surface')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 7
	iface_ptr[0].method_count = 5
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 1
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['xdg_surface'] = iface_ptr[0]
	interface_ptrs['xdg_surface'] = iface_ptr
	interface_data['xdg_surface'] = data
end

do
	local data = {}
	local methods = ffi.new('struct wl_message[14]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[0].types = nil
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_parent' + 1)
		ffi.copy(name_str, 'set_parent')
		local sig_str = ffi.new('char[?]', #'?o' + 1)
		ffi.copy(sig_str, '?o')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_toplevel'])
		end)
		data['set_parent_types'] = types
		methods[1].types = types
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['set_parent_name'] = name_str
		data['set_parent_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_title' + 1)
		ffi.copy(name_str, 'set_title')
		local sig_str = ffi.new('char[?]', #'s' + 1)
		ffi.copy(sig_str, 's')
		methods[2].types = nil
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['set_title_name'] = name_str
		data['set_title_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_app_id' + 1)
		ffi.copy(name_str, 'set_app_id')
		local sig_str = ffi.new('char[?]', #'s' + 1)
		ffi.copy(sig_str, 's')
		methods[3].types = nil
		methods[3].name = name_str
		methods[3].signature = sig_str
		data['set_app_id_name'] = name_str
		data['set_app_id_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'show_window_menu' + 1)
		ffi.copy(name_str, 'show_window_menu')
		local sig_str = ffi.new('char[?]', #'ouii' + 1)
		ffi.copy(sig_str, 'ouii')
		local types = ffi.new('const struct wl_interface*[1]')
		types[0] = ffi.C.wl_seat_interface
		data['show_window_menu_types'] = types
		methods[4].types = types
		methods[4].name = name_str
		methods[4].signature = sig_str
		data['show_window_menu_name'] = name_str
		data['show_window_menu_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'move' + 1)
		ffi.copy(name_str, 'move')
		local sig_str = ffi.new('char[?]', #'ou' + 1)
		ffi.copy(sig_str, 'ou')
		local types = ffi.new('const struct wl_interface*[1]')
		types[0] = ffi.C.wl_seat_interface
		data['move_types'] = types
		methods[5].types = types
		methods[5].name = name_str
		methods[5].signature = sig_str
		data['move_name'] = name_str
		data['move_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'resize' + 1)
		ffi.copy(name_str, 'resize')
		local sig_str = ffi.new('char[?]', #'ouu' + 1)
		ffi.copy(sig_str, 'ouu')
		local types = ffi.new('const struct wl_interface*[1]')
		types[0] = ffi.C.wl_seat_interface
		data['resize_types'] = types
		methods[6].types = types
		methods[6].name = name_str
		methods[6].signature = sig_str
		data['resize_name'] = name_str
		data['resize_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_max_size' + 1)
		ffi.copy(name_str, 'set_max_size')
		local sig_str = ffi.new('char[?]', #'ii' + 1)
		ffi.copy(sig_str, 'ii')
		methods[7].types = nil
		methods[7].name = name_str
		methods[7].signature = sig_str
		data['set_max_size_name'] = name_str
		data['set_max_size_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_min_size' + 1)
		ffi.copy(name_str, 'set_min_size')
		local sig_str = ffi.new('char[?]', #'ii' + 1)
		ffi.copy(sig_str, 'ii')
		methods[8].types = nil
		methods[8].name = name_str
		methods[8].signature = sig_str
		data['set_min_size_name'] = name_str
		data['set_min_size_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_maximized' + 1)
		ffi.copy(name_str, 'set_maximized')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[9].types = nil
		methods[9].name = name_str
		methods[9].signature = sig_str
		data['set_maximized_name'] = name_str
		data['set_maximized_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'unset_maximized' + 1)
		ffi.copy(name_str, 'unset_maximized')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[10].types = nil
		methods[10].name = name_str
		methods[10].signature = sig_str
		data['unset_maximized_name'] = name_str
		data['unset_maximized_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_fullscreen' + 1)
		ffi.copy(name_str, 'set_fullscreen')
		local sig_str = ffi.new('char[?]', #'?o' + 1)
		ffi.copy(sig_str, '?o')
		local types = ffi.new('const struct wl_interface*[1]')
		types[0] = ffi.C.wl_output_interface
		data['set_fullscreen_types'] = types
		methods[11].types = types
		methods[11].name = name_str
		methods[11].signature = sig_str
		data['set_fullscreen_name'] = name_str
		data['set_fullscreen_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'unset_fullscreen' + 1)
		ffi.copy(name_str, 'unset_fullscreen')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[12].types = nil
		methods[12].name = name_str
		methods[12].signature = sig_str
		data['unset_fullscreen_name'] = name_str
		data['unset_fullscreen_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_minimized' + 1)
		ffi.copy(name_str, 'set_minimized')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[13].types = nil
		methods[13].name = name_str
		methods[13].signature = sig_str
		data['set_minimized_name'] = name_str
		data['set_minimized_sig'] = sig_str
	end
	local events = ffi.new('struct wl_message[4]')
	data.events = events
	do
		local name_str = ffi.new('char[?]', #'configure' + 1)
		ffi.copy(name_str, 'configure')
		local sig_str = ffi.new('char[?]', #'iia' + 1)
		ffi.copy(sig_str, 'iia')
		events[0].types = nil
		events[0].name = name_str
		events[0].signature = sig_str
		data['configure_name'] = name_str
		data['configure_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'close' + 1)
		ffi.copy(name_str, 'close')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		events[1].types = nil
		events[1].name = name_str
		events[1].signature = sig_str
		data['close_name'] = name_str
		data['close_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'configure_bounds' + 1)
		ffi.copy(name_str, 'configure_bounds')
		local sig_str = ffi.new('char[?]', #'ii' + 1)
		ffi.copy(sig_str, 'ii')
		events[2].types = nil
		events[2].name = name_str
		events[2].signature = sig_str
		data['configure_bounds_name'] = name_str
		data['configure_bounds_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'wm_capabilities' + 1)
		ffi.copy(name_str, 'wm_capabilities')
		local sig_str = ffi.new('char[?]', #'a' + 1)
		ffi.copy(sig_str, 'a')
		events[3].types = nil
		events[3].name = name_str
		events[3].signature = sig_str
		data['wm_capabilities_name'] = name_str
		data['wm_capabilities_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'xdg_toplevel' + 1)
	ffi.copy(name_str, 'xdg_toplevel')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 7
	iface_ptr[0].method_count = 14
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 4
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['xdg_toplevel'] = iface_ptr[0]
	interface_ptrs['xdg_toplevel'] = iface_ptr
	interface_data['xdg_toplevel'] = data
end

do
	local data = {}
	local methods = ffi.new('struct wl_message[3]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[0].types = nil
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'grab' + 1)
		ffi.copy(name_str, 'grab')
		local sig_str = ffi.new('char[?]', #'ou' + 1)
		ffi.copy(sig_str, 'ou')
		local types = ffi.new('const struct wl_interface*[1]')
		types[0] = ffi.C.wl_seat_interface
		data['grab_types'] = types
		methods[1].types = types
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['grab_name'] = name_str
		data['grab_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'reposition' + 1)
		ffi.copy(name_str, 'reposition')
		local sig_str = ffi.new('char[?]', #'ou' + 1)
		ffi.copy(sig_str, 'ou')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_positioner'])
		end)
		data['reposition_types'] = types
		methods[2].types = types
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['reposition_name'] = name_str
		data['reposition_sig'] = sig_str
	end
	local events = ffi.new('struct wl_message[3]')
	data.events = events
	do
		local name_str = ffi.new('char[?]', #'configure' + 1)
		ffi.copy(name_str, 'configure')
		local sig_str = ffi.new('char[?]', #'iiii' + 1)
		ffi.copy(sig_str, 'iiii')
		events[0].types = nil
		events[0].name = name_str
		events[0].signature = sig_str
		data['configure_name'] = name_str
		data['configure_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'popup_done' + 1)
		ffi.copy(name_str, 'popup_done')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		events[1].types = nil
		events[1].name = name_str
		events[1].signature = sig_str
		data['popup_done_name'] = name_str
		data['popup_done_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'repositioned' + 1)
		ffi.copy(name_str, 'repositioned')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		events[2].types = nil
		events[2].name = name_str
		events[2].signature = sig_str
		data['repositioned_name'] = name_str
		data['repositioned_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'xdg_popup' + 1)
	ffi.copy(name_str, 'xdg_popup')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 7
	iface_ptr[0].method_count = 3
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 3
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['xdg_popup'] = iface_ptr[0]
	interface_ptrs['xdg_popup'] = iface_ptr
	interface_data['xdg_popup'] = data
end

-- Execute deferred type assignments for forward references
for _, fn in ipairs(deferred_type_assignments) do
	fn()
end

-- Helper to get interface
function output_table.get_interface(name)
	return {
		name = name,
		ptr = interface_ptrs[name]
	}
end

-- Interface: xdg_wm_base
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
						name = "defunct_surfaces",
						summary = "xdg_wm_base was destroyed before children",
						value = "1",
					},
					[3] = {
						name = "not_the_topmost_popup",
						summary = "the client tried to map or destroy a non-topmost popup",
						value = "2",
					},
					[4] = {
						name = "invalid_popup_parent",
						summary = "the client specified an invalid popup parent surface",
						value = "3",
					},
					[5] = {
						name = "invalid_surface_state",
						summary = "the client provided an invalid surface state",
						value = "4",
					},
					[6] = {
						name = "invalid_positioner",
						summary = "the client provided an invalid positioner",
						value = "5",
					},
					[7] = {
						name = "unresponsive",
						summary = "the client didn’t respond to a ping event in time",
						value = "6",
					},
				},
				name = "error",
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
		},
		name = "xdg_wm_base",
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
						interface = "xdg_positioner",
						name = "id",
						type = "new_id",
					},
				},
				name = "create_positioner",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "xdg_surface",
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
				name = "get_xdg_surface",
				since = 1,
			},
			[4] = {
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
		},
		version = 7,
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: create_positioner
	function meta:create_positioner(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: get_xdg_surface
	function meta:get_xdg_surface(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

					proxy = ffi.cast('struct xdg_wm_base*', proxy)

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

	output_table['xdg_wm_base'] = meta
	ffi.metatype('struct xdg_wm_base', meta)
end

-- Interface: xdg_positioner
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_input",
						summary = "invalid input provided",
						value = "0",
					},
				},
				name = "error",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "none",
						value = "0",
					},
					[2] = {
						name = "top",
						value = "1",
					},
					[3] = {
						name = "bottom",
						value = "2",
					},
					[4] = {
						name = "left",
						value = "3",
					},
					[5] = {
						name = "right",
						value = "4",
					},
					[6] = {
						name = "top_left",
						value = "5",
					},
					[7] = {
						name = "bottom_left",
						value = "6",
					},
					[8] = {
						name = "top_right",
						value = "7",
					},
					[9] = {
						name = "bottom_right",
						value = "8",
					},
				},
				name = "anchor",
			},
			[3] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "none",
						value = "0",
					},
					[2] = {
						name = "top",
						value = "1",
					},
					[3] = {
						name = "bottom",
						value = "2",
					},
					[4] = {
						name = "left",
						value = "3",
					},
					[5] = {
						name = "right",
						value = "4",
					},
					[6] = {
						name = "top_left",
						value = "5",
					},
					[7] = {
						name = "bottom_left",
						value = "6",
					},
					[8] = {
						name = "top_right",
						value = "7",
					},
					[9] = {
						name = "bottom_right",
						value = "8",
					},
				},
				name = "gravity",
			},
			[4] = {
				bitfield = true,
				entries = {
					[1] = {
						name = "none",
						value = "0",
					},
					[2] = {
						name = "slide_x",
						value = "1",
					},
					[3] = {
						name = "slide_y",
						value = "2",
					},
					[4] = {
						name = "flip_x",
						value = "4",
					},
					[5] = {
						name = "flip_y",
						value = "8",
					},
					[6] = {
						name = "resize_x",
						value = "16",
					},
					[7] = {
						name = "resize_y",
						value = "32",
					},
				},
				name = "constraint_adjustment",
			},
		},
		events = {
		},
		name = "xdg_positioner",
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
						name = "serial",
						type = "uint",
					},
				},
				name = "set_parent_configure",
				since = 3,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
				},
				name = "set_size",
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
				name = "set_anchor_rect",
				since = 1,
			},
			[4] = {
				args = {
					[1] = {
						allow_null = false,
						name = "anchor",
						type = "uint",
					},
				},
				name = "set_anchor",
				since = 1,
			},
			[5] = {
				args = {
					[1] = {
						allow_null = false,
						name = "gravity",
						type = "uint",
					},
				},
				name = "set_gravity",
				since = 1,
			},
			[6] = {
				args = {
					[1] = {
						allow_null = false,
						name = "constraint_adjustment",
						type = "uint",
					},
				},
				name = "set_constraint_adjustment",
				since = 1,
			},
			[7] = {
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
				name = "set_offset",
				since = 1,
			},
			[8] = {
				args = {
				},
				name = "set_reactive",
				since = 3,
			},
			[9] = {
				args = {
					[1] = {
						allow_null = false,
						name = "parent_width",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "parent_height",
						type = "int",
					},
				},
				name = "set_parent_size",
				since = 3,
			},
		},
		version = 7,
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_size
	function meta:set_size(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_anchor_rect
	function meta:set_anchor_rect(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_anchor
	function meta:set_anchor(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_gravity
	function meta:set_gravity(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_constraint_adjustment
	function meta:set_constraint_adjustment(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_offset
	function meta:set_offset(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_reactive
	function meta:set_reactive(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_parent_size
	function meta:set_parent_size(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_parent_configure
	function meta:set_parent_configure(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

					proxy = ffi.cast('struct xdg_positioner*', proxy)

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

	output_table['xdg_positioner'] = meta
	ffi.metatype('struct xdg_positioner', meta)
end

-- Interface: xdg_surface
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "not_constructed",
						summary = "Surface was not fully constructed",
						value = "1",
					},
					[2] = {
						name = "already_constructed",
						summary = "Surface was already constructed",
						value = "2",
					},
					[3] = {
						name = "unconfigured_buffer",
						summary = "Attaching a buffer to an unconfigured surface",
						value = "3",
					},
					[4] = {
						name = "invalid_serial",
						summary = "Invalid serial number when acking a configure event",
						value = "4",
					},
					[5] = {
						name = "invalid_size",
						summary = "Width or height was zero or negative",
						value = "5",
					},
					[6] = {
						name = "defunct_role_object",
						summary = "Surface was destroyed before its role object",
						value = "6",
					},
				},
				name = "error",
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
				name = "configure",
				since = 1,
			},
		},
		name = "xdg_surface",
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
						interface = "xdg_toplevel",
						name = "id",
						type = "new_id",
					},
				},
				name = "get_toplevel",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "xdg_popup",
						name = "id",
						type = "new_id",
					},
					[2] = {
						allow_null = true,
						interface = "xdg_surface",
						name = "parent",
						type = "object",
					},
					[3] = {
						allow_null = false,
						interface = "xdg_positioner",
						name = "positioner",
						type = "object",
					},
				},
				name = "get_popup",
				since = 1,
			},
			[4] = {
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
				name = "set_window_geometry",
				since = 1,
			},
			[5] = {
				args = {
					[1] = {
						allow_null = false,
						name = "serial",
						type = "uint",
					},
				},
				name = "ack_configure",
				since = 1,
			},
		},
		version = 7,
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: get_toplevel
	function meta:get_toplevel(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: get_popup
	function meta:get_popup(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_window_geometry
	function meta:set_window_geometry(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[4]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: ack_configure
	function meta:ack_configure(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

					proxy = ffi.cast('struct xdg_surface*', proxy)

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

	output_table['xdg_surface'] = meta
	ffi.metatype('struct xdg_surface', meta)
end

-- Interface: xdg_toplevel
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_resize_edge",
						summary = "provided value is\n        not a valid variant of the resize_edge enum",
						value = "0",
					},
					[2] = {
						name = "invalid_parent",
						summary = "invalid parent toplevel",
						value = "1",
					},
					[3] = {
						name = "invalid_size",
						summary = "client provided an invalid min or max size",
						value = "2",
					},
				},
				name = "error",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "none",
						value = "0",
					},
					[2] = {
						name = "top",
						value = "1",
					},
					[3] = {
						name = "bottom",
						value = "2",
					},
					[4] = {
						name = "left",
						value = "4",
					},
					[5] = {
						name = "top_left",
						value = "5",
					},
					[6] = {
						name = "bottom_left",
						value = "6",
					},
					[7] = {
						name = "right",
						value = "8",
					},
					[8] = {
						name = "top_right",
						value = "9",
					},
					[9] = {
						name = "bottom_right",
						value = "10",
					},
				},
				name = "resize_edge",
			},
			[3] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "maximized",
						summary = "the surface is maximized",
						value = "1",
					},
					[10] = {
						name = "constrained_left",
						value = "10",
					},
					[11] = {
						name = "constrained_right",
						value = "11",
					},
					[12] = {
						name = "constrained_top",
						value = "12",
					},
					[13] = {
						name = "constrained_bottom",
						value = "13",
					},
					[2] = {
						name = "fullscreen",
						summary = "the surface is fullscreen",
						value = "2",
					},
					[3] = {
						name = "resizing",
						summary = "the surface is being resized",
						value = "3",
					},
					[4] = {
						name = "activated",
						summary = "the surface is now activated",
						value = "4",
					},
					[5] = {
						name = "tiled_left",
						value = "5",
					},
					[6] = {
						name = "tiled_right",
						value = "6",
					},
					[7] = {
						name = "tiled_top",
						value = "7",
					},
					[8] = {
						name = "tiled_bottom",
						value = "8",
					},
					[9] = {
						name = "suspended",
						value = "9",
					},
				},
				name = "state",
			},
			[4] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "window_menu",
						summary = "show_window_menu is available",
						value = "1",
					},
					[2] = {
						name = "maximize",
						summary = "set_maximized and unset_maximized are available",
						value = "2",
					},
					[3] = {
						name = "fullscreen",
						summary = "set_fullscreen and unset_fullscreen are available",
						value = "3",
					},
					[4] = {
						name = "minimize",
						summary = "set_minimized is available",
						value = "4",
					},
				},
				name = "wm_capabilities",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "width",
						type = "int",
					},
					[2] = {
						name = "height",
						type = "int",
					},
					[3] = {
						name = "states",
						type = "array",
					},
				},
				name = "configure",
				since = 1,
			},
			[2] = {
				args = {
				},
				name = "close",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						name = "width",
						type = "int",
					},
					[2] = {
						name = "height",
						type = "int",
					},
				},
				name = "configure_bounds",
				since = 4,
			},
			[4] = {
				args = {
					[1] = {
						name = "capabilities",
						type = "array",
					},
				},
				name = "wm_capabilities",
				since = 5,
			},
		},
		name = "xdg_toplevel",
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
				},
				name = "set_maximized",
				since = 1,
			},
			[11] = {
				args = {
				},
				name = "unset_maximized",
				since = 1,
			},
			[12] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "wl_output",
						name = "output",
						type = "object",
					},
				},
				name = "set_fullscreen",
				since = 1,
			},
			[13] = {
				args = {
				},
				name = "unset_fullscreen",
				since = 1,
			},
			[14] = {
				args = {
				},
				name = "set_minimized",
				since = 1,
			},
			[2] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "xdg_toplevel",
						name = "parent",
						type = "object",
					},
				},
				name = "set_parent",
				since = 1,
			},
			[3] = {
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
			[4] = {
				args = {
					[1] = {
						allow_null = false,
						name = "app_id",
						type = "string",
					},
				},
				name = "set_app_id",
				since = 1,
			},
			[5] = {
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
						name = "x",
						type = "int",
					},
					[4] = {
						allow_null = false,
						name = "y",
						type = "int",
					},
				},
				name = "show_window_menu",
				since = 1,
			},
			[6] = {
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
						name = "edges",
						type = "uint",
					},
				},
				name = "resize",
				since = 1,
			},
			[8] = {
				args = {
					[1] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
				},
				name = "set_max_size",
				since = 1,
			},
			[9] = {
				args = {
					[1] = {
						allow_null = false,
						name = "width",
						type = "int",
					},
					[2] = {
						allow_null = false,
						name = "height",
						type = "int",
					},
				},
				name = "set_min_size",
				since = 1,
			},
		},
		version = 7,
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_parent
	function meta:set_parent(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_app_id
	function meta:set_app_id(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: show_window_menu
	function meta:show_window_menu(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_max_size
	function meta:set_max_size(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_min_size
	function meta:set_min_size(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_maximized
	function meta:set_maximized(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: unset_maximized
	function meta:unset_maximized(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: set_fullscreen
	function meta:set_fullscreen(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[12].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[12].args) do
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
					11,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					11,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 11, args_array)
		end
	end

	-- Request: unset_fullscreen
	function meta:unset_fullscreen(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[13].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[13].args) do
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
					12,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					12,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 12, args_array)
		end
	end

	-- Request: set_minimized
	function meta:set_minimized(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args
		local arg_idx = 1
		local array_idx = 0
		local has_new_id = false
		local new_id_interface = nil
		local generic_new_id = false
		local version_for_generic = nil

		-- Check if this request has a new_id (constructor)
		for _, arg in ipairs(iface.requests[14].args) do
			if arg.type == 'new_id' then
				has_new_id = true
				new_id_interface = arg.interface
				if not new_id_interface then generic_new_id = true end
				break
			end
		end

		-- Process arguments
		for i, arg in ipairs(iface.requests[14].args) do
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
					13,
					args_array,
					new_id_interface,
					version_for_generic
				)
				return ffi.cast('void*', new_proxy)
			elseif new_id_interface then
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
				local new_proxy = ffi.C.wl_proxy_marshal_array_constructor(
					ffi.cast('struct wl_proxy*', self),
					13,
					args_array,
					target_interface
				)
				return ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)
			end
		else
			ffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), 13, args_array)
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

					proxy = ffi.cast('struct xdg_toplevel*', proxy)

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

	output_table['xdg_toplevel'] = meta
	ffi.metatype('struct xdg_toplevel', meta)
end

-- Interface: xdg_popup
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_grab",
						summary = "tried to grab after being mapped",
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
						name = "x",
						type = "int",
					},
					[2] = {
						name = "y",
						type = "int",
					},
					[3] = {
						name = "width",
						type = "int",
					},
					[4] = {
						name = "height",
						type = "int",
					},
				},
				name = "configure",
				since = 1,
			},
			[2] = {
				args = {
				},
				name = "popup_done",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						name = "token",
						type = "uint",
					},
				},
				name = "repositioned",
				since = 3,
			},
		},
		name = "xdg_popup",
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
				name = "grab",
				since = 1,
			},
			[3] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "xdg_positioner",
						name = "positioner",
						type = "object",
					},
					[2] = {
						allow_null = false,
						name = "token",
						type = "uint",
					},
				},
				name = "reposition",
				since = 3,
			},
		},
		version = 7,
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: grab
	function meta:grab(...)
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

	-- Request: reposition
	function meta:reposition(...)
		local args = {...}
		local args_array = ffi.new('union wl_argument[2]')
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
				local target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])
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

					proxy = ffi.cast('struct xdg_popup*', proxy)

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

	output_table['xdg_popup'] = meta
	ffi.metatype('struct xdg_popup', meta)
end

return output_table
