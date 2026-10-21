local render = import("goluwa/render/render.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local hit = {}
hit.BINDING_COUNT = 3

function hit.GetDescriptorSets(binding, stage, tlas_binding)
	local sets = {}

	if tlas_binding then
		sets[1] = {
			type = "acceleration_structure_khr",
			binding_index = tlas_binding,
			stageFlags = stage,
		}
	end

	for i = 0, hit.BINDING_COUNT - 1 do
		sets[#sets + 1] = {type = "storage_buffer", binding_index = binding + i, stageFlags = stage}
	end

	return sets
end

do
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

function hit.GetCoreGLSL()
	return [[
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
			uint mask_lod;
			vec4 bounds;
			vec2 lod;
			vec2 pad;
		};

		struct scene_tlas_instance {
			float m[12];
			uint custom_and_mask;
			uint flags;
			uint64_t blas;
		};

		layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer SceneVertexData { float v[]; };
		layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer SceneIndexData { uint i[]; };

		#define SCENE_INSTANCE_DOUBLE_SIDED 1u
		#define SCENE_INSTANCE_ALPHA_TEST 2u

		struct scene_triangle {
			vec3 v0;
			vec3 e1;
			vec3 e2;
			vec3 normal;
			vec3 emissive;
			uint material;
		};

		struct scene_uv {
			vec2 uv0;
			vec2 uv1;
			vec2 uv2;
			vec3 blend;
		};

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

	]]
end

function hit.GetGLSL(binding)
	return hit.GetCoreGLSL() .. (
			[[
		layout(scalar, set = 0, binding = %d) readonly buffer SceneMeshes {
			scene_mesh scene_meshes[];
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneInstances {
			scene_instance_data scene_instances[];
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneTLASInstances {
			scene_tlas_instance scene_tlas_instances[];
		};

		uint scene_instance_material(uint instance) {
			return scene_instances[instance].material_row;
		}

		uint scene_instance_flags(uint instance) {
			return scene_instances[instance].flags;
		}

		scene_triangle scene_hit_tri(uint instance, uint primitive) {
			scene_instance_data data = scene_instances[instance];
			scene_mesh mesh = scene_meshes[data.mesh_row];
			scene_tlas_instance t = scene_tlas_instances[instance];
			SceneVertexData vertices = SceneVertexData(mesh.vertex_address);
			uint stride = mesh.vertex_stride / 4u;
			vec3 p0 = scene_hit_world(t, vertices, scene_mesh_index(mesh, primitive * 3u) * stride);
			vec3 p1 = scene_hit_world(t, vertices, scene_mesh_index(mesh, primitive * 3u + 1u) * stride);
			vec3 p2 = scene_hit_world(t, vertices, scene_mesh_index(mesh, primitive * 3u + 2u) * stride);
			scene_triangle tri;
			tri.v0 = p0;
			tri.e1 = p1 - p0;
			tri.e2 = p2 - p0;
			tri.normal = normalize(cross(tri.e1, tri.e2));
			tri.emissive = vec3(0.0);
			tri.material = data.material_row;
			return tri;
		}

		float scene_hit_texture_lod(scene_triangle tri, scene_uv uv, ivec2 size, float width) {
			float area = 0.5 * length(cross(tri.e1, tri.e2));
			vec2 d1 = uv.uv1 - uv.uv0;
			vec2 d2 = uv.uv2 - uv.uv0;
			float uv_area = 0.5 * abs(d1.x * d2.y - d1.y * d2.x);
			float texels = uv_area * float(size.x) * float(size.y);

			if (area <= 1e-12 || texels <= 1e-9) return 0.0;

			return max(log2(width / sqrt(area / texels)), 0.0);
		}

		scene_uv scene_hit_uv(uint instance, uint primitive) {
			scene_mesh mesh = scene_meshes[scene_instances[instance].mesh_row];
			SceneVertexData vertices = SceneVertexData(mesh.vertex_address);
			uint stride = mesh.vertex_stride / 4u;
			uint a = scene_mesh_index(mesh, primitive * 3u) * stride;
			uint b = scene_mesh_index(mesh, primitive * 3u + 1u) * stride;
			uint c = scene_mesh_index(mesh, primitive * 3u + 2u) * stride;
			scene_uv uv;
			uv.uv0 = vec2(vertices.v[a + 6u], vertices.v[a + 7u]);
			uv.uv1 = vec2(vertices.v[b + 6u], vertices.v[b + 7u]);
			uv.uv2 = vec2(vertices.v[c + 6u], vertices.v[c + 7u]);
			uv.blend = vec3(vertices.v[a + 12u], vertices.v[b + 12u], vertices.v[c + 12u]);
			return uv;
		}
	]]
		):format(binding, binding + 1, binding + 2)
end

function hit.GetTraceGLSL(tlas_name)
	return [[
		struct scene_trace_hit {
			vec3 position;
			vec3 normal;
			vec3 emissive;
			float distance;
			uint instance;
			uint primitive;
		};

		bool scene_trace(vec3 origin, vec3 dir, float t_min, float t_max, out scene_trace_hit hit) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. tlas_name .. [[, gl_RayFlagsOpaqueEXT, ]] .. string.format("0x%02X", instances.MASK_SOLID) .. [[, origin, t_min, dir, t_max);

			while (rayQueryProceedEXT(query)) {}

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return false;

			hit.instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
			hit.primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
			scene_triangle tri = scene_hit_tri(hit.instance, hit.primitive);
			hit.distance = rayQueryGetIntersectionTEXT(query, true);
			hit.position = origin + dir * hit.distance;
			hit.emissive = tri.emissive;
			hit.normal = dot(tri.normal, dir) > 0.0 ? -tri.normal : tri.normal;
			return true;
		}

		bool scene_occluded(vec3 origin, vec3 dir, float t_min, float t_max) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. tlas_name .. [[, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, ]] .. string.format("0x%02X", instances.MASK_SOLID) .. [[, origin, t_min, dir, t_max);

			while (rayQueryProceedEXT(query)) {}

			return rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT;
		}
	]]
end

function hit.GetStubTraceGLSL()
	return [[
		struct scene_trace_hit {
			vec3 position;
			vec3 normal;
			vec3 emissive;
			float distance;
			uint instance;
			uint primitive;
		};

		bool scene_trace(vec3 origin, vec3 dir, float t_min, float t_max, out scene_trace_hit hit) {
			return false;
		}

		bool scene_occluded(vec3 origin, vec3 dir, float t_min, float t_max) {
			return false;
		}
	]]
end

function hit.IsSupported()
	return render.GetDevice().ray_query_supported
end

return hit
