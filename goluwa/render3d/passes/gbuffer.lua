local event = import("goluwa/event.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local grass = import("goluwa/render3d/grass.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local system = import("goluwa/system.lua")
local normal_debug = import("goluwa/render3d/normal_debug.lua")
local camera_block = {
	name = "gbuffer_data",
	binding_index = 3,
	block = {
		render3d.camera_block,
		render3d.prev_camera_block,
		surface_weather.block,
		{"normal_debug", "int"},
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		surface_weather.WriteBlock(self, block)
		block.normal_debug = normal_debug.GetView()
		return block
	end,
	upload_scope = "frame",
}

local function build_base_pass(fragment_shader, enable_vertex_animation)
	local uniform_buffers = model_pipeline.GetPBRUniformBuffers()
	table.insert(uniform_buffers, 1, camera_block)
	return {
		name = "gbuffer",
		on_pre_draw = function(self, cmd)
			if render3d.pipelines.grass then grass.Scatter(cmd) end
		end,
		on_draw = function(self, cmd)
			gbuffer_instancing.Reset()
			event.Call("PreDraw3D", dt)
			event.Call("Draw3DGeometry", dt)
			gbuffer_instancing.Flush()

			if render3d.pipelines.grass then grass.Draw(render3d.pipelines.grass, cmd) end
		end,
		ColorFormat = gbuffer_layout.color_format,
		DepthFormat = gbuffer_layout.DEPTH_FORMAT,
		fragment = {
			uniform_buffers = uniform_buffers,
			shader = model_pipeline.BuildPBRSurfaceGlsl("gbuffer_data") .. surface_weather.GetGLSL("gbuffer_data") .. gbuffer_layout.GetEncodeGLSL() .. [[
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
		{"time", "float"},
		{"prev_time", "float"},
	},
	write = function(self, block)
		block.batches = self.draw_batches_address
		block.instances = self.draw_instances_address
		block.time = system.GetElapsedTime()
		block.prev_time = render3d.GetPreviousElapsedTime()
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
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		velocity = true,
		camera_block_name = "gbuffer_data",
		uniform_buffers = {camera_block, multi_draw_block},
		batches_expr = "gbuffer_draw.batches",
		instances_expr = "gbuffer_draw.instances",
		time_expr = "gbuffer_draw.time",
		prev_time_expr = "gbuffer_draw.prev_time",
	}
	pass.fragment.uniform_buffers = {camera_block, multi_draw_block}
	pass.fragment.custom_declarations = string.format("layout(location = %d) flat in uint in_batch;\n", pass.vertex.batch_location) .. model_pipeline.BuildPBRBatchRecordGlsl("PBRBatchData(gbuffer_draw.batches).b[in_batch]")
	return pass
end

local function build_ssdm_fragment_shader(write_depth)
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

		// parallax occlusion mapping (Tatarchuk 2006). the height field is a slab around the polygon, from
		// (1 - HeightMidlevel) above it to HeightMidlevel below it, HeightScale texture units thick. the view
		// ray is marched from where it enters the slab's top down to its bottom in layers, and the uv, height
		// and world position are where it first goes below the height field
		SSDMData get_ssdm_data(mat3 tbn) {
			SSDMData data;
			data.uv = in_uv;
			data.height = 0.0;
			data.world_pos = in_position;
			// the derivatives before any branch, they need the whole quad
			vec3 dp1 = dFdx(in_position);
			vec3 dp2 = dFdy(in_position);
			vec2 duv1 = dFdx(in_uv);
			vec2 duv2 = dFdy(in_uv);

			if (!has_heightmap()) {
				return data;
			}

			// how u and v change per meter across the surface, from the screen derivatives (Schüler 2013),
			// so the march doesn't depend on how the uv or the tangents were made
			vec3 N = tbn[2];
			vec3 dp2perp = cross(dp2, N);
			vec3 dp1perp = cross(N, dp1);
			float det = dot(dp1, dp2perp);

			if (abs(det) < 1e-12) {
				return data;
			}

			vec3 grad_u = (dp2perp * duv1.x + dp1perp * duv2.x) / det;
			vec3 grad_v = (dp2perp * duv1.y + dp1perp * duv2.y) / det;
			// the slab's thickness in meters, one texture unit being this many meters across
			float thickness = displacement_model.HeightScale / sqrt(max(length(grad_u) * length(grad_v), 1e-12));
			vec3 V = get_view_dir_world(in_position);
			float view_n = max(dot(V, N), 0.05);
			// the uv the ray moves per meter it goes down
			vec2 uv_per_depth = -vec2(dot(grad_u, V), dot(grad_v, V)) / view_n;
			float midlevel = displacement_model.HeightMidlevel;
			int layer_count = get_height_layers();
			float layer_height = 1.0 / float(layer_count);
			// the ray starts at the slab's top, above the polygon by the part of the heights above the midlevel
			vec2 top_uv = in_uv - uv_per_depth * (1.0 - midlevel) * thickness;
			vec2 uv_step = uv_per_depth * thickness * layer_height;
			float level = 1.0;
			vec2 current_uv = top_uv;
			// with the pixel's own gradients, a march that stops early in some pixels of a quad would
			// otherwise pick the wrong mip
			float current_height = textureGrad(TEXTURE(displacement_model.HeightTexture), current_uv, duv1, duv2).r;
			float previous_level = level;
			float previous_height = current_height;

			for (int i = 0; i < 64; i++) {
				if (i >= layer_count || level <= current_height) {
					break;
				}

				previous_level = level;
				previous_height = current_height;
				level -= layer_height;
				current_uv += uv_step;
				current_height = textureGrad(TEXTURE(displacement_model.HeightTexture), current_uv, duv1, duv2).r;
			}

			// between the last layer above the height field and the first below it, where the ray crosses it
			float after = current_height - level;
			float before = previous_height - previous_level;
			float weight = abs(after - before) > 0.0001 ? clamp(after / (after - before), 0.0, 1.0) : 0.0;
			float hit_level = mix(level, previous_level, weight);
			data.uv = top_uv + uv_per_depth * (1.0 - hit_level) * thickness;
			// meters above the polygon
			data.height = (hit_level - midlevel) * thickness;
			// what is below the polygon stays on it: the shadow maps only see the polygon, and would shadow
			// everything under it
			data.world_pos = in_position + V * (max(data.height, 0.0) / view_n);
			return data;
		}

		void main() {
			mat3 tbn = get_tbn();
			SSDMData displacement = get_ssdm_data(tbn);
			float alpha = get_alpha_uv(displacement.uv);
			compute_translucency_and_discard(alpha);

			vec3 albedo = get_albedo_world(displacement.uv, displacement.world_pos);
			vec3 normal = get_normal(displacement.uv, tbn);
			float metallic = get_metallic(displacement.uv);
			apply_gloss_metallic(displacement.uv, albedo, metallic);
			float roughness = get_roughness(displacement.uv);
			float transmission = get_transmission(displacement.uv);
			// thin translucent leaves are waxy rather than porous
			float clearcoat = get_clearcoat();
			float clearcoat_roughness = get_clearcoat_roughness();
			float rain;
			float snow = apply_surface_weather(albedo, roughness, metallic, normal, get_porosity(roughness, metallic) * (1.0 - transmission), displacement.world_pos, tbn[2], clearcoat, clearcoat_roughness, rain);
			transmission *= 1.0 - snow;
			roughness = get_antialiased_roughness(normal, roughness);
			set_alpha(alpha);
			set_albedo(albedo);
			if (gbuffer_data.normal_debug == 1) {
				normal = tbn[2];
			} else if (gbuffer_data.normal_debug == 2) {
				normal = get_normal_map(displacement.uv);
			}

			set_normal(gbuffer_encode_normal(normal));
			set_transmission_scattering(get_transmission_scattering());
			vec2 transmission_tint = gbuffer_encode_transmission_tint(get_transmission_color());
			set_transmission_tint_r(transmission_tint.x);
			set_transmission_tint_b(transmission_tint.y);
			set_metallic(metallic);
			set_roughness(gbuffer_encode_roughness(roughness));
			set_ao(mix(get_ao(displacement.uv), 1.0, snow));
			// ice has an F0 of 0.018
			set_specular(gbuffer_encode_specular(mix(get_specular(displacement.uv), 0.45, snow)));
			set_transmission(transmission);
			set_clearcoat(clearcoat);
			set_clearcoat_roughness(gbuffer_encode_roughness(clearcoat_roughness));
			set_clearcoat_rain(rain);
			set_clearcoat_normal(gbuffer_encode_normal(tbn[2]));
			set_emissive(gbuffer_encode_emissive(get_emissive(displacement.uv) * (1.0 - snow)));
			// the undisplaced position on both sides. parallax shifts the surface
			// by the same amount in both frames when the view barely changed, so
			// including it would mostly add noise to the offset
			write_velocity(in_position, in_prev_position);
			]] .. (
			write_depth and
			"gl_FragDepth = get_projected_depth(displacement.world_pos);" or
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
	local multi_draw = build_multi_draw_pass(fragment_shader)
	multi_draw.name = "gbuffer_multi_draw" .. suffix
	list.insert(passes, fallback)
	list.insert(passes, fallback_anim)
	list.insert(passes, instanced)
	list.insert(passes, multi_draw)
end

list.insert(passes, grass.BuildDrawPass(passes[1]))
return passes
