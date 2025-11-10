local META = {}
META.__index = META
local ffi = require("ffi")
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
	}
]])
local refs = setmetatable({}, {__mode = "k"})

function META:MakeWritable()
	self.Writable = true
	return self
end

do
	function META:GetSize()
		return self.ByteSize
	end

	function META:SetPosition(pos)
		self.Position = pos

		if self.Writable then
			while self:TheEnd() do
				local new_size = math.max(self.ByteSize * 2, pos)
				local new_buffer = ffi.new("uint8_t[?]", new_size)
				ffi.copy(new_buffer, self.Buffer, self.ByteSize)
				self.Buffer = new_buffer
				self.ByteSize = new_size
				-- Update refs to prevent GC of new buffer
				refs[self] = {new_buffer}
			end
		end
	end

	function META:GetPosition()
		return self.Position
	end

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

	META.__len = META.GetSize
end

do
	function META:WriteByte(b)
		local pos = self:GetPosition()

		-- Ensure buffer has space before writing
		if self.Writable and pos >= self.ByteSize then
			-- Expand buffer before writing
			local new_size = math.max(self.ByteSize * 2, pos + 1)
			local new_buffer = ffi.new("uint8_t[?]", new_size)
			ffi.copy(new_buffer, self.Buffer, self.ByteSize)
			self.Buffer = new_buffer
			self.ByteSize = new_size
			-- Update refs to prevent GC of new buffer
			refs[self] = {new_buffer}
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

	function META:WriteBytes(str, len)
		for i = 1, len or #str do
			self:WriteByte(str:byte(i))
		end

		return self
	end
end

do
	function META:ReadBytes(len)
		local str = self:GetStringSlice(self:GetPosition(), self:GetPosition() + len - 1)
		self:Advance(len)
		return str
	end

	function META:ReadAll()
		return self:ReadBytes(self:GetSize())
	end

	function META:GetString()
		return ffi_string(self.Buffer, self.ByteSize)
	end

	function META:GetStringSlice(start--[[#: number]], stop--[[#: number]])
		if start > self.ByteSize then return "" end

		return ffi_string(self.Buffer + start, (stop - start) + 1)
	end
end

do
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
end

-- <cmtptr> CapsAdmin, http://codepad.org/uN7qlQTm
local function swap_endian(num, size)
	local result = 0

	for shift = 0, size - 8, 8 do
		result = bit.bor(bit.lshift(result, 8), bit.band(bit.rshift(num, shift), 0xff))
	end

	return result
end

-- Helper to swap bytes in a buffer (works for any type including floats/doubles)
local function swap_bytes(str)
	local len = #str
	local result = {}

	for i = 1, len do
		result[i] = str:sub(len - i + 1, len - i + 1)
	end

	return table.concat(result)
end

do -- basic data types
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

			for i = limit - 1, 0, -1 do
				res = bit.lshift(res, NB)
				res = bit.bor(res, self:ReadByte())
			end

			if size < SZINT then
				if signed then
					local mask = bit.lshift(1, size * NB - 1)
					res = bit.bxor(res, mask) - mask
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
			if value > 127 then
				self:WriteByte(tonumber(bit.band(value, 7)))
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
		if #str > 0xFFFFFFFF then error("string is too long!", 2) end

		self:WriteU32(#str)
		self:WriteBytes(str)
		return self
	end

	function META:ReadStringNonNullterminated()
		local length = self:ReadU32()
		local str = {}

		for _ = 1, length do
			local byte = self:ReadByte()

			if not byte then break end

			table.insert(str, string.char(byte))
		end

		return table.concat(str)
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
end

do -- push pop position
	function META:PushPosition(pos)
		if self:GetSize() == 0 then return end

		if pos >= self:GetSize() then
			error("position pushed is larger than reported size of buffer", 2)
		end

		self.PushPopStack[self.PushPopStackPos] = self:GetPosition()
		self.PushPopStackPos = (self.PushPopStackPos or 0) + 1
		self:SetPosition(pos)
	end

	function META:PopPosition()
		self.PushPopStackPos = self.PushPopStackPos - 1
		self:SetPosition(self.PushPopStack[self.PushPopStackPos])
	end
end

do -- read bits
	function META:RestartReadBits()
		self.buf_byte = 0
		self.buf_nbit = 0

		-- Reset to the position where bit reading started
		if self.buf_start_pos > 0 or self:GetPosition() > 0 then
			self:SetPosition(self.buf_start_pos)
		end
	end

	function META:BitsLeftInByte()
		return self.buf_nbit
	end

	function META:ReadBits(nbits)
		if nbits == 0 then return 0 end

		-- If starting fresh bit reading, save position
		if self.buf_nbit == 0 then self.buf_start_pos = self:GetPosition() end

		-- Accumulate bytes until we have enough bits
		-- Limit to 32 bits to prevent overflow of uint32_t buf_byte
		while self.buf_nbit < nbits and self.buf_nbit < 32 do
			if self:TheEnd() then
				-- No more bytes available
				if self.buf_nbit >= nbits then break else return nil end
			end

			-- Use bit.bor instead of addition to avoid signed/unsigned issues
			self.buf_byte = bit.bor(self.buf_byte, bit.lshift(self:ReadByte(), self.buf_nbit))
			self.buf_nbit = self.buf_nbit + 8
		end

		-- Check if we have enough bits before proceeding
		if self.buf_nbit < nbits then return nil -- Not enough bits available
		end

		self.buf_nbit = self.buf_nbit - nbits
		local bits

		if nbits == 32 then
			bits = self.buf_byte
			self.buf_byte = 0
		else
			bits = bit.band(self.buf_byte, bit.rshift(0xffffffff, 32 - nbits))
			self.buf_byte = bit.rshift(self.buf_byte, nbits)
		end

		return bits
	end
end

function META.New(data, len)
	local self = META.CType({
		Buffer = ffi.cast("uint8_t *", data),
		ByteSize = len or #data,
	})
	refs[self] = {data}
	return self
end

ffi.metatype(META.CType, META)
return META
