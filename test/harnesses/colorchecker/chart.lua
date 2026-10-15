-- the X-Rite / Calibrite ColorChecker Classic: 24 matte patches in 6 columns and 4 rows. The sRGB values are the published
-- D65 renderings of the patches' reflectances (white 243 is about 90 percent, the neutrals go 59, 36, 19, 9, 3 percent), used
-- here as the linear albedo of a matte surface.
local chart = {}
chart.patches = {
	{"dark skin", 115, 82, 68},
	{"light skin", 194, 150, 130},
	{"blue sky", 98, 122, 157},
	{"foliage", 87, 108, 67},
	{"blue flower", 133, 128, 177},
	{"bluish green", 103, 189, 170},
	{"orange", 214, 126, 44},
	{"purplish blue", 80, 91, 166},
	{"moderate red", 193, 90, 99},
	{"purple", 94, 60, 108},
	{"yellow green", 157, 188, 64},
	{"orange yellow", 224, 163, 46},
	{"blue", 56, 61, 150},
	{"green", 70, 148, 73},
	{"red", 175, 54, 60},
	{"yellow", 231, 199, 31},
	{"magenta", 187, 86, 149},
	{"cyan", 8, 133, 161},
	{"white 9.5", 243, 243, 242},
	{"neutral 8", 200, 200, 200},
	{"neutral 6.5", 160, 160, 160},
	{"neutral 5", 122, 122, 121},
	{"neutral 3.5", 85, 85, 85},
	{"black 2", 52, 52, 52},
}

function chart.SRGBToLinear(v)
	v = v / 255

	if v <= 0.04045 then return v / 12.92 end

	return ((v + 0.055) / 1.055) ^ 2.4
end

function chart.GetAlbedo(index)
	local p = chart.patches[index]
	return chart.SRGBToLinear(p[2]), chart.SRGBToLinear(p[3]), chart.SRGBToLinear(p[4])
end

-- patch centers on the ground, x to the right, z away from the camera, a patch is SIZE wide with GAP between
chart.SIZE = 1
chart.GAP = 0.1
chart.COLUMNS = 6
chart.ROWS = 4

function chart.GetCenter(index)
	local col = (index - 1) % chart.COLUMNS
	local row = math.floor((index - 1) / chart.COLUMNS)
	local pitch = chart.SIZE + chart.GAP
	local x = (col - (chart.COLUMNS - 1) / 2) * pitch
	local z = (row - (chart.ROWS - 1) / 2) * pitch
	return x, z
end

return chart
