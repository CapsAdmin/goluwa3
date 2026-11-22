local ffi = require("ffi")
local commands = import("goluwa/cli/commands.lua")
local eye_glare = import("goluwa/render3d/eye_glare.lua")
local eye_psf = import("goluwa/render3d/eye_psf.lua")
local lens = {}
lens.SENSOR_DIAGONAL = math.sqrt(36 * 36 + 24 * 24)
lens.MAX_GHOSTS = 64
lens.GHOST_TEXELS = 8
lens.APERTURE_ENTRIES = 1024
lens.SENSOR_PITCH = 4.5e-3
lens.SENSOR_REFLECTANCE = {digital = 0.06, film = 0.01}
lens.FILTER_THICKNESS = 2
lens.FILTER_GAP = 1
lens.DECENTER = 0.02
lens.TRACE_GRID = 33
lens.TRACE_SOURCES = 4
lens.TRACE_EXTENT = 1.6
lens.TRACE_MIN_RADIUS = 6
lens.DESIGN_WAVELENGTH = 550
lens.MAX_DISKS = 4
lens.WARP_ENTRIES = 128
lens.VIGNETTE_FIELDS = 32
lens.VIGNETTE_APERTURES = 16
lens.APERTURE_MAX = 64
lens.OPENING_STOPS = 0.7
lens.STAR_PREFILTER_DEGREES = 0.07
lens.STAR_FAR_DEGREES = 25
lens.SMEAR_CORRELATION = 15e-6
local DESIGN_WAVELENGTH = lens.DESIGN_WAVELENGTH
local NO_DISK = 1e9
local CHANNEL_BANDS = {{590, 615, 640, 665}, {500, 525, 550, 575}, {420, 445, 470, 495}}
lens.coatings = {
	none = {},
	single = {{1.38, 0.25}},
	multi = {{1.38, 0.25}, {2.05, 0.5}, {1.63, 0.25}},
}
local DOUBLE_GAUSS = {
	{29.475, 3.76, 1.670, 47.2, 25.2},
	{84.83, 0.12, 1, 0, 25.2},
	{19.275, 4.025, 1.670, 47.2, 23},
	{40.77, 3.275, 1.699, 30.1, 23},
	{12.75, 5.705, 1, 0, 18},
	{0, 4.5, 1, 0, 17.1, stop = true},
	{-14.495, 1.18, 1.603, 38.0, 17},
	{40.77, 6.065, 1.658, 50.9, 20},
	{-20.385, 0.19, 1, 0, 20},
	{437.065, 3.22, 1.717, 47.9, 20},
	{-39.73, 0, 1, 0, 20},
}
lens.designs = {
	{
		name = "double_gauss",
		help = "double Gauss 50 mm f/2 (Tronnier, US 2,673,491), the normal lens of most cameras",
		focal_length = 50,
		surfaces = DOUBLE_GAUSS,
	},
	{
		name = "retrofocus",
		help = "retrofocus wide angle 22 mm f/2.7 (Nakamura). It covers 34 degrees off axis, less than a full frame corner",
		focal_length = 22,
		coverage = 34,
		surfaces = {
			{35.98738, 1.21638, 1.54, 59.7, 23.716},
			{11.69718, 9.9957, 1, 0, 17.996},
			{13.08714, 5.12622, 1.772, 49.6, 12.364},
			{-22.63294, 1.76924, 1.617, 36.6, 9.812},
			{71.05802, 0.8184, 1, 0, 9.152},
			{0, 2.27766, 1, 0, 8.756, stop = true},
			{-9.58584, 2.43254, 1.617, 36.6, 8.184},
			{-11.28864, 0.11506, 1, 0, 9.152},
			{-166.7765, 3.09606, 1.713, 53.9, 10.648},
			{-7.5911, 1.32682, 1.805, 25.4, 11.44},
			{-16.7662, 3.98068, 1, 0, 12.276},
			{-7.70286, 1.21638, 1.617, 36.6, 13.42},
			{-11.97328, 0, 1, 0, 17.996},
		},
	},
	{
		name = "triplet",
		help = "Cooke triplet 50 mm f/4, three air spaced elements",
		focal_length = 50,
		surfaces = {
			{21.48, 2.0, 1.6229, 60.0, 16},
			{-124.1, 4.0, 1, 0, 16},
			{-19.1, 1.0, 1.6034, 38.0, 12},
			{22.0, 2.0, 1, 0, 12},
			{0, 2.0, 1, 0, 10.4, stop = true},
			{328.9, 2.5, 1.6229, 60.0, 14},
			{-16.7, 0, 1, 0, 14},
		},
	},
	{
		name = "petzval",
		help = "Petzval portrait 127 mm f/3.7: two separated achromats with the stop between them, a long barrel that vignettes off axis bokeh into swirls",
		focal_length = 127,
		surfaces = {
			{124.4, 6, 1.517, 64.2, 36},
			{-124.4, 2, 1.649, 33.8, 36},
			{-773, 31.75, 1, 0, 36},
			{0, 31.75, 1, 0, 30, stop = true},
			{93.3, 5, 1.517, 64.2, 30},
			{-93.3, 2, 1.649, 33.8, 30},
			{-580, 0, 1, 0, 30},
		},
	},
}
lens.designs[#lens.designs + 1] = {
	name = "action_camera",
	help = "a guess at an action camera: a 3 mm fisheye form (after Muller's fisheye, clear diameters widened for f/2.8 and the whole field) behind a flat protective window, a fixed f/2.8 round aperture, 66 degrees off axis to the frame corner",
	focal_length = 3,
	coverage = 66,
	f_number = 2.8,
	fixed_aperture = true,
	surfaces = {
		{0, 0.45, 1.52, 64, 20.4},
		{0, 0.45, 1, 0, 20.4},
		{9.06747, 0.25005, 1.62, 60.3, 17.85},
		{3.41793, 2.22408, 1, 0, 11.934},
		{22.56057, 0.31962, 1.639, 55.4, 10.506},
		{2.50047, 3.34647, 1, 0, 7.956},
		{2.87646, 0.60162, 1.654, 39.6, 4.794},
		{13.16031, 1.61685, 1, 0, 4.386},
		{0, 0.42489, 1, 0, 2.652, stop = true},
		{8.83623, 0.65802, 1.517, 64.2, 2.856},
		{-1.56795, 0.29142, 1.805, 25.4, 3.264},
		{-4.28652, 0.01881, 1, 0, 3.672},
		{-6.71178, 0.282, 1.673, 32.1, 3.672},
		{-4.51212, 0, 1, 0, 3.876},
	},
}
local design_names = {"none"}

for _, design in ipairs(lens.designs) do
	lens.designs[design.name] = design
	design_names[#design_names + 1] = design.name
end

local fields = {}
local state = {}
lens.fields = fields

local function define(key, default, info)
	info.key = key
	info.default = default
	info.type = type(default)
	info.friendly = info.friendly or (key:match("%.(.+)$"):gsub("_", " "))
	fields[#fields + 1] = info
	fields[key] = info
	state[key] = default
end

define(
	"lens.design",
	"none",
	{
		group = "Lens",
		enums = design_names,
		help = "camera mode: the lens the picture is taken through, a real prescription. Its ghosts (lens flare), sunstar, vignetting, cat's eye bokeh, distortion and lateral colour come from its glass. none is an ideal lens without any of them",
	}
)
define(
	"lens.coating",
	"multi",
	{
		group = "Lens",
		enums = {"none", "single", "multi"},
		help = "the anti reflection coating on every glass to air surface. none reflects about 4% per surface (lenses before 1940: bright, many ghosts), single is one magnesium fluoride layer (about 1.3%, purple and green ghosts), multi a three layer broadband coating (about 0.2%)",
	}
)
define(
	"lens.blades",
	9,
	{
		group = "Aperture",
		integer = true,
		help = "aperture blades. 0 or below 3 is a round stop. Straight blades give a polygon: the bokeh and ghosts take its shape and the sunstar gets a ray per blade edge (twice the blade count for odd counts)",
	}
)
define(
	"lens.blade_curvature",
	0.5,
	{
		group = "Aperture",
		help = "how round the blades are: 0 straight (a sharp polygon and strong sunstars), 1 a circle. Wide open the blades leave the barrel's round opening whatever this is, the polygon shows from about a stop down",
	}
)
define(
	"lens.blade_rotation",
	90,
	{
		group = "Aperture",
		help = "rotation of the aperture polygon in degrees",
	}
)
define(
	"lens.dust",
	0,
	{
		group = "Imperfections",
		help = "the share of the glass covered by dust specks (3 to 40 micrometres). Each speck diffracts light into a halo about a degree wide: a veil around bright lights and fine speckle in the sunstar. 0.0003 is a clean lens, 0.003 a dusty one, 0.02 filthy",
	}
)
define(
	"lens.scratches",
	0,
	{
		group = "Imperfections",
		help = "cleaning scratches per square centimetre of glass. Each thin scratch diffracts light into a streak at right angles to it",
	}
)
define(
	"lens.smear",
	0,
	{
		group = "Imperfections",
		help = "a grease film on the front element (a fingerprint), as its rms phase in radians: it scatters 1 - exp(-smear^2) of the light into a soft glow a degree or two wide. 0.3 is a light smudge, 1 a thumb print",
	}
)
define(
	"lens.tolerance",
	0,
	{
		group = "Imperfections",
		help = "manufacturing variation: 1 decentres every element by about 20 micrometres and varies each aperture blade by about 2%, so ghosts leave the line through the centre and sunstar rays differ in length. 0 is the ideal lens",
	}
)
define(
	"lens.seed",
	1,
	{
		group = "Imperfections",
		integer = true,
		help = "which copy of the lens: where the dust and scratches lie and how its elements and blades are off",
	}
)
define(
	"lens.sensor",
	"digital",
	{
		group = "Sensor",
		enums = {"digital", "film"},
		help = "what sits behind the lens. digital is a sensor that reflects about 6% back into the lens through an anti reflection coated cover glass, and its grid of microlenses diffracts that reflection into a grid of dots around bright lights (red dot flare). film reflects about 1% and has no cover glass",
	}
)
define(
	"lens.ghosts",
	true,
	{
		group = "Effects",
		help = "ghosts: light reflected twice between lens surfaces lands as images of the aperture along the line through the light and the centre",
	}
)
define(
	"lens.ray_traced_ghosts",
	true,
	{
		group = "Effects",
		help = "trace the larger ghosts of the brightest lights through the real glass: aberrations bend and brighten them unevenly and the coatings tint them by angle. Off draws every ghost as a sharp paraxial image of the aperture",
	}
)
define(
	"lens.starburst",
	true,
	{
		group = "Effects",
		help = "the diffraction of the aperture around bright lights, a ray per straight blade edge, longer when stopped down",
	}
)
define(
	"lens.vignetting",
	true,
	{
		group = "Effects",
		help = "natural vignetting (cos^4 of the image side angle) and optical vignetting (the barrel cutting the light cone off axis, less when stopped down)",
	}
)
define(
	"lens.distortion",
	1,
	{
		group = "Effects",
		help = "how much of the lens's barrel or pincushion distortion (from its real chief rays) is shown: 1 is the lens, 0 a rectilinear picture, 2 twice the bend, below 0 the opposite bend. The corners stay in place",
	}
)
define(
	"lens.lateral_color",
	1,
	{
		group = "Effects",
		help = "how much lateral chromatic aberration is shown: red and blue chief rays land at other heights than green, coloured fringes toward the corners. 1 is the lens, 0 none, 2 twice as much",
	}
)
define(
	"lens.longitudinal_color",
	1,
	{
		group = "Effects",
		help = "how much longitudinal chromatic aberration the depth of field shows: red and blue focus at other depths than green, so out of focus highlights get coloured rims (purple in front of the focus, green behind it, or the other way round depending on the glass). 1 is the lens, 0 none, 2 twice as much",
	}
)
define(
	"lens.ghost_intensity",
	1,
	{
		group = "Strength",
		help = "scales the ghosts, 1 is what the coatings reflect",
	}
)
define(
	"lens.starburst_intensity",
	1,
	{
		group = "Strength",
		help = "scales the sunstar, 1 is the diffraction of the aperture",
	}
)
lens.presets = {
	none = {},
	modern_50 = {
		["lens.design"] = "double_gauss",
		["lens.coating"] = "multi",
		["lens.blades"] = 9,
		["lens.blade_curvature"] = 0.6,
		["lens.dust"] = 0.0003,
		["lens.tolerance"] = 0.5,
	},
	vintage_50 = {
		["lens.design"] = "double_gauss",
		["lens.coating"] = "none",
		["lens.blades"] = 6,
		["lens.blade_curvature"] = 0,
		["lens.dust"] = 0.004,
		["lens.scratches"] = 4,
		["lens.smear"] = 0.4,
		["lens.tolerance"] = 1.5,
		["lens.sensor"] = "film",
	},
	wide_22 = {
		["lens.design"] = "retrofocus",
		["lens.coating"] = "single",
		["lens.blades"] = 7,
		["lens.blade_curvature"] = 0,
		["lens.dust"] = 0.001,
		["lens.tolerance"] = 0.8,
	},
	cooke_triplet = {
		["lens.design"] = "triplet",
		["lens.coating"] = "single",
		["lens.blades"] = 5,
		["lens.blade_curvature"] = 0,
		["lens.dust"] = 0.002,
		["lens.scratches"] = 2,
		["lens.tolerance"] = 1,
	},
	gopro = {
		["lens.design"] = "action_camera",
		["lens.coating"] = "multi",
		["lens.blades"] = 0,
		["lens.blade_curvature"] = 1,
		["lens.dust"] = 0.003,
		["lens.scratches"] = 2,
		["lens.smear"] = 0.25,
		["lens.tolerance"] = 1,
	},
	petzval_portrait = {
		["lens.design"] = "petzval",
		["lens.coating"] = "none",
		["lens.blades"] = 0,
		["lens.blade_curvature"] = 1,
		["lens.dust"] = 0.003,
		["lens.scratches"] = 3,
		["lens.smear"] = 0.3,
		["lens.tolerance"] = 1.5,
		["lens.sensor"] = "film",
	},
}
local active_preset = "none"

function lens.Get(key)
	local value = state[key]

	if value == nil then error("unknown lens setting " .. tostring(key), 2) end

	return value
end

function lens.Set(key, value)
	local info = fields[key] or error("unknown lens setting " .. tostring(key), 2)

	if type(value) ~= info.type then
		error(key .. " expects a " .. info.type .. ", got " .. type(value), 2)
	end

	if info.enums and not table.has_value(info.enums, value) then
		error(
			key .. " expects one of " .. table.concat(info.enums, ", ") .. ", got " .. tostring(value),
			2
		)
	end

	state[key] = value
	active_preset = nil
end

function lens.SetPreset(name)
	local preset = lens.presets[name] or error("unknown lens preset " .. tostring(name), 2)

	for key in pairs(preset) do
		if not fields[key] then
			error("lens preset " .. name .. " sets unknown " .. key, 2)
		end
	end

	for _, info in ipairs(fields) do
		local value = preset[info.key]

		if value == nil then value = info.default end

		lens.Set(info.key, value)
	end

	active_preset = name
end

function lens.GetPreset()
	return active_preset
end

function lens.IsActive()
	return state["lens.design"] ~= "none"
end

local function index_at(n_d, abbe, wavelength)
	if abbe == 0 then return n_d end

	local b = (n_d - 1) / abbe / (1 / 486.1 ^ 2 - 1 / 656.3 ^ 2)
	return n_d + b * (1 / wavelength ^ 2 - 1 / 587.6 ^ 2)
end

function lens.GetCoatingReflectance(layers, n_glass, wavelength)
	local m11r, m11i, m12r, m12i = 1, 0, 0, 0
	local m21r, m21i, m22r, m22i = 0, 0, 1, 0

	for _, layer in ipairs(layers) do
		local n = layer[1]
		local phase = 2 * math.pi * layer[2] * DESIGN_WAVELENGTH / wavelength
		local c, s = math.cos(phase), math.sin(phase)
		m11r, m11i, m12r, m12i = m11r * c - m12i * n * s,
		m11i * c + m12r * n * s,
		-m11i * s / n + m12r * c,
		m11r * s / n + m12i * c
		m21r, m21i, m22r, m22i = m21r * c - m22i * n * s,
		m21i * c + m22r * n * s,
		-m21i * s / n + m22r * c,
		m21r * s / n + m22i * c
	end

	local br, bi = m11r + m12r * n_glass, m11i + m12i * n_glass
	local cr, ci = m21r + m22r * n_glass, m21i + m22i * n_glass
	local nr, ni = br - cr, bi - ci
	local dr, di = br + cr, bi + ci
	return (nr * nr + ni * ni) / (dr * dr + di * di)
end

local function interface_reflectance(n_a, n_b, layers, wavelength)
	if n_a ~= 1 and n_b ~= 1 then return ((n_a - n_b) / (n_a + n_b)) ^ 2 end

	return lens.GetCoatingReflectance(layers, math.max(n_a, n_b), wavelength)
end

local function mul(a, b)
	return {
		a[1] * b[1] + a[2] * b[3],
		a[1] * b[2] + a[2] * b[4],
		a[3] * b[1] + a[4] * b[3],
		a[3] * b[2] + a[4] * b[4],
	}
end

local function translate(m, d)
	return mul({1, d, 0, 1}, m)
end

local function power_matrix(m, c, d)
	return mul({1, 0, c, d}, m)
end

local function curvature_of(surface)
	return surface.radius == 0 and 0 or 1 / surface.radius
end

local function trace_path(built, channel, j, i)
	local surfaces = built.surfaces
	local n = built.indices[channel]
	local count = #surfaces
	local m = {1, 0, 0, 1}
	local offset_y, offset_u = {0, 0}, {0, 0}
	local after
	local events = {}
	local transmission = 1

	local function event(k)
		events[#events + 1] = {
			a = m[1],
			b = m[2],
			offset = {offset_y[1], offset_y[2]},
			radius = surfaces[k].semi,
			stop = surfaces[k].stop,
		}
	end

	local function apply_translate(d)
		m = translate(m, d)

		if after then after = translate(after, d) end

		offset_y[1], offset_y[2] = offset_y[1] + d * offset_u[1], offset_y[2] + d * offset_u[2]
	end

	local function apply_power(k, c, d)
		m = power_matrix(m, c, d)

		if after then after = power_matrix(after, c, d) end

		local center = surfaces[k].decenter
		offset_u[1] = c * (offset_y[1] - center[1]) + d * offset_u[1]
		offset_u[2] = c * (offset_y[2] - center[2]) + d * offset_u[2]
	end

	local function refract(k, c, d)
		event(k)
		apply_power(k, c, d)

		if not surfaces[k].stop and not surfaces[k].sensor then
			transmission = transmission * (1 - built.reflectance[k][channel])
		end
	end

	local function refract_forward(k)
		refract(k, (n[k - 1] - n[k]) * curvature_of(surfaces[k]) / n[k], n[k - 1] / n[k])
	end

	local function refract_backward(k)
		refract(k, (n[k - 1] - n[k]) * curvature_of(surfaces[k]) / n[k - 1], n[k] / n[k - 1])
	end

	if not j then
		for k = 1, count do
			refract_forward(k)

			if k < count then apply_translate(surfaces[k].thickness) end
		end

		local lens_matrix = m
		apply_translate(built.back_focus)
		return m, events, transmission, lens_matrix, offset_y
	end

	for k = 1, j - 1 do
		refract_forward(k)
		apply_translate(surfaces[k].thickness)
	end

	event(j)
	apply_power(j, 2 * curvature_of(surfaces[j]), 1)
	transmission = transmission * built.reflectance[j][channel]
	after = {1, 0, 0, 1}
	apply_translate(surfaces[j - 1].thickness)

	for k = j - 1, i + 1, -1 do
		refract_backward(k)
		apply_translate(surfaces[k - 1].thickness)
	end

	event(i)
	apply_power(i, -2 * curvature_of(surfaces[i]), 1)
	transmission = transmission * built.reflectance[i][channel]
	apply_translate(surfaces[i].thickness)

	for k = i + 1, count do
		refract_forward(k)

		if k < count then apply_translate(surfaces[k].thickness) end
	end

	apply_translate(built.back_focus)
	return m, events, transmission, after, offset_y
end

local function first_stop(events)
	for index, e in ipairs(events) do
		if e.stop then return index, e end
	end
end

local function build_disks(built, events, first_index, a1, b1)
	local disks = {}
	local u_max = math.tan(built.corner_angle)

	for index, e in ipairs(events) do
		local alpha = e.a / a1

		if index ~= first_index and math.abs(alpha) > 1e-6 then
			local beta = e.b - e.a * b1 / a1
			local center = -beta / alpha
			local factor = 1 / math.abs(alpha)
			local radius = e.stop and -factor or e.radius * factor
			local reach = e.stop and built.stop_radius * factor or radius
			local margin = reach - math.abs(center) * u_max - built.stop_radius

			if margin < 0 then
				disks[#disks + 1] = {center / built.focal_length, radius, margin = margin}
			end
		end
	end

	table.sort(disks, function(a, b)
		return a.margin < b.margin
	end)

	for index = lens.MAX_DISKS + 1, #disks do
		disks[index] = nil
	end

	for index = #disks + 1, lens.MAX_DISKS do
		disks[index] = {0, NO_DISK}
	end

	return disks
end

function lens.GetApertureRadius(angle, blades, curvature)
	if blades < 3 then return 1 end

	local sector = 2 * math.pi / blades
	local local_angle = angle % sector - sector / 2
	return (1 - curvature) * math.cos(sector / 2) / math.cos(local_angle) + curvature
end

function lens.GetApertureArea(blades, curvature)
	if blades < 3 then return math.pi end

	local half = math.pi / blades
	local apothem = math.cos(half)
	local secant_integral = math.log((1 + math.sin(half)) / apothem)
	return blades / 2 * (
			(
				1 - curvature
			) ^ 2 * apothem * apothem * 2 * math.tan(half) + 4 * curvature * (
				1 - curvature
			) * apothem * secant_integral
		) + curvature * curvature * math.pi
end

function lens.GetShapeArea(built, curvature)
	local straight = 1 - curvature
	return straight * straight * built.polygon_area + curvature * straight * built.polygon_perimeter_integral + curvature * curvature * math.pi
end

local function make_random(seed)
	local state = (seed * 2654435761) % 4294967296
	return function()
		state = (state * 1664525 + 1013904223) % 4294967296
		return state / 4294967296
	end
end

local function gaussian(random)
	return math.sqrt(-2 * math.log(math.max(random(), 1e-12))) * math.cos(2 * math.pi * random())
end

local function build_polygon(built, random, tolerance)
	local entries = lens.APERTURE_ENTRIES
	local polygon = ffi.new("float[?]", entries)
	local blades = built.blades
	local normals, apothems = {}, {}

	if blades >= 3 then
		local sector = 2 * math.pi / blades

		for k = 1, blades do
			normals[k] = built.rotation + (
					k - 0.5
				) * sector + gaussian(random) * math.rad(1.5) * tolerance
			apothems[k] = math.cos(sector / 2) * (1 + gaussian(random) * 0.02 * tolerance)
		end
	end

	local area, integral = 0, 0

	for e = 0, entries - 1 do
		local angle = (e + 0.5) / entries * 2 * math.pi
		local radius = 1

		if blades >= 3 then
			radius = math.huge

			for k = 1, blades do
				local c = math.cos(angle - normals[k])

				if c > 1e-3 then radius = math.min(radius, apothems[k] / c) end
			end
		end

		polygon[e] = radius
		area = area + 0.5 * radius * radius * 2 * math.pi / entries
		integral = integral + radius * 2 * math.pi / entries
	end

	built.polygon = polygon
	built.polygon_area = area
	built.polygon_perimeter_integral = integral
end

local function trace_real(built, channel, y, z, dy, dz)
	local surfaces = built.surfaces
	local n = built.indices[channel]
	local stop_y

	for k, s in ipairs(surfaces) do
		local t

		if s.radius == 0 then
			t = (s.z - z) / dz
		else
			local oy, oz = y, z - s.z - s.radius
			local b = oy * dy + oz * dz
			local disc = b * b - (oy * oy + oz * oz - s.radius * s.radius)

			if disc < 0 then return nil end

			t = s.radius > 0 and (-b - math.sqrt(disc)) or (-b + math.sqrt(disc))
		end

		y, z = y + t * dy, z + t * dz

		if s.stop then
			stop_y = y
		elseif n[k - 1] ~= n[k] then
			local ny, nz = 0, -1

			if s.radius ~= 0 then ny, nz = y / s.radius, (z - s.z - s.radius) / s.radius end

			local eta = n[k - 1] / n[k]
			local cos_i = -(dy * ny + dz * nz)
			local k2 = 1 - eta * eta * (1 - cos_i * cos_i)

			if k2 < 0 then return nil end

			local f = eta * cos_i - math.sqrt(k2)
			dy, dz = eta * dy + f * ny, eta * dz + f * nz
		end
	end

	local t = (built.sensor_z - z) / dz
	return y + t * dy, stop_y, dy / dz
end

local function find_chief_ray(built, u, guess)
	local dz = 1 / math.sqrt(1 + u * u)
	local dy = u * dz

	local function stop_height(h)
		local _, stop_y = trace_real(built, 2, h - u, -1, dy, dz)
		return stop_y
	end

	local h0, h1 = guess, guess + 0.01
	local g0, g1 = stop_height(h0), stop_height(h1)

	if not g0 or not g1 then return nil end

	for _ = 1, 20 do
		if math.abs(g1) < 1e-9 or g1 == g0 then break end

		h0, h1 = h1, h1 - g1 * (h1 - h0) / (g1 - g0)
		g0 = g1
		g1 = stop_height(h1)

		if not g1 then return nil end
	end

	return h1 - u, dy, dz, h1
end

local function trace_chief_rays(built, angle_max)
	local samples = 256
	local chief = {angles = {}, heights = {{}, {}, {}}, exit_slopes = {}, starts = {}}
	local guess, previous_u

	for i = 1, samples do
		local angle = i / samples * angle_max
		local u = math.tan(angle)
		local start, dy, dz, h = find_chief_ray(built, u, guess and guess * u / previous_u or -built.main_b1 * u / built.main_a1)

		if not start then break end

		local heights = {}
		local exit_slope

		for channel = 1, 3 do
			local height, _, slope = trace_real(built, channel, start, -1, dy, dz)
			heights[channel] = height

			if channel == 2 then exit_slope = slope end
		end

		if not heights[1] or not heights[2] or not heights[3] then break end

		chief.angles[#chief.angles + 1] = angle
		chief.exit_slopes[#chief.angles] = exit_slope
		chief.starts[#chief.angles] = h

		for channel = 1, 3 do
			chief.heights[channel][#chief.angles] = heights[channel]
		end

		guess, previous_u = h, u
	end

	return chief
end

local function chief_height_at(built, angle)
	local angles, heights = built.chief.angles, built.chief.heights[2]

	if angle <= angles[1] then
		return heights[1] * math.tan(angle) / math.tan(angles[1])
	end

	for i = 2, #angles do
		if angles[i] >= angle then
			return heights[i - 1] + (
					angle - angles[i - 1]
				) / (
					angles[i] - angles[i - 1]
				) * (
					heights[i] - heights[i - 1]
				)
		end
	end

	return heights[#angles] * math.tan(angle) / math.tan(angles[#angles])
end

local function chief_angle_at(built, height)
	local angles, heights = built.chief.angles, built.chief.heights[2]

	if height <= heights[1] then
		return math.atan(math.tan(angles[1]) * height / heights[1])
	end

	for i = 2, #angles do
		if heights[i] >= height then
			return angles[i - 1] + (
					height - heights[i - 1]
				) / (
					heights[i] - heights[i - 1]
				) * (
					angles[i] - angles[i - 1]
				)
		end
	end

	return math.atan(math.tan(angles[#angles]) * height / heights[#angles])
end

local function build_warp(built)
	local entries = lens.WARP_ENTRIES
	local corner = built.image_radius
	local chief = built.chief
	local ideal, actual = {}, chief.heights

	for i, angle in ipairs(chief.angles) do
		ideal[i] = built.focal_length * math.tan(angle)
	end

	local warp = ffi.new("float[?]", entries * 4)

	if #ideal < 2 then
		for i = 0, entries * 4 - 1 do
			warp[i] = 1
		end

		return warp
	end

	local function ratio_at(channel, radius)
		local heights = actual[channel]

		if radius <= heights[1] then return ideal[1] / heights[1] end

		for i = 2, #ideal do
			if heights[i] >= radius then
				local t = (radius - heights[i - 1]) / (heights[i] - heights[i - 1])
				return (ideal[i - 1] + t * (ideal[i] - ideal[i - 1])) / radius
			end
		end

		return ideal[#ideal] / heights[#ideal]
	end

	local normalize = ratio_at(2, corner)

	local function natural_at(radius)
		local heights = actual[2]
		local slope = chief.exit_slopes[#heights]

		for i = 1, #heights do
			if heights[i] >= radius then
				local t = i == 1 and 0 or (radius - heights[i - 1]) / (heights[i] - heights[i - 1])
				slope = i == 1 and
					chief.exit_slopes[1] * radius / heights[1] or
					chief.exit_slopes[i - 1] + t * (
						chief.exit_slopes[i] - chief.exit_slopes[i - 1]
					)

				break
			end
		end

		return 1 / (1 + slope * slope) ^ 2
	end

	for i = 0, entries - 1 do
		local radius = math.max(i / (entries - 1), 1e-3) * corner

		for channel = 1, 3 do
			warp[i * 4 + channel - 1] = ratio_at(channel, radius) / normalize
		end

		warp[i * 4 + 3] = natural_at(radius)
	end

	return warp
end

local grating = {}

do
	local sum = 0

	for order = -2, 2 do
		local x = order * 0.55
		grating[order] = x == 0 and 1 or (math.sin(math.pi * x) / (math.pi * x)) ^ 2
		sum = sum + grating[order]
	end

	for order = -2, 2 do
		grating[order] = grating[order] / sum
	end
end

local function rank_ghost(built, ghost)
	local size = math.max(math.abs(ghost.scale[2]) * built.stop_radius, 0.05)
	ghost.rank = math.max(ghost.energy[1], ghost.energy[2], ghost.energy[3]) / (size * size)
	return ghost
end

local function build_ghosts(built)
	local surfaces = built.surfaces
	local ghosts = {}

	for j = 2, #surfaces do
		for i = 1, j - 1 do
			if not surfaces[i].stop and not surfaces[j].stop then
				local ghost = {
					center = {},
					scale = {},
					energy = {},
					offset = {},
					after = {},
					surfaces = {i, j},
				}
				local valid = true

				for channel = 1, 3 do
					local m, events, transmission, after, offset = trace_path(built, channel, j, i)
					local first_index, first = first_stop(events)
					local a1, b1 = first.a, first.b

					if math.abs(a1) < 1e-9 then
						valid = false

						break
					end

					local center = (m[2] - m[1] * b1 / a1) / built.focal_length
					local main_offset = built.main_offset[channel]
					ghost.center[channel] = center
					ghost.scale[channel] = m[1] / a1
					ghost.energy[channel] = transmission
					ghost.after[channel] = after[2]
					ghost.offset[channel] = {
						offset[1] - m[1] / a1 * first.offset[1] - center * main_offset[1],
						offset[2] - m[1] / a1 * first.offset[2] - center * main_offset[2],
					}

					if channel == 2 then
						ghost.stop_a1, ghost.stop_b1 = a1, b1
						ghost.disks = build_disks(built, events, first_index, a1, b1)
					end
				end

				if valid and surfaces[j].sensor and built.sensor == "digital" then
					for mx = -2, 2 do
						for my = -2, 2 do
							local order = table.copy(ghost)
							order.energy, order.offset, order.order = {}, {}, mx ~= 0 or my ~= 0

							for channel = 1, 3 do
								local kick = ghost.after[channel] * eye_glare.CHANNEL_WAVELENGTH[channel] * 1e-6 / lens.SENSOR_PITCH
								order.energy[channel] = ghost.energy[channel] * grating[mx] * grating[my]
								order.offset[channel] = {ghost.offset[channel][1] + kick * mx, ghost.offset[channel][2] + kick * my}
							end

							ghosts[#ghosts + 1] = rank_ghost(built, order)
						end
					end
				elseif valid then
					ghosts[#ghosts + 1] = rank_ghost(built, ghost)
				end
			end
		end
	end

	table.sort(ghosts, function(a, b)
		return a.rank > b.rank
	end)

	for index = lens.MAX_GHOSTS + 1, #ghosts do
		ghosts[index] = nil
	end

	local data = ffi.new("float[?]", lens.GHOST_TEXELS * lens.MAX_GHOSTS * 4)

	for g, ghost in ipairs(ghosts) do
		local row = (g - 1) * lens.GHOST_TEXELS * 4

		for channel = 1, 3 do
			data[row + channel - 1] = ghost.center[channel]
			data[row + 4 + channel - 1] = ghost.scale[channel]
			data[row + 8 + channel - 1] = ghost.energy[channel]
		end

		for d, disk in ipairs(ghost.disks) do
			data[row + 12 + (d - 1) * 2] = disk[1]
			data[row + 12 + (d - 1) * 2 + 1] = disk[2]
		end

		data[row + 20] = ghost.surfaces[1]
		data[row + 21] = ghost.surfaces[2]
		data[row + 22] = ghost.stop_a1
		data[row + 23] = ghost.stop_b1
		data[row + 24] = -ghost.offset[1][1]
		data[row + 25] = -ghost.offset[1][2]
		data[row + 26] = -ghost.offset[2][1]
		data[row + 27] = -ghost.offset[2][2]
		data[row + 28] = -ghost.offset[3][1]
		data[row + 29] = -ghost.offset[3][2]
		data[row + 30] = ghost.order and 1 or 0
	end

	built.ghosts = ghosts
	built.ghost_data = data
end

local function update_media(built, layers)
	for channel = 1, 3 do
		local n = {[0] = 1}

		for k, surface in ipairs(built.surfaces) do
			n[k] = index_at(surface.n_d, surface.abbe, eye_glare.CHANNEL_WAVELENGTH[channel])
		end

		built.indices[channel] = n
	end

	for k, surface in ipairs(built.surfaces) do
		local before = built.surfaces[k - 1]
		built.reflectance[k] = {}

		for channel, band in ipairs(CHANNEL_BANDS) do
			local sum = 0

			for _, wavelength in ipairs(band) do
				sum = sum + interface_reflectance(
						before and index_at(before.n_d, before.abbe, wavelength) or 1,
						index_at(surface.n_d, surface.abbe, wavelength),
						surface.layers or (before and before.layers) or layers,
						wavelength
					)
			end

			built.reflectance[k][channel] = surface.sensor and
				lens.SENSOR_REFLECTANCE[built.sensor] or
				surface.stop and
				0 or
				sum / #band
		end
	end
end

local function flat_surface(thickness, n_d, abbe, semi, extra)
	local surface = {
		radius = 0,
		thickness = thickness,
		n_d = n_d,
		abbe = abbe,
		semi = semi,
		decenter = {0, 0},
	}

	for k, v in pairs(extra or {}) do
		surface[k] = v
	end

	return surface
end

function lens.BuildOptics(design, options)
	local nominal = design.focal_length
	local built = {
		name = design.name,
		coating = options.coating,
		sensor = options.sensor,
		surfaces = {},
		indices = {},
		reflectance = {},
		main = {},
		main_offset = {},
		back_focus = 0,
	}
	local layers = lens.coatings[options.coating]
	local surfaces = built.surfaces

	for k, s in ipairs(design.surfaces) do
		surfaces[k] = {
			radius = s[1],
			thickness = s[2],
			n_d = s[3],
			abbe = s[4],
			semi = s[5] / 2,
			stop = s.stop,
			decenter = {0, 0},
		}
	end

	update_media(built, layers)
	local _, _, _, raw = trace_path(built, 2)
	local scale = nominal / (-1 / raw[3])
	built.prescription_scale = scale

	for _, surface in ipairs(surfaces) do
		surface.radius = surface.radius * scale
		surface.thickness = surface.thickness * scale
		surface.semi = surface.semi * scale
	end

	local function back_focus()
		local _, _, _, m = trace_path(built, 2)
		return -m[1] / m[3]
	end

	local image_semi = 2 * (
			design.coverage and
			nominal * math.tan(math.rad(design.coverage))
			or
			lens.SENSOR_DIAGONAL / 2
		)

	if options.sensor == "digital" then
		surfaces[#surfaces].thickness = back_focus() - lens.FILTER_THICKNESS - lens.FILTER_GAP
		surfaces[#surfaces + 1] = flat_surface(lens.FILTER_THICKNESS, 1.5168, 64.17, image_semi, {layers = lens.coatings.multi})
		surfaces[#surfaces + 1] = flat_surface(0, 1, 0, image_semi, {layers = lens.coatings.multi})
		update_media(built, layers)
	end

	surfaces[#surfaces].thickness = back_focus()
	surfaces[#surfaces + 1] = flat_surface(0, 1, 0, image_semi, {sensor = true})
	update_media(built, layers)

	if options.tolerance > 0 then
		local random = make_random(options.seed)
		local group = {0, 0}

		for k, surface in ipairs(surfaces) do
			local before = surfaces[k - 1]
			local before_glass = before and before.n_d ~= 1

			if not surface.layers and not surface.sensor and not surface.stop then
				if not before_glass and surface.n_d ~= 1 then
					group = {
						gaussian(random) * lens.DECENTER * options.tolerance,
						gaussian(random) * lens.DECENTER * options.tolerance,
					}
				end

				if before_glass or surface.n_d ~= 1 then surface.decenter = group end
			end
		end
	end

	built.focus_shift = {}

	for channel = 1, 3 do
		local _, _, _, m, offset = trace_path(built, channel)
		built.main[channel] = {focal_length = -1 / m[3]}
		built.main_offset[channel] = offset
		built.focus_shift[channel] = -m[1] / m[3]
	end

	local green_focus = built.focus_shift[2]

	for channel = 1, 3 do
		built.focus_shift[channel] = built.focus_shift[channel] - green_focus
	end

	built.focal_length = built.main[2].focal_length

	if design.f_number then
		local _, events = trace_path(built, 2)
		local _, first = first_stop(events)

		for _, surface in ipairs(surfaces) do
			if surface.stop then
				surface.semi = math.abs(first.a) * built.focal_length / (2 * design.f_number)
			end
		end
	end

	local _, events = trace_path(built, 2)
	local first_index, first = first_stop(events)
	built.main_a1, built.main_b1 = first.a, first.b
	built.stop_radius = first.radius
	built.stop_scale = math.abs(first.a)
	built.aperture_min = built.stop_scale * built.focal_length / (2 * built.stop_radius)
	built.fixed_aperture = design.fixed_aperture
	built.aperture_max = design.fixed_aperture and built.aperture_min or lens.APERTURE_MAX
	local z = 0

	for _, surface in ipairs(surfaces) do
		surface.z = z
		z = z + surface.thickness
	end

	built.sensor_z = surfaces[#surfaces].z
	local coverage = design.coverage and
		math.rad(design.coverage) or
		math.atan(lens.SENSOR_DIAGONAL / 2 / built.focal_length)
	built.chief = trace_chief_rays(built, math.min(coverage * 1.2, math.rad(88)))
	built.image_radius = design.coverage and chief_height_at(built, coverage) or lens.SENSOR_DIAGONAL / 2
	built.corner_angle = coverage
	built.ideal_radius = built.focal_length * math.tan(coverage)
	built.main_disks = build_disks(built, events, first_index, first.a, first.b)
	local count = #surfaces
	local table_data = ffi.new("float[?]", 3 * (count + 1) * 4)

	for k, surface in ipairs(surfaces) do
		local row = (k - 1) * 12
		local before = k == 1 and 1 or surfaces[k - 1].n_d
		table_data[row] = surface.radius
		table_data[row + 1] = surface.z
		table_data[row + 2] = surface.semi
		table_data[row + 3] = surface.sensor and 2 or surface.stop and 1 or 0

		for channel = 1, 3 do
			table_data[row + 3 + channel] = surface.sensor and built.reflectance[k][channel] or built.indices[channel][k]
		end

		table_data[row + 7] = not surface.sensor and (before == 1) ~= (surface.n_d == 1) and 1 or 0
		table_data[row + 8] = surface.decenter[1]
		table_data[row + 9] = surface.decenter[2]
	end

	for l, layer in ipairs(layers) do
		table_data[count * 12 + (l - 1) * 2] = layer[1]
		table_data[count * 12 + (l - 1) * 2 + 1] = layer[2]
	end

	table_data[count * 12 + 7] = #layers
	table_data[count * 12 + 8] = built.main_offset[2][1]
	table_data[count * 12 + 9] = built.main_offset[2][2]
	built.table_data = table_data
	built.table_height = count + 1
	build_ghosts(built)
	built.warp = build_warp(built)
	built.vignette_chief = ffi.new("float[?]", lens.VIGNETTE_FIELDS)

	for fi = 0, lens.VIGNETTE_FIELDS - 1 do
		local angle = math.atan(fi / (lens.VIGNETTE_FIELDS - 1) * math.tan(built.corner_angle))
		local angles, starts = built.chief.angles, built.chief.starts
		local value = starts[#starts] * math.tan(angle) / math.tan(angles[#angles])

		for i = 1, #angles do
			if angles[i] >= angle then
				value = i == 1 and
					starts[1] * math.tan(angle) / math.tan(angles[1])
					or
					starts[i - 1] + (
						angle - angles[i - 1]
					) / (
						angles[i] - angles[i - 1]
					) * (
						starts[i] - starts[i - 1]
					)

				break
			end
		end

		built.vignette_chief[fi] = value
	end

	return built
end

function lens.BuildAperture(optics, options)
	local built = setmetatable(
		{
			blades = options.blades,
			curvature = options.curvature,
			rotation = math.rad(options.rotation),
			aperture_key = options.blades .. "/" .. options.curvature .. "/" .. options.rotation .. "/" .. options.tolerance .. "/" .. options.seed,
		},
		{__index = optics}
	)
	build_polygon(built, make_random(options.seed + 104729), options.tolerance)
	return built
end

function lens.Build(design, options)
	return lens.BuildAperture(lens.BuildOptics(design, options), options)
end

do
	local optics, optics_key
	local cached, cached_key

	function lens.GetBuilt()
		if not lens.IsActive() then return nil end

		local options = {
			coating = state["lens.coating"],
			blades = state["lens.blades"],
			curvature = state["lens.blade_curvature"],
			rotation = state["lens.blade_rotation"],
			sensor = state["lens.sensor"],
			tolerance = state["lens.tolerance"],
			seed = state["lens.seed"],
		}
		local key = table.concat(
			{
				state["lens.design"],
				options.coating,
				options.sensor,
				options.tolerance,
				options.seed,
			},
			"/"
		)

		if key ~= optics_key then
			optics = lens.BuildOptics(lens.designs[state["lens.design"]], options)
			optics_key = key
			cached_key = nil
		end

		key = key .. "/" .. options.blades .. "/" .. options.curvature .. "/" .. options.rotation

		if key ~= cached_key then
			cached = lens.BuildAperture(optics, options)
			cached_key = key
		end

		return cached
	end
end

function lens.GetFrameHalfHeight(built, width, height)
	return built.ideal_radius * height / math.sqrt(width * width + height * height)
end

function lens.GetFocalLengthForFOV(built, fov, width, height)
	local corner = math.atan(math.tan(fov / 2) * math.sqrt(width * width + height * height) / height)
	return built.focal_length * built.image_radius / chief_height_at(built, corner)
end

function lens.GetFOVForFocalLength(built, focal_length, width, height)
	local corner = chief_angle_at(built, built.image_radius * built.focal_length / focal_length)
	return 2 * math.atan(math.tan(corner) * height / math.sqrt(width * width + height * height))
end

function lens.GetApertureMin()
	local built = lens.GetBuilt()
	return built and built.aperture_min
end

function lens.GetApertureMax()
	local built = lens.GetBuilt()
	return built and built.fixed_aperture and built.aperture_max
end

commands.Add("lens=string", function(name)
	lens.SetPreset(name)
end)

function lens.BuildDirtPrimitives(seed, dust, scratches)
	local grid = eye_psf.GRID
	local spacing = eye_psf.SAMPLE_SPACING
	local size = grid * spacing
	local random = make_random(seed + 7919)
	local primitives = {}
	local r_min, r_max, exponent = 3e-6, 40e-6, -2.5
	local a, b = r_min ^ (exponent + 1), r_max ^ (exponent + 1)
	local mean_area = math.pi * (
			exponent + 1
		) / (
			exponent + 3
		) * (
			r_max ^ (
				exponent + 3
			) - r_min ^ (
				exponent + 3
			)
		) / (
			b - a
		)

	for _ = 1, math.floor(dust * size * size / mean_area + 0.5) do
		local radius = (a + random() * (b - a)) ^ (1 / (exponent + 1))
		primitives[#primitives + 1] = {0, random() * grid, random() * grid, radius / spacing, 0, 0, 0, 0}
	end

	for _ = 1, math.floor(scratches * size * size * 1e4 + random()) do
		local angle = random() * math.pi
		primitives[#primitives + 1] = {
			1,
			random() * grid,
			random() * grid,
			(
				0.3e-3 + random() ^ 2 * 2.7e-3
			) / spacing,
			math.cos(angle),
			math.sin(angle),
			(
				3e-6 + random() * 7e-6
			) / spacing,
			0.3,
		}
	end

	local data = ffi.new("float[?]", math.max(#primitives, 1) * 8)

	for i, primitive in ipairs(primitives) do
		for k = 1, 8 do
			data[(i - 1) * 8 + k - 1] = primitive[k]
		end
	end

	return data, #primitives
end

function lens.GetStarAnchorDegrees()
	return 0.8 * eye_psf.GetMaxDegrees()
end

lens.block = {
	{"lens_aperture_tex", "int"},
	{"lens_main_a1", "float"},
	{"lens_corner_tan", "float"},
	{"lens_aperture_area", "float"},
	{"lens_aperture_integral", "float"},
	{"lens_curvature", "float"},
	{"lens_aperture_min", "float"},
	{"lens_aperture_max", "float"},
	{"lens_focal", "float"},
	{"lens_effective_focal", "float"},
	{"lens_stop_scale", "float"},
	{"lens_image_radius", "float"},
	{"lens_actual_radius", "float"},
	{"lens_sensor_z", "float"},
	{"lens_ghost_count", "int"},
	{"lens_main_disks0", "vec4"},
	{"lens_main_disks1", "vec4"},
}

function lens.WriteBlock(block, built, aperture_texture_index)
	block.lens_aperture_tex = aperture_texture_index
	block.lens_main_a1 = built.main_a1
	block.lens_corner_tan = math.tan(built.corner_angle)
	block.lens_aperture_area = built.polygon_area
	block.lens_aperture_integral = built.polygon_perimeter_integral
	block.lens_curvature = built.curvature
	block.lens_aperture_min = built.aperture_min
	block.lens_aperture_max = built.aperture_max
	block.lens_focal = built.focal_length
	block.lens_stop_scale = built.stop_scale
	block.lens_image_radius = built.ideal_radius
	block.lens_actual_radius = built.image_radius
	block.lens_sensor_z = built.sensor_z
	block.lens_ghost_count = #built.ghosts

	for d, disk in ipairs(built.main_disks) do
		local field = d <= 2 and block.lens_main_disks0 or block.lens_main_disks1
		field[(d - 1) % 2 * 2] = disk[1]
		field[(d - 1) % 2 * 2 + 1] = disk[2]
	end

	return block
end

function lens.GetGLSL(b)
	return [[
		const float LENS_APERTURE_MAX = ]] .. string.format("%.1f", lens.APERTURE_MAX) .. [[;

		float lens_aperture_radius(float angle, float curvature) {
			float polygon = texture(TEXTURE(]] .. b .. [[.lens_aperture_tex), vec2(angle / 6.2831853, 0.5)).r;
			return mix(polygon, 1.0, curvature);
		}

		float lens_aperture_area(float curvature) {
			float straight = 1.0 - curvature;
			return straight * straight * ]] .. b .. [[.lens_aperture_area + curvature * straight * ]] .. b .. [[.lens_aperture_integral + curvature * curvature * 3.14159265;
		}

		float lens_aperture(float n) {
			return clamp(n, ]] .. b .. [[.lens_aperture_min, ]] .. b .. [[.lens_aperture_max);
		}

		float lens_curvature_at(float n) {
			float open = clamp(1.0 - log2(lens_aperture(n) / ]] .. b .. [[.lens_aperture_min) / ]] .. string.format("%.3f", lens.OPENING_STOPS) .. [[, 0.0, 1.0);
			return mix(]] .. b .. [[.lens_curvature, 1.0, open);
		}

		float lens_stop_radius(float n) {
			return ]] .. b .. [[.lens_stop_scale * ]] .. b .. [[.lens_focal / (2.0 * lens_aperture(n));
		}

		float lens_shape_distance(vec2 q, float curvature) {
			float scale = sqrt(3.14159265 / lens_aperture_area(curvature));
			return length(q) - scale * lens_aperture_radius(atan(q.y, q.x), curvature);
		}

		float lens_disk_distance(vec2 q, vec2 field_mm, vec2 disk, float stop_radius) {
			float radius = disk.y < 0.0 ? -disk.y : disk.y / stop_radius;
			return length(q - disk.x * field_mm / stop_radius) - radius;
		}

		float lens_bokeh_distance(vec2 q, vec2 field_mm, float n) {
			float stop_radius = lens_stop_radius(n);
			float d = lens_shape_distance(q, lens_curvature_at(n));
			d = max(d, lens_disk_distance(q, field_mm, ]] .. b .. [[.lens_main_disks0.xy, stop_radius));
			d = max(d, lens_disk_distance(q, field_mm, ]] .. b .. [[.lens_main_disks0.zw, stop_radius));
			d = max(d, lens_disk_distance(q, field_mm, ]] .. b .. [[.lens_main_disks1.xy, stop_radius));
			d = max(d, lens_disk_distance(q, field_mm, ]] .. b .. [[.lens_main_disks1.zw, stop_radius));
			return d;
		}
	]]
end

return lens
