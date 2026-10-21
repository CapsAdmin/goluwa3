local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Armature = import("goluwa/entities/components/armature.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Armature.RegisterSkeleton("armature_test", {{"root"}, {"head", "root"}, {"hand", "root"}})

local function world_position(entity)
	local x, y, z = entity.transform:GetWorldMatrix():GetTranslation()
	return Vec3(x, y, z)
end

local function set_bone(owner, name, x, y, z)
	owner.armature:SetBone(name, Matrix44():Identity():SetTranslation(x, y, z), "model")
end

T.Test("An attached transform follows the bone of its parent's armature", function()
	local owner = Entity.New{
		transform = {Position = Vec3(10, 0, 0)},
		armature = {Skeleton = "armature_test"},
	}
	local child = Entity.New{Parent = owner, transform = {Attachment = "head", Position = Vec3(0, 0, 1)}}
	set_bone(owner, "head", 0, 2, 0)
	T((world_position(child) - Vec3(10, 2, 1)):GetLength())["<"](0.0001)
	set_bone(owner, "head", 0, 5, 0)
	T((world_position(child) - Vec3(10, 5, 1)):GetLength())["<"](0.0001)
	child.transform:SetAttachment("hand")
	set_bone(owner, "hand", 3, 0, 0)
	T((world_position(child) - Vec3(13, 0, 1)):GetLength())["<"](0.0001)
	owner:Remove()
end)

T.Test("Root and names the parent does not have attach to the origin of the parent", function()
	local owner = Entity.New{
		transform = {Position = Vec3(10, 0, 0)},
		armature = {Skeleton = "armature_test"},
	}
	local child = Entity.New{Parent = owner, transform = {Position = Vec3(0, 0, 1)}}
	set_bone(owner, "head", 0, 2, 0)
	T(child.transform:GetAttachment())["=="]("root")
	T((world_position(child) - Vec3(10, 0, 1)):GetLength())["<"](0.0001)
	child.transform:SetAttachment("tail")
	T((world_position(child) - Vec3(10, 0, 1)):GetLength())["<"](0.0001)
	local plain = Entity.New{transform = {Position = Vec3(1, 2, 3)}}
	local attached = Entity.New{Parent = plain, transform = {Attachment = "head"}}
	T((world_position(attached) - Vec3(1, 2, 3)):GetLength())["<"](0.0001)
	attached:Remove()
	plain:Remove()
	owner:Remove()
end)

T.Test("The attachment names offered are root and the bones of the parent", function()
	local owner = Entity.New{transform = {}, armature = {Skeleton = "armature_test"}}
	local child = Entity.New{Parent = owner, transform = {}}
	local info
	local transform = child.transform

	for _, variable in ipairs(objects.GetStorableVariables(transform)) do
		if variable.var_name == "Attachment" then info = variable end
	end

	T(table.concat(info.get_enums(transform), ","))["=="]("root,head,hand")
	owner:Remove()
end)

T.Test("An attachment goes through a container between the armature and the attached transform", function()
	local owner = Entity.New{
		transform = {Position = Vec3(10, 0, 0)},
		armature = {Skeleton = "armature_test"},
	}
	local container = Entity.New{Parent = owner, transform = {Position = Vec3(0, 0, 4)}}
	local child = Entity.New{Parent = container, transform = {Attachment = "head"}}
	set_bone(owner, "head", 0, 2, 0)
	T((world_position(child) - Vec3(10, 2, 4)):GetLength())["<"](0.0001)
	owner:Remove()
end)

T.Test("An attached transform can turn world positions and rotations into its local space", function()
	local owner = Entity.New{
		transform = {Position = Vec3(10, 0, 0)},
		armature = {Skeleton = "armature_test"},
	}
	local child = Entity.New{
		Parent = owner,
		transform = {Attachment = "head", Position = Vec3(0.5, 0.25, 1)},
	}
	local bone = Matrix44():Identity()
	bone:SetRotation(QuatFromAxis(math.pi / 2, Vec3(0, 1, 0)))
	bone:Scale(1, 0.5, 1)
	bone:SetTranslation(0, 2, 0)
	owner.armature:SetBone("head", bone, "model")
	local world = world_position(child)
	T((child.transform:WorldToLocalPosition(world) - Vec3(0.5, 0.25, 1)):GetLength())["<"](0.0001)
	local rotation = child.transform:GetAttachedBoneRotation()
	local forward = rotation:GetForward()
	T(math.abs(forward.x + 1))["<"](0.0001)
	T(math.abs(forward.y))["<"](0.0001)
	T(math.abs(rotation:GetUp().y - 1))["<"](0.0001)
	local parent_world = child.transform:GetParentWorldMatrix()
	local x, y, z = parent_world:GetTranslation()
	T((Vec3(x, y, z) - Vec3(10, 2, 0)):GetLength())["<"](0.0001)
	child.transform:SetAttachment("root")
	T(child.transform:GetAttachedBoneRotation() == nil)["=="](true)
	T(
		(
			child.transform:WorldToLocalPosition(world_position(child)) - Vec3(0.5, 0.25, 1)
		):GetLength()
	)["<"](0.0001)
	owner:Remove()
end)

T.Test("Parent rotation times bone rotation times local rotation is the world rotation of an attached transform", function()
	local yaw = QuatFromAxis(0.7, Vec3(0, 1, 0))
	local local_rotation = QuatFromAxis(0.4, Vec3(1, 0, 0))
	local owner = Entity.New{
		transform = {Position = Vec3(1, 2, 3), Rotation = yaw},
		armature = {Skeleton = "armature_test"},
	}
	local child = Entity.New{Parent = owner, transform = {Attachment = "head", Rotation = local_rotation}}
	local bone = Matrix44():Identity()
	bone:SetRotation(QuatFromAxis(-0.9, Vec3(0, 0, 1)))
	bone:SetTranslation(0, 2, 0)
	owner.armature:SetBone("head", bone, "model")
	local expected = (yaw * child.transform:GetAttachedBoneRotation() * local_rotation):GetForward()
	local actual = child.transform:GetWorldMatrix():GetRotation():GetForward()
	T((expected - actual):GetLength())["<"](0.0001)
	owner:Remove()
end)

T.Test("A transform measures its render velocity from its world position, smoothed and once per frame", function()
	local system = import("goluwa/system.lua")
	local frame_number, elapsed = system.GetFrameNumber, system.GetElapsedTime
	local frame, now = 1, 0
	system.GetFrameNumber = function()
		return frame
	end
	system.GetElapsedTime = function()
		return now
	end
	local parent = Entity.New{transform = {Position = Vec3(0, 0, 0)}}
	local child = Entity.New{Parent = parent, transform = {Position = Vec3(1, 0, 0)}}
	local transform = child.transform
	T(transform:GetRenderVelocity():GetLength())["=="](0)

	for _ = 1, 60 do
		frame, now = frame + 1, now + 1 / 60
		parent.transform:SetPosition(Vec3(0, 0, -2 * now))
		transform:GetRenderVelocity()
	end

	T(transform:GetRenderVelocity().z)["~"](-2, 0.05)
	T(transform:GetRenderVelocity().x)["~"](0, 1e-6)
	local cached = transform:GetRenderVelocity().z
	parent.transform:SetPosition(Vec3(0, 0, -100))
	T(transform:GetRenderVelocity().z)["=="](cached)
	frame, now = frame + 1, now + 1
	T(transform:GetRenderVelocity():GetLength())["=="](0)
	child:Remove()
	parent:Remove()
	system.GetFrameNumber, system.GetElapsedTime = frame_number, elapsed
end)

T.Test("A socket is a bone with an offset and the attachment names list it", function()
	local owner = Entity.New{
		transform = {Position = Vec3(10, 0, 0)},
		armature = {Skeleton = "armature_test"},
	}
	owner.armature:SetSocket("grip", "hand", Vec3(0, 0, 2))
	local child = Entity.New{Parent = owner, transform = {Attachment = "grip"}}
	set_bone(owner, "hand", 3, 1, 0)
	T((world_position(child) - Vec3(13, 1, 2)):GetLength())["<"](0.0001)
	set_bone(owner, "hand", 0, 4, 0)
	T((world_position(child) - Vec3(10, 4, 2)):GetLength())["<"](0.0001)
	T(owner.armature:GetSocketNames()[1])["=="]("grip")
	T(owner.armature:GetBoneMatrix("missing") == nil)["=="](true)
	owner:Remove()
end)
