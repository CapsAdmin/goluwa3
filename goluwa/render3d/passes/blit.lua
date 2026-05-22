local render = import("goluwa/render/render.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MAX_CASCADES = 4

local function get_primary_sun(lights)
	lights = lights or render3d.GetLights()

	for _, light in ipairs(lights) do
		if light.LightType == "sun" then return light end
	end

	return nil
end

local function get_primary_sun_direction(lights)
	lights = lights or render3d.GetLights()
	local sun_dir = Vec3(0, 1, 0)
	local sun = get_primary_sun(lights)

	if sun then sun_dir = sun.Owner.transform:GetRotation():GetBackward() end

	return sun_dir
end

local function get_primary_sun_intensity(lights)
	lights = lights or render3d.GetLights()
	local sun = get_primary_sun(lights)

	if sun then return sun.Intensity end

	return atmosphere.GetSunIntensity()
end

local function write_scene_fog_shadow_block(self, shadow_block, lights)
	local sun = get_primary_sun(lights)

	for i = 0, MAX_CASCADES - 1 do
		shadow_block.shadow_map_indices[i] = -1
		shadow_block.cascade_splits[i] = -1
		shadow_block.cascade_texel_world_sizes[i] = 0
	end

	shadow_block.inset_shadow_map_index = -1
	shadow_block.inset_shadow_distance = 0
	shadow_block.inset_shadow_texel_world_size = 0
	shadow_block.cascade_count = 0

	for i = 0, 15 do
		shadow_block.inset_light_space_matrix[i] = 0
	end

	if not sun or not sun:GetCastShadows() then return end

	local shadow_map = sun:GetShadowMap()
	local cascade_count = shadow_map:GetCascadeCount()

	for i = 1, cascade_count do
		shadow_block.shadow_map_indices[i - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture(i))
		shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(shadow_block.light_space_matrices[i - 1])
		shadow_block.cascade_splits[i - 1] = shadow_map:GetCascadeSplits()[i] or -1
		shadow_block.cascade_texel_world_sizes[i - 1] = shadow_map:GetCascadeTexelWorldSize(i)
	end

	shadow_block.cascade_count = cascade_count

	if sun.InsetShadowMap then
		shadow_block.inset_shadow_map_index = self:GetTextureIndex(sun.InsetShadowMap:GetDepthTexture(1))
		sun.InsetShadowMap:GetLightSpaceMatrix(1):CopyToFloatPointer(shadow_block.inset_light_space_matrix)
		shadow_block.inset_shadow_distance = sun.InsetShadowMap:GetCascadeSplits()[1] or 0
		shadow_block.inset_shadow_texel_world_size = sun.InsetShadowMap:GetCascadeTexelWorldSize(1)
	end
end

local function get_raw_scene_source_texture(self, block, key)
	-- SMAA resolve can be re-enabled explicitly once the post-AA regression is fixed.
	if
		render3d.use_smaa_resolve and
		render3d.pipelines.smaa_resolve and
		render3d.pipelines.smaa_resolve.framebuffers
	then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.smaa_resolve:GetFramebuffer(current_idx):GetAttachment(1))
		return
	end

	if
		render3d.pipelines.ocean_resolve and
		render3d.pipelines.ocean_resolve.framebuffers
	then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.ocean_resolve:GetFramebuffer(current_idx):GetAttachment(1))
		return
	end

	if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(1))
		return
	end

	if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
		block[key] = -1
		return
	end

	local current_idx = system.GetFrameNumber() % 2 + 1
	block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
end

local function get_scene_source_texture(self, block, key)
	if self.name ~= "scene_fog" and render3d.pipelines.scene_fog then
		block[key] = self:GetTextureIndex(render3d.pipelines.scene_fog:GetFramebuffer():GetAttachment(1))
		return
	end

	get_raw_scene_source_texture(self, block, key)
end

local function get_blit_source_texture(self, block, key)
	get_scene_source_texture(self, block, key)
end

local function get_is_debug_view(_, block, key)
	block[key] = 0
end

local function write_extract_constants(self, block)
	get_scene_source_texture(self, block, "source_tex")
	return block
end

local function write_scene_fog_constants(self, block)
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	get_raw_scene_source_texture(self, block, "source_tex")

	if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block.ocean_distance_tex = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(2))
	else
		block.ocean_distance_tex = -1
	end

	block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
	get_primary_sun_direction():CopyToFloatPointer(block.primary_sun_direction)
	block.primary_sun_intensity = get_primary_sun_intensity()
	write_scene_fog_shadow_block(self, block.shadows, render3d.GetLights())
	return block
end

local function write_down_constants(self, block, pipeline_name)
	if not render3d.pipelines[pipeline_name] then
		block.source_tex = -1
		return block
	end

	block.source_tex = self:GetTextureIndex(render3d.pipelines[pipeline_name]:GetFramebuffer():GetAttachment(1))
	return block
end

local function write_up_constants(self, block, source_name, merge_name)
	if not render3d.pipelines[source_name] then
		block.source_tex = -1
	else
		block.source_tex = self:GetTextureIndex(render3d.pipelines[source_name]:GetFramebuffer():GetAttachment(1))
	end

	if not render3d.pipelines[merge_name] then
		block.merge_tex = -1
	else
		block.merge_tex = self:GetTextureIndex(render3d.pipelines[merge_name]:GetFramebuffer():GetAttachment(1))
	end

	return block
end

local function write_luminance_constants(self, block)
	get_scene_source_texture(self, block, "source_tex")

	if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
		block.prev_luma_tex = -1
		return block
	end

	local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
	block.prev_luma_tex = self:GetTextureIndex(render3d.pipelines.luminance:GetFramebuffer(prev_idx):GetAttachment(1))
	return block
end

local function write_blit_constants(self, block)
	get_blit_source_texture(self, block, "source_tex")
	get_is_debug_view(self, block, "is_debug_view")

	if not render3d.pipelines.bloom_up0 then
		block.bloom_tex = -1
	else
		block.bloom_tex = self:GetTextureIndex(render3d.pipelines.bloom_up0:GetFramebuffer():GetAttachment(1))
	end

	if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
		block.luma_tex = -1
	else
		local current_idx = system.GetFrameNumber() % 2 + 1
		block.luma_tex = self:GetTextureIndex(render3d.pipelines.luminance:GetFramebuffer(current_idx):GetAttachment(1))
	end

	block.requires_manual_gamma = render.target:RequiresManualGamma() and 1 or 0
	block.is_hdr = render.target:IsHDR() and 1 or 0
	return block
end

local r = {
	{
		name = "scene_fog",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "fog_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{
							"source_tex",
							"int",
							get_raw_scene_source_texture,
						},
						{
							"ocean_distance_tex",
							"int",
							function(self, block, key)
								if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
									local current_idx = system.GetFrameNumber() % 2 + 1
									block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(2))
								else
									block[key] = -1
								end
							end,
						},
						{
							"primary_sun_intensity",
							"float",
							function(self, block, key)
								block[key] = get_primary_sun_intensity()
							end,
						},
						{
							"primary_sun_direction",
							"vec4",
							function(self, block, key)
								get_primary_sun_direction():CopyToFloatPointer(block[key])
							end,
						},
						{
							"atmosphere_transmittance_texture_index",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
							end,
						},
						{
							"shadows",
							{
								{"light_space_matrices", "mat4", MAX_CASCADES},
								{"inset_light_space_matrix", "mat4"},
								{"cascade_splits", "float", MAX_CASCADES},
								{"cascade_texel_world_sizes", "float", MAX_CASCADES},
								{"inset_shadow_distance", "float"},
								{"inset_shadow_texel_world_size", "float"},
								{"shadow_map_indices", "int", MAX_CASCADES},
								{"inset_shadow_map_index", "int"},
								{"cascade_count", "int"},
							},
							function(self, block, key)
								write_scene_fog_shadow_block(self, block[key], render3d.GetLights())
							end,
						},
					},
					write = write_scene_fog_constants,
				},
			},
			shader = [[
			#define ATMOSPHERE_SUN_INTENSITY fog_data.primary_sun_intensity

			]] .. atmosphere.GetAerialPerspectiveGLSLCode() .. [[

			vec3 get_world_pos(float depth) {
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = fog_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				return (fog_data.inv_view * view_pos).xyz;
			}

			vec3 get_world_ray() {
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
				vec4 view_pos = fog_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (fog_data.inv_view * vec4(view_pos.xyz, 1.0)).xyz;
				return normalize(world_pos - fog_data.camera_position.xyz);
			}

			vec3 get_normal() {
				return texture(TEXTURE(fog_data.normal_tex), in_uv).xyz;
			}

			float getShadowReceiverPlaneBias(vec2 uv, float current_depth, vec2 texel_size, float filter_radius_texels) {
				vec2 uv_dx = dFdx(uv);
				vec2 uv_dy = dFdy(uv);
				float depth_dx = dFdx(current_depth);
				float depth_dy = dFdy(current_depth);
				float det = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;

				if (abs(det) < 1e-8) {
					return 0.0;
				}

				vec2 depth_grad_uv = vec2(
					(depth_dx * uv_dy.y - depth_dy * uv_dx.y) / det,
					(depth_dy * uv_dx.x - depth_dx * uv_dy.x) / det
				);
				return dot(abs(depth_grad_uv), texel_size * filter_radius_texels);
			}

			int getCascadeIndex(vec3 world_pos) {
				float dist = -(fog_data.view * vec4(world_pos, 1.0)).z;

				for (int i = 0; i < fog_data.shadows.cascade_count; i++) {
					if (dist < fog_data.shadows.cascade_splits[i]) {
						return i;
					}
				}

				return fog_data.shadows.cascade_count - 1;
			}

			bool projectFogShadowMap(
				mat4 light_space_matrix,
				vec3 world_pos,
				vec3 normal,
				vec3 light_dir,
				float texel_world_size,
				out vec3 proj_coords
			) {
				vec3 offset_pos = world_pos;

				if (dot(normal, normal) > 1e-6) {
					float normal_bias = max(texel_world_size * 1.5, 0.0005);
					float bias_val = normal_bias * max(1.0 - dot(normalize(normal), light_dir), 0.15);
					offset_pos += normalize(normal) * bias_val;
				}

				vec4 light_space_pos = light_space_matrix * vec4(offset_pos, 1.0);
				proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				return !(
					proj_coords.z > 1.0 ||
					proj_coords.z < 0.0 ||
					proj_coords.x < 0.0 ||
					proj_coords.x > 1.0 ||
					proj_coords.y < 0.0 ||
					proj_coords.y > 1.0
				);
			}

			float sampleFogShadowProjection(int shadow_map_idx, vec3 proj_coords, float filter_radius_texels) {
				vec2 shadow_size = vec2(textureSize(TEXTURE(shadow_map_idx), 0));
				vec2 texel_size = 1.0 / shadow_size;
				float current_depth = proj_coords.z;
				float receiver_bias = getShadowReceiverPlaneBias(proj_coords.xy, current_depth, texel_size, filter_radius_texels);
				receiver_bias = max(receiver_bias, 0.00002);
				float visibility = 0.0;
				const vec2 POISSON_DISK[12] = vec2[12](
					vec2(-0.326, -0.406),
					vec2(-0.840, -0.074),
					vec2(-0.696,  0.457),
					vec2(-0.203,  0.621),
					vec2( 0.962, -0.195),
					vec2( 0.473, -0.480),
					vec2( 0.519,  0.767),
					vec2( 0.185, -0.893),
					vec2( 0.507,  0.064),
					vec2( 0.896,  0.412),
					vec2(-0.322, -0.933),
					vec2(-0.792, -0.598)
				);

				for (int i = 0; i < 12; ++i) {
					vec2 offset = POISSON_DISK[i] * filter_radius_texels * texel_size;
					float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + offset).r;
					visibility += current_depth - receiver_bias > pcf_depth ? 0.0 : 1.0;
				}

				return visibility / 12.0;
			}

			float sampleFogShadowCascade(int cascade_idx, vec3 world_pos, vec3 normal, vec3 light_dir) {
				if (cascade_idx < 0 || cascade_idx >= fog_data.shadows.cascade_count) return 1.0;

				int shadow_map_idx = fog_data.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return 1.0;

				vec3 proj_coords;

				if (!projectFogShadowMap(
					fog_data.shadows.light_space_matrices[cascade_idx],
					world_pos,
					normal,
					light_dir,
					fog_data.shadows.cascade_texel_world_sizes[cascade_idx],
					proj_coords
				)) {
					return 1.0;
				}

				return sampleFogShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			bool sampleFogInsetShadow(vec3 world_pos, vec3 normal, vec3 light_dir, out float shadow) {
				shadow = 1.0;
				if (fog_data.shadows.inset_shadow_map_index < 0) return false;

				vec3 proj_coords;

				if (!projectFogShadowMap(
					fog_data.shadows.inset_light_space_matrix,
					world_pos,
					normal,
					light_dir,
					fog_data.shadows.inset_shadow_texel_world_size,
					proj_coords
				)) {
					return false;
				}

				shadow = sampleFogShadowProjection(fog_data.shadows.inset_shadow_map_index, proj_coords, 1.0);
				return true;
			}

			float get_fog_sun_visibility(vec3 world_pos, vec3 normal, vec3 sun_dir) {
				if (get_fog_sun_horizon_visibility(sun_dir) <= 0.0001) {
					return 0.0;
				}

				if (fog_data.shadows.cascade_count <= 0 || fog_data.shadows.shadow_map_indices[0] < 0) {
					return 1.0;
				}

				int cascade_idx = getCascadeIndex(world_pos);
				if (cascade_idx < 0) return 1.0;

				float dist = -(fog_data.view * vec4(world_pos, 1.0)).z;
				float shadow = sampleFogShadowCascade(cascade_idx, world_pos, normal, sun_dir);

				if (cascade_idx < fog_data.shadows.cascade_count - 1) {
					float previous_split = cascade_idx > 0 ? fog_data.shadows.cascade_splits[cascade_idx - 1] : 0.0;
					float current_split = fog_data.shadows.cascade_splits[cascade_idx];
					float cascade_span = max(current_split - previous_split, 0.0001);
					float blend_band = max(cascade_span * 0.15, 8.0);
					float blend_start = current_split - blend_band;

					if (dist > blend_start) {
						float next_shadow = sampleFogShadowCascade(cascade_idx + 1, world_pos, normal, sun_dir);
						float blend = clamp((dist - blend_start) / max(current_split - blend_start, 0.0001), 0.0, 1.0);
						shadow = mix(shadow, next_shadow, blend);
					}
				}

				if (fog_data.shadows.inset_shadow_map_index >= 0 && dist < fog_data.shadows.inset_shadow_distance) {
					float inset_shadow = 1.0;

					if (sampleFogInsetShadow(world_pos, normal, sun_dir, inset_shadow)) {
						float inset_band = max(fog_data.shadows.inset_shadow_distance * 0.25, 4.0);
						float inset_blend = 1.0 - smoothstep(
							max(fog_data.shadows.inset_shadow_distance - inset_band, 0.0),
							fog_data.shadows.inset_shadow_distance,
							dist
						);
						shadow = mix(shadow, inset_shadow, inset_blend);
					}
				}

				return shadow;
			}

			bool get_fog_world_segment(vec3 ray_dir, float max_world_distance, out float fog_near_world, out float fog_length_world) {
				vec3 fog_ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_near;
				float fog_length;
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float max_fog_distance = max_world_distance > 0.0 ? max_world_distance * fog_distance_scale : -1.0;

				if (!get_scenery_fog_segment(fog_ray_origin, ray_dir, max_fog_distance, fog_near, fog_length)) {
					return false;
				}

				fog_near_world = fog_near / fog_distance_scale;
				fog_length_world = fog_length / fog_distance_scale;
				return true;
			}

			float get_fog_ray_sun_visibility(vec3 ray_dir, float max_world_distance, vec3 sun_dir) {
				if (get_fog_sun_horizon_visibility(sun_dir) <= 0.0001) {
					return 0.0;
				}

				float fog_near_world;
				float fog_length_world;
				if (!get_fog_world_segment(ray_dir, max_world_distance, fog_near_world, fog_length_world)) {
					return 1.0;
				}

				const int FOG_VISIBILITY_STEPS = 8;
				float step_size = fog_length_world / float(FOG_VISIBILITY_STEPS);
				float weighted_distance = 0.0;
				float total_weight = 0.0;
				vec3 fog_ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;

				for (int i = 0; i < FOG_VISIBILITY_STEPS; i++) {
					float sample_u = (float(i) + 0.5) / float(FOG_VISIBILITY_STEPS);
					float world_t = fog_near_world + (float(i) + 0.5) * step_size;
					vec3 fog_sample = fog_ray_origin + ray_dir * (world_t * fog_distance_scale);
					float front_bias = mix(1.0, 0.35, sample_u);
					float weight = max(scenery_fog_density(fog_sample) * front_bias, 1e-4);
					weighted_distance += world_t * weight;
					total_weight += weight;
				}

				float representative_world_t = total_weight > 0.0
					? weighted_distance / total_weight
					: fog_near_world + fog_length_world * 0.35;
				vec3 representative_world_pos = fog_data.camera_position.xyz + ray_dir * representative_world_t;
				return get_fog_sun_visibility(representative_world_pos, vec3(0.0), sun_dir);
			}

			float get_fog_geometry_sun_visibility(vec3 ray_dir, vec3 world_pos, float max_world_distance, vec3 sun_dir) {
				if (get_fog_sun_horizon_visibility(sun_dir) <= 0.0001) {
					return 0.0;
				}

				return get_fog_sun_visibility(world_pos, get_normal(), sun_dir);
			}

			void main() {
				if (fog_data.source_tex == -1) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				vec4 scene = texture(TEXTURE(fog_data.source_tex), in_uv);
				float depth = texture(TEXTURE(fog_data.depth_tex), in_uv).r;
				float ocean_distance = -1.0;
				vec3 ray_dir = get_world_ray();

				if (fog_data.ocean_distance_tex != -1) {
					ocean_distance = texture(TEXTURE(fog_data.ocean_distance_tex), in_uv).r;
				}

				bool is_sky = depth == 1.0 && ocean_distance <= 0.0;

				vec3 world_pos = ocean_distance > 0.0
					? fog_data.camera_position.xyz + ray_dir * ocean_distance
					: get_world_pos(depth);
				vec3 sun_dir = fog_data.primary_sun_direction.xyz;

				if (length(sun_dir) < 0.0001) {
					sun_dir = vec3(0.0, 1.0, 0.0);
				} else {
					sun_dir = normalize(sun_dir);
				}

				vec3 color = scene.rgb;
				float max_world_distance = ocean_distance > 0.0
					? ocean_distance
					: length(world_pos - fog_data.camera_position.xyz);

				if (is_sky) {
					float sun_visibility = get_fog_ray_sun_visibility(ray_dir, -1.0, sun_dir);

					color = apply_scenery_fog_ray(
						scene.rgb,
						ray_dir,
						sun_dir,
						fog_data.camera_position.xyz,
						-1.0,
						sun_visibility
					);
				} else {
					float sun_visibility = get_fog_geometry_sun_visibility(ray_dir, world_pos, max_world_distance, sun_dir);

					color = apply_scenery_fog(
						scene.rgb,
						world_pos,
						sun_dir,
						fog_data.camera_position.xyz,
						sun_visibility
					);
				}

				set_color(vec4(color, scene.a));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	-- Pass 1: Extract bright areas for bloom
	{
		name = "bloom_extract",
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = 0.5,
		fragment = {
			push_constants = {
				{
					name = "extract",
					block = {
						{"source_tex", "int", get_scene_source_texture},
					},
					write = write_extract_constants,
				},
			},
			shader = [[
				void main() {
					if (extract.source_tex == -1) {
						set_bloom(vec4(0.0));
						return;
					}
					
					vec3 col = texture(TEXTURE(extract.source_tex), in_uv).rgb;
					
					// Use scene luminance so bloom stays attached to genuinely bright highlights.
					float threshold = 1.25;
					float knee = 0.75;
					float brightness = dot(col, vec3(0.2126, 0.7152, 0.0722));
					float soft = brightness - threshold + knee;
					soft = clamp(soft, 0.0, 2.0 * knee);
					soft = soft * soft / (4.0 * knee + 0.00001);
					float contribution = max(soft, brightness - threshold);
					contribution /= max(brightness, 0.00001);
					
					set_bloom(vec4(col * contribution, 1.0));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
-- Generate downsample passes
local downsample_shader = [[
	void main() {
		if (down.source_tex == -1) {
			set_bloom(vec4(0.0));
			return;
		}
		
		vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(down.source_tex), 0));
		vec3 sum = vec3(0.0);
		
		// 13-tap downsampling filter
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(-2, -2) * texel_size).rgb;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(0, -2) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(2, -2) * texel_size).rgb;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(-2, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv).rgb * 4.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(2, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(-2, 2) * texel_size).rgb;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(0, 2) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(2, 2) * texel_size).rgb;
		
		set_bloom(vec4(sum / 16.0, 1.0));
	}
]]

for i = 1, 3 do
	local prev_name = i == 1 and "bloom_extract" or ("bloom_down" .. (i - 1))
	table.insert(
		r,
		{
			name = "bloom_down" .. i,
			ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
			scale = 0.5 / (2 ^ i),
			fragment = {
				push_constants = {
					{
						name = "down",
						block = {
							{
								"source_tex",
								"int",
								function(self, block, key)
									if not render3d.pipelines[prev_name] then
										block[key] = -1
										return
									end

									block[key] = self:GetTextureIndex(render3d.pipelines[prev_name]:GetFramebuffer():GetAttachment(1))
								end,
							},
						},
						write = function(self, block)
							return write_down_constants(self, block, prev_name)
						end,
					},
				},
				shader = downsample_shader,
			},
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
		}
	)
end

-- Generate upsample passes
local upsample_merge_strength = 0.65
local upsample_shader = string.format(
	[[
	void main() {
		if (up.source_tex == -1) {
			set_bloom(vec4(0.0));
			return;
		}
		
		vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(up.source_tex), 0));
		vec3 sum = vec3(0.0);
		
		// 9-tap tent filter
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(-1, -1) * texel_size).rgb;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(0, -1) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(1, -1) * texel_size).rgb;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(-1, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv).rgb * 4.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(1, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(-1, 1) * texel_size).rgb;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(0, 1) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(1, 1) * texel_size).rgb;
		
		vec3 result = sum / 16.0;
		
		// Merge with previous level
		if (up.merge_tex != -1) {
			result += texture(TEXTURE(up.merge_tex), in_uv).rgb * %.3f;
		}
		
		set_bloom(vec4(result, 1.0));
	}
]],
	upsample_merge_strength
)

for i = 3, 1, -1 do
	local source_name = i == 3 and "bloom_down3" or ("bloom_up" .. (i + 1))
	local merge_name = i == 1 and "bloom_extract" or ("bloom_down" .. i)
	local idx = i == 1 and 0 or i
	table.insert(
		r,
		{
			name = "bloom_up" .. idx,
			ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
			scale = 0.5 / (2 ^ i),
			fragment = {
				push_constants = {
					{
						name = "up",
						block = {
							{
								"source_tex",
								"int",
								function(self, block, key)
									if not render3d.pipelines[source_name] then
										block[key] = -1
										return
									end

									block[key] = self:GetTextureIndex(render3d.pipelines[source_name]:GetFramebuffer():GetAttachment(1))
								end,
							},
							{
								"merge_tex",
								"int",
								function(self, block, key)
									if not render3d.pipelines[merge_name] then
										block[key] = -1
										return
									end

									block[key] = self:GetTextureIndex(render3d.pipelines[merge_name]:GetFramebuffer():GetAttachment(1))
								end,
							},
						},
						write = function(self, block)
							return write_up_constants(self, block, source_name, merge_name)
						end,
					},
				},
				shader = upsample_shader,
			},
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
		}
	)
end

-- Luminance pass for adaptive tonemapping
table.insert(
	r,
	{
		name = "luminance",
		ColorFormat = {{"r16_sfloat", {"luma", "r"}}},
		scale = 0.0625, -- 1/16th resolution for fast averaging
		framebuffer_count = 2,
		fragment = {
			push_constants = {
				{
					name = "lum",
					block = {
						{"source_tex", "int", get_scene_source_texture},
						{
							"prev_luma_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
									block[key] = -1
									return
								end

								local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.luminance:GetFramebuffer(prev_idx):GetAttachment(1))
							end,
						},
					},
					write = write_luminance_constants,
				},
			},
			shader = [[
			void main() {
				float luma;
				if (lum.source_tex == -1) {
					luma = 0.5;
					set_luma(luma);
					return;
				}
				
				vec3 col = texture(TEXTURE(lum.source_tex), in_uv).rgb;
				
				// Calculate luminance
				float current_luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
				current_luma = log2(max(current_luma, 0.0001));
				
				// Temporal smoothing
				if (lum.prev_luma_tex != -1) {
					float prev_luma = texture(TEXTURE(lum.prev_luma_tex), in_uv).r;
					// Smooth adaptation speed
					float adapt_speed = 0.001;
					current_luma = mix(prev_luma, current_luma, adapt_speed);
				}
				
				set_luma(current_luma);
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
)
-- Final blit pass
table.insert(
	r,
	{
		name = "blit",
		RasterizationSamples = function()
			return render.target.samples
		end,
		fragment = {
			push_constants = {
				{
					name = "blit",
					block = {
						{"source_tex", "int", get_blit_source_texture},
						{"is_debug_view", "int", get_is_debug_view},
						{
							"bloom_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.bloom_up0 then
									block[key] = -1
									return
								end

								block[key] = self:GetTextureIndex(render3d.pipelines.bloom_up0:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"luma_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.luminance:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"requires_manual_gamma",
							"int",
							function(self, block, key)
								block[key] = render.target:RequiresManualGamma() and 1 or 0
							end,
						},
						{
							"is_hdr",
							"int",
							function(self, block, key)
								block[key] = render.target:IsHDR() and 1 or 0
							end,
						},
					},
					write = write_blit_constants,
				},
			},
			shader = [[
				layout(location = 0) out vec4 frag_color;

				vec3 ACESFilm(vec3 x) {
					vec3 res = x;

					res = res/10;
					res = pow(res, vec3(0.5));
					res *= 2.2;
					
					res *= vec3(1.09,  1.025,  1);

					res.r = pow(res.r, 0.97);
					res.b = pow(res.b, 1.05);
					res = pow(res, vec3(1.1));

					res *= mat3(
						1.0,   0.0,   0.0,    
						0.0,   1.0,   0.0,    
						0.0,   0.0, 1.0     
					);

					return clamp(res, 0.0, 1.0);
				}

				vec3 ACESFilmHDR(vec3 x) {
					return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
				}

				vec3 jodieReinhardTonemap(vec3 c){
					float l = dot(c, vec3(0.7152, 0.7152, 0.7152));
					vec3 tc = c / (c + 1.0);
					vec3 c2 = mix(c / (l + 1.0), tc, tc);
					c2 = pow(c2*1.5, vec3(1.5));
					return c2;
				}

				vec3 LinearToSRGB(vec3 col) {
					vec3 low = col * 12.92;
					vec3 high = 1.055 * pow(col, vec3(1.0/2.4)) - 0.055;
					return mix(low, high, step(0.0031308, col));
				}

				vec3 tonemap(vec3 x, float exposure) {
					x *= exposure;
					
					const float a = 2.51;
					const float b = 0.03;
					const float c = 2.43;
					const float d = 0.59;
					const float e = 0.14;
					vec3 col = (x * (a * x + b)) / (x * (c * x + d) + e);

					col = pow(col*0.75, vec3(1.5))*1.25;

					return col;
				}


				vec3 tonemap_lottes(vec3 rgb) {
					const vec3 a = vec3(1.5); // Contrast
					const vec3 d = vec3(0.91); // Shoulder contrast
					const vec3 hdr_max = vec3(8.0); // White point
					const vec3 mid_in = vec3(0.26); // Fixed midpoint x
					const vec3 mid_out = vec3(0.32); // Fixed midput y

					const vec3 b = (-pow(mid_in, a) + pow(hdr_max, a) * mid_out) /
						((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
					const vec3 c = (pow(hdr_max, a * d) * pow(mid_in, a) -
									pow(hdr_max, a) * pow(mid_in, a * d) * mid_out) /
						((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);

					return pow(rgb, a) / (pow(rgb, a * d) * b + c);
				}

				void main() {
					if (blit.source_tex == -1) {
						frag_color = vec4(1.0, 0.0, 1.0, 1.0);
						return;
					}
					
					vec3 col = texture(TEXTURE(blit.source_tex), in_uv).rgb;
					if (blit.is_debug_view == 1) {
						col = clamp(col, vec3(0.0), vec3(1.0));

						if (blit.requires_manual_gamma == 1) {
							col = LinearToSRGB(col);
						}

						frag_color = vec4(col, 1.0);
						return;
					}

					vec3 bloom = vec3(0.0);
					if (blit.bloom_tex != -1) {
						bloom = texture(TEXTURE(blit.bloom_tex), in_uv).rgb;
					}
					
					// Calculate adaptive exposure
					float exposure = 1.0;
					if (blit.luma_tex != -1) {
						// Average luminance across entire screen
						float avg_log_luma = 0.0;
						vec2 luma_size = vec2(textureSize(TEXTURE(blit.luma_tex), 0));
						int samples = 0;
						
						// Sample at multiple points to get average
						for (float y = 0.125; y < 1.0; y += 0.25) {
							for (float x = 0.125; x < 1.0; x += 0.25) {
								avg_log_luma += texture(TEXTURE(blit.luma_tex), vec2(x, y)).r;
								samples++;
							}
						}
						avg_log_luma /= float(samples);
						
						// Convert back from log space and calculate exposure
						float avg_luma = exp2(avg_log_luma);
						float target_luma = 0.5; // Middle gray target
						exposure = target_luma / max(avg_luma, 0.001);
						
						// Clamp exposure to reasonable range
						exposure = clamp(exposure, 0.1, 4.0);
					}

					float bloom_luma = dot(bloom, vec3(0.2126, 0.7152, 0.0722));
					float bloom_strength = 0.03;
					float bloom_exposure_scale = clamp(1.0 / sqrt(max(exposure, 0.35)), 0.7, 1.25);
					float bloom_soft_clip = 1.0 / (1.0 + bloom_luma * 0.35);
					col += bloom * bloom_strength * bloom_exposure_scale * bloom_soft_clip;

					if (blit.is_hdr == 1) {
						col = tonemap(pow(col*1.5, vec3(0.8)), exposure)*1.2;
					} else {
						col = tonemap_lottes(col * exposure);
					}
					
					if (blit.requires_manual_gamma == 1) {
						col = LinearToSRGB(col);
					}

					vec2 vignette_uv = in_uv * 2.0 - 1.0;
					float aspect = float(textureSize(TEXTURE(blit.source_tex), 0).x) / float(textureSize(TEXTURE(blit.source_tex), 0).y);
					vignette_uv.x *= aspect;
					float vignette = smoothstep(4.0, 0.6, length(vignette_uv));
					col *= vignette;
					
					frag_color = vec4(col, 1.0);
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
)

if HOTRELOAD then
	import("goluwa/timer.lua").Delay(0, function()
		render3d.Initialize()
	end)
end

return r
