local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local pretext = import("goluwa/pretext/init.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local ARTICLE = [[
Pretext can already decide where each line should break. The missing piece for editorial layouts is a band-based flow pass that changes the available horizontal slots for each line. Once you subtract blocked intervals from the base region, the remaining slots become candidate text runs for that band.

This demo uses one animated circular obstacle and one fixed rectangular card. The text is reflowed every frame by asking pretext for the next line fragment that fits each remaining slot.
]]

local function rebuild_layout(flow)
	local size = flow.transform:GetSize()
	local t = system.GetElapsedTime()
	local region = {x = 28, y = 28, width = size.x - 56, height = size.y - 56}
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
	flow.Region = region
	flow.Obstacles = {circle, card}
	flow.Flow = pretext.layout_flow(
		flow.Prepared,
		region,
		flow.FlowFont:GetLineHeight() + 4,
		flow.Obstacles,
		{min_slot_width = 32, use_all_slots = true}
	)
end

local function draw_obstacle(obstacle)
	if obstacle.kind == "circle" then
		render2d.SetColor(0.95, 0.62, 0.18, 0.9)
		render2d.DrawFilledCircle(obstacle.cx, obstacle.cy, obstacle.radius)
		render2d.SetColor(1, 1, 1, 0.14)
		render2d.DrawCircle(obstacle.cx, obstacle.cy, obstacle.radius + 5, 2, 48)
	else
		render2d.SetColor(0.18, 0.42, 0.74, 0.88)
		render2d.DrawRect(obstacle.x, obstacle.y, obstacle.width, obstacle.height)
		render2d.SetColor(1, 1, 1, 0.12)
		render2d.DrawRect(obstacle.x + 8, obstacle.y + 8, obstacle.width - 16, 20)
	end
end

local function on_update(flow)
	rebuild_layout(flow)
end

local function on_draw(flow)
	local size = flow.transform:GetSize()
	render2d.SetTexture(nil)
	render2d.SetColor(0.05, 0.06, 0.08, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.SetColor(0.1, 0.11, 0.14, 1)
	render2d.DrawRect(20, 20, size.x - 40, size.y - 40)

	if not flow.Flow then return end

	render2d.SetColor(1, 1, 1, 0.03)
	render2d.DrawRect(flow.Region.x, flow.Region.y, flow.Region.width, flow.Region.height)

	for _, obstacle in ipairs(flow.Obstacles) do
		draw_obstacle(obstacle)
	end

	render2d.SetColor(0.9, 0.93, 0.98, 1)

	for _, line in ipairs(flow.Flow.lines) do
		flow.FlowFont:DrawText(line.text, line.x, line.y)
	end
end

return {
	Name = "text flow",
	Section = "Graphics",
	Order = 2,
	Create = function()
		local font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 18}
		local flow = Panel.New{
			FlowFont = font,
			Prepared = pretext.prepare(ARTICLE, font),
			transform = true,
			layout = {
				GrowWidth = 1,
				MinSize = Vec2(100, 420),
			},
			visual = true,
			OnUpdate = on_update,
			OnDraw = on_draw,
		}
		flow:AddGlobalEvent("Update")
		rebuild_layout(flow)
		return kit.Page{
			Title = "Text flow",
			Description = "Band based obstacle flow built on pretext.layout_next_line. The circle animates while the card stays fixed, and the text reflows around both every frame.",
		}{
			kit.Section{Title = "Obstacles", Framed = false}{flow},
		}
	end,
}
