local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local M = library()
local COMPUTE_DESCRIPTOR_SET_COUNT = 1024

local function get_pipelines()
	if M.pipelines then return M.pipelines end

	M.pipelines = {
		combine = EasyPipeline.Compute{
			DescriptorSetCount = COMPUTE_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = {{binding = 0}},
			storage_buffers = {{binding = 1}},
			block = {{"max_dist", "float"}, {"num_edges", "int"}},
			write = function(self, block)
				block.max_dist = self.current_max_dist
				block.num_edges = self.current_num_edges
				return block
			end,
			shader = [[
				layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_tex;

				// Edge data: 5 floats per edge (x0, y0, x1, y1, channel)
				// channel: bit flags - bit0=R(1), bit1=G(2), bit2=B(4)
				layout(set = 0, binding = 1, std430) coherent buffer EdgeBuffer {
					float edges[];
				} edge_buf;

				// Distance from point p to segment a->b (always positive)
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
					vec2 p = vec2(pos);

					// Inside/outside via even-odd ray cast over all edges
					bool inside = false;
					for (int i = 0; i < compute.num_edges; i++) {
						int idx = i * 5;
						float ay = edge_buf.edges[idx + 1];
						float by = edge_buf.edges[idx + 3];
						if ((ay > p.y) != (by > p.y)) {
							float x_int = edge_buf.edges[idx] + (p.y - ay) / (by - ay) * (edge_buf.edges[idx + 2] - edge_buf.edges[idx]);
							if (x_int > p.x) inside = !inside;
						}
					}
					float d_sign = inside ? 1.0 : -1.0;

					// Brute-force min-distance per channel
					float min_r = 1e10;
					float min_g = 1e10;
					float min_b = 1e10;

					for (int i = 0; i < compute.num_edges; i++) {
						int idx = i * 5;
						vec2 a = vec2(edge_buf.edges[idx], edge_buf.edges[idx + 1]);
						vec2 b = vec2(edge_buf.edges[idx + 2], edge_buf.edges[idx + 3]);
						float channel = edge_buf.edges[idx + 4];
						float d = sdSegment(p, a, b);

						// channel is bit flags: 1=R, 2=G, 4=B
						if (mod(channel, 2.0) > 0.5) { min_r = min(min_r, d); }
						if (mod(channel / 2.0, 2.0) > 0.5) { min_g = min(min_g, d); }
						if (mod(floor(channel / 4.0), 2.0) > 0.5) { min_b = min(min_b, d); }
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

local function create_edge_buffer(edges, channel_override)
	local count = #edges
	local edge_data = ffi.new("float[?]", count * 5)

	for i, edge in ipairs(edges) do
		local idx = (i - 1) * 5
		edge_data[idx + 0] = edge.p0.x
		edge_data[idx + 1] = edge.p0.y
		edge_data[idx + 2] = edge.p1.x
		edge_data[idx + 3] = edge.p1.y
		edge_data[idx + 4] = channel_override or edge.channel
	end

	local edge_buffer = Buffer.New{
		device = render.GetDevice(),
		size = count * 5 * 4,
		usage = {"storage_buffer"},
	}
	edge_buffer:CopyData(edge_data, count * 5 * 4)
	return edge_buffer
end

-- Build an SDF or MSDF texture from edges.
-- Per-channel distances and the inside/outside sign are computed directly from
-- the edges at width x height, so edges must be in final texture space and
-- spread is in final texels.
-- mode = "msdf" uses each edge's channel flags; any other mode puts every edge
-- in all channels, producing a plain SDF in every channel.
-- @param opts  { width, height, spread, format?, filter?, mode?, edges }
-- @return      The final SDF/MSDF texture at width x height
function M.Build(opts)
	opts = opts or {}
	local width = assert(opts.width, "msdf.Build requires width")
	local height = assert(opts.height, "msdf.Build requires height")
	local spread = assert(opts.spread, "msdf.Build requires spread")
	local format = opts.format or "r8g8b8a8_unorm"
	local filter = opts.filter or "linear"
	local msdf_mode = opts.mode == "msdf"
	local edges = assert(opts.edges, "msdf.Build requires edges")
	local channel_override

	if not msdf_mode then channel_override = 7 end

	return render.ExecuteCommand(function(cmd)
		local p = get_pipelines()
		local tex_final = Texture.New{
			width = width,
			height = height,
			format = format,
			sampler = {
				min_filter = filter,
				mag_filter = filter,
				wrap_s = "clamp_to_border",
				wrap_t = "clamp_to_border",
			},
			image = {usage = {"storage", "transfer_src", "sampled"}},
		}
		local pipe = p.combine
		pipe.current_max_dist = spread
		pipe.current_num_edges = #edges
		local edge_buffer = create_edge_buffer(edges, channel_override)
		pipe:Bind(cmd, {storage = {tex_final}, buffers = {edge_buffer}})
		pipe:DispatchForSize(cmd, width, height, 1)
		render.TransitionResourceToShaderRead(tex_final, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
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
