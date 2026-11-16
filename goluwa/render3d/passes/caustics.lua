local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local scene_hits = import("goluwa/render3d/scene_hits.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local caustics = import("goluwa/render3d/caustics.lua")

if not optical_rays.RAY_QUERY then return {} end

local LOCAL_SIZE = {x = 8, y = 8, z = 1}
local PHOTON_LOCAL_SIZE = {x = 64, y = 1, z = 1}
local PHOTON_ROW = 65536
local BINDING_OUTPUT = 0
local BINDING_RAW = 2
local BINDING_UNIFORM = 3
local BINDING_OCCLUSION_MAP = 4
local BINDING_LIGHT_GRID = 5
local SCENE_BINDINGS = {scene = 6, hit = 30, materials = 8}

local function attachment(name, framebuffer, index)
	return render3d.pipelines[name]:GetFramebuffer(framebuffer):GetAttachment(index)
end

local function raw_buffer(cmd)
	local size = render3d.GetRenderSize()
	return caustics.GetBuffer("screen", cmd, size.x, size.y)
end

local function bind_raw(self, cmd, frame, desc)
	local buffer = raw_buffer(cmd)
	self:UpdateDescriptorSet("storage_buffer", desc, BINDING_RAW, 0, buffer, buffer:GetSize())
end

local function dispatch_after_raw(self, cmd, fb, frame, desc)
	caustics.Barrier(cmd, "screen")
	self:UploadConstants()
	self.pipeline:DispatchForSize(cmd, fb.width, fb.height, 1, desc, self.dynamic_offsets)
end

local function is_enabled()
	return render3d.IsPassEnabled("lighting") and caustics.HasCasters()
end

local function filter_pass(name, vertical)
	return {
		name = name,
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = vertical and
			{{"r16g16b16a16_sfloat", {name, "rgba"}}} or
			{
				{"r16g16b16a16_sfloat", {name .. "_narrow", "rgba"}},
				{"r16g16b16a16_sfloat", {name .. "_wide", "rgba"}},
			},
		framebuffer_count = 1,
		LocalSize = LOCAL_SIZE,
		storage_images = vertical and
			{{binding_index = BINDING_OUTPUT, attachment = 1, dst_stage = "compute"}} or
			{
				{binding_index = BINDING_OUTPUT, attachment = 1, dst_stage = "compute"},
				{binding_index = BINDING_OUTPUT + 1, attachment = 2, dst_stage = "compute"},
			},
		storage_buffers = {{binding_index = BINDING_RAW}},
		on_pre_draw = bind_raw,
		on_draw = dispatch_after_raw,
		uniform_buffers = {
			{
				name = "filter_data",
				binding_index = BINDING_UNIFORM,
				block = {
					gbuffer_layout.block,
					render3d.camera_block,
					{"narrow_tex", "int"},
					{"wide_tex", "int"},
					{"radius", "int"},
					{"photons", "float"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					block.narrow_tex = vertical and self:GetTextureIndex(attachment("caustics_filter_h", 1, 1)) or -1
					block.wide_tex = vertical and self:GetTextureIndex(attachment("caustics_filter_h", 1, 2)) or -1
					block.radius = caustics.filter_radius:Get()
					block.photons = caustics.filter_photons:Get()
					return block
				end,
			},
		},
		custom_declarations = (
				vertical and
				[[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_caustics;
		]] or
				[[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_narrow;
			layout(set = 0, binding = ]] .. (
					BINDING_OUTPUT + 1
				) .. [[, rgba16f) uniform writeonly image2D out_wide;
		]]
			) .. caustics.GetBufferDeclarationGLSL(BINDING_RAW),
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("filter_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("filter_data") .. [[
			#define VERTICAL ]] .. (
				vertical and
				"1" or
				"0"
			) .. [[

			#define FIXED_POINT ]] .. string.format("%.1f", caustics.FIXED_POINT) .. [[

			#define NARROW_SIGMA 1.0

			void main() {
				ivec2 pos = get_screen_pos();
				#if VERTICAL
				ivec2 size = imageSize(out_caustics);
				#else
				ivec2 size = imageSize(out_narrow);
				#endif

				if (!is_screen_pos_in_bounds(pos, size)) return;

				float depth = gbuffer_depth(pos);
				vec4 narrow = vec4(0.0);
				vec4 wide = vec4(0.0);
				float narrow_total = 0.0;
				float wide_total = 0.0;

				if (depth > 0.0) {
					vec3 P = get_world_pos((vec2(pos) + 0.5) / vec2(size), depth);
					vec3 N = gbuffer_normal(pos);
					float plane_tolerance = 0.01 * filter_data.view_scale + 0.005 * distance(P, filter_data.camera_position.xyz);
					int radius = max(filter_data.radius, 2);
					float wide_sigma = float(radius) * 0.5;

					for (int i = -radius; i <= radius; i++) {
						ivec2 q = pos + (VERTICAL != 0 ? ivec2(0, i) : ivec2(i, 0));

						if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) continue;

						float w = 1.0;

						if (i != 0) {
							float q_depth = gbuffer_depth(q);

							if (q_depth <= 0.0) continue;

							vec3 Q = get_world_pos((vec2(q) + 0.5) / vec2(size), q_depth);
							w = exp(-abs(dot(N, Q - P)) / plane_tolerance) * pow(max(dot(N, gbuffer_normal(q)), 0.0), 8.0);
						}

						float x = float(i * i);
						float w_narrow = w * exp(-0.5 * x / (NARROW_SIGMA * NARROW_SIGMA));
						float w_wide = w * exp(-0.5 * x / (wide_sigma * wide_sigma));
						#if VERTICAL
						vec4 q_narrow = texelFetch(TEXTURE(filter_data.narrow_tex), q, 0);
						vec4 q_wide = texelFetch(TEXTURE(filter_data.wide_tex), q, 0);
						#else
						uint index = uint(q.y * size.x + q.x) * 4u;
						vec4 q_narrow = vec4(vec3(caustic_raw[index], caustic_raw[index + 1u], caustic_raw[index + 2u]) / FIXED_POINT, float(caustic_raw[index + 3u]));
						vec4 q_wide = q_narrow;
						#endif
						narrow += vec4(q_narrow.rgb, q_narrow.a) * w_narrow;
						wide += vec4(q_wide.rgb, q_wide.a) * w_wide;
						narrow_total += w_narrow;
						wide_total += w_wide;
					}
				}

				narrow.rgb = narrow_total > 0.0 ? narrow.rgb / narrow_total : vec3(0.0);
				wide.rgb = wide_total > 0.0 ? wide.rgb / wide_total : vec3(0.0);
				#if VERTICAL
				uint index = uint(pos.y * size.x + pos.x) * 4u;
				caustic_raw[index] = 0u;
				caustic_raw[index + 1u] = 0u;
				caustic_raw[index + 2u] = 0u;
				caustic_raw[index + 3u] = 0u;
				imageStore(out_caustics, pos, vec4(mix(wide.rgb, narrow.rgb, smoothstep(0.25 * filter_data.photons, filter_data.photons, narrow.a)), wide.a));
				#else
				imageStore(out_narrow, pos, narrow);
				imageStore(out_wide, pos, wide);
				#endif
			}
		]],
	}
end

return {
	{
		name = "caustics_photons",
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = {{"r8_unorm", {"caustics_photons_dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = PHOTON_LOCAL_SIZE,
		storage_buffers = {{binding_index = BINDING_LIGHT_GRID}, {binding_index = BINDING_RAW}},
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		on_pre_draw = function(self, cmd, frame, desc)
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
			bind_raw(self, cmd, frame, desc)

			if caustics.world:Get() then caustics.GetWorldGrid(cmd) end
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			caustics.Barrier(cmd, "screen")

			if caustics.world:Get() then caustics.Barrier(cmd, "world") end

			self:UploadConstants()

			if self.photon_count > 0 then
				self.pipeline:DispatchForSize(
					cmd,
					PHOTON_ROW,
					math.ceil(self.photon_count / PHOTON_ROW),
					1,
					desc,
					self.dynamic_offsets
				)
			end
		end,
		sampled_images = {
			{
				binding_index = BINDING_OCCLUSION_MAP,
				get_texture = function()
					return light_occlusion.GetOcclusionTexture()
				end,
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = BINDING_UNIFORM,
				block = {surface_lighting.block, gbuffer_layout.block, caustics.block},
				write = function(self, block)
					surface_lighting.WriteBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					self.photon_count = caustics.WriteBlock(self, block, caustics.photons:Get())
					return block
				end,
			},
		},
		custom_declarations = surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. optical_rays.GetDeclarationGLSL(SCENE_BINDINGS) .. caustics.GetBufferDeclarationGLSL(BINDING_RAW),
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("lighting_data") .. "\n" .. optical_rays.GetGLSL() .. ray_materials.GetAlphaTestGLSL() .. surface_lighting.GetGLSL("lighting_data", true) .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_world_pos_at"}) .. caustics.GetGLSL("lighting_data") .. [[
			bool caustic_land(vec3 P, vec3 Ng, vec3 incoming, vec3 flux) {
				caustic_world_add(P, Ng, flux * get_pre_exposure());
				ivec2 pixel = caustic_screen_pixel(P, Ng);

				if (pixel.x < 0) return false;

				caustic_add(uint(pixel.y) * uint(lighting_data.render_size.x) + uint(pixel.x), flux / caustic_pixel_area(P, Ng) * get_pre_exposure());
				return true;
			}

			void main() {
				uint id = gl_GlobalInvocationID.y * ]] .. PHOTON_ROW .. [[u + gl_GlobalInvocationID.x;

				uvec4 seed = pcg4d(uvec4(id, uint(lighting_data.caustic_frame), 0x2545F491u, 0x9E3779B9u));
				caustic_rng = seed.x ^ seed.w;
				caustic_run(id, lighting_data.caustic_bounces, lighting_data.caustic_dispersion_spread, lighting_data.view_scale);
			}
		]],
	},
	{
		name = "caustics_world",
		ComputePass = true,
		is_enabled = function()
			return is_enabled() and caustics.world:Get()
		end,
		ColorFormat = {{"r8_unorm", {"caustics_world_dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = PHOTON_LOCAL_SIZE,
		on_draw = function(self, cmd, fb, frame, desc)
			caustics.GetWorldGrid(cmd)
			caustics.Barrier(cmd, "world")
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, caustics.WORLD_ENTRIES, 1, 1, desc, self.dynamic_offsets)
			caustics.Barrier(
				cmd,
				"world",
				{
					"compute",
					"fragment",
					render.GetDevice().ray_tracing_supported and
					"ray_tracing_shader_khr" or
					nil,
				}
			)
		end,
		uniform_buffers = {
			{
				name = "world_data",
				binding_index = BINDING_UNIFORM,
				block = {caustics.world_block, post_source.pre_exposure_block, {"history", "float"}},
				write = function(self, block)
					block.caustic_world_grid = caustics.GetWorldGridAddress()
					block.history = caustics.world_history:Get()
					post_source.WritePreExposureBlock(self, block)
					return block
				end,
			},
		},
		shader = post_source.GetPreExposureGLSL("world_data") .. caustics.GetWorldGLSL("world_data") .. [[
			void main() {
				uint id = gl_GlobalInvocationID.x;

				if (id >= CAUSTIC_WORLD_ENTRIES) return;

				CausticWorldGrid grid = CausticWorldGrid(world_data.caustic_world_grid);
				uint slot = id * 8u;

				if (grid.v[slot] == 0u) return;

				vec3 irradiance = vec3(grid.v[slot + 1u], grid.v[slot + 2u], grid.v[slot + 3u]) / (CAUSTIC_WORLD_FIXED_POINT * get_pre_exposure());
				float frames = min(float(grid.v[slot + 7u]) + 1.0, world_data.history);
				vec3 smoothed = mix(vec3(uintBitsToFloat(grid.v[slot + 4u]), uintBitsToFloat(grid.v[slot + 5u]), uintBitsToFloat(grid.v[slot + 6u])), irradiance, 1.0 / frames);

				if (max(max(smoothed.r, smoothed.g), smoothed.b) < 1e-4) {
					for (uint i = 0u; i < 8u; i++) grid.v[slot + i] = 0u;

					return;
				}

				grid.v[slot + 1u] = 0u;
				grid.v[slot + 2u] = 0u;
				grid.v[slot + 3u] = 0u;
				grid.v[slot + 4u] = floatBitsToUint(smoothed.r);
				grid.v[slot + 5u] = floatBitsToUint(smoothed.g);
				grid.v[slot + 6u] = floatBitsToUint(smoothed.b);
				grid.v[slot + 7u] = uint(frames);
			}
		]],
	},
	filter_pass("caustics_filter_h", false),
	filter_pass("caustics_filter_v", true),
	{
		name = "caustics",
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"caustics", "rgba"}},
			{"r16g16b16a16_sfloat", {"caustics_geometry", "rgba"}},
		},
		framebuffer_count = 2,
		LocalSize = LOCAL_SIZE,
		storage_images = {
			{binding_index = BINDING_OUTPUT, attachment = 1, dst_stage = "compute"},
			{binding_index = BINDING_OUTPUT + 1, attachment = 2, dst_stage = "compute"},
		},
		uniform_buffers = {
			{
				name = "accumulate_data",
				binding_index = BINDING_UNIFORM,
				block = {
					gbuffer_layout.block,
					render3d.camera_block,
					post_source.pre_exposure_block,
					{"current_tex", "int"},
					{"history_tex", "int"},
					{"history_geometry_tex", "int"},
					{"max_history", "float"},
					{"photons", "float"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					block.current_tex = self:GetTextureIndex(attachment("caustics_filter_v", 1, 1))
					block.max_history = caustics.GetHistory()
					block.photons = caustics.filter_photons:Get()
					local frame = system.GetFrameNumber()

					if self.history_framebuffers ~= self.framebuffers then
						self.history_framebuffers = self.framebuffers
						self.history_reset_frame = frame
					end

					if
						frame > self.history_reset_frame and
						render3d.ShouldUseLastFrameHistory() and
						not render3d.IsDenoisingBypassed()
					then
						local history = self:GetFramebuffer((frame + 1) % 2 + 1)
						block.history_tex = self:GetTextureIndex(history:GetAttachment(1))
						block.history_geometry_tex = self:GetTextureIndex(history:GetAttachment(2))
					else
						block.history_tex = -1
						block.history_geometry_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_caustics;
			layout(set = 0, binding = ]] .. (
				BINDING_OUTPUT + 1
			) .. [[, rgba16f) uniform writeonly image2D out_geometry;
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("accumulate_data") .. post_source.GetPreExposureGLSL("accumulate_data") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_caustics);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 current_sample = texelFetch(TEXTURE(accumulate_data.current_tex), pos, 0);
				vec3 current = current_sample.rgb;
				vec2 uv = get_screen_uv(pos, size);
				float depth = gbuffer_depth(pos);
				vec3 N = gbuffer_normal(pos);
				float view_depth = 0.0;

				if (depth > 0.0) {
					vec4 view = accumulate_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
					view_depth = -view.z / view.w;
				}

				float history_length = 0.0;
				vec3 history = current;

				if (accumulate_data.history_tex != -1 && accumulate_data.velocity_tex != -1 && depth > 0.0) {
					vec4 motion = texture(TEXTURE(accumulate_data.velocity_tex), uv);
					vec2 history_pixel = (uv - motion.xy) * vec2(size) - 0.5;
					ivec2 base = ivec2(floor(history_pixel));
					vec2 f = history_pixel - vec2(base);
					float depth_tolerance = 0.05 * motion.z + 0.02 * accumulate_data.view_scale;
					float total = 0.0;
					vec4 sum = vec4(0.0);

					for (int tap = 0; tap < 4; tap++) {
						ivec2 offset = ivec2(tap & 1, tap >> 1);
						ivec2 texel = base + offset;

						if (any(lessThan(texel, ivec2(0))) || any(greaterThanEqual(texel, size))) continue;

						vec4 geometry = texelFetch(TEXTURE(accumulate_data.history_geometry_tex), texel, 0);

						if (geometry.x <= 0.0 || abs(geometry.x - motion.z) > depth_tolerance) continue;

						float w = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y) * smoothstep(0.8, 0.95, dot(oct_decode(geometry.yz), N));
						sum += texelFetch(TEXTURE(accumulate_data.history_tex), texel, 0) * w;
						total += w;
					}

					if (total > 1e-3) {
						history = sum.rgb / total * (get_pre_exposure() / max(get_previous_pre_exposure(), 1e-12));
						history_length = sum.a / total;
					}
				}

				vec3 mean = vec3(0.0);
				vec3 mean_squared = vec3(0.0);

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec3 value = texelFetch(TEXTURE(accumulate_data.current_tex), clamp(pos + ivec2(x, y), ivec2(0), size - 1), 0).rgb;
						mean += value;
						mean_squared += value * value;
					}
				}

				mean /= 9.0;
				// a few photons are noise, not motion: clamping them to their neighbours keeps the history from ever averaging them
				float dense = smoothstep(accumulate_data.photons, 4.0 * accumulate_data.photons, current_sample.a);
				vec3 spread = (1.5 * sqrt(max(mean_squared / 9.0 - mean * mean, vec3(0.0))) + 0.1 * mean + 1e-4) * mix(1e4, 1.0, dense);
				vec3 clamped = clamp(history, mean - spread, mean + spread);

				if (clamped != history) history_length = min(history_length, 2.0);

				history_length = min(history_length + 1.0, accumulate_data.max_history * mix(4.0, 1.0, dense));
				vec3 result = mix(clamped, current, 1.0 / history_length);
				imageStore(out_caustics, pos, vec4(max(result, vec3(0.0)), history_length));
				imageStore(out_geometry, pos, vec4(view_depth, oct_encode(N), 0.0));
			}
		]],
	},
}
