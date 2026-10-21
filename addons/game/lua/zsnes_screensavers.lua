local ffi = require("ffi")
local bit = require("bit")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local W, H = 288, 224
local VIEW_W = 256
local STEP_RATE = 60
local SNOW_RATE = 36
local EFFECTS = {"snow", "water a", "water b", "burning", "smoke"}
local M = {EFFECTS = EFFECTS}
local current
local santa_enabled = os.date("%m%d") == "1225"

local common = [[
	#define W 288
	#define H 224

	const int multab[48] = int[48](
		1, 1, 1, 2, 2, 3, 4, 4, 5, 6, 6, 7, 8, 8, 9, 10,
		10, 11, 12, 12, 13, 14, 14, 15, 16, 16, 17, 18, 18, 19, 20, 20,
		21, 22, 22, 23, 24, 24, 25, 26, 26, 27, 28, 28, 29, 30, 30, 31
	);

	uint pcg(uint v) {
		uint s = v * 747796405u + 2891336453u;
		uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
		return (w >> 22u) ^ w;
	}

	uint hash4(uint a, uint b, uint c, uint d) {
		return pcg(a + pcg(b + pcg(c + pcg(d))));
	}
]]

local background_glsl = [[
	layout(set = 0, binding = 8) uniform sampler2D scene_tex;

	int background(ivec2 p) {
		if (p.x < 16 || p.x >= 272 || p.y < 0 || p.y >= H) return 0;

		vec2 g = vec2(p.x - 16, p.y);
		vec3 col;

		if (compute.scene != 0) {
			vec3 sum = vec3(0.0);

			for (int j = 0; j < 4; j++) {
				for (int i = 0; i < 4; i++) {
					sum += textureLod(scene_tex, (g + (vec2(i, j) + 0.5) / 4.0) / vec2(256.0, 224.0), 0.0).rgb;
				}
			}

			col = clamp(sum / 16.0, 0.0, 1.0);
			} else {
				vec2 uv = g / vec2(256.0, 224.0);
				float t = length((uv - 0.5) * vec2(1.14, 1.0)) * 4.0 + sin(uv.x * 12.0) * 0.3 + sin(uv.y * 9.0) * 0.3;
				col = (0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)))) * (0.35 + 0.65 * (0.5 + 0.5 * sin(t * 9.0)));

				if (g.y > 160.0 && (((int(g.x) >> 4) + (int(g.y) >> 4)) & 1) == 0) col *= 0.4;
			}

			ivec3 c = ivec3(col * 31.0 + 0.5);
			return multab[(c.r + c.g + c.b) / 2];
		}

		int background_linear(int n) {
			if (n < 0) return 0;

			return background(ivec2(n % W, n / W));
		}
	]]

local pipelines
local scene_active = 0
local scene_texture

local function get_pipelines()
	if pipelines then return pipelines end

	local function storage(count)
		local t = {}

		for i = 1, count do
			t[i] = {binding = i - 1}
		end

		return t
	end

	pipelines = {
		clear = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = storage(1),
			shader = [[
				layout(set = 0, binding = 0, r32ui) uniform writeonly uimage2D target;

				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);
					if (p.x >= 288 || p.y >= 224) return;
					imageStore(target, p, uvec4(0));
				}
			]],
		},
		present = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = storage(2),
			shader = common .. [[
				layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D idx;
				layout(set = 0, binding = 1, rgba8) uniform writeonly image2D out_tex;

				uint pal16(uint i) {
					int r = 0, g = 0, b = 0;

					if (i >= 1u && i <= 31u) {
						r = int(i) + 15;
						g = int(i) + 10;
						b = int(i) + 31;
					} else if (i >= 32u && i <= 63u) {
						r = g = b = int(i) * 2;
					} else if (i == 228u) {
						r = 45; g = 45; b = 50;
					} else if (i == 229u) {
						r = 40; g = 40; b = 45;
					} else if (i == 230u) {
						r = 35; g = 35; b = 40;
					} else if (i == 231u) {
						r = 30; g = 30; b = 35;
					}

					return uint(((r >> 1) << 11) | (g << 5) | (b >> 1)) & 0xFFFFu;
				}

				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);
					if (p.x >= 256 || p.y >= 224) return;

					int n = p.y * W + p.x + 16;
					uint c;

					if (n < W) {
						int o = n * 2;
						uint lo = imageLoad(idx, ivec2(o % W, o / W)).r & 255u;
						o++;
						uint hi = imageLoad(idx, ivec2(o % W, o / W)).r & 255u;
						c = lo | (hi << 8);
					} else {
						c = pal16(imageLoad(idx, ivec2(n % W, n / W)).r & 255u);
					}

					imageStore(out_tex, p, vec4(float(c >> 11) / 31.0, float((c >> 5) & 63u) / 63.0, float(c & 31u) / 31.0, 1.0));
				}
			]],
		},
		snow = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = storage(1),
			storage_buffers = {{binding = 1}},
			sampled_images = {{binding = 8}},
			block = {{"santa_on", "int"}, {"santa_pos", "int"}, {"scene", "int"}},
			write = function(self, block)
				block.scene = scene_active
				block.santa_on = self.current_santa_on
				block.santa_pos = self.current_santa_pos
				return block
			end,
			shader = common .. background_glsl .. [[
				layout(set = 0, binding = 0, r32ui) uniform writeonly uimage2D idx_out;
				layout(set = 0, binding = 1, std430) readonly buffer Aux { uint aux[]; };

				const int santa_data[128] = int[128](
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0,
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0,
					1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1,
					1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1,
					1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1,
					1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1
				);

				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);
					if (p.x >= W || p.y >= H) return;

					int n = p.y * W + p.x;
					uint v = uint(background(p));

					if (compute.santa_on != 0) {
						for (int h = 0; h < 8; h++) {
							int w = n - (compute.santa_pos + (60 + h) * W);

							if (w >= 0 && w < 16 && santa_data[h * 16 + w] != 0) v = 0u;
						}
					}

					for (int i = 0; i < 200; i++) {
						if (aux[i] == uint(n)) v = aux[200 + i];
					}

					imageStore(idx_out, p, uvec4(v));
				}
			]],
		},
		burn = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = storage(3),
			storage_buffers = {{binding = 3}},
			sampled_images = {{binding = 8}},
			block = {{"frame", "int"}, {"scene", "int"}},
			write = function(self, block)
				block.scene = scene_active
				block.frame = self.current_frame
				return block
			end,
			shader = common .. background_glsl .. [[
				layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D pt_in;
				layout(set = 0, binding = 1, r32ui) uniform writeonly uimage2D pt_out;
				layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D idx_out;
				layout(set = 0, binding = 3, std430) readonly buffer Aux { uint aux[]; };

				// DrawBurn walks the columns left to right and each column bottom to top, every cell it visits copies its
				// value one row up and one column left, straight or right (or clears it). The cell the whole frame ends
				// with is the last writer in that order: column c + 1, then column c, then column c - 1.

				int scatter(int c, int j) {
					return int(hash4(uint(compute.frame), uint(c), uint(j), 0u) % 3u);
				}

				int decrease(int c, int j) {
					return int(hash4(uint(compute.frame), uint(c), uint(j), 1u) % 5u);
				}

				int old_value(int j, int c) {
					if (j == 223) return int(aux[c]);

					return int(imageLoad(pt_in, ivec2(c, j)).r);
				}

				// the value the visit of cell (j, c) reads: the old value, unless column c - 1 (visited just before)
				// moved its cell (j + 1, c - 1) onto it, and that depends on the same question one step down the diagonal
				int read_value(int j, int c) {
					int depth = 0;

					while (true) {
						int k = depth + 1;
						int cc = c - k;
						int jj = j + k;

						if (cc < 1 || jj > 223 || scatter(cc, jj) != 0) break;

						depth = k;
					}

					int v = old_value(j + depth, c - depth);

					for (int k = depth; k >= 1; k--) {
						if (v >= 5) {
							v = v - decrease(c - k, j + k);
						} else {
							v = old_value(j + k - 1, c - k + 1);
						}
					}

					return v;
				}

				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);
					if (p.x >= W || p.y >= H) return;

					int c = p.x;
					int r = p.y;
					int nv;

					if (r == 223) {
						nv = int(aux[c]);
					} else {
						int j = r + 1;
						bool written = false;
						nv = int(imageLoad(pt_in, p).r);

						if (c <= 285) {
							int v = read_value(j, c + 1);

							if (v >= 5 && scatter(c + 1, j) == 2) {
								nv = v - decrease(c + 1, j);
								written = true;
							}
						}

						if (!written) {
							int v = read_value(j, c);

							if (v < 5 || c <= 0 || c >= 287) {
								nv = 0;
								written = true;
							} else if (scatter(c, j) == 1) {
								nv = v - decrease(c, j);
								written = true;
							}
						}

						if (!written && c >= 2) {
							int v = read_value(j, c - 1);

							if (v >= 5 && scatter(c - 1, j) == 0) nv = v - decrease(c - 1, j);
						}
					}

					imageStore(pt_out, p, uvec4(uint(nv)));

					int i = background(p);
					int j = nv >> 3;
					imageStore(idx_out, p, uvec4(uint(j > i ? j : ((i + j) >> 1) + 1)));
				}
			]],
		},
		smoke = EasyPipeline.Compute{
			DescriptorSetCount = 1024,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = storage(3),
			storage_buffers = {{binding = 3}},
			sampled_images = {{binding = 8}},
			block = {{"line_offset", "int"}, {"scene", "int"}},
			write = function(self, block)
				block.scene = scene_active
				block.line_offset = self.current_line_offset
				return block
			end,
			shader = common .. background_glsl .. [[
				layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D fire_in;
				layout(set = 0, binding = 1, r32ui) uniform writeonly uimage2D fire_out;
				layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D idx_out;
				layout(set = 0, binding = 3, std430) readonly buffer Aux { uint aux[]; };

				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);
					if (p.x >= W || p.y >= H) return;

					int line = int(aux[compute.line_offset + p.x]);
					int v;

					if (p.y == 223) {
						v = line;
					} else {
						v = p.y == 222 ? line : int(imageLoad(fire_in, ivec2(p.x, p.y + 1)).r);
						if (v > 0) v--;
					}

					imageStore(fire_out, p, uvec4(uint(v)));

					int i = background(p);
					int j = v / 8;
					imageStore(idx_out, p, uvec4(uint(j > i ? j : ((i + j) / 2) + 1)));
				}
			]],
		},
		water = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = storage(3),
			storage_buffers = {{binding = 3}},
			sampled_images = {{binding = 8}},
			block = {{"scene", "int"}},
			write = function(self, block)
				block.scene = scene_active
				return block
			end,
			shader = common .. background_glsl .. [[
				layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D page_cur;
				layout(set = 0, binding = 1, r32ui) uniform uimage2D page_next;
				layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D idx_out;
				layout(set = 0, binding = 3, std430) readonly buffer Aux { int aux[]; };

				int blob(ivec2 q) {
					int s = 0;

					for (int i = 0; i < aux[0]; i++) {
						int o = 1 + i * 8;
						ivec2 d = q - ivec2(aux[o], aux[o + 1]);

						if (d.x >= aux[o + 2] && d.x < aux[o + 3] && d.y >= aux[o + 4] && d.y < aux[o + 5]) {
							int sq = d.x * d.x + d.y * d.y;

							if (sq < aux[o + 7]) s += aux[aux[o + 6] + sq];
						}
					}

					return s;
				}

				int height(ivec2 q) {
					return int(imageLoad(page_cur, q).r) + blob(q);
				}

				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);
					if (p.x >= W || p.y >= H) return;

					int c = 0;

					if (p.x >= 1 && p.x <= 286 && p.y >= 1 && p.y <= 222) {
						int a = int(imageLoad(page_cur, p).r);
						int dx = a - int(imageLoad(page_cur, p + ivec2(1, 0)).r);
						int dy = a - int(imageLoad(page_cur, p + ivec2(0, 1)).r);
						int q = p.y * W + p.x + W * (dy >> 3) + (dx >> 3);

						if (q > H * W) q = (q % W) + ((H - ((q - H * W) / W)) * W);

						if (q < 0) q = (W + (q - (q / W) * W)) + abs(q / W) * W;

						c = clamp(background_linear(q) - (dx >> 1), 1, 31);

						int sum = height(p + ivec2(0, 1)) + height(p + ivec2(0, -1)) + height(p + ivec2(1, 0)) + height(p + ivec2(-1, 0))
							+ height(p + ivec2(-1, -1)) + height(p + ivec2(1, -1)) + height(p + ivec2(-1, 1)) + height(p + ivec2(1, 1));
						int newh = (sum >> 2) - int(imageLoad(page_next, p).r);
						imageStore(page_next, p, uvec4(uint(newh - (newh >> 5))));
					}

					imageStore(idx_out, p, uvec4(uint(c)));
				}
			]],
		},
		water_blobs = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = storage(1),
			storage_buffers = {{binding = 1}},
			shader = common .. [[
				layout(set = 0, binding = 0, r32ui) uniform uimage2D page_cur;
				layout(set = 0, binding = 1, std430) readonly buffer Aux { int aux[]; };

				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);
					if (p.x >= W || p.y >= H) return;

					int s = 0;

					for (int i = 0; i < aux[0]; i++) {
						int o = 1 + i * 8;
						ivec2 d = p - ivec2(aux[o], aux[o + 1]);

						if (d.x >= aux[o + 2] && d.x < aux[o + 3] && d.y >= aux[o + 4] && d.y < aux[o + 5]) {
							int sq = d.x * d.x + d.y * d.y;

							if (sq < aux[o + 7]) s += aux[aux[o + 6] + sq];
						}
					}

					if (s != 0) imageStore(page_cur, p, uvec4(uint(int(imageLoad(page_cur, p).r) + s)));
				}
			]],
		},
	}
	return pipelines
end

local function create_image(format, usage, filter, w, h)
	return Texture.New{
		width = w or W,
		height = h or H,
		format = format,
		sampler = {
			min_filter = filter or "nearest",
			mag_filter = filter or "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
		image = {usage = usage},
	}
end

local idx_image, page_a, page_b, screen_image, aux_buffer
local AUX_WORDS = W * H
local aux_data = ffi.new("uint32_t[?]", AUX_WORDS)

local function barrier(cmd)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
end

local function upload_aux(first_word, count)
	aux_buffer:CopyData(aux_data + first_word, count * 4, first_word * 4)
end

local function clear(cmd, image)
	local p = get_pipelines()
	p.clear:Bind(cmd, {storage = {image}})
	p.clear:DispatchForSize(cmd, W, H, 1)
	barrier(cmd)
end

local FSIN, FCOS = {}, {}

for i = 0, 2047 do
	local s = 65536 * math.sin(i * 2 * math.pi / 2048)
	local c = 65536 * math.cos(i * 2 * math.pi / 2048)
	FSIN[i] = s < 0 and math.ceil(s) or math.floor(s)
	FCOS[i] = c < 0 and math.ceil(c) or math.floor(c)
end

local effects = {}
do
	local snow_data = {
		161, 251, 115, 211, 249, 87, 128, 101, 232, 176, 51, 180, 108, 193, 224, 112, 254, 159, 102, 238,
		223, 123, 218, 42, 173, 160, 143, 170, 64, 1, 174, 29, 34, 187, 194, 199, 40, 89, 232, 32,
		7, 195, 141, 67, 216, 48, 234, 1, 243, 116, 164, 182, 146, 136, 66, 70, 36, 43, 98, 208,
		63, 240, 216, 253, 147, 36, 33, 253, 98, 80, 228, 156, 73, 82, 85, 1, 97, 72, 187, 239,
		18, 196, 127, 182, 22, 22, 101, 25, 124, 145, 240, 213, 186, 22, 7, 161, 30, 98, 90, 197,
		22, 205, 32, 150, 59, 133, 49, 140, 10, 128, 142, 185, 176, 142, 220, 195, 100, 102, 105, 194,
		43, 139, 184, 153, 1, 95, 176, 169, 192, 201, 233, 243, 73, 65, 188, 14, 194, 39, 251, 140,
		239, 181, 142, 160, 242, 248, 82, 49, 9, 157, 233, 162, 254, 121, 112, 6, 118, 24, 56, 121,
		74, 209, 1, 223, 145, 6, 75, 73, 18, 168, 194, 168, 58, 39, 222, 170, 214, 75, 45, 218,
		39, 197, 242, 98, 22, 90, 255, 5, 144, 244, 252, 55, 98, 18, 135, 101, 27, 85, 215, 207,
		183, 28, 201, 142, 45, 122, 145, 159, 41, 243, 109, 29, 117, 203, 7, 234, 231, 214, 131, 133,
		217, 8, 74, 207, 130, 77, 21, 229, 167, 78, 218, 109, 142, 58, 134, 238, 29, 182, 178, 14,
		144, 129, 196, 219, 60, 128, 30, 105, 57, 53, 76, 122, 242, 208, 101, 241, 246, 99, 248, 67,
		137, 244, 70, 51, 202, 94, 164, 125, 115, 72, 61, 72, 129, 169, 155, 122, 91, 154, 160, 83,
		41, 102, 223, 218, 140, 40, 132, 16, 223, 92, 50, 230, 168, 47, 126, 117, 242, 136, 1, 245,
		171, 0, 36, 98, 73, 69, 14, 229, 66, 177, 108, 92, 39, 250, 243, 161, 111, 85, 211, 99,
		52, 98, 121, 188, 128, 201, 90, 205, 223, 92, 177, 19, 87, 18, 75, 54, 6, 81, 235, 137,
		247, 66, 211, 129, 247, 39, 119, 206, 116, 250, 113, 231, 190, 196, 53, 51, 34, 114, 39, 22,
		192, 33, 249, 151, 26, 22, 139, 97, 171, 238, 182, 88, 22, 176, 157, 255, 178, 199, 138, 98,
		140, 36, 112, 90, 25, 245, 134, 64, 48, 190, 165, 113, 24, 195, 84, 70, 175, 9, 179, 69,
	}
	local snow_vel = {
		57, 92, 100, 19, 100, 184, 238, 225, 55, 240, 255, 221, 215, 105, 226, 153, 164, 41, 22, 93,
		176, 203, 155, 199, 244, 52, 233, 219, 110, 227, 229, 227, 152, 240, 83, 248, 226, 31, 163, 22,
		28, 156, 18, 10, 248, 67, 123, 167, 25, 138, 90, 10, 79, 107, 208, 229, 248, 233, 185, 10,
		167, 21, 19, 178, 132, 154, 81, 70, 20, 71, 95, 147, 72, 27, 91, 189, 13, 189, 102, 84,
		195, 123, 251, 93, 68, 36, 178, 59, 107, 99, 104, 191, 76, 110, 44, 206, 123, 46, 98, 112,
		26, 50, 1, 35, 150, 17, 242, 208, 69, 23, 202, 197, 59, 80, 136, 124, 40, 89, 11, 40,
		1, 136, 90, 72, 198, 83, 2, 174, 174, 4, 28, 205, 135, 35, 194, 54, 22, 40, 4, 132,
		191, 88, 163, 66, 204, 230, 35, 111, 9, 177, 254, 174, 163, 68, 5, 88, 111, 235, 58, 236,
		4, 248, 172, 154, 101, 164, 43, 223, 10, 13, 210, 125, 146, 73, 192, 57, 117, 152, 128, 36,
		106, 21, 253, 113, 110, 133, 244, 4, 150, 32, 76, 71, 22, 106, 210, 244, 46, 128, 27, 215,
		231, 112, 177, 196, 198, 120, 196, 57, 234, 74, 235, 108, 64, 181, 209, 188, 177, 63, 197, 200,
		126, 164, 136, 163, 48, 62, 225, 223, 212, 201, 195, 121, 90, 7, 10, 196, 88, 53, 39, 249,
		147, 98, 65, 253, 246, 3, 152, 125, 242, 105, 44, 129, 94, 232, 13, 4, 86, 220, 194, 67,
		186, 210, 171, 197, 64, 138, 89, 78, 58, 150, 52, 79, 138, 201, 244, 111, 106, 181, 192, 69,
		234, 253, 239, 113, 98, 37, 209, 151, 60, 47, 241, 235, 185, 52, 173, 94, 172, 182, 47, 150,
		80, 118, 10, 58, 161, 237, 10, 64, 238, 198, 14, 74, 132, 250, 234, 63, 169, 86, 158, 170,
		76, 168, 124, 133, 28, 203, 246, 140, 228, 77, 50, 53, 115, 113, 157, 218, 90, 192, 28, 209,
		72, 117, 156, 101, 226, 99, 11, 245, 69, 59, 17, 175, 164, 59, 8, 166, 163, 185, 10, 60,
		100, 19, 26, 38, 114, 232, 180, 115, 238, 184, 88, 103, 178, 67, 212, 21, 87, 64, 85, 1,
		62, 87, 155, 62, 21, 96, 205, 195, 131, 97, 191, 252, 218, 209, 179, 201, 12, 2, 234, 110,
	}
	local data, vel, num_snow, snow_timer, santa_pos, santa_next_t, snow_mover
	function effects.snow_init()
		data, vel = {}, {}

		for i = 0, 399 do
			data[i] = bit.band(bit.lshift(snow_data[i + 1], 8), 0xFFFF)
			vel[i] = bit.band(snow_vel[i + 1], 0xF7)
		end

		-- the gui config load (guifuncs.c) sets NumSnow = 200 and SnowTimer = 0, the 30 second ramp is only the first run default
		num_snow, snow_timer, santa_pos, santa_next_t, snow_mover = 200, 0, 272, 36 * 15, 0
	end

	local function process_snow_velocity()
		if num_snow == 200 then
			if santa_next_t ~= 0 then
				santa_next_t = santa_next_t - 1
			else
				santa_pos = santa_pos - 1

				if santa_pos == 0 then
					santa_pos = 272
					santa_next_t = 36 * 60
				end
			end
		else
			snow_timer = snow_timer - 1

			if snow_timer == 0 then
				num_snow = num_snow + 1
				snow_timer = 18
			end
		end

		for i = 0, num_snow - 1 do
			data[i * 2] = bit.band(data[i * 2] + vel[i * 2], 0xFFFF)
			data[i * 2 + 1] = bit.band(data[i * 2 + 1] + vel[i * 2 + 1] + 256, 0xFFFF)

			if data[i * 2 + 1] <= 0x200 then vel[i * 2] = bit.bor(vel[i * 2], 8) end
		end
	end

	function effects.snow_step(cmd, dt)
		snow_mover = snow_mover + dt * SNOW_RATE

		while snow_mover >= 1 do
			snow_mover = snow_mover - 1
			process_snow_velocity()
		end

		for i = 0, 199 do
			if bit.band(vel[i * 2], 8) ~= 0 then
				aux_data[i] = bit.rshift(data[i * 2 + 1], 8) * W + bit.rshift(data[i * 2], 8) + 16
				aux_data[200 + i] = 228 + bit.band(vel[i * 2], 3)
			else
				aux_data[i] = 0xFFFFFFFF
			end
		end

		upload_aux(0, 400)
		local p = get_pipelines()
		p.snow.current_santa_on = santa_enabled and 1 or 0
		p.snow.current_santa_pos = santa_pos
		p.snow:Bind(cmd, {storage = {idx_image}, buffers = {aux_buffer}, sampled = {scene_texture}})
		p.snow:DispatchForSize(cmd, W, H, 1)
		barrier(cmd)
	end
end

do
	local xstart, xend = 0, 287
	local flame
	local frame

	function effects.burn_init(cmd)
		flame = {}

		for i = 0, W - 1 do
			flame[i] = 0
		end

		frame = 0
		clear(cmd, page_a)
		clear(cmd, page_b)
	end

	function effects.burn_step(cmd)
		-- the bottom row of the flame buffer is the flame array as it was at the start of the frame
		for i = 0, W - 1 do
			aux_data[i] = flame[i]
		end

		upload_aux(0, W)
		frame = frame + 1
		local p = get_pipelines()
		p.burn.current_frame = frame
		p.burn:Bind(cmd, {storage = {page_a, page_b, idx_image}, buffers = {aux_buffer}, sampled = {scene_texture}})
		p.burn:DispatchForSize(cmd, W, H, 1)
		barrier(cmd)
		page_a, page_b = page_b, page_a

		if math.random(0, 149) == 0 then
			local start = xstart + math.random(0, xend - xstart - 6)

			for i = start, start + 4 do
				flame[i] = 255
			end
		end

		for i = xstart, xend do
			local x = flame[i]

			if x < 50 then
				if x > 10 then x = x + math.random(0, 2) end
			else
				x = x + (math.random(0, 40) - 20) + 1
			end

			if x > 255 then x = 255 end

			flame[i] = x
		end

		-- smoothen, in place and left to right like the original
		for i = xstart + 1, xend - 1 do
			flame[i] = math.floor((flame[i - 1] + flame[i] + flame[i + 1]) / 3)
		end
	end
end

do
	local HOTSPOTS = 80
	local hotspot
	local fire_line = {}

	local function draw_bottom_line_of_fire()
		for i = 0, W - 1 do
			fire_line[i] = 0
		end

		for k = 1, HOTSPOTS do
			local hs = hotspot[k]

			for x = hs - 20, hs + 19 do
				if x >= 0 and x < W then
					fire_line[x] = math.min(fire_line[x] + 20 - math.abs(hs - x), 255)
				end
			end

			hs = hs + math.random(0, 7) - 3

			if hs < 0 then hs = hs + W elseif hs >= W then hs = hs - W end

			hotspot[k] = hs
		end
	end

	function effects.smoke_init(cmd)
		hotspot = {}

		for k = 1, HOTSPOTS do
			hotspot[k] = math.random(0, W - 1)
		end

		clear(cmd, page_a)
		clear(cmd, page_b)
		local p = get_pipelines()

		for round = 0, H - 1 do
			draw_bottom_line_of_fire()

			for i = 0, W - 1 do
				aux_data[round * W + i] = fire_line[i]
			end
		end

		upload_aux(0, W * H)

		for round = 0, H - 1 do
			p.smoke.current_line_offset = round * W
			p.smoke:Bind(cmd, {storage = {page_a, page_b, idx_image}, buffers = {aux_buffer}, sampled = {scene_texture}})
			p.smoke:DispatchForSize(cmd, W, H, 1)
			barrier(cmd)
			page_a, page_b = page_b, page_a
		end
	end

	function effects.smoke_step(cmd)
		draw_bottom_line_of_fire()

		for i = 0, W - 1 do
			aux_data[i] = fire_line[i]
		end

		upload_aux(0, W)
		local p = get_pipelines()
		p.smoke.current_line_offset = 0
		p.smoke:Bind(cmd, {storage = {page_a, page_b, idx_image}, buffers = {aux_buffer}, sampled = {scene_texture}})
		p.smoke:DispatchForSize(cmd, W, H, 1)
		barrier(cmd)
		page_a, page_b = page_b, page_a
	end
end

do
	local f32 = ffi.new("float[1]")
	local PHEIGHT, RADIUS = 400, 30
	local LUT_BASE = 64
	local BLOB_TYPES = {
		{rad = 3, height = -1200},
		{rad = 4, height = -2000},
		{rad = RADIUS, height = -PHEIGHT * 6},
	}
	local ox, oy, xang, yang, surfer, blobs

	local function fsin(x)
		return FSIN[bit.band(x, 2047)]
	end

	function effects.water_init(cmd, rain)
		surfer = not rain
		ox, oy, xang, yang = 80, 60, 0, 0
		clear(cmd, page_a)
		clear(cmd, page_b)

		local offset = LUT_BASE

		for _, blob in ipairs(BLOB_TYPES) do
			blob.offset = offset
			f32[0] = 1024 / blob.rad
			local q = f32[0]
			f32[0] = q * q
			local length = f32[0]
			local height = (blob.height < 0 and math.ceil or math.floor)(blob.height / 8)

			for square = 0, blob.rad * blob.rad - 1 do
				f32[0] = square * length
				local dist = math.floor(math.sqrt(f32[0]))
				aux_data[offset + square] = bit.arshift((FCOS[bit.band(dist, 2047)] + 0xffff) * height, 19)
			end

			offset = offset + blob.rad * blob.rad
		end

		upload_aux(LUT_BASE, offset - LUT_BASE)
	end

	local function sine_blob(x, y, type_index)
		local blob = BLOB_TYPES[type_index]
		local rad = blob.rad
		local left, right, top, bottom = -rad, rad, -rad, rad

		if x - rad < 1 then left = left - (x - rad - 1) end

		if y - rad < 1 then top = top - (y - rad - 1) end

		if x + rad > W - 1 then right = right - (x + rad - W + 1) end

		if y + rad > H - 1 then bottom = bottom - (y + rad - H + 1) end

		local o = 1 + blobs * 8
		aux_data[o], aux_data[o + 1], aux_data[o + 2], aux_data[o + 3] = x, y, left, right
		aux_data[o + 4], aux_data[o + 5], aux_data[o + 6], aux_data[o + 7] = top, bottom, blob.offset, rad * rad
		blobs = blobs + 1
	end

	function effects.water_step(cmd)
		blobs = 0

		if surfer then
			local x = W / 2 + bit.arshift(
					bit.arshift(fsin(bit.arshift(xang * 65, 8)), 8) * bit.arshift(fsin(bit.arshift(xang * 349, 8)), 8) * ((W - 8) / 2),
					16
				)
			local y = H / 2 + bit.arshift(
					bit.arshift(fsin(bit.arshift(yang * 377, 8)), 8) * bit.arshift(fsin(bit.arshift(yang * 84, 8)), 8) * ((H - 8) / 2),
					16
				)
			xang = xang + 13
			yang = yang + 12
			sine_blob(math.floor((ox + x) / 2), math.floor((oy + y) / 2), 1)
			sine_blob(x, y, 2)
			ox, oy = x, y
		elseif math.random(0, 13) == 7 then
			sine_blob(math.random(0, W - 3) + 1, math.random(0, H - 3) + 1, 3)
		end

		aux_data[0] = blobs
		upload_aux(0, 1 + blobs * 8)
		local p = get_pipelines()
		p.water:Bind(cmd, {storage = {page_a, page_b, idx_image}, buffers = {aux_buffer}, sampled = {scene_texture}})
		p.water:DispatchForSize(cmd, W, H, 1)
		barrier(cmd)
		p.water_blobs:Bind(cmd, {storage = {page_a}, buffers = {aux_buffer}})
		p.water_blobs:DispatchForSize(cmd, W, H, 1)
		barrier(cmd)
		page_a, page_b = page_b, page_a
	end
end

local initialized_effect
local accumulator = 0

local function init_effect(cmd)
	initialized_effect = current

	if current == 1 then
		effects.snow_init()
	elseif current == 2 or current == 3 then
		effects.water_init(cmd, current == 3)
	elseif current == 4 then
		effects.burn_init(cmd)
	else
		effects.smoke_init(cmd)
	end

end

local function create_resources()
	local storage_usage = {"storage", "sampled", "transfer_src", "transfer_dst"}
	idx_image = create_image("r32_uint", storage_usage)
	page_a = create_image("r32_uint", storage_usage)
	page_b = create_image("r32_uint", storage_usage)
	screen_image = create_image("r8g8b8a8_unorm", storage_usage, "nearest", VIEW_W, H)
	aux_buffer = Buffer.New{
		device = render.GetDevice(),
		size = AUX_WORDS * 4,
		usage = {"storage_buffer"},
	}
	aux_buffer:CopyData(aux_data, AUX_WORDS * 4)
end

event.AddListener("PreFrame", "zsnes_screensaver", function(dt)
	if not current then return end

	if not idx_image then create_resources() end

	local pipeline = render3d.pipelines and render3d.pipelines.blit_compute
	local framebuffer = pipeline and pipeline:GetFramebuffer()
	scene_texture = framebuffer and framebuffer:GetAttachment(1)
	scene_active = scene_texture and 1 or 0
	scene_texture = scene_texture or render.GetErrorTexture()

	accumulator = math.min(accumulator + dt, 3 / STEP_RATE)
	local steps = math.floor(accumulator * STEP_RATE)
	local first = initialized_effect ~= current

	if steps < 1 and not first then return end

	accumulator = accumulator - steps / STEP_RATE
	steps = math.max(steps, 1)

	for step = 1, steps do
		render.ExecuteCommand(function(cmd)
			if scene_active == 1 then
				cmd:PipelineBarrier{srcStage = "fragment", dstStage = "compute", memoryBarrier = true}
			end

			if initialized_effect ~= current then init_effect(cmd) end

			if current == 1 then
				effects.snow_step(cmd, 1 / STEP_RATE)
			elseif current == 2 or current == 3 then
				effects.water_step(cmd)
			elseif current == 4 then
				effects.burn_step(cmd)
			else
				effects.smoke_step(cmd)
			end

			if step == steps then
				local p = get_pipelines()
				p.present:Bind(cmd, {storage = {idx_image, screen_image}})
				p.present:DispatchForSize(cmd, VIEW_W, H, 1)
				render.TransitionResourceToShaderRead(screen_image, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
			end
		end)
	end
end)

function M.Start(index)
	current = index
end

function M.Stop()
	current = nil
end

function M.Draw(x, y, w, h)
	if not screen_image or initialized_effect ~= current then return end

	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(screen_image)
	render2d.SetColorUV(0, 1, 1, 0)
	render2d.DrawRect(x, y, w, h)
	render2d.SetColorUV(0, 0, 1, 1)
end

return M
