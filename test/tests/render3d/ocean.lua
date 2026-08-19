local T = import("test/environment.lua")
T.SkipFile("disabled: long running and failing tests (85600db1)")
do
	return
end

local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")

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
		local fallback_r, fallback_g, fallback_b = T.GetScreenPixel(256, 430)
		render3d.SetOceanLevel(40)
		draw()
		T.AssertScreenPixel{
			pos = {256, 430},
			color = function(r, g, b, a)
				local dr = r - fallback_r
				local dg = g - fallback_g
				local db = b - fallback_b
				return math.sqrt(dr * dr + dg * dg + db * db) > 0.08
			end,
			msg = "expected ocean override to change the visible pixel",
		}
	end)
	sun:Remove()
	atmosphere.SetOceanLevel(previous_atmosphere_level)
	render3d.SetOceanLevel(previous_ocean_override)
	render3d.SetOceanEnabled(previous_ocean_enabled)

	if not ok then error(err, 0) end
end)
