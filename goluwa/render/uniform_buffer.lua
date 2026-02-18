local ffi = require("ffi")
local render = require("render.render")
local prototype = require("prototype")
local UniformBuffer = prototype.CreateTemplate("render_uniform_buffer")

function UniformBuffer.New(decl)
	-- Check if this declaration contains $ placeholders (indicating nested structs)
	local has_nested = decl:match("%$")
	local struct
	local nested_ctypes = {}

	if has_nested then
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
		for _, nested_def in ipairs(nested_struct_defs) do
			local ctype = ffi.typeof(nested_def)
			table.insert(nested_ctypes, ctype)
		end

		struct = ffi.typeof(main_struct, unpack(nested_ctypes))
	else
		-- No nested structs, just create the struct directly
		struct = ffi.typeof(decl)
	end

	assert(ffi.sizeof(struct) > 0, "UniformBuffer struct size must be greater than 0")
	local self = UniformBuffer:CreateObject()
	self.size = ffi.sizeof(struct)
	-- Align to 256 for maximum compatibility across GPUs (standard for dynamic offsets)
	self.aligned_size = math.ceil(self.size / 256) * 256
	-- Allocate enough space for 1024 unique uploads per frame (assuming 3 frames in flight)
	self.max_uploads = 1024
	self.frame_count = 3
	self.ring_size = self.aligned_size * self.max_uploads * self.frame_count
	self.data = struct()
	self.struct = struct
	self.buffer = render.CreateBuffer(
		{
			byte_size = self.ring_size,
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
		}
	)
	self.current_offset = 0
	self.current_slot = 0
	return self
end

function UniformBuffer:GetData()
	return self.data
end

function UniformBuffer:Upload(frame_index)
	frame_index = (frame_index or 0) % self.frame_count
	self.current_slot = (self.current_slot + 1) % (self.max_uploads)
	local offset = (frame_index * self.max_uploads + self.current_slot) * self.aligned_size
	self.buffer:CopyData(self.data, self.size, offset)
	return offset
end

return UniformBuffer:Register()
