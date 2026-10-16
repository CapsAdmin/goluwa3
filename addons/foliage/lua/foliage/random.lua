-- the random numbers of the generators. everything a generator makes comes from one of these, made from the seed of
-- its config, so the same seed and config give the same asset. a stream forks named sub streams, so drawing one more
-- number for the trunk does not change the leaves
local bit = require("bit")
local band, bxor, rshift, lshift, tobit = bit.band, bit.bxor, bit.rshift, bit.lshift, bit.tobit
local Random = {}
Random.__index = Random

-- the low 32 bits of a * b, a double product of two 32 bit numbers is not exact
local function mul32(a, b)
	local a_lo, a_hi = band(a, 0xffff), rshift(a, 16)
	local b_lo, b_hi = band(b, 0xffff), rshift(b, 16)
	return tobit(a_lo * b_lo + lshift(band(a_hi * b_lo + a_lo * b_hi, 0xffff), 16))
end

-- murmur3's finalizer, every bit of the input moves every bit of the output
local function mix(h)
	h = mul32(bxor(h, rshift(h, 16)), 0x85ebca6b)
	h = mul32(bxor(h, rshift(h, 13)), 0xc2b2ae35)
	return bxor(h, rshift(h, 16))
end

-- fnv-1a of the string of the value
function Random.Hash(value)
	local str = tostring(value)
	local h = tobit(2166136261)

	for i = 1, #str do
		h = mul32(bxor(h, str:byte(i)), 16777619)
	end

	return mix(h)
end

function Random.New(seed)
	local state = Random.Hash(seed)
	return setmetatable({state = state, origin = state}, Random)
end

-- a stream of its own for a part of the asset, the same name gives the same stream whatever was drawn before
function Random:Fork(name)
	local state = mix(bxor(self.origin, Random.Hash(name)))
	return setmetatable({state = state, origin = state}, Random)
end

-- [0, 1), xorshift32
function Random:Next()
	local x = self.state

	if x == 0 then x = 0x6d2b79f5 end

	x = bxor(x, lshift(x, 13))
	x = bxor(x, rshift(x, 17))
	x = bxor(x, lshift(x, 5))
	self.state = x
	return (x % 4294967296) / 4294967296
end

function Random:Range(min, max)
	return min + (max - min) * self:Next()
end

-- a number or {min, max}
function Random:Pick(range)
	if type(range) == "number" then return range end

	return range[1] + (range[2] - range[1]) * self:Next()
end

function Random:Int(min, max)
	return min + math.floor(self:Next() * (max - min + 1))
end

function Random:Sign()
	return self:Next() < 0.5 and -1 or 1
end

-- roughly normal around 0 with a deviation of 1
function Random:Gaussian()
	return (self:Next() + self:Next() + self:Next() + self:Next() - 2) * 1.7320508
end

function Random:Choose(list)
	return list[math.floor(self:Next() * #list) + 1]
end

-- a positive 31 bit integer, for the shaders that take a seed
function Random:Seed()
	self:Next()
	return band(self.state, 0x7fffffff)
end

return Random
