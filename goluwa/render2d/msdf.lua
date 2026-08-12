local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local M = library()
local JFA_DESCRIPTOR_SET_COUNT = 1024

local function get_pipelines()
	if M.pipelines then return M.pipelines end

	M.pipelines = {
		init = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = {{binding = 0}},
			sampled_images = {{binding = 1}},
			block = {{"mode", "int"}},
			write = function(self, block)
				block.mode = self.current_jfa_mode
				return block
			end,
			shader = [[
				layout(set = 0, binding = 0, rg32f) uniform writeonly image2D out_seed;
					layout(set = 0, binding = 1) uniform sampler2D mask_tex;
					void main() {
						ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
						ivec2 size = imageSize(out_seed);
						if (pos.x >= size.x || pos.y >= size.y) return;
						vec2 uv = (vec2(pos) + vec2(0.5)) / vec2(size);
						vec4 tex = texture(mask_tex, uv);
						float mask = max(tex.r, tex.a);
						vec2 seed = (compute.mode == 0) ? (mask > 0.0 ? vec2(pos) : vec2(-1.0)) : (mask < 1 ? vec2(pos) : vec2(-1.0));
						imageStore(out_seed, pos, vec4(seed, 0.0, 0.0));
					}
			]],
		},
		step = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = {{binding = 0}},
			sampled_images = {{binding = 1}},
			block = {{"step_size", "int"}},
			write = function(self, block)
				block.step_size = self.current_jfa_step
				return block
			end,
			shader = [[
				layout(set = 0, binding = 0, rg32f) uniform writeonly image2D out_seed;
				layout(set = 0, binding = 1) uniform sampler2D in_seed;
				void main() {
					ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(out_seed);
					if (pos.x >= size.x || pos.y >= size.y) return;
					vec2 best_seed = texelFetch(in_seed, pos, 0).rg;
					float best_dist = (best_seed.x < 0.0) ? 1e10 : length(best_seed - vec2(pos));

					for (int y = -1; y <= 1; y++) {
						for (int x = -1; x <= 1; x++) {
							if (x == 0 && y == 0) continue;
							ivec2 sample_pos = clamp(pos + ivec2(x, y) * compute.step_size, ivec2(0), size - ivec2(1));
							vec2 seed = texelFetch(in_seed, sample_pos, 0).rg;
							if (seed.x >= 0.0) {
								float dist = length(seed - vec2(pos));
								if (dist < best_dist) {
									best_dist = dist;
									best_seed = seed;
								}
							}
						}
					}

					imageStore(out_seed, pos, vec4(best_seed, 0.0, 0.0));
				}
			]],
		},
		final = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = {{binding = 0}},
			sampled_images = {{binding = 1}},
			block = {{"max_dist", "float"}},
			write = function(self, block)
				block.max_dist = self.current_jfa_max_dist
				return block
			end,
			shader = [[
				layout(set = 0, binding = 0, r32f) uniform writeonly image2D out_dist;
				layout(set = 0, binding = 1) uniform sampler2D in_seed;
				void main() {
					ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(out_dist);
					if (pos.x >= size.x || pos.y >= size.y) return;
					vec2 seed = texelFetch(in_seed, pos, 0).rg;
					float dist = length(seed - vec2(pos));
					imageStore(out_dist, pos, vec4(dist, 0.0, 0.0, 1.0));
				}
			]],
		},
		combine_sdf = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = {{binding = 0}},
			sampled_images = {{binding = 1}, {binding = 2}, {binding = 3}},
			block = {{"max_dist", "float"}},
			write = function(self, block)
				block.max_dist = self.current_jfa_max_dist
				return block
			end,
			shader = [[
				layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_tex;
				layout(set = 0, binding = 1) uniform sampler2D dist_on_tex;
				layout(set = 0, binding = 2) uniform sampler2D dist_off_tex;
				layout(set = 0, binding = 3) uniform sampler2D mask_tex;

				void main() {
					ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(out_tex);
					if (pos.x >= size.x || pos.y >= size.y) return;
					ivec2 dist_size = textureSize(dist_on_tex, 0);
					ivec2 sample_pos = clamp(pos, ivec2(0), dist_size - ivec2(1));
					float d_on = texelFetch(dist_on_tex, sample_pos, 0).r;
					float d_off = texelFetch(dist_off_tex, sample_pos, 0).r;
					float dist = d_off - d_on;
					float norm_dist = clamp(dist / compute.max_dist + 0.5, 0.0, 1.0);
					imageStore(out_tex, pos, vec4(norm_dist, norm_dist, norm_dist, 1.0));
				}
			]],
		},
		combine_msdf = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = {{binding = 0}},
			sampled_images = {{binding = 1}, {binding = 2}, {binding = 3}},
			storage_buffers = {{binding = 4}},
			block = {{"max_dist", "float"}, {"num_edges", "int"}},
			write = function(self, block)
				block.max_dist = self.current_jfa_max_dist
				block.num_edges = self.current_num_edges
				return block
			end,
			shader = [[
				layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_tex;
				layout(set = 0, binding = 1) uniform sampler2D dist_on_tex;
				layout(set = 0, binding = 2) uniform sampler2D dist_off_tex;
				layout(set = 0, binding = 3) uniform sampler2D mask_tex;

				// Edge data: 5 floats per edge (x0, y0, x1, y1, channel)
				// channel: bit flags - bit0=R(1), bit1=G(2), bit2=B(4)
				layout(set = 0, binding = 4, std430) coherent buffer EdgeBuffer {
					float edges[];
				} edge_buf;

				// Signed distance from point p to segment a->b
				// Returns distance (always positive); sign determined separately
				float sdSegment(vec2 p, vec2 a, vec2 b) {
					vec2 ea = a - p;
					vec2 ab = b - a;
					float h = clamp(dot(ea, -ab) / dot(ab, ab), 0.0, 1.0);
					return length(ea + ab * h);
				}

				void main() {
					ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(out_tex);
					if (pos.x >= size.x || pos.y >= size.y) return;

					// Sign oracle from JFA distance fields
					float d_on = texelFetch(dist_on_tex, pos, 0).r;
					float d_off = texelFetch(dist_off_tex, pos, 0).r;
					float dist = d_off - d_on;
					float d_sign = sign(dist);
					float abs_dist = abs(dist);

					// Brute-force min-distance per channel
					float min_r = abs_dist;
					float min_g = abs_dist;
					float min_b = abs_dist;
					vec2 p = vec2(pos);

					for (int i = 0; i < compute.num_edges; i++) {
						int idx = i * 5;
						vec2 a = vec2(edge_buf.edges[idx], edge_buf.edges[idx + 1]);
						vec2 b = vec2(edge_buf.edges[idx + 2], edge_buf.edges[idx + 3]);
						float channel = edge_buf.edges[idx + 4];
						float d = sdSegment(p, a, b);

						// channel is bit flags: 1=R, 2=G, 4=B
						if (mod(channel, 2.0) > 0.5) { min_r = min(min_r, d); }
						if (mod(channel / 2.0, 2.0) > 0.5) { min_g = min(min_g, d); }
						if (mod(channel / 4.0, 2.0) > 0.5) { min_b = min(min_b, d); }
					}

					// Apply sign and normalize
					float r_ch = clamp(d_sign * min_r / compute.max_dist + 0.5, 0.0, 1.0);
					float g_ch = clamp(d_sign * min_g / compute.max_dist + 0.5, 0.0, 1.0);
					float b_ch = clamp(d_sign * min_b / compute.max_dist + 0.5, 0.0, 1.0);

					imageStore(out_tex, pos, vec4(r_ch, g_ch, b_ch, 1.0));
				}
			]],
		},
	}
	return M.pipelines
end

local function get_next_pow2_and_steps(n)
	local r = 1
	local steps = 0

	while r < n do
		r = r * 2
		steps = steps + 1
	end

	return r, steps
end

-- Build an SDF or MSDF texture from a binary mask.
-- JFA runs at the mask texture's resolution, result is blitted down to width x height.
-- @param maskTexture  Binary on/off texture (r channel used)
-- @param opts         { width, height, spread, format, filter, msdf?, edges? }
-- @return             The final SDF/MSDF texture at width x height
function M.Build(maskTexture, opts)
	opts = opts or {}
	local width = assert(opts.width, "msdf.Build requires width")
	local height = assert(opts.height, "msdf.Build requires height")
	local spread = assert(opts.spread, "msdf.Build requires spread")
	local format = opts.format or "r8g8b8a8_unorm"
	local filter = opts.filter or "linear"
	local msdf_mode = opts.mode == "msdf"
	local edges = opts.edges
	return render.ExecuteCommand(function(cmd)
		local p = get_pipelines()
		local mask_size = maskTexture:GetSize()
		local super_w = mask_size.x
		local super_h = mask_size.y
		local tex_a = Texture.New{
			width = super_w,
			height = super_h,
			format = "r32g32_sfloat",
			sampler = {min_filter = "nearest", mag_filter = "nearest"},
			image = {usage = {"storage", "sampled"}},
		}
		local tex_b = Texture.New{
			width = super_w,
			height = super_h,
			format = "r32g32_sfloat",
			sampler = {min_filter = "nearest", mag_filter = "nearest"},
			image = {usage = {"storage", "sampled"}},
		}
		local tex_dist_on = Texture.New{
			width = super_w,
			height = super_h,
			format = "r32_sfloat",
			sampler = {min_filter = "nearest", mag_filter = "nearest"},
			image = {usage = {"storage", "sampled"}},
		}
		local tex_dist_off = Texture.New{
			width = super_w,
			height = super_h,
			format = "r32_sfloat",
			sampler = {min_filter = "nearest", mag_filter = "nearest"},
			image = {usage = {"storage", "sampled"}},
		}
		local jfa_max_dist = spread
		p.final.current_jfa_max_dist = jfa_max_dist

		for mode = 0, 1 do
			p.init.current_jfa_mode = mode
			p.init:Bind(cmd, {storage = {tex_a}, sampled = {maskTexture}})
			p.init:DispatchForSize(cmd, super_w, super_h, 1)
			render.TransitionResourceToShaderRead(tex_a, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
			local current_tex = tex_a
			local next_tex = tex_b
			local p2 = get_next_pow2_and_steps(math.max(super_w, super_h))
			local step = p2 / 2

			while step >= 1 do
				p.step.current_jfa_step = step
				p.step:Bind(cmd, {storage = {next_tex}, sampled = {current_tex}})
				p.step:DispatchForSize(cmd, super_w, super_h, 1)
				render.TransitionResourceToShaderRead(next_tex, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
				current_tex, next_tex = next_tex, current_tex
				step = math.floor(step / 2)
			end

			for i = 1, 2 do
				p.step.current_jfa_step = 1
				p.step:Bind(cmd, {storage = {next_tex}, sampled = {current_tex}})
				p.step:DispatchForSize(cmd, super_w, super_h, 1)
				render.TransitionResourceToShaderRead(next_tex, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
				current_tex, next_tex = next_tex, current_tex
			end

			local out_tex = mode == 0 and tex_dist_on or tex_dist_off
			p.final:Bind(cmd, {storage = {out_tex}, sampled = {current_tex}})
			p.final:DispatchForSize(cmd, super_w, super_h, 1)
			render.TransitionResourceToShaderRead(out_tex, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
		end

		local tex_final = Texture.New{
			width = width,
			height = height,
			format = format,
			sampler = {min_filter = filter, mag_filter = filter},
			image = {usage = {"transfer_dst", "transfer_src", "sampled"}},
		}
		local pipe_combine = msdf_mode and p.combine_msdf or p.combine_sdf
		pipe_combine.current_jfa_max_dist = jfa_max_dist
		local tex_combine = Texture.New{
			width = super_w,
			height = super_h,
			format = format,
			sampler = {min_filter = filter, mag_filter = filter},
			image = {usage = {"storage", "transfer_src", "sampled"}},
		}

		if msdf_mode then
			assert(edges, "msdf.Build with msdf=true requires edges")
			local num_edges = #edges
			pipe_combine.current_num_edges = num_edges
			local edge_data = ffi.new("float[?]", num_edges * 5)

			for i, edge in ipairs(edges) do
				local idx = (i - 1) * 5
				edge_data[idx + 0] = edge.p0.x
				edge_data[idx + 1] = edge.p0.y
				edge_data[idx + 2] = edge.p1.x
				edge_data[idx + 3] = edge.p1.y
				edge_data[idx + 4] = edge.channel
			end

			local edge_buffer = Buffer.New{
				device = render.GetDevice(),
				size = num_edges * 5 * 4,
				usage = {"storage_buffer"},
			}
			edge_buffer:CopyData(edge_data, num_edges * 5 * 4)
			pipe_combine:Bind(
				cmd,
				{
					storage = {tex_combine},
					sampled = {tex_dist_on, tex_dist_off, maskTexture},
					buffers = {edge_buffer},
				}
			)
		else
			pipe_combine:Bind(
				cmd,
				{storage = {tex_combine}, sampled = {tex_dist_on, tex_dist_off, maskTexture}}
			)
		end

		pipe_combine:DispatchForSize(cmd, super_w, super_h, 1)
		render.TransitionResourceToTransferSrc(tex_combine, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
		render.TransitionResourceToTransferDst(tex_final, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
		cmd:BlitImage{
			src_image = tex_combine.image,
			dst_image = tex_final.image,
			src_layout = "transfer_src_optimal",
			dst_layout = "transfer_dst_optimal",
			src_width = super_w,
			src_height = super_h,
			dst_width = width,
			dst_height = height,
			filter = "linear",
		}
		render.TransitionResourceToShaderRead(tex_final, {cmd = cmd, srcStage = "transfer", srcAccess = "transfer_write"})
		return tex_final
	end)
end

do
	local CHANNEL_R, CHANNEL_G, CHANNEL_B = 1, 2, 4
	local CHANNEL_CYCLE = {CHANNEL_R + CHANNEL_G, CHANNEL_G + CHANNEL_B, CHANNEL_B + CHANNEL_R} -- yellow, cyan, magenta
	local CORNER_ANGLE_THRESHOLD = math.rad(3) -- msdfgen default-ish
	local function normalize(v)
		local len = math.sqrt(v.x * v.x + v.y * v.y)

		if len < 1e-9 then return {x = 0, y = 0} end

		return {x = v.x / len, y = v.y / len}
	end

	local function angle_between(a, b)
		local cross = a.x * b.y - a.y * b.x
		local dot = a.x * b.x + a.y * b.y
		return math.atan2(math.abs(cross), dot)
	end

	-- Color a polyline with MSDF channel flags.
	-- @param poly  Array of {x, y} points
	-- @return      Array of {p0, p1, channel} edges
	function M.ColorPolyline(poly)
		local n = #poly

		if n < 2 then return {} end

		local dirs = {}

		for i = 1, n do
			local a = poly[i]
			local b = poly[(i % n) + 1]
			dirs[i] = normalize{x = b.x - a.x, y = b.y - a.y}
		end

		local corner_before = {} -- corner_before[i] == true means edge i starts right after a corner
		for i = 1, n do
			local prev_dir = dirs[((i - 2) % n) + 1]
			local this_dir = dirs[i]

			if angle_between(prev_dir, this_dir) > CORNER_ANGLE_THRESHOLD then
				corner_before[i] = true
			end
		end

		local any_corner = false

		for i = 1, n do
			if corner_before[i] then
				any_corner = true

				break
			end
		end

		local edges = {}
		local color_idx = 1

		if not any_corner then
			for i = 1, n do
				local a = poly[i]
				local b = poly[(i % n) + 1]
				edges[#edges + 1] = {p0 = a, p1 = b, channel = CHANNEL_CYCLE[1]}
			end

			return edges
		end

		for i = 1, n do
			if corner_before[i] then color_idx = color_idx % 3 + 1 end

			local a = poly[i]
			local b = poly[(i % n) + 1]
			edges[#edges + 1] = {p0 = a, p1 = b, channel = CHANNEL_CYCLE[color_idx]}
		end

		return edges
	end
end

return M
