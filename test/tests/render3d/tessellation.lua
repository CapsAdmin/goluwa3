local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local tessellation = import("goluwa/render3d/scene/tessellation.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

local function create_facing_quad()
	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 0.5, 1.0, 4)
	local poly = Polygon3D.New()

	for i = 1, #cube.Vertices, 3 do
		local a, b, c = cube.Vertices[i], cube.Vertices[i + 1], cube.Vertices[i + 2]

		if a.pos.z > 0.49 and b.pos.z > 0.49 and c.pos.z > 0.49 then
			poly:AddVertex(a)
			poly:AddVertex(b)
			poly:AddVertex(c)
		end
	end

	poly:BuildBoundingBox()
	poly:Upload()
	return poly
end

local function spawn(polygon3d, material, z)
	local entity = Entity.New{Name = "tessellation_quad"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, z))
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "tessellation_quad_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	return entity
end

local function draw_center(draw, tessellate)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(60))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local polygon3d = create_facing_quad()
	local raised = Material.New{
		ColorMultiplier = Color(1, 0, 0, 1),
		HeightTexture = shapes.Texture("return vec4(1.0);"),
		HeightScale = 0.5,
		HeightTessellate = tessellate,
	}
	local front = Material.New{ColorMultiplier = Color(0, 1, 0, 1)}
	local entities = {spawn(polygon3d, raised, -4), spawn(polygon3d, front, -3.75)}
	local library = Visual.Library
	local was_noculling = library.noculling
	library.noculling = false
	local ok, err = pcall(function()
		local deadline = system.GetTime() + 90

		repeat
			draw()		
		until not tessellate or tessellation.IsDrawing() or system.GetTime() > deadline

		draw()
	end)
	library.noculling = was_noculling
	local rows = tessellation.GetRowCount()

	for _, entity in ipairs(entities) do
		entity:Remove()
	end

	if not ok then error(err, 0) end

	local size = render.GetRenderImageSize()
	local r, g = gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2))
	return r, g, rows
end

T.Test3D("Graphics render3d tessellated height maps raise real geometry out of the mesh", function(draw)
	local r, g, rows = draw_center(draw, true)
	T(rows)["=="](1)
	T(r)[">"](200)
	T(g)["<"](10)
end)

T.Test3D("Graphics render3d parallax height maps stay inside the mesh", function(draw)
	local r, g, rows = draw_center(draw, false)
	T(rows)["=="](0)
	T(g)[">"](200)
	T(r)["<"](10)
end)

T.Test3DRayTracing("Graphics render3d tessellated height maps are traced with their relief", function(draw)
	if not render.GetDevice().cluster_acceleration_structure_supported then
		return
	end

	local ffi = require("ffi")
	local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
	local instances = import("goluwa/render3d/scene/instances.lua")
	local hit = import("goluwa/render3d/scene/hit.lua")
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(60))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local raised = Material.New{
		HeightTexture = shapes.Texture("return vec4(1.0);"),
		HeightScale = 0.5,
		HeightTessellate = true,
	}
	local entity = spawn(create_facing_quad(), raised, -4)
	local library = Visual.Library
	local was_noculling = library.noculling
	library.noculling = false
	local deadline = system.GetTime() + 90

	repeat
		draw()	
	until (tessellation.IsDrawing() and tessellation.GetStats().rt_jobs) or system.GetTime() > deadline

	for _ = 1, 4 do
		draw()
	end

	library.noculling = was_noculling
	local results = render.CreateBuffer{
		byte_size = 16,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "tessellation_trace_results",
	}
	local descriptor_sets = {
		{type = "acceleration_structure_khr", binding_index = 1, stageFlags = "compute"},
	}

	for _, set in ipairs(hit.GetDescriptorSets(2, "compute")) do
		descriptor_sets[#descriptor_sets + 1] = set
	end

	local pipeline = EasyPipeline.Compute{
		name = "tessellation_test_trace",
		DescriptorSetCount = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		storage_buffers = {{binding_index = 0}},
		descriptor_sets = descriptor_sets,
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = 0) buffer Results { float results[]; };
			layout(set = 0, binding = 1) uniform accelerationStructureEXT scene;
		]] .. hit.GetGLSL(2),
		shader = [[
			void main() {
				rayQueryEXT query;
				vec3 dir = normalize(vec3(0.02, 0.01, -1.0));
				rayQueryInitializeEXT(query, scene, gl_RayFlagsOpaqueEXT, 0xFF, vec3(0.0), 0.0, dir, 100.0);
				while (rayQueryProceedEXT(query)) {}

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
					results[0] = 0.0;
					return;
				}

				uint instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
				scene_triangle tri = scene_hit_tri(instance, scene_query_primitive(query, true));
				float t = rayQueryGetIntersectionTEXT(query, true);
				results[0] = 1.0;
				results[1] = abs(dot(dir * t - tri.v0, tri.normal));
				results[2] = t * dir.z;
			}
		]],
	}
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, results, results:GetSize())
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", 1, 1, 0, instances.tlas)
	hit.Bind(pipeline, 1, 2)
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "compute", memoryBarrier = true}
	pipeline.pipeline:Dispatch(cmd, 1, 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	local out = ffi.cast("float *", results:Map())
	local found, plane_distance, depth = out[0], out[1], out[2]
	results:Remove()
	pipeline:Remove()
	entity:Remove()
	T(found)["=="](1)
	T(plane_distance < 0.001)["=="](true)
	T(math.abs(depth + 3.0) < 0.02)["=="](true)
end)
