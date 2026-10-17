local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local gbuffer_inspect = import("goluwa/render3d/gbuffer_inspect.lua")
local Rect = import("goluwa/structs/rect.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local WIDTH = 1140
local VIEWS_HEIGHT = 600
local LAYOUT_HEIGHT = 300
local TARGETS_HEIGHT = 330
local CONTENT_HEIGHT = math.max(VIEWS_HEIGHT, LAYOUT_HEIGHT + TARGETS_HEIGHT + 8)
local HEADER = 26
local open_entry
local preview_time = -math.huge
local TEXT = Color(0.9, 0.92, 0.97, 1)
local TEXT_DIM = Color(0.55, 0.6, 0.7, 1)
local PANEL = Color(0.03, 0.04, 0.07, 0.95)
-- what a sheet lets you change while you look at it
local CONTEXTS = {normal = "normal_source", albedo = "terrain"}

local function get_tint(name, shade)
	local hash = 0

	for i = 1, #name do
		hash = (hash * 31 + name:byte(i)) % 1000
	end

	local c = Color.FromHSV(hash / 1000, 0.45, shade or 0.75)
	return c.r, c.g, c.b
end

local function get_sheet(name)
	for _, sheet in ipairs(gbuffer_inspect.GetSheets()) do
		if sheet.name == name then return sheet end
	end
end

local function get_preview_texture()
	local pipeline = render3d.pipelines and render3d.pipelines.gbuffer_inspect

	if not (pipeline and pipeline.framebuffers) then return nil end

	return pipeline:GetFramebuffer():GetAttachment(1)
end

-- the rect that fits the render size in a w x h box
local function fit(w, h)
	local render_size = render3d.GetRenderSize()
	local scale = math.min(w / render_size.x, h / render_size.y)
	local fit_w, fit_h = render_size.x * scale, render_size.y * scale
	return (w - fit_w) / 2, (h - fit_h) / 2, fit_w, fit_h
end

local function get_grid(count)
	local columns = math.max(math.ceil(math.sqrt(count)), 1)
	return columns, math.ceil(count / columns)
end

local function draw_labels(labels, x, y, w, h, hovered_index)
	local columns, rows = get_grid(#labels)
	local cell_w, cell_h = w / columns, h / rows

	for i, label in ipairs(labels) do
		local tile_x, tile_y = x + ((i - 1) % columns) * cell_w, y + math.floor((i - 1) / columns) * cell_h

		if i == hovered_index then
			render2d.SetTexture(nil)
			render2d.SetColor(1, 1, 1, 0.9)
			render2d.DrawRect(tile_x, tile_y, cell_w, 2)
			render2d.DrawRect(tile_x, tile_y + cell_h - 2, cell_w, 2)
			render2d.DrawRect(tile_x, tile_y, 2, cell_h)
			render2d.DrawRect(tile_x + cell_w - 2, tile_y, 2, cell_h)
		end

		render2d.DrawText{
			text = label,
			x = tile_x + 6,
			y = tile_y + 12,
			align_y = "cap_center",
			size = 12,
			foreground_color = TEXT,
			shadow_x = 1,
			shadow_y = 1,
		}
	end
end

local TileView = Panel:CreateTemplate("gbuffer_tiles")
TileView.CMP.transform = {}
TileView.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
TileView.CMP.visual = {}
TileView.CMP.mouse_input = {Cursor = "hand"}

function TileView.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

-- the preview to draw, the clickable tiles ({label, OnClick}) when it is a grid, the title and going back
function TileView.OnSpec(view) end

function TileView.OnTiles(view) end

function TileView.OnTitle(view)
	return ""
end

function TileView.OnBack(view) end

local function get_tile_at(self, tiles, local_x, local_y)
	local size = self.transform:GetSize()
	local x, y, w, h = fit(size.x, size.y - HEADER)
	y = y + HEADER

	if local_x < x or local_y < y or local_x >= x + w or local_y >= y + h then return nil end

	local columns, rows = get_grid(#tiles)
	local index = math.floor((local_y - y) / (h / rows)) * columns + math.floor((local_x - x) / (w / columns)) + 1
	return tiles[index] and index or nil
end

function TileView:OnMouseInput(button, press, local_pos)
	if not press then return true end

	if button == "button_2" then
		self.OnBack(self)
		return true
	end

	local tiles = button == "button_1" and self.OnTiles(self)

	if tiles then
		local index = get_tile_at(self, tiles, local_pos.x, local_pos.y)

		if index then tiles[index].OnClick() end
	end

	return true
end

function TileView:OnDraw()
	local size = self.transform:GetSize()
	render2d.SetTexture(nil)
	render2d.SetColor(PANEL.r, PANEL.g, PANEL.b, PANEL.a)
	render2d.DrawRoundedRect(0, 0, size.x, size.y, 10)
	gbuffer_inspect.SetPreview(self.OnSpec(self))
	preview_time = system.GetElapsedTime()
	render2d.DrawText{
		text = self.OnTitle(self),
		x = 12,
		y = HEADER / 2 + 2,
		align_y = "cap_center",
		size = 13,
		foreground_color = TEXT_DIM,
	}
	local texture = get_preview_texture()

	if not texture then return end

	local x, y, w, h = fit(size.x, size.y - HEADER)
	y = y + HEADER
	render2d.SetColor(1, 1, 1, 1)
	render2d.PushColorUV(0, 1, 1, 0)
	render2d.SetTexture(texture)
	render2d.DrawRect(x, y, w, h)
	render2d.PopColorUV()
	render2d.SetTexture(nil)
	local tiles = self.OnTiles(self)

	if tiles then
		local labels = {}

		for i, tile in ipairs(tiles) do
			labels[i] = tile.label
		end

		local mouse = self.mouse_input:GetMousePosition()
		draw_labels(labels, x, y, w, h, self.mouse_input.Hovered and get_tile_at(self, tiles, mouse.x, mouse.y) or nil)
	end
end

TileView:Register()
local LayoutView = Panel:CreateTemplate("gbuffer_layout_view")
LayoutView.CMP.transform = {}
LayoutView.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
LayoutView.CMP.visual = {}
LayoutView.CMP.mouse_input = {Cursor = "hand"}
local ROW_HEIGHT = 32
local LABEL_WIDTH = 210
local layout_rows

function LayoutView.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

local function build_layout_rows()
	layout_rows = {}

	for i, target in ipairs(gbuffer_layout.targets) do
		local cells = {r = {}, g = {}, b = {}, a = {}}

		if target.texture:match("^packed") then
			for _, field in ipairs(gbuffer_layout.fields) do
				if field.target == target then
					for channel in field.swizzle:gmatch(".") do
						table.insert(cells[channel], {name = field.name, nibble = field.nibble})
					end
				end
			end
		else
			for _, channel in ipairs(target.channels) do
				for c in channel[2]:gmatch(".") do
					table.insert(cells[c], {name = channel[1]})
				end
			end
		end

		layout_rows[i] = {target = target, cells = cells}
	end
end

local CHANNELS = {"r", "g", "b", "a"}

local function get_cell_rect(self, row_index, channel_index)
	local size = self.transform:GetSize()
	local cell_w = (size.x - LABEL_WIDTH - 12) / 4
	return LABEL_WIDTH + (channel_index - 1) * cell_w, 8 + (row_index - 1) * ROW_HEIGHT, cell_w - 4, ROW_HEIGHT - 5
end

function LayoutView:OnMouseInput(button, press, local_pos)
	if not press or button ~= "button_1" then return true end

	for row_index, row in ipairs(layout_rows) do
		for channel_index, channel in ipairs(CHANNELS) do
			local x, y, w, h = get_cell_rect(self, row_index, channel_index)

			if local_pos.x >= x and local_pos.x < x + w and local_pos.y >= y and local_pos.y < y + h then
				local cell = row.cells[channel][1]

				if cell then
					local ok, entry = pcall(gbuffer_inspect.GetEntry, cell.name)
					open_entry(ok and entry or gbuffer_inspect.GetEntry("velocity"))
				end

				return true
			end
		end
	end

	return true
end

function LayoutView:OnDraw()
	if not layout_rows then build_layout_rows() end

	local size = self.transform:GetSize()
	render2d.SetTexture(nil)
	render2d.SetColor(PANEL.r, PANEL.g, PANEL.b, PANEL.a)
	render2d.DrawRoundedRect(0, 0, size.x, size.y, 10)
	local total = 0
	local free = 0

	for row_index, row in ipairs(layout_rows) do
		local target = row.target
		local bytes = gbuffer_layout.FORMAT_BYTES[target.format]
		total = total + bytes
		local y = 8 + (row_index - 1) * ROW_HEIGHT
		render2d.DrawText{text = target.texture, x = 12, y = y + 4, size = 13, foreground_color = TEXT}
		render2d.DrawText{
			text = target.format .. "  " .. bytes .. " B",
			x = 12,
			y = y + 18,
			size = 11,
			foreground_color = TEXT_DIM,
		}

		for channel_index, channel in ipairs(CHANNELS) do
			local x, cy, w, h = get_cell_rect(self, row_index, channel_index)
			local cell = row.cells[channel]
			render2d.SetTexture(nil)

			if cell[1] then
				render2d.SetColor(0.12, 0.14, 0.2, 1)
				render2d.DrawRoundedRect(x, cy, w, h, 4)
				local half_h = #cell > 1 and h / #cell or h

				for i, entry in ipairs(cell) do
					local r, g, b = get_tint(entry.name, 0.6)
					render2d.SetColor(r, g, b, 0.85)
					render2d.DrawRoundedRect(x + 2, cy + (i - 1) * half_h + 2, w - 4, half_h - 4, 3)
					render2d.DrawText{
						text = entry.name,
						x = x + 6,
						y = cy + (i - 1) * half_h + half_h / 2 - 7,
						size = 11,
						foreground_color = Color(0.02, 0.03, 0.05, 1),
					}
				end
			else
				free = free + 1
				render2d.SetColor(0.08, 0.09, 0.13, 1)
				render2d.DrawRoundedRect(x, cy, w, h, 4)
				render2d.DrawText{text = "free", x = x + 8, y = cy + h / 2 - 7, size = 11, foreground_color = TEXT_DIM}
			end
		end
	end

	render2d.DrawText{
		text = string.format(
			"%d targets of 8, %d bytes per pixel plus depth %s, %d free channels (click a field to look at it, the raw targets are below)",
			#gbuffer_layout.targets,
			total,
			gbuffer_layout.DEPTH_FORMAT,
			free
		),
		x = 12,
		y = size.y - 20,
		size = 12,
		foreground_color = TEXT_DIM,
	}
end

LayoutView:Register()
local PASS_NAMES = {"ambient_occlusion", "reflections", "ssgi_filter_1", "ssgi_filter_2", "ssgi"}
local SWIZZLES = {r = "rrr", g = "ggg", b = "bbb", a = "aaa", rgb = "rgb"}

local function show_fullscreen(spec)
	gbuffer_inspect.SetView(spec)
	desktop.Hide()
end

local function get_targets_tiles()
	local tiles = {}

	for i, target in ipairs(gbuffer_layout.targets) do
		tiles[i] = {
			label = "raw " .. target.texture,
			OnClick = function()
				show_fullscreen({mode = "target", target = target.texture, channel = "rgb"})
			end,
		}
	end

	return tiles
end

local TARGETS_SPEC = {mode = "targets"}


-- the VIEWS tab: a tree of the views, the views or the fields of one as tiles, and what is selected on the right.
-- the sheets are the gbuffer decoded (gbuffer_inspect), the passes are the debug textures of the passes
local LABEL_HEIGHT = 36
local CELL_WIDTH = 150
local PREVIEW_HEIGHT = 186
local browser = {category = "sheets", folder = nil, selected = nil, items = {}}
local folder_items = {}
local expanded = {sheets = true, passes = true, lighting = true}
local pass_fullscreen
local lighting_fullscreen
local colors = {}

local function refresh_colors()
	local active = theme.active

	if colors.theme == active then return end

	colors.theme = active
	colors.text = active:GetColor("text")
	colors.text_disabled = active:GetColor("text_disabled")
	colors.primary = active:GetColor("primary")
	colors.border = active:GetColor("border")
	local surface_alt = active:GetColor("surface_alt")
	colors.tile_fill = {r = surface_alt.r, g = surface_alt.g, b = surface_alt.b, a = 0.7}
	colors.tile_fill_hover = {r = surface_alt.r, g = surface_alt.g, b = surface_alt.b, a = 1}
	colors.preview_background = {r = 0.2, g = 0.21, b = 0.24, a = 1}
	colors.badge_fill = {r = 0, g = 0, b = 0, a = 0.55}
	colors.white = {r = 1, g = 1, b = 1, a = 1}
	colors.font = active:GetFont("body", "S")
	colors.font_small = active:GetFont("body", "XS")
end

local function draw_font_text(font, text, x, y, color)
	render2d.SetTexture(nil)
	render2d.PushColor(color.r, color.g, color.b, 1)
	render2d.PushAlphaMultiplier(color.a)
	font:DrawText(text, x, y, 0)
	render2d.PopAlphaMultiplier()
	render2d.PopColor()
end

-- views that are a setting of the lighting, they have no picture of their own, applying one shows it on screen
local LIGHTING_MODES = {
	{
		name = "direct light only",
		key = "lighting_debug_direct",
		value = true,
		description = "the direct light of the lights and the sun, without the indirect light, the reflections or the ambient term",
	},
	{
		name = "gi only",
		key = "ddgi_debug_gi",
		value = true,
		description = "only the irradiance of the global illumination (ddgi)",
	},
	{
		name = "screen space shadows",
		key = "screen_space_shadows_debug",
		value = true,
		description = "what the screen space shadows darken, white is untouched",
	},
	{
		name = "ddgi probe irradiance",
		key = "ddgi_debug_probes",
		value = "irradiance",
		description = "markers at the ddgi probes colored by their irradiance (the cascade is ddgi_debug_cascade)",
	},
	{
		name = "ddgi probe hit distance",
		key = "ddgi_debug_probes",
		value = "hit_distance",
		description = "markers at the ddgi probes colored by the mean distance their rays hit",
	},
	{
		name = "ddgi scene albedo",
		key = "ddgi_debug_scene",
		value = "albedo",
		description = "the albedo of the scene the ddgi probe rays trace",
	},
	{
		name = "ddgi scene normals",
		key = "ddgi_debug_scene",
		value = "normals",
		description = "the normals of the scene the ddgi probe rays trace",
	},
	{
		name = "ddgi scene hit distance",
		key = "ddgi_debug_scene",
		value = "hit_distance",
		description = "the hit distance of the scene the ddgi probe rays trace",
	},
}

local function is_lighting_mode_on(mode)
	return pvars.Get(mode.key) == mode.value
end

-- the pvars are bools or enums with "off"
local function set_lighting_mode(mode, on)
	if on then
		pvars.SetSession(mode.key, mode.value)
	elseif type(mode.value) == "boolean" then
		pvars.SetSession(mode.key, false)
	else
		pvars.SetSession(mode.key, "off")
	end
end

local function get_pass_views()
	local list = {}

	for _, name in ipairs(PASS_NAMES) do
		local pipeline = render3d.pipelines and render3d.pipelines[name]

		if pipeline and pipeline.framebuffers then
			local views = {}

			for _, view in ipairs(pipeline:GetDebugViews()) do
				views[#views + 1] = {
					name = view.name,
					kind = "pass_view",
					pipeline = pipeline,
					view = view,
					title = name .. " " .. view.name,
				}
			end

			if views[1] then list[#list + 1] = {name = name, views = views} end
		end
	end

	return list
end

local function get_pass_texture(item)
	return item.pipeline:GetFramebuffer():GetAttachment(item.view.attachment_index)
end

local function get_items(category, folder)
	local key = category .. ":" .. (folder or "")

	if category == "sheets" and folder_items[key] then return folder_items[key] end

	local items = {}

	if category == "lighting" then
		for _, mode in ipairs(LIGHTING_MODES) do
			items[#items + 1] = {name = mode.name, kind = "lighting", mode = mode}
		end

		return items
	end

	if category == "passes" then
		for _, pass in ipairs(get_pass_views()) do
			if not folder and #pass.views > 1 then
				items[#items + 1] = {name = pass.name, kind = "pass_folder", is_folder = true, views = pass.views, pipeline = pass.views[1].pipeline, view = pass.views[1].view, title = pass.name}
			elseif not folder and #pass.views == 1 then
				items[#items + 1] = pass.views[1]
			elseif folder == pass.name then
				for _, view in ipairs(pass.views) do
					items[#items + 1] = view
				end
			end
		end

		return items
	end

	if not folder then
		for _, sheet in ipairs(gbuffer_inspect.GetSheets()) do
			items[#items + 1] = {name = sheet.name, kind = "sheet", entry = sheet.primary, sheet = sheet, is_folder = #sheet.entries > 1}
		end
	else
		local sheet = get_sheet(folder)

		for _, entry in ipairs(sheet.entries) do
			items[#items + 1] = {name = entry.name, kind = "entry", entry = entry, sheet = sheet}
		end
	end

	-- the preview draws its tiles in the order of the entries
	table.sort(items, function(a, b)
		return a.entry.index < b.entry.index
	end)
	items.names = {}

	for i, item in ipairs(items) do
		item.index = i
		items.names[i] = item.entry.name
	end

	folder_items[key] = items
	return items
end

local function request_preview()
	if browser.category ~= "sheets" then return end

	gbuffer_inspect.SetPreview({mode = "sheet", names = browser.items.names})
	preview_time = system.GetElapsedTime()
end

-- draws one tile of the preview texture, which holds count tiles
local function draw_tile(texture, index, count, x, y, w, h)
	local columns, rows = get_grid(count)
	local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
	local inset = 0.003
	render2d.SetColor(1, 1, 1, 1)
	-- the uv are left, bottom, right and top, and row 0 of the texture is the top of the screen
	render2d.PushColorUV(
		(column + inset) / columns,
		(row + 1 - inset) / rows,
		(column + 1 - inset) / columns,
		(row + inset) / rows
	)
	render2d.SetTexture(texture)
	render2d.DrawRect(x, y, w, h)
	render2d.PopColorUV()
	render2d.SetTexture(nil)
end

local function draw_pass_texture(texture, view, x, y, w, h)
	render2d.SetColor(1, 1, 1, 1)
	render2d.PushColorUV(0, 1, 1, 0)
	render2d.PushSwizzleMode(SWIZZLES[view.swizzle] or "none")
	render2d.SetTexture(texture)
	render2d.DrawRect(x, y, w, h)
	render2d.PopSwizzleMode()
	render2d.PopColorUV()
	render2d.SetTexture(nil)
end

-- the item's picture in a rect of the aspect of the screen
local function draw_item_picture(item, x, y, w, h)
	if item.kind == "lighting" then
		local text = is_lighting_mode_on(item.mode) and "on" or "off"
		local tw, th = colors.font:GetTextSize(text)
		draw_font_text(colors.font, text, x + (w - tw) / 2, y + (h - th) / 2, colors.text_disabled)
		return
	end

	if item.kind == "pass_view" or item.kind == "pass_folder" then
		local texture = get_pass_texture(item)

		if texture then draw_pass_texture(texture, item.view, x, y, w, h) end

		return
	end

	local texture = get_preview_texture()

	if texture then draw_tile(texture, item.index, #browser.items, x, y, w, h) end
end

local function draw_item(item, index, x, y, w, h, selected, hovered)
	refresh_colors()
	render2d.DrawBox(
		x,
		y,
		w,
		h,
		6,
		hovered and colors.tile_fill_hover or colors.tile_fill,
		selected and colors.primary or colors.border,
		selected and -2 or -1
	)
	local inset = 4
	local px, py, pw = x + inset, y + inset, w - inset * 2
	local render_size = render3d.GetRenderSize()
	local ph = pw * render_size.y / render_size.x
	py = py + (pw - ph) / 2
	render2d.DrawBox(px, py, pw, ph, 4, colors.preview_background)
	draw_item_picture(item, px, py, pw, ph)

	if item.is_folder then
		local count = item.sheet and #item.sheet.entries or #item.views
		local badge = count .. (item.sheet and " fields" or " views")
		local bw, bh = colors.font_small:GetTextSize(badge)
		render2d.DrawBox(px + pw - bw - 8, py + ph - bh - 6, bw + 6, bh + 2, 3, colors.badge_fill)
		draw_font_text(colors.font_small, badge, px + pw - bw - 5, py + ph - bh - 5, colors.white)
	end

	local label_y = y + h - LABEL_HEIGHT + 2
	local tw = colors.font:GetTextSize(item.name)
	draw_font_text(colors.font, item.name, x + (w - tw) / 2, label_y, colors.text)
	local sub = item.kind == "lighting" and item.mode.key or
		item.is_folder and (item.sheet and "sheet" or "pass") or
		item.kind == "pass_view" and item.view.swizzle or
		(item.entry.field and item.entry.field.kind or "fixed")
	local sw = colors.font_small:GetTextSize(sub)
	draw_font_text(colors.font_small, sub, x + (w - sw) / 2, label_y + 16, colors.text_disabled)
end

-- the view of the selected item on screen, for sheets one of the inspect views
local function show_selected_fullscreen()
	local item = browser.selected

	if not item then return end

	if item.kind == "lighting" then
		set_lighting_mode(item.mode, true)
		lighting_fullscreen = item
		desktop.Hide()
	elseif item.kind == "pass_view" or item.kind == "pass_folder" then
		pass_fullscreen = item
		desktop.Hide()
	else
		show_fullscreen({mode = "field", name = item.entry.name})
	end
end

local FIXED_DETAILS = {
	albedo = {"stored", "albedo target, rgb (r8g8b8a8_srgb)"},
	alpha = {"stored", "albedo target, a"},
	emissive = {"stored", "emissive target (b10g11r11), shown as 1 - exp(-v / 16)"},
	depth = {"stored", "depth buffer (d32_sfloat), shown as the distance from the camera, white is far"},
	velocity = {"stored", "velocity target, rg in uv per frame (shown x200) and prev_view_depth in b"},
}

open_entry = function(entry)
	event.Call("RenderViewsOpen", entry)
end

local function build_all_tree_items()
	local function folder_icon(_, is_expanded)
		return is_expanded and "folder_open" or "folder"
	end

	local sheet_nodes = {}

	for _, sheet in ipairs(gbuffer_inspect.GetSheets()) do
		local node = {
			Key = "sheets/" .. sheet.name,
			Text = sheet.name,
			Icon = "image",
			Nav = {category = "sheets", select = sheet.name},
		}

		if #sheet.entries > 1 then
			node.Text = ("%s  (%d)"):format(sheet.name, #sheet.entries)
			node.Icon = folder_icon
			node.Nav = {category = "sheets", folder = sheet.name}
			node.Children = {}

			for _, entry in ipairs(sheet.entries) do
				node.Children[#node.Children + 1] = {
					Key = "sheets/" .. sheet.name .. "/" .. entry.name,
					Text = entry.name,
					Icon = "image",
					Nav = {category = "sheets", folder = sheet.name, select = entry.name},
				}
			end
		end

		sheet_nodes[#sheet_nodes + 1] = node
	end

	local pass_nodes = {}

	for _, pass in ipairs(get_pass_views()) do
		local node = {
			Key = "passes/" .. pass.name,
			Text = pass.name,
			Icon = "image",
			Nav = {category = "passes", select = pass.name},
		}

		if #pass.views > 1 then
			node.Text = ("%s  (%d)"):format(pass.name, #pass.views)
			node.Icon = folder_icon
			node.Nav = {category = "passes", folder = pass.name}
			node.Children = {}

			for _, view in ipairs(pass.views) do
				node.Children[#node.Children + 1] = {
					Key = "passes/" .. pass.name .. "/" .. view.name,
					Text = view.name,
					Icon = "image",
					Nav = {category = "passes", folder = pass.name, select = view.name},
				}
			end
		end

		pass_nodes[#pass_nodes + 1] = node
	end

	local lighting_nodes = {}

	for _, mode in ipairs(LIGHTING_MODES) do
		lighting_nodes[#lighting_nodes + 1] = {
			Key = "lighting/" .. mode.name,
			Text = mode.name,
			Icon = "sun",
			Nav = {category = "lighting", select = mode.name},
		}
	end

	return {
		{
			Key = "sheets",
			Text = ("sheets  (%d)"):format(#sheet_nodes),
			Icon = "layout",
			Nav = {category = "sheets"},
			Children = sheet_nodes,
		},
		{
			Key = "passes",
			Text = ("passes  (%d)"):format(#pass_nodes),
			Icon = "layout",
			Nav = {category = "passes"},
			Children = pass_nodes,
		},
		{
			Key = "lighting",
			Text = ("lighting  (%d)"):format(#lighting_nodes),
			Icon = "layout",
			Nav = {category = "lighting"},
			Children = lighting_nodes,
		},
	}
end

-- the nodes that match the filter, a node that matches keeps all its children
local function filter_nodes(nodes, filter)
	local out = {}

	for _, node in ipairs(nodes) do
		local matches = node.Text:lower():find(filter, 1, true) ~= nil
		local children = node.Children and (matches and node.Children or filter_nodes(node.Children, filter))

		if matches or (children and children[1]) then
			local copy = {}

			for key, value in pairs(node) do
				copy[key] = value
			end

			copy.Children = children
			out[#out + 1] = copy
		end
	end

	return out
end

local function build_tree_items(filter)
	local items = build_all_tree_items()

	if filter == "" then return items end

	return filter_nodes(items, filter)
end

local function draw_preview(self)
	refresh_colors()
	local size = self.Owner.transform:GetSize()
	render2d.DrawBox(0, 0, size.x, size.y, 4, colors.preview_background)
	request_preview()
	local item = browser.selected

	if not item then
		local text = "no selection"
		local tw, th = colors.font:GetTextSize(text)
		draw_font_text(colors.font, text, (size.x - tw) / 2, (size.y - th) / 2, colors.text_disabled)
		return
	end

	local x, y, w, h = fit(size.x, size.y)
	draw_item_picture(item, x, y, w, h)
end

local function detail_row(label, value)
	return ui.Row{Key = label, layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "start"}}{
		ui.Text{
			Text = label,
			Font = "body S",
			Color = "text_disabled",
			layout = {MinSize = Vec2(70, 0), MaxSize = Vec2(70, 0), FitWidth = false},
		},
		ui.Text{Text = value, Font = "body S", Wrap = true, layout = {GrowWidth = 1}},
	}
end

local function detail_text(key, text, font, color)
	return ui.Text{Key = key, Text = text, Font = font, Color = color, Wrap = true, layout = {GrowWidth = 1}}
end

-- the VIEWS tab. nav says where the tree, the breadcrumb and the grid are, the selected item is the one picked in the grid or the one the navigation asked for, everything else is made from those two. browser is what the draw code and the fullscreen views read, it is written while this renders
local ViewsPage = react.Component(|| -> do
	local nav, set_nav = react.UseState({category = "sheets"})
	local picked, set_picked = react.UseState()
	local filter, set_filter = react.UseState("")
	local terrain_only, set_terrain_only = react.UseState(|| -> gbuffer_inspect.GetTerrainOnly())
	local _, set_version = react.UseState(0)
	local tree = react.UseRef()
	local items = react.UseMemo(|| -> get_items(nav.category, nav.folder), {nav.category, nav.folder})
	local selected = picked

	if not selected and nav.select then
		for _, item in ipairs(items) do
			if item.name == nav.select then selected = item end
		end
	end

	browser.category = nav.category
	browser.folder = nav.folder
	browser.items = items
	browser.selected = selected

	local function navigate(category, folder, select_name)
		set_nav({category = category, folder = folder, select = select_name})
		set_picked(nil)
	end

	react.UseEvent("RenderViewsOpen", |entry| -> do
		local sheet = get_sheet(entry.sheet)

		if #sheet.entries == 1 then
			navigate("sheets", nil, sheet.name)
		else
			navigate("sheets", sheet.name, entry.name)
		end
	end)
	react.UseEvent("RenderViewsChanged", || -> set_version(|version| -> version + 1))

	local tree_items = react.UseMemo(|| -> build_tree_items(filter), {filter})
	local tree_key = nav.category

	if selected and not nav.folder then
		tree_key = tree_key .. "/" .. selected.name
	elseif selected then
		tree_key = tree_key .. "/" .. nav.folder .. "/" .. selected.name
	elseif nav.folder then
		tree_key = tree_key .. "/" .. nav.folder
	end

	react.UseEffect(|| -> tree.current:ExpandToKey(tree_key), {tree_key, tree_items})

	local crumbs = {{name = nav.category, category = nav.category}}

	if nav.folder then
		crumbs[2] = {name = nav.folder, category = nav.category, folder = nav.folder}
	end

	local breadcrumb = {}

	for index, crumb in ipairs(crumbs) do
		if index > 1 then
			breadcrumb[#breadcrumb + 1] = ui.Icon{Key = "separator", Icon = "chevron_right", Size = "S", IconColor = "text_disabled"}
		end

		breadcrumb[#breadcrumb + 1] = ui.Clickable{
			Key = "crumb " .. index,
			Mode = "text",
			Padding = Rect(4, 2, 4, 2),
			OnClick = || -> navigate(crumb.category, crumb.folder),
			layout = {FitWidth = true, FitHeight = true},
		}{
			ui.Text{
				Text = crumb.name,
				Font = index == #crumbs and "body_strong S" or "body S",
				IgnoreMouseInput = true,
			},
		}
	end

	local details = {}

	if not selected then
		details[1] = detail_text("empty", "Select a view to see details.", nil, "text_disabled")
	elseif selected.kind == "lighting" then
		details[1] = detail_text("title", selected.name, "body_strong M")
		details[2] = detail_text("description", selected.mode.description, "body S")
		details[3] = detail_row("pvar", selected.mode.key)
		details[4] = detail_row("value", tostring(selected.mode.value))
		details[5] = detail_row("state", is_lighting_mode_on(selected.mode) and "on" or "off")
	elseif selected.kind == "pass_view" or selected.kind == "pass_folder" then
		local texture = get_pass_texture(selected)
		details[1] = detail_text("title", selected.title, "body_strong M")
		details[2] = detail_row("pass", selected.pipeline.name)
		details[3] = detail_row("view", selected.view.name)
		details[4] = detail_row("channels", selected.view.swizzle or "all")

		if texture then details[#details + 1] = detail_row("size", texture:GetWidth() .. " x " .. texture:GetHeight()) end

		if selected.is_folder then details[#details + 1] = detail_row("views", tostring(#selected.views)) end
	else
		local entry = selected.entry
		details[1] = detail_text(
			"title",
			selected.is_folder and (selected.name .. " (sheet)") or entry.name,
			"body_strong M"
		)

		if selected.is_folder then
			local names = {}

			for _, sheet_entry in ipairs(selected.sheet.entries) do
				names[#names + 1] = sheet_entry.name
			end

			details[2] = detail_row("fields", table.concat(names, ", "))
			details[3] = detail_row("primary", entry.name)
			details[4] = detail_text("hint", "Double click the tile to open the sheet.", "body S", "text_disabled")
		elseif entry.field then
			local field = entry.field
			details[2] = detail_row("kind", field.kind)
			details[3] = detail_row(
				"stored",
				string.format("%s.%s%s", field.target.texture, field.swizzle, field.nibble and (field.nibble == 1 and " (high half)" or " (low half)") or "")
			)
			details[4] = detail_row("range", "0 to " .. (field.max or 1))
			details[5] = detail_row("read by", field.readers and table.concat(field.readers, ", ") or "everything")
			details[6] = detail_row("sheet", entry.sheet)
		elseif FIXED_DETAILS[entry.name] then
			details[2] = detail_row(unpack(FIXED_DETAILS[entry.name]))
		end
	end

	local context = selected and selected.entry and CONTEXTS[selected.entry.sheet]
	local input_height = theme.active:GetInputHeight("M")

	return ui.Column{
		Tab = "VIEWS",
		layout = {
			MinSize = Vec2(WIDTH, VIEWS_HEIGHT),
			MaxSize = Vec2(WIDTH, VIEWS_HEIGHT),
			FitWidth = false,
			FitHeight = false,
			AlignmentX = "stretch",
		},
	}{
		ui.Splitter{InitialSize = 200, layout = {GrowWidth = 1, GrowHeight = 1}}{
			ui.Column{layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false, AlignmentX = "stretch", ChildGap = 4}}{
				ui.TextEdit{
					Hint = "search",
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					ScrollbarVisible = false,
					Size = Vec2(0, input_height),
					MinSize = Vec2(0, input_height),
					MaxSize = Vec2(0, input_height),
					OnTextChanged = |_, text| -> set_filter(text:lower():match("^%s*(.-)%s*$")),
					layout = {GrowWidth = 1},
				},
				ui.ScrollablePanel{Padding = Rect(), ScrollX = false, ScrollY = true, layout = {GrowWidth = 1, GrowHeight = 1}}{
					ui.Tree{
						Ref = tree,
						Items = tree_items,
						SelectedKey = tree_key,
						LabelGrow = true,
						layout = {GrowWidth = 1, FitHeight = true},
						OnIsExpanded = |_, _, key| -> filter ~= "" or expanded[key] == true,
						OnToggle = |_, is_expanded, key| -> do expanded[key] = is_expanded == true end,
						OnSelect = |node| -> do
							if node then navigate(node.Nav.category, node.Nav.folder, node.Nav.select) end
						end,
					},
				},
			},
			ui.Column{layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false, AlignmentX = "stretch", ChildGap = 4}}{
				ui.Row{layout = {GrowWidth = 1, ChildGap = 2, AlignmentY = "center"}}{breadcrumb},
				ui.Row{layout = {GrowWidth = 1, GrowHeight = 1, ChildGap = 6, FitHeight = false, AlignmentY = "stretch"}}{
					ui.VirtualGrid{
						CellWidth = CELL_WIDTH,
						ExtraHeight = LABEL_HEIGHT,
						Gap = 8,
						ContentPadding = 6,
						Items = items,
						SelectedItem = selected,
						OnDrawItem = draw_item,
						OnSelect = set_picked,
						OnActivate = |item| -> do
							if item.is_folder then
								navigate(nav.category, item.name)
							else
								set_picked(item)
								browser.selected = item
								show_selected_fullscreen()
							end
						end,
						layout = {GrowWidth = 1, GrowHeight = 1},
					},
					ui.Frame{
						Padding = Rect() + 6,
						layout = {
							MinSize = Vec2(344, 0),
							MaxSize = Vec2(344, 0),
							FitWidth = false,
							GrowHeight = 1,
							FitHeight = false,
							Direction = "y",
							ChildGap = 6,
							AlignmentX = "stretch",
						},
					}{
						ui.Panel{
							Name = "ViewPreview",
							transform = true,
							layout = {GrowWidth = 1, MinSize = Vec2(0, PREVIEW_HEIGHT), MaxSize = Vec2(0, PREVIEW_HEIGHT)},
							visual = {OnDraw = draw_preview},
						},
						ui.Row{layout = {GrowWidth = 1, ChildGap = 4}}{
							ui.Button{Key = "fullscreen", Text = "Fullscreen", Icon = "expand", Mode = "outline", OnClick = show_selected_fullscreen},
							nav.category == "sheets" && ui.Button{
								Key = "sheet",
								Text = "Sheet fullscreen",
								Mode = "outline",
								OnClick = || -> show_fullscreen({mode = "sheet", names = browser.items.names}),
							},
							nav.category == "lighting" && ui.Button{
								Key = "toggle",
								Text = "Toggle",
								Mode = "outline",
								OnClick = || -> do
									if selected and selected.kind == "lighting" then
										set_lighting_mode(selected.mode, not is_lighting_mode_on(selected.mode))
										set_version(|version| -> version + 1)
									end
								end,
							},
						},
						ui.Row{layout = {GrowWidth = 1, ChildGap = 4, AlignmentY = "center"}}{
							context == "normal_source" && ui.Dropdown{
								Key = "normal source",
								Options = gbuffer_inspect.NORMAL_SOURCES,
								Value = gbuffer_inspect.GetNormalSource(),
								OnSelect = |value| -> gbuffer_inspect.SetNormalSource(value),
								layout = {MinSize = Vec2(120, 0), MaxSize = Vec2(120, 0), GrowWidth = 0},
							},
							context == "terrain" && ui.Button{
								Key = "terrain",
								Text = terrain_only and "Terrain base only: on" or "Terrain base only",
								Mode = "outline",
								OnClick = || -> do
									local on = not gbuffer_inspect.GetTerrainOnly()
									gbuffer_inspect.SetTerrainOnly(on)
									set_terrain_only(on)
								end,
							},
						},
						ui.ScrollablePanel{Padding = Rect(), ScrollX = false, ScrollY = true, layout = {GrowWidth = 1, GrowHeight = 1}}{
							ui.Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = 4, AlignmentX = "stretch"}}{details},
						},
					},
				},
			},
		},
	}
end)
local TileViewElement = react.Element(TileView)
local LayoutViewElement = react.Element(LayoutView)
local RenderViewsView = react.Component(|| -> do
	local tab, set_tab = react.UseState("VIEWS")
	local hud, set_hud = react.UseState(false)

	react.UseEvent("RenderViewsOpen", || -> set_tab("VIEWS"))

	return ui.Window{
		Title = "RENDER VIEWS",
		Pinnable = true,
		OnHudChanged = |_, value| -> set_hud(value),
		Size = Vec2(WIDTH + 40, CONTENT_HEIGHT + 90),
		MinSize = Vec2(WIDTH + 40, CONTENT_HEIGHT + 90),
	}{
		ui.Tabs{Value = tab, OnChange = set_tab, BarHidden = hud, layout = {GrowWidth = 1, GrowHeight = 1}}{
			ViewsPage{},
			ui.Column{Key = "layout", Tab = "GBUFFER LAYOUT", layout = {GrowWidth = 1, AlignmentX = "center", ChildGap = "XS"}}{
				LayoutViewElement{Size = Vec2(WIDTH, LAYOUT_HEIGHT)},
				TileViewElement{
					Size = Vec2(WIDTH, TARGETS_HEIGHT),
					OnSpec = || -> TARGETS_SPEC,
					OnTiles = get_targets_tiles,
					OnTitle = || -> "raw targets, as stored (click one to see it full screen)",
				},
			},
		},
	}
end)

desktop.RegisterProgram{
	Name = "Render Views",
	Icon = "layout",
	Create = function()
		return react.Mount(RenderViewsView{}, Panel.World):GetEntity()
	end,
	OnEscape = function()
		if not (gbuffer_inspect.IsFullScreen() or pass_fullscreen or lighting_fullscreen) then
			return false
		end

		gbuffer_inspect.SetView(nil)
		pass_fullscreen = nil

		if lighting_fullscreen then
			set_lighting_mode(lighting_fullscreen.mode, false)
			lighting_fullscreen = nil
			event.Call("RenderViewsChanged")
		end

		desktop.Show(true)
		return true
	end,
}

event.AddListener("Update", "gbuffer_view_idle", function()
	if gbuffer_inspect.GetPreview() and system.GetElapsedTime() - preview_time > 0.25 then
		gbuffer_inspect.SetPreview(nil)
	end
end)

-- the labels of a view that fills the screen
local function get_fullscreen_labels(view)
	local labels = {}

	if view.mode == "sheet" then
		for _, entry in ipairs(gbuffer_inspect.GetSheetEntries(view.names)) do
			labels[#labels + 1] = entry.name
		end
	elseif view.mode == "targets" then
		for _, target in ipairs(gbuffer_layout.targets) do
			labels[#labels + 1] = target.texture
		end
	end

	return labels
end

event.AddListener("Draw2D", "gbuffer_view_fullscreen", function()
	if lighting_fullscreen then
		render2d.DrawText{
			text = lighting_fullscreen.name .. "  (escape to leave)",
			x = 12,
			y = 22,
			align_y = "cap_center",
			size = 18,
			foreground_color = TEXT,
			shadow_x = 1,
			shadow_y = 1,
		}
		return
	end

	if pass_fullscreen then
		local texture = get_pass_texture(pass_fullscreen)
		local size = render3d.GetRenderSize()

		if texture then
			draw_pass_texture(texture, pass_fullscreen.view, 0, 0, size.x, size.y)
		end

		render2d.DrawText{
			text = pass_fullscreen.title .. "  (escape to leave)",
			x = 12,
			y = 22,
			align_y = "cap_center",
			size = 18,
			foreground_color = TEXT,
			shadow_x = 1,
			shadow_y = 1,
		}
		return
	end

	local view = gbuffer_inspect.GetView()

	if not view then return end

	local size = render3d.GetRenderSize()

	if view.mode == "sheet" or view.mode == "targets" then
		draw_labels(get_fullscreen_labels(view), 0, 0, size.x, size.y)
	else
		render2d.DrawText{
			text = view.mode == "field" and view.name or (view.target .. " " .. (view.channel or "rgb")),
			x = 12,
			y = 22,
			align_y = "cap_center",
			size = 22,
			foreground_color = TEXT,
			shadow_x = 1,
			shadow_y = 1,
		}
	end

	render2d.DrawText{
		text = "escape to leave",
		x = 12,
		y = size.y - 22,
		align_y = "cap_center",
		size = 14,
		foreground_color = TEXT_DIM,
		shadow_x = 1,
		shadow_y = 1,
	}
end)

commands.Add("gbuffer_view=string|nil", function(name)
	if not name or name == "off" then
		gbuffer_inspect.SetView(nil)
	elseif name == "sheet" or name == "targets" then
		gbuffer_inspect.SetView({mode = name})
	else
		gbuffer_inspect.SetView({mode = "field", name = name})
	end
end)

commands.Add("gbuffer_layout", function()
	logf("%s\n", gbuffer_layout.Describe())
end)
