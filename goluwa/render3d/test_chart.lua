local test_chart = {}
local SURROUND = 0.05
local PATCH_MARGIN = 0.08
-- the classic 24 patch chart as published sRGB values (D65), which read as reflectances once linear
local COLORCHECKER = {
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
	{"white", 243, 243, 242},
	{"neutral 8", 200, 200, 200},
	{"neutral 6.5", 160, 160, 160},
	{"neutral 5", 122, 122, 121},
	{"neutral 3.5", 85, 85, 85},
	{"black", 52, 52, 52},
}
local HUES = {
	{"red", {1, 0.02, 0.02}},
	{"yellow", {1, 1, 0.02}},
	{"green", {0.02, 1, 0.02}},
	{"cyan", {0.02, 1, 1}},
	{"blue", {0.02, 0.02, 1}},
	{"magenta", {1, 0.02, 1}},
}

local function srgb_to_linear(c)
	c = c / 255
	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

local function build_regions()
	local regions = {}
	local colors = {}
	local names = {}

	for i, patch in ipairs(COLORCHECKER) do
		colors[i] = {srgb_to_linear(patch[2]), srgb_to_linear(patch[3]), srgb_to_linear(patch[4])}
		names[i] = patch[1]
	end

	regions[#regions + 1] = {
		name = "colorchecker",
		x = 0.08,
		y = 0.06,
		cell_w = 0.14,
		cell_h = 0.13,
		cols = 6,
		rows = 4,
		colors = colors,
		names = names,
	}
	colors, names = {}, {}

	for stop = -8, 6 do
		local value = 0.18 * 2 ^ stop
		colors[#colors + 1] = {value, value, value}
		names[#names + 1] = "grey " .. stop .. " stops"
	end

	regions[#regions + 1] = {
		name = "stops",
		x = 0.08,
		y = 0.64,
		cell_w = 0.84 / 15,
		cell_h = 0.12,
		cols = 15,
		rows = 1,
		colors = colors,
		names = names,
	}
	colors, names = {}, {}

	for _, scale in ipairs{0.36, 0.045} do
		for _, hue in ipairs(HUES) do
			colors[#colors + 1] = {hue[2][1] * scale, hue[2][2] * scale, hue[2][3] * scale}
			names[#names + 1] = hue[1] .. " " .. (scale > 0.18 and "+1" or "-2") .. " stops"
		end
	end

	regions[#regions + 1] = {
		name = "hues",
		x = 0.08,
		y = 0.82,
		cell_w = 0.07,
		cell_h = 0.12,
		cols = 12,
		rows = 1,
		colors = colors,
		names = names,
	}
	return regions
end

test_chart.regions = build_regions()

function test_chart.GetPatches()
	local patches = {}

	for _, region in ipairs(test_chart.regions) do
		for index, color in ipairs(region.colors) do
			local column, row = (index - 1) % region.cols, math.floor((index - 1) / region.cols)
			patches[#patches + 1] = {
				region = region.name,
				name = region.names[index],
				uv = {
					region.x + (column + 0.5) * region.cell_w,
					region.y + (row + 0.5) * region.cell_h,
				},
				linear = color,
			}
		end
	end

	return patches
end

local function vec3_list(colors)
	local parts = {}

	for i, color in ipairs(colors) do
		parts[i] = string.format("vec3(%.9f, %.9f, %.9f)", color[1], color[2], color[3])
	end

	return table.concat(parts, ", ")
end

function test_chart.GetGLSL()
	local blocks = {}

	for _, region in ipairs(test_chart.regions) do
		blocks[#blocks + 1] = string.format(
			[[
		{
			vec2 area = (uv - vec2(%.9f, %.9f)) / vec2(%.9f, %.9f);

			if (all(greaterThanEqual(area, vec2(0.0))) && all(lessThan(area, vec2(1.0)))) {
				vec3 palette[%d] = vec3[%d](%s);
				vec2 cell = area * vec2(%d.0, %d.0);
				vec2 inside = fract(cell);
				ivec2 index = ivec2(floor(cell));

				if (all(greaterThan(inside, vec2(%.9f))) && all(lessThan(inside, vec2(%.9f)))) color = palette[index.y * %d + index.x];
			}
		}]],
			region.x,
			region.y,
			region.cell_w * region.cols,
			region.cell_h * region.rows,
			#region.colors,
			#region.colors,
			vec3_list(region.colors),
			region.cols,
			region.rows,
			PATCH_MARGIN,
			1 - PATCH_MARGIN,
			region.cols
		)
	end

	return string.format(
		[[
	vec3 test_chart(vec2 uv) {
		vec3 color = vec3(%.9f);
%s
		return color;
	}
]],
		SURROUND,
		table.concat(blocks, "\n")
	)
end

return test_chart
