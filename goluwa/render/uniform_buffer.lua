local ffi = require("ffi")
local render = require("render.render")
local prototype = require("prototype")
local UniformBuffer = prototype.CreateTemplate("render", "uniform_buffer")

function UniformBuffer.New(decl)
	-- Check if this declaration contains $ placeholders (indicating nested structs)
	local has_nested = decl:match("%$")

	if not has_nested then
		-- No nested structs, just create the struct directly
		local struct = ffi.typeof(decl)
		local self = UniformBuffer:CreateObject()
		self.data = struct()
		self.struct = struct
		self.buffer = render.CreateBuffer(
			{
				data = self.data,
				byte_size = ffi.sizeof(struct),
				buffer_usage = {"uniform_buffer"},
				memory_property = {"host_visible", "host_coherent"},
			}
		)
		self.size = ffi.sizeof(self.struct)
		return self
	end

	-- Has nested structs - split them out
	local nested_struct_defs = {}
	local main_lines = {}
	local current_struct_lines = {}
	local brace_depth = 0
	local structs = {}

	-- First pass: split into individual struct definitions
	for line in decl:gmatch("[^\n]+") do
		table.insert(current_struct_lines, line)

		-- Count braces to know when a struct ends
		for c in line:gmatch(".") do
			if c == "{" then
				brace_depth = brace_depth + 1
			elseif c == "}" then
				brace_depth = brace_depth - 1

				if brace_depth == 0 then
					-- Complete struct found
					local struct_def = table.concat(current_struct_lines, "\n")
					table.insert(structs, struct_def)
					current_struct_lines = {}
				end
			end
		end
	end

	-- Last struct is the main struct (has $ placeholders)
	-- All others are nested struct definitions
	local main_struct = structs[#structs]

	for i = 1, #structs - 1 do
		table.insert(nested_struct_defs, structs[i])
	end

	-- Create ctypes for all nested structs first
	local nested_ctypes = {}

	for _, nested_def in ipairs(nested_struct_defs) do
		local ctype = ffi.typeof(nested_def)
		table.insert(nested_ctypes, ctype)
	end

	-- Now create the main struct, passing nested ctypes as parameters
	local struct = ffi.typeof(main_struct, unpack(nested_ctypes))
	local self = UniformBuffer:CreateObject()
	self.data = struct()
	self.struct = struct
	self.buffer = render.CreateBuffer(
		{
			data = self.data,
			byte_size = ffi.sizeof(struct),
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
		}
	)
	self.size = ffi.sizeof(self.struct)
	return self
end

function UniformBuffer:GetData()
	return self.data
end

function UniformBuffer:Upload()
	self.buffer:CopyData(self.data, self.size)
end

return UniformBuffer:Register()
