-- close ups of foliage under a low sun from the left, to see the normal maps and the roughness: NORMALS=0 turns the
-- normal maps off (r_normal_map_strength), ROUGHNESS=flat gives every foliage material its RoughnessMultiplier instead
-- of its roughness map
-- NORMALS=0 test/harnesses/foliage/shot.sh ... with --setup test/harnesses/foliage/maps_ab.lua, see maps_ab.sh
local pvars = import("goluwa/cli/pvars.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local foliage = import("lua/foliage/foliage.lua")

if os.getenv("NORMALS") == "0" then pvars.SetSession("r_normal_map_strength", 0) end

if os.getenv("ROUGHNESS") == "flat" then
	for name in pairs(foliage.materials) do
		foliage.GetMaterial(name):SetRoughnessTexture(nil)
	end
end

weather.SetSunDirection(Vec3(-1, 0.3, 0.25):GetNormalized())
import("test/harnesses/foliage/scene.lua")
