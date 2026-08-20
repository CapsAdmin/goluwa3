local buffer_template = library()

function buffer_template.AddBasicFunctions(META)
	function META:Advance(i)
		i = i or 1
		local pos = self:GetPosition() + i
		self:SetPosition(pos)
		return pos
	end

	function META:RemainingSize()
		return self:GetSize() - self:GetPosition()
	end

	function META:TheEnd()
		return self:GetPosition() >= self:GetSize()
	end

	function META:WriteBytes(str, len)
		for i = 1, len or #str do
			self:WriteByte(str:byte(i))
		end

		return self
	end

	function META:PeakByte()
		return self:ReadByte(), self:Advance(-1)
	end

	function META:PeakBytes(len)
		return self:ReadBytes(len), self:Advance(-len)
	end

	function META:GetDebugString()
		local pos = self:GetPosition()
		self:SetPosition(1)
		local str = self:GetString():hex_readable()
		self:SetPosition(pos)
		return str
	end

	META.__len = META.GetSize
end

function buffer_template.AddBitFunctions(META)
	local math_floor = math.floor
	local math_min = math.min
	local math_max = math.max
	local bit_band = bit.band
	local bit_rshift = bit.rshift

	local function get_bit_pos(self)
		local bit_pos = self.Position * 8 - self.buf_nbit

		if bit_pos < 0 then return 0 end

		return bit_pos
	end

	local function set_bit_pos(self, bit_pos)
		if bit_pos <= 0 then
			self.Position = 0
			self.buf_nbit = 0
			self.buf_byte = 0
			return
		end

		local byte_pos = math_floor(bit_pos / 8)
		local bit_offset = bit_pos % 8

		if bit_offset == 0 then
			self.Position = byte_pos
			self.buf_nbit = 0
		else
			self.Position = byte_pos + 1
			self.buf_nbit = 8 - bit_offset
		end

		self.buf_byte = 0
	end

	local function read_bits_at(self, bit_pos, nbits)
		local buffer = self.Buffer
		local out = 0
		local out_shift = 0
		local remaining = nbits
		local current_bit_pos = bit_pos

		while remaining > 0 do
			local byte_pos = math_floor(current_bit_pos / 8)
			local bit_offset = current_bit_pos % 8
			local chunk = math_min(remaining, 8 - bit_offset)
			local byte = buffer[byte_pos]
			local mask = bit_rshift(0xff, 8 - chunk)
			local chunk_bits = bit_band(bit_rshift(byte, bit_offset), mask)
			out = out + chunk_bits * (2 ^ out_shift)
			current_bit_pos = current_bit_pos + chunk
			out_shift = out_shift + chunk
			remaining = remaining - chunk
		end

		return out
	end

	function META:RestartReadBits()
		self.buf_start_pos = self.buf_start_pos or 0
		self.buf_byte = 0
		self.buf_nbit = 0

		-- Reset to the position where bit reading started
		if self.buf_start_pos > 0 or self.Position > 0 then
			self:SetPosition(self.buf_start_pos)
		end
	end

	function META:BitsLeftInByte()
		return self.buf_nbit
	end

	function META:BitPos()
		return get_bit_pos(self)
	end

	function META:RemainingBits()
		return math_max(0, self.ByteSize * 8 - get_bit_pos(self))
	end

	function META:ReadBits(nbits)
		if nbits == 0 then return 0 end

		local bit_pos = get_bit_pos(self)
		local total_bits = self.ByteSize * 8

		if total_bits - bit_pos < nbits then return nil end

		if self.buf_nbit == 0 then self.buf_start_pos = self.Position end

		local out = read_bits_at(self, bit_pos, nbits)
		set_bit_pos(self, bit_pos + nbits)
		return out
	end

	function META:PeekBits(nbits)
		if nbits == 0 then return 0 end

		local bit_pos = get_bit_pos(self)

		if self.ByteSize * 8 - bit_pos < nbits then return nil end

		return read_bits_at(self, bit_pos, nbits)
	end

	function META:SkipBits(nbits)
		if nbits == 0 then return end

		local bit_pos = get_bit_pos(self)

		if self.ByteSize * 8 - bit_pos < nbits then return nil end

		if self.buf_nbit == 0 then self.buf_start_pos = self.Position end

		set_bit_pos(self, bit_pos + nbits)
		return true
	end

	function META:Read(nbits)
		if nbits == 0 then return 0 end

		local bit_pos = get_bit_pos(self)
		local remaining = self.ByteSize * 8 - bit_pos

		if remaining <= 0 then return 0 end

		nbits = math_min(nbits, remaining)

		if self.buf_nbit == 0 then self.buf_start_pos = self.Position end

		local out = read_bits_at(self, bit_pos, nbits)
		set_bit_pos(self, bit_pos + nbits)
		return out or 0
	end

	function META:Peek(nbits)
		if nbits == 0 then return 0 end

		local bit_pos = get_bit_pos(self)
		local remaining = self.ByteSize * 8 - bit_pos

		if remaining <= 0 then return 0 end

		return read_bits_at(self, bit_pos, math_min(nbits, remaining)) or 0
	end
end

function buffer_template.AddBasicDataTypes(META)
	local ffi = require("ffi")
	local type_info = {
		I64 = "int64_t",
		U64 = "uint64_t",
		I32 = "int32_t",
		U32 = "uint32_t",
		I16 = "int16_t",
		U16 = "uint16_t",
		Double = "double",
		Float = "float",
	}
	local ffi_cast = ffi.cast
	local ffi_string = ffi.string

	for name, type in pairs(type_info) do
		type = ffi.typeof(type)
		local size = ffi.sizeof(type)
		local ctype = ffi.typeof("$*", type)
		META["Read" .. name] = function(self)
			return ffi_cast(ctype, self:ReadBytes(size))[0]
		end
		local ctype = ffi.typeof("$[1]", type)
		local hmm = ffi.new(ctype, 0)
		META["Write" .. name] = function(self, num)
			hmm[0] = num
			self:WriteBytes(ffi_string(hmm, size))
			return self
		end
	end

	META.ReadU8 = META.ReadByte
	META.WriteU8 = META.WriteByte
	META.ReadI8 = META.ReadByte
	META.WriteI8 = META.WriteByte

	-- Add explicit endianness variants for multi-byte types
	-- Note: We provide both LE and BE methods regardless of native endianness
	for name, type in pairs(type_info) do
		type = ffi.typeof(type)
		local size = ffi.sizeof(type)

		if size > 1 then -- Only for multi-byte types
			local ctype_read = ffi.typeof("$*", type)
			local ctype_write = ffi.typeof("$[1]", type)

			-- Little-endian: bytes in LSB-first order
			do
				local temp = ffi.new(ctype_write, 0)
				META["Write" .. name .. "LE"] = function(self, num)
					temp[0] = num
					local bytes = ffi_string(temp, size)

					-- Write bytes in little-endian order (LSB first)
					for i = 1, size do
						self:WriteByte(bytes:byte(i))
					end

					return self
				end
				META["Read" .. name .. "LE"] = function(self)
					local bytes = {}

					for i = 1, size do
						bytes[i] = string.char(self:ReadByte())
					end

					return ffi_cast(ctype_read, table.concat(bytes))[0]
				end
			end

			-- Big-endian: bytes in MSB-first order
			do
				local temp = ffi.new(ctype_write, 0)
				META["Write" .. name .. "BE"] = function(self, num)
					temp[0] = num
					local bytes = ffi_string(temp, size)

					-- Write bytes in big-endian order (MSB first)
					for i = size, 1, -1 do
						self:WriteByte(bytes:byte(i))
					end

					return self
				end
				META["Read" .. name .. "BE"] = function(self)
					local bytes = {}

					for i = size, 1, -1 do
						bytes[i] = string.char(self:ReadByte())
					end

					return ffi_cast(ctype_read, table.concat(bytes))[0]
				end
			end
		end
	end

	do -- Luajit uses NAN tagging, make sure we have the canonical NAN
		local bit_band = bit.band
		local bit_bor = bit.bor
		local split_int32_p = ffi.typeof("struct { int32_t " .. (ffi.abi("le") and "lo, hi" or "hi, lo") .. "; } *")
		local int32_ctype = ffi.typeof("int32_t*")

		do
			local function double_isnan(buff)
				local q = ffi_cast(split_int32_p, buff)
				return bit_band(q.hi, 0x7FF00000) == 0x7FF00000 and
					bit_bor(q.lo, bit_band(q.hi, 0xFFFFF)) ~= 0
			end

			local double_ctype = ffi.typeof("double *")

			function META:ReadDouble()
				local src = self:ReadBytes(8)

				if double_isnan(src) then return 0 / 0 end

				return ffi_cast(double_ctype, src)[0]
			end
		end

		do
			local function float_isnan(buff)
				local as_int = ffi_cast(int32_ctype, buff)[0]
				return bit_band(as_int, 0x7F800000) == 0x7F800000 and
					bit_band(as_int, 0x7FFFFF) ~= 0
			end

			local float_ctype = ffi.typeof("float *")

			function META:ReadFloat()
				local src = self:ReadBytes(4)

				if float_isnan(src) then return 0 / 0 end

				return ffi_cast(float_ctype, src)[0]
			end

			-- Add LE/BE variants for Float with NaN handling
			-- Little-endian Float
			do
				local temp = ffi.new("float[1]", 0)

				function META:WriteFloatLE(num)
					temp[0] = num
					local bytes = ffi_string(temp, 4)

					for i = 1, 4 do
						self:WriteByte(bytes:byte(i))
					end

					return self
				end

				function META:ReadFloatLE()
					local bytes = {}

					for i = 1, 4 do
						bytes[i] = string.char(self:ReadByte())
					end

					local src = table.concat(bytes)

					if float_isnan(src) then return 0 / 0 end

					return ffi_cast(float_ctype, src)[0]
				end
			end

			-- Big-endian Float
			do
				local temp = ffi.new("float[1]", 0)

				function META:WriteFloatBE(num)
					temp[0] = num
					local bytes = ffi_string(temp, 4)

					for i = 4, 1, -1 do
						self:WriteByte(bytes:byte(i))
					end

					return self
				end

				function META:ReadFloatBE()
					local bytes = {}

					for i = 4, 1, -1 do
						bytes[i] = string.char(self:ReadByte())
					end

					local src = table.concat(bytes)

					if float_isnan(src) then return 0 / 0 end

					return ffi_cast(float_ctype, src)[0]
				end
			end
		end

		-- Add LE/BE variants for Double with NaN handling
		do
			local double_ctype = ffi.typeof("double *")

			-- Little-endian Double
			do
				local temp = ffi.new("double[1]", 0)

				function META:WriteDoubleLE(num)
					temp[0] = num
					local bytes = ffi_string(temp, 8)

					for i = 1, 8 do
						self:WriteByte(bytes:byte(i))
					end

					return self
				end

				function META:ReadDoubleLE()
					local bytes = {}

					for i = 1, 8 do
						bytes[i] = string.char(self:ReadByte())
					end

					local src = table.concat(bytes)
					local q = ffi_cast(split_int32_p, src)

					if
						bit_band(q.hi, 0x7FF00000) == 0x7FF00000 and
						bit_bor(q.lo, bit_band(q.hi, 0xFFFFF)) ~= 0
					then
						return 0 / 0
					end

					return ffi_cast(double_ctype, src)[0]
				end
			end

			-- Big-endian Double
			do
				local temp = ffi.new("double[1]", 0)

				function META:WriteDoubleBE(num)
					temp[0] = num
					local bytes = ffi_string(temp, 8)

					for i = 8, 1, -1 do
						self:WriteByte(bytes:byte(i))
					end

					return self
				end

				function META:ReadDoubleBE()
					local bytes = {}

					for i = 8, 1, -1 do
						bytes[i] = string.char(self:ReadByte())
					end

					local src = table.concat(bytes)
					local q = ffi_cast(split_int32_p, src)

					if
						bit_band(q.hi, 0x7FF00000) == 0x7FF00000 and
						bit_bor(q.lo, bit_band(q.hi, 0xFFFFF)) ~= 0
					then
						return 0 / 0
					end

					return ffi_cast(double_ctype, src)[0]
				end
			end
		end
	end

	do -- taken from lua sources https://github.com/lua/lua/blob/master/lstrlib.c
		local NB = 8
		local MC = bit.lshift(1, NB) - 1
		local SZINT = ffi.sizeof("uint64_t")

		function META:WritePackedInteger(n, size, signed)
			for i = 0, size - 1 do
				self:WriteByte(tonumber(bit.band(n, MC)))
				n = bit.rshift(n, NB)
			end

			if signed and size > SZINT then
				for i = SZINT, size - 1 do
					self:WriteByte(MC)
				end
			end
		end

		function META:ReadPackedInteger(size, signed)
			local res = 0
			local limit = (size <= SZINT) and size or SZINT

			for i = 0, limit - 1 do
				res = bit.bor(res, bit.lshift(self:ReadByte(), NB * i))
			end

			if signed and size < SZINT then
				-- sign extend: if MSB of the highest byte is set, fill upper bits with 1s
				local msb = bit.lshift(1, (size - 1) * NB + NB - 1)

				if bit.band(res, msb) ~= 0 then
					res = bit.bor(res, bit.bnot(bit.lshift(1, size * NB) - 1))
				end
			end

			return res
		end
	end

	function META:ReadVariableSizedInteger(byte_size)
		local ret = 0

		for i = 0, byte_size - 1 do
			local byte = self:ReadByte()
			ret = bit.bor(ret, bit.lshift(bit.band(byte, 127), 7 * i))

			if bit.band(byte, 128) == 0 then break end
		end

		if byte_size == 1 then
			ret = tonumber(ffi.cast("uint8_t", ret))
		elseif byte_size == 2 then
			ret = tonumber(ffi.cast("uint16_t", ret))
		elseif byte_size >= 2 and byte_size <= 4 then
			ret = tonumber(ffi.cast("uint32_t", ret))
		elseif byte_size > 4 then
			ret = ffi.cast("uint64_t", ret)
		end

		return ret
	end

	function META:WriteSizedInteger(value, byte_size)
		for i = 0, byte_size do
			if value > 0 then
				self:WriteByte(tonumber(bit.band(value, 127)))
				value = bit.rshift(value, 7)
			else
				self:WriteByte(0)
			end
		end
	end

	function META:ReadSizedInteger(byte_size)
		local ret = 0

		for i = 0, byte_size do
			ret = bit.bor(ret, bit.lshift(self:ReadByte(), 7 * i))
		end

		if byte_size == 1 then
			ret = tonumber(ffi.cast("uint8_t", ret))
		elseif byte_size == 2 then
			ret = tonumber(ffi.cast("uint16_t", ret))
		elseif byte_size >= 2 and byte_size <= 4 then
			ret = tonumber(ffi.cast("uint32_t", ret))
		elseif byte_size > 4 and byte_size <= 8 then
			ret = tonumber(ffi.cast("uint64_t", ret))
		end

		return ret
	end

	-- half precision (2 bytes)
	function META:WriteHalf(value)
		-- ieee 754 binary16
		-- 111111
		-- 54321098 76543210
		-- seeeeemm mmmmmmmm
		if value == 0.0 then
			self:WriteByte(0)
			self:WriteByte(0)
			return
		end

		local signBit = 0

		if value < 0 then
			signBit = 128 -- shifted left to appropriate position
			value = -value
		end

		local m, e = math.frexp(value)
		m = m * 2 - 1
		e = e - 1 + 15
		e = math.min(math.max(0, e), 31)
		m = m * 4
		-- sign, 5 bits of exponent, 2 bits of mantissa
		self:WriteByte(bit.bor(signBit, bit.band(e, 31) * 4, bit.band(m, 3)))
		-- get rid of written bits and shift for next 8
		m = (m - math.floor(m)) * 256
		self:WriteByte(bit.band(m, 255))
		return self
	end

	function META:ReadHalf()
		local b = self:ReadByte()
		local sign = 1

		if b >= 128 then
			sign = -1
			b = b - 128
		end

		local exponent = bit.rshift(b, 2) - 15
		local mantissa = bit.band(b, 3) / 4
		b = self:ReadByte()
		mantissa = mantissa + b / 4 / 256

		if mantissa == 0.0 and exponent == -15 then
			return 0.0
		else
			return (mantissa + 1.0) * math.pow(2, exponent) * sign
		end
	end

	function META:ReadVarInt(signed)
		local res = 0
		local size = 0

		for shift = 0, math.huge, 7 do
			local b = self:ReadByte()

			if shift < 28 then
				res = res + bit.lshift(bit.band(b, 0x7F), shift)
			else
				res = res + bit.band(b, 0x7F) * (2 ^ shift)
			end

			size = size + 1

			if b < 0x80 then break end
		end

		if signed then res = res - bit.band(res, 2 ^ 15) * 2 end

		return res
	end

	function META:WriteVariableSizedInteger(value, max_size)
		local output_size = 1

		while (max_size and output_size < max_size) or (not max_size and value > 127) do
			self:WriteByte(tonumber(bit.bor(bit.band(value, 127), 128)))
			value = bit.rshift(value, 7)
			output_size = output_size + 1
		end

		self:WriteByte(tonumber(bit.band(value, 127)))
		return output_size
	end

	function META:ReadULEB128()
		local result, shift = 0, 0

		while not self:TheEnd() do
			local b = self:ReadByte()
			result = bit.bor(result, bit.lshift(bit.band(b, 0x7f), shift))

			if bit.band(b, 0x80) == 0 then break end

			shift = shift + 7
		end

		return result
	end

	-- boolean
	function META:WriteBoolean(b)
		self:WriteByte(b and 1 or 0)
		return self
	end

	function META:ReadBoolean()
		return self:ReadByte() >= 1
	end

	-- char
	function META:WriteChar(b)
		self:WriteByte(b:byte())
		return self
	end

	function META:ReadChar()
		local b = self:ReadByte()

		if not b then return end

		return string.char(b)
	end
end

function buffer_template.AddStringFunctions(META)
	do
		function META:ReadBytes(len)
			local str = self:GetStringSlice(self:GetPosition(), self:GetPosition() + len - 1)
			self:Advance(len)
			return str
		end

		function META:ReadAll()
			return self:ReadBytes(self:GetSize())
		end
	end

	function META:FindNearest(str--[[#: string]], start--[[#: number]])
		for i = self:GetPosition(), self.ByteSize do
			if self:IsStringSlice(i, str) then return i + #str end
		end
	end

	function META:IsStringSlice(start--[[#: number]], str--[[#: string]])
		for i = 1, #str do
			if self.Buffer[start + i - 1] ~= str:byte(i) then return false end
		end

		return true
	end

	function META:IsStringSlice2(start--[[#: number]], stop--[[#: number]], str--[[#: string]])
		if start > self.ByteSize then return str == "" end

		if stop - start + 1 ~= #str then return false end

		for i = 1, #str do
			if self.Buffer[start + i - 1] ~= str:byte(i) then return false end
		end

		return true
	end

	-- null terminated string
	function META:WriteString(str)
		self:WriteBytes(str)
		self:WriteByte(0)
		return self
	end

	function META:ReadString(length, advance, terminator)
		terminator = terminator or 0

		if length and not advance then return self:ReadBytes(length) end

		local str = {}
		local pos = self:GetPosition()

		for _ = 1, length or self:GetSize() do
			local byte = self:ReadByte()

			if not byte or byte == terminator then break end

			table.insert(str, string.char(byte))
		end

		if advance then self:SetPosition(pos + length) end

		return table.concat(str)
	end

	function META:ReadFixedLengthString(length)
		return self:ReadString(length)
	end

	function META:WriteStringNonNullterminated(str)
		assert(META.WriteU32, "missing META:WriteU32")

		if #str > 0xFFFFFFFF then error("string is too long!", 2) end

		self:WriteU32(#str)
		self:WriteBytes(str)
		return self
	end

	function META:ReadStringNonNullterminated()
		assert(META.ReadU32, "missing META:ReadU32")
		local length = self:ReadU32()
		local str = {}

		for _ = 1, length do
			local byte = self:ReadByte()

			if not byte then break end

			table.insert(str, string.char(byte))
		end

		return table.concat(str)
	end

	function META:ReadBytesUntil(what)
		local pos = self:FindString(what)

		if pos then
			local str = self:ReadBytes(pos - self:GetPosition())
			self:Advance(#what)
			return str
		end

		return false
	end

	function META:FindString(str)
		local old_pos = self:GetPosition()

		for i = 1, self:GetSize() do
			local chr = self:ReadChar()

			if chr == str:sub(1, 1) then
				for i = 2, #str do
					if self:ReadChar() == str:sub(i, i) then
						local pos = self:GetPosition() - #str
						self:SetPosition(old_pos)
						return pos
					end
				end
			end
		end

		self:SetPosition(old_pos)
		return false
	end

	function META:IterateStrings()
		return function()
			local value = self:ReadString()
			return value ~= "" and value or nil
		end
	end
end

function buffer_template.AddPushPopFunctions(META)
	function META:PushPosition(pos)
		if self:GetSize() == 0 then return end

		if pos >= self:GetSize() then
			error("position pushed is larger than reported size of buffer", 2)
		end

		self.PushPopStackPos = self.PushPopStackPos or 0
		self.PushPopStack = self.PushPopStack or {}
		self.PushPopStack[self.PushPopStackPos] = self:GetPosition()
		self.PushPopStackPos = self.PushPopStackPos + 1
		self:SetPosition(pos)
	end

	function META:PopPosition()
		self.PushPopStack = self.PushPopStack or {}
		self.PushPopStackPos = self.PushPopStackPos or 0
		self.PushPopStackPos = self.PushPopStackPos - 1
		self:SetPosition(self.PushPopStack[self.PushPopStackPos])
	end
end

function buffer_template.AddStructFunctions(META)
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Vec2 = import("goluwa/structs/vec2.lua")
	local Color = import("goluwa/structs/color.lua")
	local Ang3 = import("goluwa/structs/ang3.lua")

	function META:WriteNumber(n)
		self:WriteDouble(n)
		return self
	end

	function META:ReadNumber()
		self:ReadDouble()
		return nil
	end

	-- nil
	function META:WriteNil()
		self:WriteByte(0)
		return self
	end

	function META:ReadNil()
		self:ReadByte()
		return nil
	end

	-- matrix44
	function META:WriteMatrix44(matrix)
		for i = 1, 16 do
			self:WriteFloat(matrix[i - 1])
		end

		return self
	end

	function META:ReadMatrix44()
		local out = Matrix44()

		for i = 1, 16 do
			out.m[i - 1] = self:ReadFloat()
		end

		return out
	end

	-- matrix33
	function META:WriteMatrix33(matrix)
		for i = 1, 8 do
			self:WriteFloat(matrix[i - 1])
		end

		return self
	end

	function META:ReadMatrix33()
		local out = Matrix33()

		for i = 1, 8 do
			out.m[i - 1] = self:ReadFloat()
		end

		return out
	end

	-- vec3
	function META:WriteVec3(v)
		self:WriteFloat(v.x)
		self:WriteFloat(v.y)
		self:WriteFloat(v.z)
		return self
	end

	function META:ReadVec3()
		return Vec3(self:ReadFloat(), self:ReadFloat(), self:ReadFloat())
	end

	-- vec2
	function META:WriteVec2(v)
		self:WriteFloat(v.x)
		self:WriteFloat(v.y)
		return self
	end

	function META:ReadVec2()
		return Vec2(self:ReadFloat(), self:ReadFloat())
	end

	-- vec2
	function META:WriteVec2Short(v)
		self:WriteI16(v.x)
		self:WriteI16(v.y)
		return self
	end

	function META:ReadVec2Short()
		return Vec2(self:ReadShort(), self:ReadShort())
	end

	-- ang3
	function META:WriteAng3(v)
		self:WriteFloat(v.x)
		self:WriteFloat(v.y)
		self:WriteFloat(v.z)
		return self
	end

	function META:ReadAng3()
		return Ang3(self:ReadFloat(), self:ReadFloat(), self:ReadFloat())
	end

	-- quat
	function META:WriteQuat(quat)
		self:WriteFloat(quat.x)
		self:WriteFloat(quat.y)
		self:WriteFloat(quat.z)
		self:WriteFloat(quat.w)
		return self
	end

	function META:ReadQuat()
		return Quat(self:ReadFloat(), self:ReadFloat(), self:ReadFloat(), self:ReadFloat())
	end

	-- color
	function META:WriteColor(color)
		self:WriteFloat(color.r)
		self:WriteFloat(color.g)
		self:WriteFloat(color.b)
		self:WriteFloat(color.a)
		return self
	end

	function META:ReadColor()
		return Color(self:ReadFloat(), self:ReadFloat(), self:ReadFloat(), self:ReadFloat())
	end

	function META:ReadByteColor()
		return Color.FromBytes(self:ReadByte(), self:ReadByte(), self:ReadByte(), self:ReadByte())
	end

	do
		function META:GenerateTypes()
			local read_functions = {}
			local write_functions = {}

			for k, v in pairs(META) do
				if type(k) == "string" then
					local key = k:match("Read(.+)")

					if key then
						read_functions[key:lower()] = v

						if key:find("Unsigned") then
							key = key:gsub("(Unsigned)(.+)", "%1 %2")
							read_functions[key:lower()] = v
						end
					end

					key = k:match("Write(.+)")

					if key then
						write_functions[key:lower()] = v

						if key:find("Unsigned") then
							key = key:gsub("(Unsigned)(.+)", "%1 %2")
							write_functions[key:lower()] = v
						end
					end
				end
			end

			META.read_functions = read_functions
			META.write_functions = write_functions
			local ids = {}

			for k in pairs(read_functions) do
				list.insert(ids, k)
			end

			list.sort(ids, function(a, b)
				return a > b
			end)

			META.type_ids = ids
		end

		META:GenerateTypes()

		function META:WriteType(val, t, type_func)
			t = t or type(val)

			if META.write_functions[t] then
				if t == "table" then
					return META.write_functions[t](self, val, type_func)
				else
					return META.write_functions[t](self, val)
				end
			end

			error("tried to write unknown type " .. t, 2)
		end

		function META:ReadType(t, signed)
			if META.read_functions[t] then
				return META.read_functions[t](self, signed)
			end

			error("tried to read unknown type " .. t, 2)
		end

		function META:GetTypeID(val)
			for k, v in ipairs(META.type_ids) do
				if v == val then return k end
			end
		end

		function META:GetTypeFromID(id)
			return META.type_ids[id]
		end
	end

	do
		-- Table terminator (255 is not a valid type ID since type_ids starts at 1)
		local TABLE_TERMINATOR = 255

		function META:WriteTable(tbl, type_func)
			type_func = type_func or _G.type

			for k, v in pairs(tbl) do
				local t = type_func(k)

				-- Map Lua "number" to a default numeric type for table keys
				if t == "number" then t = "double" end

				local id = self:GetTypeID(t)

				if not id then error("tried to write unknown type " .. t, 2) end

				self:WriteByte(id)
				self:WriteType(k, t, type_func)
				t = type_func(v)

				-- Map Lua "number" to a default numeric type for values
				if t == "number" then t = "double" end

				id = self:GetTypeID(t)

				if not id then error("tried to write unknown type " .. t, 2) end

				self:WriteByte(id)
				self:WriteType(v, t, type_func)
			end

			-- Write terminator to mark end of table
			self:WriteByte(TABLE_TERMINATOR)
		end

		function META:ReadTable()
			local tbl = {}

			while true do
				local b = self:ReadByte()

				-- Check for terminator
				if b == TABLE_TERMINATOR then return tbl end

				local t = self:GetTypeFromID(b)

				if not t then error("typeid " .. b .. " is unknown!", 2) end

				local k = self:ReadType(t)
				b = self:ReadByte()

				-- Check for terminator after key
				if b == TABLE_TERMINATOR then return tbl end

				t = self:GetTypeFromID(b)

				if not t then error("typeid " .. b .. " is unknown!", 2) end

				tbl[k] = self:ReadType(t)
			end
		end
	end

	function META:ReadULEB()
		local result, shift = 0, 0

		while not self:TheEnd() do
			local b = self:ReadByte()
			result = bit.bor(result, bit.lshift(bit.band(b, 0x7f), shift))

			if bit.band(b, 0x80) == 0 then break end

			shift = shift + 7
		end

		return result
	end
end

function buffer_template.AddStructureFunctions(META)
	local function header_to_table(str)
		local out = {}
		str = str:gsub("//.-\n", "") -- remove line comments
		str = str:gsub("/%*.-%s*/", "") -- remove multiline comments
		str = str:gsub("%s+", " ") -- remove excessive whitespace
		for field in str:gmatch("(.-);") do
			local type, key
			local assert
			local swap_endianess = false
			field = field:trim()

			if field:starts_with("swap") then
				field = field:sub(#"swap" + 1)
				swap_endianess = true
			end

			if field:find("=") then
				type, key, assert = field:match("^(.+) (.+) = (.+)$")
				assert = tonumber(assert) or assert
			else
				type, key = field:match("(.+) (.+)$")
			end

			type = type:trim()
			key = key:trim()
			local length
			key = key:gsub("%[(.-)%]$", function(num)
				length = tonumber(num) or num
				return ""
			end)
			local qualifier, _type = type:match("(.+) (.+)")

			if qualifier then type = _type end

			if not type then
				logn("somethings wrong with the above line!")
				error(field, 2)
			end

			if qualifier == nil then qualifier = "signed" end

			if type == "char" and not length then type = "byte" end

			list.insert(
				out,
				{
					type,
					key,
					signed = qualifier == "signed",
					length = length,
					padding = qualifier == "padding",
					assert = assert,
					swap_endianess = swap_endianess,
				}
			)
		end

		return out
	end

	function META:WriteStructure(structure, values)
		for _, data in ipairs(structure) do
			if type(data) == "number" then
				self:WriteByte(data)
			else
				if data.get then
					if type(data.get) == "function" then
						self:WriteType(data.get(values), data[1])
					else
						if not values or values[data.get] == nil then
							errorf("expected %s %s got nil", 2, data[1], data.get)
						end

						self:WriteType(values[data.get], data[1])
					end
				else
					self:WriteType(data[2], data[1])
				end
			end
		end
	end

	local cache = table.weak("kv")
	local map = {
		["short"] = "16",
		["long"] = "32",
		["int"] = "32",
		["long long"] = "64",
		["unsigned short"] = "u16",
		["unsigned long"] = "u32",
		["unsigned int"] = "u32",
		["unsigned long long"] = "u64",
		["signed short"] = "i16",
		["signed long"] = "i32",
		["signed int"] = "i32",
		["signed long long"] = "i64",
	}

	function META:ReadStructure(structure, ordered)
		if cache[structure] then
			return self:ReadStructure(cache[structure], ordered)
		end

		if type(structure) == "string" then
			-- if the string is something like "vec3" just call ReadType
			if map[structure] then
				structure = map[structure]

				if not structure:starts_with("i") and not structure:starts_with("u") then
					structure = "i" .. structure
				end
			end

			if META.read_functions[structure] then return self:ReadType(structure) end

			local data = header_to_table(structure)
			cache[structure] = data
			return self:ReadStructure(data, ordered)
		end

		if self:GetSize() == 0 then return end

		local out = {}

		for i, data in ipairs(structure) do
			if data.match then
				local key, val = next(data.match)

				if (type(val) == "function" and not val(out[key])) or out[key] ~= val then
					goto continue_
				end
			end

			local read_type = data[1]

			if map[read_type] then
				read_type = map[read_type]

				if data.signed then
					read_type = "i" .. read_type
				else
					read_type = "u" .. read_type
				end
			end

			local val

			if data.length then
				local length = data.length

				if type(length) == "string" then
					if out[length] then
						length = out[length]
					else
						error(length .. "  is not defined!")
					end
				end

				if data[1] == "char" or data[1] == "string" then
					val = self:ReadString(length)
				else
					local values = {}

					for i = 1, length do
						values[i] = self:ReadType(read_type)
					end

					val = values
				end
			else
				if data[1] == "bufferpos" then
					val = self:GetPosition()
				else
					val = self:ReadType(read_type)

					if data.swap_endianess then
						local size = 16

						if read_type:find("32", nil, true) or read_type:find("long", nil, true) then
							size = 32 -- asdasdasd
						end

						val = swap_endian(val, size)
					end
				end
			end

			if data.assert then
				if val ~= data.assert then
					errorf(
						"error in header: %s %s expected %s got %s",
						2,
						data[1],
						data[2],
						data.assert,
						(type(val) == "number" and ("%X"):format(val) or val)
					)
				end
			end

			if data.translate then val = data.translate[val] or val end

			if not data.padding then
				if val == nil then val = "nil" end

				local key = data[2]

				if ordered then
					list.insert(out, {key = key, val = val})
				else
					if out[key] then key = key .. i end

					out[key] = val
				end
			end

			if type(data[3]) == "table" then
				local tbl = {}

				if ordered then
					list.insert(out, {key = data[2], val = tbl})
				else
					out[data[2]] = tbl
				end

				for _ = 1, val do
					list.insert(tbl, self:ReadStructure(data[3], ordered))
				end
			end

			if data.switch then
				for k, v in pairs(self:ReadStructure(data.switch[val], ordered)) do
					if ordered then
						list.insert(out, {key = k, val = v})
					else
						out[k] = v
					end
				end
			end

			::continue_::
		end

		return out
	end

	function META:GetStructureSize(structure)
		if type(structure) == "string" then
			return self:GetStructureSize(header_to_table(structure))
		end

		local size = 0

		for _, v in ipairs(structure) do
			local t = v[1]

			if t == "longlong" then t = "long long" end

			if t == "byte" then t = "uint8_t" end

			if structs.GetStructMeta(t) then
				size = size + structs.GetStructMeta(t).byte_size
			elseif ffi then
				size = size + ffi.sizeof(t)
			end
		end

		return size
	end
end

return buffer_template
