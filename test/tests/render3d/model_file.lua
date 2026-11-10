local T = import("test/environment.lua")
local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Material = import("goluwa/render3d/material.lua")
local model_file = import("goluwa/render3d/model_file.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local material_file = import("goluwa/render3d/material_file.lua")
local DIRECTORY = vfs.GetStorageDirectory("storage") .. "cache/test_model_file/"

local function make_polygon()
	local polygon = Polygon3D.New()

	for _, p in ipairs{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0.5}} do
		polygon:AddVertex{pos = Vec3(p[1], p[2], p[3]), uv = Vec2(p[1], p[2]), normal = Vec3(0, 0, 1)}
	end

	polygon:Upload{1, 2, 3, 3, 2, 4}
	polygon:SetBendHeight(2.5)
	polygon:SetMaterialSlot(3)
	polygon:SetLODLevel(1)
	polygon:SetLODDistance(40)
	polygon:SetRootChain{flex = 0.5, pivot = {0, 0, 0}, mid = {0, 1, 0}, tip = {0, 2, 0}}
	return polygon
end

local function make_skin()
	local indices = ffi.new("uint16_t[?]", 16)
	local weights = ffi.new("float[?]", 16)

	for i = 0, 3 do
		indices[i * 4] = i % 2
		weights[i * 4] = 1
	end

	indices[13] = 700
	return {BoneIndices = indices, BoneWeights = weights, Flexes = {}}
end

local function make_skeleton()
	local bind = ffi.new("float[?]", 2 * Skeleton.PoseSize)
	local inverse = ffi.new("float[?]", 2 * Skeleton.MatrixSize)
	bind[3 + 0], bind[Skeleton.PoseSize + 6] = 1, 1
	inverse[0], inverse[Skeleton.MatrixSize + 5] = 2, 3
	return Skeleton.New{
		BoneNames = {"root", "child"},
		Parents = {-1, 0},
		BindLocal = bind,
		InverseBind = inverse,
	}
end

local function make_physics()
	local cube = {}

	for _, x in ipairs{-1, 1} do
		for _, y in ipairs{-1, 1} do
			for _, z in ipairs{-1, 1} do
				cube[#cube + 1] = Vec3(x, y, z)
			end
		end
	end

	local collider = Polygon3D.New()

	for i, p in ipairs{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}} do
		collider.Vertices[i] = {pos = Vec3(p[1], p[2], p[3])}
	end

	collider.indices = {0, 1, 2}
	return {
		children = {
			{ConvexHull = convex_hull.Normalize(cube), Position = Vec3(0, 1, 0)},
			{Polygon3D = collider},
		},
		mass = 12,
		surface_property = "wood",
		center_of_mass = Vec3(0, 0.5, 0),
		damping = 0.1,
		rotation_damping = 0.2,
		inertia = Vec3(1, 2, 3),
	}
end

T.Test3D("model_file round trips meshes, skin, skeleton and physics", function()
	local polygon = make_polygon()
	polygon.Skin = make_skin()
	local geometry = assert(model_file.GetGeometry(polygon))
	T(geometry.vertex_count)["=="](4)
	T(geometry.index_count)["=="](6)
	local text = model_file.Serialize{
		meshes = {{polygon = polygon, material = "../../materials/x/material.mat"}},
		bounds = {min = Vec3(0, 0, 0), max = Vec3(1, 1, 1)},
		source = "source/model.mdl",
		physics = make_physics(),
		skeleton = make_skeleton(),
	}
	local header, reader = model_file.Read(text)
	local info = header.meshes[1]
	T(info.material)["=="]("../../materials/x/material.mat")
	T(info.bend_height)["=="](2.5)
	T(info.material_slot)["=="](3)
	T(info.lod_level)["=="](1)
	T(info.lod_distance)["=="](40)
	T(info.root_chain.mid[2])["=="](1)
	T(header.bounds[2])["=="](Vec3(1, 1, 1))
	T(header.source)["=="]("source/model.mdl")
	local vertices, indices = reader.Mesh(info)
	T(
		ffi.string(vertices, ffi.sizeof(vertices)) == ffi.string(geometry.vertices, ffi.sizeof(vertices))
	)["=="](true)

	for i = 0, 5 do
		T(indices[i])["=="](geometry.indices[i])
	end

	local skin = reader.Skin(header.skins[info.skin])
	T(skin.BoneIndices[4])["=="](1)
	T(skin.BoneIndices[13])["=="](700)
	T(skin.BoneWeights[8])["=="](1)
	local skeleton = reader.Skeleton(header.skeleton)
	T(skeleton.BoneCount)["=="](2)
	T(skeleton.BoneNames[2])["=="]("child")
	T(skeleton.parents[1])["=="](0)
	T(skeleton.InverseBind[0])["=="](2)
	T(skeleton.InverseBind[Skeleton.MatrixSize + 5])["=="](3)
	T(skeleton.BindLocal[Skeleton.PoseSize + 6])["=="](1)
	local physics = reader.Physics(header.physics)
	T(physics.mass)["=="](12)
	T(physics.surface_property)["=="]("wood")
	T(physics.inertia)["=="](Vec3(1, 2, 3))
	T(physics.children[1].Position)["=="](Vec3(0, 1, 0))
	T(#physics.children[1].ConvexHull.vertices)["=="](8)
	T(#physics.children[2].Polygon3D.Vertices)["=="](3)
	T(physics.children[2].Polygon3D.indices[3])["=="](2)
	T(pcall(model_file.Read, "not a model file"))["=="](false)
end)

T.Test3D("a written model file loads through the model loader with its material", function()
	local material = Material.New{}
	material:SetRoughnessMultiplier(0.3)
	fs.remove_directory_recursive(DIRECTORY)
	assert(fs.create_directory_recursive(DIRECTORY .. "materials/m/"))
	assert(fs.create_directory_recursive(DIRECTORY .. "models/a/"))
	assert(
		fs.write_file(
			DIRECTORY .. "materials/m/" .. material_file.FileName,
			material_file.Serialize(material, DIRECTORY .. "materials/m/")
		)
	)
	local path = DIRECTORY .. "models/a/" .. model_file.FileName
	assert(
		fs.write_file(
			path,
			model_file.Serialize{
				meshes = {
					{
						polygon = make_polygon(),
						material = "../../materials/m/" .. material_file.FileName,
					},
				},
				bounds = {min = Vec3(0, 0, 0), max = Vec3(1, 1, 1)},
				physics = make_physics(),
				skeleton = make_skeleton(),
			}
		)
	)
	local loaded, failure

	model_loader.LoadModel(
		path,
		function(data)
			loaded = data
		end,
		nil,
		function(err)
			failure = err
		end
	)

	local start = os.clock()

	while not loaded and not failure and os.clock() - start < 10 do
		tasks.Wait(0.05)
	end

	T(failure)["=="](nil)
	T(#loaded)["=="](1)
	T(loaded[1].mesh:GetBendHeight())["=="](2.5)
	T(loaded[1].mesh:GetMaterialSlot())["=="](3)
	T(loaded[1].material:GetRoughnessMultiplier())["=="](0.3)
	T(loaded.bounds.max)["=="](Vec3(1, 1, 1))
	T(loaded.skeleton.BoneCount)["=="](2)
	T(loaded.physics.mass)["=="](12)
	T(#loaded.physics.children)["=="](2)
	fs.remove_directory_recursive(DIRECTORY)
end)
