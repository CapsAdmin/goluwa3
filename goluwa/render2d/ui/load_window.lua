local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Texture = import("goluwa/render/texture.lua")
local engines = import("goluwa/engines.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Splitter = react.Element(import("goluwa/render2d/ui/elements/splitter.lua"))
local VirtualGrid = react.Element(import("goluwa/render2d/ui/elements/virtual_grid.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local ErrorBoundary = react.ErrorBoundary
local LABEL_HEIGHT = 40
local ALL_GAMES = {name = "All games", all = true}
local ALL_KEY = "all"
local HINT = "double click a map to load it, mounting a game lists the maps it keeps in packages"
local textures = {}
local colors = {}
-- the png and bmp decoders write the bottom row first, the others the top row
local top_first = {jpg = true, jpeg = true, dds = true, vtf = true}

local function refresh_colors()
	local active = theme.active

	if colors.theme == active then return end

	colors.theme = active
	colors.text = active:GetColor("text")
	colors.text_disabled = active:GetColor("text_disabled")
	colors.primary = active:GetColor("primary")
	colors.surface_alt = active:GetColor("surface_alt")
	colors.border = active:GetColor("border")
	colors.tile_fill = {
		r = colors.surface_alt.r,
		g = colors.surface_alt.g,
		b = colors.surface_alt.b,
		a = 0.7,
	}
	colors.tile_fill_hover = {
		r = colors.surface_alt.r,
		g = colors.surface_alt.g,
		b = colors.surface_alt.b,
		a = 1,
	}
	colors.placeholder = {r = 0.2, g = 0.21, b = 0.24, a = 1}
	colors.shade = {r = 0, g = 0, b = 0, a = 0.6}
	colors.font = active:GetFont("body", "S")
	colors.font_strong = active:GetFont("body_strong", "S")
	colors.font_small = active:GetFont("body", "XS")
end

local function draw_text(font, text, x, y, color)
	render2d.SetTexture(nil)
	render2d.PushColor(color.r, color.g, color.b, 1)
	render2d.PushAlphaMultiplier(color.a)
	font:DrawText(text, x, y, 0)
	render2d.PopAlphaMultiplier()
	render2d.PopColor()
end

local function get_texture(path)
	local texture = textures[path]

	if texture == false then return end

	if not texture then
		texture = Texture.New{path = path, srgb = true}
		textures[path] = texture
	end

	if not texture:IsReady() then return end

	if texture.image == Texture.GetFallback().image then
		textures[path] = false
		return
	end

	return texture
end

local function draw_picture(path, x, y, w, h, alpha, crop)
	local texture = path and get_texture(path)

	if not texture then return false end

	render2d.DrawTextureCover(texture, x, y, w, h, 4, 1, 1, 1, alpha, top_first[path:lower():match("%.(%w+)$")], crop)
	return true
end

local function draw_tile_frame(x, y, w, h, selected, hovered)
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
end

local function draw_game(game, index, x, y, w, h, selected, hovered)
	refresh_colors()
	draw_tile_frame(x, y, w, h, selected, hovered)
	local inset = 4
	local name = colors.font_strong:ElideText(game.name, w - inset * 4)

	if game.all then
		draw_text(colors.font_strong, name, x + inset * 2, y + (h - 16) / 2, colors.text)
		return
	end

	if
		not draw_picture(game.image, x + inset, y + inset, w - inset * 2, h - inset * 2, 1)
	then
		render2d.DrawBox(x + inset, y + inset, w - inset * 2, h - inset * 2, 4, colors.placeholder)
	end

	render2d.DrawBox(x + inset, y + h - 34 - inset, w - inset * 2, 34, 4, colors.shade)
	draw_text(colors.font_strong, name, x + inset * 2, y + h - 34, {r = 1, g = 1, b = 1, a = 1})
	draw_text(
		colors.font_small,
		game.mountable and
			(
				game.mounted and
				"mounted" or
				"not mounted"
			)
			or
			"always available",
		x + inset * 2,
		y + h - 18,
		game.mounted and
			{r = 0.5, g = 1, b = 0.5, a = 1} or
			{r = 0.85, g = 0.85, b = 0.85, a = 1}
	)
end

local function draw_map(map, index, x, y, w, h, selected, hovered)
	refresh_colors()
	draw_tile_frame(x, y, w, h, selected, hovered)
	local inset = 4
	local px, py, pw, ph = x + inset, y + inset, w - inset * 2, h - LABEL_HEIGHT - inset

	if map.thumbnail == nil then
		local thumbnail, crop = engines.GetMapThumbnail(map)
		map.thumbnail = thumbnail or false
		map.thumbnail_crop = crop
	end

	if not draw_picture(map.thumbnail, px, py, pw, ph, 1, map.thumbnail_crop) then
		render2d.DrawBox(px, py, pw, ph, 4, colors.placeholder)
		draw_picture(map.game_image, px, py, pw, ph, 0.35)
	end

	draw_text(
		colors.font,
		colors.font:ElideText(map.name, w - inset * 2),
		x + inset,
		y + h - LABEL_HEIGHT + 2,
		colors.text
	)
	draw_text(
		colors.font_small,
		colors.font_small:ElideText(map.game_name, w - inset * 2),
		x + inset,
		y + h - LABEL_HEIGHT + 18,
		colors.text_disabled
	)
end

local function game_key_of(game)
	if not game or game.all then return ALL_KEY end

	return game.engine .. game.id
end

local function load_data()
	local games = engines.GetGames()
	local maps = engines.GetMaps()
	local items = {ALL_GAMES}
	local by_key = {[ALL_KEY] = ALL_GAMES}

	for _, game in ipairs(games) do
		items[#items + 1] = game
		by_key[game_key_of(game)] = game
	end

	for _, map in ipairs(maps) do
		local game = by_key[map.engine .. tostring(map.game)]
		map.game_name = game and game.name or map.engine
		map.game_image = game and game.image
	end

	return {games = items, by_key = by_key, maps = maps}
end

local function load_error(err, reset)
	return Column{
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
			ChildGap = "S",
			Padding = "S",
			AlignmentX = "stretch",
		},
	}{
		Text{Text = tostring(err), Wrap = true, layout = {GrowWidth = 1}},
		Button{Text = "Back", Icon = "arrow_left", OnClick = reset},
	}
end

local LoadView = react.Component(
	|props|-> do
		local data, set_data = react.UseState(load_data)
		local query, set_query = react.UseState("")
		local game_key, set_game_key = react.UseState(ALL_KEY)
		local selected_map, set_selected_map = react.UseState()
		local selected_game = data.by_key[game_key] ?? ALL_GAMES
		local maps = react.UseMemo(
			||-> do
				local shown = {}

				for _, map in ipairs(data.maps) do
					if
						(
							selected_game.all or
							(
								map.engine == selected_game.engine and
								map.game == selected_game.id
							)
						)
						and
						(
							query == "" or
							map.name:lower():find(query, 1, true)
						)
					then
						shown[#shown + 1] = map
					end
				end

				return shown
			end,
			{data, selected_game, query}
		)
		local map = selected_map and list.has_value(maps, selected_map) ? selected_map : nil
		local input_height = theme.active:GetInputHeight("M")

		local function toggle_mount()
			if not selected_game.mountable then return end

			if selected_game.mounted then
				engines.UnmountGame(selected_game.engine, selected_game.id)
			else
				engines.MountGame(selected_game.engine, selected_game.id)
			end

			set_data(load_data())
		end

		local function load_map(target)
			engines.LoadMap(target)
			props.OnLoad()
		end

		return Window{Title = "LOAD", Size = Vec2(980, 640), MinSize = Vec2(640, 360)}{
			ErrorBoundary{Fallback = load_error}{
				Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center"}}{
					TextEdit{
						Hint = "search maps",
						Wrap = false,
						ScrollX = false,
						ScrollY = false,
						Size = Vec2(0, input_height),
						MinSize = Vec2(160, input_height),
						MaxSize = Vec2(0, input_height),
						OnTextChanged = |_,text|->set_query(text:lower()),
						layout = {GrowWidth = 1},
					},
					Text{
						Text = #maps .. " maps",
						Color = "text_disabled",
						layout = {FitWidth = true, MinSize = Vec2(80, 0)},
					},
					Button{
						Text = "Load",
						Icon = "play",
						Disabled = map == nil,
						OnClick = ||->load_map(map),
					},
				},
				Splitter{InitialSize = 310, layout = {GrowWidth = 1, GrowHeight = 1}}{
					Column{
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							FitHeight = false,
							AlignmentX = "stretch",
							ChildGap = 4,
						},
					}{
						Button{
							Text = selected_game.mountable ? (selected_game.mounted ? "Unmount" : "Mount") : (selected_game.all ? "Mount" : "Always available"),
							Disabled = not selected_game.mountable,
							OnClick = toggle_mount,
							layout = {GrowWidth = 1},
						},
						VirtualGrid{
							CellWidth = 280,
							CellAspect = 0.34,
							ExtraHeight = 0,
							Gap = 6,
							ContentPadding = 4,
							KeepScroll = true,
							Items = data.games,
							SelectedItem = selected_game,
							OnDrawItem = draw_game,
							OnSelect = |game|->set_game_key(game_key_of(game)),
							OnActivate = toggle_mount,
							layout = {GrowWidth = 1, GrowHeight = 1},
						},
					},
					VirtualGrid{
						CellWidth = 170,
						CellAspect = 0.5625,
						ExtraHeight = LABEL_HEIGHT + 4,
						Gap = 8,
						ContentPadding = 6,
						Items = maps,
						SelectedItem = map,
						OnDrawItem = draw_map,
						OnSelect = |selected|->set_selected_map(selected),
						OnActivate = load_map,
						layout = {GrowWidth = 1, GrowHeight = 1},
					},
				},
				Text{Text = HINT, Color = "text_disabled", layout = {GrowWidth = 1}},
			},
		}
	end
)
return function(props)
	return react.Mount(LoadView{OnLoad = props.OnLoad}, Panel.World):GetEntity()
end
