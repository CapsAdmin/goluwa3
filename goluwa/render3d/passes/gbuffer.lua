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
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local shader_features = import("goluwa/render3d/shader_features.lua")
local camera_block = geometry_block.New("gbuffer_data", {
	{"normal_source", "int"},
	{"eye_near_height_shell", "int"},
}, function(self, block)
	block.normal_source = gbuffer_inspect.GetNormalSourceIndex()
	block.eye_near_height_shell = scene_draw.IsEyeNearHeightShell(render3d.GetCamera():GetPosition()) and 1 or 0
end)

local function get_extra_pipeline(extra)
	local pipeline = render3d.GetPipelineVariant(extra.name, scene_draw.GetVariant(scene_draw.SHAPE_PLAIN, scene_draw.GetGlobalBits(0)))

	if render3d.IsPipelineReady(pipeline) then return pipeline end

	return render3d.GetPipelineVariant(extra.name, scene_draw.GetVariant(scene_draw.SHAPE_PLAIN, 0))
end

local function build_base_pass(fragment_shader, enable_vertex_animation)
	local uniform_buffers = model_pipeline.GetPBRUniformBuffers()
	table.insert(uniform_buffers, 1, camera_block)
	return {
		name = "gbuffer",
		on_pre_draw = function(self, cmd)
			for _, extra in ipairs(gbuffer_extras) do
				if render3d.HasPipelineVariants(extra.name) then extra.PreDraw(cmd) end
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

			for _, extra in ipairs(gbuffer_extras) do
				if render3d.HasPipelineVariants(extra.name) then
					extra.Draw(get_extra_pipeline(extra), cmd)
				end
			end

			-- displaced surfaces (terrain) are the most expensive per pixel and write their own depth, so they go last, where meshes and scatter drawn before them reject most of their fragments early
			event.Call("Draw3DDisplacedGeometry", dt)
			gbuffer_instancing.Flush()
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

local function build_multi_draw_pass(fragment_shader, bits)
	local pass = build_base_pass(fragment_shader, true)
	pass.name = "gbuffer_multi_draw"
	pass.draw_in_prerender = false
	pass.dont_create_framebuffers = true
	pass.on_draw = nil
	pass.on_pre_draw = nil
	pass.vertex = model_pipeline.CreateMultiDrawVertexStage{
		shell_offset_expr = "world_normal * batch_data.b[batch_index].m_displacement_model.HeightShell * (((abs(in_tangent.w) > 1.5 && abs(in_tangent.w) < 2.5) || abs(in_tangent.w) > 3.5 ? 0.0 : 1.0) - batch_data.b[batch_index].m_displacement_model.HeightMidlevel) + world_normal * (abs(in_tangent.w) > 1.5 ? 0.0 : batch_data.b[batch_index].m_terrain_model.TerrainShell * 1.1)",
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
	pass.fragment.custom_declarations = shader_features.GetDefines(bits) .. string.format(
			"layout(location = %d) flat in uint in_batch;\nlayout(location = %d) flat in uint in_instance;\nlayout(location = %d) flat in uint in_triangle;\n",
			pass.vertex.batch_location,
			pass.vertex.batch_location + 1,
			pass.vertex.batch_location + 2
		) .. model_pipeline.BuildPBRBatchRecordGlsl("PBRBatchData(gbuffer_draw.batches).b[in_batch]") .. [[
layout(buffer_reference, scalar) readonly buffer PrismVertexData { float v[]; };
layout(buffer_reference, scalar) readonly buffer PrismIndexData { uint i[]; };
layout(buffer_reference, scalar) readonly buffer PrismInstanceData { mat4 worlds[]; };
]] .. string.format(
			"const uint PRISM_VERTEX_STRIDE = %du;\nconst uint PRISM_VERTEX_POSITION = %du;\nconst uint PRISM_VERTEX_NORMAL = %du;\nconst uint PRISM_VERTEX_UV = %du;\nconst uint PRISM_VERTEX_PIVOT = %du;\nconst uint PRISM_VERTEX_TANGENT = %du;\n",
			vertex_layout.FloatStride,
			vertex_layout.GetFloatOffset("position"),
			vertex_layout.GetFloatOffset("normal"),
			vertex_layout.GetFloatOffset("uv"),
			vertex_layout.GetFloatOffset("pivot"),
			vertex_layout.GetFloatOffset("tangent")
		)
	return pass
end

local function build_ssdm_fragment_shader(write_depth, prism, nearer)
	-- shell hits of entry fragments lie behind them, so the rasterized depth is a bound that keeps early depth rejection; hits marched from an eye inside the relief lie in front and only matter when something else sits between them and their exit surface
	return (
			write_depth and
			prism and
			not nearer and
			"layout(depth_less) out float gl_FragDepth;\n" or
			""
		) .. [[
		struct SSDMData {
			vec2 uv;
			float height;
			vec3 world_pos;
			vec3 texture_pos;
			vec3 normal;
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
			float sink;
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

		bool prism_locate(PrismMesh mesh, inout uint tri, vec3 p, int max_hops, out float lambda, out vec2 uv, out uvec3 corners, out vec3 weights) {
			uint i0 = 0u;
			uint i1 = 0u;
			uint i2 = 0u;
			vec3 b = vec3(1.0, 0.0, 0.0);
			bool inside = false;
			lambda = 0.0;

			for (int hop = 0; hop < max_hops; hop++) {
				i0 = prism_index(mesh, tri, 0u);
				i1 = prism_index(mesh, tri, 1u);
				i2 = prism_index(mesh, tri, 2u);
				vec3 n0 = prism_normal(mesh, i0);
				vec3 n1 = prism_normal(mesh, i1);
				vec3 n2 = prism_normal(mesh, i2);
				vec3 b0 = prism_position(mesh, i0) - n0 * mesh.sink;
				vec3 b1 = prism_position(mesh, i1) - n1 * mesh.sink;
				vec3 b2 = prism_position(mesh, i2) - n2 * mesh.sink;
				vec3 d0 = n0 * mesh.lift;
				vec3 d1 = n1 * mesh.lift;
				vec3 d2 = n2 * mesh.lift;
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
			corners = uvec3(i0, i1, i2);
			weights = b;
			return inside;
		}

		float terrain_shell_ground(vec2 uv) {
			vec2 size = vec2(textureSize(TEXTURE(terrain_model.TerrainHeightTexture), 0));
			return textureLod(TEXTURE(terrain_model.TerrainHeightTexture), (clamp(uv, 0.0, 1.0) * (size - 1.0) + 0.5) / size, 0.0).r;
		}

		// steepest side the layer relief is assumed to have; lower values step over the flanks of boulders
		const float TERRAIN_SHELL_RELIEF_SLOPE = 0.9;

		struct TerrainShellWeights {
			vec4 weights;
			vec4 weights2;
			vec3 blend;
			vec2 uv;
		};

		struct TerrainShellCoarse {
			vec3 normal;
			float max_relief;
		};

		TerrainShellCoarse terrain_shell_coarse(vec2 uv) {
			TerrainShellCoarse c;
			c.normal = get_terrain_world_normal(uv);
			vec4 present = step(vec4(0.001), texture(TEXTURE(terrain_model.TerrainMaterialTexture), uv)) + step(vec4(0.001), terrain_model.TerrainLayerCoverSlope);
			vec4 relief = (terrain_model.TerrainLayerHeightScales * terrain_model.TerrainLayerScales + terrain_model.TerrainLayerCoverDepth) * min(present, vec4(1.0));
			c.max_relief = max(max(relief.x, relief.y), max(relief.z, relief.w));

			if (terrain_model.TerrainMaterial2Texture != -1) {
				vec4 present2 = step(vec4(0.001), texture(TEXTURE(terrain_model.TerrainMaterial2Texture), uv)) + step(vec4(0.001), terrain_model.TerrainLayerCoverSlope2);
				vec4 relief2 = (terrain_model.TerrainLayerHeightScales2 * terrain_model.TerrainLayerScales2 + terrain_model.TerrainLayerCoverDepth2) * min(present2, vec4(1.0));
				c.max_relief = max(c.max_relief, max(max(relief2.x, relief2.y), max(relief2.z, relief2.w)));
			}

			return c;
		}

		TerrainShellWeights terrain_shell_weights(vec2 uv, vec3 normal) {
			TerrainShellWeights w;
			w.uv = clamp(uv, 0.0, 1.0);
			get_terrain_material_weights_both_uv(w.uv, normal, w.weights, w.weights2);
			vec3 blend = get_terrain_triplanar_weights(normal);
			blend = max(blend - 0.2, vec3(0.0));
			w.blend = blend / max(blend.x + blend.y + blend.z, 0.0001);
			return w;
		}

		float terrain_shell_relief_set(vec4 weights, ivec4 height_textures, vec4 height_scales, vec4 scales, vec4 height_blend, vec4 cover_slope, vec4 cover_depth, vec3 q, vec3 blend, vec2 gx[3], vec2 gy[3], inout float weight_sum, inout float cover_amount, inout float cover_level) {
			float relief = 0.0;

			for (int i = 0; i < 4; i++) {
				if (weights[i] <= 0.001) {
					continue;
				}

				float h = height_textures[i] != -1 ? sample_terrain_layer_height(height_textures[i], q, max(scales[i], 0.0001), blend, gx, gy) : 0.5;

				if (cover_slope[i] > 0.0) {
					cover_amount += weights[i];
					cover_level += weights[i] * (cover_depth[i] + (height_textures[i] != -1 ? h * height_scales[i] * scales[i] : 0.0));
					continue;
				}

				float w = weights[i] * mix(1.0, h * 2.0, height_blend[i]);
				weight_sum += w;

				if (height_textures[i] != -1) {
					relief += w * h * height_scales[i] * scales[i];
				}
			}

			return relief;
		}

		float terrain_shell_relief(vec3 q, TerrainShellWeights w, vec2 gx[3], vec2 gy[3]) {
			float weight_sum = 0.0;
			float cover_amount = 0.0;
			float cover_level = 0.0;
			float relief = terrain_shell_relief_set(w.weights, ivec4(terrain_model.TerrainLayer1HeightTexture, terrain_model.TerrainLayer2HeightTexture, terrain_model.TerrainLayer3HeightTexture, terrain_model.TerrainLayer4HeightTexture), terrain_model.TerrainLayerHeightScales, terrain_model.TerrainLayerScales, terrain_model.TerrainLayerHeightBlend, terrain_model.TerrainLayerCoverSlope, terrain_model.TerrainLayerCoverDepth, q, w.blend, gx, gy, weight_sum, cover_amount, cover_level);

			if (terrain_model.TerrainMaterial2Texture != -1) {
				relief += terrain_shell_relief_set(w.weights2, ivec4(terrain_model.TerrainLayer5HeightTexture, terrain_model.TerrainLayer6HeightTexture, terrain_model.TerrainLayer7HeightTexture, terrain_model.TerrainLayer8HeightTexture), terrain_model.TerrainLayerHeightScales2, terrain_model.TerrainLayerScales2, terrain_model.TerrainLayerHeightBlend2, terrain_model.TerrainLayerCoverSlope2, terrain_model.TerrainLayerCoverDepth2, q, w.blend, gx, gy, weight_sum, cover_amount, cover_level);
			}

			float base = weight_sum > 0.0001 ? relief / weight_sum : 0.0;

			if (cover_amount <= 0.0) {
				return base;
			}

			return mix(base, max(base, cover_level / cover_amount), min(cover_amount, 1.0));
		}

		struct ShellState {
			bool terrain;
			PrismMesh mesh;
			uint tri;
			float midlevel;
			vec2 duv1;
			vec2 duv2;
			vec3 bounds;
			TerrainShellWeights weights;
			TerrainShellCoarse coarse;
			vec2 gx[3];
			vec2 gy[3];
			float shell;
			float lift;
			float max_step;
			float escape;
			int hops;
			int eye_hops;
		};

		mat3 prism_frame(PrismMesh mesh, uvec3 corners, vec3 weights) {
			vec3 n = vec3(0.0);
			vec4 t = vec4(0.0);

			for (int k = 0; k < 3; k++) {
				uint at = corners[k] * PRISM_VERTEX_STRIDE;
				n += vec3(mesh.vertices.v[at + PRISM_VERTEX_NORMAL], mesh.vertices.v[at + PRISM_VERTEX_NORMAL + 1u], mesh.vertices.v[at + PRISM_VERTEX_NORMAL + 2u]) * weights[k];
				t += vec4(mesh.vertices.v[at + PRISM_VERTEX_TANGENT], mesh.vertices.v[at + PRISM_VERTEX_TANGENT + 1u], mesh.vertices.v[at + PRISM_VERTEX_TANGENT + 2u], mesh.vertices.v[at + PRISM_VERTEX_TANGENT + 3u]) * weights[k];
			}

			vec3 normal = normalize(mesh.normal_matrix * n);
			vec3 tangent = normalize(mat3(mesh.world) * t.xyz);
			tangent = normalize(tangent - normal * dot(normal, tangent));
			return mat3(tangent, cross(normal, tangent) * sign(t.w), normal);
		}

		struct ShellSample {
			bool valid;
			float level;
			float clearance;
			vec2 uv;
			uvec3 corners;
			vec3 weights;
			vec3 foot;
		};

		ShellSample shell_sample(inout ShellState s, vec3 p) {
			ShellSample r;

			if (s.terrain) {
				vec2 uv = (p.xz - s.bounds.xy) / s.bounds.z;
				s.coarse = terrain_shell_coarse(clamp(uv, 0.0, 1.0));
				vec3 normal = s.coarse.normal;
				float height = (p.y - terrain_shell_ground(uv)) * normal.y;
				vec3 foot = p - normal * height;
				r.foot = foot;
				r.uv = (foot.xz - s.bounds.xy) / s.bounds.z;
				float margin = s.lift / s.bounds.z + 1e-3;
				r.valid = all(greaterThanEqual(r.uv, vec2(-margin))) && all(lessThanEqual(r.uv, vec2(1.0 + margin)));
				r.level = height / s.lift;
				float headroom = height - s.coarse.max_relief;

				if (headroom > 0.0) {
					r.clearance = headroom;
					return r;
				}

				s.weights = terrain_shell_weights(r.uv, normal);
				r.clearance = height - terrain_shell_relief(foot, s.weights, s.gx, s.gy);
				return r;
			}

			float lambda;
			r.foot = p;
			r.valid = prism_locate(s.mesh, s.tri, p, s.hops, lambda, r.uv, r.corners, r.weights);
			r.level = lambda;
			float h = textureGrad(TEXTURE(displacement_model.HeightTexture), r.uv, s.duv1, s.duv2).r;
			r.clearance = (lambda - h) * s.shell;
			return r;
		}

		SSDMData shell_trace(inout ShellState s, bool base_copy, bool side, vec3 outward, inout mat3 tbn) {
			vec3 eye = gbuffer_data.camera_position.xyz;
			vec3 to_fragment = in_position - eye;
			float t_fragment = length(to_fragment);
			vec3 dir = to_fragment / t_fragment;
			float facing = dot(dir, normalize(in_normal));
			bool entering = side ? dot(dir, outward) < 0.0 : !base_copy && facing < 0.0;
			float t = t_fragment;
			float pixel_angle = 2.0 / (abs(gbuffer_data.projection[1][1]) * gbuffer_data.render_size.y);

			if (!s.terrain && entering && !side && s.lift < t_fragment * pixel_angle * 0.5) {
				float h = textureGrad(TEXTURE(displacement_model.HeightTexture), in_uv, s.duv1, s.duv2).r;
				SSDMData flat_data;
				flat_data.uv = in_uv;
				flat_data.height = (h - s.midlevel) * s.lift;
				flat_data.world_pos = in_position + dir * ((1.0 - h) * s.lift / max(-facing, 0.25));
				flat_data.texture_pos = flat_data.world_pos;
				flat_data.normal = vec3(0.0);
				return flat_data;
			}

			if (!entering) {
				int hops = s.hops;
				s.hops = s.eye_hops;
				ShellSample at_eye = shell_sample(s, eye);
				s.hops = hops;

				if (!at_eye.valid || at_eye.level < 0.0 || at_eye.level > 1.5) {
					discard;
				}

				t = 0.0;
			}

			float min_dt = s.shell / 16.0;
			float descent = max(-facing, 0.0) + 0.25;
			float lo = -1.0;
			float hi = -1.0;
			float air_t = -1.0;

			for (int i = 0; i < 128; i++) {
				ShellSample r = shell_sample(s, eye + dir * t);

				if (!r.valid && side && entering && t < t_fragment + s.shell * 0.1) {
					t += s.shell * 0.01;
					continue;
				}

				if (!r.valid || (i > 0 && r.level > s.escape)) {
					break;
				}

				if (r.clearance <= 0.0 || r.level < 0.0) {
					lo = air_t < 0.0 ? t : air_t;
					hi = t;
					break;
				}

				air_t = t;
				float advance = r.clearance / descent;

				if (s.terrain) {
					float along = dot(dir, s.coarse.normal);
					float ground_approach = max(-along, 0.0) + 0.05;
					float headroom = r.level * s.lift - s.coarse.max_relief;
					advance = max(headroom / ground_approach, r.clearance / (ground_approach + TERRAIN_SHELL_RELIEF_SLOPE * sqrt(max(1.0 - along * along, 0.0))));
				}

				t += clamp(advance * 0.8, max(min_dt, t * pixel_angle * 3.0), max(s.max_step, t * pixel_angle * 6.0));
			}

			if (hi < 0.0) {
				discard;
			}

			for (int i = 0; i < 4 && lo < hi; i++) {
				float mid = 0.5 * (lo + hi);
				ShellSample r = shell_sample(s, eye + dir * mid);

				if (r.valid && (r.clearance <= 0.0 || r.level < 0.0)) {
					hi = mid;
				} else {
					lo = mid;
				}
			}

			ShellSample hit = shell_sample(s, eye + dir * hi);

			if (!hit.valid || (!s.terrain && displacement_model.HeightShellClip > 0.5 && (hit.uv.x < -0.001 || hit.uv.y < -0.001 || hit.uv.x > 1.001 || hit.uv.y > 1.001))) {
				discard;
			}

			if (!s.terrain) {
				tbn = prism_frame(s.mesh, hit.corners, hit.weights);
			}

			SSDMData data;
			data.uv = hit.uv;
			data.height = (clamp(hit.level, 0.0, 1.0) - s.midlevel) * s.lift;
			data.world_pos = eye + dir * hi;
			data.texture_pos = hit.foot;
			data.normal = vec3(0.0);

			if (s.terrain) {
				vec3 n = s.coarse.normal;
				vec3 t1 = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
				vec3 t2 = cross(n, t1);
				float e = max(hi * pixel_angle, 0.005);
				float center = hit.level * s.lift - hit.clearance;
				float dx = terrain_shell_relief(hit.foot + t1 * e, s.weights, s.gx, s.gy) - center;
				float dy = terrain_shell_relief(hit.foot + t2 * e, s.weights, s.gx, s.gy) - center;
				data.normal = normalize(n - (t1 * dx + t2 * dy) / e);
			}
			return data;
		}

		SSDMData get_terrain_shell_data(float shell, inout mat3 tbn) {
			ShellState s;
			s.terrain = true;
			s.midlevel = 0.0;
			s.bounds = terrain_model.TerrainBounds;
			s.shell = shell;
			s.lift = shell * 1.1;
			s.max_step = shell * 3.0;
			s.escape = 1.25;
			s.hops = 0;
			s.eye_hops = 0;
			s.weights.uv = vec2(-1.0);
			float scale = max(terrain_model.TerrainLayerScales.y, 0.0001);
			s.gx = vec2[3](dFdx(in_position.zy) / scale, dFdx(in_position.xz) / scale, dFdx(in_position.xy) / scale);
			s.gy = vec2[3](dFdy(in_position.zy) / scale, dFdy(in_position.xz) / scale, dFdy(in_position.xy) / scale);
			vec2 edge = min(in_uv, 1.0 - in_uv);
			bool side = min(edge.x, edge.y) < 1e-4;
			vec2 out_uv = edge.x < edge.y ? vec2(in_uv.x < 0.5 ? -1.0 : 1.0, 0.0) : vec2(0.0, in_uv.y < 0.5 ? -1.0 : 1.0);
			return shell_trace(s, !side && abs(in_tangent.w) > 1.5, side, vec3(out_uv.x, 0.0, out_uv.y), tbn);
		}

		SSDMData get_prism_data(float shell, vec2 duv1, vec2 duv2, inout mat3 tbn) {
			ShellState s;
			s.terrain = false;
			uvec4 addresses = PBRBatchData(gbuffer_draw.batches).b[in_batch].addresses;
			s.mesh.vertices = PrismVertexData(packUint2x32(addresses.xy));
			s.mesh.indexed = (addresses.z | addresses.w) != 0u;
			s.mesh.indices = PrismIndexData(packUint2x32(addresses.zw));
			s.mesh.index_32 = PBRBatchData(gbuffer_draw.batches).b[in_batch].index_is_32 != 0u;
			s.mesh.world = PrismInstanceData(gbuffer_draw.instances).worlds[in_instance];
			s.mesh.normal_matrix = transpose(inverse(mat3(s.mesh.world)));
			s.midlevel = displacement_model.HeightMidlevel;
			s.mesh.lift = shell;
			s.mesh.sink = shell * s.midlevel;
			s.tri = in_triangle;
			s.duv1 = duv1;
			s.duv2 = duv2;
			s.shell = shell;
			s.lift = s.mesh.lift;
			s.max_step = shell * 0.15;
			s.escape = 4.0;
			s.hops = 24;
			s.eye_hops = gbuffer_data.eye_near_height_shell != 0 ? 256 : 0;
			bool side = abs(in_tangent.w) > 2.5;

			vec3 face = normalize(cross(dFdx(in_position), dFdy(in_position)));
			vec3 outward = face;

			if (side) {
				s.tri = uint(s.mesh.vertices.v[prism_index(s.mesh, in_triangle, 0u) * PRISM_VERTEX_STRIDE + PRISM_VERTEX_PIVOT] + 0.5);
				vec3 middle = (prism_position(s.mesh, prism_index(s.mesh, s.tri, 0u)) + prism_position(s.mesh, prism_index(s.mesh, s.tri, 1u)) + prism_position(s.mesh, prism_index(s.mesh, s.tri, 2u))) / 3.0;
				outward = face * sign(dot(face, in_position - middle));
			}

			return shell_trace(s, !side && abs(in_tangent.w) > 1.5, side, outward, tbn);
		}
]=] or
			""
		) .. [[

		SSDMData get_ssdm_data(inout mat3 tbn) {
			SSDMData data;
			data.uv = in_uv;
			data.height = 0.0;
			data.world_pos = in_position;
			data.texture_pos = in_position;
			data.normal = vec3(0.0);
			vec3 dp1 = dFdx(in_position);
			vec3 dp2 = dFdy(in_position);
			vec2 duv1 = dFdx(in_uv);
			vec2 duv2 = dFdy(in_uv);

]] .. (
			prism and
			"\t\t\tif (TERRAIN_LAYERS != 0 && terrain_model.TerrainShell > 0.0) return get_terrain_shell_data(terrain_model.TerrainShell, tbn);\n" or
			""
		) .. [[
			if (!has_heightmap()) {
				return data;
			}

]] .. (
			prism and
			[=[
			if (displacement_model.HeightShell > 0.0) {
				return get_prism_data(displacement_model.HeightShell, duv1, duv2, tbn);
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
			data.texture_pos = data.world_pos;
			return data;
		}

		void main() {
			gbuffer_set_defaults();
			discard_lod_fade();
			mat3 tbn = get_tbn();
			SSDMData displacement = get_ssdm_data(tbn);
			vec3 snow_normal;

			if (march_snow_cover(gbuffer_data.camera_position.xyz, displacement.world_pos, tbn[2], snow_normal)) {
				displacement.normal = snow_normal;
				displacement.texture_pos = displacement.world_pos;
				surface_snow_force = 1.0;
			}
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
			surface.geometric_N = surface_snow_force > 0.0 ? snow_normal : tbn[2];
			prepare_terrain_layers(displacement.uv, displacement.texture_pos);
			init_surface_features(surface, displacement.uv);
			surface.alpha = alpha;
			surface.albedo = get_albedo_world(displacement.uv, displacement.world_pos);
			surface.N = dot(displacement.normal, displacement.normal) > 0.0 ? displacement.normal : get_normal(displacement.uv, tbn);
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

			if (Decal && surface_snow_force <= 0.0) {
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
	list.insert(passes, fallback)
	list.insert(passes, fallback_anim)
	list.insert(passes, instanced)
end

do
	local SHAPE_NAMES = {
		[scene_draw.SHAPE_PLAIN] = "plain",
		[scene_draw.SHAPE_RELIEF] = "relief",
		[scene_draw.SHAPE_NEARER] = "nearer",
	}
	local TERRAIN = shader_features.TERRAIN
	render3d.RegisterPipelineVariants(
		"gbuffer_multi_draw",
		{
			prewarm = {
				scene_draw.GetVariant(scene_draw.SHAPE_PLAIN, 0),
				scene_draw.GetVariant(scene_draw.SHAPE_RELIEF, 0),
				scene_draw.GetVariant(scene_draw.SHAPE_PLAIN, TERRAIN),
				scene_draw.GetVariant(scene_draw.SHAPE_RELIEF, TERRAIN),
				scene_draw.GetVariant(scene_draw.SHAPE_NEARER, shader_features.ALL),
			},
			label = function(variant)
				local features = shader_features.GetName(scene_draw.GetVariantBits(variant))
				return SHAPE_NAMES[scene_draw.GetVariantShape(variant)] .. (
						features ~= "" and
						"," .. features or
						""
					)
			end,
			build = function(variant)
				local shape = scene_draw.GetVariantShape(variant)
				-- snow lying on everything moves hits nearer than the triangle, so the nearer shape cannot promise depth_less
				return build_multi_draw_pass(
					build_ssdm_fragment_shader(shape ~= scene_draw.SHAPE_PLAIN, true, shape == scene_draw.SHAPE_NEARER),
					scene_draw.GetVariantBits(variant)
				)
			end,
		}
	)
	scene_draw.SetVariantKind(0, {"gbuffer_multi_draw"}, shader_features.ALL, true)
end

for _, extra in ipairs(gbuffer_extras) do
	if extra.BuildPass then list.insert(passes, extra.BuildPass(passes[1])) end
end

return passes
