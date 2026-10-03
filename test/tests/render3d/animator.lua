local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local render = import("goluwa/render/render.lua")
local ffi = require("ffi")

-- two bones, the second one a child 1 unit up, and a clip that swings it around z by up to 90 degrees
local function create_skeleton()
	local bind_local = ffi.new("float[14]", {0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1})
	local inverse_bind = ffi.new(
		"float[24]",
		{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 1, 0}
	)
	local skeleton = Skeleton.New{
		BoneNames = {"root", "arm"},
		Parents = {-1, 0},
		BindLocal = bind_local,
		InverseBind = inverse_bind,
	}
	skeleton:AddClip{
		Name = "swing",
		Duration = 1,
		Loop = true,
		Sample = function(clip, cycle, params, out)
			ffi.copy(out, bind_local, 14 * 4)
			local half = cycle * math.pi / 4
			out[12] = math.sin(half)
			out[13] = math.cos(half)
		end,
	}
	return skeleton
end

local function create_animated_entity(skeleton)
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)
	poly:Upload()
	local count = poly.mesh.vertex_buffer:GetVertexCount()
	poly.Skin = {
		BoneIndices = ffi.new("uint8_t[?]", count * 4),
		BoneWeights = ffi.new("float[?]", count * 4),
	}

	for i = 0, count - 1 do
		poly.Skin.BoneIndices[i * 4] = 1
		poly.Skin.BoneWeights[i * 4] = 1
	end

	local entity = Entity.New{Name = "animated"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local primitive_entity = Entity.New{Name = "animated_primitive", Parent = entity}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(poly)
	primitive:SetMaterial(Material.New{})
	entity.visual.Skeleton = skeleton
	return entity, primitive, poly
end

T.Test3D("animator skins a primitive on the gpu without touching the shared mesh", function(draw)
	local skeleton = create_skeleton()
	local entity, primitive, poly = create_animated_entity(skeleton)
	local animator = entity:AddComponent("animator")
	local bind = ffi.cast("float*", poly.mesh.vertex_buffer.data)
	local x, y, z = bind[0], bind[1], bind[2]
	animator:Bind(skeleton)
	T(primitive:GetPolygon3D() ~= poly)["=="](true)
	T(#animator.targets)["=="](1)
	animator:SetSequence("swing")
	animator:SetPlaying(false)
	animator:SetTime(0.5)
	animator:Animate(0)
	draw()
	render.GetDevice():WaitIdle()
	local skinned = ffi.cast("float*", primitive:GetPolygon3D().mesh.vertex_buffer:GetBuffer():Map())
	-- 45 degrees around z about the point (0, 1, 0)
	local angle = math.pi / 4
	local dx, dy = x, y - 1
	local expected_x = dx * math.cos(angle) - dy * math.sin(angle)
	local expected_y = dx * math.sin(angle) + dy * math.cos(angle) + 1
	T(math.abs(skinned[0] - expected_x))["<"](1e-4)
	T(math.abs(skinned[1] - expected_y))["<"](1e-4)
	T(math.abs(skinned[2] - z))["<"](1e-4)
	T(bind[0])["=="](x)
	T(bind[1])["=="](y)
	animator:Unbind()
	T(primitive:GetPolygon3D())["=="](poly)
	entity:Remove()
end)

T.Test3D("animator crossfades when the sequence changes", function()
	local skeleton = create_skeleton()
	skeleton:AddClip{
		Name = "rest",
		Duration = 1,
		Loop = true,
		Sample = function(clip, cycle, params, out)
			ffi.copy(out, skeleton.BindLocal, 14 * 4)
		end,
	}
	local entity = create_animated_entity(skeleton)
	local animator = entity:AddComponent("animator")
	animator:Bind(skeleton)
	animator:SetSequence("swing")
	animator:SetBlendTime(1)
	animator:Animate(0.25)
	animator:SetSequence("rest")
	animator:Animate(0.5)
	T(animator.fade ~= nil)["=="](true)
	animator:Animate(0.6)
	T(animator.fade)["=="](nil)
	entity:Remove()
end)

T.Test3D("source engine player model animations", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/player/alyx.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	local skeleton

	model_loader.LoadModel("models/player/alyx.mdl", function(data)
		skeleton = data.skeleton
	end)

	T.WaitUntil(function()
		return skeleton ~= nil
	end, 30)
	T(skeleton ~= nil)["=="](true)
	T(skeleton.BoneCount)[">"](1)
	local walk = skeleton.ClipsByName["walk_all"]
	T(walk ~= nil)["=="](true)
	local a, b = skeleton:CreatePose(), skeleton:CreatePose()
	walk:Sample(0, {move_x = 1}, a)
	walk:Sample(0.5, {move_x = 1}, b)
	local difference = 0

	for i = 0, skeleton.BoneCount * 7 - 1 do
		difference = difference + math.abs(a[i] - b[i])
	end

	T(difference)[">"](0.1)
end)

T.Test3D("animated visuals get a block in the scene bvh with a per triangle source table", function(draw)
	local scene_bvh = import("goluwa/render3d/scene_bvh.lua")

	if not render.GetDevice().ray_tracing_supported then
		return T.Unavailable("ray tracing not supported")
	end

	local skeleton = create_skeleton()
	local entity, primitive, poly = create_animated_entity(skeleton)
	local animator = entity:AddComponent("animator")
	animator:Bind(skeleton)
	animator:SetSequence("swing")
	animator:Animate(0)
	entity.visual:BuildAABB()
	scene_bvh.Build(true)
	local block

	for animated in pairs(scene_bvh.animated_blocks) do
		if animated.shape.animated_source then block = animated end
	end

	T(block ~= nil)["=="](true)
	T(block.shape.total)["=="](poly.mesh.vertex_buffer:GetVertexCount() / 3)
	animator:Unbind()
	entity:Remove()
end)

T.Test3D("animator skins once more after the pose stops changing, then goes quiet", function()
	local skeleton = create_skeleton()
	local entity = create_animated_entity(skeleton)
	local animator = entity:AddComponent("animator")
	animator:Bind(skeleton)
	animator:SetSequence("swing")
	animator:SetPlaying(false)
	animator:SetTime(0.5)
	animator:Animate(0)
	local version = animator.skin_version
	T(animator.settle)["=="](1)
	-- the second pass has the same pose, which takes the motion since the previous update to zero. the bvh has nothing new
	animator:Settle()
	T(animator.settle)["=="](0)
	animator:Settle()
	animator:Animate(0)
	T(animator.skin_version)["=="](version)
	animator:SetTime(0.25)
	animator:Animate(0)
	T(animator.skin_version)["=="](version + 1)
	animator:Unbind()
	entity:Remove()
end)

T.Test3D("animators update less often the farther they are", function()
	local Animator = import("goluwa/entities/components/animator.lua")
	T(Animator.GetUpdateInterval(0))["=="](0)
	T(Animator.GetUpdateInterval(Animator.LOD_NEAR))["=="](0)
	T(Animator.GetUpdateInterval(Animator.LOD_FAR))["=="](1 / Animator.LOD_MIN_RATE)
	T(Animator.GetUpdateInterval(Animator.LOD_FAR * 10))["=="](1 / Animator.LOD_MIN_RATE)
	local middle = Animator.GetUpdateInterval((Animator.LOD_NEAR + Animator.LOD_FAR) / 2)
	T(middle)[">"](0)
	T(middle)["<"](1 / Animator.LOD_MIN_RATE)
end)
