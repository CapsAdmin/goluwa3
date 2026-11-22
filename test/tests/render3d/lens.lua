local T = import("test/environment.lua")
local lens = import("goluwa/render3d/lens.lua")

local function build(design, coating, extra)
	local options = {
		coating = coating or "multi",
		blades = 6,
		curvature = 0,
		rotation = 90,
		sensor = "digital",
		tolerance = 0,
		seed = 1,
	}

	for k, v in pairs(extra or {}) do
		options[k] = v
	end

	return lens.Build(lens.designs[design], options)
end

T.Test("Graphics render3d lens prescriptions image at their nominal focal length", function()
	for _, design in ipairs(lens.designs) do
		local built = build(design.name)
		T(built.prescription_scale)["~"](1, 0.04)
		T(built.focal_length)["~"](design.focal_length, 1e-6)
		T(built.surfaces[#built.surfaces - 1].thickness > 0)["=="](true)
		T(built.surfaces[#built.surfaces].sensor)["=="](true)
		T(built.aperture_min > 1.5 and built.aperture_min < 5)["=="](true)
	end

	T(build("double_gauss").aperture_min)["~"](2, 0.1)
end)

T.Test("Graphics render3d lens coatings reflect like thin films", function()
	local n = 1.52
	local quarter_wave = ((1.38 * 1.38 - n) / (1.38 * 1.38 + n)) ^ 2
	T(lens.GetCoatingReflectance(lens.coatings.none, n, 550))["~"](((n - 1) / (n + 1)) ^ 2, 1e-9)
	T(lens.GetCoatingReflectance(lens.coatings.single, n, 550))["~"](quarter_wave, 1e-9)
	T(lens.GetCoatingReflectance(lens.coatings.single, n, 450) > quarter_wave)["=="](true)
	T(lens.GetCoatingReflectance(lens.coatings.multi, n, 550) < quarter_wave / 4)["=="](true)
end)

T.Test("Graphics render3d lens aperture area matches the shape it describes", function()
	for _, case in ipairs{{0, 1}, {5, 0}, {6, 0.4}, {9, 0.6}, {3, 0}} do
		local blades, curvature = case[1], case[2]
		local inside, grid = 0, 400

		for y = 0, grid - 1 do
			for x = 0, grid - 1 do
				local px, py = (x + 0.5) / grid * 2 - 1, (y + 0.5) / grid * 2 - 1

				if
					math.sqrt(px * px + py * py) <= lens.GetApertureRadius(math.atan2(py, px), blades, curvature)
				then
					inside = inside + 1
				end
			end
		end

		T(inside / (grid * grid) * 4)["~"](lens.GetApertureArea(blades, curvature), 0.01)
	end
end)

T.Test("Graphics render3d lens ghosts and distortion from the prescription", function()
	local coated = build("double_gauss", "multi")
	local uncoated = build("double_gauss", "none")
	T(#coated.ghosts > 10)["=="](true)
	T(uncoated.ghosts[1].energy[2] > coated.ghosts[1].energy[2] * 10)["=="](true)

	for i = 2, #coated.ghosts do
		T(coated.ghosts[i - 1].rank >= coated.ghosts[i].rank)["=="](true)
	end

	local corner = (lens.WARP_ENTRIES - 1) * 4
	T(coated.warp[corner + 1])["~"](1, 1e-6)
	T(coated.warp[1])["~"](1, 0.05)
end)

T.Test("Graphics render3d lens presets set known settings and build", function()
	for name in pairs(lens.presets) do
		lens.SetPreset(name)
		T(lens.GetPreset())["=="](name)
		T(lens.IsActive())["=="](name ~= "none")

		if name ~= "none" then T(lens.GetBuilt() ~= nil)["=="](true) end
	end

	lens.Set("lens.blades", 7)
	T(lens.GetPreset())["=="](nil)
	T(pcall(lens.Set, "lens.design", "pinhole"))["=="](false)
	T(pcall(lens.Set, "lens.blades", "seven"))["=="](false)
	lens.SetPreset("none")
end)

T.Test("Graphics render3d lens sensor reflections and manufacturing tolerances", function()
	local digital = build("double_gauss", "multi")
	local film = build("double_gauss", "multi", {sensor = "film"})
	local orders, sensor_ghosts = 0, 0

	for _, ghost in ipairs(digital.ghosts) do
		if digital.surfaces[ghost.surfaces[2]].sensor then
			sensor_ghosts = sensor_ghosts + 1
		end

		if ghost.order then orders = orders + 1 end
	end

	T(sensor_ghosts > 0)["=="](true)
	T(orders > 0)["=="](true)

	for _, ghost in ipairs(film.ghosts) do
		T(ghost.order)["=="](nil)
	end

	local ideal = build("double_gauss", "multi", {sensor = "film"})
	local worn = build("double_gauss", "multi", {sensor = "film", tolerance = 1, seed = 3})
	local ideal_offset, worn_offset = 0, 0

	for _, ghost in ipairs(ideal.ghosts) do
		ideal_offset = math.max(ideal_offset, math.abs(ghost.offset[2][1]), math.abs(ghost.offset[2][2]))
	end

	for _, ghost in ipairs(worn.ghosts) do
		worn_offset = math.max(worn_offset, math.abs(ghost.offset[2][1]), math.abs(ghost.offset[2][2]))
	end

	T(ideal_offset < 1e-9)["=="](true)
	T(worn_offset > 1e-3)["=="](true)
	T(ideal.polygon_area)["~"](lens.GetApertureArea(6, 0), 0.01)
	T(worn.polygon_area ~= ideal.polygon_area)["=="](true)
	T(lens.GetShapeArea(worn, 1))["~"](math.pi, 1e-9)
end)

T.Test("Graphics render3d lens field of view and focal length describe the same frame", function()
	local built = build("double_gauss", "multi", {sensor = "film"})
	local fov = lens.GetFOVForFocalLength(built, 50, 1920, 1080)
	local rectilinear = 2 * math.atan(lens.SENSOR_DIAGONAL / 2 * 1080 / math.sqrt(1920 ^ 2 + 1080 ^ 2) / 50)
	T(math.deg(fov))["~"](math.deg(rectilinear), 0.5)
	T(lens.GetFocalLengthForFOV(built, fov, 1920, 1080))["~"](50, 1e-6)
	T(lens.GetFOVForFocalLength(built, 200, 1920, 1080) < fov)["=="](true)
	local action = build("action_camera", "multi")
	T(math.deg(action.chief.angles[#action.chief.angles]) > 70)["=="](true)
	T(action.ideal_radius > action.image_radius * 1.5)["=="](true)
	T(action.warp[1] < 0.7)["=="](true)
	T(action.aperture_max)["=="](action.aperture_min)
	T(action.aperture_min)["~"](2.8, 1e-6)
end)

T.Test("Graphics render3d lens aperture knobs keep the optics", function()
	lens.SetPreset("modern_50")
	local first = lens.GetBuilt()
	lens.Set("lens.blade_curvature", 0.2)
	local second = lens.GetBuilt()
	T(first ~= second)["=="](true)
	T(first.ghosts == second.ghosts)["=="](true)
	T(first.polygon ~= second.polygon)["=="](true)
	lens.Set("lens.coating", "none")
	T(lens.GetBuilt().ghosts ~= second.ghosts)["=="](true)
	lens.SetPreset("none")
end)
