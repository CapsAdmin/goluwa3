local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local event = import("goluwa/event.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local gbuffer_extras = import("goluwa/render3d/gbuffer_extras.lua")
local geometry_block = import("goluwa/render3d/geometry_block.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local gbuffer_inspect = import("goluwa/render3d/gbuffer_inspect.lua")
local camera_block = geometry_block.New("gbuffer_data", {
	{"normal_source", "int"},
}, function(self, block)
	block.normal_source = gbuffer_inspect.GetNormalSourceIndex()
end)

local function build_base_pass(fragment_shader, enable_vertex_animation)
	local uniform_buffers = model_pipeline.GetPBRUniformBuffers()
	table.insert(uniform_buffers, 1, camera_block)
	return {
		name = "gbuffer",
		on_pre_draw = function(self, cmd)
			for _, extra in ipairs(gbuffer_extras) do
				if render3d.pipelines[extra.name] then extra.PreDraw(cmd) end
			end
		end,
		on_draw = function(self, cmd)
			local draw_geometry = render3d.GetDrawGeometry()

			if draw_geometry then
				draw_geometry(cmd)
				return
			end

			gbuffer_instancing.Reset()
			event.Call("PreDraw3D", dt)
			event.Call("Draw3DGeometry", dt)
			gbuffer_instancing.Flush()

			for _, extra in ipairs(gbuffer_extras) do
				local pipeline = render3d.pipelines[extra.name]

				if pipeline then extra.Draw(pipeline, cmd) end
			end
		end,
		ColorFormat = gbuffer_layout.color_format,
		DepthFormat = gbuffer_layout.DEPTH_FORMAT,
		DepthClear = 0.0,
		fragment = {
			uniform_buffers = uniform_buffers,
			shader = model_pipeline.BuildPBRSurfaceGlsl("gbuffer_data") .. surface_weather.GetGLSL("gbuffer_data") .. surface_conditions.GetGLSL("gbuffer_data") .. surface_overlays.GetGLSL("gbuffer_data") .. gbuffer_layout.GetEncodeGLSL() .. [[

					vec3 get_screen_velocity(vec3 world_pos, vec3 prev_world_pos) {
						vec4 clip = gbuffer_data.projection * gbuffer_data.view * vec4(world_pos, 1.0);
						vec4 prev_view_pos = gbuffer_data.prev_view * vec4(prev_world_pos, 1.0);
						vec4 prev_clip = gbuffer_data.prev_projection * prev_view_pos;

						if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) {
							return vec3(0.0, 0.0, -prev_view_pos.z);
						}

						vec2 uv = (clip.xy / clip.w) * 0.5;
						vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5;
						return vec3(uv - prev_uv, -prev_view_pos.z);
					}

					void discard_lod_fade() {
						float fade = in_lod_fade;
						float t = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));

						if (Billboard) {
							float facing = abs(dot(normalize(in_normal), normalize(gbuffer_data.camera_position.xyz - in_position)));
							float own = facing * facing;
							float visible = smoothstep(0.35, 0.7, own / max(own, 0.5 * (1.0 - own)));

							if (t >= visible) discard;
						}

						if (abs(fade) < 0.0001) return;

						if (fade > 0.0 ? t >= 1.0 - fade : t < -fade) discard;
					}

					void write_velocity(vec3 world_pos, vec3 prev_world_pos) {
						vec3 motion = get_screen_velocity(world_pos, prev_world_pos);
						set_velocity(motion.xy);
						set_prev_view_depth(motion.z);
					}

			]] .. fragment_shader,
		},
		DepthClamp = false,
		Discard = false,
		PolygonMode = "fill",
		LineWidth = 1.0,
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		DepthBias = false,
		LogicOpEnabled = false,
		LogicOp = "copy",
		BlendConstants = {0.0, 0.0, 0.0, 0.0},
		Blend = false,
		ColorWriteMask = "rgba",
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "greater_or_equal",
		DepthBoundsTest = false,
		StencilTest = false,
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			velocity = true,
			lod_fade = true,
			instance_overlay = true,
			instance_dynamic = true,
			effect_space = true,
			camera_block_name = "gbuffer_data",
			uniform_buffers = {
				camera_block,
			},
			enable_vertex_animation = enable_vertex_animation,
		},
	}
end

local function build_instanced_pass(fragment_shader)
	local pass = build_base_pass(fragment_shader, true)
	pass.name = "gbuffer_instanced"
	pass.draw_in_prerender = false
	pass.dont_create_framebuffers = true
	pass.on_draw = nil
	pass.vertex = model_pipeline.CreateInstancedVertexStage{
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		velocity = true,
		lod_fade = true,
		instance_overlay = true,
		instance_dynamic = true,
		effect_space = true,
		camera_block_name = "gbuffer_data",
		uniform_buffers = {
			camera_block,
		},
		enable_vertex_animation = true,
	}
	return pass
end

local multi_draw_block = {
	name = "gbuffer_draw",
	binding_index = 4,
	block = {
		{"batches", "uint64_t"},
		{"instances", "uint64_t"},
		{"prev_instances", "uint64_t"},
		{"batch_ids", "uint64_t"},
		{"time", "float"},
		{"prev_time", "float"},
		{"detail_time", "float"},
		{"prev_detail_time", "float"},
	},
	write = function(self, block)
		block.batches = self.draw_batches_address
		block.instances = self.draw_instances_address
		block.prev_instances = self.draw_prev_instances_address
		block.batch_ids = self.draw_batch_ids_address or 0
		block.time = atmosphere.GetWindTime()
		block.prev_time = atmosphere.GetPreviousWindTime()
		block.detail_time = atmosphere.GetWindDetailTime()
		block.prev_detail_time = atmosphere.GetPreviousWindDetailTime()
		return block
	end,
}

local function build_multi_draw_pass(fragment_shader)
	local pass = build_base_pass(fragment_shader, true)
	pass.name = "gbuffer_multi_draw"
	pass.draw_in_prerender = false
	pass.dont_create_framebuffers = true
	pass.on_draw = nil
	pass.on_pre_draw = nil
	pass.vertex = model_pipeline.CreateMultiDrawVertexStage{
		shell_expr = "((abs(in_tangent.w) > 1.5 && abs(in_tangent.w) < 2.5) || abs(in_tangent.w) > 3.5 ? 0.0 : batch_data.b[batch_index].m_displacement_model.HeightShell * (1.0 - batch_data.b[batch_index].m_displacement_model.HeightMidlevel))",
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		velocity = true,
		lod_fade = true,
		instance_overlay = true,
		instance_dynamic = true,
		effect_space = true,
		camera_block_name = "gbuffer_data",
		uniform_buffers = {camera_block, multi_draw_block},
		batches_expr = "gbuffer_draw.batches",
		instances_expr = "gbuffer_draw.instances",
		prev_instances_expr = "gbuffer_draw.prev_instances",
		batch_index_expr = "(gbuffer_draw.batch_ids != 0ul ? PBRBatchIdData(gbuffer_draw.batch_ids).ids[gl_InstanceIndex].x : uint(gl_DrawID))",
		time_expr = "gbuffer_draw.time",
		prev_time_expr = "gbuffer_draw.prev_time",
		detail_time_expr = "gbuffer_draw.detail_time",
		prev_detail_time_expr = "gbuffer_draw.prev_detail_time",
	}
	pass.fragment.uniform_buffers = {camera_block, multi_draw_block}
	pass.fragment.custom_declarations = string.format(
			"layout(location = %d) flat in uint in_batch;\nlayout(location = %d) flat in uint in_instance;\nlayout(location = %d) flat in uint in_triangle;\n",
			pass.vertex.batch_location,
			pass.vertex.batch_location + 1,
			pass.vertex.batch_location + 2
		) .. model_pipeline.BuildPBRBatchRecordGlsl("PBRBatchData(gbuffer_draw.batches).b[in_batch]") .. [[
layout(buffer_reference, scalar) readonly buffer PrismVertexData { float v[]; };
layout(buffer_reference, scalar) readonly buffer PrismIndexData { uint i[]; };
layout(buffer_reference, scalar) readonly buffer PrismInstanceData { mat4 worlds[]; };
]] .. string.format(
			"const uint PRISM_VERTEX_STRIDE = %du;\nconst uint PRISM_VERTEX_POSITION = %du;\nconst uint PRISM_VERTEX_NORMAL = %du;\nconst uint PRISM_VERTEX_UV = %du;\nconst uint PRISM_VERTEX_PIVOT = %du;\n",
			vertex_layout.FloatStride,
			vertex_layout.GetFloatOffset("position"),
			vertex_layout.GetFloatOffset("normal"),
			vertex_layout.GetFloatOffset("uv"),
			vertex_layout.GetFloatOffset("pivot")
		)
	return pass
end

local function build_ssdm_fragment_shader(write_depth, prism)
	return [[
		struct SSDMData {
			vec2 uv;
			float height;
			vec3 world_pos;
		};

		vec3 get_view_dir_world(vec3 world_pos) {
			return normalize(gbuffer_data.camera_position.xyz - world_pos);
		}

		float get_projected_depth(vec3 world_pos) {
			vec4 clip_pos = gbuffer_data.projection * gbuffer_data.view * vec4(world_pos, 1.0);
			float clip_w = max(clip_pos.w, 0.0001);
			return clamp(clip_pos.z / clip_w, 0.0, 1.0);
		}

		const float DECAL_DEPTH_BIAS_RELATIVE = 0.002;
		const float DECAL_DEPTH_BIAS_ABSOLUTE = 0.002;

		]] .. (
			prism and
			[=[		struct PrismMesh {
			PrismVertexData vertices;
			PrismIndexData indices;
			bool indexed;
			bool index_32;
			mat4 world;
			mat3 normal_matrix;
			float lift;
		};

		uint prism_index(PrismMesh mesh, uint tri, uint k) {
			uint index = tri * 3u + k;

			if (!mesh.indexed) {
				return index;
			}

			if (mesh.index_32) {
				return mesh.indices.i[index];
			}

			uint word = mesh.indices.i[index >> 1];
			return (index & 1u) != 0u ? word >> 16 : word & 0xFFFFu;
		}

		vec3 prism_position(PrismMesh mesh, uint index) {
			uint at = index * PRISM_VERTEX_STRIDE + PRISM_VERTEX_POSITION;
			return (mesh.world * vec4(mesh.vertices.v[at], mesh.vertices.v[at + 1u], mesh.vertices.v[at + 2u], 1.0)).xyz;
		}

		vec3 prism_normal(PrismMesh mesh, uint index) {
			uint at = index * PRISM_VERTEX_STRIDE + PRISM_VERTEX_NORMAL;
			return normalize(mesh.normal_matrix * vec3(mesh.vertices.v[at], mesh.vertices.v[at + 1u], mesh.vertices.v[at + 2u]));
		}

		vec2 prism_uv(PrismMesh mesh, uint index) {
			uint at = index * PRISM_VERTEX_STRIDE + PRISM_VERTEX_UV;
			return vec2(mesh.vertices.v[at], mesh.vertices.v[at + 1u]);
		}

		bool prism_locate(PrismMesh mesh, inout uint tri, vec3 p, out float lambda, out vec2 uv) {
			uint i0 = 0u;
			uint i1 = 0u;
			uint i2 = 0u;
			vec3 b = vec3(1.0, 0.0, 0.0);
			bool inside = false;
			lambda = 0.0;

			for (int hop = 0; hop < 24; hop++) {
				i0 = prism_index(mesh, tri, 0u);
				i1 = prism_index(mesh, tri, 1u);
				i2 = prism_index(mesh, tri, 2u);
				vec3 b0 = prism_position(mesh, i0);
				vec3 b1 = prism_position(mesh, i1);
				vec3 b2 = prism_position(mesh, i2);
				vec3 d0 = prism_normal(mesh, i0) * mesh.lift;
				vec3 d1 = prism_normal(mesh, i1) * mesh.lift;
				vec3 d2 = prism_normal(mesh, i2) * mesh.lift;
				vec3 face = normalize(cross(b1 - b0, b2 - b0));
				float rise = dot(d0 + d1 + d2, face) / 3.0;
				lambda = dot(p - b0, face) / (abs(rise) < 1e-6 ? 1e-6 : rise);

				for (int k = 0; k < 3; k++) {
					vec3 v0 = b0 + d0 * lambda;
					float f = dot(p - v0, cross(b1 + d1 * lambda - v0, b2 + d2 * lambda - v0));
					float l2 = lambda + 1e-3;
					vec3 w0 = b0 + d0 * l2;
					float f2 = dot(p - w0, cross(b1 + d1 * l2 - w0, b2 + d2 * l2 - w0));
					float df = (f2 - f) / 1e-3;
					lambda -= abs(df) > 1e-12 ? f / df : 0.0;
				}

				vec3 v0 = b0 + d0 * lambda;
				vec3 e1 = b1 + d1 * lambda - v0;
				vec3 e2 = b2 + d2 * lambda - v0;
				vec3 n = cross(e1, e2);
				float nn = max(dot(n, n), 1e-20);
				vec3 w = p - v0;
				b.y = dot(cross(w, e2), n) / nn;
				b.z = dot(cross(e1, w), n) / nn;
				b.x = 1.0 - b.y - b.z;
				float lowest = min(b.x, min(b.y, b.z));

				if (lowest >= -1e-4) {
					inside = true;
					break;
				}

				uint pivot_at = i0 * PRISM_VERTEX_STRIDE + PRISM_VERTEX_PIVOT;
				int slot = b.x == lowest ? 0 : (b.y == lowest ? 1 : 2);
				float next = mesh.vertices.v[pivot_at + uint(slot)];

				if (next < 0.0) {
					break;
				}

				tri = uint(next + 0.5);
			}

			b = max(b, vec3(0.0));
			b /= max(b.x + b.y + b.z, 1e-6);
			uv = prism_uv(mesh, i0) * b.x + prism_uv(mesh, i1) * b.y + prism_uv(mesh, i2) * b.z;
			return inside;
		}

		bool prism_in_rock(float lambda, float midlevel, vec2 uv, vec2 duv1, vec2 duv2) {
			if (lambda <= 0.0) return true;
			if (lambda >= 1.0) return false;
			return midlevel + lambda * (1.0 - midlevel) <= textureGrad(TEXTURE(displacement_model.HeightTexture), uv, duv1, duv2).r;
		}

		SSDMData get_prism_data(float shell, vec2 duv1, vec2 duv2) {
			SSDMData data;
			data.uv = in_uv;
			data.height = 0.0;
			data.world_pos = in_position;
			float midlevel = displacement_model.HeightMidlevel;
			PrismMesh mesh;
			uvec4 addresses = PBRBatchData(gbuffer_draw.batches).b[in_batch].addresses;
			mesh.vertices = PrismVertexData(packUint2x32(addresses.xy));
			mesh.indexed = (addresses.z | addresses.w) != 0u;
			mesh.indices = PrismIndexData(packUint2x32(addresses.zw));
			mesh.index_32 = PBRBatchData(gbuffer_draw.batches).b[in_batch].index_is_32 != 0u;
			mesh.world = PrismInstanceData(gbuffer_draw.instances).worlds[in_instance];
			mesh.normal_matrix = transpose(inverse(mat3(mesh.world)));
			mesh.lift = shell * (1.0 - midlevel);
			bool skirt = abs(in_tangent.w) > 2.5;
			bool base_copy = !skirt && abs(in_tangent.w) > 1.5;
			vec3 eye = gbuffer_data.camera_position.xyz;
			vec3 to_fragment = in_position - eye;
			float t_fragment = length(to_fragment);
			vec3 dir = to_fragment / t_fragment;
			float along_normal = dot(dir, normalize(in_normal));
			uint tri = in_triangle;
			vec2 uv = in_uv;
			float lambda = base_copy ? 0.0 : 1.0;
			bool forward = along_normal < 0.0 && !base_copy;

			if (base_copy && along_normal >= 0.0) {
				discard;
			}

			if (skirt) {
				tri = uint(mesh.vertices.v[prism_index(mesh, in_triangle, 0u) * PRISM_VERTEX_STRIDE + PRISM_VERTEX_PIVOT] + 0.5);
				prism_locate(mesh, tri, in_position, lambda, uv);
				uint probe_tri = tri;
				float probe_lambda;
				vec2 probe_uv;
				bool interior_toward_eye = prism_locate(mesh, probe_tri, eye + dir * max(t_fragment - 0.02, 0.0), probe_lambda, probe_uv);
				forward = !interior_toward_eye;
			}

			float direction = forward ? 1.0 : -1.0;
			float base_dt = mesh.lift / float(get_height_layers() * 2) / max(abs(along_normal), 0.1);
			float dt = base_dt;
			float t = t_fragment;
			bool rock = prism_in_rock(lambda, midlevel, uv, duv1, duv2);
			uint rock_tri = tri;
			float free_t = -1.0;
			float rock_t = -1.0;

			if (forward && rock) {
				free_t = t;
				rock_t = t;
			}

			for (int i = 0; i < 256 && !(forward && rock_t >= 0.0); i++) {
				float next_t = t + direction * dt;

				if (next_t <= 0.0) {
					break;
				}

				float next_lambda;
				vec2 next_uv;
				bool valid = prism_locate(mesh, tri, eye + dir * next_t, next_lambda, next_uv);

				if (!valid || next_lambda < -0.25 || next_lambda > 1.25) {
					break;
				}

				bool next_rock = prism_in_rock(next_lambda, midlevel, next_uv, duv1, duv2);

				if (!next_rock && next_lambda > 0.0 && next_lambda < 1.0) {
					float gap = midlevel + next_lambda * (1.0 - midlevel) - textureGrad(TEXTURE(displacement_model.HeightTexture), next_uv, duv1, duv2).r;
					dt = clamp(gap * mesh.lift / max(abs(along_normal), 0.05) * 0.5, mesh.lift / 256.0, base_dt);
				} else {
					dt = base_dt;
				}

				if (forward && next_rock && !rock) {
					free_t = t;
					rock_t = next_t;
					rock_tri = tri;
				} else if (!forward && rock && !next_rock) {
					free_t = next_t;
					rock_t = t;
					rock_tri = tri;
				}

				t = next_t;
				rock = next_rock;
			}

			if (rock_t < 0.0) {
				discard;
			}

			tri = rock_tri;
			float lo = min(free_t, rock_t);
			float hi = max(free_t, rock_t);

			for (int i = 0; i < 12 && hi - lo > 1e-5; i++) {
				float mid = 0.5 * (lo + hi);
				float mid_lambda;
				vec2 mid_uv;
				bool mid_valid = prism_locate(mesh, tri, eye + dir * mid, mid_lambda, mid_uv);

				if (mid_valid && prism_in_rock(mid_lambda, midlevel, mid_uv, duv1, duv2)) {
					hi = mid;
				} else {
					lo = mid;
				}
			}

			float hit_lambda;
			vec2 hit_uv;
			bool inside = prism_locate(mesh, tri, eye + dir * hi, hit_lambda, hit_uv);

			if (!inside || (displacement_model.HeightShellClip > 0.5 && (hit_uv.x < -0.001 || hit_uv.y < -0.001 || hit_uv.x > 1.001 || hit_uv.y > 1.001))) {
				discard;
			}

			data.uv = hit_uv;
			data.height = clamp(hit_lambda, 0.0, 1.0) * mesh.lift;
			data.world_pos = eye + dir * hi;
			return data;
		}
]=] or
			""
		) .. [[

		SSDMData get_ssdm_data(mat3 tbn) {
			SSDMData data;
			data.uv = in_uv;
			data.height = 0.0;
			data.world_pos = in_position;
			vec3 dp1 = dFdx(in_position);
			vec3 dp2 = dFdy(in_position);
			vec2 duv1 = dFdx(in_uv);
			vec2 duv2 = dFdy(in_uv);

			if (!has_heightmap()) {
				return data;
			}

]] .. (
			prism and
			[=[
			if (displacement_model.HeightShell > 0.0) {
				return get_prism_data(displacement_model.HeightShell, duv1, duv2);
			}
]=] or
			""
		) .. [[

			vec3 N = tbn[2];
			vec3 dp2perp = cross(dp2, N);
			vec3 dp1perp = cross(N, dp1);
			float det = dot(dp1, dp2perp);

			if (abs(det) < 1e-12) {
				return data;
			}

			vec3 grad_u = (dp2perp * duv1.x + dp1perp * duv2.x) / det;
			vec3 grad_v = (dp2perp * duv1.y + dp1perp * duv2.y) / det;
			vec3 V = get_view_dir_world(in_position);
			float facing = dot(V, N);
			float view_n = max(facing, 0.05);
			vec2 height_size = vec2(textureSize(TEXTURE(displacement_model.HeightTexture), 0));
			float texels_per_pixel = max(length(duv1 * height_size), length(duv2 * height_size));
			float fade = (1.0 - smoothstep(2.0, 6.0, texels_per_pixel)) * smoothstep(0.04, 0.2, facing);

			if (fade <= 0.0) {
				return data;
			}

			float thickness = displacement_model.HeightScale * fade / sqrt(max(length(grad_u) * length(grad_v), 1e-12));
			vec2 uv_per_depth = -vec2(dot(grad_u, V), dot(grad_v, V)) / view_n;
			float midlevel = displacement_model.HeightMidlevel;
			int layer_count = clamp(int(float(get_height_layers()) * (0.5 + 1.5 * (1.0 - view_n))), 4, 64);
			float layer_height = 1.0 / float(layer_count);
			vec2 top_uv = in_uv - uv_per_depth * (1.0 - midlevel) * thickness;
			vec2 uv_step = uv_per_depth * thickness * layer_height;
			float level = 1.0;
			vec2 current_uv = top_uv;
			float current_height = textureGrad(TEXTURE(displacement_model.HeightTexture), current_uv, duv1, duv2).r;
			float previous_level = level;

			for (int i = 0; i < 64; i++) {
				if (i >= layer_count || level <= current_height) {
					break;
				}

				previous_level = level;
				level -= layer_height;
				current_uv += uv_step;
				current_height = textureGrad(TEXTURE(displacement_model.HeightTexture), current_uv, duv1, duv2).r;
			}

			float hit_level = level;

			if (level <= current_height) {
				float below = level;
				float above = previous_level;

				for (int i = 0; i < 5; i++) {
					float mid = 0.5 * (below + above);
					vec2 mid_uv = top_uv + uv_per_depth * (1.0 - mid) * thickness;
					float mid_height = textureGrad(TEXTURE(displacement_model.HeightTexture), mid_uv, duv1, duv2).r;

					if (mid <= mid_height) {
						below = mid;
					} else {
						above = mid;
					}
				}

				hit_level = 0.5 * (below + above);
			}

			data.uv = top_uv + uv_per_depth * (1.0 - hit_level) * thickness;
			data.height = (hit_level - midlevel) * thickness;
			data.world_pos = in_position + V * (max(data.height, 0.0) / view_n);
			return data;
		}

		void main() {
			gbuffer_set_defaults();
			discard_lod_fade();
			mat3 tbn = get_tbn();
			SSDMData displacement = get_ssdm_data(tbn);
			float alpha = get_alpha_uv(displacement.uv);

			if (Decal && DecalFade) {
				float fade = in_texture_blend;

				if (fade < 0.0) {
					vec2 centered = in_uv - 0.5;
					fade = clamp(dot(centered, centered) * 4.0, 0.0, 1.0);
				}

				alpha *= 1.0 - fade;
			}

			compute_translucency_and_discard(alpha);

			Surface surface;
			surface.world_pos = displacement.world_pos;
			surface.geometric_N = tbn[2];
			prepare_terrain_layers(displacement.uv, displacement.world_pos);
			init_surface_features(surface, displacement.uv);
			surface.alpha = alpha;
			surface.albedo = get_albedo_world(displacement.uv, displacement.world_pos);
			surface.N = get_normal(displacement.uv, tbn);
			SurfaceWeather weather;
			prepare_surface_weather(surface, weather);
			SurfaceConditions conditions;
			bool has_conditions = sample_surface_conditions(surface.world_pos, surface.geometric_N, in_instance_dynamic, in_effect_position, in_effect_normal, conditions);

			if (has_conditions) weather_surface_conditions(conditions, weather);

			apply_surface_weather(surface, weather);

			if (has_conditions) {
				float consumed = apply_surface_conditions(surface, weather, conditions);

				if (AlphaTest && consumed > fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))))) discard;
			}

			apply_surface_overlays(surface, weather, in_instance_overlay, in_effect_position, in_effect_normal, in_uv);
			weather_surface_features(surface, weather);
			surface.roughness_alpha = get_antialiased_roughness(surface.N, surface.roughness_alpha);

			if (gbuffer_data.normal_source == 1) {
				surface.N = tbn[2];
			} else if (gbuffer_data.normal_source == 2) {
				surface.N = get_normal_map(displacement.uv);
			}

			write_surface_features(surface);
			write_velocity(displacement.world_pos, in_prev_position + (displacement.world_pos - in_position));
			]] .. (
			write_depth and
			[[
			vec3 depth_position = displacement.world_pos;

			if (Decal) {
				vec3 to_camera = gbuffer_data.camera_position.xyz - depth_position;
				float camera_distance = max(length(to_camera), 0.0001);
				depth_position += to_camera / camera_distance * (camera_distance * DECAL_DEPTH_BIAS_RELATIVE + DECAL_DEPTH_BIAS_ABSOLUTE);
			}

			gl_FragDepth = get_projected_depth(depth_position);]] or
			""
		) .. [[
		}
	]]
end

local passes = {}

for _, write_depth in ipairs({false, true}) do
	local suffix = write_depth and "_height_map" or ""
	local fragment_shader = build_ssdm_fragment_shader(write_depth)
	local fallback = build_base_pass(fragment_shader, false)
	fallback.name = "gbuffer" .. suffix

	if write_depth then
		fallback.draw_in_prerender = false
		fallback.dont_create_framebuffers = true
	end

	local fallback_anim = build_base_pass(fragment_shader, true)
	fallback_anim.name = "gbuffer_anim" .. suffix
	fallback_anim.draw_in_prerender = false
	fallback_anim.dont_create_framebuffers = true
	local instanced = build_instanced_pass(fragment_shader)
	instanced.name = "gbuffer_instanced" .. suffix
	local multi_draw = build_multi_draw_pass(build_ssdm_fragment_shader(write_depth, true))
	multi_draw.name = "gbuffer_multi_draw" .. suffix
	list.insert(passes, fallback)
	list.insert(passes, fallback_anim)
	list.insert(passes, instanced)
	list.insert(passes, multi_draw)
end

for _, extra in ipairs(gbuffer_extras) do
	if extra.BuildPass then list.insert(passes, extra.BuildPass(passes[1])) end
end

return passes
