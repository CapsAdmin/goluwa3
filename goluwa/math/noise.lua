local bit = require("bit")
local ffi = require("ffi")
local math = require("math")
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local floor = math.floor
local lshift = bit.lshift
local max = math.max
local rshift = bit.rshift
local M = {}
local Perms = ffi.new(
	"uint8_t[512]",
	{
		151,
		160,
		137,
		91,
		90,
		15,
		131,
		13,
		201,
		95,
		96,
		53,
		194,
		233,
		7,
		225,
		140,
		36,
		103,
		30,
		69,
		142,
		8,
		99,
		37,
		240,
		21,
		10,
		23,
		190,
		6,
		148,
		247,
		120,
		234,
		75,
		0,
		26,
		197,
		62,
		94,
		252,
		219,
		203,
		117,
		35,
		11,
		32,
		57,
		177,
		33,
		88,
		237,
		149,
		56,
		87,
		174,
		20,
		125,
		136,
		171,
		168,
		68,
		175,
		74,
		165,
		71,
		134,
		139,
		48,
		27,
		166,
		77,
		146,
		158,
		231,
		83,
		111,
		229,
		122,
		60,
		211,
		133,
		230,
		220,
		105,
		92,
		41,
		55,
		46,
		245,
		40,
		244,
		102,
		143,
		54,
		65,
		25,
		63,
		161,
		1,
		216,
		80,
		73,
		209,
		76,
		132,
		187,
		208,
		89,
		18,
		169,
		200,
		196,
		135,
		130,
		116,
		188,
		159,
		86,
		164,
		100,
		109,
		198,
		173,
		186,
		3,
		64,
		52,
		217,
		226,
		250,
		124,
		123,
		5,
		202,
		38,
		147,
		118,
		126,
		255,
		82,
		85,
		212,
		207,
		206,
		59,
		227,
		47,
		16,
		58,
		17,
		182,
		189,
		28,
		42,
		223,
		183,
		170,
		213,
		119,
		248,
		152,
		2,
		44,
		154,
		163,
		70,
		221,
		153,
		101,
		155,
		167,
		43,
		172,
		9,
		129,
		22,
		39,
		253,
		19,
		98,
		108,
		110,
		79,
		113,
		224,
		232,
		178,
		185,
		112,
		104,
		218,
		246,
		97,
		228,
		251,
		34,
		242,
		193,
		238,
		210,
		144,
		12,
		191,
		179,
		162,
		241,
		81,
		51,
		145,
		235,
		249,
		14,
		239,
		107,
		49,
		192,
		214,
		31,
		181,
		199,
		106,
		157,
		184,
		84,
		204,
		176,
		115,
		121,
		50,
		45,
		127,
		4,
		150,
		254,
		138,
		236,
		205,
		93,
		222,
		114,
		67,
		29,
		24,
		72,
		243,
		141,
		128,
		195,
		78,
		66,
		215,
		61,
		156,
		180,
	}
)
local Perms12 = ffi.new("uint8_t[512]")

for i = 0, 255 do
	local x = Perms[i] % 12
	Perms[i + 256], Perms12[i], Perms12[i + 256] = Perms[i], x, x
end

local Grads3 = ffi.new(
	"const double[12][3]",
	{1, 1, 0},
	{-1, 1, 0},
	{1, -1, 0},
	{-1, -1, 0},
	{1, 0, 1},
	{-1, 0, 1},
	{1, 0, -1},
	{-1, 0, -1},
	{0, 1, 1},
	{0, -1, 1},
	{0, 1, -1},
	{0, -1, -1}
)

do
	local function GetN(bx, by, x, y)
		local t = .5 - x * x - y * y
		local index = Perms12[bx + Perms[by]]
		return max(0, (t * t) * (t * t)) * (Grads3[index][0] * x + Grads3[index][1] * y)
	end

	function M.Simplex2D(x, y)
		local s = (x + y) * 0.366025403
		local ix, iy = floor(x + s), floor(y + s)
		local t = (ix + iy) * 0.211324865
		local x0 = x + t - ix
		local y0 = y + t - iy
		ix, iy = band(ix, 255), band(iy, 255)
		local n0 = GetN(ix, iy, x0, y0)
		local n2 = GetN(ix + 1, iy + 1, x0 - 0.577350270, y0 - 0.577350270)
		local xi = rshift(floor(y0 - x0), 31)
		local n1 = GetN(ix + xi, iy + (1 - xi), x0 + 0.211324865 - xi, y0 - 0.788675135 + xi)
		return 70 * (n0 + n1 + n2)
	end
end

do
	local function GetN(ix, iy, iz, x, y, z)
		local t = .6 - x * x - y * y - z * z
		local index = Perms12[ix + Perms[iy + Perms[iz]]]
		return max(0, (t * t) * (t * t)) * (
				Grads3[index][0] * x + Grads3[index][1] * y + Grads3[index][2] * z
			)
	end

	function M.Simplex3D(x, y, z)
		local s = (x + y + z) * 0.333333333
		local ix, iy, iz = floor(x + s), floor(y + s), floor(z + s)
		local t = (ix + iy + iz) * 0.166666667
		local x0 = x + t - ix
		local y0 = y + t - iy
		local z0 = z + t - iz
		ix, iy, iz = band(ix, 255), band(iy, 255), band(iz, 255)
		local n0 = GetN(ix, iy, iz, x0, y0, z0)
		local n3 = GetN(ix + 1, iy + 1, iz + 1, x0 - 0.5, y0 - 0.5, z0 - 0.5)
		local yx = rshift(floor(y0 - x0), 31)
		local zy = rshift(floor(z0 - y0), 31)
		local zx = rshift(floor(z0 - x0), 31)
		local i1 = band(yx, bor(zy, zx))
		local j1 = band(1 - yx, zy)
		local k1 = band(1 - zy, 1 - band(yx, zx))
		local i2 = bor(yx, band(zy, zx))
		local j2 = bor(1 - yx, zy)
		local k2 = bxor(yx, zy)
		local n1 = GetN(
			ix + i1,
			iy + j1,
			iz + k1,
			x0 + 0.166666667 - i1,
			y0 + 0.166666667 - j1,
			z0 + 0.166666667 - k1
		)
		local n2 = GetN(
			ix + i2,
			iy + j2,
			iz + k2,
			x0 + 0.333333333 - i2,
			y0 + 0.333333333 - j2,
			z0 + 0.333333333 - k2
		)
		return 32 * (n0 + n1 + n2 + n3)
	end
end

do
	local Grads4 = ffi.new(
		"const double[32][4]",
		{0, 1, 1, 1},
		{0, 1, 1, -1},
		{0, 1, -1, 1},
		{0, 1, -1, -1},
		{0, -1, 1, 1},
		{0, -1, 1, -1},
		{0, -1, -1, 1},
		{0, -1, -1, -1},
		{1, 0, 1, 1},
		{1, 0, 1, -1},
		{1, 0, -1, 1},
		{1, 0, -1, -1},
		{-1, 0, 1, 1},
		{-1, 0, 1, -1},
		{-1, 0, -1, 1},
		{-1, 0, -1, -1},
		{1, 1, 0, 1},
		{1, 1, 0, -1},
		{1, -1, 0, 1},
		{1, -1, 0, -1},
		{-1, 1, 0, 1},
		{-1, 1, 0, -1},
		{-1, -1, 0, 1},
		{-1, -1, 0, -1},
		{1, 1, 1, 0},
		{1, 1, -1, 0},
		{1, -1, 1, 0},
		{1, -1, -1, 0},
		{-1, 1, 1, 0},
		{-1, 1, -1, 0},
		{-1, -1, 1, 0},
		{-1, -1, -1, 0}
	)

	local function GetN(ix, iy, iz, iw, x, y, z, w)
		local t = .6 - x * x - y * y - z * z - w * w
		local index = band(Perms[ix + Perms[iy + Perms[iz + Perms[iw]]]], 0x1F)
		return max(0, (t * t) * (t * t)) * (
				Grads4[index][0] * x + Grads4[index][1] * y + Grads4[index][2] * z + Grads4[index][3] * w
			)
	end

	local Simplex = ffi.new(
		"uint8_t[64][4]",
		{0, 1, 2, 3},
		{0, 1, 3, 2},
		{},
		{0, 2, 3, 1},
		{},
		{},
		{},
		{1, 2, 3},
		{0, 2, 1, 3},
		{},
		{0, 3, 1, 2},
		{0, 3, 2, 1},
		{},
		{},
		{},
		{1, 3, 2},
		{},
		{},
		{},
		{},
		{},
		{},
		{},
		{},
		{1, 2, 0, 3},
		{},
		{1, 3, 0, 2},
		{},
		{},
		{},
		{2, 3, 0, 1},
		{2, 3, 1},
		{1, 0, 2, 3},
		{1, 0, 3, 2},
		{},
		{},
		{},
		{2, 0, 3, 1},
		{},
		{2, 1, 3},
		{},
		{},
		{},
		{},
		{},
		{},
		{},
		{},
		{2, 0, 1, 3},
		{},
		{},
		{},
		{3, 0, 1, 2},
		{3, 0, 2, 1},
		{},
		{3, 1, 2},
		{2, 1, 0, 3},
		{},
		{},
		{},
		{3, 1, 0, 2},
		{},
		{3, 2, 0, 1},
		{3, 2, 1}
	)

	for i = 0, 63 do
		Simplex[i][0] = lshift(1, Simplex[i][0]) - 1
		Simplex[i][1] = lshift(1, Simplex[i][1]) - 1
		Simplex[i][2] = lshift(1, Simplex[i][2]) - 1
		Simplex[i][3] = lshift(1, Simplex[i][3]) - 1
	end

	function M.Simplex4D(x, y, z, w)
		local s = (x + y + z + w) * 0.309016994
		local ix, iy, iz, iw = floor(x + s), floor(y + s), floor(z + s), floor(w + s)
		local t = (ix + iy + iz + iw) * 0.138196601
		local x0 = x + t - ix
		local y0 = y + t - iy
		local z0 = z + t - iz
		local w0 = w + t - iw
		local c1 = band(rshift(floor(y0 - x0), 26), 32)
		local c2 = band(rshift(floor(z0 - x0), 27), 16)
		local c3 = band(rshift(floor(z0 - y0), 28), 8)
		local c4 = band(rshift(floor(w0 - x0), 29), 4)
		local c5 = band(rshift(floor(w0 - y0), 30), 2)
		local c6 = rshift(floor(w0 - z0), 31)
		local c = c1 + c2 + c3 + c4 + c5 + c6
		local i1 = rshift(Simplex[c][0], 2)
		local j1 = rshift(Simplex[c][1], 2)
		local k1 = rshift(Simplex[c][2], 2)
		local l1 = rshift(Simplex[c][3], 2)
		local i2 = band(rshift(Simplex[c][0], 1), 1)
		local j2 = band(rshift(Simplex[c][1], 1), 1)
		local k2 = band(rshift(Simplex[c][2], 1), 1)
		local l2 = band(rshift(Simplex[c][3], 1), 1)
		local i3 = band(Simplex[c][0], 1)
		local j3 = band(Simplex[c][1], 1)
		local k3 = band(Simplex[c][2], 1)
		local l3 = band(Simplex[c][3], 1)
		ix, iy, iz, iw = band(ix, 255), band(iy, 255), band(iz, 255), band(iw, 255)
		local n0 = GetN(ix, iy, iz, iw, x0, y0, z0, w0)
		local n1 = GetN(
			ix + i1,
			iy + j1,
			iz + k1,
			iw + l1,
			x0 + 0.138196601 - i1,
			y0 + 0.138196601 - j1,
			z0 + 0.138196601 - k1,
			w0 + 0.138196601 - l1
		)
		local n2 = GetN(
			ix + i2,
			iy + j2,
			iz + k2,
			iw + l2,
			x0 + 0.276393202 - i2,
			y0 + 0.276393202 - j2,
			z0 + 0.276393202 - k2,
			w0 + 0.276393202 - l2
		)
		local n3 = GetN(
			ix + i3,
			iy + j3,
			iz + k3,
			iw + l3,
			x0 + 0.414589803 - i3,
			y0 + 0.414589803 - j3,
			z0 + 0.414589803 - k3,
			w0 + 0.414589803 - l3
		)
		local n4 = GetN(
			ix + 1,
			iy + 1,
			iz + 1,
			iw + 1,
			x0 - 0.447213595,
			y0 - 0.447213595,
			z0 - 0.447213595,
			w0 - 0.447213595
		)
		return 27 * (n0 + n1 + n2 + n3 + n4)
	end
end

return M
