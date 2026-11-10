local objects = import("goluwa/objects/objects.lua")
local constraints = import("goluwa/physics/constraints.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local OVERLAP_MARGIN = 0.02
local META = objects.CreateTemplate("map_constraint")
META:StartStorable()
META:GetSet("Kind", "hinge", {enums = {"hinge", "slider", "weld"}})
META:GetSet("Entity0", "")
META:GetSet("Entity1", "")
META:GetSet("Anchor0", Vec3())
META:GetSet("Axis0", Vec3(0, 1, 0))
META:GetSet("HasLimits", false)
META:GetSet("Lower", 0)
META:GetSet("Upper", 0)
META:GetSet("Friction", 0)
META:GetSet("IgnoredGroup", 0)
META:EndStorable()

function META:Initialize()
	self:AddGlobalEvent("Update")
end

local function get_body(guid)
	local entity = objects.GetObjectByGUID(guid)

	if not entity:IsValid() then return nil end

	local body = entity.rigid_body

	-- a body has a placeholder collider before its shape model loads, and the model moves it to its centre of mass
	if
		body and
		body:IsValid() and
		body:GetColliders()[1] and
		(
			body.ShapeModelPath == "" or
			body.shape_model_static ~= nil
		)
	then
		return body, entity
	end
end

-- a map's constraints join bodies at their spawn pose, so they wait until every body has its shapes
function META:Build()
	local body0, entity0 = get_body(self.Entity0)

	if not body0 then return false end

	local body1

	if self.Entity1 ~= "" then
		body1 = get_body(self.Entity1)

		if not body1 then return false end
	end

	-- a door sits in a frame that is part of the static map, they are modelled to touch and the door must not fight it
	if self.IgnoredGroup ~= 0 and self.Kind ~= "weld" then
		body0:SetCollisionMask(bit.band(body0:GetCollisionMask(), bit.bnot(self.IgnoredGroup)))
	end

	local anchor = entity0.transform:GetWorldPosition() + entity0.transform:GetWorldRotation():VecMul(self.Anchor0)
	local axis = entity0.transform:GetWorldRotation():VecMul(self.Axis0):GetNormalized()
	local kind = self.Kind
	local config = {Friction = self.Friction}
	local constraint

	if kind == "hinge" then
		if self.HasLimits then
			config.LowerAngle = self.Lower
			config.UpperAngle = self.Upper
		end

		constraint = constraints.Hinge(body0, body1, anchor, axis, config)
	elseif kind == "slider" then
		if self.HasLimits then
			config.LowerTranslation = self.Lower
			config.UpperTranslation = self.Upper
		end

		constraint = constraints.Slider(body0, body1, anchor, axis, config)
	else
		constraint = constraints.Weld(body0, body1, anchor, config)
	end

	self.physics_constraint = constraint
	local box = body0:GetBroadphaseAABB(body0:GetPosition(), body0:GetRotation())

	for _, other in ipairs(META.Instances) do
		local other_body = other ~= self and other.physics_constraint and get_body(other.Entity0)

		if other_body and other_body ~= body0 and other_body ~= body1 then
			local other_box = other_body:GetBroadphaseAABB(other_body:GetPosition(), other_body:GetRotation())

			if
				other_box.min_x <= box.max_x + OVERLAP_MARGIN and
				other_box.max_x >= box.min_x - OVERLAP_MARGIN and
				other_box.min_y <= box.max_y + OVERLAP_MARGIN and
				other_box.max_y >= box.min_y - OVERLAP_MARGIN and
				other_box.min_z <= box.max_z + OVERLAP_MARGIN and
				other_box.max_z >= box.min_z - OVERLAP_MARGIN
			then
				constraints.NoCollide(body0, other_body)
			end
		end
	end

	return true
end

function META:OnUpdate()
	if self.physics_constraint then
		if not self.physics_constraint:IsValid() then self.Owner:Remove() end

		return
	end

	self:Build()
end

function META:OnRemove()
	local constraint = self.physics_constraint

	if constraint and constraint:IsValid() then constraint:Remove() end
end

return META:Register()
