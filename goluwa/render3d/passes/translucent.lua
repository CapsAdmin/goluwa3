local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local exposure_compensation = import("goluwa/render3d/exposure_compensation.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local gi = import("goluwa/render3d/gi.lua")
local glass_light = import("goluwa/render3d/glass_light.lua")
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local froxel_fog = import("goluwa/render3d/froxel_fog.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local translucent_moments = import("goluwa/render3d/translucent_moments.lua")
local translucent_extras = import("goluwa/render3d/translucent_extras.lua")
local Texture = import("goluwa/render/texture.lua")
local BINDING_CAMERA = 3
local BINDING_LIGHT_GRID = 20
local BINDING_OCCLUSION_MAP = 21
local SCENE_BINDINGS = {scene = 22, hit = 30, materials = 24}
local surface_descriptor_sets = {
	{
		type = "storage_buffer",
		binding_index = BINDING_LIGHT_GRID,
		stageFlags = "fragment",
	},
	{
		type = "combined_image_sampler",
		binding_index = BINDING_OCCLUSION_MAP,
		stageFlags = "fragment",
	},
	{
		type = "combined_image_sampler",
		binding_index = 0,
		set_index = 2,
		args = froxel_fog.GetVolumeDescriptor,
	},
}

if scene_reflection.RAY_QUERY then
	table.add(
		surface_descriptor_sets,
		scene_reflection.GetDescriptorSets(SCENE_BINDINGS, "fragment")
	)
end

local refraction_source = nil

local function update_refraction_source(cmd)
	local scene = post_source.GetFoggedOpaqueSceneTexture()
	local width, height = scene:GetWidth(), scene:GetHeight()

	if
		not refraction_source or
		refraction_source:GetWidth() ~= width or
		refraction_source:GetHeight() ~= height
	then
		if refraction_source then refraction_source:Remove() end

		refraction_source = Texture.New{
			width = width,
			height = height,
			format = "r16g16b16a16_sfloat",
			mip_map_levels = "auto",
			image = {usage = {"sampled", "transfer_src", "transfer_dst"}},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	end

	render.TransitionResourceTo(scene, "transfer_src_optimal", {cmd = cmd})
	render.TransitionResourceTo(refraction_source, "transfer_dst_optimal", {cmd = cmd, srcStage = "fragment"})
	cmd:CopyImageToImage(scene:GetImage(), refraction_source:GetImage(), width, height)
	render.TransitionResourceTo(
		scene,
		"shader_read_only_optimal",
		{cmd = cmd, dstStage = {"fragment", "compute"}}
	)
	refraction_source:GenerateMipmaps("transfer_dst_optimal")
	refraction_source:GetImage().layout = "shader_read_only_optimal"
end

local camera_block = {
	name = "translucent_camera",
	binding_index = BINDING_CAMERA,
	block = {
		render3d.camera_block,
		render3d.prev_camera_block,
		surface_overlays.block,
		exposure_compensation.block,
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		surface_overlays.WriteBlock(self, block)
		exposure_compensation.WriteBlock(self, block)
		return render3d.WritePreviousCameraBlock(self, block)
	end,
	upload_scope = "frame",
}
local surface_uniform_buffers = model_pipeline.GetPBRUniformBuffers()
table.insert(surface_uniform_buffers, 1, camera_block)
table.insert(
	surface_uniform_buffers,
	{
		name = "lighting_data",
		block = {
			surface_lighting.block,
			{"reflection_screenspace_roughness", "float"},
			{"reflection_gi_start", "float"},
			{"reflection_gi_end", "float"},
			{"rough_rays", "int"},
			{"reflection_max_distance", "float"},
			{"reflection_fog", "int"},
			{"frame_index", "int"},
			{"depth_tex", "int"},
			{"refraction_tex", "int"},
			{"b0_tex", "int"},
			{"moments_tex", "int"},
			{"depth_warp", "vec2"},
			{"fog", "int"},
		},
		write = function(self, block)
			surface_lighting.WriteBlock(self, block)
			block.reflection_screenspace_roughness = 0
			block.reflection_gi_start, block.reflection_gi_end = ibl.GetReflectionGIRange()
			block.rough_rays = scene_reflection.rough_rays:Get()
			block.reflection_max_distance = scene_reflection.max_distance:Get()
			block.reflection_fog = scene_reflection.fog:Get() and 1 or 0
			block.frame_index = render3d.GetTemporalFrame()
			block.fog = render3d.IsPassEnabled("volumetric_fog") and 1 or 0
			block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
			local b0, moments = translucent_moments.GetTextures()
			block.b0_tex = self:GetTextureIndex(b0)
			block.moments_tex = self:GetTextureIndex(moments)
			translucent_moments.WriteDepthWarp(block.depth_warp)
			block.refraction_tex = render3d.refraction_source_requested and
				self:GetTextureIndex(refraction_source) or
				-1
			return block
		end,
		upload_scope = "frame",
	}
)
table.insert(
	surface_uniform_buffers,
	{
		name = "ddgi_data",
		block = gi.GetProbeBlockLayout(),
		write = scene_reflection.WriteProbeBlock,
		upload_scope = "frame",
	}
)
local moments_uniform_buffers = model_pipeline.GetPBRUniformBuffers()
table.insert(moments_uniform_buffers, 1, camera_block)
table.insert(
	moments_uniform_buffers,
	{
		name = "moments_data",
		block = {
			{"depth_warp", "vec2"},
		},
		write = function(self, block)
			translucent_moments.WriteDepthWarp(block.depth_warp)
			return block
		end,
		upload_scope = "frame",
	}
)

local function bind_surface(surface, cmd)
	if not surface then return end

	local frame = render.GetCurrentFrame()

	if not surface.pipeline.descriptor_sets[frame] then frame = 1 end

	surface.surface_lighting_sets = surface.surface_lighting_sets or {}
	froxel_fog.BindVolume(surface, frame)

	if not surface.surface_lighting_sets[frame] then
		surface.surface_lighting_sets[frame] = true
		local grid = light_grid.GetBuffer(cmd)
		surface:UpdateDescriptorSet("storage_buffer", frame, BINDING_LIGHT_GRID, 0, grid, grid:GetSize())
		surface:UpdateDescriptorSet(
			"combined_image_sampler",
			frame,
			BINDING_OCCLUSION_MAP,
			0,
			unpack(light_occlusion.GetOcclusionDescriptor())
		)
	end

	if scene_reflection.RAY_QUERY then
		scene_reflection.Bind(surface, cmd, frame, SCENE_BINDINGS)
	end
end

local passes = {
	{
		name = "translucent_moments",
		ColorFormat = {
			{"r32_sfloat", {"b0", "r"}},
			{"r32g32b32a32_sfloat", {"moments", "rgba"}},
		},
		DepthFormat = gbuffer_layout.DEPTH_FORMAT,
		ReadOnlyDepth = gbuffer_layout.GetDepthTexture,
		ClearColors = {{0, 0, 0, 0}, {0, 0, 0, 0}},
		on_pre_draw = function(self, cmd)
			bind_surface(render3d.pipelines.translucent_surface, cmd)
			bind_surface(render3d.pipelines.translucent_surface_multi_draw, cmd)
			render3d.refraction_source_requested = false
			render3d.translucent_depth_near = math.huge
			render3d.translucent_depth_far = 0
			event.Call("PreDraw3DTranslucent")

			if render3d.refraction_source_requested then update_refraction_source(cmd) end
		end,
		on_draw = function(self, cmd)
			if render3d.translucent_depth_far == 0 then return end

			render3d.translucent_pipeline = render3d.pipelines.translucent_moments_surface
			render3d.translucent_scope = "translucent_moments"
			render3d.translucent_multi_draw_pipeline = render3d.pipelines.translucent_moments_surface_multi_draw
			event.Call("Draw3DTranslucent")
			translucent_extras.Draw("moments", cmd)
		end,
		fragment = {shader = "void main() { set_b0(0.0); set_moments(vec4(0.0)); }"},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "translucent_moments_surface",
		draw_in_prerender = false,
		dont_create_framebuffers = true,
		ColorFormat = {
			{"r32_sfloat", {"b0", "r"}},
			{"r32g32b32a32_sfloat", {"moments", "rgba"}},
		},
		DepthFormat = gbuffer_layout.DEPTH_FORMAT,
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			camera_block_name = "translucent_camera",
			uniform_buffers = {camera_block},
		},
		fragment = {
			uniform_buffers = moments_uniform_buffers,
			shader = model_pipeline.BuildPBRSurfaceGlsl("translucent_camera") .. translucent_moments.GLSL .. [[
				void main() {
					float alpha = get_alpha();

					if (AlphaTest && alpha < factor_model.AlphaCutoff) discard;

					float absorbance = (Additive || Modulate) ? 0.0 : -log(max(1.0 - alpha, 1e-3));
					float depth = moments_warp_depth(distance(in_position, translucent_camera.camera_position), moments_data.depth_warp);
					float depth2 = depth * depth;
					set_b0(absorbance);
					set_moments(vec4(depth, depth2, depth2 * depth, depth2 * depth2) * absorbance);
				}
			]],
		},
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "one",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "add",
		color_blend = {attachments = {{}, translucent_moments.ADDITIVE}},
		DepthTest = true,
		DepthWrite = false,
		DepthCompareOp = "greater_or_equal",
	},
	{
		name = "translucent_accumulate",
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16b16a16_sfloat", {"motion", "rgba"}},
			{"r16g16b16a16_sfloat", {"additive", "rgba"}},
			{"r16g16b16a16_sfloat", {"modulate", "rgba"}},
		},
		DepthFormat = gbuffer_layout.DEPTH_FORMAT,
		ReadOnlyDepth = gbuffer_layout.GetDepthTexture,
		ClearColors = {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {1, 1, 1, 1}},
		on_draw = function(self, cmd)
			if render3d.translucent_depth_far == 0 then return end

			render3d.translucent_pipeline = render3d.pipelines.translucent_surface
			render3d.translucent_scope = "translucent_accumulate"
			render3d.translucent_multi_draw_pipeline = render3d.pipelines.translucent_surface_multi_draw
			event.Call("Draw3DTranslucent")
			translucent_extras.Draw("accumulate", cmd)
		end,
		fragment = {
			shader = "void main() { set_color(vec4(0.0)); set_motion(vec4(0.0)); set_additive(vec4(0.0)); set_modulate(vec4(1.0)); }",
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "translucent_surface",
		DescriptorSetCount = scene_reflection.RAY_QUERY and render.GetSwapchainImageCount() or nil,
		draw_in_prerender = false,
		dont_create_framebuffers = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16b16a16_sfloat", {"motion", "rgba"}},
			{"r16g16b16a16_sfloat", {"additive", "rgba"}},
			{"r16g16b16a16_sfloat", {"modulate", "rgba"}},
		},
		DepthFormat = gbuffer_layout.DEPTH_FORMAT,
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			velocity = true,
			instance_overlay = true,
			instance_effects = true,
			camera_block_name = "translucent_camera",
			uniform_buffers = {camera_block},
		},
		fragment = {
			push_constants = {
				{
					name = "refraction",
					block = {
						{"amount", "float"},
						{"ior", "float"},
						{"abbe", "float"},
						{"thickness", "float"},
						{"attenuation", "float"},
					},
					write = function(self, block)
						local material = render3d.GetMaterial()
						block.amount = material:GetRefraction()
						block.ior = math.max(material:GetIndexOfRefraction(), 1)
						block.abbe = material:GetAbbeNumber()
						block.thickness = render3d.translucent_thickness
						block.attenuation = material:GetAttenuationDistance()
						return block
					end,
				},
			},
			uniform_buffers = surface_uniform_buffers,
			descriptor_sets = surface_descriptor_sets,
			custom_declarations = surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. (
					scene_reflection.RAY_QUERY and
					scene_reflection.GetDeclarationGLSL(SCENE_BINDINGS, true) or
					""
				) .. [[
				layout(set = 2, binding = 0) uniform sampler3D froxel_volume;
			]],
			shader = glsl_common.GetHashGLSL() .. glsl_common.GetFresnelGLSL() .. model_pipeline.BuildPBRSurfaceGlsl("translucent_camera") .. surface_overlays.GetGLSL("translucent_camera") .. exposure_compensation.GetGLSL() .. (
					scene_reflection.RAY_QUERY and
					glass_light.GetGLSL("ddgi_scene") or
					""
				) .. surface_lighting.GetGLSL("lighting_data") .. gi.GetCommonGLSL() .. (
					scene_reflection.RAY_QUERY and
					scene_reflection.GetGLSL("lighting_data", true) .. scene_reflection.GetDirectionGLSL()
					or
					""
				) .. screen_refraction.GetGLSL("lighting_data") .. translucent_moments.GLSL .. froxel_fog.SLICE_GLSL .. froxel_fog.GetViewDirGLSL("lighting_data") .. [[
				float get_fog_sun_visibility(vec3 world_pos, vec3 sun_dir) {
					return calculateShadow(world_pos, sun_dir, sun_dir) * get_cloud_shadow(world_pos);
				}
			]] .. froxel_fog.GetGLSL("lighting_data") .. [[

				vec3 get_gi_irradiance(vec2 screen_uv, vec3 world_pos, vec3 facing_N, vec3 V, bool use_probes, out float sky_visibility) {
					vec3 irradiance;
					bool behind_is_sky = texture(TEXTURE(lighting_data.depth_tex), screen_uv).r <= 0.0;

					if (lighting_data.gi_screen_tex < 0 || behind_is_sky) {
						sky_visibility = 1.0;
						irradiance = sample_environment_irradiance(lighting_data.env_irradiance_tex, facing_N);
					} else {
						vec4 gi = texture(TEXTURE(lighting_data.gi_screen_tex), screen_uv);
						sky_visibility = gi.a;
						irradiance = gi.rgb;
					}

					if (!use_probes || !gi_available() || !gi_in_volume(world_pos)) return irradiance;

					float weight;
					vec4 probes = gi_sample_irradiance(world_pos, facing_N, V, ddgi_data.ddgi_smooth_blend != 0, DDGI_VISIBILITY_MIN_WEIGHT, weight);
					float confidence = saturate(weight / ]] .. gi.MIN_WEIGHT .. [[);
					sky_visibility = mix(sky_visibility, probes.a, confidence);
					return mix(irradiance, probes.rgb, confidence);
				}

				vec2 get_screen_motion(vec3 world_pos, vec3 prev_world_pos) {
					vec4 clip = translucent_camera.projection * translucent_camera.view * vec4(world_pos, 1.0);
					vec4 prev_clip = translucent_camera.prev_projection * translucent_camera.prev_view * vec4(prev_world_pos, 1.0);

					if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) return vec2(0.0);

					return (clip.xy / clip.w - prev_clip.xy / prev_clip.w) * 0.5;
				}

]] .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_scene_pos"}) .. [[

				vec3 exit_irradiance;
				float exit_sky_visibility;
				vec3 exit_world_pos;
				vec3 exit_N;
				float exit_perceptual_roughness;

				vec3 get_exit_environment(vec3 dir) {
					return blend_probe_reflections(
						mix(exit_irradiance, sample_environment_specular(lighting_data.env_tex, dir, exit_N, exit_perceptual_roughness), exit_sky_visibility),
						dir,
						exit_perceptual_roughness,
						exit_world_pos
					);
				}

				const int MAX_REFRACTION_RAYS = 12;
				int refraction_ray_count = 0;
				vec3 refraction_ray_origin[MAX_REFRACTION_RAYS];
				vec3 refraction_ray_dir[MAX_REFRACTION_RAYS];
				int refraction_ray_channel[MAX_REFRACTION_RAYS];
				float refraction_ray_weight[MAX_REFRACTION_RAYS];

				// the environment and scene traces are left to the caller (env_weight, refraction_ray_*), so each has one call site
				vec3 get_refracted_background(int channel, vec3 surface_pos, vec3 exit_pos, vec3 exit_normal, vec3 dir, float reach, float roughness, out float env_weight) {
					vec3 hash_state = pcg3d_unorm(uvec3(uvec2(gl_FragCoord.xy), uint(lighting_data.time * 60.0)));
					float spin = hash_state.x;
					float jitter = hash_state.y;

					env_weight = 0.0;

					int samples = roughness < 0.04 ? 1 : 4;
					vec3 tangent = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
					vec3 bitangent = cross(dir, tangent);
					vec3 sum = vec3(0.0);
					float weight = 1.0 / float(samples);

					float to_absolute = 1.0 / get_pre_exposure();

					for (int s = 0; s < samples; s++) {
						vec3 ray_dir = dir;

						if (samples > 1) {
							float radius = roughness * sqrt((float(s) + jitter) / float(samples));
							float phi = 6.2831853 * (float(s) / float(samples) + spin);
							ray_dir = normalize(dir + (tangent * cos(phi) + bitangent * sin(phi)) * radius);
						}

						vec2 uv;
						float travel;

						if (!screen_refraction_trace(surface_pos, exit_pos, ray_dir, reach, jitter, uv, travel)) {
							#ifdef SCENE_REFLECTION
							if (scene_reflection_ready()) {
								// a ray that leaves a solid nearly along its surface must start outside it, or it meets the solid again
								refraction_ray_origin[refraction_ray_count] = exit_pos + exit_normal * 0.05 + ray_dir * 0.02;
								refraction_ray_dir[refraction_ray_count] = ray_dir;
								refraction_ray_channel[refraction_ray_count] = channel;
								refraction_ray_weight[refraction_ray_count] = weight;
								refraction_ray_count++;
								continue;
							}
							#endif

							float outside = length(uv - clamp(uv, vec2(0.0), vec2(1.0)));
							float edge_blur = 1.0 + outside * lighting_data.render_size.y * 0.25;
							vec3 edge = textureLod(TEXTURE(lighting_data.refraction_tex), clamp(uv, vec2(0.0), vec2(1.0)), log2(edge_blur)).rgb * to_absolute;
							float far_outside = smoothstep(0.5, 2.0, outside);
							sum += edge * ((1.0 - far_outside) * weight);
							env_weight += far_outside * weight;
							continue;
						}

						vec3 target = exit_pos + ray_dir * travel;
						float view_depth = max(-(lighting_data.view * vec4(target, 1.0)).z, 1e-3);
						float blur_pixels = roughness * travel * abs(lighting_data.projection[1][1]) * 0.5 * lighting_data.render_size.y / view_depth;

						if (samples > 1) blur_pixels *= 0.5;

						if (blur_pixels <= 2.0) {
							sum += textureLod(TEXTURE(lighting_data.refraction_tex), uv, log2(max(blur_pixels, 1.0))).rgb * (to_absolute * weight);
							continue;
						}

						vec2 spread = vec2(blur_pixels * 0.5) / lighting_data.render_size;
						float lod = log2(blur_pixels * 0.5);
						sum += (
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(-0.5, -0.5), lod).rgb +
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(0.5, -0.5), lod).rgb +
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(-0.5, 0.5), lod).rgb +
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(0.5, 0.5), lod).rgb
						) * (0.25 * to_absolute * weight);
					}

					return sum;
				}

				void main() {
					float alpha = get_alpha();

					if (AlphaTest && alpha < factor_model.AlphaCutoff) discard;

					vec2 screen_uv = gl_FragCoord.xy / lighting_data.render_size;
					vec3 world_pos = in_position;
					ivec2 pixel = ivec2(gl_FragCoord.xy);
					float transmittance = moments_transmittance(
						texelFetch(TEXTURE(lighting_data.b0_tex), pixel, 0).r,
						texelFetch(TEXTURE(lighting_data.moments_tex), pixel, 0),
						moments_warp_depth(distance(world_pos, lighting_data.camera_position.xyz), lighting_data.depth_warp)
					);
					vec3 fog_transmittance = vec3(1.0);
					vec3 fog_scattered = lighting_data.fog != 0 ? get_volumetric_fog(screen_uv, distance(world_pos, lighting_data.camera_position.xyz), fog_transmittance) : vec3(0.0);
					vec2 motion = get_screen_motion(world_pos, in_prev_position);
					vec3 geometric_N = get_vertex_normal();
					float curvature = max(
						length(dFdx(geometric_N)) / max(length(dFdx(world_pos)), 1e-6),
						length(dFdy(geometric_N)) / max(length(dFdy(world_pos)), 1e-6)
					);
					vec3 V = normalize(lighting_data.camera_position.xyz - world_pos);
					mat3 tbn = get_tbn();
					prepare_terrain_layers(in_uv, in_position);
					vec3 N = bend_normal_to_view(get_normal(in_uv, tbn), V);
					vec3 albedo = get_albedo();
					float metallic = get_metallic(in_uv);
					float roughness = get_antialiased_roughness(N, get_roughness(in_uv));
					float overlay_cover = 0.0;
					vec3 overlay_emissive = vec3(0.0);

					if (in_instance_overlay > 0.0) {
						Surface overlay_surface;
						init_surface_features(overlay_surface, in_uv);
						overlay_surface.world_pos = world_pos;
						overlay_surface.geometric_N = geometric_N;
						overlay_surface.albedo = albedo;
						overlay_surface.roughness_alpha = roughness;
						overlay_surface.metallic = metallic;
						overlay_surface.N = N;
						overlay_surface.alpha = 0.0;
						overlay_surface.emissive = vec3(0.0);
						SurfaceWeather overlay_weather = SurfaceWeather(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0);
						apply_surface_overlays(overlay_surface, overlay_weather, in_instance_overlay, in_effect_position, in_effect_normal, in_uv);
						albedo = overlay_surface.albedo;
						roughness = overlay_surface.roughness_alpha;
						metallic = overlay_surface.metallic;
						N = overlay_surface.N;
						overlay_emissive = overlay_surface.emissive;
						overlay_cover = overlay_surface.alpha;
						alpha = max(alpha, overlay_cover);
					}

					if (Unlit) {
						vec3 unlit_emission = DisplayReferred ? get_albedo_uv(in_uv) * color_model.ColorMultiplier.a / ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : get_emissive(in_uv) * color_model.ColorMultiplier.a * get_pre_exposure();

						if (VertexTint) {
							unlit_emission = DisplayReferred ? unlit_emission * in_vertex_color.rgb * in_vertex_color.a : min(get_emissive(in_uv) * in_vertex_color.rgb, vec3(EMISSIVE_MAX_LUMINANCE)) * in_vertex_color.a * get_pre_exposure();
						}

						if (!DisplayReferred) unlit_emission *= effect_exposure_gain(translucent_camera.exposure_compensation_tex, color_model.ExposureCompensation);

						unlit_emission += overlay_emissive * alpha * (VertexTint ? in_vertex_color.a : 1.0) * get_pre_exposure();
						set_color(vec4(0.0));
						set_motion(vec4(0.0));
						set_additive(vec4(min(unlit_emission * fog_transmittance, vec3(65504.0)), 0.0) * transmittance);
						set_modulate(vec4(1.0));
						return;
					}

					float perceptual_roughness = sqrt(roughness);
					float diffuse_transmission = get_transmission(in_uv);
					float refraction_amount = refraction.amount * (1.0 - overlay_cover);
					bool refractive = refraction.amount > 0.0;
					float refraction_roughness = roughness;
					float ior_f0 = (refraction.ior - 1.0) / (refraction.ior + 1.0);
					vec3 F0 = mix(vec3(refractive ? ior_f0 * ior_f0 : get_specular(in_uv) * 0.04), albedo, metallic);
					float NdotV = max(dot(N, V), 0.001);
					vec3 diffuse_albedo = albedo * (refractive ? 1.0 - refraction_amount : alpha);
					float specular_coverage = refractive ? 1.0 : smoothstep(0.0, 0.1, alpha);

					vec3 direct_specular;
					Surface surface;
					surface.geometric_N = geometric_N;
					init_surface_features(surface, in_uv);
					surface.F0 = F0;
					surface.NdotV = NdotV;
					surface.albedo = diffuse_albedo;
					surface.roughness_alpha = roughness;
					surface.perceptual_roughness = perceptual_roughness;
					surface.metallic = metallic;
					surface.world_pos = world_pos;
					surface.V = V;
					surface.N = N;
					finish_surface_features(surface);
					vec3 direct_diffuse = get_direct_light(surface, direct_specular);

					bool traced_only = false;
					#ifdef SCENE_REFLECTION
					float traced_weight = 1.0 - smoothstep(lighting_data.reflection_gi_start, lighting_data.reflection_gi_end, clamp(perceptual_roughness, 0.0, 1.0));
					traced_only = traced_weight >= 1.0 && scene_reflection_ready();
					#endif
					float sky_visibility = 1.0;
					vec3 irradiance = vec3(0.0);
					bool gi_known = !(refractive && refraction_amount >= 1.0 && traced_only);
					bool use_probes = !(refractive && refraction_amount >= 1.0);

					exit_world_pos = world_pos;
					exit_N = N;
					exit_perceptual_roughness = sqrt(refraction_roughness);
					vec3 raw_R = reflect(-V, N);
					vec3 reflection = vec3(0.0);

					vec3 trace_origin = world_pos + (dot(geometric_N, V) < 0.0 ? -geometric_N : geometric_N) * 0.02;
					bool reflection_rough = perceptual_roughness > SCENE_REFLECTION_MIRROR_THRESHOLD;
					int reflection_rays = 0;
					float reflection_limit = 0.0;
					#ifdef SCENE_REFLECTION
					if (traced_weight > 0.0 && scene_reflection_ready()) {
						reflection_rays = scene_reflection_ray_count(perceptual_roughness, lighting_data.rough_rays);
						reflection_limit = scene_reflection_hit_luminance_limit(perceptual_roughness, SCENE_REFLECTION_MAX_HIT_LUMINANCE / get_exposure(), lighting_data.reflection_gi_end);
					}
					#endif

					bool refracts = refractive && !Modulate && !Additive;
					int channel_count = refraction.abbe > 0.0 ? 3 : 1;
					vec3 channel_known[3] = vec3[3](vec3(0.0), vec3(0.0), vec3(0.0));
					float channel_env[3] = float[3](0.0, 0.0, 0.0);
					vec3 channel_exit_dir[3] = vec3[3](vec3(0.0), vec3(0.0), vec3(0.0));
					float exit_transmitted = 0.0;
					float path_length = 0.0;
					float flat_exit = 0.0;

					if (refracts) {
						vec3 I = -V;
						vec3 facing_N = dot(geometric_N, V) < 0.0 ? -geometric_N : geometric_N;
						vec3 channel_ior = screen_refraction_dispersed_ior(refraction.ior, refraction.abbe);

						for (int channel = 0; channel < channel_count; channel++) {
							float ior = channel_ior[channel];
							float eta = 1.0 / ior;
							vec3 T = refract(I, N, eta);
							vec3 exit_pos = world_pos;
							vec3 exit_dir;
							vec3 exit_outward = facing_N;

							if (refraction.thickness > 0.0) {
								float radius = max(1.0 / max(curvature, 1e-4), refraction.thickness * 0.5);
								float cos_in = max(-dot(T, facing_N), 0.05);
								float sphere_length = 2.0 * radius * cos_in;
								float slab_length = refraction.thickness / cos_in;
								exit_pos = world_pos + T * min(sphere_length, slab_length);
								vec3 exit_N = sphere_length < slab_length ? normalize(exit_pos - (world_pos - facing_N * radius)) : -facing_N;
								exit_outward = exit_N;
								exit_dir = refract(T, -exit_N, ior);

								path_length += min(sphere_length, slab_length);
								flat_exit += sphere_length < slab_length ? 0.0 : 1.0;

								if (dot(exit_dir, exit_dir) < 1e-6) {
									exit_dir = T;
									exit_transmitted += 1.0;
								} else {
									exit_transmitted += 1.0 - fresnel_dielectric(dot(T, exit_N), ior);
								}
							} else {
								exit_dir = normalize(I + T - refract(I, facing_N, eta));
							}

							vec3 channel_background = vec3(0.0);
							channel_exit_dir[channel] = exit_dir;
							channel_env[channel] = 0.0;

							if (lighting_data.refraction_tex < 0) {
								channel_env[channel] = 1.0;
							} else if (refraction.thickness > 0.0) {
								float scene_depth = texture(TEXTURE(lighting_data.depth_tex), screen_uv).r;
								float surface_distance = distance(lighting_data.camera_position.xyz, exit_pos);
								float reach = 2.0 * surface_distance;

								if (scene_depth > 0.0) {
									vec3 scene_pos = get_scene_pos(screen_uv, scene_depth);
									reach = 3.0 * max(distance(lighting_data.camera_position.xyz, scene_pos) - surface_distance, 0.0) + 0.5;
								}

								channel_background = get_refracted_background(channel, world_pos, exit_pos, exit_outward, exit_dir, reach, refraction_roughness, channel_env[channel]);
							} else {
								vec2 slope = (lighting_data.view * vec4(N - facing_N, 0.0)).xy;
								vec2 uv = clamp(screen_uv + vec2(slope.x, -slope.y) * (ior - 1.0), vec2(0.0), vec2(1.0));
								float blur_pixels = refraction_roughness * lighting_data.render_size.y * 0.05;
								channel_background = textureLod(TEXTURE(lighting_data.refraction_tex), uv, log2(max(blur_pixels, 1.0))).rgb / get_pre_exposure();
							}

							channel_known[channel] = channel_background;
						}
					}

					// every call site inlines the whole hit shading and gi lookup, so reflection and refraction rays share one trace call
					vec3 reflection_sum = vec3(0.0);
					#ifdef SCENE_REFLECTION

					for (int ray = 0; ray < reflection_rays + refraction_ray_count; ray++) {
						bool reflected = ray < reflection_rays;
						int k = ray - reflection_rays;
						vec3 origin = trace_origin;
						vec3 dir = raw_R;
						vec3 trace_N = N;
						float environment_roughness = perceptual_roughness;

						if (reflected) {
							if (reflection_rough) {
								vec2 xi = pcg3d_unorm(uvec3(uvec2(gl_FragCoord.xy), uint(lighting_data.frame_index) * 16u + uint(ray))).xy;
								dir = scene_reflection_direction(N, V, perceptual_roughness, xi, environment_roughness);
							}
						} else {
							origin = refraction_ray_origin[k];
							dir = refraction_ray_dir[k];
							trace_N = dir;
							environment_roughness = refraction_roughness;
						}

						float traced_t;
						vec3 traced = trace_scene_reflection(origin, dir, trace_N, environment_roughness, SCENE_REFLECTION_MAX_DISTANCE, traced_t);

						if (reflected) {
							if (reflection_rough && traced_t < SCENE_REFLECTION_MAX_DISTANCE) traced = scene_reflection_limit_hit(traced, perceptual_roughness, reflection_limit);

							reflection_sum += traced;
						} else {
							int c = refraction_ray_channel[k];

							if (traced_t < SCENE_REFLECTION_MAX_DISTANCE) {
								channel_known[c] += traced * refraction_ray_weight[k];
							} else {
								channel_env[c] += refraction_ray_weight[k];
							}
						}
					}

					#endif

					// the surface's gi and the exit environment's are never both needed: one call site for either
					bool exit_needs_gi = !gi_known && refracts && (channel_env[0] > 0.0 || channel_env[1] > 0.0 || channel_env[2] > 0.0);

					if (gi_known || exit_needs_gi) {
						float gi_sky_visibility;
						vec3 gi_irradiance = get_gi_irradiance(screen_uv, world_pos, dot(geometric_N, V) < 0.0 ? -geometric_N : geometric_N, V, gi_known ? use_probes : true, gi_sky_visibility);
						exit_irradiance = gi_irradiance;
						exit_sky_visibility = gi_sky_visibility;

						if (gi_known) {
							irradiance = gi_irradiance;
							sky_visibility = gi_sky_visibility;
						}
					}

					if (!traced_only) {
						vec3 R = get_specular_dominant_direction(raw_R, N, perceptual_roughness);
						vec3 sky_reflection = sample_environment_specular(lighting_data.env_tex, raw_R, N, perceptual_roughness);
						reflection = blend_probe_reflections(mix(irradiance, sky_reflection, sky_visibility), R, perceptual_roughness, world_pos);
					}

					if (reflection_rays > 0) reflection = mix(reflection, reflection_sum / float(reflection_rays), traced_weight);

					vec3 background = vec3(0.0);

					for (int channel = 0; refracts && channel < channel_count; channel++) {
						vec3 channel_background = channel_known[channel];

						if (channel_env[channel] > 0.0) channel_background += channel_env[channel] * get_exit_environment(channel_exit_dir[channel]);

						if (channel_count == 1) {
							background = channel_background;
						} else {
							background[channel] = channel_background[channel];
						}
					}

					vec2 env_brdf = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NdotV, perceptual_roughness)).rg;
					vec3 F_ambient = F_SchlickRoughness(F0, NdotV, perceptual_roughness);
					vec3 ambient_diffuse = (1.0 - F_ambient) * (1.0 - metallic) * irradiance * diffuse_albedo * get_ao(in_uv);
					vec3 ambient_specular = reflection * (F0 * env_brdf.x + F90(F0) * env_brdf.y) * GGXEnergyCompensation(F0, env_brdf);
					float fresnel_front = fresnel_dielectric(NdotV, 1.0 / refraction.ior);
					vec3 pane_reflectance = vec3(fresnel_front);
					vec3 pane_transmittance = vec3(1.0 - fresnel_front);

					if (refractive && refraction.thickness <= 0.0) {
						vec3 tau = albedo;
						vec3 bounces = 1.0 - fresnel_front * fresnel_front * tau * tau;
						pane_reflectance = fresnel_front + (1.0 - fresnel_front) * (1.0 - fresnel_front) * fresnel_front * tau * tau / bounces;
						pane_transmittance = (1.0 - fresnel_front) * (1.0 - fresnel_front) * tau / bounces;
					}


					set_modulate(vec4(1.0));

					if (Modulate) {
						vec3 factor = 4.5948 * albedo * color_model.ColorMultiplier.rgb;
						set_color(vec4(0.0));
						set_motion(vec4(0.0));
						set_additive(vec4(0.0));
						set_modulate(vec4(mix(vec3(1.0), factor, transmittance * color_model.ColorMultiplier.a), 1.0));
						return;
					}

					if (Additive) {
						vec3 emission = DisplayReferred ? get_albedo_uv(in_uv) * color_model.ColorMultiplier.a / ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : get_emissive(in_uv) * color_model.ColorMultiplier.a * get_pre_exposure();

						if (VertexTint) {
							emission = DisplayReferred ? emission * in_vertex_color.rgb * in_vertex_color.a : min(get_emissive(in_uv) * in_vertex_color.rgb, vec3(EMISSIVE_MAX_LUMINANCE)) * in_vertex_color.a * get_pre_exposure();
						}
						if (!DisplayReferred) emission *= effect_exposure_gain(translucent_camera.exposure_compensation_tex, color_model.ExposureCompensation);

						vec3 specular = (direct_specular + ambient_specular) * specular_coverage * get_pre_exposure();

						if (VertexTint) {
							specular *= in_vertex_color.rgb / max(max(in_vertex_color.r, max(in_vertex_color.g, in_vertex_color.b)), 1e-4) * in_vertex_color.a;
						}

						vec3 added = emission + specular;
						set_color(vec4(0.0));
						set_motion(vec4(0.0));
						set_additive(vec4(min(added * fog_transmittance, vec3(65504.0)), 0.0) * transmittance);
						return;
					}

					if (!refractive) {
						vec3 emissive = (get_emissive(in_uv) + overlay_emissive) * alpha;
						vec3 color = direct_diffuse + ambient_diffuse + (direct_specular + ambient_specular) * specular_coverage + emissive;
						color = color * fog_transmittance + fog_scattered * alpha;
						set_color(vec4(min(color * get_pre_exposure(), vec3(65504.0)), alpha) * transmittance);
						set_motion(vec4(motion, 1.0, 0.0) * alpha * transmittance);
						set_additive(vec4(0.0));
						return;
					}

					vec3 transmission = pane_transmittance;
					vec3 reflectance = pane_reflectance;

					if (refraction.thickness > 0.0) {
						float inside = path_length / float(channel_count);
						vec3 absorbed = refraction.attenuation > 0.0 ? pow(max(albedo, vec3(1e-3)), vec3(inside / refraction.attenuation)) : albedo;
						transmission = (1.0 - fresnel_front) * absorbed * (exit_transmitted / float(channel_count));
						reflectance = vec3(fresnel_front);

						float slab = flat_exit / float(channel_count);

						if (slab > 0.0) {
							vec3 bounces = 1.0 - fresnel_front * fresnel_front * absorbed * absorbed;
							vec3 slab_reflectance = fresnel_front + (1.0 - fresnel_front) * (1.0 - fresnel_front) * fresnel_front * absorbed * absorbed / bounces;
							vec3 slab_transmittance = (1.0 - fresnel_front) * (1.0 - fresnel_front) * absorbed / bounces;
							transmission = mix(transmission, slab_transmittance, slab);
							reflectance = mix(reflectance, slab_reflectance, slab);
						}
					}

					float schlick_front = F0.x + (1.0 - F0.x) * pow(1.0 - NdotV, 5.0);
					vec3 reflectance_scale = reflectance / max(schlick_front, 1e-4);
					ambient_specular *= reflectance_scale;
					direct_specular *= reflectance_scale;
					transmission *= (1.0 - metallic) * refraction_amount;
					vec3 emissive = get_emissive(in_uv) + overlay_emissive;
					vec3 color = (direct_diffuse + ambient_diffuse + direct_specular + ambient_specular + emissive) * fog_transmittance + fog_scattered * (1.0 - transmission) + background * transmission;
					set_color(vec4(min(color * (alpha * get_pre_exposure()), vec3(65504.0)), alpha) * transmittance);
					set_motion(vec4(motion, 1.0, 0.0) * alpha * transmittance * (1.0 - dot(transmission, vec3(1.0 / 3.0))));
					set_additive(vec4(0.0));
				}
			]],
		},
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "one",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "add",
		color_blend = {
			attachments = {
				{},
				translucent_moments.ADDITIVE,
				translucent_moments.ADDITIVE,
				translucent_moments.MULTIPLY,
			},
		},
		DepthTest = true,
		DepthWrite = false,
		DepthCompareOp = "greater_or_equal",
	},
	{
		name = "translucent_modulate",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		dont_create_framebuffers = true,
		TargetFramebuffer = post_source.GetFoggedOpaqueSceneFramebuffer,
		on_draw = function(self, cmd)
			if render3d.translucent_depth_far == 0 then return end

			self:UploadConstants()
			cmd:Draw(3, 1, 0, 0)
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "modulate_composite",
					binding_index = 3,
					block = {
						{"modulate_tex", "int"},
					},
					write = function(self, block)
						block.modulate_tex = self:GetTextureIndex(render3d.pipelines.translucent_accumulate:GetFramebuffer():GetAttachment(4))
						return block
					end,
				},
			},
			shader = [[
				void main() {
					set_color(vec4(texelFetch(TEXTURE(modulate_composite.modulate_tex), ivec2(gl_FragCoord.xy), 0).rgb, 1.0));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		Blend = true,
		SrcColorBlendFactor = "zero",
		DstColorBlendFactor = "src_color",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "zero",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "add",
	},
	{
		name = "translucent",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		dont_create_framebuffers = true,
		TargetFramebuffer = post_source.GetFoggedOpaqueSceneFramebuffer,
		on_draw = function(self, cmd)
			if render3d.translucent_depth_far == 0 then return end

			self:UploadConstants()
			cmd:Draw(3, 1, 0, 0)
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "translucent_composite",
					binding_index = 3,
					block = {
						{"b0_tex", "int"},
						{"accumulated_tex", "int"},
						{"additive_tex", "int"},
					},
					write = function(self, block)
						block.b0_tex = self:GetTextureIndex(translucent_moments.GetTextures())
						local accumulate = render3d.pipelines.translucent_accumulate:GetFramebuffer()
						block.accumulated_tex = self:GetTextureIndex(accumulate:GetAttachment(1))
						block.additive_tex = self:GetTextureIndex(accumulate:GetAttachment(3))
						return block
					end,
				},
			},
			shader = [[
				void main() {
					ivec2 pixel = ivec2(gl_FragCoord.xy);
					vec4 accumulated = texelFetch(TEXTURE(translucent_composite.accumulated_tex), pixel, 0);

					vec3 additive = texelFetch(TEXTURE(translucent_composite.additive_tex), pixel, 0).rgb;

					if (accumulated.a <= 0.0 && dot(additive, vec3(1.0)) <= 0.0) discard;

					float transmittance = exp(-texelFetch(TEXTURE(translucent_composite.b0_tex), pixel, 0).r);
					vec3 covering = accumulated.a > 0.0 ? accumulated.rgb * ((1.0 - transmittance) / accumulated.a) : vec3(0.0);
					set_color(vec4(covering + additive, transmittance));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "zero",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "add",
	},
}
local multi_draw_block = {
	name = "translucent_draw",
	block = {
		{"batches", "uint64_t"},
		{"instances", "uint64_t"},
		{"prev_instances", "uint64_t"},
		{"thicknesses", "uint64_t"},
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
		block.thicknesses = self.draw_thicknesses_address or 0
		block.batch_ids = self.draw_batch_ids_address or 0
		block.time = atmosphere.GetWindTime()
		block.prev_time = atmosphere.GetPreviousWindTime()
		block.detail_time = atmosphere.GetWindDetailTime()
		block.prev_detail_time = atmosphere.GetPreviousWindDetailTime()
		return block
	end,
}

local function build_multi_draw_pass(source, uniform_buffers, with_thickness)
	local pass = {}

	for k, v in pairs(source) do
		pass[k] = v
	end

	pass.name = source.name .. "_multi_draw"
	pass.vertex = model_pipeline.CreateMultiDrawVertexStage{
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		velocity = true,
		instance_overlay = with_thickness or nil,
		instance_effects = with_thickness or nil,
		camera_block_name = "translucent_camera",
		uniform_buffers = {camera_block, multi_draw_block},
		batches_expr = "translucent_draw.batches",
		instances_expr = "translucent_draw.instances",
		prev_instances_expr = "translucent_draw.prev_instances",
		batch_index_expr = "(translucent_draw.batch_ids != 0ul ? PBRBatchIdData(translucent_draw.batch_ids).ids[gl_InstanceIndex].x : uint(gl_DrawID))",
		instance_thickness_expr = with_thickness and
			"PBRBatchThicknessData(translucent_draw.thicknesses).t[gl_InstanceIndex]" or
			nil,
		time_expr = "translucent_draw.time",
		prev_time_expr = "translucent_draw.prev_time",
		detail_time_expr = "translucent_draw.detail_time",
		prev_detail_time_expr = "translucent_draw.prev_detail_time",
	}
	local fragment = {}

	for k, v in pairs(source.fragment) do
		fragment[k] = v
	end

	fragment.push_constants = nil
	fragment.uniform_buffers = {}

	for _, ubo in ipairs(uniform_buffers) do
		table.insert(fragment.uniform_buffers, ubo)
	end

	table.insert(fragment.uniform_buffers, multi_draw_block)
	fragment.custom_declarations = (
			source.fragment.custom_declarations or
			""
		) .. string.format("layout(location = %d) flat in uint in_batch;\n", pass.vertex.batch_location) .. model_pipeline.BuildPBRBatchRecordGlsl("PBRBatchData(translucent_draw.batches).b[in_batch]")

	if with_thickness then
		fragment.custom_declarations = fragment.custom_declarations .. [[
			struct RefractionView {
				float amount;
				float ior;
				float abbe;
				float thickness;
				float attenuation;
			};
			RefractionView refraction;
		]]
		local main
		local init = 1

		while true do
			local found = source.fragment.shader:find("void main() {", init, true)

			if not found then break end

			main = found
			init = found + 1
		end

		assert(main, "no main in the surface shader")
		fragment.shader = source.fragment.shader:sub(1, main - 1) .. [[
			void main() {
				refraction = RefractionView(refraction_record.amount, refraction_record.ior, refraction_record.abbe, in_instance_thickness, refraction_record.attenuation);
		]] .. source.fragment.shader:sub(main + #"void main() {")
	end

	pass.fragment = fragment
	return pass
end

do
	local list = {}

	for i, pass in ipairs(passes) do
		if pass.name == "translucent_moments_surface" then
			table.insert(
				list,
				build_multi_draw_pass(pass, {camera_block, moments_uniform_buffers[#moments_uniform_buffers]}, false)
			)
		elseif pass.name == "translucent_surface" then
			table.insert(
				list,
				build_multi_draw_pass(
					pass,
					{
						camera_block,
						surface_uniform_buffers[#surface_uniform_buffers - 1],
						surface_uniform_buffers[#surface_uniform_buffers],
					},
					true
				)
			)
		end
	end

	for _, pass in ipairs(list) do
		table.insert(passes, pass)
	end
end

for _, extra in ipairs(translucent_extras.list) do
	for _, pass in ipairs(extra.BuildPasses()) do
		table.insert(passes, pass)
	end
end

return passes
