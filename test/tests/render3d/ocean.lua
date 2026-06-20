local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")

local function get_screen_pixel(x, y)
	local r, g, b, a = render.target:GetTexture():GetPixel(x, y)
	return {r / 255, g / 255, b / 255, a / 255}
end

local function color_distance(a, b)
	local dr = a[1] - b[1]
	local dg = a[2] - b[2]
	local db = a[3] - b[3]
	return math.sqrt(dr * dr + dg * dg + db * db)
end

T.Test("Render3D ocean level resolves override then atmosphere default", function()
	local previous_atmosphere_level = atmosphere.GetOceanLevel()
	local previous_ocean_override = render3d.GetOceanLevelOverride()
	local ok, err = pcall(function()
		atmosphere.SetOceanLevel(12.5)
		render3d.SetOceanLevel(nil)
		T(render3d.GetOceanLevel())["=="](12.5)
		render3d.SetOceanLevel(-4)
		T(render3d.GetOceanLevel())["=="](-4)
	end)
	atmosphere.SetOceanLevel(previous_atmosphere_level)
	render3d.SetOceanLevel(previous_ocean_override)

	if not ok then error(err, 0) end
end)

T.Test3D("Render3D ocean level override changes visible waterline", function(draw)
	local previous_atmosphere_level = atmosphere.GetOceanLevel()
	local previous_ocean_override = render3d.GetOceanLevelOverride()
	local previous_ocean_enabled = render3d.IsOceanEnabled()
	local sun = Entity.New{
		transform = {
			Rotation = Quat():SetAngles(Deg3(35, 180, 0)),
		},
		light = {
			LightType = "sun",
			Color = Color(1, 1, 1),
			Intensity = 1,
		},
	}
	local ok, err = pcall(function()
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 20, 20))
		cam:SetRotation(Quat():Identity())
		cam:SetFOV(math.rad(70))
		cam:SetNearZ(0.1)
		cam:SetFarZ(1000)
		atmosphere.SetOceanLevel(0)
		render3d.SetOceanEnabled(true)
		render3d.SetOceanLevel(nil)
		draw()
		local fallback_pixel = get_screen_pixel(256, 430)
		render3d.SetOceanLevel(40)
		draw()
		local override_pixel = get_screen_pixel(256, 430)
		assert(
			color_distance(fallback_pixel, override_pixel) > 0.08,
			string.format(
				"expected ocean override to change the visible pixel, got fallback=(%.3f, %.3f, %.3f) override=(%.3f, %.3f, %.3f)",
				fallback_pixel[1],
				fallback_pixel[2],
				fallback_pixel[3],
				override_pixel[1],
				override_pixel[2],
				override_pixel[3]
			)
		)
	end)
	sun:Remove()
	atmosphere.SetOceanLevel(previous_atmosphere_level)
	render3d.SetOceanLevel(previous_ocean_override)
	render3d.SetOceanEnabled(previous_ocean_enabled)

	if not ok then error(err, 0) end
end)
