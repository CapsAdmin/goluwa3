local AABB = import("goluwa/structs/aabb.lua")
local visual_bounds = {}
local animated_box = AABB(0, 0, 0, 0, 0, 0)

local function expand(out, box)
	if not box or box.min_x > box.max_x then return end

	if box.min_x < out.min_x then out.min_x = box.min_x end

	if box.min_y < out.min_y then out.min_y = box.min_y end

	if box.min_z < out.min_z then out.min_z = box.min_z end

	if box.max_x > out.max_x then out.max_x = box.max_x end

	if box.max_y > out.max_y then out.max_y = box.max_y end

	if box.max_z > out.max_z then out.max_z = box.max_z end
end

local function expand_entity(out, entity, core)
	local animator = entity.animator

	if animator and animator.rig then
		expand(out, animator:GetWorldAABB(animated_box, core))
	elseif not core and entity.visual and entity.visual.Visible then
		expand(out, entity.visual:GetWorldAABB())
	end
end

local function build(entity, out, core)
	out = out or AABB(0, 0, 0, 0, 0, 0)
	out.min_x, out.min_y, out.min_z = math.huge, math.huge, math.huge
	out.max_x, out.max_y, out.max_z = -math.huge, -math.huge, -math.huge
	expand_entity(out, entity, core)

	for _, child in ipairs(entity:GetChildrenList()) do
		expand_entity(out, child, core)
	end

	if out.min_x > out.max_x then return nil end

	return out
end

function visual_bounds.Get(entity, out)
	return build(entity, out, false)
end

function visual_bounds.GetCore(entity, out)
	return build(entity, out, true)
end

return visual_bounds
