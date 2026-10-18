local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local perf = import("lua/perf.lua")
local react = import("goluwa/render2d/ui/react.lua")
local WIDTH, HEIGHT = 660, 430
local PIE_X, PIE_Y, PIE_RADIUS, PIE_INNER = 200, 232, 150, 84
local LIST_X, LIST_W = 400, 244
local LIST_Y, ROW_H = 58, 16
local VERTEX_CAPACITY = 8192
local FEATHER = 1
local ZOOM_SECONDS = 0.22
local TEXT = Color(0.84, 0.87, 0.94, 1)
local TEXT_DIM = Color(0.5, 0.55, 0.65, 1)
gpu_timing.RegisterGroup("shadows", "shadows", "^shadow_")
gpu_timing.RegisterGroup("ddgi", "ddgi", "^ddgi_")
gpu_timing.RegisterGroup("ambient_occlusion", "ambient occlusion", "^ambient_occlusion")
gpu_timing.RegisterGroup("reflections", "reflections", "^reflections")
gpu_timing.RegisterGroup("volumetrics", "volumetrics", "^volumetric_")
gpu_timing.RegisterGroup("ocean", "ocean", "^ocean_")
gpu_timing.RegisterGroup("particles", "particles", "^particles_")
gpu_timing.RegisterGroup("translucency", "translucency", "^translucent")
gpu_timing.RegisterGroup("lighting", "lighting", "^lighting$", "^light_grid$", "^light_occlusion$")
gpu_timing.RegisterGroup("scene", "scene acceleration", "^rt_build$", "^skinning$")
gpu_timing.RegisterGroup("antialiasing", "anti aliasing", "^taa")
gpu_timing.RegisterGroup("bloom", "bloom", "^bloom_", "^glare$")
gpu_timing.RegisterGroup(
	"post",
	"post processing",
	"^motion_blur$",
	"^exposure_feedback$",
	"^blit",
	"^forward_overlay$"
)
local smoothed = {}
local selected
local switch_time = -math.huge
local poly = Polygon2D.New(VERTEX_CAPACITY)
poly.WorldMatrixMultiply = true

local function get_ms(name)
	local ms = gpu_timing.GetMilliseconds(name)
	local value = smoothed[name]
	value = value and (value * 0.85 + ms * 0.15) or ms
	smoothed[name] = value
	return value
end

local function pass_label(group, name)
	local label = gpu_timing.GetLabel(name):lower()
	local word = group.scopes[1]:match("^[^_]+")

	if #group.scopes == 1 then return label end

	for _, scope in ipairs(group.scopes) do
		if scope:match("^[^_]+") ~= word then return label end
	end

	return label:sub(#word + 2)
end

-- the golden angle keeps neighbouring slices apart in hue
local function slice_color(index, shade)
	local c = Color.FromHSV(index * 0.381966, 0.62 - shade * 0.25, 0.95 - shade * 0.35)
	return c.r, c.g, c.b
end

local META = Panel:CreateTemplate("gpu_pie")
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "hand"}

function META.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

local function collect()
	local groups = gpu_timing.GetGroups()
	local group

	if selected then
		for _, g in ipairs(groups) do
			if g.id == selected then
				group = g

				break
			end
		end
	end

	local total = 0
	local entries = {}

	if group then
		for i, name in ipairs(group.scopes) do
			local ms = get_ms(name)
			entries[i] = {id = name, label = pass_label(group, name), ms = ms}
		end
	else
		for i, g in ipairs(groups) do
			local ms = 0

			for _, name in ipairs(g.scopes) do
				ms = ms + get_ms(name)
			end

			entries[i] = {id = g.id, label = g.label:lower(), ms = ms}
		end
	end

	for _, entry in ipairs(entries) do
		total = total + entry.ms
	end

	for i, entry in ipairs(entries) do
		entry.r, entry.g, entry.b = slice_color(i, group and (i % 2) * 0.5 or 0)
		entry.fraction = total > 0 and entry.ms / total or 0
	end

	return group, entries, total
end

local function entry_at(entries, local_x, local_y)
	local dx, dy = local_x - PIE_X, local_y - PIE_Y
	local radius = math.sqrt(dx * dx + dy * dy)

	if radius >= PIE_INNER and radius <= PIE_RADIUS + 8 then
		local turn = (math.atan2(dy, dx) + math.pi / 2) / (math.pi * 2) % 1
		local start = 0

		for i, entry in ipairs(entries) do
			if turn >= start and turn < start + entry.fraction then return i end

			start = start + entry.fraction
		end
	end

	if
		local_x >= LIST_X and
		local_x <= LIST_X + LIST_W and
		local_y >= LIST_Y and
		local_y < LIST_Y + #entries * ROW_H
	then
		return math.floor((local_y - LIST_Y) / ROW_H) + 1
	end
end

function META:OnMouseInput(button, press, local_pos)
	if not press then return true end

	local group, entries = collect()

	if button == "button_2" then
		selected = nil
		switch_time = system.GetElapsedTime()
		return true
	end

	if button ~= "button_1" then return true end

	local dx, dy = local_pos.x - PIE_X, local_pos.y - PIE_Y

	if dx * dx + dy * dy < PIE_INNER * PIE_INNER then
		if group then
			selected = nil
			switch_time = system.GetElapsedTime()
		end

		return true
	end

	local index = entry_at(entries, local_pos.x, local_pos.y)

	if index and not group then
		selected = entries[index].id
		switch_time = system.GetElapsedTime()
	end

	return true
end

function META:OnDraw()
	local group, entries, total = collect()
	local mouse = self.mouse_input:GetMousePosition()
	local hovered = self.mouse_input.Hovered and entry_at(entries, mouse.x, mouse.y)
	local ease = math.clamp((system.GetElapsedTime() - switch_time) / ZOOM_SECONDS, 0, 1)
	ease = 1 - (1 - ease) * (1 - ease)
	local scale = math.lerp(ease, 0.82, 1)
	local alpha = math.lerp(ease, 0.2, 1)
	render2d.SetTexture(nil)
	render2d.SetColor(0.03, 0.04, 0.07, 0.92)
	render2d.DrawRoundedRect(0, 0, WIDTH, HEIGHT, 10)
	local vertex = 0
	local start = -math.pi / 2

	for i, entry in ipairs(entries) do
		local sweep = entry.fraction * math.pi * 2

		if sweep > 0 then
			local outer = PIE_RADIUS * scale + (i == hovered and 8 or 0)
			local inner = PIE_INNER * scale
			local r, g, b = entry.r, entry.g, entry.b
			local a = (hovered and i ~= hovered) and alpha * 0.7 or alpha
			local segments = math.max(1, math.ceil(entry.fraction * 96))
			local gap = math.min(0.012, sweep * 0.2)

			if vertex + (segments + 2) * 18 <= VERTEX_CAPACITY then
				vertex = poly:SetArc(
					vertex,
					PIE_X,
					PIE_Y,
					inner,
					outer,
					start + gap / 2,
					start + sweep - gap / 2,
					segments,
					FEATHER,
					r,
					g,
					b,
					a
				)
			end
		end

		start = start + sweep
	end

	render2d.SetColor(1, 1, 1, 1)

	if vertex > 0 then poly:Draw(vertex) end

	local title = group and group.label or "gpu"
	local title_w = render2d.GetTextSize(title, nil, 20)
	render2d.DrawText{
		text = title,
		x = PIE_X - title_w / 2,
		y = PIE_Y - 26,
		size = 20,
		foreground_color = TEXT,
	}
	local sub = string.format("%.2f ms", total)
	local sub_w = render2d.GetTextSize(sub, nil, 15)
	render2d.DrawText{
		text = sub,
		x = PIE_X - sub_w / 2,
		y = PIE_Y + 2,
		size = 15,
		foreground_color = TEXT_DIM,
	}
	local frame = string.format("frame %.2f ms", get_ms("gpu_frame"))
	local frame_w = render2d.GetTextSize(frame, nil, 12)
	render2d.DrawText{
		text = frame,
		x = PIE_X - frame_w / 2,
		y = PIE_Y + 22,
		size = 12,
		foreground_color = TEXT_DIM,
	}
	render2d.DrawText{
		text = group and "click the center or right click to go back" or "click a slice to zoom in",
		x = 16,
		y = HEIGHT - 24,
		size = 12,
		foreground_color = TEXT_DIM,
	}
	render2d.DrawText{
		text = group and group.label .. " passes" or "systems",
		x = LIST_X,
		y = 28,
		size = 14,
		foreground_color = TEXT,
	}

	for i, entry in ipairs(entries) do
		local y = LIST_Y + (i - 1) * ROW_H

		if i == hovered then
			render2d.SetColor(1, 1, 1, 0.08)
			render2d.DrawRect(LIST_X - 6, y, LIST_W + 12, ROW_H)
		end

		render2d.SetColor(entry.r, entry.g, entry.b, 1)
		render2d.DrawRect(LIST_X, y + ROW_H / 2 - 4, 8, 8)
		local dim = entry.ms <= 0
		render2d.DrawText{
			text = entry.label,
			x = LIST_X + 16,
			y = y + ROW_H / 2,
			align_y = "cap_center",
			size = 12,
			foreground_color = dim and TEXT_DIM or TEXT,
		}
		local text = string.format("%.3f  %4.1f%%", entry.ms, entry.fraction * 100)
		local text_w = render2d.GetTextSize(text, nil, 12)
		render2d.DrawText{
			text = text,
			x = LIST_X + LIST_W - text_w,
			y = y + ROW_H / 2,
			align_y = "cap_center",
			size = 12,
			foreground_color = dim and TEXT_DIM or TEXT,
		}
	end
end

META:Register()
local GpuPie = react.Element(META)
perf.RegisterTab("GPU", 1, react.Component(|| -> GpuPie{Size = Vec2(WIDTH, HEIGHT)}))
