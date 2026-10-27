local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local trace_debug = {enabled = false, last = table.weak("k")}

function trace_debug.Record(player, kind, origin, hit_position, entity)
	if not trace_debug.enabled then return end

	local records = trace_debug.last[player]

	if not records then
		records = {}
		trace_debug.last[player] = records
	end

	local record = records[kind]

	if not record then
		record = {origin = Vec3(), hit = Vec3()}
		records[kind] = record
	end

	record.origin:Set(origin.x, origin.y, origin.z)
	record.has_hit = hit_position ~= nil

	if hit_position then
		record.hit:Set(hit_position.x, hit_position.y, hit_position.z)
	end

	record.entity = entity and entity:IsValid() and entity:GetName() or ""
	record.time = system.GetTime()
end

return trace_debug
