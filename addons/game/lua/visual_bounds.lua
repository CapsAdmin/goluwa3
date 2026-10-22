local AABB = import("goluwa/structs/aabb.lua")
local visual_bounds = {}

local function expand(out, entity)
	local visual = entity.visual

	if not visual then return end

	local box = visual:GetWorldAABB()

	if not box or box.min_x > box.max_x then return end

	if box.min_x < out.min_x then out.min_x = box.min_x end

	if box.min_y < out.min_y then out.min_y = box.min_y end

	if box.min_z < out.min_z then out.min_z = box.min_z end

	if box.max_x > out.max_x then out.max_x = box.max_x end

	if box.max_y > out.max_y then out.max_y = box.max_y end

	if box.max_z > out.max_z then out.max_z = box.max_z end
end

function visual_bounds.Get(entity, out)
	out = out or AABB(0, 0, 0, 0, 0, 0)
	out.min_x, out.min_y, out.min_z = math.huge, math.huge, math.huge
	out.max_x, out.max_y, out.max_z = -math.huge, -math.huge, -math.huge
	expand(out, entity)

	for _, child in ipairs(entity:GetChildrenList()) do
		expand(out, child)
	end

	if out.min_x > out.max_x then return nil end

	return out
end

return visual_bounds
