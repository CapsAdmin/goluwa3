local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Column = import("../elements/column.lua")
local Text = import("../elements/text.lua")
local Panel = import("goluwa/ecs/panel.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local system = import("goluwa/system.lua")
local pretext = import("goluwa/pretext/init.lua")
local ARTICLE = [[
Pretext can already decide where each line should break. The missing piece for editorial layouts is a band-based flow pass that changes the available horizontal slots for each line. Once you subtract blocked intervals from the base region, the remaining slots become candidate text runs for that band.

This demo uses one animated circular obstacle and one fixed rectangular card. The text is reflowed every frame by asking pretext for the next line fragment that fits each remaining slot.
]]

local function rebuild_layout(self, font, prepared, state)
	local size = self.transform.Size
	local t = system.GetElapsedTime()
	local region = {
		x = 28,
		y = 28,
		width = size.x - 56,
		height = size.y - 56,
	}
	local circle = {
		kind = "circle",
		cx = region.x + region.width * 0.52 + math.sin(t * 0.85) * region.width * 0.18,
		cy = region.y + region.height * 0.30 + math.cos(t * 1.10) * 34,
		radius = 52,
		horizontal_padding = 10,
		vertical_padding = 6,
	}
	local card = {
		kind = "rect",
		x = region.x + region.width * 0.10,
		y = region.y + region.height * 0.52,
		width = math.min(170, region.width * 0.34),
		height = 92,
		horizontal_padding = 12,
		vertical_padding = 8,
	}
	state.layout = pretext.layout_flow(
		prepared,
		region,
		font:GetLineHeight() + 4,
		{circle, card},
		{
			min_slot_width = 32,
			use_all_slots = true,
		}
	)
	state.region = region
	state.obstacles = {circle, card}
	state.band_height = font:GetLineHeight() + 4
end

local function draw_obstacle(obstacle)
	if obstacle.kind == "circle" then
		render2d.SetColor(0.95, 0.62, 0.18, 0.9)
		gfx.DrawFilledCircle(obstacle.cx, obstacle.cy, obstacle.radius)
		render2d.SetColor(1, 1, 1, 0.14)
		gfx.DrawCircle(obstacle.cx, obstacle.cy, obstacle.radius + 5, 2, 48)
	elseif obstacle.kind == "rect" then
		render2d.SetColor(0.18, 0.42, 0.74, 0.88)
		render2d.DrawRect(obstacle.x, obstacle.y, obstacle.width, obstacle.height)
		render2d.SetColor(1, 1, 1, 0.12)
		render2d.DrawRect(obstacle.x + 8, obstacle.y + 8, obstacle.width - 16, 20)
	end
end

return {
	Name = "text flow",
	Create = function()
		local font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 18}
		local prepared = pretext.prepare(ARTICLE, font)
		local state = {
			layout = nil,
		}
		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 16,
				Padding = Rect(20, 20, 20, 20),
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Band-based obstacle flow on top of pretext.layout_next_line. The circle animates; the blue card stays fixed.",
				Wrap = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Panel.New{
				transform = true,
				rect = true,
				Ref = function(self)
					self:AddGlobalEvent("Update")
					rebuild_layout(self, font, prepared, state)
				end,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(100, 420),
				},
				OnUpdate = function(self)
					rebuild_layout(self, font, prepared, state)
				end,
				OnDraw = function(self)
					local size = self.transform.Size + self.transform.DrawSizeOffset
					render2d.SetColor(0.05, 0.06, 0.08, 1)
					render2d.DrawRect(0, 0, size.x, size.y)
					render2d.SetColor(0.1, 0.11, 0.14, 1)
					render2d.DrawRect(20, 20, size.x - 40, size.y - 40)

					if not state.layout then return end

					render2d.SetColor(1, 1, 1, 0.03)
					render2d.DrawRect(state.region.x, state.region.y, state.region.width, state.region.height)

					for i = 1, #state.obstacles do
						draw_obstacle(state.obstacles[i])
					end

					render2d.SetColor(0.9, 0.93, 0.98, 1)

					for i = 1, #state.layout.lines do
						local line = state.layout.lines[i]
						font:DrawText(line.text, line.x, line.y)
					end

					render2d.SetColor(1, 1, 1, 0.06)
				end,
			},
		}
	end,
}
