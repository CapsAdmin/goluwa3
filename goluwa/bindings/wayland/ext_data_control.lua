-- Generated from ext_data_control_v1 protocol
local ffi = require('ffi')

-- Global table to keep listener callbacks alive (prevent GC)
local listeners_registry = {}

ffi.cdef[[
// Protocol: ext_data_control_v1
struct ext_data_control_manager_v1 {};
extern const struct wl_interface ext_data_control_manager_v1_interface;
struct ext_data_control_device_v1 {};
extern const struct wl_interface ext_data_control_device_v1_interface;
struct ext_data_control_source_v1 {};
extern const struct wl_interface ext_data_control_source_v1_interface;
struct ext_data_control_offer_v1 {};
extern const struct wl_interface ext_data_control_offer_v1_interface;
enum ext_data_control_device_v1_error {
	EXT_DATA_CONTROL_DEVICE_V1_ERROR_USED_SOURCE = 1,
};
enum ext_data_control_source_v1_error {
	EXT_DATA_CONTROL_SOURCE_V1_ERROR_INVALID_OFFER = 1,
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
	local methods = ffi.new('struct wl_message[3]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'create_data_source' + 1)
		ffi.copy(name_str, 'create_data_source')
		local sig_str = ffi.new('char[?]', #'n' + 1)
		ffi.copy(sig_str, 'n')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['ext_data_control_source_v1'])
		end)
		data['create_data_source_types'] = types
		methods[0].types = types
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['create_data_source_name'] = name_str
		data['create_data_source_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'get_data_device' + 1)
		ffi.copy(name_str, 'get_data_device')
		local sig_str = ffi.new('char[?]', #'no' + 1)
		ffi.copy(sig_str, 'no')
		local types = ffi.new('const struct wl_interface*[2]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['ext_data_control_device_v1'])
		end)
		types[1] = ffi.C.wl_seat_interface
		data['get_data_device_types'] = types
		methods[1].types = types
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['get_data_device_name'] = name_str
		data['get_data_device_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[2].types = nil
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'ext_data_control_manager_v1' + 1)
	ffi.copy(name_str, 'ext_data_control_manager_v1')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 2
	iface_ptr[0].method_count = 3
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 0
	iface_ptr[0].events = nil
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['ext_data_control_manager_v1'] = iface_ptr[0]
	interface_ptrs['ext_data_control_manager_v1'] = iface_ptr
	interface_data['ext_data_control_manager_v1'] = data
end

do
	local data = {}
	local methods = ffi.new('struct wl_message[3]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'set_selection' + 1)
		ffi.copy(name_str, 'set_selection')
		local sig_str = ffi.new('char[?]', #'?o' + 1)
		ffi.copy(sig_str, '?o')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['ext_data_control_source_v1'])
		end)
		data['set_selection_types'] = types
		methods[0].types = types
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['set_selection_name'] = name_str
		data['set_selection_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[1].types = nil
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'set_primary_selection' + 1)
		ffi.copy(name_str, 'set_primary_selection')
		local sig_str = ffi.new('char[?]', #'?o' + 1)
		ffi.copy(sig_str, '?o')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['ext_data_control_source_v1'])
		end)
		data['set_primary_selection_types'] = types
		methods[2].types = types
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['set_primary_selection_name'] = name_str
		data['set_primary_selection_sig'] = sig_str
	end
	local events = ffi.new('struct wl_message[4]')
	data.events = events
	do
		local name_str = ffi.new('char[?]', #'data_offer' + 1)
		ffi.copy(name_str, 'data_offer')
		local sig_str = ffi.new('char[?]', #'n' + 1)
		ffi.copy(sig_str, 'n')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['ext_data_control_offer_v1'])
		end)
		data['data_offer_types'] = types
		events[0].types = types
		events[0].name = name_str
		events[0].signature = sig_str
		data['data_offer_name'] = name_str
		data['data_offer_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'selection' + 1)
		ffi.copy(name_str, 'selection')
		local sig_str = ffi.new('char[?]', #'o' + 1)
		ffi.copy(sig_str, 'o')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['ext_data_control_offer_v1'])
		end)
		data['selection_types'] = types
		events[1].types = types
		events[1].name = name_str
		events[1].signature = sig_str
		data['selection_name'] = name_str
		data['selection_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'finished' + 1)
		ffi.copy(name_str, 'finished')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		events[2].types = nil
		events[2].name = name_str
		events[2].signature = sig_str
		data['finished_name'] = name_str
		data['finished_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'primary_selection' + 1)
		ffi.copy(name_str, 'primary_selection')
		local sig_str = ffi.new('char[?]', #'o' + 1)
		ffi.copy(sig_str, 'o')
		local types = ffi.new('const struct wl_interface*[1]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['ext_data_control_offer_v1'])
		end)
		data['primary_selection_types'] = types
		events[3].types = types
		events[3].name = name_str
		events[3].signature = sig_str
		data['primary_selection_name'] = name_str
		data['primary_selection_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'ext_data_control_device_v1' + 1)
	ffi.copy(name_str, 'ext_data_control_device_v1')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 2
	iface_ptr[0].method_count = 3
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 4
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['ext_data_control_device_v1'] = iface_ptr[0]
	interface_ptrs['ext_data_control_device_v1'] = iface_ptr
	interface_data['ext_data_control_device_v1'] = data
end

do
	local data = {}
	local methods = ffi.new('struct wl_message[2]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'offer' + 1)
		ffi.copy(name_str, 'offer')
		local sig_str = ffi.new('char[?]', #'s' + 1)
		ffi.copy(sig_str, 's')
		methods[0].types = nil
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['offer_name'] = name_str
		data['offer_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[1].types = nil
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	local events = ffi.new('struct wl_message[2]')
	data.events = events
	do
		local name_str = ffi.new('char[?]', #'send' + 1)
		ffi.copy(name_str, 'send')
		local sig_str = ffi.new('char[?]', #'sh' + 1)
		ffi.copy(sig_str, 'sh')
		events[0].types = nil
		events[0].name = name_str
		events[0].signature = sig_str
		data['send_name'] = name_str
		data['send_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'cancelled' + 1)
		ffi.copy(name_str, 'cancelled')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		events[1].types = nil
		events[1].name = name_str
		events[1].signature = sig_str
		data['cancelled_name'] = name_str
		data['cancelled_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'ext_data_control_source_v1' + 1)
	ffi.copy(name_str, 'ext_data_control_source_v1')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 1
	iface_ptr[0].method_count = 2
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 2
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['ext_data_control_source_v1'] = iface_ptr[0]
	interface_ptrs['ext_data_control_source_v1'] = iface_ptr
	interface_data['ext_data_control_source_v1'] = data
end

do
	local data = {}
	local methods = ffi.new('struct wl_message[2]')
	data.methods = methods
	do
		local name_str = ffi.new('char[?]', #'receive' + 1)
		ffi.copy(name_str, 'receive')
		local sig_str = ffi.new('char[?]', #'sh' + 1)
		ffi.copy(sig_str, 'sh')
		methods[0].types = nil
		methods[0].name = name_str
		methods[0].signature = sig_str
		data['receive_name'] = name_str
		data['receive_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'destroy' + 1)
		ffi.copy(name_str, 'destroy')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[1].types = nil
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['destroy_name'] = name_str
		data['destroy_sig'] = sig_str
	end
	local events = ffi.new('struct wl_message[1]')
	data.events = events
	do
		local name_str = ffi.new('char[?]', #'offer' + 1)
		ffi.copy(name_str, 'offer')
		local sig_str = ffi.new('char[?]', #'s' + 1)
		ffi.copy(sig_str, 's')
		events[0].types = nil
		events[0].name = name_str
		events[0].signature = sig_str
		data['offer_name'] = name_str
		data['offer_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'ext_data_control_offer_v1' + 1)
	ffi.copy(name_str, 'ext_data_control_offer_v1')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 1
	iface_ptr[0].method_count = 2
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 1
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['ext_data_control_offer_v1'] = iface_ptr[0]
	interface_ptrs['ext_data_control_offer_v1'] = iface_ptr
	interface_data['ext_data_control_offer_v1'] = data
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

-- Interface: ext_data_control_manager_v1
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
		},
		name = "ext_data_control_manager_v1",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = false,
						interface = "ext_data_control_source_v1",
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
						interface = "ext_data_control_device_v1",
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
			[3] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
		},
		version = 2,
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

					proxy = ffi.cast('struct ext_data_control_manager_v1*', proxy)

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

	output_table['ext_data_control_manager_v1'] = meta
	ffi.metatype('struct ext_data_control_manager_v1', meta)
end

-- Interface: ext_data_control_device_v1
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "used_source",
						summary = "source given to set_selection or set_primary_selection was already used before",
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
						interface = "ext_data_control_offer_v1",
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
						interface = "ext_data_control_offer_v1",
						name = "id",
						type = "object",
					},
				},
				name = "selection",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "finished",
				since = 1,
			},
			[4] = {
				args = {
					[1] = {
						interface = "ext_data_control_offer_v1",
						name = "id",
						type = "object",
					},
				},
				name = "primary_selection",
				since = 2,
			},
		},
		name = "ext_data_control_device_v1",
		requests = {
			[1] = {
				args = {
					[1] = {
						allow_null = true,
						interface = "ext_data_control_source_v1",
						name = "source",
						type = "object",
					},
				},
				name = "set_selection",
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
						allow_null = true,
						interface = "ext_data_control_source_v1",
						name = "source",
						type = "object",
					},
				},
				name = "set_primary_selection",
				since = 2,
			},
		},
		version = 2,
	}

	-- Request: set_selection
	function meta:set_selection(...)
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

	-- Request: set_primary_selection
	function meta:set_primary_selection(...)
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

					proxy = ffi.cast('struct ext_data_control_device_v1*', proxy)

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

	output_table['ext_data_control_device_v1'] = meta
	ffi.metatype('struct ext_data_control_device_v1', meta)
end

-- Interface: ext_data_control_source_v1
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "invalid_offer",
						summary = "offer sent after wlr_data_control_device.set_selection",
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
					[2] = {
						name = "fd",
						type = "fd",
					},
				},
				name = "send",
				since = 1,
			},
			[2] = {
				args = {
				},
				name = "cancelled",
				since = 1,
			},
		},
		name = "ext_data_control_source_v1",
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
		},
		version = 1,
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

					proxy = ffi.cast('struct ext_data_control_source_v1*', proxy)

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

	output_table['ext_data_control_source_v1'] = meta
	ffi.metatype('struct ext_data_control_source_v1', meta)
end

-- Interface: ext_data_control_offer_v1
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
						name = "mime_type",
						type = "string",
					},
				},
				name = "offer",
				since = 1,
			},
		},
		name = "ext_data_control_offer_v1",
		requests = {
			[1] = {
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
			[2] = {
				args = {
				},
				name = "destroy",
				since = 1,
				type = "destructor",
			},
		},
		version = 1,
	}

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

					proxy = ffi.cast('struct ext_data_control_offer_v1*', proxy)

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

	output_table['ext_data_control_offer_v1'] = meta
	ffi.metatype('struct ext_data_control_offer_v1', meta)
end

output_table._interface_data = interface_data
return output_table
