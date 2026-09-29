local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local froxel_fog = import("goluwa/render3d/froxel_fog.lua")
local clouds = import("goluwa/render3d/clouds.lua")
--[[
	clouds_noise: bakes the base and detail noise volumes and the weather map
	once.

	clouds_shadow: the clouds' optical depth along the primary light over
	clouds.SHADOW_EXTENT around the camera, as a beer shadow map (the depth
	where the clouds start, their mean extinction and their optical depth).

	clouds_sky: the clouds with the air in front of them all around the
	camera at a low resolution, for the sky the environment probes capture and
	the fog's ambient.

	clouds_trace and clouds_reconstruct: the main view at half resolution.
	Each frame traces one pixel of every 2x2 block, the rest are reprojected
	from the last frame by the depth of the clouds they saw.
]]
local BINDING_OUT = 0
local BINDING_OUT2 = 1
local BINDING_OUT3 = 2
local BINDING_DATA = 3
local BINDING_BASE_NOISE = 4
local BINDING_DETAIL_NOISE = 5
-- how far the clouds are followed along the view
local VIEW_DISTANCE = 300000
-- the share of a traced pixel that goes into its history, the rest averages the step jitter away
local TRACE_BLEND = 0.5

local function dummy_color_format()
	return {{"r8_unorm", {"clouds_dummy", "r"}}}
end

local function is_active()
	return clouds.IsActive()
end

local noise_samplers = {
	{
		binding_index = BINDING_BASE_NOISE,
		get_descriptor = function()
			local t = clouds.EnsureResources()
			return {t.base_noise:GetView(), t.base_noise_sampler}
		end,
	},
	{
		binding_index = BINDING_DETAIL_NOISE,
		get_descriptor = function()
			local t = clouds.EnsureResources()
			return {t.detail_noise:GetView(), t.detail_noise_sampler}
		end,
	},
}
local NOISE_DECLARATIONS = [[
	layout(set = 0, binding = ]] .. BINDING_BASE_NOISE .. [[) uniform sampler3D cloud_base_noise;
	layout(set = 0, binding = ]] .. BINDING_DETAIL_NOISE .. [[) uniform sampler3D cloud_detail_noise;
]]
local SUN_ILLUMINANCE_EXPR = string.format("%.17g", atmosphere.GetSunIlluminance())

local function cloud_block(extra)
	local block = {
		render3d.camera_block,
		atmosphere.GetBlockLayout(),
		clouds.GetBlockLayout(),
	}

	for _, field in ipairs(extra or {}) do
		block[#block + 1] = field
	end

	return block
end

local function write_cloud_block(self, block)
	render3d.WriteCameraBlock(self, block)
	atmosphere.WriteBlock(
		self,
		block,
		render3d.GetCamera():GetPosition(),
		directional_shadows.GetPrimarySunDirection(render3d.GetLights())
	)
	-- the dome is written by one of these passes, and they light the clouds with the clear sky
	block.atmosphere_cloud_sky_texture_index = -1
	clouds.WriteBlock(self, block)
end

local function cloud_glsl()
	return atmosphere.GetGLSLDefines("cloud_data", SUN_ILLUMINANCE_EXPR) .. atmosphere.GetAerialPerspectiveGLSLCode() .. clouds.GetGLSL("cloud_data") .. [[
		// interleaved gradient noise, a different pattern each frame
		float cloud_ign(vec2 pixel, int frame) {
			pixel += 5.588238 * float(frame % 64);
			return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
		}
	]]
end

local noise_pass = {
	name = "clouds_noise",
	ComputePass = true,
	ColorFormat = dummy_color_format(),
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 4, y = 4, z = 4},
	is_enabled = function()
		return is_active() and not clouds.EnsureResources().noise_ready
	end,
	storage_images = {
		{
			binding_index = BINDING_OUT,
			dst_stage = "compute",
			get_texture = function()
				return clouds.EnsureResources().base_noise_storage
			end,
		},
		{
			binding_index = BINDING_OUT2,
			dst_stage = "compute",
			get_texture = function()
				return clouds.EnsureResources().detail_noise_storage
			end,
		},
		{
			binding_index = BINDING_OUT3,
			dst_stage = "compute",
			get_texture = function()
				return clouds.EnsureResources().weather
			end,
		},
	},
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		local size = clouds.BASE_NOISE_SIZE
		self.pipeline:DispatchForSize(cmd, size, size, size, desc, self.dynamic_offsets)
		clouds.textures.noise_ready = true
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUT .. [[, rgba8) uniform writeonly image3D out_base;
		layout(set = 0, binding = ]] .. BINDING_OUT2 .. [[, rgba8) uniform writeonly image3D out_detail;
		layout(set = 0, binding = ]] .. BINDING_OUT3 .. [[, rgba8) uniform writeonly image2D out_weather;
	]],
	shader = clouds.NOISE_GLSL .. [[
		const int BASE_SIZE = ]] .. clouds.BASE_NOISE_SIZE .. [[;
		const int DETAIL_SIZE = ]] .. clouds.DETAIL_NOISE_SIZE .. [[;
		const int WEATHER_SIZE = ]] .. clouds.WEATHER_SIZE .. [[;

		// the fbms stretched from where most of their values lie to 0-1
		float worley_channel(vec3 p, int freq, uint seed) {
			return cloud_saturate((cloud_worley_fbm(p, ivec3(freq), seed) - 0.32) / 0.32);
		}

		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);

			if (any(greaterThanEqual(id, ivec3(BASE_SIZE)))) return;

			{
				vec3 p = (vec3(id) + 0.5) / float(BASE_SIZE);
				// perlin-worley: billowy perlin whose low parts are cut into round cells
				float perlin = cloud_saturate(0.5 + 0.8 * cloud_perlin_fbm(p, ivec3(4), 6, 0u));
				float worley = cloud_worley_fbm(p, ivec3(4), 10u);
				float perlin_worley = cloud_saturate(cloud_remap(perlin, worley - 1.0, 1.0, 0.0, 1.0));
				imageStore(out_base, id, vec4(
					cloud_saturate((perlin_worley - 0.54) / 0.26),
					worley_channel(p, 8, 20u),
					worley_channel(p, 16, 30u),
					worley_channel(p, 32, 40u)
				));
			}

			if (all(lessThan(id, ivec3(DETAIL_SIZE)))) {
				vec3 p = (vec3(id) + 0.5) / float(DETAIL_SIZE);
				imageStore(out_detail, id, vec4(
					worley_channel(p, 2, 50u),
					worley_channel(p, 4, 60u),
					worley_channel(p, 8, 70u),
					1.0
				));
			}

			// the weather map's pixels spread over the first slices
			int tiles = WEATHER_SIZE / BASE_SIZE;

			if (id.z < tiles * tiles) {
				ivec2 pixel = id.xy + ivec2(id.z % tiles, id.z / tiles) * BASE_SIZE;
				vec3 p = vec3((vec2(pixel) + 0.5) / float(WEATHER_SIZE), 0.0);
				// where clouds gather: broad patches of more and less, clumped into cells
				float patches = cloud_saturate(0.5 + 0.9 * cloud_perlin_fbm(p, ivec3(3, 3, 1), 5, 80u));
				float cells = cloud_worley_fbm(p, ivec3(6, 6, 1), 90u);
				float coverage = cloud_saturate(mix(patches, cells, 0.35) * 1.15 - 0.075);
				// how tall the heaps grow
				float height = cloud_saturate(0.5 + 0.9 * cloud_perlin_fbm(p, ivec3(5, 5, 1), 3, 100u));
				// cirrus: fibres stretched along x, bent by a slow warp, in patches
				vec3 warp = vec3(
					cloud_perlin_fbm(p, ivec3(3, 3, 1), 3, 110u),
					cloud_perlin_fbm(p, ivec3(3, 3, 1), 3, 120u),
					0.0
				) * 0.06;
				float fibres = cloud_saturate(0.5 + 1.1 * cloud_perlin_fbm(p + warp, ivec3(3, 28, 1), 4, 130u));
				float veil = cloud_saturate(0.5 + 1.0 * cloud_perlin_fbm(p, ivec3(4, 4, 1), 3, 140u));
				// where the base sits within the layer's base_variation, drifting over a few kilometers
				float base = cloud_saturate(0.5 + 1.1 * cloud_perlin_fbm(p, ivec3(8, 8, 1), 3, 150u));
				imageStore(out_weather, pixel, vec4(coverage, height, fibres * mix(0.4, 1.0, veil), base));
			}
		}
	]],
}
local shadow_pass = {
	name = "clouds_shadow",
	ComputePass = true,
	ColorFormat = dummy_color_format(),
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	is_enabled = is_active,
	storage_images = {
		{
			binding_index = BINDING_OUT,
			dst_stage = "fragment",
			get_texture = function()
				return clouds.EnsureResources().shadow
			end,
		},
	},
	sampled_images = noise_samplers,
	uniform_buffers = {
		{
			name = "cloud_data",
			binding_index = BINDING_DATA,
			block = cloud_block{
				{"shadow_right", "vec4"},
				{"shadow_up", "vec4"},
				{"shadow_dir", "vec4"},
				{"shadow_center", "vec4"},
			},
			write = function(self, block)
				write_cloud_block(self, block)
				local frame = clouds.UpdateShadowFrame(render3d.GetCamera():GetPosition())
				frame.right:CopyToFloatPointer(block.shadow_right)
				block.shadow_right[3] = clouds.SHADOW_EXTENT
				frame.up:CopyToFloatPointer(block.shadow_up)
				frame.dir:CopyToFloatPointer(block.shadow_dir)
				block.shadow_dir[3] = frame.distance
				frame.center:CopyToFloatPointer(block.shadow_center)
				return block
			end,
		},
	},
	on_pre_draw = function(self, cmd)
		clouds.GenerateNoiseMips(cmd)
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, clouds.SHADOW_SIZE, clouds.SHADOW_SIZE, 1, desc, self.dynamic_offsets)
		clouds.textures.shadow_ready = true
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUT .. [[, rgba16f) uniform writeonly image2D out_shadow;
	]] .. NOISE_DECLARATIONS,
	shader = cloud_glsl() .. [[
		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);
			ivec2 size = imageSize(out_shadow);

			if (any(greaterThanEqual(id, size))) return;

			vec2 uv = (vec2(id) + 0.5) / vec2(size) - 0.5;
			vec3 dir = cloud_data.shadow_dir.xyz;
			float distance = cloud_data.shadow_dir.w;
			vec3 origin = cloud_data.shadow_center.xyz + (cloud_data.shadow_right.xyz * uv.x + cloud_data.shadow_up.xyz * uv.y) * cloud_data.shadow_right.w + dir * distance;
			float front;
			float back;
			float od = cloud_march_optical_depth(origin, -dir, distance * 1.5, 0.5, front, back);

			if (od <= 0.0) {
				imageStore(out_shadow, id, vec4(0.0));
				return;
			}

			imageStore(out_shadow, id, vec4(front * 0.001, od / max(back - front, 1.0), od, 0.0));
		}
	]],
}
local sky_pass = {
	name = "clouds_sky",
	ComputePass = true,
	ColorFormat = dummy_color_format(),
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	is_enabled = is_active,
	storage_images = {
		{
			binding_index = BINDING_OUT,
			dst_stage = "fragment",
			get_texture = function()
				return clouds.EnsureResources().sky
			end,
		},
	},
	sampled_images = noise_samplers,
	uniform_buffers = {
		{
			name = "cloud_data",
			binding_index = BINDING_DATA,
			block = cloud_block(),
			write = function(self, block)
				write_cloud_block(self, block)
				return block
			end,
		},
	},
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, clouds.SKY_WIDTH, clouds.SKY_HEIGHT, 1, desc, self.dynamic_offsets)
		clouds.textures.sky_ready = true
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUT .. [[, rgba16f) uniform writeonly image2D out_sky;
	]] .. NOISE_DECLARATIONS,
	shader = cloud_glsl() .. [[
		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);
			ivec2 size = imageSize(out_sky);

			if (any(greaterThanEqual(id, size))) return;

			// get_cloud_sky_uv inverted
			vec2 uv = (vec2(id) + 0.5) / vec2(size);
			float azimuth = (uv.x - 0.5) * 2.0 * PI;
			float s = (uv.y - 0.5) * 2.0;
			float elevation = sign(s) * s * s * 0.5 * PI;
			vec3 dir = vec3(cos(azimuth) * cos(elevation), sin(elevation), sin(azimuth) * cos(elevation));
			vec3 origin = cloud_data.camera_position.xyz;
			float depth;
			vec4 c = cloud_march(origin, dir, ]] .. string.format("%.1f", VIEW_DISTANCE) .. [[, cloud_ign(vec2(id), cloud_data.cloud_frame), 0.5, depth);

			if (c.a >= 1.0) {
				imageStore(out_sky, id, vec4(0.0, 0.0, 0.0, 1.0));
				return;
			}

			// the air in front of the clouds
			vec3 air_transmittance;
			vec3 air = integrate_scattering(get_atmosphere_camera_origin(origin), dir, 0.0, depth * 0.001, ATMOSPHERE_SKY_SUN_DIRECTION, 8, vec2(1.0), 1.0, air_transmittance);
			imageStore(out_sky, id, vec4(((1.0 - c.a) * air + air_transmittance * c.rgb) * CLOUD_RADIANCE_SCALE, c.a));
		}
	]],
}
local trace_pass = {
	name = "clouds_trace",
	ComputePass = true,
	ColorFormat = dummy_color_format(),
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	is_enabled = is_active,
	storage_images = {
		{
			binding_index = BINDING_OUT,
			dst_stage = "compute",
			get_texture = function()
				return clouds.EnsureViewResources(render.GetRenderImageSize()).trace
			end,
		},
		{
			binding_index = BINDING_OUT2,
			dst_stage = "compute",
			get_texture = function()
				return clouds.EnsureViewResources(render.GetRenderImageSize()).trace_depth
			end,
		},
	},
	sampled_images = noise_samplers,
	uniform_buffers = {
		{
			name = "cloud_data",
			binding_index = BINDING_DATA,
			block = cloud_block{
				gbuffer_layout.block,
				{"view_size", "vec2"},
				{"trace_offset", "ivec2"},
			},
			write = function(self, block)
				write_cloud_block(self, block)
				gbuffer_layout.WriteBlock(self, block)
				local t = clouds.textures
				block.view_size[0] = t.view_width
				block.view_size[1] = t.view_height
				-- which pixel of each 2x2 block this frame traces
				local k = (clouds.frame or 0) % 4
				block.trace_offset[0] = (k == 1 or k == 2) and 1 or 0
				block.trace_offset[1] = (k == 1 or k == 3) and 1 or 0
				return block
			end,
		},
	},
	on_pre_draw = function()
		clouds.frame = (clouds.frame or 0) + 1
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		local t = clouds.textures
		self.pipeline:DispatchForSize(cmd, t.trace_width, t.trace_height, 1, desc, self.dynamic_offsets)
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUT .. [[, rgba16f) uniform writeonly image2D out_trace;
		layout(set = 0, binding = ]] .. BINDING_OUT2 .. [[, r32f) uniform writeonly image2D out_depth;
	]] .. NOISE_DECLARATIONS,
	shader = cloud_glsl() .. froxel_fog.GetViewDirGLSL("cloud_data") .. [[
		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);

			if (any(greaterThanEqual(id, imageSize(out_trace)))) return;

			ivec2 pixel = min(id * 2 + cloud_data.trace_offset, ivec2(cloud_data.view_size) - 1);
			vec2 uv = (vec2(pixel) + 0.5) / cloud_data.view_size;
			vec3 view_dir = get_view_dir(uv);
			vec3 dir = normalize(mat3(cloud_data.inv_view) * view_dir);
			// the farthest surface of the pixels this one covers, clouds in front of the nearer ones are
			// dropped when they are composited
			vec2 full_size = vec2(textureSize(TEXTURE(cloud_data.depth_tex), 0));
			float depth = 0.0;

			for (int i = 0; i < 4; i++) {
				vec2 full_uv = (vec2(pixel * 2 + ivec2(i & 1, i >> 1)) + 0.5) / (cloud_data.view_size * 2.0);
				depth = max(depth, textureLod(TEXTURE(cloud_data.depth_tex), min(full_uv, 1.0 - 0.5 / full_size), 0.0).r);
			}

			float t_max = ]] .. string.format("%.1f", VIEW_DISTANCE) .. [[;

			if (depth < 1.0) {
				vec4 surface = cloud_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
				t_max = -surface.z / surface.w * length(view_dir);
			}

			float cloud_depth;
			vec4 c = cloud_march(cloud_data.camera_position.xyz, dir, t_max, cloud_ign(vec2(id), cloud_data.cloud_frame), 1.0, cloud_depth);
			imageStore(out_trace, id, vec4(c.rgb * CLOUD_RADIANCE_SCALE, c.a));
			imageStore(out_depth, id, vec4(cloud_depth));
		}
	]],
}
local reconstruct_pass = {
	name = "clouds_reconstruct",
	ComputePass = true,
	ColorFormat = dummy_color_format(),
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	is_enabled = is_active,
	storage_images = {
		{
			binding_index = BINDING_OUT,
			dst_stage = "fragment",
			get_texture = function()
				local t = clouds.textures
				return t["view" .. t.view_current]
			end,
		},
		{
			binding_index = BINDING_OUT2,
			dst_stage = "fragment",
			get_texture = function()
				local t = clouds.textures
				return t["view_depth" .. t.view_current]
			end,
		},
	},
	uniform_buffers = {
		{
			name = "reconstruct_data",
			binding_index = BINDING_DATA,
			block = {
				render3d.camera_block,
				render3d.prev_camera_block,
				{"view_size", "vec2"},
				{"trace_offset", "ivec2"},
				{"trace_tex", "int"},
				{"trace_depth_tex", "int"},
				{"history_tex", "int"},
				{"history_depth_tex", "int"},
				{"history_valid", "int"},
				{"trace_blend", "float"},
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				render3d.WritePreviousCameraBlock(self, block)
				local t = clouds.textures
				block.view_size[0] = t.view_width
				block.view_size[1] = t.view_height
				local k = (clouds.frame or 0) % 4
				block.trace_offset[0] = (k == 1 or k == 2) and 1 or 0
				block.trace_offset[1] = (k == 1 or k == 3) and 1 or 0
				block.trace_tex = self:GetTextureIndex(t.trace)
				block.trace_depth_tex = self:GetTextureIndex(t.trace_depth)
				local previous = 3 - t.view_current
				block.history_valid = t.view_valid and 1 or 0
				block.history_tex = t.view_valid and self:GetTextureIndex(t["view" .. previous]) or -1
				block.history_depth_tex = t.view_valid and self:GetTextureIndex(t["view_depth" .. previous]) or -1
				block.trace_blend = TRACE_BLEND
				return block
			end,
		},
	},
	on_pre_draw = function()
		local t = clouds.textures
		t.view_current = 3 - t.view_current
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		local t = clouds.textures
		self.pipeline:DispatchForSize(cmd, t.view_width, t.view_height, 1, desc, self.dynamic_offsets)
		t.view_valid = true
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUT .. [[, rgba16f) uniform writeonly image2D out_view;
		layout(set = 0, binding = ]] .. BINDING_OUT2 .. [[, r32f) uniform writeonly image2D out_depth;
	]],
	shader = froxel_fog.GetViewDirGLSL("reconstruct_data") .. [[
		void main() {
			ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
			ivec2 size = ivec2(reconstruct_data.view_size);

			if (any(greaterThanEqual(pixel, size))) return;

			ivec2 trace_size = textureSize(TEXTURE(reconstruct_data.trace_tex), 0);
			ivec2 trace_id = min(pixel / 2, trace_size - 1);
			bool traced = all(equal(pixel & 1, reconstruct_data.trace_offset));
			vec2 uv = (vec2(pixel) + 0.5) / reconstruct_data.view_size;
			// this frame's samples around the pixel, which the history is clamped to
			vec4 low = vec4(1e30);
			vec4 high = vec4(-1e30);

			for (int i = 0; i < 9; i++) {
				vec4 v = texelFetch(TEXTURE(reconstruct_data.trace_tex), clamp(trace_id + ivec2(i % 3, i / 3) - 1, ivec2(0), trace_size - 1), 0);
				low = min(low, v);
				high = max(high, v);
			}

			vec4 current = traced ? texelFetch(TEXTURE(reconstruct_data.trace_tex), trace_id, 0) : textureLod(TEXTURE(reconstruct_data.trace_tex), uv, 0.0);
			float current_depth = traced ? texelFetch(TEXTURE(reconstruct_data.trace_depth_tex), trace_id, 0).r : textureLod(TEXTURE(reconstruct_data.trace_depth_tex), uv, 0.0).r;
			vec4 result = current;
			float result_depth = current_depth;

			if (reconstruct_data.history_valid != 0) {
				// where what the pixel sees was last frame
				vec3 view_dir = get_view_dir(uv);
				vec3 world = reconstruct_data.camera_position.xyz + normalize(mat3(reconstruct_data.inv_view) * view_dir) * current_depth;
				vec4 clip = reconstruct_data.prev_projection * reconstruct_data.prev_view * vec4(world, 1.0);
				vec2 previous = clip.xy / clip.w * 0.5 + 0.5;

				if (clip.w > 0.0 && all(greaterThanEqual(previous, vec2(0.0))) && all(lessThanEqual(previous, vec2(1.0)))) {
					vec4 history = textureLod(TEXTURE(reconstruct_data.history_tex), previous, 0.0);
					float history_depth = textureLod(TEXTURE(reconstruct_data.history_depth_tex), previous, 0.0).r;

					if (traced) {
						result = mix(clamp(history, low, high), current, reconstruct_data.trace_blend);
					} else {
						// the pixels traced in the last frames, unless the clouds moved away from them
						result = clamp(history, low - 0.05 * (high - low), high + 0.05 * (high - low));
						result_depth = history_depth;
					}
				}
			}

			imageStore(out_view, pixel, result);
			imageStore(out_depth, pixel, vec4(result_depth));
		}
	]],
}
return {noise_pass, shadow_pass, sky_pass, trace_pass, reconstruct_pass}
