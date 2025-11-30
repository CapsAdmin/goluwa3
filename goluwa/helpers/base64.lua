local bit_band = bit.band
local table_concat = table.concat
local math_floor = math.floor
local string_char = string.char
local base64 = {}
local decode_table = {}
local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

for i = 1, #chars do
	decode_table[chars:sub(i, i)] = i - 1
end

function base64.decode(str)
	local result = {}
	local bits = 0
	local num_bits = 0

	for i = 1, #str do
		local c = str:sub(i, i)

		if c ~= "=" and decode_table[c] then
			bits = bits * 64 + decode_table[c]
			num_bits = num_bits + 6

			while num_bits >= 8 do
				num_bits = num_bits - 8
				local byte = bit_band(math_floor(bits / (2 ^ num_bits)), 255)
				result[#result + 1] = string_char(byte)
			end
		end
	end

	return table_concat(result)
end

return base64
