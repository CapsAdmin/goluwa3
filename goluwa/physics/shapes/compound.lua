local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local META = prototype.CreateTemplate("physics_shape_compound")

local function identity_quat()
	return Quat(0, 0, 0, 1)
end

local function zero_vec3()
	return Vec3(0, 0, 0)
end

local function copy_child_rotation(rotation)
	if rotation and rotation.Copy then return rotation:Copy() end

	return identity_quat()
end

local function copy_child_position(position)
	if position and position.Copy then return position:Copy() end

	return zero_vec3()
end

local function get_child_shape(child)
	local shape = child.Shape or child.shape

	if not shape and child.ConvexHull then
		shape = ConvexShape.New(child.ConvexHull)
	end

	return shape
end

function META.New(children)
	local shape = META:CreateObject()
	shape.Children = {}

	if children and children.children then children = children.children end

	for _, child in ipairs(children or {}) do
		shape:AddChild(
			child.Shape or child.shape,
			child.Position or child.position,
			child.Rotation or child.rotation,
			child
		)
	end

	return shape
end

function META:GetTypeName()
	return "compound"
end

function META:GetChildren()
	self.Children = self.Children or {}
	return self.Children
end

function META:AddChild(shape, local_position, local_rotation, data)
	self.Children = self.Children or {}
	local child = {}

	if data then for key, value in pairs(data) do
		child[key] = value
	end end

	child.Shape = shape or get_child_shape(child)
	assert(child.Shape, "compound child requires Shape or ConvexHull")
	child.Position = copy_child_position(local_position or child.Position or child.position)
	child.Rotation = copy_child_rotation(local_rotation or child.Rotation or child.rotation)
	self.Children[#self.Children + 1] = child
	return child
end

return META:Register()