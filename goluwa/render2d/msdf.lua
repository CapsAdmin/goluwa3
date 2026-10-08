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
			block = {
				{"max_dist", "float"},
				{"num_edges", "int"},
				{"even_odd", "int"},
				{"pseudo", "int"},
			},
			write = function(self, block)
				block.max_dist = self.current_max_dist
				block.num_edges = self.current_num_edges
				block.even_odd = self.current_even_odd
				block.pseudo = self.current_pseudo
				return block
			end,
			shader = [[
				layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_tex;

				// Edge data: 6 floats per edge (x0, y0, x1, y1, channel, side)
				// channel: bit flags - bit0=R(1), bit1=G(2), bit2=B(4)
				// side: +1 if the filled side is where cross(b - a, p - a) > 0, else -1
				layout(set = 0, binding = 1, std430) coherent buffer EdgeBuffer {
					float edges[];
				} edge_buf;

				struct Best {
					float dist;
					float ortho;
					float signed_dist;
				};

				void consider(inout Best best, float dist, float ortho, float signed_dist) {
					if (dist < best.dist - 1e-5 || (dist < best.dist + 1e-5 && ortho < best.ortho)) {
						best.dist = dist;
						best.ortho = ortho;
						best.signed_dist = signed_dist;
					}
				}

				void main() {
					ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(out_tex);
					if (pos.x >= size.x || pos.y >= size.y) return;
					vec2 p = vec2(pos) + 0.5;

					int winding = 0;
					for (int i = 0; i < compute.num_edges; i++) {
						int idx = i * 6;
						float ay = edge_buf.edges[idx + 1];
						float by = edge_buf.edges[idx + 3];
						if ((ay > p.y) != (by > p.y)) {
							float x_int = edge_buf.edges[idx] + (p.y - ay) / (by - ay) * (edge_buf.edges[idx + 2] - edge_buf.edges[idx]);
							if (x_int > p.x) winding += (by > ay) ? 1 : -1;
						}
					}
					bool inside = compute.even_odd != 0 ? ((winding & 1) != 0) : (winding != 0);
					float d_sign = inside ? 1.0 : -1.0;

					Best best_r = Best(1e10, 1e10, d_sign * 1e10);
					Best best_g = best_r;
					Best best_b = best_r;
					float nearest = 1e10;

					for (int i = 0; i < compute.num_edges; i++) {
						int idx = i * 6;
						vec2 a = vec2(edge_buf.edges[idx], edge_buf.edges[idx + 1]);
						vec2 b = vec2(edge_buf.edges[idx + 2], edge_buf.edges[idx + 3]);
						int channel = int(edge_buf.edges[idx + 4] + 0.5);
						float side = edge_buf.edges[idx + 5];

						vec2 ab = b - a;
						vec2 ap = p - a;
						float len2 = max(dot(ab, ab), 1e-12);
						float t = dot(ap, ab) / len2;
						vec2 q = ap - ab * clamp(t, 0.0, 1.0);
						float dist = length(q);
						float signed_dist = d_sign * dist;
						float ortho = 0.0;

						if (compute.pseudo != 0 && (t <= 0.0 || t >= 1.0)) {
							float perp = (ab.x * ap.y - ab.y * ap.x) * inversesqrt(len2);
							ortho = abs(dot(q, ab)) / max(dist * sqrt(len2), 1e-9);
							signed_dist = side * perp;
						}

						nearest = min(nearest, dist);

						if ((channel & 1) != 0) consider(best_r, dist, ortho, signed_dist);
						if ((channel & 2) != 0) consider(best_g, dist, ortho, signed_dist);
						if ((channel & 4) != 0) consider(best_b, dist, ortho, signed_dist);
					}

					vec3 sd = vec3(best_r.signed_dist, best_g.signed_dist, best_b.signed_dist);
					vec3 v = clamp(sd / compute.max_dist + 0.5, 0.0, 1.0);
					float a = clamp(d_sign * nearest / compute.max_dist + 0.5, 0.0, 1.0);
					imageStore(out_tex, pos, vec4(v, a));
				}
			]],
		},
	}
	return M.pipelines
end

local function get_contour_ranges(edges)
	local ranges = {}

	for i, edge in ipairs(edges) do
		local range = ranges[edge.contour]

		if not range then
			range = {first = i, last = i, area = 0}
			ranges[edge.contour] = range
		end

		range.last = i
		range.area = range.area + (edge.p0.x * edge.p1.y - edge.p1.x * edge.p0.y) / 2
	end

	return ranges
end

local function point_in_contour(edges, range, x, y)
	local inside = false

	for i = range.first, range.last do
		local e = edges[i]
		local ay, by = e.p0.y, e.p1.y

		if (ay > y) ~= (by > y) then
			if e.p0.x + (y - ay) / (by - ay) * (e.p1.x - e.p0.x) > x then
				inside = not inside
			end
		end
	end

	return inside
end

local function compute_contour_sides(edges, fill_rule)
	local ranges = get_contour_ranges(edges)
	local sides = {}

	if fill_rule == "evenodd" then
		for id, range in pairs(ranges) do
			local first = edges[range.first]
			local depth = 0

			for other_id, other in pairs(ranges) do
				if other_id ~= id and point_in_contour(edges, other, first.p0.x, first.p0.y) then
					depth = depth + 1
				end
			end

			local orientation = range.area >= 0 and 1 or -1
			sides[id] = depth % 2 == 0 and orientation or -orientation
		end
	else
		local largest, largest_area = nil, -1

		for id, range in pairs(ranges) do
			if math.abs(range.area) > largest_area then
				largest, largest_area = id, math.abs(range.area)
			end
		end

		local orientation = ranges[largest].area >= 0 and 1 or -1

		for id in pairs(ranges) do
			sides[id] = orientation
		end
	end

	return sides
end

local function create_edge_buffer(edges, channel_override, fill_rule)
	local count = #edges
	local edge_data = ffi.new("float[?]", count * 6)
	local sides = compute_contour_sides(edges, fill_rule)

	for i, edge in ipairs(edges) do
		local idx = (i - 1) * 6
		edge_data[idx + 0] = edge.p0.x
		edge_data[idx + 1] = edge.p0.y
		edge_data[idx + 2] = edge.p1.x
		edge_data[idx + 3] = edge.p1.y
		edge_data[idx + 4] = channel_override or edge.channel
		edge_data[idx + 5] = sides[edge.contour]
	end

	local edge_buffer = Buffer.New{
		device = render.GetDevice(),
		size = count * 6 * 4,
		usage = {"storage_buffer"},
	}
	edge_buffer:CopyData(edge_data, count * 6 * 4)
	return edge_buffer
end

function M.Build(opts)
	opts = opts or {}
	local width = assert(opts.width, "msdf.Build requires width")
	local height = assert(opts.height, "msdf.Build requires height")
	local spread = assert(opts.spread, "msdf.Build requires spread")
	local format = opts.format or "r8g8b8a8_unorm"
	local filter = opts.filter or "linear"
	local msdf_mode = opts.mode == "msdf"
	local edges = assert(opts.edges, "msdf.Build requires edges")
	local fill_rule = opts.fill_rule or "nonzero"
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
		pipe.current_even_odd = fill_rule == "evenodd" and 1 or 0
		pipe.current_pseudo = msdf_mode and 1 or 0
		local edge_buffer = create_edge_buffer(edges, channel_override, fill_rule)
		pipe:Bind(cmd, {storage = {tex_final}, buffers = {edge_buffer}})
		pipe:DispatchForSize(cmd, width, height, 1)
		render.TransitionResourceToShaderRead(tex_final, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
		return tex_final
	end)
end

do
	local CHANNEL_R, CHANNEL_G, CHANNEL_B = 1, 2, 4
	local CHANNEL_WHITE = CHANNEL_R + CHANNEL_G + CHANNEL_B
	local CHANNEL_CYCLE = {CHANNEL_R + CHANNEL_G, CHANNEL_G + CHANNEL_B, CHANNEL_B + CHANNEL_R}
	local CORNER_ANGLE_THRESHOLD = math.rad(30)

	function M.ColorPolyline(poly, contour)
		local unique = {}

		for _, pt in ipairs(poly) do
			local last = unique[#unique]

			if not last or math.abs(pt.x - last.x) > 1e-9 or math.abs(pt.y - last.y) > 1e-9 then
				unique[#unique + 1] = pt
			end
		end

		local first, last = unique[1], unique[#unique]

		if
			#unique > 1 and
			math.abs(first.x - last.x) <= 1e-9 and
			math.abs(first.y - last.y) <= 1e-9
		then
			unique[#unique] = nil
		end

		poly = unique
		local n = #poly

		if n < 2 then return {} end

		local dirs = {}

		for i = 1, n do
			local a = poly[i]
			local b = poly[(i % n) + 1]
			local dx, dy = b.x - a.x, b.y - a.y
			local len = math.sqrt(dx * dx + dy * dy)

			if len < 1e-9 then
				dirs[i] = {x = 0, y = 0}
			else
				dirs[i] = {x = dx / len, y = dy / len}
			end
		end

		local corners = {}

		for i = 1, n do
			local prev = dirs[((i - 2) % n) + 1]
			local this = dirs[i]
			local cross = prev.x * this.y - prev.y * this.x
			local dot = prev.x * this.x + prev.y * this.y

			if math.atan2(math.abs(cross), dot) > CORNER_ANGLE_THRESHOLD then
				corners[#corners + 1] = i
			end
		end

		local edge_color = {}

		if #corners == 0 then
			for i = 1, n do
				edge_color[i] = CHANNEL_WHITE
			end
		else
			local run_starts = corners

			if #corners == 1 then
				local parts = math.min(3, n)
				run_starts = {}

				for k = 0, parts - 1 do
					run_starts[#run_starts + 1] = ((corners[1] - 1 + math.floor(k * n / parts)) % n) + 1
				end
			end

			local run_count = #run_starts

			for r = 1, run_count do
				local color_idx = (r - 1) % 3 + 1

				if r == run_count and run_count > 1 and color_idx == 1 then color_idx = 2 end

				local first = run_starts[r]
				local count = run_count == 1 and n or ((run_starts[r % run_count + 1] - first - 1) % n) + 1

				for k = 0, count - 1 do
					edge_color[((first - 1 + k) % n) + 1] = CHANNEL_CYCLE[color_idx]
				end
			end
		end

		local edges = {}

		for i = 1, n do
			edges[i] = {
				p0 = poly[i],
				p1 = poly[(i % n) + 1],
				channel = edge_color[i],
				contour = contour,
			}
		end

		return edges
	end
end

return M
