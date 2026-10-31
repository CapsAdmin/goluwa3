local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
local JRPGTheme = import("goluwa/render2d/ui/themes/jrpg.lua")
local jrpg = import("lua/jrpg/jrpg.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local weapon_categories = import("lua/weapon_categories.lua")
local hitmarkers = import("lua/hitmarkers.lua")
local targeting = import("lua/targeting.lua")
local third_person = import("lua/third_person.lua")

function third_person.IsDefaultHudReplaced(rig)
	return rig.rpg ~= nil
end

local visual_bounds = import("lua/visual_bounds.lua")
local Health = import("lua/components/health.lua")
local HEADING = "Orbitron"
local BODY = "Exo"
local BOLD = "Bold"
local INK = Color.FromHex("#04060d")
local STEEL = Color.FromHex("#2e5876")
local WHITE = Color.FromHex("#eef4ff")
local MUTED = Color.FromHex("#8fa8c8")
local NEON = jrpg.Colors.neon
local GOLD = jrpg.Colors.gold
local DANGER = jrpg.Colors.danger
local NAME_GLOW = NAME_GLOW
local LEVEL_COLOR = Color(0.75, 0.55, 1, 1)
local LEVEL_GLOW = Color(0.25, 0.1, 0.4, 1)
local NPC_LOW = Color(0.95, 0.75, 0.2, 1)
local DEFEAT_COLOR = Color(1, 0.35, 0.3, 1)
local DEFEAT_GLOW = Color(0.4, 0, 0, 1)
local BARS = {
	{
		key = "health",
		label = "HP",
		color = jrpg.Colors.health,
		trail = Color(1, 0.3, 0.28, 1),
	},
	{
		key = "mana",
		label = "MP",
		color = jrpg.Colors.mana,
		trail = Color(0.55, 0.8, 1, 1),
	},
	{
		key = "stamina",
		label = "SP",
		color = jrpg.Colors.stamina,
		trail = Color(1, 0.92, 0.55, 1),
	},
}
local NPC_TRAIL = Color(1, 0.3, 0.28, 1)
local BAR_HEIGHT = 15
local BAR_GAP = 5
local BAR_SKEW = 10
local XP_HEIGHT = 6
local NPC_WIDTH = 110
local NPC_TARGET_WIDTH = 170
local NPC_HEIGHT = 6
local NPC_LIFT = 0.25
local NPC_VISIBLE_TIME = 6
local NPC_FADE_TIME = 0.5
local NPC_LINGER = 2.5
local TRAIL_DELAY = 0.6
local TRAIL_SPEED = 0.8
local SMOOTH_SPEED = 8
local style
local vignette
local bounds = AABB(0, 0, 0, 0, 0, 0)
local smoothed = {}
local records = table.weak("k")
local tracked = {}

local function get_style()
	if not style then
		style = JRPGTheme:CreateObject()
		style:Initialize()
	end

	return style
end

local function get_vignette()
	if vignette then return vignette end

	vignette = Texture.New{
		width = 256,
		height = 256,
		format = "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	vignette:Shade[[
		vec2 p = uv * 2.0 - 1.0;
		float v = smoothstep(0.7, 1.45, length(p * vec2(1.0, 1.15)));
		return vec4(vec3(v), v);
	]]
	return vignette
end

local function smooth(key, target, dt, speed)
	local value = smoothed[key] or target
	value = value + (target - value) * math.min(dt * (speed or SMOOTH_SPEED), 1)
	smoothed[key] = value
	return value
end

local function text(str, x, y, font, size, color, alpha, align_x, glow)
	local w, h = render2d.GetTextSize(str, font, size, BOLD)
	render2d.DrawText{
		text = str,
		x = x - w * (align_x or 0),
		y = y,
		font = font,
		weight = BOLD,
		size = size,
		foreground_color = color,
		background_color = glow or INK,
		softness = glow and 5 or 3,
		blur_intensity = 2.5,
		outline_width = math.max(size * 0.08, 1.5),
		outline_color = glow or INK,
		alpha = alpha or 1,
	}
	return w, h
end

local function set_color(color, alpha)
	render2d.SetColor(color.r, color.g, color.b, alpha)
end

local TRAIL_FADE = render2d.CreateGradient{
	width = 64,
	height = 1,
	angle = 90,
	stops = {
		{pos = 0, color = Color(1, 1, 1, 1)},
		{pos = 1, color = Color(1, 1, 1, 0.3)},
	},
}

local function draw_skewed_bar(x, y, w, h, skew, fraction, ghost, ghost_color, color, alpha, segments)
	local theme = get_style()
	render2d.PushWorldMatrix()
	render2d.Translatef(x, y + h)
	render2d.Shear(-skew / h, 0)
	render2d.Translatef(0, -h)
	render2d.SetTexture(nil)
	set_color(INK, 0.82 * alpha)
	render2d.DrawRect(-2, -2, w + 4, h + 4)
	render2d.SetColor(1, 1, 1, 0.05 * alpha)
	render2d.DrawRect(0, 0, w, h * 0.5)
	local fill = w * math.clamp(fraction, 0, 1)

	if ghost > fraction + 0.001 then
		set_color(ghost_color, 0.8 * alpha)
		render2d.SetTexture(TRAIL_FADE)
		render2d.DrawRect(fill, 0, w * math.min(ghost, 1) - fill, h)
		render2d.SetTexture(nil)
	end

	if fill > 0.5 then
		set_color(color, alpha)
		render2d.DrawRect(0, 0, fill, h)
		render2d.SetColor(0, 0, 0, 0.18 * alpha)
		render2d.DrawRect(0, h * 0.55, fill, h * 0.45)
		render2d.SetTexture(nil)
		render2d.SetColor(1, 1, 1, 0.35 * alpha)
		render2d.DrawRect(0, 0, fill, math.max(h * 0.18, 1))
	end

	if segments then
		for i = 1, segments - 1 do
			local tick_x = math.floor(w * i / segments)
			render2d.SetColor(0, 0, 0, 0.35 * alpha)
			render2d.DrawRect(tick_x, 1, 1, h - 2)
			render2d.SetColor(1, 1, 1, 0.22 * alpha)
			render2d.DrawRect(tick_x, 1, 1, math.max(h * 0.25, 2) - 1)
		end
	end

	set_color(STEEL, 0.95 * alpha)
	render2d.DrawRect(-2, -2, w + 4, 1)
	render2d.DrawRect(-2, h + 1, w + 4, 1)
	render2d.DrawRect(-2, -2, 1, h + 4)
	render2d.DrawRect(w + 1, -2, 1, h + 4)
	render2d.PushBlendPreset("additive")
	set_color(color, 0.3 * alpha)
	theme:DrawGlowLine(-8, -2, w + 8, -2, 3)
	theme:DrawGlowLine(-8, h + 2, w + 8, h + 2, 3)
	render2d.PopBlendMode()

	if fill > 0.5 then
		render2d.PushBlendPreset("additive")
		set_color(color, 0.9 * alpha)
		theme:DrawGlowLine(fill, -h * 0.6, fill, h * 1.6, math.max(h * 0.5, 3))
		render2d.SetColor(1, 1, 1, 0.9 * alpha)
		theme:DrawGlowLine(fill, -h * 0.2, fill, h * 1.2, math.max(h * 0.18, 1.5))
		render2d.PopBlendMode()
	end

	render2d.PopWorldMatrix()
end

local function draw_status_icons(component, x, y, size, alpha, align_right)
	if not component then return end

	local theme = get_style()
	local now = system.GetElapsedTime()

	for _, definition in ipairs(status_effects.List) do
		local amount = component.amounts[definition.Name]

		if amount then
			local cx = align_right and x - size / 2 or x + size / 2
			local cy = y + size / 2
			local fade = alpha * math.min(amount * 4, 1)
			render2d.SetTexture(nil)
			set_color(INK, 0.85 * fade)
			theme:DrawDiamond(cx, cy, size * 1.05)
			render2d.PushBlendPreset("additive")
			local pulse = 0.75 + 0.25 * math.sin(now * 5)
			set_color(definition.Color, 0.35 * fade * pulse)
			theme:DrawDiamond(cx, cy, size * 1.3)
			set_color(definition.Color, fade)
			theme:DrawDiamond(cx, cy, size * 0.9 * math.min(amount, 1) ^ 0.5)
			render2d.PopBlendMode()
			render2d.SetTexture(nil)
			set_color(GOLD, fade)
			theme:DrawDiamond2(cx, cy, size * 1.05)
			text(
				definition.Label,
				cx,
				cy + size * 0.55,
				HEADING,
				math.floor(size * 0.36),
				WHITE,
				fade,
				0.5
			)
			x = align_right and x - size - 4 or x + size + 4
		end
	end
end

local radial_wheel = {}
radial_wheel.__index = radial_wheel

function radial_wheel.New(config)
	local self = setmetatable(table.shallow_copy(config), radial_wheel)
	self.poly = Polygon2D.New(4096)
	self.poly.WorldMatrixMultiply = true
	self.visible = {}
	self.visible_count = 0
	self.scroll_key = self.Name .. "_scroll"
	return self
end

function radial_wheel:Scroll(selected, count, dt)
	local last = self.last_selected or selected
	local target = self.scroll_target or selected

	if selected ~= last then
		target = target + math.wrapped_delta(last, selected, count)
	end

	self.last_selected = selected
	self.scroll_target = target
	return smooth(self.scroll_key, target, dt, 10)
end

function radial_wheel:Collect(items, count, scroll, selected)
	local visible = self.visible
	local range = self.Range
	local n = 0

	for i = 1, count do
		local offset = math.wrapped_offset(i, scroll, count, range)

		while offset < range do
			local fade = math.max(1 - math.abs(offset) / range, 0) ^ 2

			if fade > 0.01 then
				n = n + 1
				local entry = visible[n]

				if not entry then
					entry = {}
					visible[n] = entry
				end

				entry.offset = offset
				entry.fade = fade
				entry.scale = self.ScaleFalloff ^ math.abs(offset)
				entry.selected = i == selected and math.abs(offset) < 0.5
				self.FillEntry(entry, items, i, count)
			end

			offset = offset + count
		end
	end

	self.visible_count = n
end

function radial_wheel:PushEntry(entry, cx, cy, step, mid)
	render2d.PushWorldMatrix()
	render2d.Translatef(cx, cy)
	render2d.Rotate(entry.offset * step)
	render2d.ScaleAround(entry.scale, entry.scale, mid, 0)
end

function radial_wheel:Draw(items, count, scroll, selected, cx, cy, S, theme, accent)
	self:Collect(items, count, scroll, selected)
	local visible = self.visible
	local step = math.pi * 2 / math.max(count, self.MinSlots)
	local cos_half = math.cos(step / 2)
	local inner = self.Inner * S
	local outer = self.Outer * S
	local mid = (inner + outer) / 2

	for n = 1, self.visible_count do
		local entry = visible[n]
		self:PushEntry(entry, cx, cy, step, mid)
		local color = entry.wedge_color
		self.poly:BatchArc(
			0,
			0,
			inner / cos_half,
			outer / cos_half,
			-step / 2,
			step / 2,
			1,
			self.Feather,
			INK.r,
			INK.g,
			INK.b,
			0.5 * entry.fade
		)
		self.poly:BatchArc(
			0,
			0,
			inner / cos_half,
			outer / cos_half,
			-step / 2,
			step / 2,
			1,
			self.Feather,
			color.r,
			color.g,
			color.b,
			(entry.selected and 0.55 or 0.3) * entry.fade
		)
		render2d.PopWorldMatrix()
	end

	render2d.SetTexture(self.FadeTexture)
	render2d.SetColor(1, 1, 1, 1)
	self.poly:FlushBatch()
	render2d.SetTexture(nil)

	for n = 1, self.visible_count do
		local entry = visible[n]

		if entry.group ~= entry.previous_group then
			self:PushEntry(entry, cx, cy, step, mid)
			render2d.Rotate(-step / 2)
			render2d.PushBlendPreset("additive")
			local r, g, b = self.DividerColor(entry.previous_group, entry.group)
			render2d.SetColor(r, g, b, 1.5 * entry.fade)
			theme:DrawGlowLine(inner / cos_half, 0, outer / cos_half, 0, 4 * S)
			render2d.PopBlendMode()
			render2d.PopWorldMatrix()
		end
	end

	for n = 1, self.visible_count do
		local entry = visible[n]
		self:PushEntry(entry, cx, cy, step, mid)

		if entry.selected then
			render2d.PushBlendPreset("additive")
			render2d.SetTexture(theme.GlowLineTexture)
			set_color(accent, 0.8)
			render2d.DrawRect(inner, -10 * S, (self.BarEnd - self.Inner) * S, 20 * S)
			render2d.SetTexture(nil)
			set_color(self.MarkerColor, 1)
			theme:DrawDiamond(inner, 0, 7 * S)
			render2d.PopBlendMode()
		end

		local size = math.floor((entry.selected and self.SelectedSize or self.Size) * S)
		local _, h = render2d.GetTextSize(entry.label, HEADING, size, BOLD)
		text(
			entry.label,
			self.TextStart * S,
			-h / 2,
			HEADING,
			size,
			entry.text_color,
			entry.fade,
			0,
			entry.glow
		)
		render2d.PopWorldMatrix()
	end
end

local function weapon_element_color(weapon)
	if weapon.weapon:GetCategory() == "magic" and weapon.weapon_magic then
		return damage_types.GetColor(weapon.weapon_magic.Element)
	end
end

local function fill_weapon_entry(entry, weapons, i, count)
	local weapon = weapons[i]
	local info = weapon.weapon
	local category = info:GetCategory()
	local element_color = weapon_element_color(weapon)
	entry.label = info:GetDisplayName():upper()
	entry.text_color = element_color or (entry.selected and WHITE or MUTED)
	entry.wedge_color = weapon_categories.Get(category).Color
	entry.group = category
	entry.previous_group = weapons[(i - 2) % count + 1].weapon:GetCategory()

	if entry.selected then
		local glow = entry.glow_color or Color()
		local color = entry.text_color
		glow.r, glow.g, glow.b, glow.a = color.r * 0.4, color.g * 0.4, color.b * 0.4, 1
		entry.glow_color = glow
		entry.glow = glow
	else
		entry.glow = nil
	end
end

local weapon_wheel = radial_wheel.New{
	Name = "weapon_wheel",
	Range = 8,
	MinSlots = 34,
	Inner = 72,
	Outer = 175,
	TextStart = 92,
	BarEnd = 296,
	Size = 13,
	SelectedSize = 17,
	Feather = 1,
	ScaleFalloff = 0.93,
	MarkerColor = GOLD,
	FillEntry = fill_weapon_entry,
	DividerColor = weapon_categories.GetDividerColor,
	FadeTexture = render2d.CreateGradient{
		width = 256,
		height = 1,
		angle = 90,
		stops = {
			{pos = 0, color = Color(1, 1, 1, 0)},
			{pos = 0.45, color = Color(1, 1, 1, 0.35)},
			{pos = 1, color = Color(1, 1, 1, 1)},
		},
	},
}
local ring_color = Color(1, 1, 1, 1)
local backdrop_poly = Polygon2D.New(8192)
backdrop_poly.WorldMatrixMultiply = true
local backdrop_white = Color(1, 1, 1, 1)

local function batch_arcs(cx, cy, r_in, r_out, count, sweep, rotation, color, alpha)
	local segments = math.max(1, math.ceil(sweep / 0.1))

	for i = 0, count - 1 do
		local start = rotation + i / count * math.pi * 2
		backdrop_poly:BatchArc(
			cx,
			cy,
			r_in,
			r_out,
			start,
			start + sweep,
			segments,
			1,
			color.r,
			color.g,
			color.b,
			alpha
		)
	end
end

local function draw_ring_backdrop(theme, cx, cy, S, spin)
	local outer = (weapon_wheel.Outer + 6) * S
	local inner = (weapon_wheel.Inner - 2) * S
	render2d.SetTexture(theme.Textures.GlowPoint)
	render2d.SetColor(0, 0, 0, 0.75)
	render2d.DrawRect(cx - 260 * S, cy - 260 * S, 520 * S, 520 * S)
	render2d.PushBlendPreset("additive")
	set_color(ring_color, 0.28)
	render2d.DrawRect(cx - 110 * S, cy - 110 * S, 220 * S, 220 * S)
	render2d.SetTexture(nil)
	set_color(ring_color, 0.8)
	theme:DrawCircle(cx, cy, 58 * S, 2, 1)
	set_color(ring_color, 0.3)
	theme:DrawCircle(cx, cy, 50 * S, 1, 1)
	theme:DrawCircle(cx, cy, inner, 1, 1)
	theme:DrawCircle(cx, cy, outer, 1, 1)
	set_color(GOLD, 0.35)
	theme:DrawCircle(cx, cy, outer + 6 * S, 1, 1)

	for i = 1, 36 do
		local a = spin * 0.5 + i / 36 * math.pi * 2
		local long = i % 3 == 0
		local r1 = outer - (long and 12 or 6) * S
		local r2 = outer
		set_color(long and GOLD or ring_color, long and 0.7 or 0.3)
		theme:DrawGlowLine(
			cx + math.cos(a) * r1,
			cy + math.sin(a) * r1,
			cx + math.cos(a) * r2,
			cy + math.sin(a) * r2,
			long and 1.5 or 1
		)
	end

	for triangle = 0, 1 do
		for i = 0, 2 do
			local a1 = -spin * 1.3 + (i / 3 + triangle * 0.5) * math.pi * 2
			local a2 = -spin * 1.3 + ((i + 1) / 3 + triangle * 0.5) * math.pi * 2
			set_color(ring_color, 0.3)
			theme:DrawGlowLine(
				cx + math.cos(a1) * 50 * S,
				cy + math.sin(a1) * 50 * S,
				cx + math.cos(a2) * 50 * S,
				cy + math.sin(a2) * 50 * S,
				1.5
			)
		end
	end

	for i = 1, 8 do
		local a = spin * -0.6 + i / 8 * math.pi * 2 + math.pi / 8
		set_color(GOLD, 0.9)
		theme:DrawDiamond(cx + math.cos(a) * 66 * S, cy + math.sin(a) * 66 * S, 5 * S)
	end

	for i = 0, 3 do
		local a = spin * 0.35 + i / 4 * math.pi * 2
		set_color(backdrop_white, 0.9)
		theme:DrawDiamond(cx + math.cos(a) * outer, cy + math.sin(a) * outer, 8 * S)
		set_color(GOLD, 0.9)
		theme:DrawDiamond(cx + math.cos(a) * outer, cy + math.sin(a) * outer, 12 * S)
	end

	batch_arcs(cx, cy, outer - 2 * S, outer + 2 * S, 3, 1.1, spin * 0.8, ring_color, 0.6)
	batch_arcs(cx, cy, inner - 1.5 * S, inner + 1.5 * S, 14, 0.2, -spin * 0.7, GOLD, 0.6)
	batch_arcs(cx, cy, 63 * S, 69 * S, 2, 2, spin * 1.5, ring_color, 0.5)
	batch_arcs(cx, cy, 55 * S, 57 * S, 6, 0.6, -spin * 2, backdrop_white, 0.35)
	render2d.SetColor(1, 1, 1, 1)
	backdrop_poly:FlushBatch()
	render2d.PopBlendMode()
end

local ring_weapons = {}

local function draw_ring(holder, cx, cy, S, dt)
	local weapons = ring_weapons
	table.clear(weapons)

	for _, weapon in ipairs(holder:GetWeapons()) do
		if weapon.weapon:CanEquip("right") then weapons[#weapons + 1] = weapon end
	end

	local count = #weapons

	if count == 0 then return end

	local active = holder:GetWeapon("right")
	local left = holder:GetWeapon("left")
	local selected = 1

	for i, weapon in ipairs(weapons) do
		if weapon == active then selected = i end
	end

	local scroll = weapon_wheel:Scroll(selected, count, dt)
	local accent = NEON

	if active and active.weapon:GetCategory() == "magic" then
		accent = damage_types.GetColor(active.weapon_magic and active.weapon_magic.Element or "generic")
	end

	ring_color.r = smooth("ring_r", accent.r, dt, 6)
	ring_color.g = smooth("ring_g", accent.g, dt, 6)
	ring_color.b = smooth("ring_b", accent.b, dt, 6)
	local theme = get_style()
	draw_ring_backdrop(theme, cx, cy, S, system.GetElapsedTime() * 0.15 + scroll * 0.4)
	weapon_wheel:Draw(weapons, count, scroll, selected, cx, cy, S, theme, ring_color)

	if active then
		local category = weapon_categories.Get(active.weapon:GetCategory())
		text(
			category.Label,
			cx,
			cy - 9 * S,
			HEADING,
			math.floor(13 * S),
			category.Color,
			1,
			0.5
		)
	end

	if left and left ~= active then
		text(
			left.weapon:GetDisplayName():upper(),
			cx,
			cy + 8 * S,
			HEADING,
			math.floor(9 * S),
			weapon_element_color(left) or MUTED,
			1,
			0.5
		)
	end
end

local function draw_player(rig, w, h, dt)
	local S = h / 1080
	local rpg = rig.rpg
	local health = rig.health
	local now = system.GetElapsedTime()
	local ring_x, ring_y = 120 * S, h - 130 * S
	draw_ring(rig.weapon_holder, ring_x, ring_y, S, dt)
	local x = 420 * S
	local y = h - 150 * S
	local name_size = math.floor(32 * S)
	local name_w = text(
		rig:GetName(),
		x,
		y - name_size * 1.2,
		HEADING,
		name_size,
		WHITE,
		1,
		0,
		NAME_GLOW
	)
	text(
		"LV",
		x + name_w + 18 * S,
		y - name_size * 0.95,
		HEADING,
		math.floor(13 * S),
		GOLD,
		1
	)
	text(
		tostring(rpg:GetLevel()),
		x + name_w + 42 * S,
		y - name_size * 1.15,
		HEADING,
		math.floor(26 * S),
		LEVEL_COLOR,
		1,
		0,
		LEVEL_GLOW
	)

	if rpg:GetAttributePoints() > 0 then
		local pulse = 0.6 + 0.4 * math.sin(now * 4)
		text(
			"+" .. rpg:GetAttributePoints() .. " !level",
			x + name_w + 80 * S,
			y - name_size * 0.9,
			BODY,
			math.floor(14 * S),
			GOLD,
			pulse
		)
	end

	draw_status_icons(rig.status_effects, x + 4 * S, y - name_size * 2.4, 26 * S, 1)
	local values = {
		health = {health.Health, health.MaxHealth},
		mana = {rpg:GetMana(), rpg:GetMaxMana()},
		stamina = {rpg:GetStamina(), rpg:GetMaxStamina()},
	}
	local bar_h = BAR_HEIGHT * S
	local skew = BAR_SKEW * S
	local by = y
	local bx = x

	for _, bar in ipairs(BARS) do
		local value, max = values[bar.key][1], values[bar.key][2]
		local fraction = value / math.max(max, 1)
		local shown = smooth(bar.key, fraction, dt)
		local ghost_key = bar.key .. "_ghost"
		local ghost = smoothed[ghost_key] or shown

		if shown < ghost then
			if (smoothed[ghost_key .. "_time"] or 0) < now - TRAIL_DELAY then
				ghost = math.max(ghost - dt * TRAIL_SPEED, shown)
			end
		else
			ghost = shown
			smoothed[ghost_key .. "_time"] = now
		end

		smoothed[ghost_key] = ghost
		local width = math.clamp(max * 2, 120, w / 3 / S) * S
		local color = bar.color

		if bar.key == "health" and fraction < 0.25 then
			color = color:GetLerped(0.5 + 0.5 * math.sin(now * 10), DANGER)
		elseif bar.key == "stamina" and rpg:IsStunned() then
			color = color:GetLerped(0.5 + 0.5 * math.sin(now * 14), DANGER)
		end

		draw_skewed_bar(bx, by, width, bar_h, skew, shown, ghost, bar.trail, color, 1, 10)
		text(
			bar.label,
			bx - 34 * S,
			by - 1 * S,
			HEADING,
			math.floor(13 * S),
			color,
			1,
			0,
			Color(color.r * 0.3, color.g * 0.3, color.b * 0.3, 1)
		)
		text(
			tostring(math.floor(value + 0.5)),
			bx + width + 14 * S,
			by - 4 * S,
			BODY,
			math.floor(19 * S),
			WHITE,
			1,
			0,
			Color(color.r * 0.35, color.g * 0.35, color.b * 0.35, 1)
		)
		by = by + bar_h + BAR_GAP * S
		bx = bx - skew * 0.5
	end

	local next_xp = math.max(rpg:GetNextLevelXP(), 1)
	local xp_fraction = smooth("xp", rpg:GetXP() / next_xp, dt)
	local xp_width = math.clamp(rpg:GetMaxStamina() * 2, 120, w / 3 / S) * S
	draw_skewed_bar(
		bx,
		by + 2 * S,
		xp_width,
		XP_HEIGHT * S,
		skew * 0.5,
		xp_fraction,
		xp_fraction,
		jrpg.Colors.xp,
		jrpg.Colors.xp,
		1
	)
	text("XP", bx - 34 * S, by - 2 * S, HEADING, math.floor(11 * S), jrpg.Colors.xp, 1)
	text(
		math.floor(rpg:GetXP()) .. " / " .. next_xp,
		bx + xp_width + 14 * S,
		by - 3 * S,
		BODY,
		math.floor(13 * S),
		MUTED,
		1
	)

	if rpg:IsCheat() then
		text("CHEAT", x, by + 16 * S, HEADING, math.floor(10 * S), DANGER, 0.7)
	end
end

local function get_record(health)
	local record = records[health]

	if record then return record end

	record = {
		health_component = health,
		health = health.Health,
		time = -math.huge,
		shown = health:GetFraction(),
		trail = health:GetFraction(),
		trail_time = 0,
		anchor = Vec3(),
		name = "",
		status = nil,
	}
	records[health] = record
	tracked[#tracked + 1] = record
	return record
end

local function draw_npc_bar(camera, record, alpha, is_target, w, h, S)
	local screen = camera:WorldPositionToScreen(record.anchor, w, h)

	if not screen then return end

	local width = (is_target and NPC_TARGET_WIDTH or NPC_WIDTH) * S
	local bar_h = (is_target and NPC_HEIGHT * 1.5 or NPC_HEIGHT) * S
	local x = screen.x - width / 2
	local y = screen.y
	local color = jrpg.Colors.health:GetLerped(1 - math.min(record.shown * 2, 1), NPC_LOW)

	if record.shown < 0.25 then color = DANGER end

	draw_skewed_bar(
		x,
		y,
		width,
		bar_h,
		6 * S,
		record.shown,
		record.trail,
		NPC_TRAIL,
		color,
		alpha,
		is_target and 8 or nil
	)
	text(
		record.name,
		x,
		y - 22 * S,
		HEADING,
		math.floor((is_target and 15 or 13) * S),
		is_target and WHITE or MUTED,
		alpha
	)
	draw_status_icons(record.status, x + width, y + bar_h + 6 * S, 16 * S, alpha, true)
end

local function update_record(record, health, now, dt)
	local owner = health.Owner
	record.name = owner:GetName()
	record.status = owner.status_effects
	local box = visual_bounds.GetCore(owner, bounds) or
		visual_bounds.Get(owner, bounds) or
		(
			owner.rigid_body and
			owner.rigid_body:GetBroadphaseAABB(nil, nil, bounds)
		)

	if box then
		record.anchor:Set(
			(box.min_x + box.max_x) * 0.5,
			box.max_y + NPC_LIFT,
			(box.min_z + box.max_z) * 0.5
		)
	end

	if health.Health < record.health then
		record.time = now
		record.trail_time = now + TRAIL_DELAY
	end

	record.health = health.Health
	record.shown = record.shown + (
			health:GetFraction() - record.shown
		) * math.min(dt * SMOOTH_SPEED, 1)

	if now > record.trail_time then
		record.trail = math.max(record.trail - dt * TRAIL_SPEED, record.shown)
	end

	record.trail = math.max(record.trail, record.shown)
end

local function draw_npcs(rig, camera, w, h, now, dt)
	local S = h / 1080
	local target = targeting.Get()
	local target_owner = target and target.Owner

	for _, health in ipairs(Health.Instances) do
		local owner = health.Owner

		if owner ~= rig and owner.rigid_body and owner.transform and not health:IsDead() then
			local record = get_record(health)
			update_record(record, health, now, dt)
			local is_target = owner == target_owner
			local alpha = is_target and
				1 or
				math.min((record.time + NPC_VISIBLE_TIME + NPC_FADE_TIME - now) / NPC_FADE_TIME, 1)

			if record.status and next(record.status.amounts) then
				alpha = math.max(alpha, 1)
			end

			if alpha > 0 then draw_npc_bar(camera, record, alpha, is_target, w, h, S) end
		end
	end

	for i = #tracked, 1, -1 do
		local record = tracked[i]
		local health = record.health_component

		if not health:IsValid() or health:IsDead() then
			if not record.removed_time and now - record.time > NPC_VISIBLE_TIME then
				record.removed_time = now - NPC_LINGER
			end

			record.removed_time = record.removed_time or now
			record.status = nil
			local age = now - record.removed_time
			local alpha = math.min((NPC_LINGER - age) / NPC_FADE_TIME, 1)

			if alpha <= 0 then
				table.remove(tracked, i)
			else
				record.shown = math.max(record.shown - dt * 4, 0)
				record.trail = math.max(record.trail - dt * TRAIL_SPEED, record.shown)
				draw_npc_bar(camera, record, alpha, false, w, h, S)
			end
		end
	end
end

local function draw_reticle(camera, w, h, now)
	local target = targeting.Get()

	if not target then return end

	local S = h / 1080
	local box = visual_bounds.Get(target.Owner, bounds)
	local center = box and box:GetCenter() or target:GetPosition()
	local screen = camera:WorldPositionToScreen(center, w, h)

	if not screen then return end

	local theme = get_style()
	local size = (34 + math.sin(now * 6) * 3) * S
	render2d.SetTexture(nil)
	render2d.PushBlendPreset("additive")

	for i = 0, 3 do
		local a = now * 1.5 + i * math.pi / 2
		local x = screen.x + math.cos(a) * size
		local y = screen.y + math.sin(a) * size
		set_color(DANGER, 0.9)
		theme:DrawDiamond(x, y, 9 * S)
		set_color(WHITE, 0.8)
		theme:DrawDiamond(x, y, 3 * S)
	end

	set_color(DANGER, 0.5)
	theme:DrawCircle(screen.x, screen.y, size * 0.8, 1, 1)
	render2d.PopBlendMode()
end

local function draw_vignette(rig, w, h, now)
	local color = Color(0, 0, 0, 0)
	local strength = 0
	local fraction = rig.health:GetFraction()

	if fraction < 0.35 and fraction > 0 then
		local pulse = 0.5 + 0.5 * math.sin(now * (4 + (1 - fraction) * 8))
		color = DANGER
		strength = (1 - fraction / 0.35) * (0.3 + 0.35 * pulse)
	end

	local statuses = rig.status_effects

	if statuses then
		for name, amount in pairs(statuses.amounts) do
			local definition = status_effects.Registered[name]

			if amount * 0.45 > strength then
				color = definition.Color
				strength = math.min(amount, 1) * 0.45
			end
		end
	end

	if rig.rpg:IsStunned() then
		color = DANGER
		strength = math.max(strength, 0.45)
	end

	if strength <= 0.01 then return end

	render2d.SetTexture(get_vignette())
	set_color(color, strength)
	render2d.DrawRect(0, 0, w, h)
	render2d.SetTexture(nil)
end

local function draw_defeat(w, h, now, rig)
	local S = h / 1080
	local dead_time = smoothed.dead_time or now
	smoothed.dead_time = dead_time
	local f = math.min((now - dead_time) / 1.5, 1)
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.55 * f)
	render2d.DrawRect(0, h * 0.42, w, h * 0.16)
	local theme = get_style()
	render2d.PushBlendPreset("additive")
	set_color(DANGER, 0.6 * f)
	theme:DrawGlowLine(w * 0.1, h * 0.42, w * 0.9, h * 0.42, 1)
	theme:DrawGlowLine(w * 0.1, h * 0.58, w * 0.9, h * 0.58, 1)
	render2d.PopBlendMode()
	local size = math.floor(72 * S * (1.1 - f * 0.1))
	text(
		"DEFEATED",
		w / 2,
		h / 2 - size * 0.7,
		HEADING,
		size,
		DEFEAT_COLOR,
		f,
		0.5,
		DEFEAT_GLOW
	)

	if f >= 1 then
		text(
			"CLICK TO RISE AGAIN",
			w / 2,
			h / 2 + size * 0.45,
			BODY,
			math.floor(18 * S),
			MUTED,
			0.6 + 0.4 * math.sin(now * 3),
			0.5
		)
	end
end

event.AddListener("DrawHUD", "jrpg_hud", function(dt)
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid() and rig.rpg) or third_person.IsHudHidden() then
		return
	end

	dt = system.GetFrameTime()
	local now = system.GetElapsedTime()
	local w, h = render2d.GetSize()
	local camera = render3d.GetMainCamera()
	draw_vignette(rig, w, h, now)
	draw_npcs(rig, camera, w, h, now, dt)
	draw_reticle(camera, w, h, now)

	if rig.health:IsDead() then
		draw_defeat(w, h, now, rig)
	else
		smoothed.dead_time = nil
		draw_player(rig, w, h, dt)
	end
end)

event.AddListener("DrawHUD", "jrpg_hitmarkers", function()
	if third_person.IsHudHidden() then return end

	local w, h = render2d.GetSize()
	hitmarkers.Draw(render3d.GetMainCamera(), w, h, system.GetElapsedTime(), system.GetFrameTime())
end)
