local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local froxel_fog = import("goluwa/render3d/froxel_fog.lua")
local Texture = import("goluwa/render/texture.lua")
local BINDING_CAMERA = 3
local BINDING_LIGHT_GRID = 20
local BINDING_OCCLUSION_MAP = 21
-- Translucent materials, which the gbuffer can't hold, drawn forward and lit
-- like the gbuffer's surfaces, in any order: moment based order independent
-- transparency (Münstermann et al. 2018).
-- The moments pass sums, per pixel, each surface's absorbance and its
-- absorbance weighted powers of its depth. From those the accumulate pass
-- estimates how much of each surface is seen through the ones in front of it,
-- and sums the lit surfaces weighted by it. The composite lays that sum over
-- the lit opaque scene, which stays untouched for the passes that want what is
-- behind the translucent surfaces. Both geometry passes are depth tested
-- against a copy of the opaque depth.
-- Refractive materials see the opaque scene through a mip chain of it, which
-- rough surfaces sample blurrier. It is only built on frames that draw one.
-- The opaque scene is fogged before this, so each surface fogs itself at its
-- own depth, and sums how it moves for taa.
local refraction_source = nil
-- depth is warped logarithmically into -1..1 over the distances the
-- translucent surfaces span this frame, which the moments resolve best
local MOMENTS_GLSL = [[
	float moments_warp_depth(float distance, vec2 warp) {
		return clamp(log(max(distance, 1e-4)) * warp.x + warp.y, -1.0, 1.0);
	}

	// the transmittance of everything in front of depth. b0 is the summed
	// absorbance, moments its weighted depth, depth², depth³ and depth⁴. a
	// surface counts a quarter of itself as in front of it, so the summed
	// weights never vanish
	float moments_transmittance(float b0, vec4 moments, float depth) {
		if (b0 < 0.00100050033) return 1.0;

		vec4 b = mix(moments / b0, vec4(0.0, 0.375, 0.0, 0.375), 5e-7);
		float L21D11 = fma(-b.x, b.y, b.z);
		float D11 = fma(-b.x, b.x, b.y);
		float inv_D11 = 1.0 / D11;
		float L21 = L21D11 * inv_D11;
		float D22 = fma(-L21D11, L21, fma(-b.y, b.y, b.w));
		vec3 c = vec3(1.0, depth, depth * depth);
		c.y -= b.x;
		c.z -= b.y + L21 * c.y;
		c.y *= inv_D11;
		c.z /= D22;
		c.y -= L21 * c.z;
		c.x -= dot(c.yz, b.xy);
		float p = c.y / c.z;
		float q = c.x / c.z;
		float r = sqrt(p * p * 0.25 - q);
		vec3 z = vec3(depth, -p * 0.5 - r, -p * 0.5 + r);
		vec3 f = vec3(0.25, z.y < z.x ? 1.0 : 0.0, z.z < z.x ? 1.0 : 0.0);
		float f01 = (f.y - f.x) / (z.y - z.x);
		float f12 = (f.z - f.y) / (z.z - z.y);
		float f012 = (f12 - f01) / (z.z - z.x);
		float p0 = f01 - f012 * z.y;
		float p1 = p0 - f012 * z.x;
		p0 = f.x - p0 * z.x;
		return clamp(exp(-b0 * (p0 + b.x * p1 + b.y * f012)), 0.0, 1.0);
	}
]]

local function write_depth_warp(warp)
	local camera = render3d.GetCamera()
	local near = math.clamp(render3d.translucent_depth_near, camera:GetNearZ(), camera:GetFarZ())
	local far = math.max(math.min(render3d.translucent_depth_far, camera:GetFarZ()), near * 1.01)
	local scale = 2 / (math.log(far) - math.log(near))
	warp[0] = scale
	warp[1] = -math.log(near) * scale - 1
end

local function get_moments_textures()
	local fb = render3d.pipelines.translucent_moments:GetFramebuffer()
	return fb:GetAttachment(1), fb:GetAttachment(2)
end

-- a geometry pass starts with a fullscreen draw that zeroes its targets and
-- copies the opaque depth to test against
local function create_depth_copy_fragment(shader)
	return {
		uniform_buffers = {
			{
				name = "depth_copy",
				binding_index = 3,
				block = {
					{"depth_tex", "int"},
				},
				write = function(self, block)
					block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
					return block
				end,
			},
		},
		shader = [[
			void main() {
				]] .. shader .. [[
				gl_FragDepth = texelFetch(TEXTURE(depth_copy.depth_tex), ivec2(gl_FragCoord.xy), 0).r;
			}
		]],
	}
end

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
			{"depth_tex", "int"},
			{"refraction_tex", "int"},
			{"b0_tex", "int"},
			{"moments_tex", "int"},
			{"depth_warp", "vec2"},
			{"fog", "int"},
		},
		write = function(self, block)
			surface_lighting.WriteBlock(self, block)
			block.fog = render3d.pipelines.volumetric_fog and 1 or 0
			block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
			local b0, moments = get_moments_textures()
			block.b0_tex = self:GetTextureIndex(b0)
			block.moments_tex = self:GetTextureIndex(moments)
			write_depth_warp(block.depth_warp)
			block.refraction_tex = render3d.refraction_source_requested and
				self:GetTextureIndex(refraction_source) or
				-1
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
			write_depth_warp(block.depth_warp)
			return block
		end,
		upload_scope = "frame",
	}
)
local ADDITIVE = {
	blend = true,
	src_color_blend_factor = "one",
	dst_color_blend_factor = "one",
	color_blend_op = "add",
	src_alpha_blend_factor = "one",
	dst_alpha_blend_factor = "one",
	alpha_blend_op = "add",
}
return {
	{
		name = "translucent_moments",
		ColorFormat = {
			{"r32_sfloat", {"b0", "r"}},
			{"r32g32b32a32_sfloat", {"moments", "rgba"}},
		},
		DepthFormat = "d32_sfloat",
		-- the light grid and the occlusion map live as long as the engine, so
		-- each of the surface pipeline's descriptor sets is written once, before
		-- any frame uses it
		on_pre_draw = function(self, cmd)
			local surface = render3d.pipelines.translucent_surface
			-- the set Bind will pick
			local frame = render.GetCurrentFrame()

			if not surface.pipeline.descriptor_sets[frame] then frame = 1 end

			surface.surface_lighting_sets = surface.surface_lighting_sets or {}

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

			-- what draws this frame, how far away it is, and whether any of it
			-- refracts
			render3d.refraction_source_requested = false
			render3d.translucent_depth_near = math.huge
			render3d.translucent_depth_far = 0
			event.Call("PreDraw3DTranslucent")

			if render3d.refraction_source_requested then
				update_refraction_source(cmd)
			end
		end,
		-- with nothing translucent in view, the cleared targets composite to the
		-- scene as it is
		on_draw = function(self, cmd)
			if render3d.translucent_depth_far == 0 then return end

			self:UploadConstants()
			cmd:Draw(3, 1, 0, 0)
			render3d.translucent_pipeline = render3d.pipelines.translucent_moments_surface
			event.Call("Draw3DTranslucent")
		end,
		fragment = create_depth_copy_fragment("set_b0(0.0); set_moments(vec4(0.0));"),
		CullMode = "none",
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "always",
	},
	{
		name = "translucent_moments_surface",
		draw_in_prerender = false,
		dont_create_framebuffers = true,
		ColorFormat = {
			{"r32_sfloat", {"b0", "r"}},
			{"r32g32b32a32_sfloat", {"moments", "rgba"}},
		},
		DepthFormat = "d32_sfloat",
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			include_projection_view_world = false,
			camera_uniform_block_name = "translucent_camera",
			uniform_buffers = {camera_block},
		},
		fragment = {
			uniform_buffers = moments_uniform_buffers,
			shader = model_pipeline.BuildPBRSurfaceGlsl() .. MOMENTS_GLSL .. [[
				void main() {
					float alpha = get_alpha();

					if (AlphaTest && alpha < factor_model.AlphaCutoff) discard;

					float absorbance = -log(max(1.0 - alpha, 1e-3));
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
		color_blend = {attachments = {{}, ADDITIVE}},
		DepthTest = true,
		DepthWrite = false,
		DepthCompareOp = "less_or_equal",
	},
	{
		name = "translucent_accumulate",
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16b16a16_sfloat", {"motion", "rgba"}},
		},
		DepthFormat = "d32_sfloat",
		on_draw = function(self, cmd)
			if render3d.translucent_depth_far == 0 then return end

			self:UploadConstants()
			cmd:Draw(3, 1, 0, 0)
			render3d.translucent_pipeline = render3d.pipelines.translucent_surface
			event.Call("Draw3DTranslucent")
		end,
		fragment = create_depth_copy_fragment("set_color(vec4(0.0)); set_motion(vec4(0.0));"),
		CullMode = "none",
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "always",
	},
	{
		name = "translucent_surface",
		draw_in_prerender = false,
		dont_create_framebuffers = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16b16a16_sfloat", {"motion", "rgba"}},
		},
		DepthFormat = "d32_sfloat",
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			velocity = true,
			include_projection_view_world = false,
			camera_uniform_block_name = "translucent_camera",
			uniform_buffers = {camera_block},
		},
		fragment = {
			push_constants = {
				{
					name = "refraction",
					block = {
						{"amount", "float"},
						{"ior", "float"},
						{"thickness", "float"},
					},
					write = function(self, block)
						local material = render3d.GetMaterial()
						block.amount = material:GetRefraction()
						block.ior = material:GetIndexOfRefraction()
						block.thickness = render3d.translucent_thickness
						return block
					end,
				},
			},
			uniform_buffers = surface_uniform_buffers,
			descriptor_sets = {
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
			},
			custom_declarations = surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. [[
				layout(set = 2, binding = 0) uniform sampler3D froxel_volume;
			]],
			shader = model_pipeline.BuildPBRSurfaceGlsl() .. surface_lighting.GetGLSL("lighting_data") .. screen_refraction.GetGLSL("lighting_data") .. MOMENTS_GLSL .. froxel_fog.SLICE_GLSL .. froxel_fog.GetViewDirGLSL("lighting_data") .. [[
				float get_fog_sun_visibility(vec3 world_pos, vec3 sun_dir) {
					return calculateShadow(world_pos, sun_dir, sun_dir);
				}
			]] .. froxel_fog.GetGLSL("lighting_data", "get_fog_sun_visibility", "get_primary_sun_direction()") .. [[
				// the gbuffer's screen space gi, of the opaque surface behind
				// this one. a thin surface sits in about the same light
				vec3 get_gi_irradiance(vec2 screen_uv, vec3 N, out float sky_visibility) {
					bool behind_is_sky = texture(TEXTURE(lighting_data.depth_tex), screen_uv).r >= 1.0;

					if (lighting_data.gi_screen_tex < 0 || behind_is_sky) {
						sky_visibility = 1.0;
						return sample_environment_irradiance(lighting_data.env_irradiance_tex, N);
					}

					vec4 gi = texture(TEXTURE(lighting_data.gi_screen_tex), screen_uv);
					sky_visibility = gi.a;
					return gi.rgb;
				}

				// how far the surface moved on screen since last frame
				vec2 get_screen_motion(vec3 world_pos, vec3 prev_world_pos) {
					vec4 clip = translucent_camera.projection * translucent_camera.view * vec4(world_pos, 1.0);
					vec4 prev_clip = translucent_camera.prev_projection * translucent_camera.prev_view * vec4(prev_world_pos, 1.0);

					if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) return vec2(0.0);

					return (clip.xy / clip.w - prev_clip.xy / prev_clip.w) * 0.5;
				}

				vec3 get_scene_pos(vec2 uv, float depth) {
					vec4 view_pos = lighting_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
					return (lighting_data.inv_view * vec4(view_pos.xyz / view_pos.w, 1.0)).xyz;
				}

				// the radiance behind the surface arriving along dir: the scene
				// where the ray meets it, blurred by how far roughness has spread
				// it by then, or the environment when it leaves the screen.
				// reach is how far to look, a few times how far behind the
				// surface the scene is along the view ray
				vec3 get_refracted_background(vec3 surface_pos, vec3 exit_pos, vec3 dir, float reach, float roughness, vec3 environment_fallback) {
					vec2 uv;
					float travel;

					// interleaved gradient noise, moving each frame
					vec2 noise_pos = gl_FragCoord.xy + 5.588238 * floor(lighting_data.time * 60.0);
					float jitter = fract(52.9829189 * fract(dot(noise_pos, vec2(0.06711056, 0.00583715))));

					if (lighting_data.refraction_tex < 0 || !screen_refraction_trace(surface_pos, exit_pos, dir, reach, jitter, uv, travel)) {
						return environment_fallback;
					}

					vec3 target = exit_pos + dir * travel;
					float view_depth = max(-(lighting_data.view * vec4(target, 1.0)).z, 1e-3);
					float blur_pixels = roughness * travel * abs(lighting_data.projection[1][1]) * 0.5 * lighting_data.render_size.y / view_depth;

					if (blur_pixels <= 2.0) {
						return textureLod(TEXTURE(lighting_data.refraction_tex), uv, log2(max(blur_pixels, 1.0))).rgb;
					}

					// four taps a level finer than the blur, so the box filtered
					// mips don't show as blocks
					vec2 spread = vec2(blur_pixels * 0.5) / lighting_data.render_size;
					float lod = log2(blur_pixels * 0.5);
					return (
						textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(-0.5, -0.5), lod).rgb +
						textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(0.5, -0.5), lod).rgb +
						textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(-0.5, 0.5), lod).rgb +
						textureLod(TEXTURE(lighting_data.refraction_tex), uv + spread * vec2(0.5, 0.5), lod).rgb
					) * 0.25;
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
					vec4 fog = lighting_data.fog != 0 ? get_volumetric_fog(screen_uv, distance(world_pos, lighting_data.camera_position.xyz)) : vec4(0.0, 0.0, 0.0, 1.0);
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
					float roughness = get_roughness(in_uv);
					float perceptual_roughness = sqrt(roughness);
					float subsurface = get_subsurface(in_uv);
					bool refractive = refraction.amount > 0.0;
					// a refracting surface reflects what its index of refraction
					// says, and scatters diffusely only what it doesn't transmit
					float ior_f0 = (refraction.ior - 1.0) / (refraction.ior + 1.0);
					vec3 F0 = mix(vec3(refractive ? ior_f0 * ior_f0 : get_specular() * 0.08), albedo, metallic);
					float NdotV = max(dot(N, V), 0.001);
					// alpha is how much of the pixel the surface covers. a surface
					// that doesn't refract uses it as its opacity, scaling what it
					// scatters itself: its diffuse and emission. reflection comes off
					// the covered and the clear parts alike, but not off texels that
					// hold no surface at all
					vec3 diffuse_albedo = albedo * (refractive ? 1.0 - refraction.amount : alpha);
					float specular_coverage = refractive ? 1.0 : smoothstep(0.0, 0.1, alpha);

					vec3 direct_specular;
					vec3 direct_diffuse = get_direct_light(F0, NdotV, diffuse_albedo, roughness, perceptual_roughness, metallic, subsurface, get_transmission_blocking(in_uv), get_transmission_color(), get_transmission_view_dependency(), world_pos, V, N, geometric_N, direct_specular);

					float sky_visibility;
					vec3 irradiance = get_gi_irradiance(screen_uv, N, sky_visibility);
					vec3 raw_R = reflect(-V, N);
					vec3 R = get_specular_dominant_direction(raw_R, N, perceptual_roughness);
					vec3 sky_reflection = sample_environment_specular(lighting_data.env_tex, raw_R, N, perceptual_roughness);
					vec3 reflection = blend_probe_reflections(mix(irradiance, sky_reflection, sky_visibility), R, perceptual_roughness, world_pos);
					vec2 env_brdf = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NdotV, perceptual_roughness)).rg;
					vec3 F_ambient = F_SchlickRoughness(F0, NdotV, perceptual_roughness);
					vec3 ambient_diffuse = (1.0 - F_ambient) * (1.0 - metallic) * irradiance * diffuse_albedo * get_ao(in_uv);
					vec3 ambient_specular = reflection * (F0 * env_brdf.x + env_brdf.y) * GGXEnergyCompensation(F0, env_brdf);

					if (!refractive) {
						vec3 emissive = Subsurface ? vec3(0.0) : get_emissive(in_uv) * alpha;
						vec3 color = direct_diffuse + ambient_diffuse + (direct_specular + ambient_specular) * specular_coverage + emissive;
						// the fog in front of the surface covers what the surface covers
						color = color * fog.a + fog.rgb * alpha;
						set_color(vec4(min(color, vec3(65504.0)), alpha) * transmittance);
						set_motion(vec4(motion, 1.0, 0.0) * alpha * transmittance);
						return;
					}

					vec3 I = -V;
					float eta = 1.0 / refraction.ior;
					vec3 T = refract(I, N, eta);
					vec3 exit_pos = world_pos;
					vec3 exit_dir;

					vec3 facing_N = dot(geometric_N, V) < 0.0 ? -geometric_N : geometric_N;

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
						exit_dir = refract(T, -exit_N, refraction.ior);

						// totally reflected inside; it leaves somewhere, roughly on
						if (dot(exit_dir, exit_dir) < 1e-6) exit_dir = T;
					} else {
						// a thin wall leaves the ray parallel to how it came in, so
						// only the normal map's slopes bend it
						exit_dir = normalize(I + T - refract(I, facing_N, eta));
					}

					// how far behind the surface the opaque scene is along the view
					// ray sets how far the refracted ray is followed. with only sky
					// behind, as far as the surface is from the camera, again
					float scene_depth = texture(TEXTURE(lighting_data.depth_tex), screen_uv).r;
					float surface_distance = distance(lighting_data.camera_position.xyz, exit_pos);
					float reach = 2.0 * surface_distance;

					if (scene_depth < 1.0) {
						vec3 scene_pos = get_scene_pos(screen_uv, scene_depth);
						reach = 3.0 * max(distance(lighting_data.camera_position.xyz, scene_pos) - surface_distance, 0.0) + 0.5;
					}

					vec3 environment = blend_probe_reflections(
						mix(irradiance, sample_environment_specular(lighting_data.env_tex, exit_dir, N, perceptual_roughness), sky_visibility),
						exit_dir,
						perceptual_roughness,
						world_pos
					);
					vec3 background = get_refracted_background(world_pos, exit_pos, exit_dir, reach, roughness, environment);
					// the fraction of the background that comes through. the fogged
					// scene it is taken from already holds the fog in front of the
					// surface, so of that fog only what covers the rest is added,
					// and taa follows the background there
					vec3 transmission = albedo * (1.0 - F_ambient) * (1.0 - metallic) * refraction.amount;
					vec3 emissive = Subsurface ? vec3(0.0) : get_emissive(in_uv);
					vec3 color = (direct_diffuse + ambient_diffuse + direct_specular + ambient_specular + emissive) * fog.a + fog.rgb * (1.0 - transmission) + background * transmission;
					set_color(vec4(min(color * alpha, vec3(65504.0)), alpha) * transmittance);
					set_motion(vec4(motion, 1.0, 0.0) * alpha * transmittance * (1.0 - dot(transmission, vec3(1.0 / 3.0))));
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
		color_blend = {attachments = {{}, ADDITIVE}},
		DepthTest = true,
		DepthWrite = false,
		DepthCompareOp = "less_or_equal",
	},
	-- what the surfaces leave of the scene behind them, and the surfaces in
	-- the proportions they are seen in
	{
		name = "translucent",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "translucent_composite",
					binding_index = 3,
					block = {
						{"scene_tex", "int"},
						{"b0_tex", "int"},
						{"accumulated_tex", "int"},
					},
					write = function(self, block)
						block.scene_tex = self:GetTextureIndex(post_source.GetFoggedOpaqueSceneTexture())
						block.b0_tex = self:GetTextureIndex(get_moments_textures())
						block.accumulated_tex = self:GetTextureIndex(render3d.pipelines.translucent_accumulate:GetFramebuffer():GetAttachment(1))
						return block
					end,
				},
			},
			shader = [[
				void main() {
					ivec2 pixel = ivec2(gl_FragCoord.xy);
					vec4 scene = texelFetch(TEXTURE(translucent_composite.scene_tex), pixel, 0);
					vec4 accumulated = texelFetch(TEXTURE(translucent_composite.accumulated_tex), pixel, 0);

					if (accumulated.a <= 0.0) {
						set_color(scene);
						return;
					}

					float transmittance = exp(-texelFetch(TEXTURE(translucent_composite.b0_tex), pixel, 0).r);
					set_color(vec4(scene.rgb * transmittance + accumulated.rgb * ((1.0 - transmittance) / accumulated.a), scene.a));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
