local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local pretext = import("goluwa/pretext/init.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local ARTICLE = [[
Pretext can already decide where each line should break. The missing piece for editorial layouts is a band-based flow pass that changes the available horizontal slots for each line. Once you subtract blocked intervals from the base region, the remaining slots become candidate text runs for that band.

This demo uses one animated circular obstacle and one fixed rectangular card. The text is reflowed every frame by asking pretext for the next line fragment that fits each remaining slot.
]]

local function rebuild_layout(view, size)
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
	view.region = region
	view.obstacles = {circle, card}
	view.flow = pretext.layout_flow(
		view.prepared,
		region,
		view.font:GetLineHeight() + 4,
		view.obstacles,
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

return {
	Name = "text flow",
	Section = "Graphics",
	Order = 2,
	View = react.Component(|| -> do
		local panel = react.UseRef()
		local view = react.UseMemo(|| -> do
			local font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 18}

			return {font = font, prepared = pretext.prepare(ARTICLE, font)}
		end, {})

		react.UseEvent("Update", || -> do
			if panel.current then rebuild_layout(view, panel.current.transform:GetSize()) end
		end)

		local draw = react.UseCallback(|flow| -> do
			local size = flow.transform:GetSize()
			render2d.SetTexture(nil)
			render2d.SetColor(0.05, 0.06, 0.08, 1)
			render2d.DrawRect(0, 0, size.x, size.y)
			render2d.SetColor(0.1, 0.11, 0.14, 1)
			render2d.DrawRect(20, 20, size.x - 40, size.y - 40)

			if not view.flow then return end

			render2d.SetColor(1, 1, 1, 0.03)
			render2d.DrawRect(view.region.x, view.region.y, view.region.width, view.region.height)

			for _, obstacle in ipairs(view.obstacles) do
				draw_obstacle(obstacle)
			end

			render2d.SetColor(0.9, 0.93, 0.98, 1)

			for _, line in ipairs(view.flow.lines) do
				view.font:DrawText(line.text, line.x, line.y)
			end
		end, {})

		return kit.Page{
			Title = "Text flow",
			Description = "Band based obstacle flow built on pretext.layout_next_line. The circle animates while the card stays fixed, and the text reflows around both every frame.",
		}{
			kit.Section{Title = "Obstacles", Framed = false}{
				ui.Panel{
					Ref = panel,
					transform = true,
					layout = {GrowWidth = 1, MinSize = Vec2(100, 420)},
					visual = true,
					OnDraw = draw,
				},
			},
		}
	end),
}
