local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local gbuffer_inspect = import("goluwa/render3d/gbuffer_inspect.lua")
local entries = gbuffer_inspect.GetEntries()
local entry_glsl = {}
local target_glsl = {}

for _, entry in ipairs(entries) do
	entry_glsl[#entry_glsl + 1] = string.format("if (index == %d) return %s;", entry.index, entry.glsl)
end

local normal_indices = {}

for _, entry in ipairs(entries) do
	if entry.field and entry.field.kind == "octa" then
		normal_indices[#normal_indices + 1] = "index == " .. entry.index
	end
end

for i, target in ipairs(gbuffer_layout.targets) do
	target_glsl[#target_glsl + 1] = string.format(
		"if (index == %d) return gbuffer_fetch_nearest(GBUFFER.%s_tex, pixel);",
		i - 1,
		target.texture
	)
end

local shader = gbuffer_layout.GetDecodeGLSL("debug_data") .. ([[
	float gbuffer_view_distance(ivec2 pixel) {
		float depth = gbuffer_depth(pixel);
		vec2 ndc = (vec2(pixel) + 0.5) / debug_data.render_size * 2.0 - 1.0;
		vec4 view_position = debug_data.inv_projection * vec4(ndc, depth, 1.0);
		return length(view_position.xyz / view_position.w);
	}

	vec3 inspect_entry(int index, ivec2 pixel) {
		// the sky has no surface, its values are the gbuffer defaults
		if (index != %d && gbuffer_depth(pixel) == 1.0) return vec3(0.06);

		%s
		return vec3(0.0);
	}

	bool inspect_is_normal(int index) {
		return %s;
	}

	// the n-th entry of the sheet, the entries are bits of two masks
	int inspect_nth_entry(int n) {
		int seen = 0;

		for (int i = 0; i < 64; i++) {
			int bits = i < 32 ? debug_data.mask_low : debug_data.mask_high;

			if (((bits >> (i %% 32)) & 1) != 0) {
				if (seen == n) return i;

				seen++;
			}
		}

		return -1;
	}

	vec4 inspect_target(int index, ivec2 pixel) {
		%s
		return vec4(0.0);
	}

	void main() {
		ivec2 pixel = ivec2(gl_FragCoord.xy);
		vec3 shown = vec3(0.0);

		if (debug_data.mode == %d || debug_data.mode == %d) {
			int count = debug_data.count;
			int columns = max(int(ceil(sqrt(float(count)))), 1);
			int rows = (count + columns - 1) / columns;
			vec2 cell = debug_data.render_size / vec2(float(columns), float(rows));
			ivec2 tile = ivec2(gl_FragCoord.xy / cell);
			int index = tile.y * columns + tile.x;

			if (index < count) {
				vec2 local = (gl_FragCoord.xy - vec2(tile) * cell) / cell;
				ivec2 sample_pixel = ivec2(local * debug_data.render_size);

				if (debug_data.mode == %d) {
					shown = inspect_target(index, sample_pixel).rgb;
				} else {
					int entry = inspect_nth_entry(index);
					shown = entry >= 0 ? inspect_entry(entry, sample_pixel) : vec3(0.0);
				}

				if (min(min(local.x, local.y), min(1.0 - local.x, 1.0 - local.y)) < 0.004) shown = vec3(0.0);
			}
		} else if (debug_data.mode == %d) {
			shown = inspect_entry(debug_data.index, pixel);

			if (inspect_is_normal(debug_data.index)) {
				// a half sphere in the corner shaded like the surfaces, as seen from the camera: each pixel is the
				// normal a surface facing that way on screen would have. the map normal is tangent space, so its
				// sphere is not rotated into the world
				float radius = debug_data.render_size.y * 0.1;
				vec2 offset = vec2(debug_data.render_size.x - radius * 1.4, debug_data.render_size.y - radius * 1.4);
				vec2 d = (gl_FragCoord.xy - offset) / radius;
				d.y = -d.y;
				float len = length(d);

				if (len < 1.0) {
					vec3 view_normal = vec3(d, sqrt(1.0 - len * len));
					vec3 sphere = debug_data.normal_source == 2 ? view_normal : normalize(mat3(debug_data.inv_view) * view_normal);
					shown = sphere * 0.5 + 0.5;
				} else if (len < 1.04) {
					shown = vec3(0.0);
				}
			}
		} else {
			vec4 raw = inspect_target(debug_data.index, pixel);

			if (debug_data.channel == 0) shown = raw.rgb;
			else shown = vec3(raw[debug_data.channel - 1]);
		}

		set_color(vec4(shown, 1.0));
	}
]]):format(
	gbuffer_inspect.GetEntry("depth").index,
	(table.concat(entry_glsl, "\n\t\t"):gsub("GBUFFER%.", "debug_data.")),
	table.concat(normal_indices, " || "),
	(table.concat(target_glsl, "\n\t\t"):gsub("GBUFFER%.", "debug_data.")),
	gbuffer_inspect.SHEET,
	gbuffer_inspect.TARGETS,
	gbuffer_inspect.TARGETS,
	gbuffer_inspect.FIELD
)
return {
	{
		name = "gbuffer_inspect",
		is_enabled = function()
			return gbuffer_inspect.IsActive()
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "debug_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						gbuffer_layout.block,
						{"mode", "int"},
						{"index", "int"},
						{"channel", "int"},
						{"normal_source", "int"},
						{"mask_low", "int"},
						{"mask_high", "int"},
						{"count", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						gbuffer_layout.WriteBlock(self, block)
						block.mode = gbuffer_inspect.GetMode()
						block.index = gbuffer_inspect.GetMode() == gbuffer_inspect.TARGET and
							gbuffer_inspect.GetTargetIndex() or
							gbuffer_inspect.GetEntryIndex()
						block.channel = gbuffer_inspect.GetChannelIndex()
						block.normal_source = gbuffer_inspect.GetNormalSourceIndex()
						block.mask_low, block.mask_high, block.count = gbuffer_inspect.GetTileMask()
						return block
					end,
				},
			},
			shader = shader,
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
