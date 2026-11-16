local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local perf = import("lua/perf.lua")
local react = import("goluwa/render2d/ui/react.lua")
local slice_color = import("lua/gpu_slice_color.lua")
local WIDTH, HEIGHT = 660, 430
local PLOT_X, PLOT_W = 84, 560
local PLOT_Y = 52
local ROW_H = 18
local CONTAINER_H = 6
local LANE_GAP = 16
local TEXT = Color(0.84, 0.87, 0.94, 1)
local TEXT_DIM = Color(0.5, 0.55, 0.65, 1)
local STEPS = {0.5, 1, 2, 5, 10, 20, 50}
local SMOOTHING = 0.08
local CHECK_X, CHECK_Y, CHECK_W, CHECK_H = WIDTH - 100, 12, 84, 20
local frozen
local average = false
local smoothed = {}
local keys = {}

local function by_begin(a, b)
	return a.begin < b.begin
end

local META = Panel:CreateTemplate("gpu_timeline")
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "hand"}

function META.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

function META:OnMouseInput(button, press, local_pos)
	if not press or button ~= "button_1" then return true end

	if
		local_pos.x >= CHECK_X and
		local_pos.x <= CHECK_X + CHECK_W and
		local_pos.y >= CHECK_Y and
		local_pos.y <= CHECK_Y + CHECK_H
	then
		average = not average
		smoothed = {}
	else
		frozen = not frozen and gpu_timing.GetTimeline() or nil
	end

	return true
end

function META:OnDraw()
	local timeline = frozen or gpu_timing.GetTimeline()
	render2d.SetTexture(nil)
	render2d.SetColor(0.03, 0.04, 0.07, 0.92)
	render2d.DrawRoundedRect(0, 0, WIDTH, HEIGHT, 10)
	render2d.DrawText{
		text = "timeline",
		x = 16,
		y = 24,
		size = 14,
		foreground_color = TEXT,
	}
	render2d.SetColor(0.5, 0.55, 0.65, 1)
	render2d.DrawRect(CHECK_X, CHECK_Y + 4, 12, 12)
	render2d.SetColor(0.03, 0.04, 0.07, 1)
	render2d.DrawRect(CHECK_X + 1, CHECK_Y + 5, 10, 10)

	if average then
		render2d.SetColor(0.45, 0.8, 0.95, 1)
		render2d.DrawRect(CHECK_X + 3, CHECK_Y + 7, 6, 6)
	end

	render2d.DrawText{
		text = "average",
		x = CHECK_X + 20,
		y = CHECK_Y + 10,
		align_y = "cap_center",
		size = 12,
		foreground_color = TEXT_DIM,
	}

	if not timeline then return end

	local range = 0

	for _, lane in ipairs(timeline.lanes) do
		table.sort(lane.spans, by_begin)
		table.clear(keys)

		for _, span in ipairs(lane.spans) do
			local key = lane.name .. span.name
			local count = (keys[key] or 0) + 1
			keys[key] = count
			key = key .. count
			local b, f = span.begin - timeline.begin, span.finish - timeline.begin

			if average then
				local state = smoothed[key]

				if not state then
					state = {b = b, f = f}
					smoothed[key] = state
				elseif not frozen then
					state.b = math.lerp(SMOOTHING, state.b, b)
					state.f = math.lerp(SMOOTHING, state.f, f)
				end

				b, f = state.b, state.f
			end

			span.b, span.f = b, f
			range = math.max(range, f)
		end
	end

	local scale = PLOT_W / range
	local color_index = {}

	for i, group in ipairs(gpu_timing.GetGroups()) do
		color_index[group.id] = i
	end

	local mouse = self.mouse_input:GetMousePosition()
	local hovered
	local y = PLOT_Y
	local plot_bottom = y

	for _, lane in ipairs(timeline.lanes) do
		if #lane.spans > 0 then
			local row_ends = {}
			local lane_rows = 0

			for _, span in ipairs(lane.spans) do
				span.x = PLOT_X + span.b * scale
				span.w = math.max((span.f - span.b) * scale, 1)

				if span.container then
					span.y = y
					span.h = CONTAINER_H
				else
					local row = 1

					while row_ends[row] and row_ends[row] > span.b do
						row = row + 1
					end

					row_ends[row] = span.f
					lane_rows = math.max(lane_rows, row)
					span.y = y + CONTAINER_H + 2 + (row - 1) * ROW_H
					span.h = ROW_H - 2
				end

				if
					self.mouse_input.Hovered and
					mouse.x >= span.x and
					mouse.x <= span.x + span.w and
					mouse.y >= span.y and
					mouse.y <= span.y + span.h
				then
					hovered = span
				end
			end

			lane.y = y
			y = y + CONTAINER_H + 2 + lane_rows * ROW_H + LANE_GAP
			plot_bottom = y
		end
	end

	local step = STEPS[#STEPS]

	for _, candidate in ipairs(STEPS) do
		if range / candidate <= 12 then
			step = candidate

			break
		end
	end

	for tick = 0, range, step do
		local x = PLOT_X + tick * scale
		render2d.SetColor(1, 1, 1, 0.07)
		render2d.DrawRect(x, PLOT_Y - 4, 1, plot_bottom - PLOT_Y + 4)
		render2d.DrawText{
			text = string.format("%g", tick),
			x = x + 3,
			y = plot_bottom + 2,
			size = 11,
			foreground_color = TEXT_DIM,
		}
	end

	for _, lane in ipairs(timeline.lanes) do
		if #lane.spans > 0 then
			render2d.DrawText{
				text = lane.name,
				x = 16,
				y = lane.y + CONTAINER_H + 2 + ROW_H / 2,
				align_y = "cap_center",
				size = 12,
				foreground_color = TEXT_DIM,
			}

			for _, span in ipairs(lane.spans) do
				if span.container then
					render2d.SetColor(0.45, 0.5, 0.62, 1)
				else
					local r, g, b = slice_color(color_index[span.group] or 1, 0)
					render2d.SetColor(r, g, b, hovered and hovered ~= span and 0.55 or 1)
				end

				render2d.DrawRect(span.x, span.y, span.w, span.h)

				if not span.container then
					local label = gpu_timing.GetLabel(span.name):lower()
					local label_w = render2d.GetTextSize(label, nil, 11)

					if label_w + 6 < span.w then
						render2d.DrawText{
							text = label,
							x = span.x + 3,
							y = span.y + span.h / 2,
							align_y = "cap_center",
							size = 11,
							foreground_color = Color(0.04, 0.05, 0.08, 1),
						}
					end
				end
			end
		end
	end

	render2d.DrawText{
		text = string.format("ms, %.2f ms span", range),
		x = PLOT_X,
		y = 24,
		size = 12,
		foreground_color = TEXT_DIM,
	}
	local footer = frozen and "frozen, click to resume" or "click to freeze"

	if hovered then
		footer = string.format(
			"%s  %.3f ms  start %.2f  end %.2f",
			gpu_timing.GetLabel(hovered.name):lower(),
			hovered.f - hovered.b,
			hovered.b,
			hovered.f
		)
	end

	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawText{
		text = footer,
		x = 16,
		y = HEIGHT - 24,
		size = 12,
		foreground_color = TEXT_DIM,
	}
end

META:Register()
local GpuTimeline = react.Element(META)
perf.RegisterTab("TIMELINE", 1.5, react.Component(||->GpuTimeline{Size = Vec2(WIDTH, HEIGHT)}))
