local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local render_stats = import("goluwa/render/stats.lua")
local UniformBuffer = objects.CreateTemplate("render_uniform_buffer")
-- every live ring, for the stats overlay
local instances = setmetatable({}, {__mode = "k"})

local function create(struct, name)
	assert(ffi.sizeof(struct) > 0, "UniformBuffer struct size must be greater than 0")
	local self = UniformBuffer:CreateObject()
	self.name = name
	self.size = ffi.sizeof(struct)
	-- Align to 256 for maximum compatibility across GPUs (standard for dynamic offsets)
	self.aligned_size = math.ceil(self.size / 256) * 256
	-- slots per frame, shared by persistent and transient uploads. the heaviest scenes measured
	-- need about 220 (translucent draws and per material persistent slots), and the ring does
	-- not grow, so running out is an error rather than overwriting earlier draws in the frame
	self.max_uploads = 1024
	self.frame_count = 3
	self.ring_size = self.aligned_size * self.max_uploads * self.frame_count
	self.data = struct()
	self.struct = struct
	self.buffer = render.CreateBuffer{
		byte_size = self.ring_size,
		buffer_usage = {"uniform_buffer"},
		memory_property = {"host_visible", "host_coherent"},
	}
	self.current_offset = 0
	self.current_slot = 0
	self.persistent_slot_count = 0
	-- the most transient uploads made in one frame, what the ring actually needs per frame
	self.upload_frame = -1
	self.frame_uploads = 0
	self.peak_frame_uploads = 0
	instances[self] = true
	return self
end

-- name identifies the ring in the stats overlay
function UniformBuffer.New(decl, name)
	if type(decl) ~= "string" then return create(decl, name) end

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

	return create(struct, name)
end

function UniformBuffer:OnRemove()
	if self.buffer and self.buffer.Remove then self.buffer:Remove() end
end

function UniformBuffer:GetData()
	return self.data
end

function UniformBuffer:GetOffset(frame_index, slot)
	frame_index = (frame_index or 0) % self.frame_count
	return (frame_index * self.max_uploads + slot) * self.aligned_size
end

function UniformBuffer:UploadToSlot(frame_index, slot)
	local offset = self:GetOffset(frame_index, slot)
	self.buffer:CopyData(self.data, self.size, offset)
	return offset
end

function UniformBuffer:AllocatePersistentSlot()
	if self.persistent_slot_count >= self.max_uploads then
		error(
			string.format(
				"uniform buffer %s ran out of persistent slots (%d)",
				self.name,
				self.max_uploads
			)
		)
	end

	local slot = self.persistent_slot_count
	self.persistent_slot_count = self.persistent_slot_count + 1
	return slot
end

function UniformBuffer:UploadPersistent(slot)
	for frame_index = 0, self.frame_count - 1 do
		self:UploadToSlot(frame_index, slot)
	end

	return self:GetOffset(0, slot)
end

function UniformBuffer:Upload(frame_index)
	local transient_capacity = self.max_uploads - self.persistent_slot_count

	if transient_capacity <= 0 then
		error(
			string.format(
				"uniform buffer %s has no transient slots left, %d are persistent",
				self.name,
				self.persistent_slot_count
			)
		)
	end

	local frame = system.GetFrameNumber()

	if self.upload_frame ~= frame then
		self.upload_frame = frame
		self.frame_uploads = 0
	end

	self.frame_uploads = self.frame_uploads + 1

	if self.frame_uploads > transient_capacity then
		error(
			string.format(
				"uniform buffer %s overflowed: more than %d uploads this frame (%d slots, %d persistent)",
				self.name,
				transient_capacity,
				self.max_uploads,
				self.persistent_slot_count
			)
		)
	end

	if self.frame_uploads > self.peak_frame_uploads then
		self.peak_frame_uploads = self.frame_uploads
	end

	self.current_slot = (self.current_slot + 1) % transient_capacity
	return self:UploadToSlot(frame_index, self.persistent_slot_count + self.current_slot)
end

do
	render_stats.RegisterGroup{id = "uniform_buffers", label = "UNIFORM RINGS"}

	local function get_busiest(key)
		local busiest

		for ubo in pairs(instances) do
			if ubo:IsValid() and (not busiest or ubo[key] > busiest[key]) then
				busiest = ubo
			end
		end

		return busiest
	end

	render_stats.RegisterField{
		id = "uniform_ring_memory",
		label = "MEMORY",
		group = "uniform_buffers",
		getter = function()
			local count = 0
			local bytes = 0

			for ubo in pairs(instances) do
				if ubo:IsValid() then
					count = count + 1
					bytes = bytes + ubo.ring_size
				end
			end

			return count .. " RINGS " .. render_stats.FormatBytes(bytes)
		end,
	}
	-- all time peaks rather than per second, since the capacity has to cover the worst frame
	render_stats.RegisterField{
		id = "uniform_ring_peak_uploads",
		label = "PEAK UPLOADS/FRAME",
		glyphs = "._/",
		group = "uniform_buffers",
		getter = function()
			local ubo = get_busiest("peak_frame_uploads")
			return ubo and ubo.peak_frame_uploads .. " " .. ubo.name or "-"
		end,
	}
	render_stats.RegisterField{
		id = "uniform_ring_persistent",
		label = "PERSISTENT SLOTS",
		glyphs = "._/",
		group = "uniform_buffers",
		getter = function()
			local ubo = get_busiest("persistent_slot_count")
			return ubo and ubo.persistent_slot_count .. " " .. ubo.name or "-"
		end,
	}
end

return UniformBuffer:Register()
