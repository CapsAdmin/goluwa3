local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local shape_description = {}
local NONE, BOX, SPHERE, CAPSULE = 0, 1, 2, 3

function shape_description.Write(buffer, shape)
	if not shape then
		buffer:WriteByte(NONE)
		return
	end

	local name = shape:GetTypeName()

	if name == "box" then
		buffer:WriteByte(BOX)
		buffer:WriteVec3(shape:GetSize())
	elseif name == "sphere" then
		buffer:WriteByte(SPHERE)
		buffer:WriteFloat(shape:GetRadius())
	elseif name == "capsule" then
		buffer:WriteByte(CAPSULE)
		buffer:WriteFloat(shape:GetRadius())
		buffer:WriteFloat(shape:GetHeight())
	else
		error("physics shape " .. name .. " cannot be replicated", 2)
	end
end

function shape_description.Read(buffer)
	local kind = buffer:ReadByte()

	if kind == NONE then
		return nil
	elseif kind == BOX then
		return BoxShape.New(buffer:ReadVec3())
	elseif kind == SPHERE then
		return SphereShape.New(buffer:ReadFloat())
	elseif kind == CAPSULE then
		return CapsuleShape.New(buffer:ReadFloat(), buffer:ReadFloat())
	end

	error("unknown replicated shape kind " .. tostring(kind))
end

return shape_description
