local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local weapons = import("lua/weapons.lua")
local inventory_menu = import("lua/inventory_menu.lua")
local third_person = import("lua/third_person.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
import("lua/inventory_ui.lua")
local FADE_SPEED = 7
local alpha = 0

local function draw_text(text, x, y, size, color, alpha, font, weight)
	render2d.DrawText{
		text = text,
		x = x,
		y = y,
		size = size,
		font = font,
		weight = weight,
		foreground_color = color,
		alpha = alpha,
	}
end

local function rarity_color(active, weapon)
	local color = weapons.Roller and weapons.Roller.GetColor(weapon.weapon.Rarity)
	return color or active:GetColor("neutral")
end

event.AddListener("DrawHUD", "inventory_hud", function()
	local target = inventory_menu.IsOpen() and 1 or 0
	alpha = math.clamp(alpha + (target - alpha) * math.min(system.GetFrameTime() * FADE_SPEED, 1), 0, 1)

	if alpha < 0.01 and target == 0 then
		alpha = 0
		return
	end

	local menu = inventory_menu.GetState()
	local subject = inventory_menu.GetSubject()
	local holder = subject.weapon_holder
	local active = theme.active
	local text_color = active:GetColor("text_on_dark")
	local gold = active:GetColor("gold")
	local strong_font, strong_weight = active:GetTextStyle("body_strong")
	local screen_w, screen_h = render2d.GetSize()
	local S = screen_h / 1080
	local focus = render3d and inventory_menu.GetSocketPosition(subject, menu.place)

	if focus then
		local screen = render3d.GetMainCamera():WorldPositionToScreen(focus, screen_w, screen_h)
		local current = holder:GetWeapon(menu.place)

		if screen then
			active:DrawReticle(
				screen.x,
				screen.y,
				46 * S,
				{kind = "use", alpha = alpha, time = system.GetElapsedTime()}
			)
			local title = current and current.weapon:GetTitle() or "Empty"
			local title_w = render2d.GetTextSize(title, strong_font, 22 * S, strong_weight)
			active:DrawHudPanel(
				screen.x + 40 * S,
				screen.y - 18 * S,
				title_w + 36 * S,
				36 * S,
				{alpha = alpha, opacity = 0.7, accent = gold}
			)
			draw_text(
				title,
				screen.x + 58 * S,
				screen.y - 11 * S,
				22 * S,
				current and rarity_color(active, current) or text_color,
				alpha,
				strong_font,
				strong_weight
			)
		end
	end
end)
