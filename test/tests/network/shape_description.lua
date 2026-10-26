local T = import("test/environment.lua")
local attest = import("goluwa/attest.lua")
local packet = import("goluwa/network/packet.lua")
local shape_description = import("goluwa/physics/shape_description.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")

local function round_trip(shape)
	local buffer = packet.CreateBuffer()
	shape_description.Write(buffer, shape)
	buffer:SetPosition(1)
	return shape_description.Read(buffer)
end

T.Test("shape description round trips primitive shapes", function()
	local box = round_trip(BoxShape.New(Vec3(1, 2, 3)))
	T(box:GetTypeName())["=="]("box")
	T(box:GetSize().z)["=="](3)
	local sphere = round_trip(SphereShape.New(2.5))
	T(sphere:GetTypeName())["=="]("sphere")
	T(sphere:GetRadius())["=="](2.5)
	local capsule = round_trip(CapsuleShape.New(0.5, 3))
	T(capsule:GetTypeName())["=="]("capsule")
	T(capsule:GetHeight())["=="](3)
	T(round_trip(nil))["=="](nil)
end)

T.Test("shape description round trips compound shapes of primitives", function()
	local compound = round_trip(
		CompoundShape.New{
			{Shape = BoxShape.New(Vec3(1, 2, 3)), Position = Vec3(0.5, 1, 0)},
			{Shape = SphereShape.New(0.25), Position = Vec3(0, 2, 0)},
		}
	)
	local children = compound:GetChildren()
	T(compound:GetTypeName())["=="]("compound")
	T(#children)["=="](2)
	T(children[1].Shape:GetTypeName())["=="]("box")
	T(children[1].Shape:GetSize().y)["=="](2)
	T(children[1].Position.x)["=="](0.5)
	T(children[2].Shape:GetRadius())["=="](0.25)
	T(children[2].Position.y)["=="](2)
end)

T.Test("shape description refuses mesh shapes", function()
	attest.fails(function()
		round_trip(MeshShape.New())
	end, "cannot be replicated")
end)

T.Test("shape description refuses shapes it cannot describe", function()
	attest.fails(
		function()
			round_trip(ConvexShape.New({vertices = {}}))
		end,
		"cannot be replicated"
	)
end)

T.Test("packet buffer position can reach the end of the buffer", function()
	local buffer = packet.CreateBuffer()
	buffer:WriteI32(7)
	buffer:SetPosition(1)
	T(buffer:ReadI32())["=="](7)
	T(buffer:TheEnd())["=="](true)
end)
