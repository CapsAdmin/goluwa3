local players = import("goluwa/network/players.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local third_person = import("lua/third_person.lua")
local inventory_menu = import("lua/inventory_menu.lua")
local PANEL_WIDTH = 190
local PANEL_HEIGHT = 64
local MARGIN_X = 48
local MARGIN_Y = 84

event.AddListener("DrawHUD", "ammo_hud", function()
	local rig = players.GetLocal()

	if
		not (
			rig and
			rig:IsValid()
		) or
		third_person.IsDefaultHudReplaced(rig) or
		third_person.IsHudHidden() or
		inventory_menu.IsOpen()
	then
		return
	end

	local holder = rig.weapon_holder
	local entity = holder:GetWeapon("right")
	local weapon = entity and entity.weapon

	if not (weapon and weapon:UsesAmmo()) then return end

	local active = theme.active
	local text_color = active:GetColor("text_on_dark")
	local accent = active:GetColor("primary")
	local font, weight = active:GetTextStyle("body_strong")
	local screen_w, screen_h = render2d.GetSize()
	local S = screen_h / 1080
	local w, h = PANEL_WIDTH * S, PANEL_HEIGHT * S
	local x, y = screen_w - MARGIN_X * S - w, screen_h - MARGIN_Y * S - h
	local infinite = holder:IsAmmoInfinite()
	local count = weapon.ClipSize > 0 and weapon.Clip or holder:GetAmmoCount(weapon.AmmoType)
	active:DrawHudPanel(
		x,
		y,
		w,
		h,
		{alpha = 1, opacity = 0.6, accent = weapon:IsReloading() and accent or nil}
	)
	render2d.DrawText{
		text = infinite and weapon.ClipSize <= 0 and "-" or tostring(count),
		x = x + 18 * S,
		y = y + 10 * S,
		size = 36 * S,
		font = font,
		weight = weight,
		foreground_color = text_color,
		alpha = count == 0 and 0.4 or 1,
	}

	if weapon.ClipSize > 0 and not infinite then
		render2d.DrawText{
			text = "/ " .. holder:GetAmmoCount(weapon.AmmoType),
			x = x + 96 * S,
			y = y + 24 * S,
			size = 18 * S,
			font = font,
			weight = weight,
			foreground_color = text_color,
			alpha = 0.7,
		}
	end

	if weapon.SecondaryAmmoType ~= "" and not infinite then
		render2d.DrawText{
			text = "alt " .. holder:GetAmmoCount(weapon.SecondaryAmmoType),
			x = x + w - 14 * S,
			y = y + 8 * S,
			size = 14 * S,
			font = font,
			weight = weight,
			foreground_color = accent,
			alpha = 0.9,
			align_x = 1,
		}
	end

	if weapon:IsReloading() then
		render2d.DrawText{
			text = "reloading",
			x = x + w - 14 * S,
			y = y + h - 24 * S,
			size = 14 * S,
			font = font,
			weight = weight,
			foreground_color = text_color,
			alpha = 0.8,
			align_x = 1,
		}
	end
end)
