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
local raycast = import("goluwa/render3d/raycast.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local STRIDE = vertex_layout.CoreFloatStride
local X = vertex_layout.GetFloatOffset("position")
local Y = X + 1
local Vec3 = import("goluwa/structs/vec3.lua")
local ffi = require("ffi")

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
	local x, y, z = bind[X], bind[Y], bind[Y + 1]
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
	local angle = math.pi / 4
	local dx, dy = x, y - 1
	local expected_x = dx * math.cos(angle) - dy * math.sin(angle)
	local expected_y = dx * math.sin(angle) + dy * math.cos(angle) + 1
	T(math.abs(skinned[X] - expected_x))["<"](1e-4)
	T(math.abs(skinned[1] - expected_y))["<"](1e-4)
	T(math.abs(skinned[2] - z))["<"](1e-4)
	T(bind[X])["=="](x)
	T(bind[1])["=="](y)
	animator:Unbind()
	T(primitive:GetPolygon3D())["=="](poly)
	entity:Remove()
end)

T.Test3D("skinning keeps the positions of the skin before beside the skinned copy", function(draw)
	local skeleton = create_skeleton()
	local entity, primitive = create_animated_entity(skeleton)
	local animator = entity:AddComponent("animator")
	animator:Bind(skeleton)
	animator:SetSequence("swing")
	animator:SetPlaying(false)

	local function skin(time)
		animator:SetTime(time)
		animator:Animate(0)
		draw()
		render.GetDevice():WaitIdle()
		local vertex_buffer = primitive:GetPolygon3D().mesh.vertex_buffer
		local current = ffi.cast("float*", vertex_buffer:GetBuffer():Map())
		local previous = ffi.cast("float*", vertex_buffer.previous_positions:Map())
		return {current[X], current[Y], current[Y + 1]}, {previous[0], previous[1], previous[2]}
	end

	local first, first_previous = skin(0.25)

	for i = 1, 3 do
		T(first_previous[i])["=="](first[i])
	end

	local second, second_previous = skin(0.5)
	T(math.abs(second[1] - first[1]) + math.abs(second[2] - first[2]))[">"](0.01)

	for i = 1, 3 do
		T(second_previous[i])["=="](first[i])
	end

	animator:Unbind()
	entity:Remove()
end)

T.Test3D("a skinned primitive has velocity while its pose changes and none once it rests", function(draw)
	local render3d = import("goluwa/render3d/render3d.lua")
	local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
	local Quat = import("goluwa/structs/quat.lua")
	local camera = render3d.GetCamera()
	camera:SetPosition(Vec3(0, 0.5, 4))
	camera:SetRotation(Quat():Identity())
	local skeleton = create_skeleton()
	local entity = create_animated_entity(skeleton)
	local animator = entity:AddComponent("animator")
	animator:Bind(skeleton)
	animator:SetSequence("swing")
	animator:SetPlaying(false)

	local function largest_velocity(time)
		animator:SetTime(time)
		animator:Animate(0)
		draw()
		local velocity = gbuffer_layout.GetTexture("velocity"):Download()
		local largest = 0

		for y = 0, velocity.height - 1, 4 do
			for x = 0, velocity.width - 1, 4 do
				local vx, vy = velocity:GetPixelFloat(x, y)
				largest = math.max(largest, math.abs(vx), math.abs(vy))
			end
		end

		return largest
	end

	largest_velocity(0.25)
	T(largest_velocity(0.5))[">"](0.001)

	for _ = 1, 3 do
		animator:Settle()
		largest_velocity(0.5)
	end

	T(largest_velocity(0.5))["<"](1e-4)
	animator:Unbind()
	entity:Remove()
end)

T.Test3D("raycasts hit an animated primitive where it is posed and not where it was bound", function(draw)
	local skeleton = create_skeleton()
	local entity, primitive, poly = create_animated_entity(skeleton)
	local animator = entity:AddComponent("animator")
	local count = poly.mesh.vertex_buffer:GetVertexCount()
	local bind = ffi.cast("float*", poly.mesh.vertex_buffer.data)
	local bind_x, bind_y = 0, 0

	for i = 0, count - 1 do
		bind_x = bind_x + bind[i * STRIDE + X] / count
		bind_y = bind_y + bind[i * STRIDE + Y] / count
	end

	animator:Bind(skeleton)
	animator:SetSequence("swing")
	animator:SetPlaying(false)
	animator:SetTime(0.5)
	animator:Animate(0)
	draw()
	render.GetDevice():WaitIdle()
	local skinned = ffi.cast("float*", primitive:GetPolygon3D().mesh.vertex_buffer:GetBuffer():Map())
	local posed_x, posed_y = 0, 0

	for i = 0, count - 1 do
		posed_x = posed_x + skinned[i * STRIDE + X] / count
		posed_y = posed_y + skinned[i * STRIDE + Y] / count
	end

	T(math.abs(posed_x - bind_x) + math.abs(posed_y - bind_y))[">"](0.5)
	local at_pose = raycast.CastClosest(Vec3(posed_x, posed_y, 10), Vec3(0, 0, -1), 100)
	T(at_pose ~= nil)["=="](true)
	T(at_pose.entity)["=="](entity)
	T(raycast.CastClosest(Vec3(bind_x, bind_y, 10), Vec3(0, 0, -1), 100))["=="](nil)
	animator:Unbind()
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
