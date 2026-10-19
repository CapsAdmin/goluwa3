-- what the main cull drew in each measured view: rows, triangles, and the biggest rows by triangles
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local commands = import("goluwa/cli/commands.lua")
function _G.MP_REPORT()
	local opaque, translucent = scene_draw.ReadBackCull(0), scene_draw.ReadBackCull(1)
	local function triangles(result)
		local total = 0
		for _, entry in pairs(result.by_id) do total = total + entry.index_count / 3 end
		return total
	end
	print(string.format("MP   cull: opaque %d rows (%d tris)  translucent %d rows (%d tris) of %d slots", opaque.count, triangles(opaque), translucent.count, triangles(translucent), opaque.slots))
	commands.RunString("scene_draw_dump " .. (os.getenv("MP_DUMP") or "12"))
end
