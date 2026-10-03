-- glw: --3d
-- sun and local shadow maps on, off and on again, from the same view on gm_construct
local commands = import("goluwa/cli/commands.lua")
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local raycast = import("goluwa/physics/raycast.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function set_shadows(enabled)
	return function()
		for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
			shadow_map:SetEnabled(enabled)
		end
	end
end

frame_benchmark.Run{
	name = "gm_construct shadows",
	load = function()
		commands.RunString("map gm_construct")
	end,
	view = function()
		local hit = raycast.CastClosest(Vec3(0, 60, 0), Vec3(0, -1, 0), 200)
		return Vec3(0, (hit and hit.position.y or 0) + 1.7, 0), -5, 0
	end,
	phases = {
		{name = "shadows on", enter = set_shadows(true)},
		{name = "shadows off", enter = set_shadows(false)},
		{name = "shadows on again", enter = set_shadows(true)},
	},
}
