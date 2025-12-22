local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping transform tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Polygon3D = require("render3d.polygon_3d")
local Material = require("render3d.material")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Matrix44 = require("structs.matrix").Matrix44
local ecs = require("ecs")
require("components.transform")
require("components.model")
local width = 512
local height = 512
local initialized = false

local function init_render3d()
	if not initialized then
		render.Initialize({headless = true, width = width, height = height})
		initialized = true
	else
		render.GetDevice():WaitIdle()
	end

	render3d.Initialize()
end

local function create_cube(pos, ang, scale, color)
	local poly = Polygon3D.New()
	poly:CreateCube(1.0, 1.0)
	poly:AddSubMesh(#poly.Vertices)
	poly:BuildNormals()
	poly:BuildBoundingBox()
	poly:Upload()
	local entity = ecs.CreateEntity("cube", ecs.GetWorld())
	entity:AddComponent(
		"transform",
		{
			position = pos or Vec3(0, 0, 0),
			scale = scale or Vec3(1, 1, 1),
		}
	)

	if ang then entity.transform:SetAngles(ang) end

	entity:AddComponent(
		"model",
		{
			mesh = poly,
			material = Material.New({base_color_factor = color or {1, 1, 1, 1}}),
		}
	)
	return entity
end

T.Test("transform basic", function()
	init_render3d()
	local world = ecs.GetWorld()
	local pos = Vec3(1, 2, 3)
	local ang = Deg3(10, 20, 30)
	local scale = Vec3(2, 2, 2)
	local ent = create_cube(pos, ang, scale)
	local transform = ent.transform
	T(transform:GetPosition())["=="](pos)
	local ang_out = transform:GetAngles()
	T(ang_out.x)["~"](ang.x)
	T(ang_out.y)["~"](ang.y)
	T(ang_out.z)["~"](ang.z)
	T(transform:GetScale())["=="](scale)
	-- Test matrix generation
	local mat = transform:GetWorldMatrix()
	local pos_out = Vec3(mat.m30, mat.m31, mat.m32)
	T(pos_out)["=="](pos)
	ent:Remove()
end)

T.Test("transform parenting", function()
	init_render3d()
	local world = ecs.GetWorld()
	local parent_pos = Vec3(10, 0, 0)
	local parent = create_cube(parent_pos)
	local child_pos = Vec3(5, 0, 0)
	local child = create_cube(child_pos)
	child:SetParent(parent)
	-- Child world position should be parent_pos + child_pos if no rotation
	local world_mat = child.transform:GetWorldMatrix()
	local world_pos = Vec3(world_mat.m30, world_mat.m31, world_mat.m32)
	T(world_pos)["=="](parent_pos + child_pos)
	-- Test rotation inheritance
	parent.transform:SetAngles(Deg3(0, 90, 0)) -- Rotate 90 degrees around Y
	-- After 90 deg Y rotation, it should be at (0, 0, -5) relative to parent in world space
	-- (Positive Yaw is turn left in this coordinate system)
	world_mat = child.transform:GetWorldMatrix()
	world_pos = Vec3(world_mat.m30, world_mat.m31, world_mat.m32)
	local expected_pos = parent_pos + Vec3(0, 0, -5)
	T(world_pos.x)["~"](expected_pos.x)
	T(world_pos.y)["~"](expected_pos.y)
	T(world_pos.z)["~"](expected_pos.z)
	parent:Remove()
	child:Remove()
end)

T.Test("transform camera match", function()
	init_render3d()
	local cam = render3d.GetCamera()
	local pos = Vec3(1, 2, 3)
	local ang = Deg3(10, 20, 30)
	cam:SetPosition(pos)
	cam:SetAngles(ang)
	local ent = create_cube(pos, ang)
	local transform = ent.transform
	local cam_view = cam:BuildViewMatrix()
	local ent_world = transform:GetWorldMatrix()
	-- Camera view matrix is inverse of its world matrix (roughly)
	-- V = (T * R)^-1 = R^-1 * T^-1
	-- Let's check if ent_world:GetInverse() matches cam_view
	local ent_world_inv = ent_world:GetInverse()

	-- Compare matrices
	for i = 0, 15 do
		T(ent_world_inv:GetI(i))["~"](cam_view:GetI(i))
	end

	ent:Remove()
end)
