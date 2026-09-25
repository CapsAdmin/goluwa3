local event = import("goluwa/event.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local commands = import("goluwa/cli/commands.lua")
local grass = import("goluwa/render3d/grass.lua")
local camera_block = {
	name = "gbuffer_data",
	binding_index = 3,
	block = {
		render3d.camera_block,
		render3d.prev_camera_block,
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		return block
	end,
	upload_scope = "frame",
}

commands.Add("velocity_buffer=boolean[true]", function(enabled)
	render3d.SetVelocityEnabled(enabled)
	logf(
		"[gbuffer] velocity buffer %s, consumers %s\n",
		enabled ~= false and "enabled" or "disabled",
		enabled ~= false and
			"follow moving surfaces" or
			"reproject through the previous camera only"
	)
end)

local function build_base_pass(fragment_shader, enable_vertex_animation)
	local uniform_buffers = model_pipeline.GetPBRUniformBuffers()
	table.insert(uniform_buffers, 1, camera_block)
	return {
		name = "gbuffer",
		-- compute has to run before the gbuffer begins rendering. a bundle
		-- without the grass pass (env probes) draws no grass
		on_pre_draw = function(self, cmd)
			if render3d.pipelines.grass then grass.Scatter(cmd) end
		end,
		on_draw = function(self, cmd)
			render3d.ResetQueuedGBufferInstances()
			event.Call("PreDraw3D", dt)
			event.Call("Draw3DGeometry", dt)
			render3d.FlushQueuedGBufferInstances()

			if render3d.pipelines.grass then grass.Draw(render3d.pipelines.grass, cmd) end
		end,
		ColorFormat = {
			{"r8g8b8a8_srgb", {"albedo", "rgb"}, {"alpha", "a"}},
			{"b10g11r11_ufloat_pack32", {"normal", "rgb"}},
			{
				"r8g8b8a8_unorm",
				{"metallic", "r"},
				{"roughness", "g"},
				{"ao", "b"},
				{"subsurface", "a"},
			},
			{"b10g11r11_ufloat_pack32", {"emissive", "rgb"}},
			{
				"r8g8b8a8_unorm",
				{"transmission_blocking", "r"},
				{"transmission_view_dep", "g"},
				{"specular", "b"},
			},
			{"r16g16b16a16_sfloat", {"velocity", "rg"}, {"prev_view_depth", "b"}},
		},
		DepthFormat = "d32_sfloat",
		fragment = {
			uniform_buffers = uniform_buffers,
			shader = model_pipeline.BuildPBRSurfaceGlsl() .. [[
					// both endpoints go through their own frame's camera, so a still
					// object under a moving camera and a moving object under a still
					// camera come out of the same subtraction. the divide by w is
					// what makes it a screen offset rather than a world one
					vec3 get_screen_velocity(vec3 world_pos, vec3 prev_world_pos) {
						vec4 clip = gbuffer_data.projection * gbuffer_data.view * vec4(world_pos, 1.0);
						vec4 prev_view_pos = gbuffer_data.prev_view * vec4(prev_world_pos, 1.0);
						vec4 prev_clip = gbuffer_data.prev_projection * prev_view_pos;

						// behind the eye either frame there is no honest offset to
						// give, and a reprojection is better off treating the pixel
						// as new than following a mirrored one
						if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) {
							return vec3(0.0, 0.0, -prev_view_pos.z);
						}

						vec2 uv = (clip.xy / clip.w) * 0.5;
						vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5;
						return vec3(uv - prev_uv, -prev_view_pos.z);
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
		DepthCompareOp = "less_or_equal",
		DepthBoundsTest = false,
		StencilTest = false,
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			velocity = true,
			include_projection_view_world = false,
			camera_uniform_block_name = "gbuffer_data",
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
		include_projection_view = false,
		camera_uniform_block_name = "gbuffer_data",
		uniform_buffers = {
			camera_block,
		},
		enable_vertex_animation = true,
	}
	return pass
end

local function build_ssdm_fragment_shader(displacement_var)
	displacement_var = displacement_var or "model"
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

		SSDMData get_ssdm_data(mat3 tbn) {
			SSDMData data;
			data.uv = in_uv;
			data.height = 0.0;
			data.world_pos = in_position;

			if (!has_heightmap()) {
				return data;
			}

			vec3 view_dir_world = get_view_dir_world(in_position);
			vec3 view_dir_tangent = normalize(transpose(tbn) * view_dir_world);
			float view_z = max(view_dir_tangent.z, 0.05);
			int layer_count = get_height_layers();
			float layer_depth = 1.0 / float(layer_count);
			float current_layer_depth = 0.0;
			vec2 current_uv = in_uv;
			vec2 delta_uv = -(view_dir_tangent.xy / view_z) * displacement_model.HeightScale / float(layer_count);
			float current_map_depth = 1.0 - (get_height_centered_sample(current_uv) + displacement_model.HeightCenter);
			vec2 previous_uv = current_uv;
			float previous_layer_depth = current_layer_depth;
			float previous_map_depth = current_map_depth;

			for (int i = 0; i < 64; i++) {
				if (i >= layer_count || current_layer_depth >= current_map_depth) {
					break;
				}

				previous_uv = current_uv;
				previous_layer_depth = current_layer_depth;
				previous_map_depth = current_map_depth;
				current_uv = current_uv + delta_uv;
				current_layer_depth += layer_depth;
				current_map_depth = 1.0 - (get_height_centered_sample(current_uv) + displacement_model.HeightCenter);
			}

			float after_depth = current_map_depth - current_layer_depth;
			float before_depth = previous_map_depth - previous_layer_depth;
			float weight = 0.0;
			float denominator = after_depth - before_depth;

			if (abs(denominator) > 0.0001) {
				weight = clamp(after_depth / denominator, 0.0, 1.0);
			}

			float parallax_depth = mix(current_layer_depth, previous_layer_depth, weight);
			float centered_height = parallax_depth - displacement_model.HeightCenter;
			data.uv = mix(current_uv, previous_uv, weight);
			data.height = centered_height * displacement_model.HeightScale;
			data.world_pos = in_position - view_dir_world * (data.height / view_z);
			return data;
		}

		void main() {
			mat3 tbn = get_tbn();
			SSDMData displacement = get_ssdm_data(tbn);
			float alpha = get_alpha_uv(displacement.uv);
			compute_translucency_and_discard(alpha);

			set_alpha(alpha);
			set_albedo(get_albedo_world(displacement.uv, displacement.world_pos));
			set_normal(get_normal(displacement.uv, tbn) * 0.5 + 0.5);
			set_transmission_view_dep(get_transmission_view_dependency());
			set_metallic(get_metallic(displacement.uv));
			set_roughness(get_roughness(displacement.uv));
			set_ao(get_ao(displacement.uv));
			set_specular(get_specular());
			set_subsurface(get_subsurface(displacement.uv));
			set_transmission_blocking(get_transmission_blocking(displacement.uv));
			set_emissive(get_emissive(displacement.uv));
			// the undisplaced position on both sides. parallax shifts the surface
			// by the same amount in both frames when the view barely changed, so
			// including it would mostly add noise to the offset
			write_velocity(in_position, in_prev_position);
			gl_FragDepth = has_heightmap() ? get_projected_depth(displacement.world_pos) : gl_FragCoord.z;
		}
	]]
end

local fallback = build_base_pass(build_ssdm_fragment_shader("displacement_model"), false)
local fallback_anim = build_base_pass(build_ssdm_fragment_shader("displacement_model"), true)
fallback_anim.name = "gbuffer_anim"
fallback_anim.draw_in_prerender = false
fallback_anim.dont_create_framebuffers = true
local instanced = build_instanced_pass(build_ssdm_fragment_shader("displacement_model"))
return {fallback, fallback_anim, instanced, grass.BuildDrawPass(fallback)}
