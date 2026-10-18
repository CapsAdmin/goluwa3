local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local glass_light = import("goluwa/render3d/glass_light.lua")
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
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
	table.add(surface_descriptor_sets, scene_reflection.GetDescriptorSets(SCENE_BINDINGS, "fragment"))
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
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
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
		block = ddgi.GetProbeBlockLayout(),
		write = function(self, block)
			if render3d.IsPassEnabled("ddgi") then
				ddgi.WriteProbeBlock(self, block)

				if not scene_reflection.IsEnabled() then block.ddgi_rt_ready = 0 end

				return block
			end

			block.ddgi_cascade_count = 0
			block.ddgi_rt_ready = 0
			return block
		end,
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
-- what the surface pipelines read besides their own uniforms: the light grid, the occlusion map, the fog and the scene
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

	if scene_reflection.RAY_QUERY then scene_reflection.Bind(surface, cmd, frame, SCENE_BINDINGS) end
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

			if render3d.refraction_source_requested then
				update_refraction_source(cmd)
			end
		end,
		on_draw = function(self, cmd)
			if render3d.translucent_depth_far == 0 then return end

			render3d.translucent_pipeline = render3d.pipelines.translucent_moments_surface
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

					// an additive surface only adds light, the scene behind it stays
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
						-- an index under 1 is not a medium light slows down in, and 0 divides by zero in the refraction
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
			shader = glsl_common.GetHashGLSL() .. glsl_common.GetFresnelGLSL() .. model_pipeline.BuildPBRSurfaceGlsl("translucent_camera") .. (
				scene_reflection.RAY_QUERY and
				glass_light.GetGLSL("ddgi_scene") or
				""
			) .. surface_lighting.GetGLSL("lighting_data") .. ddgi.GetCommonGLSL() .. (
				scene_reflection.RAY_QUERY and
				scene_reflection.GetGLSL("lighting_data", true) or
				""
			) .. screen_refraction.GetGLSL("lighting_data") .. translucent_moments.GLSL .. froxel_fog.SLICE_GLSL .. froxel_fog.GetViewDirGLSL("lighting_data") .. [[
				float get_fog_sun_visibility(vec3 world_pos, vec3 sun_dir) {
					return calculateShadow(world_pos, sun_dir, sun_dir) * get_cloud_shadow(world_pos);
				}
			]] .. froxel_fog.GetGLSL("lighting_data") .. [[
				// the gi at the surface itself, from the probes, for the side the
				// viewer is on. the gbuffer's screen space gi is the light of the
				// opaque surface behind, which is another place with another
				// normal, and only stands in where there are no probes
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

					if (!use_probes || !ddgi_in_volume(world_pos)) return irradiance;

					float weight;
					vec4 probes = ddgi_sample_irradiance(world_pos, facing_N, facing_N, V, ddgi_data.ddgi_smooth_blend != 0, DDGI_VISIBILITY_MIN_WEIGHT, weight);
					// where the probes are all but hidden the sample fades to nothing,
					// which gives way to the fallback just as smoothly
					float confidence = saturate(weight / ]] .. ddgi.MIN_WEIGHT .. [[);
					sky_visibility = mix(sky_visibility, probes.a, confidence);
					return mix(irradiance, probes.rgb, confidence);
				}

				// how far the surface moved on screen since last frame
				vec2 get_screen_motion(vec3 world_pos, vec3 prev_world_pos) {
					vec4 clip = translucent_camera.projection * translucent_camera.view * vec4(world_pos, 1.0);
					vec4 prev_clip = translucent_camera.prev_projection * translucent_camera.prev_view * vec4(prev_world_pos, 1.0);

					if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) return vec2(0.0);

					return (clip.xy / clip.w - prev_clip.xy / prev_clip.w) * 0.5;
				}

]] .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_scene_pos"}) .. [[

				// the radiance behind the surface arriving along dir: the scene
				// where the ray meets it, blurred by how far roughness has spread
				// it by then, or the environment when it leaves the screen.
				// reach is how far to look, a few times how far behind the
				// surface the scene is along the view ray
				// what a ray that leaves a refracting surface finds where the screen and the scene do not say: the sky and the probes'
				// light. Only a ray that misses needs it, so it is worked out there, with the surface's values kept here
				bool exit_gi_known;
				bool exit_use_probes;
				vec3 exit_irradiance;
				float exit_sky_visibility;
				vec2 exit_screen_uv;
				vec3 exit_world_pos;
				vec3 exit_geometric_N;
				vec3 exit_V;
				vec3 exit_N;
				float exit_perceptual_roughness;

				vec3 get_exit_environment(vec3 dir) {
					if (!exit_gi_known) {
						exit_irradiance = get_gi_irradiance(exit_screen_uv, exit_world_pos, dot(exit_geometric_N, exit_V) < 0.0 ? -exit_geometric_N : exit_geometric_N, exit_V, exit_use_probes, exit_sky_visibility);
						exit_gi_known = true;
					}

					return blend_probe_reflections(
						mix(exit_irradiance, sample_environment_specular(lighting_data.env_tex, dir, exit_N, exit_perceptual_roughness), exit_sky_visibility),
						dir,
						exit_perceptual_roughness,
						exit_world_pos
					);
				}

				vec3 get_refracted_background(vec3 surface_pos, vec3 exit_pos, vec3 exit_normal, vec3 dir, float reach, float roughness) {
					// per pixel and frame noise for the step jitter and the cone's rotation; a hash, because the
					// gradient noise has diagonal structure that slides along as the frame moves
					vec3 hash_state = pcg3d_unorm(uvec3(uvec2(gl_FragCoord.xy), uint(lighting_data.time * 60.0)));
					float spin = hash_state.x;
					float jitter = hash_state.y;

					if (lighting_data.refraction_tex < 0) return get_exit_environment(dir);

					// a rough interface spreads the ray into a cone. One ray lands on one object, so a blurred lookup
					// at where it landed keeps the hard edge of whatever it met; several rays across the cone average
					// the objects they meet instead, and the lookup only has to fill what lies between them
					int samples = roughness < 0.04 ? 1 : 4;
					vec3 tangent = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
					vec3 bitangent = cross(dir, tangent);
					vec3 sum = vec3(0.0);

					// the fogged scene is pre-exposed, the shading here is absolute
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
							// the ray left the screen, where the opaque scene is not known. With ray queries the scene
							// there is traced, without them the edge of the screen it left through stands in for it
							// (smeared and blurred more the further outside it went) and fades to the probes' light
							// only when far outside, a probe is dark where the scene is not
							#ifdef SCENE_REFLECTION
							if (scene_reflection_ready()) {
								float traced_t;
								// a ray that leaves a solid nearly along its surface must start outside it, or it meets the solid again
								vec3 traced = trace_scene_reflection(exit_pos + exit_normal * 0.05 + ray_dir * 0.02, ray_dir, ray_dir, roughness, SCENE_REFLECTION_MAX_DISTANCE, traced_t);

								// a ray that hit nothing got the raw sky back, which is not what the surroundings (an enclosed place,
								// the probes) say is there: those are what the screen would have used, so only a hit is taken
								sum += traced_t < SCENE_REFLECTION_MAX_DISTANCE ? traced : get_exit_environment(dir);
								continue;
							}
							#endif

							float outside = length(uv - clamp(uv, vec2(0.0), vec2(1.0)));
							float edge_blur = 1.0 + outside * lighting_data.render_size.y * 0.25;
							vec3 edge = textureLod(TEXTURE(lighting_data.refraction_tex), clamp(uv, vec2(0.0), vec2(1.0)), log2(edge_blur)).rgb * to_absolute;
							float far_outside = smoothstep(0.5, 2.0, outside);
							sum += far_outside > 0.0 ? mix(edge, get_exit_environment(dir), far_outside) : edge;
							continue;
						}

						vec3 target = exit_pos + ray_dir * travel;
						float view_depth = max(-(lighting_data.view * vec4(target, 1.0)).z, 1e-3);
						float blur_pixels = roughness * travel * abs(lighting_data.projection[1][1]) * 0.5 * lighting_data.render_size.y / view_depth;

						if (samples > 1) blur_pixels *= 0.5;

						if (blur_pixels <= 2.0) {
							sum += textureLod(TEXTURE(lighting_data.refraction_tex), uv, log2(max(blur_pixels, 1.0))).rgb * to_absolute;
							continue;
						}

						// four taps a level finer than the blur, so the box filtered
						// mips don't show as blocks
						vec2 spread = vec2(blur_pixels * 0.5) / lighting_data.render_size;
						float lod = log2(blur_pixels * 0.5);
						sum += (
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(-0.5, -0.5), lod).rgb +
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(0.5, -0.5), lod).rgb +
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(-0.5, 0.5), lod).rgb +
							textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(0.5, 0.5), lod).rgb
						) * (0.25 * to_absolute);
					}

					return sum / float(samples);
				}

				void main() {
					float alpha = get_alpha();

					if (AlphaTest && alpha < factor_model.AlphaCutoff) discard;

					vec2 screen_uv = gl_FragCoord.xy / lighting_data.render_size;
					vec3 world_pos = in_position;
					// how much of this surface is seen through those in front of it
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
					// how fast the surface bends, from how the interpolated normal
					// turns across the pixel. 0 on a flat face
					float curvature = max(
						length(dFdx(geometric_N)) / max(length(dFdx(world_pos)), 1e-6),
						length(dFdy(geometric_N)) / max(length(dFdy(world_pos)), 1e-6)
					);
					vec3 V = normalize(lighting_data.camera_position.xyz - world_pos);
					mat3 tbn = get_tbn();
					vec3 N = bend_normal_to_view(get_normal(in_uv, tbn), V);
					vec3 albedo = get_albedo();
					float metallic = get_metallic(in_uv);
					float roughness = get_antialiased_roughness(N, get_roughness(in_uv));
					float perceptual_roughness = sqrt(roughness);
					float diffuse_transmission = get_transmission(in_uv);
					bool refractive = refraction.amount > 0.0;
					// a refracting surface reflects what its index of refraction
					// says, and scatters diffusely only what it doesn't transmit
					float ior_f0 = (refraction.ior - 1.0) / (refraction.ior + 1.0);
					vec3 F0 = mix(vec3(refractive ? ior_f0 * ior_f0 : get_specular(in_uv) * 0.04), albedo, metallic);
					float NdotV = max(dot(N, V), 0.001);
					// alpha is how much of the pixel the surface covers. a surface
					// that doesn't refract uses it as its opacity, scaling what it
					// scatters itself: its diffuse and emission. reflection comes off
					// the covered and the clear parts alike, but not off texels that
					// hold no surface at all
					vec3 diffuse_albedo = albedo * (refractive ? 1.0 - refraction.amount : alpha);
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

					// a smooth surface reflects what the scene holds, one ray along the mirror direction (there
					// is no history to average a rough one over), fading into the probes as it roughens
					bool traced_only = false;
					#ifdef SCENE_REFLECTION
					float traced_weight = 1.0 - smoothstep(0.1, 0.35, perceptual_roughness);
					traced_only = traced_weight >= 1.0 && scene_reflection_ready();
					#endif
					// the light of the probes is the surface's own diffuse and what it reflects where nothing is traced. A
					// surface that transmits all, and reflects only what it traces, needs it only where a refracted ray misses
					float sky_visibility = 1.0;
					vec3 irradiance = vec3(0.0);
					bool gi_known = !(refractive && refraction.amount >= 1.0 && traced_only);
					// a surface that transmits all of the light has no diffuse of its own, the light only reaches its reflection:
					// the opaque scene's light behind it and the sky stand in for the probes' (8 probes with a visibility
					// test per pixel and layer)
					bool use_probes = !(refractive && refraction.amount >= 1.0);

					if (gi_known) irradiance = get_gi_irradiance(screen_uv, world_pos, dot(geometric_N, V) < 0.0 ? -geometric_N : geometric_N, V, use_probes, sky_visibility);

					exit_gi_known = gi_known;
					exit_use_probes = true;
					exit_irradiance = irradiance;
					exit_sky_visibility = sky_visibility;
					exit_screen_uv = screen_uv;
					exit_world_pos = world_pos;
					exit_geometric_N = geometric_N;
					exit_V = V;
					exit_N = N;
					exit_perceptual_roughness = perceptual_roughness;
					vec3 raw_R = reflect(-V, N);
					vec3 reflection = vec3(0.0);

					if (!traced_only) {
						vec3 R = get_specular_dominant_direction(raw_R, N, perceptual_roughness);
						vec3 sky_reflection = sample_environment_specular(lighting_data.env_tex, raw_R, N, perceptual_roughness);
						reflection = blend_probe_reflections(mix(irradiance, sky_reflection, sky_visibility), R, perceptual_roughness, world_pos);
					}

					#ifdef SCENE_REFLECTION
					if (traced_weight > 0.0 && scene_reflection_ready()) {
						float traced_t;
						vec3 traced = trace_scene_reflection(world_pos + (dot(geometric_N, V) < 0.0 ? -geometric_N : geometric_N) * 0.02, raw_R, N, perceptual_roughness, SCENE_REFLECTION_MAX_DISTANCE, traced_t);
						reflection = mix(reflection, traced, traced_weight);
					}
					#endif
					vec2 env_brdf = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NdotV, perceptual_roughness)).rg;
					vec3 F_ambient = F_SchlickRoughness(F0, NdotV, perceptual_roughness);
					vec3 ambient_diffuse = (1.0 - F_ambient) * (1.0 - metallic) * irradiance * diffuse_albedo * get_ao(in_uv);
					vec3 ambient_specular = reflection * (F0 * env_brdf.x + F90(F0) * env_brdf.y) * GGXEnergyCompensation(F0, env_brdf);
					// what a refracting surface reflects and lets through. A thin wall is a pane, two surfaces with the light
					// bouncing between them (what it reflects is 2F / (1 + F), twice what one surface does), and what it
					// carries is the tint once. A solid has its front surface here and its far one where the ray leaves.
					// The split sum above is built on Schlick, so the exact reflectance scales it by the ratio of the two
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
						// source's decalmodulate: the scene behind is multiplied by twice the
						// texture, and source does that in gamma space, which in linear is
						// a factor of 2^2.2 times the linear albedo
						vec3 factor = 4.5948 * albedo * color_model.ColorMultiplier.rgb;
						set_color(vec4(0.0));
						set_motion(vec4(0.0));
						set_additive(vec4(0.0));
						set_modulate(vec4(mix(vec3(1.0), factor, transmittance * color_model.ColorMultiplier.a), 1.0));
						return;
					}

					if (Additive) {
						// source's $additive: the albedo is added to the scene, nothing
						// of it is taken away, and it lights nothing but its reflection
						// an unlit source material adds its color to the picture as it is
						// displayed, so it follows the exposure instead of glowing at a fixed
						// luminance. the pre exposed scene is the displayed one over the headroom
						vec3 emission = DisplayReferred ? get_albedo_uv(in_uv) * color_model.ColorMultiplier.a / ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : get_emissive(in_uv) * color_model.ColorMultiplier.a * get_pre_exposure();
						vec3 added = emission + (direct_specular + ambient_specular) * specular_coverage * get_pre_exposure();
						set_color(vec4(0.0));
						set_motion(vec4(0.0));
						set_additive(vec4(min(added * fog_transmittance, vec3(65504.0)), 0.0) * transmittance);
						return;
					}

					if (!refractive) {
						vec3 emissive = get_emissive(in_uv) * alpha;
						vec3 color = direct_diffuse + ambient_diffuse + (direct_specular + ambient_specular) * specular_coverage + emissive;
						// the fog in front of the surface covers what the surface covers
						color = color * fog_transmittance + fog_scattered * alpha;
						set_color(vec4(min(color * get_pre_exposure(), vec3(65504.0)), alpha) * transmittance);
						set_motion(vec4(motion, 1.0, 0.0) * alpha * transmittance);
						set_additive(vec4(0.0));
						return;
					}

					vec3 I = -V;
					vec3 facing_N = dot(geometric_N, V) < 0.0 ? -geometric_N : geometric_N;
					// a dispersive medium bends each wavelength by its own index, so red, green and
					// blue are followed separately and each takes its own channel of the background
					vec3 channel_ior = screen_refraction_dispersed_ior(refraction.ior, refraction.abbe);
					int channel_count = refraction.abbe > 0.0 ? 3 : 1;
					vec3 background = vec3(0.0);
					// the light that gets out through the far surface of a solid and how far it went inside
					float exit_transmitted = 0.0;
					float path_length = 0.0;
					float flat_exit = 0.0;

					for (int channel = 0; channel < channel_count; channel++) {
						float ior = channel_ior[channel];
						float eta = 1.0 / ior;
						vec3 T = refract(I, N, eta);
						vec3 exit_pos = world_pos;
						vec3 exit_dir;
						vec3 exit_outward = facing_N;

						if (refraction.thickness > 0.0) {
							// a solid. locally the surface is a sphere as curved as it is
							// here, or a slab with a parallel far side when it is flat;
							// the ray leaves through whichever it reaches first
							// no rounder than a sphere as wide as the object is thin
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

							// totally reflected inside; it leaves somewhere, roughly on
							if (dot(exit_dir, exit_dir) < 1e-6) {
								exit_dir = T;
								exit_transmitted += 1.0;
							} else {
								exit_transmitted += 1.0 - fresnel_dielectric(dot(T, exit_N), ior);
							}
						} else {
							// a thin wall leaves the ray parallel to how it came in, so
							// only the normal map's slopes bend it
							exit_dir = normalize(I + T - refract(I, facing_N, eta));
						}

						vec3 channel_background;

						if (lighting_data.refraction_tex < 0) {
							channel_background = get_exit_environment(exit_dir);
						} else if (refraction.thickness > 0.0) {
							// how far behind the surface the opaque scene is along the view
							// ray sets how far the refracted ray is followed. with only sky
							// behind, as far as the surface is from the camera, again
							float scene_depth = texture(TEXTURE(lighting_data.depth_tex), screen_uv).r;
							float surface_distance = distance(lighting_data.camera_position.xyz, exit_pos);
							float reach = 2.0 * surface_distance;

							if (scene_depth > 0.0) {
								vec3 scene_pos = get_scene_pos(screen_uv, scene_depth);
								reach = 3.0 * max(distance(lighting_data.camera_position.xyz, scene_pos) - surface_distance, 0.0) + 0.5;
							}

							channel_background = get_refracted_background(world_pos, exit_pos, exit_outward, exit_dir, reach, roughness);
						} else {
							vec2 slope = (lighting_data.view * vec4(N - facing_N, 0.0)).xy;
							vec2 uv = clamp(screen_uv + vec2(slope.x, -slope.y) * (ior - 1.0), vec2(0.0), vec2(1.0));
							float blur_pixels = roughness * lighting_data.render_size.y * 0.05;
							channel_background = textureLod(TEXTURE(lighting_data.refraction_tex), uv, log2(max(blur_pixels, 1.0))).rgb / get_pre_exposure();
						}

						if (channel_count == 1) {
							background = channel_background;
						} else {
							background[channel] = channel_background[channel];
						}
					}

					// the fraction of the background that comes through. the fogged
					// scene it is taken from already holds the fog in front of the
					// surface, so of that fog only what covers the rest is added,
					// and taa follows the background there
					vec3 transmission = pane_transmittance;
					vec3 reflectance = pane_reflectance;

					if (refraction.thickness > 0.0) {
						// through the glass: absorbed along the path (the tint is the color at the attenuation distance,
						// without one it is taken once), and out through the far surface
						float inside = path_length / float(channel_count);
						vec3 absorbed = refraction.attenuation > 0.0 ? pow(max(albedo, vec3(1e-3)), vec3(inside / refraction.attenuation)) : albedo;
						transmission = (1.0 - fresnel_front) * absorbed * (exit_transmitted / float(channel_count));
						reflectance = vec3(fresnel_front);

						// where the far side is flat it is parallel to the near one: a slab, which reflects and
						// transmits as a pane does, the light bouncing between the two surfaces
						float slab = flat_exit / float(channel_count);

						if (slab > 0.0) {
							vec3 bounces = 1.0 - fresnel_front * fresnel_front * absorbed * absorbed;
							vec3 slab_reflectance = fresnel_front + (1.0 - fresnel_front) * (1.0 - fresnel_front) * fresnel_front * absorbed * absorbed / bounces;
							vec3 slab_transmittance = (1.0 - fresnel_front) * (1.0 - fresnel_front) * absorbed / bounces;
							transmission = mix(transmission, slab_transmittance, slab);
							reflectance = mix(reflectance, slab_reflectance, slab);
						}
					}

					// the split sum is built on Schlick: the exact reflectance scales it by the ratio of the two
					float schlick_front = F0.x + (1.0 - F0.x) * pow(1.0 - NdotV, 5.0);
					vec3 reflectance_scale = reflectance / max(schlick_front, 1e-4);
					ambient_specular *= reflectance_scale;
					direct_specular *= reflectance_scale;
					transmission *= (1.0 - metallic) * refraction.amount;
					vec3 emissive = get_emissive(in_uv);
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
		color_blend = {attachments = {{}, translucent_moments.ADDITIVE, translucent_moments.ADDITIVE, translucent_moments.MULTIPLY}},
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

-- the two surface passes again for the rows of the scene store: the vertices come from the mesh buffers by address, the
-- material of a draw from a record of its batch, and what refracts brings its thickness along per instance
local multi_draw_block = {
	name = "translucent_draw",
	block = {
		{"batches", "uint64_t"},
		{"instances", "uint64_t"},
		{"prev_instances", "uint64_t"},
		{"thicknesses", "uint64_t"},
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
		camera_block_name = "translucent_camera",
		uniform_buffers = {camera_block, multi_draw_block},
		batches_expr = "translucent_draw.batches",
		instances_expr = "translucent_draw.instances",
		prev_instances_expr = "translucent_draw.prev_instances",
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
	fragment.custom_declarations = (source.fragment.custom_declarations or "") .. string.format("layout(location = %d) flat in uint in_batch;\n", pass.vertex.batch_location) .. model_pipeline.BuildPBRBatchRecordGlsl("PBRBatchData(translucent_draw.batches).b[in_batch]")

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
			table.insert(list, build_multi_draw_pass(pass, {camera_block, moments_uniform_buffers[#moments_uniform_buffers]}, false))
		elseif pass.name == "translucent_surface" then
			table.insert(list, build_multi_draw_pass(pass, {camera_block, surface_uniform_buffers[#surface_uniform_buffers - 1], surface_uniform_buffers[#surface_uniform_buffers]}, true))
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
