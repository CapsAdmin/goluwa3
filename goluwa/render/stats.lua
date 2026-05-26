local ffi = require("ffi")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local stats = {}
local current = {}
local last_second = {}
local FRAMETIME_HISTORY_SIZE = 120
local frametime_history = ffi.new("float[?]", FRAMETIME_HISTORY_SIZE)
local frametime_history_count = 0
local frametime_history_head = 0
local registered_groups = {}
local registered_group_order = {}
local registered_fields = {}
local registered_field_order = {}
local registered_glyphs = {}
local compiled_fields = {}
local compiled_entries = {}
local compiled_glyph_order = ""
local compiled_glyph_masks = {}
local glyph_index_by_byte = {}
local overlay_config = {
	field_order = nil,
	extra_glyphs = "",
	group_indent = "  ",
}
local public = {
	current = current,
	last_second = last_second,
	history = frametime_history,
	history_size = FRAMETIME_HISTORY_SIZE,
	history_count = 0,
	history_head = 0,
	overlay = {
		config = overlay_config,
		fields = compiled_fields,
		entries = compiled_entries,
		glyphs = compiled_glyph_order,
	},
}
local window_start = 0
local started = false
local suppress_depth = 0
local overlay_pipeline
local overlay_lines = {}
local overlay_state_dirty = true
local overlay_constants_type = ffi.typeof([[
	struct {
		float rect[4];
		float viewport[4];
		float color[4];
		int32_t data[4];
	}
]])
local overlay_constants = overlay_constants_type()
local OVERLAY_PADDING = 12
local CHAR_WIDTH = 10
local CHAR_HEIGHT = 12
local CHAR_ADVANCE = 12
local LINE_HEIGHT = 14
local SHADOW_OFFSET = 1
local GRAPH_HEIGHT = 72
local GRAPH_BAR_WIDTH = 3
local GRAPH_BAR_GAP = 1
local GRAPH_MS_MAX = 50
local GRAPH_GRID_MINOR_MS = 16.6667
local GRAPH_GRID_MAJOR_MS = 33.3333
local BUILTIN_GLYPH_ORDER = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local BUILTIN_GLYPH_MASKS = {
	488166958,
	432148639,
	487701279,
	487786030,
	73759815,
	1057949230,
	261047854,
	1041317000,
	488064558,
	488160324,
	145292849,
	1025459774,
	488129070,
	1025033790,
	1057964575,
	1057964560,
	488132142,
	589284913,
	1044517023,
	505645644,
	594303537,
	554189343,
	599643697,
	597481075,
	488162862,
	1025047056,
	488166989,
	1025047121,
	487983662,
	1044516996,
	588826158,
	588589188,
	588830378,
	581052977,
	588583044,
	1041441311,
}

local function pack_glyph(rows)
	local value = 0

	for y = 1, #rows do
		local row = rows[y]

		for x = 1, #row do
			if row:sub(x, x) == "1" then
				local bit_index = 4 - (x - 1) + (y - 1) * 5
				value = bit.bor(value, bit.lshift(1, bit_index))
			end
		end
	end

	return value
end

local function register_builtin_glyphs()
	for i = 1, #BUILTIN_GLYPH_ORDER do
		registered_glyphs[BUILTIN_GLYPH_ORDER:sub(i, i)] = BUILTIN_GLYPH_MASKS[i]
	end

	registered_glyphs["."] = pack_glyph{
		"00000",
		"00000",
		"00000",
		"00000",
		"01100",
		"01100",
	}
	registered_glyphs[":"] = pack_glyph{
		"00000",
		"01100",
		"01100",
		"00000",
		"01100",
		"01100",
	}
	registered_glyphs["-"] = pack_glyph{
		"00000",
		"00000",
		"11111",
		"00000",
		"00000",
		"00000",
	}
	registered_glyphs["/"] = pack_glyph{
		"00001",
		"00010",
		"00100",
		"01000",
		"10000",
		"00000",
	}
	registered_glyphs["_"] = pack_glyph{
		"00000",
		"00000",
		"00000",
		"00000",
		"00000",
		"11111",
	}
	registered_glyphs["("] = pack_glyph{
		"00010",
		"00100",
		"01000",
		"01000",
		"00100",
		"00010",
	}
	registered_glyphs[")"] = pack_glyph{
		"01000",
		"00100",
		"00010",
		"00010",
		"00100",
		"01000",
	}
	registered_glyphs["+"] = pack_glyph{
		"00000",
		"00100",
		"11111",
		"00100",
		"00000",
		"00000",
	}
	registered_glyphs[","] = pack_glyph{
		"00000",
		"00000",
		"00000",
		"00000",
		"00100",
		"01000",
	}
end

register_builtin_glyphs()

local function reset_bucket(bucket)
	bucket.seconds = 0
	bucket.frames = 0
	bucket.fps = 0
	bucket.frametime_sum = 0
	bucket.frametime_avg = 0
	bucket.frametime_min = 0
	bucket.frametime_max = 0
	bucket.pipeline_switches = 0
	bucket.bytes_uploaded = 0
	bucket.upload_calls = 0
	bucket.draw_calls = 0
	bucket.descriptor_writes = 0
	bucket.descriptor_update_calls = 0
end

local function ensure_started(now)
	if started then return end

	started = true
	window_start = now or system.GetElapsedTime()
	reset_bucket(current)
	reset_bucket(last_second)
end

local function should_ignore_counters()
	return suppress_depth > 0
end

local function record_frametime_history(dt)
	frametime_history[frametime_history_head] = dt
	frametime_history_head = (frametime_history_head + 1) % FRAMETIME_HISTORY_SIZE

	if frametime_history_count < FRAMETIME_HISTORY_SIZE then
		frametime_history_count = frametime_history_count + 1
	end

	public.history_count = frametime_history_count
	public.history_head = frametime_history_head
end

local function publish_window(now)
	local elapsed = now - window_start

	if elapsed <= 0 then return end

	last_second.seconds = elapsed
	last_second.frames = current.frames
	last_second.fps = current.frames / elapsed
	last_second.frametime_sum = current.frametime_sum
	last_second.frametime_avg = current.frames > 0 and current.frametime_sum / current.frames or 0
	last_second.frametime_min = current.frames > 0 and current.frametime_min or 0
	last_second.frametime_max = current.frametime_max
	last_second.pipeline_switches = current.pipeline_switches
	last_second.bytes_uploaded = current.bytes_uploaded
	last_second.upload_calls = current.upload_calls
	last_second.draw_calls = current.draw_calls
	last_second.descriptor_writes = current.descriptor_writes
	last_second.descriptor_update_calls = current.descriptor_update_calls
	reset_bucket(current)
	window_start = now
end

local function get_display_bucket()
	if last_second.frames > 0 then return last_second end

	return current
end

local function round_positive(value)
	return math.floor((value or 0) + 0.5)
end

local function format_bytes(value)
	value = tonumber(value) or 0
	local unit_index = 1
	local units = {"B", "KB", "MB", "GB"}

	while value >= 1024 and unit_index < #units do
		value = math.floor((value + 512) / 1024)
		unit_index = unit_index + 1
	end

	return tostring(value) .. " " .. units[unit_index]
end

local function format_integer(value)
	return tostring(round_positive(value))
end

local function format_frametime_ms(value)
	return tostring(round_positive((tonumber(value) or 0) * 1000)) .. " MS"
end

local function append_unique_character(chars, char)
	if char == " " or char == "" then return chars end

	if not chars[char] then chars[char] = true end

	return chars
end

local function collect_required_glyphs(chars, text)
	text = tostring(text or ""):upper()

	for i = 1, #text do
		append_unique_character(chars, text:sub(i, i))
	end

	return chars
end

local function clear_overlay_lines(start_index)
	for i = start_index, #overlay_lines do
		overlay_lines[i] = nil
	end
end

local function append_field_to_compiled(out, seen, required_chars, id)
	if seen[id] then return end

	local field = registered_fields[id]

	if not field or field.enabled == false then return end

	seen[id] = true
	out[#out + 1] = field
	collect_required_glyphs(required_chars, field.label)
	collect_required_glyphs(required_chars, field.glyphs)
end

local function append_group_entry(out, required_chars, group_id)
	local group = registered_groups[group_id]

	if not group or group.enabled == false then return nil end

	out[#out + 1] = {
		kind = "group",
		id = group.id,
		label = group.label,
		group = group,
	}
	collect_required_glyphs(required_chars, group.label)
	collect_required_glyphs(required_chars, group.glyphs)
	return group
end

local function rebuild_compiled_overlay_state()
	local seen = {}
	local out = {}
	local entry_count = 0
	local required_chars = {}
	local field_order = overlay_config.field_order
	local emitted_groups = {}

	if field_order then
		for i = 1, #field_order do
			append_field_to_compiled(out, seen, required_chars, field_order[i])
		end
	end

	for i = 1, #registered_field_order do
		append_field_to_compiled(out, seen, required_chars, registered_field_order[i])
	end

	for i = 1, #out do
		compiled_fields[i] = out[i]
	end

	for i = #out + 1, #compiled_fields do
		compiled_fields[i] = nil
	end

	for i = 1, #out do
		local field = out[i]
		local group = nil

		if field.group then
			group = registered_groups[field.group]

			if group and group.enabled ~= false and not emitted_groups[group.id] then
				emitted_groups[group.id] = true
				append_group_entry(compiled_entries, required_chars, group.id)
				entry_count = entry_count + 1
			end
		end

		entry_count = entry_count + 1
		compiled_entries[entry_count] = {
			kind = "field",
			field = field,
			indent = field.indent or
				(
					group and
					group.indent
				)
				or
				(
					field.group and
					overlay_config.group_indent
				)
				or
				"",
		}
	end

	for i = entry_count + 1, #compiled_entries do
		compiled_entries[i] = nil
	end

	collect_required_glyphs(required_chars, overlay_config.extra_glyphs)
	local glyph_order = BUILTIN_GLYPH_ORDER

	for i = 1, #overlay_config.extra_glyphs do
		local char = overlay_config.extra_glyphs:sub(i, i):upper()

		if char ~= " " and not glyph_order:find(char, 1, true) then
			if not registered_glyphs[char] then
				error("render.stats missing glyph for '" .. char .. "'", 2)
			end

			glyph_order = glyph_order .. char
		end
	end

	for char in pairs(required_chars) do
		if not glyph_order:find(char, 1, true) then
			if not registered_glyphs[char] then
				error("render.stats missing glyph for '" .. char .. "'", 2)
			end

			glyph_order = glyph_order .. char
		end
	end

	if compiled_glyph_order ~= glyph_order then
		compiled_glyph_order = glyph_order

		for i = 1, #compiled_glyph_order do
			local char = compiled_glyph_order:sub(i, i)
			compiled_glyph_masks[i] = registered_glyphs[char]
		end

		for i = #compiled_glyph_order + 1, #compiled_glyph_masks do
			compiled_glyph_masks[i] = nil
		end

		for i = 0, 255 do
			glyph_index_by_byte[i] = nil
		end

		for i = 1, #compiled_glyph_order do
			glyph_index_by_byte[compiled_glyph_order:byte(i)] = i - 1
		end

		public.overlay.glyphs = compiled_glyph_order
		overlay_pipeline = nil
	end

	public.overlay.fields = compiled_fields
	public.overlay.entries = compiled_entries
	overlay_state_dirty = false
end

local function ensure_overlay_state()
	if overlay_state_dirty then rebuild_compiled_overlay_state() end
end

local function build_overlay_line(field, bucket)
	local value

	if field.getter then
		value = field.getter(bucket, public, field)
	elseif field.bucket_key then
		value = bucket[field.bucket_key]
	else
		value = field.value
	end

	if value == nil and field.default ~= nil then value = field.default end

	local text

	if field.formatter then
		text = field.formatter(value, bucket, public, field)
	elseif type(value) == "boolean" then
		text = value and "ON" or "OFF"
	elseif type(value) == "number" then
		text = format_integer(value)
	elseif value == nil then
		text = "-"
	else
		text = tostring(value)
	end

	text = tostring(text or "")

	if field.label and field.label ~= "" then
		if text == "" then return field.label end

		return field.label .. " " .. text
	end

	return text
end

local function build_overlay_entry_line(entry, bucket)
	if not entry then return nil end

	if entry.kind == "group" then return entry.label end

	if entry.kind == "field" then
		local line = build_overlay_line(entry.field, bucket)

		if not line or line == "" then return line end

		if entry.indent and entry.indent ~= "" then return entry.indent .. line end

		return line
	end

	return nil
end

local function rebuild_overlay_lines(bucket)
	ensure_overlay_state()
	local line_count = 0

	for i = 1, #compiled_entries do
		local line = build_overlay_entry_line(compiled_entries[i], bucket)

		if line and line ~= "" then
			line_count = line_count + 1
			overlay_lines[line_count] = tostring(line):upper()
		end
	end

	clear_overlay_lines(line_count + 1)
	return line_count
end

local function get_glyph_index(byte)
	if byte >= 97 and byte <= 122 then byte = byte - 32 end

	return glyph_index_by_byte[byte]
end

local function build_fragment_shader_character_table()
	local parts = {}

	for i = 1, #compiled_glyph_masks do
		parts[i] = tostring(compiled_glyph_masks[i])
	end

	return "const int CHARACTERS[] = int[" .. #parts .. "](" .. table.concat(parts, ",") .. ");"
end

local function build_overlay_fragment_shader()
	return [[
					#version 450

					layout(location = 0) in vec2 out_uv;
					layout(location = 0) out vec4 out_color;

					layout(push_constant) uniform Constants {
						vec4 rect;
						vec4 viewport;
						vec4 color;
						ivec4 data;
					} pc;

					]] .. build_fragment_shader_character_table() .. [[

					float chard(int digit, vec2 id) {
						if (digit < 0 || digit >= CHARACTERS.length()) return 0.0;
						if (id.x < 0.0 || id.y < 0.0 || id.x > 4.0 || id.y > 5.0) return 0.0;
						return float(1 & (CHARACTERS[digit] >> (4 - int(id.x) + int(id.y) * 5)));
					}

					void main() {
						if (pc.data.y == 0) {
							out_color = pc.color;
							return;
						}

						vec2 id = floor(out_uv * vec2(5.0, 6.0));
						float alpha = chard(pc.data.x, id);

						if (alpha <= 0.0) discard;

						out_color = vec4(pc.color.rgb, pc.color.a * alpha);
					}
				]]
end

local function get_overlay_pipeline()
	ensure_overlay_state()

	if overlay_pipeline and overlay_pipeline.IsValid and not overlay_pipeline:IsValid() then
		overlay_pipeline = nil
	end

	if overlay_pipeline then return overlay_pipeline end

	overlay_pipeline = render.CreateGraphicsPipeline{
		Blend = true,
		ColorWriteMask = {"r", "g", "b", "a"},
		CullMode = "none",
		DepthClamp = false,
		DepthTest = false,
		DepthWrite = false,
		Discard = false,
		DstAlphaBlendFactor = "one_minus_src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		FrontFace = "counter_clockwise",
		LineWidth = 1.0,
		LogicOp = "copy",
		LogicOpEnabled = false,
		PolygonMode = "fill",
		PrimitiveRestart = false,
		RasterizationSamples = "1",
		SrcAlphaBlendFactor = "one",
		SrcColorBlendFactor = "src_alpha",
		Topology = "triangle_list",
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450

					layout(location = 0) out vec2 out_uv;

					layout(push_constant) uniform Constants {
						vec4 rect;
						vec4 viewport;
						vec4 color;
						ivec4 data;
					} pc;

					vec2 positions[6] = vec2[](
						vec2(0.0, 0.0),
						vec2(1.0, 0.0),
						vec2(1.0, 1.0),
						vec2(0.0, 0.0),
						vec2(1.0, 1.0),
						vec2(0.0, 1.0)
					);

					void main() {
						vec2 uv = positions[gl_VertexIndex];
						vec2 pixel = pc.rect.xy + uv * pc.rect.zw;
						vec2 clip = vec2(
							(pixel.x / pc.viewport.x) * 2.0 - 1.0,
							1.0 - (pixel.y / pc.viewport.y) * 2.0
						);
						out_uv = uv;
						gl_Position = vec4(clip, 0.0, 1.0);
					}
				]],
				push_constants = {
					offset = 0,
					size = ffi.sizeof(overlay_constants_type),
				},
			},
			{
				type = "fragment",
				code = build_overlay_fragment_shader(),
				push_constants = {
					offset = 0,
					size = ffi.sizeof(overlay_constants_type),
				},
			},
		},
	}
	return overlay_pipeline
end

local function setup_overlay_constants(viewport_w, viewport_h, x, y, width, height, r, g, b, a, glyph, mode)
	overlay_constants.rect[0] = x
	overlay_constants.rect[1] = y
	overlay_constants.rect[2] = width
	overlay_constants.rect[3] = height
	overlay_constants.viewport[0] = viewport_w
	overlay_constants.viewport[1] = viewport_h
	overlay_constants.viewport[2] = 0
	overlay_constants.viewport[3] = 0
	overlay_constants.color[0] = r
	overlay_constants.color[1] = g
	overlay_constants.color[2] = b
	overlay_constants.color[3] = a
	overlay_constants.data[0] = glyph or 0
	overlay_constants.data[1] = mode or 1
	overlay_constants.data[2] = 0
	overlay_constants.data[3] = 0
end

local function draw_overlay_rect(
	cmd,
	pipeline,
	frame_index,
	viewport_w,
	viewport_h,
	x,
	y,
	width,
	height,
	r,
	g,
	b,
	a
)
	setup_overlay_constants(viewport_w, viewport_h, x, y, width, height, r, g, b, a, 0, 0)
	pipeline:PushConstants(cmd, {"vertex", "fragment"}, 0, overlay_constants)
	cmd:Draw(6, 1, 0, 0)
end

local function draw_overlay_glyph(cmd, pipeline, frame_index, viewport_w, viewport_h, glyph_index, x, y, r, g, b, a)
	setup_overlay_constants(viewport_w, viewport_h, x, y, CHAR_WIDTH, CHAR_HEIGHT, r, g, b, a, glyph_index, 1)
	pipeline:PushConstants(cmd, {"vertex", "fragment"}, 0, overlay_constants)
	cmd:Draw(6, 1, 0, 0)
end

local function get_frametime_history_value(index)
	if frametime_history_count == 0 then return 0 end

	local offset = (
			frametime_history_head - frametime_history_count + index
		) % FRAMETIME_HISTORY_SIZE

	if offset < 0 then offset = offset + FRAMETIME_HISTORY_SIZE end

	return frametime_history[offset]
end

local function draw_overlay_history(cmd, pipeline, frame_index, viewport_w, viewport_h, x, y, width, height)
	draw_overlay_rect(
		cmd,
		pipeline,
		frame_index,
		viewport_w,
		viewport_h,
		x,
		y,
		width,
		height,
		0.06,
		0.06,
		0.06,
		0.85
	)
	local guides = {
		GRAPH_GRID_MAJOR_MS,
		GRAPH_GRID_MINOR_MS,
	}

	for i = 1, #guides do
		local ms = guides[i]
		local normalized = math.min(ms / GRAPH_MS_MAX, 1)
		local guide_y = y + height - math.max(1, math.floor(normalized * (height - 2)))
		local alpha = i == 1 and 0.22 or 0.14
		local tone = i == 1 and 0.85 or 0.55
		local guide_height = i == 1 and 2 or 1
		local draw_y = math.max(y + 1, guide_y - math.floor((guide_height - 1) * 0.5))

		if draw_y + guide_height <= y + height - 1 then
			draw_overlay_rect(
				cmd,
				pipeline,
				frame_index,
				viewport_w,
				viewport_h,
				x + 1,
				draw_y,
				width - 2,
				guide_height,
				tone,
				tone,
				tone,
				alpha
			)
		end
	end

	if frametime_history_count == 0 then return end

	local stride = GRAPH_BAR_WIDTH + GRAPH_BAR_GAP
	local available_bars = math.max(1, math.floor((width - 2) / stride))
	local visible_bars = math.min(frametime_history_count, available_bars)
	local start_index = frametime_history_count - visible_bars

	for i = 0, visible_bars - 1 do
		local dt = get_frametime_history_value(start_index + i)
		local ms = dt * 1000
		local normalized = math.min(ms / GRAPH_MS_MAX, 1)
		local bar_height = math.max(1, math.floor(normalized * (height - 2)))
		local bar_x = x + 1 + i * stride
		local bar_y = y + height - 1 - bar_height
		local r = 0.35
		local g = 0.9
		local b = 0.45

		if ms > GRAPH_GRID_MAJOR_MS then
			r = 0.95
			g = 0.3
			b = 0.25
		elseif ms > GRAPH_GRID_MINOR_MS then
			r = 0.95
			g = 0.75
			b = 0.2
		end

		draw_overlay_rect(
			cmd,
			pipeline,
			frame_index,
			viewport_w,
			viewport_h,
			bar_x,
			bar_y,
			GRAPH_BAR_WIDTH,
			bar_height,
			r,
			g,
			b,
			0.95
		)
	end
end

function stats.RecordFrame(dt)
	local now = system.GetElapsedTime()
	ensure_started(now)
	record_frametime_history(dt)
	current.frames = current.frames + 1
	current.frametime_sum = current.frametime_sum + dt

	if current.frames == 1 or dt < current.frametime_min then
		current.frametime_min = dt
	end

	if dt > current.frametime_max then current.frametime_max = dt end

	current.seconds = now - window_start
	current.fps = current.seconds > 0 and current.frames / current.seconds or 0
	current.frametime_avg = current.frametime_sum / current.frames

	if current.seconds >= 1 then publish_window(now) end
end

function stats.PushIgnore()
	suppress_depth = suppress_depth + 1
end

function stats.PopIgnore()
	if suppress_depth > 0 then suppress_depth = suppress_depth - 1 end
end

function stats.DrawOverlay(cmd)
	if not cmd then return end

	local pipeline = get_overlay_pipeline()
	local size = render.GetRenderImageSize()
	local viewport_w = size.x
	local viewport_h = size.y
	local frame_index = render.GetCurrentFrame()
	local line_count = rebuild_overlay_lines(get_display_bucket())
	local max_chars = 0
	local panel_width
	local panel_height
	local graph_width = FRAMETIME_HISTORY_SIZE * (GRAPH_BAR_WIDTH + GRAPH_BAR_GAP) + 2
	local x
	local y = OVERLAY_PADDING

	if line_count == 0 then return end

	for i = 1, line_count do
		max_chars = math.max(max_chars, #overlay_lines[i])
	end

	panel_width = math.max(OVERLAY_PADDING * 2 + max_chars * CHAR_ADVANCE, OVERLAY_PADDING * 2 + graph_width)
	panel_height = OVERLAY_PADDING * 3 + line_count * LINE_HEIGHT + GRAPH_HEIGHT
	x = viewport_w - panel_width - OVERLAY_PADDING
	stats.PushIgnore()
	pipeline:Bind(cmd, frame_index)
	draw_overlay_rect(
		cmd,
		pipeline,
		frame_index,
		viewport_w,
		viewport_h,
		x,
		y,
		panel_width,
		panel_height,
		0,
		0,
		0,
		0.7
	)

	for line_index = 1, line_count do
		local line = overlay_lines[line_index]
		local pen_x = x + OVERLAY_PADDING
		local pen_y = y + OVERLAY_PADDING + (line_index - 1) * LINE_HEIGHT

		for i = 1, #line do
			local byte = line:byte(i)

			if byte == 32 then
				pen_x = pen_x + CHAR_ADVANCE
			else
				local glyph_index = get_glyph_index(byte)

				if glyph_index then
					draw_overlay_glyph(
						cmd,
						pipeline,
						frame_index,
						viewport_w,
						viewport_h,
						glyph_index,
						pen_x + SHADOW_OFFSET,
						pen_y + SHADOW_OFFSET,
						0,
						0,
						0,
						0.9
					)
					draw_overlay_glyph(
						cmd,
						pipeline,
						frame_index,
						viewport_w,
						viewport_h,
						glyph_index,
						pen_x,
						pen_y,
						1,
						1,
						1,
						1
					)
				end

				pen_x = pen_x + CHAR_ADVANCE
			end
		end
	end

	draw_overlay_history(
		cmd,
		pipeline,
		frame_index,
		viewport_w,
		viewport_h,
		x + OVERLAY_PADDING,
		y + OVERLAY_PADDING * 2 + line_count * LINE_HEIGHT,
		panel_width - OVERLAY_PADDING * 2,
		GRAPH_HEIGHT
	)
	stats.PopIgnore()
end

function stats.AddPipelineSwitches(count)
	if should_ignore_counters() then return end

	ensure_started()
	current.pipeline_switches = current.pipeline_switches + (count or 1)
end

function stats.AddUploadedBytes(byte_count)
	if should_ignore_counters() then return end

	ensure_started()
	current.bytes_uploaded = current.bytes_uploaded + (byte_count or 0)
	current.upload_calls = current.upload_calls + 1
end

function stats.AddDrawCalls(count)
	if should_ignore_counters() then return end

	ensure_started()
	current.draw_calls = current.draw_calls + (count or 1)
end

function stats.AddDescriptorWrites(write_count)
	if should_ignore_counters() then return end

	ensure_started()
	current.descriptor_writes = current.descriptor_writes + (write_count or 1)
	current.descriptor_update_calls = current.descriptor_update_calls + 1
end

function stats.Reset()
	started = false
	window_start = 0
	suppress_depth = 0
	frametime_history_count = 0
	frametime_history_head = 0
	public.history_count = 0
	public.history_head = 0
	reset_bucket(current)
	reset_bucket(last_second)
end

function stats.RegisterGlyph(char, glyph)
	if type(char) ~= "string" or #char ~= 1 then
		error("render.stats glyph key must be a single character", 2)
	end

	char = char:upper()

	if type(glyph) == "table" then glyph = pack_glyph(glyph) end

	if type(glyph) ~= "number" then
		error("render.stats glyph must be a packed integer or 5x6 row table", 2)
	end

	registered_glyphs[char] = glyph
	overlay_state_dirty = true
	return glyph
end

function stats.RegisterGroup(id, group)
	if type(id) == "table" then
		group = id
		id = group and group.id
	end

	if not id then error("render.stats group id is required", 2) end

	group = group or {}
	group.id = id
	group.label = group.label or tostring(id):upper()
	group.indent = group.indent == nil and overlay_config.group_indent or tostring(group.indent)
	registered_groups[id] = group
	local found = false

	for i = 1, #registered_group_order do
		if registered_group_order[i] == id then
			found = true

			break
		end
	end

	if not found then registered_group_order[#registered_group_order + 1] = id end

	overlay_state_dirty = true
	return group
end

function stats.UnregisterGroup(id)
	if not registered_groups[id] then return end

	registered_groups[id] = nil

	for i = 1, #registered_group_order do
		if registered_group_order[i] == id then
			table.remove(registered_group_order, i)

			break
		end
	end

	overlay_state_dirty = true
end

function stats.RegisterField(id, field)
	if type(id) == "table" then
		field = id
		id = field and field.id
	end

	if not id then error("render.stats field id is required", 2) end

	field = field or {}
	field.id = id
	field.label = field.label or tostring(id):upper()
	registered_fields[id] = field
	local found = false

	for i = 1, #registered_field_order do
		if registered_field_order[i] == id then
			found = true

			break
		end
	end

	if not found then registered_field_order[#registered_field_order + 1] = id end

	overlay_state_dirty = true
	return field
end

function stats.UnregisterField(id)
	if not registered_fields[id] then return end

	registered_fields[id] = nil

	for i = 1, #registered_field_order do
		if registered_field_order[i] == id then
			table.remove(registered_field_order, i)

			break
		end
	end

	overlay_state_dirty = true
end

function stats.SetOverlayConfig(config)
	config = config or {}
	overlay_config.extra_glyphs = tostring(config.extra_glyphs or ""):upper()
	overlay_config.group_indent = tostring(config.group_indent or "  ")
	overlay_config.field_order = nil

	if config.field_order then
		overlay_config.field_order = {}

		for i = 1, #config.field_order do
			overlay_config.field_order[i] = config.field_order[i]
		end
	end

	overlay_state_dirty = true
	return overlay_config
end

function stats.GetOverlayConfig()
	local config = {
		extra_glyphs = overlay_config.extra_glyphs,
		group_indent = overlay_config.group_indent,
		field_order = nil,
	}

	if overlay_config.field_order then
		config.field_order = {}

		for i = 1, #overlay_config.field_order do
			config.field_order[i] = overlay_config.field_order[i]
		end
	end

	return config
end

function stats.FormatBytes(value)
	return format_bytes(value)
end

function stats.Get()
	ensure_overlay_state()
	return public
end

stats.RegisterGroup{
	id = "render",
	label = "RENDER",
}
stats.RegisterGroup{
	id = "render3d_shadows",
	label = "RENDER3D SHADOWS",
}
stats.RegisterGroup{
	id = "render3d_instancing",
	label = "RENDER3D INSTANCING",
}
stats.RegisterField{
	id = "fps",
	label = "FPS",
	bucket_key = "fps",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "frame_ms",
	label = "FRAME",
	bucket_key = "frametime_avg",
	formatter = format_frametime_ms,
	glyphs = ".",
	group = "render",
}
stats.RegisterField{
	id = "pipeline_switches",
	label = "PIPELINES",
	bucket_key = "pipeline_switches",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "bytes_uploaded",
	label = "UPLOAD",
	bucket_key = "bytes_uploaded",
	formatter = format_bytes,
	group = "render",
}
stats.RegisterField{
	id = "upload_calls",
	label = "UPLOAD CALLS",
	bucket_key = "upload_calls",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "draw_calls",
	label = "DRAWS",
	bucket_key = "draw_calls",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "descriptor_writes",
	label = "DESC WRITES",
	bucket_key = "descriptor_writes",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "descriptor_update_calls",
	label = "DESC UPDATES",
	bucket_key = "descriptor_update_calls",
	formatter = format_integer,
	group = "render",
}
return stats
