local physics = import("goluwa/physics.lua")
local AABB = import("goluwa/structs/aabb.lua")
local brush_hull = import("goluwa/physics/brush_hull.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local world_mesh_body = {}

local function get_entity_rotation(entity)
	local transform = entity and entity.transform or nil
	return transform and transform.GetRotation and transform:GetRotation() or Quat():Identity()
end

local function get_entity_position(entity)
	local transform = entity and entity.transform or nil
	return transform and transform.GetPosition and transform:GetPosition() or Vec3()
end

local function build_brush_polygon(primitive)
	if not (primitive and primitive.brush_planes) then return nil end

	if primitive.world_brush_polygon then return primitive.world_brush_polygon end

	local hull = primitive.brush_hull or brush_hull.BuildHullFromPlanes(primitive.brush_planes)

	if not (hull and hull.vertices and hull.vertices[1] and hull.indices and hull.indices[1]) then return nil end

	primitive.brush_hull = hull
	local indices = {}

	for i = 1, #hull.indices do
		indices[i] = hull.indices[i] - 1
	end

	primitive.world_brush_polygon = {
		Vertices = hull.vertices,
		indices = indices,
		AABB = AABB(
			hull.bounds_min.x,
			hull.bounds_min.y,
			hull.bounds_min.z,
			hull.bounds_max.x,
			hull.bounds_max.y,
			hull.bounds_max.z
		),
	}
	return primitive.world_brush_polygon
end

function world_mesh_body.IsSupportedPrimitive(primitive)
	return primitive and (primitive.polygon3d or primitive.brush_planes) or false
end

local function build_shape_for_primitive(primitive)
	if primitive and primitive.polygon3d then return MeshShape.New({Primitive = primitive}) end

	local brush_polygon = build_brush_polygon(primitive)

	if brush_polygon then return MeshShape.New({Polygons = {brush_polygon}}) end

	return nil
end

function world_mesh_body.GetPrimitiveShape(primitive)
	if not world_mesh_body.IsSupportedPrimitive(primitive) then return nil end

	return build_shape_for_primitive(primitive)
end

function world_mesh_body.GetPrimitivePolygon(primitive)
	if not world_mesh_body.IsSupportedPrimitive(primitive) then return nil end

	if primitive.polygon3d then return primitive.polygon3d end

	return build_brush_polygon(primitive)
end

local function create_proxy(model, entity, primitive, primitive_index)
	local proxy = {}
	proxy.Enabled = true
	proxy.CollisionEnabled = true
	proxy.Owner = entity
	proxy.Model = model
	proxy.Primitive = primitive
	proxy.PrimitiveIndex = primitive_index
	proxy.Shape = build_shape_for_primitive(primitive)
	proxy.MotionType = "static"
	proxy.InverseMass = 0
	proxy.CollisionGroup = 1
	proxy.CollisionMask = -1
	proxy.Friction = 0
	proxy.StaticFriction = 0
	proxy.RollingFriction = 0
	proxy.Restitution = 0
	proxy.FrictionCombineMode = "max"
	proxy.StaticFrictionCombineMode = "max"
	proxy.RollingFrictionCombineMode = "max"
	proxy.RestitutionCombineMode = "max"
	proxy.CollisionMargin = physics.DefaultSkin or 0.02
	proxy.MinGroundNormalY = 0.2

	function proxy:GetOwner()
		return self.Owner
	end

	function proxy:GetPhysicsShape()
		return self.Shape
	end

	function proxy:GetColliders()
		return {self}
	end

	function proxy:GetBody()
		return self
	end

	function proxy:GetLocalPosition()
		return Vec3()
	end

	function proxy:GetLocalRotation()
		return Quat():Identity()
	end

	function proxy:GetShapeType()
		return "mesh"
	end

	function proxy:GetPosition()
		return get_entity_position(self.Owner)
	end

	function proxy:GetPreviousPosition()
		return self:GetPosition()
	end

	function proxy:GetRotation()
		return get_entity_rotation(self.Owner)
	end

	function proxy:GetPreviousRotation()
		return self:GetRotation()
	end

	function proxy:WorldToLocal(world_pos, position, rotation)
		position = position or self:GetPosition()
		rotation = rotation or self:GetRotation()
		return rotation:GetConjugated():VecMul(world_pos - position)
	end

	function proxy:LocalToWorld(local_pos, position, rotation)
		position = position or self:GetPosition()
		rotation = rotation or self:GetRotation()
		return position + rotation:VecMul(local_pos)
	end

	function proxy:GeometryLocalToWorld(local_pos, position, rotation)
		return self:LocalToWorld(local_pos, position, rotation)
	end

	function proxy:GetBroadphaseAABB(position, rotation)
		return self.Shape:GetBroadphaseAABB(self, position, rotation)
	end

	function proxy:GetHalfExtents()
		return self.Shape:GetHalfExtents(self)
	end

	function proxy:GetVelocity()
		return Vec3()
	end

	function proxy:GetAngularVelocity()
		return Vec3()
	end

	function proxy:GetAngularVelocityDelta()
		return Vec3()
	end

	function proxy:GetInverseMassAlong()
		return 0
	end

	function proxy:GetCollisionGroup()
		return self.CollisionGroup
	end

	function proxy:GetCollisionMask()
		return self.CollisionMask
	end

	function proxy:GetCollisionMargin()
		return self.CollisionMargin
	end

	function proxy:GetCollisionProbeDistance()
		return 0
	end

	function proxy:GetFriction()
		return self.Friction
	end

	function proxy:GetStaticFriction()
		return self.StaticFriction
	end

	function proxy:GetRollingFriction()
		return self.RollingFriction
	end

	function proxy:GetRestitution()
		return self.Restitution
	end

	function proxy:GetFrictionCombineMode()
		return self.FrictionCombineMode
	end

	function proxy:GetStaticFrictionCombineMode()
		return self.StaticFrictionCombineMode
	end

	function proxy:GetRollingFrictionCombineMode()
		return self.RollingFrictionCombineMode
	end

	function proxy:GetRestitutionCombineMode()
		return self.RestitutionCombineMode
	end

	function proxy:GetMinGroundNormalY()
		return self.MinGroundNormalY
	end

	function proxy:GetGrounded()
		return false
	end

	function proxy:SetGrounded() end
	function proxy:SetGroundNormal() end
	function proxy:SetGroundRollingFriction() end
	function proxy:SetGroundBody() end
	function proxy:SetGroundEntity() end

	function proxy:IsStatic()
		return true
	end

	function proxy:IsKinematic()
		return false
	end

	function proxy:IsDynamic()
		return false
	end

	function proxy:HasSolverMass()
		return false
	end

	function proxy:IsSolverImmovable()
		return true
	end

	function proxy:ApplyImpulse() end
	function proxy:ApplyAngularImpulse() end
	function proxy:ApplyForce() end
	function proxy:ApplyTorque() end
	function proxy:ApplyCorrection() return 0 end
	function proxy:Wake() return self end
	function proxy:Sleep() return self end
	function proxy:BodyHasSignificantRotation() return false end

	return proxy
end

function world_mesh_body.GetPrimitiveBody(model, entity, primitive, primitive_index)
	if not (model and entity and world_mesh_body.IsSupportedPrimitive(primitive)) then return nil end

	local shape = world_mesh_body.GetPrimitiveShape(primitive)

	if not shape then return nil end

	primitive.world_mesh_body = primitive.world_mesh_body or create_proxy(model, entity, primitive, primitive_index)
	local proxy = primitive.world_mesh_body
	proxy.Owner = entity
	proxy.Model = model
	proxy.Primitive = primitive
	proxy.PrimitiveIndex = primitive_index
	proxy.Shape = proxy.Shape or shape
	return proxy
end

return world_mesh_body