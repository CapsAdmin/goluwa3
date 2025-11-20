-- Generated from xdg_decoration_unstable_v1 protocol
local ffi = require('ffi')

-- Global table to keep listener callbacks alive (prevent GC)
local listeners_registry = {}

ffi.cdef[[
// Protocol: xdg_decoration_unstable_v1
struct zxdg_decoration_manager_v1 {};
extern const struct wl_interface zxdg_decoration_manager_v1_interface;
struct zxdg_toplevel_decoration_v1 {};
extern const struct wl_interface zxdg_toplevel_decoration_v1_interface;
enum zxdg_toplevel_decoration_v1_error {
	ZXDG_TOPLEVEL_DECORATION_V1_ERROR_UNCONFIGURED_BUFFER = 0,
	ZXDG_TOPLEVEL_DECORATION_V1_ERROR_ALREADY_CONSTRUCTED = 1,
	ZXDG_TOPLEVEL_DECORATION_V1_ERROR_ORPHANED = 2,
};
enum zxdg_toplevel_decoration_v1_mode {
	ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE = 1,
	ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE = 2,
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
	local methods = ffi.new('struct wl_message[2]')
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
		local name_str = ffi.new('char[?]', #'get_toplevel_decoration' + 1)
		ffi.copy(name_str, 'get_toplevel_decoration')
		local sig_str = ffi.new('char[?]', #'no' + 1)
		ffi.copy(sig_str, 'no')
		local types = ffi.new('const struct wl_interface*[2]')
		table.insert(deferred_type_assignments, function()
			types[0] = ffi.cast('const struct wl_interface*', interface_ptrs['zxdg_toplevel_decoration_v1'])
		end)
		table.insert(deferred_type_assignments, function()
			types[1] = ffi.cast('const struct wl_interface*', interface_ptrs['xdg_toplevel'])
		end)
		data['get_toplevel_decoration_types'] = types
		methods[1].types = types
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['get_toplevel_decoration_name'] = name_str
		data['get_toplevel_decoration_sig'] = sig_str
	end
	local name_str = ffi.new('char[?]', #'zxdg_decoration_manager_v1' + 1)
	ffi.copy(name_str, 'zxdg_decoration_manager_v1')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 1
	iface_ptr[0].method_count = 2
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 0
	iface_ptr[0].events = nil
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['zxdg_decoration_manager_v1'] = iface_ptr[0]
	interface_ptrs['zxdg_decoration_manager_v1'] = iface_ptr
	interface_data['zxdg_decoration_manager_v1'] = data
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
		local name_str = ffi.new('char[?]', #'set_mode' + 1)
		ffi.copy(name_str, 'set_mode')
		local sig_str = ffi.new('char[?]', #'u' + 1)
		ffi.copy(sig_str, 'u')
		methods[1].types = nil
		methods[1].name = name_str
		methods[1].signature = sig_str
		data['set_mode_name'] = name_str
		data['set_mode_sig'] = sig_str
	end
	do
		local name_str = ffi.new('char[?]', #'unset_mode' + 1)
		ffi.copy(name_str, 'unset_mode')
		local sig_str = ffi.new('char[?]', #'' + 1)
		ffi.copy(sig_str, '')
		methods[2].types = nil
		methods[2].name = name_str
		methods[2].signature = sig_str
		data['unset_mode_name'] = name_str
		data['unset_mode_sig'] = sig_str
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
	local name_str = ffi.new('char[?]', #'zxdg_toplevel_decoration_v1' + 1)
	ffi.copy(name_str, 'zxdg_toplevel_decoration_v1')
	local iface_ptr = ffi.new('struct wl_interface[1]')
	iface_ptr[0].name = name_str
	iface_ptr[0].version = 1
	iface_ptr[0].method_count = 3
	iface_ptr[0].methods = methods
	iface_ptr[0].event_count = 1
	iface_ptr[0].events = events
	data.name_str = name_str
	data.iface_ptr = iface_ptr
	interfaces['zxdg_toplevel_decoration_v1'] = iface_ptr[0]
	interface_ptrs['zxdg_toplevel_decoration_v1'] = iface_ptr
	interface_data['zxdg_toplevel_decoration_v1'] = data
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

-- Interface: zxdg_decoration_manager_v1
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
		},
		events = {
		},
		name = "zxdg_decoration_manager_v1",
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
						interface = "zxdg_toplevel_decoration_v1",
						name = "id",
						type = "new_id",
					},
					[2] = {
						allow_null = false,
						interface = "xdg_toplevel",
						name = "toplevel",
						type = "object",
					},
				},
				name = "get_toplevel_decoration",
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

	-- Request: get_toplevel_decoration
	function meta:get_toplevel_decoration(...)
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

					proxy = ffi.cast('struct zxdg_decoration_manager_v1*', proxy)

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

	output_table['zxdg_decoration_manager_v1'] = meta
	ffi.metatype('struct zxdg_decoration_manager_v1', meta)
end

-- Interface: zxdg_toplevel_decoration_v1
do
	local meta = {}
	meta.__index = meta

	local iface = {
		enums = {
			[1] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "unconfigured_buffer",
						summary = "xdg_toplevel has a buffer attached before configure",
						value = "0",
					},
					[2] = {
						name = "already_constructed",
						summary = "xdg_toplevel already has a decoration object",
						value = "1",
					},
					[3] = {
						name = "orphaned",
						summary = "xdg_toplevel destroyed before the decoration object",
						value = "2",
					},
				},
				name = "error",
			},
			[2] = {
				bitfield = false,
				entries = {
					[1] = {
						name = "client_side",
						summary = "no server-side window decoration",
						value = "1",
					},
					[2] = {
						name = "server_side",
						summary = "server-side window decoration",
						value = "2",
					},
				},
				name = "mode",
			},
		},
		events = {
			[1] = {
				args = {
					[1] = {
						name = "mode",
						type = "uint",
					},
				},
				name = "configure",
				since = 1,
			},
		},
		name = "zxdg_toplevel_decoration_v1",
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
						name = "mode",
						type = "uint",
					},
				},
				name = "set_mode",
				since = 1,
			},
			[3] = {
				args = {
				},
				name = "unset_mode",
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

	-- Request: set_mode
	function meta:set_mode(...)
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

	-- Request: unset_mode
	function meta:unset_mode(...)
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

					proxy = ffi.cast('struct zxdg_toplevel_decoration_v1*', proxy)

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

	output_table['zxdg_toplevel_decoration_v1'] = meta
	ffi.metatype('struct zxdg_toplevel_decoration_v1', meta)
end

output_table._interface_data = interface_data
return output_table
