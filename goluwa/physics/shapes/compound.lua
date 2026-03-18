local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local META = prototype.CreateTemplate("physics_shape_compound")

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
	child.Position = (local_position or child.Position or child.position or Vec3()):Copy()
	child.Rotation = (local_rotation or child.Rotation or child.rotation or Quat():Identity()):Copy()
	self.Children[#self.Children + 1] = child
	return child
end

return META:Register()
