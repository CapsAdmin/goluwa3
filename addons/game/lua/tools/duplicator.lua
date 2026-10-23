local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
local scene = import("goluwa/entities/scene.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local UP = Vec3(0, 1, 0)

local function get_yaw(forward)
	return math.atan2(-forward.x, -forward.z)
end

return toolgun.Register{
	Name = "duplicator",
	DisplayName = "Duplicator",
	Category = "Construction",
	Description = "Copies an object together with everything constrained to it and pastes copies of it.",
	Instructions = {
		Left = "paste the copy",
		Right = "copy an object and everything constrained to it",
		Reload = "clear the copy",
	},
	LeftClick = function(context, trace)
		local clipboard = context.clipboard

		if not clipboard then return false end

		local data = scene.Decode(clipboard.payload)
		local rotation = QuatFromAxis(get_yaw(trace.forward) - clipboard.yaw, UP)
		local origin = trace.position

		for _, record in ipairs(data.entities) do
			if not record.parent then
				local transform = record.components.transform

				if transform then
					transform.Position = origin + rotation:VecMul((transform.Position or Vec3()) - clipboard.origin)
					transform.Rotation = rotation * (transform.Rotation or Quat():Identity())
				end

				local constraint = record.components.constraint

				if constraint and (constraint.Entity1 or "") == "" then
					constraint.Anchor1 = origin + rotation:VecMul((constraint.Anchor1 or Vec3()) - clipboard.origin)
				end
			end
		end

		local roots, spawned = scene.Deserialize(data, Entity.World, {regenerate_guids = true})
		local client = toolgun.GetClient(context:GetPlayer())
		local entries = {}

		for _, root in ipairs(roots) do
			local constraint = root.constraint

			if constraint then
				constraint:SetEntity0(spawned[constraint.Entity0]:GetGUID())

				if constraint.Entity1 ~= "" then
					constraint:SetEntity1(spawned[constraint.Entity1]:GetGUID())
				end
			end

			root:SetOwnedBy(client)
			entries[#entries + 1] = game_history.Spawned("paste", root)
		end

		context:Record(game_history.Group("paste", entries))
		return true
	end,
	RightClick = function(context, trace)
		if not toolgun.IsProp(trace.entity) then return false end

		local entities, links = toolgun.GetContraption(trace.entity)
		local inside = {}

		for _, entity in ipairs(entities) do
			inside[entity:GetGUID()] = true
		end

		local copied = list.copy(entities)
		local bottom = math.huge

		for _, entity in ipairs(entities) do
			bottom = math.min(bottom, entity.rigid_body:GetBroadphaseAABB().min_y)
		end

		for _, link in ipairs(links) do
			local constraint = link.constraint

			if
				inside[constraint.Entity0] and
				(
					constraint.Entity1 == "" or
					inside[constraint.Entity1]
				)
			then
				copied[#copied + 1] = link
			end
		end

		context.clipboard = {
			payload = scene.Encode(scene.SerializeEntities(copied)),
			origin = Vec3(trace.position.x, bottom, trace.position.z),
			yaw = get_yaw(trace.forward),
			count = #entities,
		}
		return true
	end,
	Reload = function(context)
		if not context.clipboard then return false end

		context.clipboard = nil
		return true
	end,
}
