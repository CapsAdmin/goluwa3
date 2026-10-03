local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local Rig = import("goluwa/render3d/rig.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render = import("goluwa/render/render.lua")
local ffi = require("ffi")

-- two bones, the second one a child 1 unit up
local function create_skeleton()
	return Skeleton.New{
		BoneNames = {"root", "arm"},
		Parents = {-1, 0},
		BindLocal = ffi.new("float[14]", {0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1}),
		InverseBind = ffi.new(
			"float[24]",
			{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 1, 0}
		),
	}
end

-- a cube that follows the second bone
local function create_part()
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)
	poly:Upload()
	local count = poly.mesh.vertex_buffer:GetVertexCount()
	local skin = {
		BoneIndices = ffi.new("uint8_t[?]", count * 4),
		BoneWeights = ffi.new("float[?]", count * 4),
	}

	for i = 0, count - 1 do
		skin.BoneIndices[i * 4] = 1
		skin.BoneWeights[i * 4] = 1
	end

	poly.Skin = skin
	local clone = poly:CloneDynamic()
	return poly,
	clone,
	{
		bind_vertex_buffer = poly.mesh.vertex_buffer,
		vertex_buffer = clone.mesh.vertex_buffer,
		skin = skin,
	}
end

T.Test3D("rig moves bones with matrices in local and model space", function(draw)
	local skeleton = create_skeleton()
	local poly, clone, part = create_part()
	local rig = Rig.New(skeleton, {part})
	local bind = ffi.cast("float*", poly.mesh.vertex_buffer.data)
	rig:SetPose(skeleton:NewPose())
	T(select(2, rig:GetBone("arm"):GetTranslation()))["=="](1)
	-- local: on top of the pose in the space of the bone
	rig:SetBone("arm", Matrix44():SetTranslation(0, 0.5, 0), "local")
	rig:Update()
	draw()
	render.GetDevice():WaitIdle()
	local skinned = ffi.cast("float*", clone.mesh.vertex_buffer:GetBuffer():Map())
	T(math.abs(skinned[1] - (bind[1] + 0.5)))["<"](1e-4)
	T(math.abs(select(2, rig:GetBone("arm"):GetTranslation()) - 1.5))["<"](1e-5)
	-- model: replaces the matrix of the bone
	rig:ClearBone("arm")
	rig:SetBone("arm", Matrix44():SetTranslation(2, 0, 0), "model")
	local x, y = rig:GetBone("arm"):GetTranslation()
	T(x)["=="](2)
	T(y)["=="](0)
	-- children follow the bones they hang on
	rig:ClearBones()
	rig:SetBone("root", Matrix44():SetTranslation(1, 0, 0), "model")
	x, y = rig:GetBone("arm"):GetTranslation()
	T(math.abs(x - 1))["<"](1e-5)
	T(math.abs(y - 1))["<"](1e-5)
	rig:ClearBones()
	rig:SetBone("root", Matrix44():SetAngles(Ang3(0, 0, math.pi / 2)), "local")
	x, y = rig:GetBone("arm"):GetTranslation()
	T(math.abs(y))["<"](1e-5)
	T(math.abs(math.abs(x) - 1))["<"](1e-5)
	T(pcall(rig.SetBone, rig, "nobody", Matrix44(), "local"))["=="](false)
	T(pcall(rig.SetBone, rig, "arm", Matrix44(), "world"))["=="](false)
	rig:Remove()
end)

T.Test3D("bone_pose moves the bones of an animated entity by name", function()
	local skeleton = create_skeleton()
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)
	poly:Upload()
	local count = poly.mesh.vertex_buffer:GetVertexCount()
	poly.Skin = {
		BoneIndices = ffi.new("uint8_t[?]", count * 4),
		BoneWeights = ffi.new("float[?]", count * 4),
	}
	local entity = Entity.New{Name = "posed"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local child = Entity.New{Name = "posed_primitive", Parent = entity}
	child:AddComponent("transform")
	local primitive = child:AddComponent("visual_primitive")
	primitive:SetPolygon3D(poly)
	primitive:SetMaterial(Material.New{})
	entity.visual.Skeleton = skeleton
	local animator = entity:AddComponent("animator")
	local bone_pose = entity:AddComponent("bone_pose")
	T(#bone_pose:GetDynamicProperties())["=="](0)
	animator:Bind(skeleton)
	bone_pose:Update()
	local properties = bone_pose:GetDynamicProperties()
	-- a position and angles for both bones
	T(#properties)["=="](4)
	T(properties[1].var_name)["=="]("bone root position")
	properties[3].set(bone_pose, Vec3(0, 0.25, 0))
	T(properties[3].get(bone_pose).y)["=="](0.25)
	T(math.abs(select(2, animator:GetRig():GetBone("arm"):GetTranslation()) - 1.25))["<"](1e-5)
	-- a new rig gets the bones again
	animator:Bind(skeleton)
	bone_pose:Update()
	T(math.abs(select(2, animator:GetRig():GetBone("arm"):GetTranslation()) - 1.25))["<"](1e-5)
	bone_pose:ClearBones()
	T(math.abs(select(2, animator:GetRig():GetBone("arm"):GetTranslation()) - 1))["<"](1e-5)
	local saved = bone_pose:OnSerialize()
	T(next(saved.positions))["=="](nil)
	animator:Unbind()
	entity:Remove()
end)
