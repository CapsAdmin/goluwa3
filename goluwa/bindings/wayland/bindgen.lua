local scanner = {}

-- Inlined XML parser
local function parse_xml(s)
	local io, string, pairs = io, string, pairs
	local slashchar = string.byte("/", 1)
	local E = string.byte("E", 1)

	local function defaultEntityTable()
		return {
			quot = "\"",
			apos = "\'",
			lt = "<",
			gt = ">",
			amp = "&",
			tab = "\t",
			nbsp = " ",
		}
	end

	local function replaceEntities(s, entities)
		return s:gsub("&([^;]+);", entities)
	end

	local function createEntityTable(docEntities, resultEntities)
		local entities = resultEntities or defaultEntityTable()

		for _, e in pairs(docEntities) do
			e.value = replaceEntities(e.value, entities)
			entities[e.name] = e.value
		end

		return entities
	end

	-- remove comments
	s = s:gsub("<!--(.-)-->", "")
	local entities, tentities = {}
	local t, l = {}, {}
	local addtext = function(txt)
		txt = txt:match("^%s*(.* %S)") or ""

		if #txt ~= 0 then t[#t + 1] = {text = txt} end
	end

	s:gsub("<([?!/]?)([-:_%w]+)%s*(/?>?)([^<]*)", function(type, name, closed, txt)
		-- open
		if #type == 0 then
			local attrs, orderedattrs = {}, {}

			if #closed == 0 then
				local len = 0

				for all, aname, _, value, starttxt in string.gmatch(txt, "(.-([-_%w]+)%s*=%s*(.)(.-)%3%s*(/?>?))") do
					len = len + #all
					attrs[aname] = value
					orderedattrs[#orderedattrs + 1] = {name = aname, value = value}

					if #starttxt ~= 0 then
						txt = txt:sub(len + 1)
						closed = starttxt

						break
					end
				end
			end

			t[#t + 1] = {tag = name, attrs = attrs, children = {}, orderedattrs = orderedattrs}

			if closed:byte(1) ~= slashchar then
				l[#l + 1] = t
				t = t[#t].children
			end

			addtext(txt)
		-- close
		elseif "/" == type then
			t = l[#l]
			l[#l] = nil
			addtext(txt)
		-- ENTITY
		elseif "!" == type then
			if E == name:byte(1) then
				txt:gsub(
					"([_%w]+)%s+(.)(.-)%2",
					function(name, _, entity)
						entities[#entities + 1] = {name = name, value = entity}
					end,
					1
				)
			end
		end
	end)

	return {children = t, entities = entities, tentities = tentities}
end

local function parseFile_xml(filename)
	local f, err = io.open(filename)

	if f then
		local content = f:read("*a")
		f:close()
		return parse_xml(content), nil
	end

	return f, err
end

-- Helper to escape strings for Lua code generation
local function escape_string(s)
	return s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\"", "\\\"")
end

-- Helper to serialize a Lua table as code
local function serialize_table(t, indent)
	indent = indent or ""
	local parts = {}
	table.insert(parts, "{\n")
	-- Collect and sort keys for deterministic output
	local keys = {}

	for k in pairs(t) do
		table.insert(keys, k)
	end

	table.sort(keys, function(a, b)
		-- Sort numbers first, then strings
		if type(a) == type(b) then
			return tostring(a) < tostring(b)
		else
			return type(a) < type(b)
		end
	end)

	for _, k in ipairs(keys) do
		local v = t[k]
		local key = type(k) == "string" and k or "[" .. k .. "]"

		if type(v) == "table" then
			table.insert(
				parts,
				indent .. "\t" .. key .. " = " .. serialize_table(v, indent .. "\t") .. ",\n"
			)
		elseif type(v) == "string" then
			table.insert(parts, indent .. "\t" .. key .. " = \"" .. escape_string(v) .. "\",\n")
		elseif type(v) == "boolean" then
			table.insert(parts, indent .. "\t" .. key .. " = " .. tostring(v) .. ",\n")
		else
			table.insert(parts, indent .. "\t" .. key .. " = " .. tostring(v) .. ",\n")
		end
	end

	table.insert(parts, indent .. "}")
	return table.concat(parts)
end

-- Helper to generate message signature from args
local function generate_signature(args)
	local sig = {}

	for _, arg in ipairs(args) do
		local char

		if arg.type == "int" then
			char = "i"
		elseif arg.type == "uint" then
			char = "u"
		elseif arg.type == "fixed" then
			char = "f"
		elseif arg.type == "string" then
			char = arg.allow_null and "?s" or "s"
		elseif arg.type == "object" then
			char = arg.allow_null and "?o" or "o"
		elseif arg.type == "new_id" then
			if arg.interface then
				-- Typed new_id - include 'n' in signature
				char = "n"
			else
				-- Generic new_id: string, uint, new_id
				char = "sun"
			end
		elseif arg.type == "array" then
			char = arg.allow_null and "?a" or "a"
		elseif arg.type == "fd" then
			char = "h"
		else
			char = "?"
		end

		if char then table.insert(sig, char) end
	end

	return table.concat(sig)
end

-- Generate list of interface names for types array (for objects/new_ids)
local function generate_types_list(args)
	local types = {}

	for _, arg in ipairs(args) do
		if arg.type == "object" then
			-- Add interface name for objects
			table.insert(types, arg.interface or "nil")
		elseif arg.type == "new_id" then
			if arg.interface then
				-- Typed new_id - add interface to types array
				table.insert(types, arg.interface)
			end
		-- Generic new_id doesn't add to types (it's in the signature as sun)
		end
	end

	return types
end

function scanner.generate(xml_path, output_file)
	local doc = parseFile_xml(xml_path)
	local protocol = doc.children[1] -- <protocol>
	local protocol_name = protocol.attrs.name
	local interfaces = {}

	for _, child in ipairs(protocol.children) do
		if child.tag == "interface" then
			local iface = {
				name = child.attrs.name,
				version = tonumber(child.attrs.version),
				requests = {},
				events = {},
				enums = {},
			}

			for _, item in ipairs(child.children) do
				if item.tag == "request" then
					local req = {
						name = item.attrs.name,
						args = {},
						type = item.attrs.type, -- destructor?
						since = tonumber(item.attrs.since) or 1,
					}

					for _, arg in ipairs(item.children) do
						if arg.tag == "arg" then
							table.insert(
								req.args,
								{
									name = arg.attrs.name,
									type = arg.attrs.type,
									interface = arg.attrs.interface,
									allow_null = arg.attrs["allow-null"] == "true",
								}
							)
						end
					end

					table.insert(iface.requests, req)
				elseif item.tag == "event" then
					local evt = {
						name = item.attrs.name,
						args = {},
						since = tonumber(item.attrs.since) or 1,
					}

					for _, arg in ipairs(item.children) do
						if arg.tag == "arg" then
							table.insert(
								evt.args,
								{
									name = arg.attrs.name,
									type = arg.attrs.type,
									interface = arg.attrs.interface,
								}
							)
						end
					end

					table.insert(iface.events, evt)
				elseif item.tag == "enum" then
					local enum = {
						name = item.attrs.name,
						entries = {},
						bitfield = item.attrs.bitfield == "true",
					}

					for _, entry in ipairs(item.children) do
						if entry.tag == "entry" then
							table.insert(
								enum.entries,
								{
									name = entry.attrs.name,
									value = entry.attrs.value,
									summary = entry.attrs.summary,
								}
							)
						end
					end

					table.insert(iface.enums, enum)
				end
			end

			table.insert(interfaces, iface)
		end
	end

	-- Start building the output Lua file
	local output = {}
	table.insert(output, "-- Generated from " .. protocol_name .. " protocol\n")
	table.insert(output, "local ffi = require('ffi')\n\n")
	-- Global listener registry
	table.insert(output, "-- Global table to keep listener callbacks alive (prevent GC)\n")
	table.insert(output, "local listeners_registry = {}\n\n")
	-- Generate C definitions
	table.insert(output, "ffi.cdef[[\n")
	table.insert(output, "// Protocol: " .. protocol_name .. "\n")

	for _, iface in ipairs(interfaces) do
		table.insert(output, "struct " .. iface.name .. " {};\n")
		table.insert(output, "extern const struct wl_interface " .. iface.name .. "_interface;\n")
	end

	-- Generate Enums
	for _, iface in ipairs(interfaces) do
		for _, enum in ipairs(iface.enums) do
			table.insert(output, "enum " .. iface.name .. "_" .. enum.name .. " {\n")

			for _, entry in ipairs(enum.entries) do
				local name = string.upper(iface.name .. "_" .. enum.name .. "_" .. entry.name)
				table.insert(output, "\t" .. name .. " = " .. entry.value .. ",\n")
			end

			table.insert(output, "};\n")
		end
	end

	table.insert(output, "]]\n\n")
	-- Generate the output_table
	table.insert(output, "local output_table = {}\n\n")

	-- Generate stub wl_interface structures for protocols not in wayland-client
	if protocol_name ~= "wayland" then
		table.insert(output, "-- Create complete wl_interface structures\n")
		table.insert(output, "local interfaces = {}\n")
		table.insert(output, "local interface_ptrs = {}\n")
		table.insert(output, "local interface_data = {} -- Keep all C data alive (prevent GC)\n")
		table.insert(output, "local deferred_type_assignments = {} -- For forward references\n\n")

		for iface_idx, iface in ipairs(interfaces) do
			table.insert(output, "do\n")
			table.insert(output, "\tlocal data = {}\n")

			-- Generate method messages
			if #iface.requests > 0 then
				table.insert(
					output,
					"\tlocal methods = ffi.new('struct wl_message[" .. #iface.requests .. "]')\n"
				)
				table.insert(output, "\tdata.methods = methods\n")

				for i, req in ipairs(iface.requests) do
					local sig = generate_signature(req.args)
					local types_list = generate_types_list(req.args)
					table.insert(output, "\tdo\n")
					table.insert(output, "\t\tlocal name_str = ffi.new('char[?]', #'" .. req.name .. "' + 1)\n")
					table.insert(output, "\t\tffi.copy(name_str, '" .. req.name .. "')\n")
					table.insert(output, "\t\tlocal sig_str = ffi.new('char[?]', #'" .. sig .. "' + 1)\n")
					table.insert(output, "\t\tffi.copy(sig_str, '" .. sig .. "')\n")

					-- Generate types array if needed
					if #types_list > 0 then
						table.insert(
							output,
							"\t\tlocal types = ffi.new('const struct wl_interface*[" .. #types_list .. "]')\n"
						)

						for ti, iface_name in ipairs(types_list) do
							if iface_name ~= "nil" then
								if protocol_name == "wayland" then
									table.insert(output, "\t\ttypes[" .. (ti - 1) .. "] = ffi.C." .. iface_name .. "_interface\n")
								else
									-- For xdg protocol, check if it's a wayland core interface or xdg interface
									if iface_name:match("^wl_") then
										table.insert(output, "\t\ttypes[" .. (ti - 1) .. "] = ffi.C." .. iface_name .. "_interface\n")
									else
										-- Defer assignment for forward references to xdg interfaces
										table.insert(output, "\t\ttable.insert(deferred_type_assignments, function()\n")
										table.insert(
											output,
											"\t\t\ttypes[" .. (
													ti - 1
												) .. "] = ffi.cast('const struct wl_interface*', interface_ptrs['" .. iface_name .. "'])\n"
										)
										table.insert(output, "\t\tend)\n")
									end
								end
							else
								table.insert(output, "\t\ttypes[" .. (ti - 1) .. "] = nil\n")
							end
						end

						table.insert(output, "\t\tdata['" .. req.name .. "_types'] = types\n")
						table.insert(output, "\t\tmethods[" .. (i - 1) .. "].types = types\n")
					else
						table.insert(output, "\t\tmethods[" .. (i - 1) .. "].types = nil\n")
					end

					table.insert(output, "\t\tmethods[" .. (i - 1) .. "].name = name_str\n")
					table.insert(output, "\t\tmethods[" .. (i - 1) .. "].signature = sig_str\n")
					table.insert(output, "\t\tdata['" .. req.name .. "_name'] = name_str\n")
					table.insert(output, "\t\tdata['" .. req.name .. "_sig'] = sig_str\n")
					table.insert(output, "\tend\n")
				end
			end

			-- Generate event messages
			if #iface.events > 0 then
				table.insert(
					output,
					"\tlocal events = ffi.new('struct wl_message[" .. #iface.events .. "]')\n"
				)
				table.insert(output, "\tdata.events = events\n")

				for i, evt in ipairs(iface.events) do
					local sig = generate_signature(evt.args)
					local types_list = generate_types_list(evt.args)
					table.insert(output, "\tdo\n")
					table.insert(output, "\t\tlocal name_str = ffi.new('char[?]', #'" .. evt.name .. "' + 1)\n")
					table.insert(output, "\t\tffi.copy(name_str, '" .. evt.name .. "')\n")
					table.insert(output, "\t\tlocal sig_str = ffi.new('char[?]', #'" .. sig .. "' + 1)\n")
					table.insert(output, "\t\tffi.copy(sig_str, '" .. sig .. "')\n")

					-- Generate types array if needed
					if #types_list > 0 then
						table.insert(
							output,
							"\t\tlocal types = ffi.new('const struct wl_interface*[" .. #types_list .. "]')\n"
						)

						for ti, iface_name in ipairs(types_list) do
							if iface_name ~= "nil" then
								if protocol_name == "wayland" then
									table.insert(output, "\t\ttypes[" .. (ti - 1) .. "] = ffi.C." .. iface_name .. "_interface\n")
								else
									-- For xdg protocol, check if it's a wayland core interface or xdg interface
									if iface_name:match("^wl_") then
										table.insert(output, "\t\ttypes[" .. (ti - 1) .. "] = ffi.C." .. iface_name .. "_interface\n")
									else
										-- Defer assignment for forward references to xdg interfaces
										table.insert(output, "\t\ttable.insert(deferred_type_assignments, function()\n")
										table.insert(
											output,
											"\t\t\ttypes[" .. (
													ti - 1
												) .. "] = ffi.cast('const struct wl_interface*', interface_ptrs['" .. iface_name .. "'])\n"
										)
										table.insert(output, "\t\tend)\n")
									end
								end
							else
								table.insert(output, "\t\ttypes[" .. (ti - 1) .. "] = nil\n")
							end
						end

						table.insert(output, "\t\tdata['" .. evt.name .. "_types'] = types\n")
						table.insert(output, "\t\tevents[" .. (i - 1) .. "].types = types\n")
					else
						table.insert(output, "\t\tevents[" .. (i - 1) .. "].types = nil\n")
					end

					table.insert(output, "\t\tevents[" .. (i - 1) .. "].name = name_str\n")
					table.insert(output, "\t\tevents[" .. (i - 1) .. "].signature = sig_str\n")
					table.insert(output, "\t\tdata['" .. evt.name .. "_name'] = name_str\n")
					table.insert(output, "\t\tdata['" .. evt.name .. "_sig'] = sig_str\n")
					table.insert(output, "\tend\n")
				end
			end

			-- Create interface structure
			table.insert(output, "\tlocal name_str = ffi.new('char[?]', #'" .. iface.name .. "' + 1)\n")
			table.insert(output, "\tffi.copy(name_str, '" .. iface.name .. "')\n")
			table.insert(output, "\tlocal iface_ptr = ffi.new('struct wl_interface[1]')\n")
			table.insert(output, "\tiface_ptr[0].name = name_str\n")
			table.insert(output, "\tiface_ptr[0].version = " .. iface.version .. "\n")
			table.insert(output, "\tiface_ptr[0].method_count = " .. #iface.requests .. "\n")

			if #iface.requests > 0 then
				table.insert(output, "\tiface_ptr[0].methods = methods\n")
			else
				table.insert(output, "\tiface_ptr[0].methods = nil\n")
			end

			table.insert(output, "\tiface_ptr[0].event_count = " .. #iface.events .. "\n")

			if #iface.events > 0 then
				table.insert(output, "\tiface_ptr[0].events = events\n")
			else
				table.insert(output, "\tiface_ptr[0].events = nil\n")
			end

			table.insert(output, "\tdata.name_str = name_str\n")
			table.insert(output, "\tdata.iface_ptr = iface_ptr\n")
			table.insert(output, "\tinterfaces['" .. iface.name .. "'] = iface_ptr[0]\n")
			table.insert(output, "\tinterface_ptrs['" .. iface.name .. "'] = iface_ptr\n")
			table.insert(output, "\tinterface_data['" .. iface.name .. "'] = data\n")
			table.insert(output, "end\n\n")
		end

		-- Execute deferred type assignments now that all interfaces are created
		table.insert(output, "-- Execute deferred type assignments for forward references\n")
		table.insert(output, "for _, fn in ipairs(deferred_type_assignments) do\n")
		table.insert(output, "\tfn()\n")
		table.insert(output, "end\n\n")
		table.insert(output, "-- Helper to get interface\n")
		table.insert(output, "function output_table.get_interface(name)\n")
		table.insert(output, "\treturn {\n")
		table.insert(output, "\t\tname = name,\n")
		table.insert(output, "\t\tptr = interface_ptrs[name]\n")
		table.insert(output, "\t}\n")
		table.insert(output, "end\n\n")
	end

	-- Generate Lua bindings for each interface
	for _, iface in ipairs(interfaces) do
		table.insert(output, "-- Interface: " .. iface.name .. "\n")
		table.insert(output, "do\n")
		table.insert(output, "\tlocal meta = {}\n")
		table.insert(output, "\tmeta.__index = meta\n\n")
		-- Store interface data for runtime use
		table.insert(output, "\tlocal iface = " .. serialize_table(iface, "\t") .. "\n\n")

		-- Generate request methods
		for opcode, req in ipairs(iface.requests) do
			local op = opcode - 1
			local sig = generate_signature(req.args)
			local array_size = #sig
			table.insert(output, "\t-- Request: " .. req.name .. "\n")
			table.insert(output, "\tfunction meta:" .. req.name .. "(...)\n")
			table.insert(output, "\t\tlocal args = {...}\n")

			if array_size > 0 then
				table.insert(
					output,
					"\t\tlocal args_array = ffi.new('union wl_argument[" .. array_size .. "]')\n"
				)
			else
				table.insert(
					output,
					"\t\tlocal args_array = ffi.new('union wl_argument[1]') -- Dummy for empty args\n"
				)
			end

			table.insert(output, "\t\tlocal arg_idx = 1\n")
			table.insert(output, "\t\tlocal array_idx = 0\n")
			table.insert(output, "\t\tlocal has_new_id = false\n")
			table.insert(output, "\t\tlocal new_id_interface = nil\n")
			table.insert(output, "\t\tlocal generic_new_id = false\n")
			table.insert(output, "\t\tlocal version_for_generic = nil\n\n")
			-- Check for new_id
			table.insert(output, "\t\t-- Check if this request has a new_id (constructor)\n")
			table.insert(output, "\t\tfor _, arg in ipairs(iface.requests[" .. opcode .. "].args) do\n")
			table.insert(output, "\t\t\tif arg.type == 'new_id' then\n")
			table.insert(output, "\t\t\t\thas_new_id = true\n")
			table.insert(output, "\t\t\t\tnew_id_interface = arg.interface\n")
			table.insert(output, "\t\t\t\tif not new_id_interface then generic_new_id = true end\n")
			table.insert(output, "\t\t\t\tbreak\n")
			table.insert(output, "\t\t\tend\n")
			table.insert(output, "\t\tend\n\n")
			-- Process arguments
			table.insert(output, "\t\t-- Process arguments\n")
			table.insert(output, "\t\tfor i, arg in ipairs(iface.requests[" .. opcode .. "].args) do\n")
			table.insert(output, "\t\t\tif arg.type == 'new_id' then\n")
			table.insert(output, "\t\t\t\tif not arg.interface then\n")
			table.insert(output, "\t\t\t\t\tlocal target_iface = args[arg_idx]\n")
			table.insert(output, "\t\t\t\t\tlocal target_ver = args[arg_idx + 1]\n")
			table.insert(output, "\t\t\t\t\targ_idx = arg_idx + 2\n")
			table.insert(output, "\t\t\t\t\tif target_iface then\n")
			table.insert(output, "\t\t\t\t\t\targs_array[array_idx].s = target_iface.name\n")
			table.insert(output, "\t\t\t\t\t\targs_array[array_idx + 1].u = tonumber(target_ver)\n")
			table.insert(output, "\t\t\t\t\t\targs_array[array_idx + 2].n = 0\n")
			table.insert(output, "\t\t\t\t\t\t-- Extract pointer if it's a table with .ptr field\n")
			table.insert(output, "\t\t\t\t\t\tnew_id_interface = target_iface.ptr or target_iface\n")
			table.insert(output, "\t\t\t\t\t\tversion_for_generic = tonumber(target_ver)\n")
			table.insert(output, "\t\t\t\t\tend\n")
			table.insert(output, "\t\t\t\t\tarray_idx = array_idx + 3\n")
			table.insert(output, "\t\t\t\telse\n")
			table.insert(output, "\t\t\t\t\targs_array[array_idx].n = 0\n")
			table.insert(output, "\t\t\t\t\tarray_idx = array_idx + 1\n")
			table.insert(output, "\t\t\t\tend\n")
			table.insert(output, "\t\t\telseif arg.type == 'fixed' then\n")
			table.insert(output, "\t\t\t\tlocal val = args[arg_idx] or 0\n")
			table.insert(output, "\t\t\t\targ_idx = arg_idx + 1\n")
			table.insert(
				output,
				"\t\t\t\targs_array[array_idx].f = ffi.cast('wl_fixed_t', val * 256.0)\n"
			)
			table.insert(output, "\t\t\t\tarray_idx = array_idx + 1\n")
			table.insert(output, "\t\t\telseif arg.type == 'object' then\n")
			table.insert(output, "\t\t\t\tlocal val = args[arg_idx]\n")
			table.insert(output, "\t\t\t\targ_idx = arg_idx + 1\n")
			table.insert(
				output,
				"\t\t\t\targs_array[array_idx].o = val and ffi.cast('struct wl_object*', val) or nil\n"
			)
			table.insert(output, "\t\t\t\tarray_idx = array_idx + 1\n")
			table.insert(output, "\t\t\telseif arg.type == 'array' then\n")
			table.insert(output, "\t\t\t\tlocal val = args[arg_idx]\n")
			table.insert(output, "\t\t\t\targ_idx = arg_idx + 1\n")
			table.insert(
				output,
				"\t\t\t\targs_array[array_idx].a = ffi.cast('struct wl_array*', val)\n"
			)
			table.insert(output, "\t\t\t\tarray_idx = array_idx + 1\n")
			table.insert(output, "\t\t\telseif arg.type == 'string' then\n")
			table.insert(output, "\t\t\t\tlocal val = args[arg_idx]\n")
			table.insert(output, "\t\t\t\targ_idx = arg_idx + 1\n")
			table.insert(output, "\t\t\t\targs_array[array_idx].s = val\n")
			table.insert(output, "\t\t\t\tarray_idx = array_idx + 1\n")
			table.insert(output, "\t\t\telseif arg.type == 'fd' then\n")
			table.insert(output, "\t\t\t\tlocal val = args[arg_idx]\n")
			table.insert(output, "\t\t\t\targ_idx = arg_idx + 1\n")
			table.insert(output, "\t\t\t\targs_array[array_idx].h = tonumber(val)\n")
			table.insert(output, "\t\t\t\tarray_idx = array_idx + 1\n")
			table.insert(output, "\t\t\telse\n")
			table.insert(output, "\t\t\t\tlocal val = args[arg_idx]\n")
			table.insert(output, "\t\t\t\targ_idx = arg_idx + 1\n")
			table.insert(output, "\t\t\t\tif arg.type == 'uint' then\n")
			table.insert(output, "\t\t\t\t\targs_array[array_idx].u = tonumber(val)\n")
			table.insert(output, "\t\t\t\telse\n")
			table.insert(output, "\t\t\t\t\targs_array[array_idx].i = tonumber(val)\n")
			table.insert(output, "\t\t\t\tend\n")
			table.insert(output, "\t\t\t\tarray_idx = array_idx + 1\n")
			table.insert(output, "\t\t\tend\n")
			table.insert(output, "\t\tend\n\n")
			-- Call marshal function
			table.insert(output, "\t\t-- Call appropriate marshal function\n")
			table.insert(output, "\t\tif has_new_id then\n")
			table.insert(output, "\t\t\tif generic_new_id then\n")
			table.insert(
				output,
				"\t\t\t\tlocal new_proxy = ffi.C.wl_proxy_marshal_array_constructor_versioned(\n"
			)
			table.insert(output, "\t\t\t\t\tffi.cast('struct wl_proxy*', self),\n")
			table.insert(output, "\t\t\t\t\t" .. op .. ",\n")
			table.insert(output, "\t\t\t\t\targs_array,\n")
			table.insert(output, "\t\t\t\t\tnew_id_interface,\n")
			table.insert(output, "\t\t\t\t\tversion_for_generic\n")
			table.insert(output, "\t\t\t\t)\n")
			table.insert(output, "\t\t\t\treturn ffi.cast('void*', new_proxy)\n")
			table.insert(output, "\t\t\telseif new_id_interface then\n")

			if protocol_name == "wayland" then
				table.insert(
					output,
					"\t\t\t\tlocal target_interface = ffi.C[new_id_interface .. '_interface']\n"
				)
			else
				table.insert(
					output,
					"\t\t\t\tlocal target_interface = ffi.cast('struct wl_interface*', interface_ptrs[new_id_interface])\n"
				)
			end

			table.insert(output, "\t\t\t\tlocal new_proxy = ffi.C.wl_proxy_marshal_array_constructor(\n")
			table.insert(output, "\t\t\t\t\tffi.cast('struct wl_proxy*', self),\n")
			table.insert(output, "\t\t\t\t\t" .. op .. ",\n")
			table.insert(output, "\t\t\t\t\targs_array,\n")
			table.insert(output, "\t\t\t\t\ttarget_interface\n")
			table.insert(output, "\t\t\t\t)\n")
			table.insert(
				output,
				"\t\t\t\treturn ffi.cast('struct ' .. new_id_interface .. '*', new_proxy)\n"
			)
			table.insert(output, "\t\t\tend\n")
			table.insert(output, "\t\telse\n")
			table.insert(
				output,
				"\t\t\tffi.C.wl_proxy_marshal_array(ffi.cast('struct wl_proxy*', self), " .. op .. ", args_array)\n"
			)
			table.insert(output, "\t\tend\n")
			table.insert(output, "\tend\n\n")
		end

		-- Generate add_listener method
		table.insert(output, "\t-- Helper to create listener\n")
		table.insert(output, "\tfunction meta:add_listener(callbacks, data)\n")
		table.insert(output, "\t\tlocal count = #iface.events\n")
		table.insert(output, "\t\tlocal listener = ffi.new('void*[' .. count .. ']')\n")
		table.insert(
			output,
			"\t\tlocal ptr_key = tonumber(ffi.cast('intptr_t', ffi.cast('struct wl_proxy*', self)))\n"
		)
		table.insert(output, "\t\tlisteners_registry[ptr_key] = listeners_registry[ptr_key] or {}\n")
		table.insert(output, "\t\ttable.insert(listeners_registry[ptr_key], listener)\n")
		table.insert(output, "\t\ttable.insert(listeners_registry[ptr_key], callbacks)\n\n")
		table.insert(output, "\t\tfor i, evt in ipairs(iface.events) do\n")
		table.insert(output, "\t\t\tlocal cb = callbacks[evt.name]\n")
		table.insert(output, "\t\t\tif cb then\n")
		table.insert(output, "\t\t\t\tlocal sig_args = {'void*', 'struct wl_proxy*'}\n")
		table.insert(output, "\t\t\t\tfor _, arg in ipairs(evt.args) do\n")
		table.insert(output, "\t\t\t\t\tif arg.type == 'int' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'int32_t')\n")
		table.insert(output, "\t\t\t\t\telseif arg.type == 'uint' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'uint32_t')\n")
		table.insert(output, "\t\t\t\t\telseif arg.type == 'fixed' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'wl_fixed_t')\n")
		table.insert(output, "\t\t\t\t\telseif arg.type == 'string' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'const char*')\n")
		table.insert(output, "\t\t\t\t\telseif arg.type == 'object' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'struct wl_proxy*')\n")
		table.insert(output, "\t\t\t\t\telseif arg.type == 'new_id' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'struct wl_proxy*')\n")
		table.insert(output, "\t\t\t\t\telseif arg.type == 'array' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'struct wl_array*')\n")
		table.insert(output, "\t\t\t\t\telseif arg.type == 'fd' then\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(sig_args, 'int32_t')\n")
		table.insert(output, "\t\t\t\t\tend\n")
		table.insert(output, "\t\t\t\tend\n\n")
		table.insert(
			output,
			"\t\t\t\tlocal sig = 'void (*)(' .. table.concat(sig_args, ', ') .. ')'\n"
		)
		table.insert(output, "\t\t\t\tlocal cb_func = ffi.cast(sig, function(data, proxy, ...)\n")
		table.insert(output, "\t\t\t\t\tlocal args = {...}\n")
		table.insert(output, "\t\t\t\t\tlocal lua_args = {}\n")
		table.insert(output, "\t\t\t\t\tlocal arg_idx = 1\n\n")
		-- Cast proxy to correct interface
		table.insert(output, "\t\t\t\t\tproxy = ffi.cast('struct " .. iface.name .. "*', proxy)\n\n")
		table.insert(output, "\t\t\t\t\tfor _, arg in ipairs(evt.args) do\n")
		table.insert(output, "\t\t\t\t\t\tlocal val = args[arg_idx]\n")
		table.insert(output, "\t\t\t\t\t\targ_idx = arg_idx + 1\n\n")
		table.insert(output, "\t\t\t\t\t\tif arg.type == 'fixed' then\n")
		table.insert(output, "\t\t\t\t\t\t\tval = tonumber(val) / 256.0\n")
		table.insert(output, "\t\t\t\t\t\telseif arg.type == 'string' then\n")
		table.insert(output, "\t\t\t\t\t\t\tval = ffi.string(val)\n")
		table.insert(output, "\t\t\t\t\t\telseif arg.type == 'object' or arg.type == 'new_id' then\n")
		table.insert(output, "\t\t\t\t\t\t\tif arg.interface then\n")
		table.insert(
			output,
			"\t\t\t\t\t\t\t\tval = ffi.cast('struct ' .. arg.interface .. '*', val)\n"
		)
		table.insert(output, "\t\t\t\t\t\t\tend\n")
		table.insert(output, "\t\t\t\t\t\tend\n\n")
		table.insert(output, "\t\t\t\t\t\ttable.insert(lua_args, val)\n")
		table.insert(output, "\t\t\t\t\tend\n\n")
		table.insert(output, "\t\t\t\t\tcb(data, proxy, unpack(lua_args))\n")
		table.insert(output, "\t\t\t\tend)\n")
		table.insert(output, "\t\t\t\tlistener[i - 1] = cb_func\n")
		table.insert(output, "\t\t\t\ttable.insert(listeners_registry[ptr_key], cb_func)\n")
		table.insert(output, "\t\t\tend\n")
		table.insert(output, "\t\tend\n\n")
		table.insert(output, "\t\tffi.C.wl_proxy_add_listener(\n")
		table.insert(output, "\t\t\tffi.cast('struct wl_proxy*', self),\n")
		table.insert(output, "\t\t\tffi.cast('void(**)(void)', listener),\n")
		table.insert(output, "\t\t\tffi.cast('void*', data)\n")
		table.insert(output, "\t\t)\n")
		table.insert(output, "\tend\n\n")
		-- Register interface
		table.insert(output, "\toutput_table['" .. iface.name .. "'] = meta\n")
		table.insert(output, "\tffi.metatype('struct " .. iface.name .. "', meta)\n")
		table.insert(output, "end\n\n")
	end

	table.insert(output, "output_table._interface_data = interface_data\n")
	table.insert(output, "return output_table\n")
	return table.concat(output)
end

return scanner
