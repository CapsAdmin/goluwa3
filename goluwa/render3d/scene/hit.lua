local render = import("goluwa/render/render.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local hit = {}
-- a hit is an instance (the custom index of the top level structure) and a primitive of its mesh. everything about it
-- is read from the scene store: the instance says which mesh, material and transform, the mesh where its vertices and
-- indices are. the three tables take consecutive bindings from `binding`
hit.BINDING_COUNT = 3

function hit.GetDescriptorSets(binding, stage, tlas_binding)
	local sets = {}

	if tlas_binding then
		sets[1] = {type = "acceleration_structure_khr", binding_index = tlas_binding, stageFlags = stage}
	end

	for i = 0, hit.BINDING_COUNT - 1 do
		sets[#sets + 1] = {type = "storage_buffer", binding_index = binding + i, stageFlags = stage}
	end

	return sets
end

do
	-- a set that a command buffer is still using can't be written to, so only what changed is
	local bound = setmetatable({}, {__mode = "k"})

	function hit.Bind(pipeline, desc, binding)
		local tlas_table, data_table = instances.GetTables()
		local mesh_table = meshes.GetTable()
		bound[pipeline] = bound[pipeline] or {}
		local last = bound[pipeline][desc]

		if not last then
			last = {}
			bound[pipeline][desc] = last
		end

		local buffers = {mesh_table:GetBuffer(), data_table:GetBuffer(), tlas_table:GetBuffer()}

		for i = 1, 3 do
			if last[i] ~= buffers[i] then
				pipeline:UpdateDescriptorSet("storage_buffer", desc, binding + i - 1, 0, buffers[i], buffers[i]:GetSize())
				last[i] = buffers[i]
			end
		end
	end
end

function hit.GetSceneGLSL(name, tlas_binding)
	return "#extension GL_EXT_ray_query : require\nlayout(set = 0, binding = " .. tlas_binding .. ") uniform accelerationStructureEXT " .. name .. ";\n"
end

-- declarations, the triangle of a hit in world space and its uvs. a triangle's normal is the normalized cross product
-- of its edges (the winding of the mesh), its material the row of the instance's material
function hit.GetGLSL(binding)
	return ([[
		#extension GL_EXT_buffer_reference : require
		#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

		struct scene_mesh {
			uint64_t vertex_address;
			uint64_t index_address;
			uint64_t blas_address;
			uint triangle_count;
			uint vertex_stride;
			uint flags;
			uint pad;
		};

		struct scene_instance_data {
			uint mesh_row;
			uint material_row;
			uint flags;
			uint user;
		};

		struct scene_tlas_instance {
			float m[12];
			uint custom_and_mask;
			uint flags;
			uint64_t blas;
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneMeshes {
			scene_mesh scene_meshes[];
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneInstances {
			scene_instance_data scene_instances[];
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneTLASInstances {
			scene_tlas_instance scene_tlas_instances[];
		};

		layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer SceneVertexData { float v[]; };
		layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer SceneIndexData { uint i[]; };

		#define SCENE_INSTANCE_DOUBLE_SIDED 1u
		#define SCENE_INSTANCE_ALPHA_TEST 2u

		struct scene_bvh_triangle {
			vec3 v0;
			vec3 e1;
			vec3 e2;
			vec3 normal;
			vec3 emissive;
			uint material;
		};

		struct scene_bvh_uv {
			vec2 uv0;
			vec2 uv1;
			vec2 uv2;
			vec3 blend;
		};

		uint scene_instance_material(uint instance) {
			return scene_instances[instance].material_row;
		}

		uint scene_instance_flags(uint instance) {
			return scene_instances[instance].flags;
		}

		uint scene_mesh_index(scene_mesh mesh, uint k) {
			if ((mesh.flags & 2u) == 0u) return k;

			SceneIndexData data = SceneIndexData(mesh.index_address);

			if ((mesh.flags & 1u) != 0u) return data.i[k];

			uint word = data.i[k >> 1u];
			return (k & 1u) != 0u ? word >> 16u : word & 0xFFFFu;
		}

		vec3 scene_hit_world(scene_tlas_instance t, SceneVertexData vertices, uint base) {
			vec3 p = vec3(vertices.v[base], vertices.v[base + 1u], vertices.v[base + 2u]);
			return vec3(
				dot(vec3(t.m[0], t.m[1], t.m[2]), p) + t.m[3],
				dot(vec3(t.m[4], t.m[5], t.m[6]), p) + t.m[7],
				dot(vec3(t.m[8], t.m[9], t.m[10]), p) + t.m[11]
			);
		}

		scene_bvh_triangle scene_hit_tri(uint instance, uint primitive) {
			scene_instance_data data = scene_instances[instance];
			scene_mesh mesh = scene_meshes[data.mesh_row];
			scene_tlas_instance t = scene_tlas_instances[instance];
			SceneVertexData vertices = SceneVertexData(mesh.vertex_address);
			uint stride = mesh.vertex_stride / 4u;
			vec3 p0 = scene_hit_world(t, vertices, scene_mesh_index(mesh, primitive * 3u) * stride);
			vec3 p1 = scene_hit_world(t, vertices, scene_mesh_index(mesh, primitive * 3u + 1u) * stride);
			vec3 p2 = scene_hit_world(t, vertices, scene_mesh_index(mesh, primitive * 3u + 2u) * stride);
			scene_bvh_triangle tri;
			tri.v0 = p0;
			tri.e1 = p1 - p0;
			tri.e2 = p2 - p0;
			tri.normal = normalize(cross(tri.e1, tri.e2));
			tri.emissive = vec3(0.0);
			tri.material = data.material_row;
			return tri;
		}

		scene_bvh_uv scene_hit_uv(uint instance, uint primitive) {
			scene_mesh mesh = scene_meshes[scene_instances[instance].mesh_row];
			SceneVertexData vertices = SceneVertexData(mesh.vertex_address);
			uint stride = mesh.vertex_stride / 4u;
			uint a = scene_mesh_index(mesh, primitive * 3u) * stride;
			uint b = scene_mesh_index(mesh, primitive * 3u + 1u) * stride;
			uint c = scene_mesh_index(mesh, primitive * 3u + 2u) * stride;
			scene_bvh_uv uv;
			uv.uv0 = vec2(vertices.v[a + 6u], vertices.v[a + 7u]);
			uv.uv1 = vec2(vertices.v[b + 6u], vertices.v[b + 7u]);
			uv.uv2 = vec2(vertices.v[c + 6u], vertices.v[c + 7u]);
			uv.blend = vec3(vertices.v[a + 12u], vertices.v[b + 12u], vertices.v[c + 12u]);
			return uv;
		}
	]]):format(binding, binding + 1, binding + 2)
end

-- trace helpers over a top level structure: the closest hit between t_min and t_max, and whether there is one. they
-- see the solid instances only, what the ray flies through (see through materials, alpha tested leaves) is not hit
function hit.GetTraceGLSL(tlas_name)
	return [[
		struct scene_bvh_hit {
			vec3 position;
			vec3 normal;
			vec3 emissive;
			float distance;
			uint instance;
			uint primitive;
		};

		bool scene_bvh_trace(vec3 origin, vec3 dir, float t_min, float t_max, out scene_bvh_hit hit) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. tlas_name .. [[, gl_RayFlagsOpaqueEXT, ]] .. string.format("0x%02X", instances.MASK_SOLID) .. [[, origin, t_min, dir, t_max);

			while (rayQueryProceedEXT(query)) {}

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return false;

			hit.instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
			hit.primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
			scene_bvh_triangle tri = scene_hit_tri(hit.instance, hit.primitive);
			hit.distance = rayQueryGetIntersectionTEXT(query, true);
			hit.position = origin + dir * hit.distance;
			hit.emissive = tri.emissive;
			hit.normal = dot(tri.normal, dir) > 0.0 ? -tri.normal : tri.normal;
			return true;
		}

		bool scene_bvh_occluded(vec3 origin, vec3 dir, float t_min, float t_max) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. tlas_name .. [[, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, ]] .. string.format("0x%02X", instances.MASK_SOLID) .. [[, origin, t_min, dir, t_max);

			while (rayQueryProceedEXT(query)) {}

			return rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT;
		}
	]]
end

-- without ray queries nothing is hit
function hit.GetStubTraceGLSL()
	return [[
		struct scene_bvh_hit {
			vec3 position;
			vec3 normal;
			vec3 emissive;
			float distance;
			uint instance;
			uint primitive;
		};

		bool scene_bvh_trace(vec3 origin, vec3 dir, float t_min, float t_max, out scene_bvh_hit hit) {
			return false;
		}

		bool scene_bvh_occluded(vec3 origin, vec3 dir, float t_min, float t_max) {
			return false;
		}
	]]
end

function hit.IsSupported()
	return render.GetDevice().ray_query_supported
end

return hit
