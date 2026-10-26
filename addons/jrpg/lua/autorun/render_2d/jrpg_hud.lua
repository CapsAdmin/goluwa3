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
	{key = "health", label = "HP", color = jrpg.Colors.health},
	{key = "mana", label = "MP", color = jrpg.Colors.mana},
	{key = "stamina", label = "SP", color = jrpg.Colors.stamina},
}
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

local function draw_skewed_bar(x, y, w, h, skew, fraction, ghost, color, alpha, segments)
	local theme = get_style()
	render2d.PushWorldMatrix()
	render2d.Translatef(x, y + h)
	render2d.Shear(-skew / h, 0)
	render2d.Translatef(0, -h)
	render2d.SetTexture(nil)
	set_color(INK, 0.82 * alpha)
	render2d.DrawRect(-2, -2, w + 4, h + 4)

	if ghost > fraction + 0.001 then
		render2d.SetColor(1, 0.92, 0.8, 0.55 * alpha)
		render2d.DrawRect(0, 0, w * math.min(ghost, 1), h)
	end

	local fill = w * math.clamp(fraction, 0, 1)

	if fill > 0.5 then
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = fill,
			h = h,
			color = color,
			alpha = alpha,
			texture = theme.Textures.Gradient,
			color_uv = {x = 0, y = 0, w = 0.5, h = 1},
		}
		render2d.SetTexture(nil)
		render2d.SetColor(1, 1, 1, 0.35 * alpha)
		render2d.DrawRect(0, 0, fill, math.max(h * 0.18, 1))
	end

	if segments then
		render2d.SetColor(0, 0, 0, 0.35 * alpha)

		for i = 1, segments - 1 do
			render2d.DrawRect(math.floor(w * i / segments), 1, 1, h - 2)
		end
	end

	set_color(STEEL, 0.95 * alpha)
	render2d.DrawRect(-2, -2, w + 4, 1)
	render2d.DrawRect(-2, h + 1, w + 4, 1)
	render2d.DrawRect(-2, -2, 1, h + 4)
	render2d.DrawRect(w + 1, -2, 1, h + 4)

	if fill > 0.5 then
		render2d.PushBlendPreset("additive")
		set_color(color, 0.9 * alpha)
		render2d.SetTexture(theme.GlowLineTexture)
		render2d.DrawRect(fill - 6, -h * 0.8, 12, h * 2.6)
		render2d.SetTexture(nil)
		set_color(color, alpha)
		theme:DrawDiamond(fill, h / 2, h * 0.7)
		render2d.SetColor(1, 1, 1, 0.9 * alpha)
		theme:DrawDiamond(fill, h / 2, h * 0.3)
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

local RING_RANGE = 6
local RING_INNER = 72
local RING_OUTER = 235
local RING_GAP = 2
local RING_FEATHER = 1
local ring_poly = Polygon2D.New(4096)
ring_poly.WorldMatrixMultiply = true

local function draw_ring(holder, cx, cy, S, dt)
	local theme = get_style()
	local now = system.GetElapsedTime()
	local weapons = holder:GetWeapons()
	local count = #weapons

	if count == 0 then return end

	local active = holder:GetActiveWeapon()
	local selected = 1

	for i, weapon in ipairs(weapons) do
		if weapon == active then selected = i end
	end

	local last_selected = smoothed.ring_last or selected
	local scroll_target = smoothed.ring_target or selected

	if selected ~= last_selected then
		local delta = (selected - last_selected) % count

		if delta > count / 2 then delta = delta - count end

		scroll_target = scroll_target + delta
	end

	smoothed.ring_last = selected
	smoothed.ring_target = scroll_target
	local scroll = smooth("ring_scroll", scroll_target, dt, 10)
	local accent = NEON

	if active and active.weapon:GetCategory() == "magic" then
		accent = damage_types.GetColor(active.weapon_magic and active.weapon_magic.Element or "generic")
	end

	local ring_color = Color(
		smooth("ring_r", accent.r, dt, 6),
		smooth("ring_g", accent.g, dt, 6),
		smooth("ring_b", accent.b, dt, 6),
		1
	)
	render2d.SetTexture(theme.Textures.GlowPoint)
	render2d.SetColor(0, 0, 0, 0.75)
	render2d.DrawRect(cx - 260 * S, cy - 260 * S, 520 * S, 520 * S)
	render2d.SetTexture(nil)
	render2d.PushBlendPreset("additive")
	local spin = now * 0.15 + scroll * 0.4
	set_color(ring_color, 0.75)
	theme:DrawCircle(cx, cy, 58 * S, 2, 1)
	set_color(ring_color, 0.35)
	theme:DrawCircle(cx, cy, 66 * S, 1, 1)
	theme:DrawCircle(cx, cy, 148 * S, 1, 1)

	for i = 1, 24 do
		local a = spin + i / 24 * math.pi * 2
		local r1 = (i % 3 == 0 and 136 or 141) * S
		local r2 = 148 * S
		set_color(ring_color, i % 3 == 0 and 0.6 or 0.25)
		theme:DrawGlowLine(
			cx + math.cos(a) * r1,
			cy + math.sin(a) * r1,
			cx + math.cos(a) * r2,
			cy + math.sin(a) * r2,
			1
		)
	end

	for i = 1, 6 do
		local a = -spin * 1.7 + i / 6 * math.pi * 2
		set_color(ring_color, 0.18)
		theme:DrawGlowLine(cx, cy, cx + math.cos(a) * 52 * S, cy + math.sin(a) * 52 * S, 2)
	end

	for i = 1, 8 do
		local a = spin * -0.6 + i / 8 * math.pi * 2 + math.pi / 8
		set_color(GOLD, 0.8)
		theme:DrawDiamond(cx + math.cos(a) * 66 * S, cy + math.sin(a) * 66 * S, 5 * S)
	end

	render2d.PopBlendMode()
	local step = math.pi * 2 / math.max(count, 25)
	local tan_half = math.tan(step / 2)
	local cos_half = math.cos(step / 2)
	local ring_vertex = 0

	for pass = 1, 3 do
		for i, weapon in ipairs(weapons) do
			local base = (i - scroll) % count
			local offset = base - count * math.floor((base + RING_RANGE) / count)

			while offset < RING_RANGE do
				local fade = math.max(1 - math.abs(offset) / RING_RANGE, 0) ^ 2

				if fade > 0.01 then
					local info = weapon.weapon
					local is_selected = weapon == active and math.abs(offset) < 0.5
					local name = info:GetDisplayName():upper()
					local color = is_selected and WHITE or MUTED

					if info:GetCategory() == "magic" and weapon.weapon_magic then
						color = damage_types.GetColor(weapon.weapon_magic.Element)
					end

					local size = math.floor((is_selected and 20 or 15) * S)
					render2d.PushWorldMatrix()
					render2d.Translatef(cx, cy)
					render2d.Rotate(offset * step)
					local _, h = render2d.GetTextSize(name, HEADING, size, BOLD)
					local category = weapon_categories.Get(info:GetCategory())
					local previous = weapons[(i - 2) % count + 1].weapon:GetCategory()
					local following = weapons[i % count + 1].weapon:GetCategory()
					local gap_up = previous == info:GetCategory() and RING_GAP * S or 0
					local gap_down = following == info:GetCategory() and RING_GAP * S or 0

					if pass == 1 then
						local rim = RING_OUTER * S / cos_half
						local gap_up_angle = gap_up / rim
						local gap_down_angle = gap_down / rim
						ring_vertex = ring_poly:SetArc(
							ring_vertex,
							0,
							0,
							RING_INNER * S / cos_half,
							rim,
							-step / 2 + gap_up_angle,
							step / 2 - gap_down_angle,
							1,
							RING_FEATHER,
							INK.r,
							INK.g,
							INK.b,
							0.5 * fade
						)
						ring_vertex = ring_poly:SetArc(
							ring_vertex,
							0,
							0,
							RING_INNER * S / cos_half,
							rim,
							-step / 2 + gap_up_angle,
							step / 2 - gap_down_angle,
							1,
							RING_FEATHER,
							category.Color.r,
							category.Color.g,
							category.Color.b,
							(is_selected and 0.55 or 0.3) * fade
						)
					elseif pass == 2 and previous ~= info:GetCategory() then
						local other = weapon_categories.Get(previous).Color
						render2d.PushWorldMatrix()
						render2d.Rotate(-step / 2)
						render2d.PushBlendPreset("additive")
						render2d.SetColor(
							(category.Color.r + other.r) * 0.5 + 0.25,
							(category.Color.g + other.g) * 0.5 + 0.25,
							(category.Color.b + other.b) * 0.5 + 0.25,
							1.5 * fade
						)
						theme:DrawGlowLine(RING_INNER * S / cos_half, 0, RING_OUTER * S / cos_half, 0, 4 * S)
						render2d.PopBlendMode()
						render2d.PopWorldMatrix()
					end

					if pass == 3 and is_selected then
						render2d.PushBlendPreset("additive")
						render2d.SetTexture(theme.GlowLineTexture)
						set_color(ring_color, 0.8)
						render2d.DrawRect(76 * S, -10 * S, 220 * S, 20 * S)
						render2d.SetTexture(nil)
						set_color(GOLD, 1)
						theme:DrawDiamond(76 * S, 0, 7 * S)
						render2d.PopBlendMode()
					end

					if pass == 3 then
						text(
							name,
							88 * S,
							-h / 2,
							HEADING,
							size,
							color,
							fade,
							0,
							is_selected and Color(color.r * 0.4, color.g * 0.4, color.b * 0.4, 1) or nil
						)
					end

					render2d.PopWorldMatrix()
				end

				offset = offset + count
			end
		end

		if pass == 1 and ring_vertex > 0 then
			render2d.SetTexture(nil)
			render2d.SetColor(1, 1, 1, 1)
			ring_poly:Draw(ring_vertex)
		end
	end

	if active then
		local category = weapon_categories.Get(active.weapon:GetCategory())
		text(category.Label, cx, cy - 9 * S, HEADING, math.floor(13 * S), category.Color, 1, 0.5)
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

		draw_skewed_bar(bx, by, width, bar_h, skew, shown, ghost, color, 1, 10)
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
	hitmarkers.Draw(camera, w, h, now, dt)

	if rig.health:IsDead() then
		draw_defeat(w, h, now, rig)
	else
		smoothed.dead_time = nil
		draw_player(rig, w, h, dt)
	end
end)
