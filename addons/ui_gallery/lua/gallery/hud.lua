local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Markup = import("goluwa/render2d/markup.lua")
local MarkupLabel = import("goluwa/render2d/ui/elements/markup_label.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local BAR_SIZE = Vec2(260, 16)
local CANVAS = 130

local function bar(props)
	return ui.ProgressBar(
		table.merge(
			{
				layout = {GrowWidth = 0, MinSize = BAR_SIZE, MaxSize = BAR_SIZE},
				transform = {Size = BAR_SIZE},
			},
			props
		)
	)
end

local TrailBar = react.Component(
	||-> do
		local time, set_time = react.UseState(0)
		react.UseEvent("Update", |dt|->set_time(|value|->(value + dt) % 4))
		local value = 1

		if time >= 1.5 and time < 2 then
			value = 0.45
		elseif time >= 2 then
			value = 0.45 + (time - 2) * 0.275
		end

		return bar{Value = value, Color = "positive", GhostColor = "negative", Trail = true}
	end
)

local function draw_reticle(canvas)
	local now = system.GetElapsedTime()
	render2d.SetTexture(nil)
	render2d.SetColor(0.12, 0.14, 0.18, 1)
	render2d.DrawRoundedRect(0, 0, CANVAS, CANVAS, 6)
	local pulse = canvas.Pulse and math.max(1 - (now % 1.2) / 0.35, 0) or 0
	theme.active:DrawReticle(
		CANVAS / 2,
		CANVAS / 2,
		canvas.Kind == "crosshair" and 5 or 70 + pulse * 30,
		{kind = canvas.Kind, alpha = 1, time = now, blocked = canvas.Blocked}
	)
end

local function draw_backdrop(canvas)
	render2d.SetTexture(nil)
	render2d.SetColor(0.12, 0.14, 0.18, 1)
	render2d.DrawRoundedRect(0, 0, canvas.transform:GetSize().x, CANVAS, 6)
end

local function draw_panels(canvas)
	draw_backdrop(canvas)
	local active = theme.active
	active:DrawHudPanel(14, 14, 190, 40, {})
	active:DrawHudPanel(14, 70, 190, 40, {accent = "primary"})
	active:DrawHudPanel(220, 14, 90, 40, {opacity = 0.8, accent = "positive", accent_side = "bottom"})
	active:DrawHudPanel(220, 70, 90, 40, {opacity = 0.55, accent = "neutral", accent_side = "bottom", accent_from = 0.5})
	active:DrawHudPanel(316, 14, 90, 40, {opacity = 0.55, accent = "primary", accent_side = "bottom", accent_to = 0.5})
	active:DrawHudPanel(316, 70, 90, 40, {opacity = 0.2})
end

local function draw_keycap(canvas)
	draw_backdrop(canvas)
	theme.active:DrawKeycap(20, 20, 40, 36, "E", 22, 1)
	theme.active:DrawKeycap(80, 20, 60, 36, "LMB", 18, 1)
	theme.active:DrawKeycap(20, 76, 40, 36, "R", 22, 0.5)
end

local function hud_canvas(draw, width, height)
	return ui.Panel{
		transform = {Size = Vec2(width, height)},
		layout = {MinSize = Vec2(width, height), MaxSize = Vec2(width, height)},
		visual = true,
		OnDraw = draw,
	}
end

local WORLD_W, WORLD_H = 400, 170
local COMPLETIONS = {"!give weapon_sword", "!give weapon_pistol", "!goto spawn", "!god"}

local function draw_messy_background()
	local seed = 12345

	local function rand()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	render2d.SetTexture(nil)
	render2d.SetColor(0.55, 0.5, 0.4, 1)
	render2d.DrawRect(0, 0, WORLD_W, WORLD_H)

	for i = 1, 90 do
		local shade = rand()
		render2d.SetColor(shade, shade * (0.6 + rand() * 0.4), shade * (0.4 + rand() * 0.6), 1)
		local w, h = 10 + rand() * 70, 4 + rand() * 40
		render2d.DrawRect(rand() * (WORLD_W - w), rand() * (WORLD_H - h), w, h)
	end

	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(WORLD_W * 0.55, 0, WORLD_W * 0.2, WORLD_H)
	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(WORLD_W * 0.8, 0, WORLD_W * 0.2, WORLD_H)
end

local function draw_chat(canvas)
	if not canvas.markup then
		canvas.markup = Markup.New()
		canvas.markup:SetEditable(false)
		canvas.markup:SetSelectable(false)
		canvas.markup:AddString(
			"<color=0.4,0.8,1>Alice</color>: anyone seen the key?\n<color=1,0.5,0.4>Bob</color>: behind the red door\n<color=0.5,1,0.5>Carol</color>: !give weapon_sword\nthe quick brown fox jumps over the lazy dog",
			true
		)
	end

	draw_messy_background()
	render2d.PushMatrix(10, 10)
	MarkupLabel.SyncTheme(canvas.markup, "M", true, canvas.WorldText)
	canvas.markup:SetMaxWidth(WORLD_W - 20)
	canvas.markup:Update()
	canvas.markup:Draw()
	render2d.PopMatrix()
end

local function draw_completions(canvas)
	draw_messy_background()
	local active = theme.active
	local font = active:GetFont("body", "M")
	local plain = active:GetColor("text", {surface = "surface"})
	local _, line_h = font:GetTextSize("Ag")

	for i, text in ipairs(COMPLETIONS) do
		local y = 10 + (i - 1) * (line_h + 8)

		if canvas.WorldText then
			active:DrawWorldText(font, text, 10, y, nil, i == 1 and 1 or 0.75)
		else
			render2d.PushColor(plain.r, plain.g, plain.b, 1)
			font:DrawText(text, 10, y)
			render2d.PopColor()
		end
	end
end

local function world_canvas(draw, world)
	return ui.Panel{
		WorldText = world,
		transform = {Size = Vec2(WORLD_W, WORLD_H)},
		layout = {MinSize = Vec2(WORLD_W, WORLD_H), MaxSize = Vec2(WORLD_W, WORLD_H)},
		visual = true,
		OnDraw = draw,
	}
end

local function reticle(kind, pulse, blocked)
	return ui.Panel{
		Kind = kind,
		Pulse = pulse,
		Blocked = blocked,
		transform = {Size = Vec2(CANVAS, CANVAS)},
		layout = {MinSize = Vec2(CANVAS, CANVAS), MaxSize = Vec2(CANVAS, CANVAS)},
		visual = true,
		OnDraw = draw_reticle,
	}
end

return {
	Name = "hud",
	Section = "HUD",
	Order = 1,
	View = react.Component(
		||-> do
			return kit.Page{
			Title = "Heads up display",
			Description = "Progress bars and the use and target reticle are drawn by the active theme, so the game hud follows whichever theme is loaded.",
		}{
			kit.Section{
				Title = "Progress bar states",
				Description = "Value is 0..1. Color takes a palette token or a Color. The trail option holds a ghost behind drops in the value, segments sets the tick count.",
			}{
				kit.Wrap{
					kit.Labeled("Empty", bar{Value = 0}),
					kit.Labeled("Low, negative", bar{Value = 0.18, Color = "negative"}),
					kit.Labeled("Half, neutral", bar{Value = 0.5, Color = "neutral"}),
					kit.Labeled("Healthy, positive", bar{Value = 0.8, Color = "positive"}),
					kit.Labeled("Full", bar{Value = 1}),
				},
			},
			kit.Section{
				Title = "Segments and trail",
				Description = "Segments = 0 draws a solid bar. The trailing bar drops by 55% every few seconds.",
			}{
				kit.Wrap{
					kit.Labeled("Segments = 0", bar{Value = 0.65, Segments = 0}),
					kit.Labeled("Segments = 5", bar{Value = 0.65, Segments = 5}),
					kit.Labeled("Segments = 20", bar{Value = 0.65, Segments = 20}),
					kit.Labeled("Trail", TrailBar{}),
				},
			},
			kit.Section{
				Title = "Reticle",
				Description = "theme.active:DrawReticle(x, y, size, {kind, alpha, time}). Kind is use for something you can interact with and target for a lock on. A locked target that can also be used shows the target reticle.",
			}{
				kit.Wrap{
					kit.Labeled("use", reticle("use")),
					kit.Labeled("use, just used", reticle("use", true)),
					kit.Labeled("target", reticle("target")),
					kit.Labeled("target, just used", reticle("target", true)),
					kit.Labeled("crosshair", reticle("crosshair")),
					kit.Labeled("crosshair, blocked", reticle("crosshair", false, true)),
				},
			},
			kit.Section{
				Title = "Text over the world",
				Description = "The chat overlay and autocomplete list draw straight onto the game world. theme.active:GetWorldTextStyle() gives the light foreground, dark outline and glow they use, and DrawWorldText and Markup.Halo apply it. Left is plain theme text, right is world text, over a busy background with white and black patches.",
			}{
				kit.Wrap{
					kit.Labeled("chat, plain theme text", world_canvas(draw_chat, false)),
					kit.Labeled("chat, world text", world_canvas(draw_chat, true)),
					kit.Labeled("autocomplete, plain theme text", world_canvas(draw_completions, false)),
					kit.Labeled("autocomplete, world text", world_canvas(draw_completions, true)),
				},
			},
			kit.Section{
				Title = "Panels and prompts",
				Description = "theme.active:DrawHudPanel(x, y, w, h, {alpha, opacity, accent, accent_side, accent_from, accent_to}) backs the killfeed, vehicle readout, toolgun help and weapon cells. theme.active:DrawKeycap(x, y, w, h, text, size, alpha) draws a key in the use prompt.",
			}{
				kit.Wrap{
					kit.Labeled("panel states", hud_canvas(draw_panels, 420, CANVAS)),
					kit.Labeled("keycap", hud_canvas(draw_keycap, 160, CANVAS)),
				},
			},
			}
		end
	),
}
