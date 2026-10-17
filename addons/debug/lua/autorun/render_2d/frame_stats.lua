local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render_stats = import("goluwa/render/stats.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local perf = import("lua/perf.lua")
local WIDTH = 660
local GRAPH_HEIGHT = 110
local GRAPH_MS_MAX = 50
local GRID_MS = {16.6667, 33.3333}
local FrameGraph = Panel:CreateTemplate("frame_graph")
FrameGraph.CMP.transform = {}
FrameGraph.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
FrameGraph.CMP.visual = {}

function FrameGraph.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

function FrameGraph:OnDraw()
	local size = self.transform:GetSize()
	local stats = render_stats.Get()
	render2d.SetTexture(nil)
	render2d.SetColor(0.03, 0.04, 0.07, 0.92)
	render2d.DrawRoundedRect(0, 0, size.x, size.y, 10)
	local graph_x, graph_y = 12, 10
	local graph_w, graph_h = size.x - 24, size.y - 20
	render2d.SetColor(1, 1, 1, 0.12)

	for _, ms in ipairs(GRID_MS) do
		render2d.DrawRect(graph_x, graph_y + graph_h * (1 - ms / GRAPH_MS_MAX), graph_w, 1)
	end

	local count = stats.history_count
	local bar_w = graph_w / stats.history_size

	for i = 0, count - 1 do
		local index = (stats.history_head - count + i) % stats.history_size
		local ms = stats.history[index] * 1000
		local height = math.min(ms / GRAPH_MS_MAX, 1) * graph_h
		local over = ms > GRID_MS[2] and 1 or ms > GRID_MS[1] and 0.5 or 0
		render2d.SetColor(0.35 + over * 0.65, 0.8 - over * 0.5, 0.45 - over * 0.2, 0.9)
		render2d.DrawRect(graph_x + (stats.history_size - count + i) * bar_w, graph_y + graph_h - height, math.max(bar_w - 1, 1), height)
	end
end

FrameGraph:Register()

local function rows_of(in_group)
	return function()
		local rows = {}

		for _, row in ipairs(render_stats.GetRows()) do
			if (row.group == "render") == in_group then rows[#rows + 1] = row end
		end

		return rows
	end
end

local FrameGraphElement = react.Element(FrameGraph)
local render_rows = rows_of(true)
local other_rows = rows_of(false)

perf.RegisterTab(
	"FRAME",
	0,
	react.Component(|| -> ui.Column{layout = {ChildGap = "S", AlignmentX = "center"}}{
		FrameGraphElement{Size = Vec2(WIDTH, GRAPH_HEIGHT)},
		ui.StatTable{Size = Vec2(WIDTH, 316), Rows = react.UsePoll(render_rows, perf.POLL_INTERVAL)},
	})
)
perf.RegisterTab(
	"RENDER",
	3,
	react.Component(|| -> ui.StatTable{Size = Vec2(WIDTH, 470), Rows = react.UsePoll(other_rows, perf.POLL_INTERVAL)})
)

local counting = false

event.AddListener("Update", "perf_counters", function()
	local open = desktop.IsOpen("Perf")

	if open ~= counting then
		counting = open
		render.stats = open
	end
end)
