local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local pvars = import("goluwa/cli/pvars.lua")
local scopes = import("goluwa/render3d/scopes.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local WIDTH = 640
local HEIGHT = 260
local HEADER = 36
local LABEL_WIDTH = 40
local PAD = 6

local SDR_CODES = {0, 128, 256, 384, 512, 640, 768, 896, 1023}
local HDR_NITS = {0, 10, 50, 100, 200, 500, 1000, 2000, 4000, 10000}

local function linear_to_srgb(x)
	return x <= 0.0031308 and x * 12.92 or 1.055 * x ^ (1 / 2.4) - 0.055
end

local function draw_waveform(visual)
	scopes.RequestWaveform()
	local size = visual.Owner.transform:GetSize()
	local font = theme.active:GetFont("body", "XS")
	local left, top = LABEL_WIDTH, PAD
	local width, height = size.x - LABEL_WIDTH - PAD, size.y - PAD * 2
	local range = scopes.GetRange()
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
	local texture = scopes.GetWaveformTexture()

	if texture and scopes.IsWaveformActive() then
		local columns = scopes.GetColumns()
		render2d.PushColorUV(0, 0, columns / texture:GetWidth(), columns / 2 / texture:GetHeight())
		render2d.SetTexture(texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(left, top, width, height)
		render2d.SetTexture(nil)
		render2d.PopColorUV()
	end

	local paper_white = pvars.Get("r_hdr_paper_white")

	for _, level in ipairs(range > 1 and HDR_NITS or SDR_CODES) do
		local value = range > 1 and linear_to_srgb(level / paper_white) or level / 1023

		if value <= range + 1e-6 then
			local y = top + height - height * value / range
			render2d.SetColor(0.75, 0.6, 0.15, level == 0 and 0.6 or 0.35)
			render2d.DrawRect(left, math.floor(y), width, 1)
			render2d.SetColor(0.85, 0.7, 0.2, 1)
			font:DrawText(tostring(level), 4, y - 6)
		end
	end

	if range > 1 then
		local y = math.floor(top + height - height / range)
		render2d.SetColor(1, 1, 1, 0.06)
		render2d.DrawRect(left, top, width, y - top)
		render2d.SetColor(1, 1, 1, 0.5)
		render2d.DrawRect(left, y, width, 1)
		render2d.SetColor(1, 1, 1, 0.7)
		font:DrawText("paper white", left + 4, y - 14)
	end
end

local function open_menu()
	local items = {}

	for _, columns in ipairs{128, 256, 512, 1024} do
		items[#items + 1] = MenuItem{
			Text = columns .. " x " .. columns / 2,
			Icon = scopes.GetColumns() == columns and "check" or nil,
			OnClick = function()
				scopes.SetColumns(columns)
			end,
		}
	end

	Panel.OpenContextMenu({}, items)
end

local function on_mouse_input(_, button, press)
	if button == "button_2" and press then
		open_menu()
		return true
	end
end

local HistogramView = react.Component(
	||-> do
		return ui.Panel{
			transform = true,
			layout = {GrowWidth = 1, GrowHeight = 1},
			mouse_input = {},
			visual = {OnDraw = draw_waveform},
			OnMouseInput = on_mouse_input,
		}
	end
)
local HistogramWindow = react.Component(
	||-> do
		local position = react.UseMemo(
			||-> do
				local world_size = Panel.World.transform:GetSize()
				return Vec2(world_size.x - WIDTH - 16, world_size.y - HEIGHT - HEADER - 16)
			end,
			{}
		)
		return ui.Window{
			Title = "HISTOGRAM",
			Pinnable = true,
			Padding = "none",
			Size = Vec2(WIDTH, HEIGHT + HEADER),
			MinSize = Vec2(240, 120),
			Position = position,
		}{HistogramView{}}
	end
)
desktop.RegisterProgram{
	Name = "Histogram",
	Icon = "palette",
	Positioned = true,
	Content = HistogramView,
	Create = function()
		return react.Mount(HistogramWindow{}, Panel.World):GetEntity()
	end,
}
