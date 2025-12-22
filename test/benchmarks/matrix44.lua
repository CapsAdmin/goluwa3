local benchmark = require("goluwa.helpers.benchmark")
local Matrix44 = require("structs.matrix44")

local function RandomMatrix()
	local m = Matrix44()

	for i = 1, 16 do
		m:SetI(i - 1, math.random() * 200 - 100)
	end

	return m
end

local b = RandomMatrix()
local a = RandomMatrix()
local c = Matrix44()

benchmark.Run("Matrix44 Multiply", function()
	c = a * b * c
end)

benchmark.Run("Matrix44 Inverse", function()
	c = a:GetInverse()
end)
