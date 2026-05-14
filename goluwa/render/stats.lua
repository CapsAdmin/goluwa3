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
local public = {
	current = current,
	last_second = last_second,
	history = frametime_history,
	history_size = FRAMETIME_HISTORY_SIZE,
	history_count = 0,
	history_head = 0,
}
local window_start = 0
local started = false
local suppress_depth = 0
local overlay_pipeline
local overlay_lines = {}
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
	local unit_index = 1
	local units = {"B", "KB", "MB", "GB"}

	while value >= 1024 and unit_index < #units do
		value = math.floor((value + 512) / 1024)
		unit_index = unit_index + 1
	end

	return tostring(value) .. " " .. units[unit_index]
end

local function rebuild_overlay_lines(bucket)
	overlay_lines[1] = "FPS " .. round_positive(bucket.fps)
	overlay_lines[2] = "FRAME " .. round_positive(bucket.frametime_avg * 1000) .. " MS"
	overlay_lines[3] = "PIPELINES " .. bucket.pipeline_switches
	overlay_lines[4] = "UPLOAD " .. format_bytes(bucket.bytes_uploaded)
	overlay_lines[5] = "UPLOAD CALLS " .. bucket.upload_calls
	overlay_lines[6] = "DRAWS " .. bucket.draw_calls
	overlay_lines[7] = "DESC WRITES " .. bucket.descriptor_writes
	overlay_lines[8] = "DESC UPDATES " .. bucket.descriptor_update_calls
	return 8
end

local function get_glyph_index(byte)
	if byte >= 48 and byte <= 57 then return byte - 48 end

	if byte >= 65 and byte <= 90 then return byte - 55 end

	return nil
end

local function get_overlay_pipeline()
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
				code = [[
					#version 450

					layout(location = 0) in vec2 out_uv;
					layout(location = 0) out vec4 out_color;

					layout(push_constant) uniform Constants {
						vec4 rect;
						vec4 viewport;
						vec4 color;
						ivec4 data;
					} pc;

					const int CHARACTERS[] = int[60](488166958,432148639,487701279,487786030,73759815,1057949230,261047854,1041317000,488064558,488160324,145292849,1025459774,488129070,1025033790,1057964575,1057964560,488132142,589284913,1044517023,505645644,594303537,554189343,599643697,597481075,488162862,1025047056,488166989,1025047121,487983662,1044516996,588826158,588589188,588830378,581052977,588583044,1041441311,198,139432064,31744,18157905,35787024,4539392,32506848,149360644,487657476,142876932,136382532,478421262,471926862,10813440,4333568,10813998,31,6212,545394753,490397199,589435185,368409920,145118798,138547332);

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
				]],
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

function stats.Get()
	return public
end

return stats
