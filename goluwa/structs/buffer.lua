local META = {}
META.__index = META
local ffi = require("ffi")
local buffer_template = import("goluwa/buffer_template.lua")
local memory = import("goluwa/bindings/memory.lua")
local ffi_string = ffi.string
META.CType = ffi.typeof([[
	struct {
		uint8_t * Buffer;
		uint32_t ByteSize;
		uint32_t Position;
		bool Writable;
		bool PushPopStack[32];
		uint32_t PushPopStackPos;
		uint32_t buf_byte;
		uint8_t buf_nbit;
		uint32_t buf_start_pos;
		bool OwnsMemory;
	}
]])
local refs = setmetatable({}, {__mode = "k"})

function META.New(data, len)
	if data == nil then
		-- Allocate new buffer with malloc
		local size = len or 1024
		local buffer = memory.malloc(size)

		if buffer == nil then
			error("Failed to allocate buffer of size " .. size)
		end

		local self = META.CType{
			Buffer = ffi.cast("uint8_t*", buffer),
			ByteSize = size,
			OwnsMemory = true,
		}
		refs[self] = true
		return self
	else
		-- Use existing data
		local self = META.CType()
		self.Buffer = ffi.cast("uint8_t *", data)
		self.ByteSize = len or #data
		self.OwnsMemory = false
		refs[self] = {data}
		return self
	end
end

function META:__gc()
	if self.OwnsMemory and self.Buffer ~= nil then
		memory.free(self.Buffer)
		self.Buffer = nil
	end
end

function META:MakeWritable()
	self.Writable = true
	return self
end

do
	function META:GetAllocatedSize()
		return self.ByteSize
	end

	function META:GetString()
		return ffi_string(self.Buffer, self.ByteSize)
	end

	function META:GetStringSlice(start--[[#: number]], stop--[[#: number]])
		if start > self.ByteSize then return "" end

		return ffi_string(self.Buffer + start, (stop - start) + 1)
	end

	function META:GetSize()
		--if self.Writable then return self.Position end
		return self.ByteSize
	end

	function META:SetPosition(pos)
		self.Position = pos

		if self.Writable then
			while self:TheEnd() do
				local new_size = math.max(self.ByteSize * 2, pos)

				if self.OwnsMemory then
					-- Use realloc for buffers we own
					local new_buffer = memory.realloc(self.Buffer, new_size)

					if new_buffer == nil then
						error("Failed to reallocate buffer to size " .. new_size)
					end

					self.Buffer = ffi.cast("uint8_t*", new_buffer)
				else
					-- Allocate new buffer and copy data
					local new_buffer = memory.malloc(new_size)

					if new_buffer == nil then
						error("Failed to allocate buffer of size " .. new_size)
					end

					memory.memcpy(new_buffer, self.Buffer, self.ByteSize)
					self.Buffer = ffi.cast("uint8_t*", new_buffer)
					self.OwnsMemory = true
				end

				self.ByteSize = new_size
				-- Update refs to prevent GC
				refs[self] = true
			end
		end
	end

	function META:GetPosition()
		return self.Position
	end
end

do
	function META:WriteByte(b)
		local pos = self:GetPosition()

		-- Ensure buffer has space before writing
		if self.Writable and pos >= self.ByteSize then
			-- Expand buffer before writing
			local new_size = math.max(self.ByteSize * 2, pos + 1)

			if self.OwnsMemory then
				-- Use realloc for buffers we own
				local new_buffer = memory.realloc(self.Buffer, new_size)

				if new_buffer == nil then
					error("Failed to reallocate buffer to size " .. new_size)
				end

				self.Buffer = ffi.cast("uint8_t*", new_buffer)
			else
				-- Allocate new buffer and copy data
				local new_buffer = memory.malloc(new_size)

				if new_buffer == nil then
					error("Failed to allocate buffer of size " .. new_size)
				end

				memory.memcpy(new_buffer, self.Buffer, self.ByteSize)
				self.Buffer = ffi.cast("uint8_t*", new_buffer)
				self.OwnsMemory = true
			end

			self.ByteSize = new_size
			-- Update refs to prevent GC
			refs[self] = true
		end

		self.Buffer[pos] = b
		self:Advance(1)
		return self
	end

	function META:ReadByte()
		local pos = self:GetPosition()
		local byte = self.Buffer[pos]
		self:Advance(1)
		return byte
	end

	function META:GetByte(pos--[[#: number]])
		return self.Buffer[pos]
	end

	function META:GetBuffer()
		return self.Buffer
	end
end

buffer_template.AddBasicFunctions(META)
buffer_template.AddBasicDataTypes(META)
buffer_template.AddStringFunctions(META)
buffer_template.AddPushPopFunctions(META)
buffer_template.AddBitFunctions(META)
buffer_template.AddStructFunctions(META)
ffi.metatype(META.CType, META)
return META
