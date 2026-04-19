local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local vfs = import("goluwa/vfs.lua")
local theme = import("../theme.lua")
local Button = import("../elements/button.lua")
local Column = import("../elements/column.lua")
local Dropdown = import("../elements/dropdown.lua")
local Splitter = import("../elements/splitter.lua")
local Text = import("../elements/text.lua")
local Window = import("../elements/window.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Panel = import("goluwa/ecs/panel.lua")
local timer = import("goluwa/timer.lua")

local function update_layout_now(entity)
	if not entity or not entity:IsValid() or not entity.layout then return end

	entity.layout:InvalidateLayout()
	local root = entity.layout
	local parent = entity:GetParent()

	while parent and parent:IsValid() and parent.layout do
		root = parent.layout
		parent = parent:GetParent()
	end

	root:UpdateLayout()
end

local function build_gallery(props)
	local pages = {}
	local gallery_files = vfs.Find("lua/ui/gallery/%.lua$")

	for _, file in ipairs(gallery_files) do
		local ok, page = pcall(import, "lua/ui/gallery/" .. file)

		if ok then
			table.insert(pages, page)
		else
			print("Failed to load page: " .. file .. " - " .. tostring(page))
		end
	end

	local function find_page_by_name(name)
		if not name then return nil end

		for _, page in ipairs(pages) do
			if page.Name == name then return page end
		end

		return nil
	end

	local content_panel = ScrollablePanel{
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
		},
		Padding = Rect() + theme.GetPadding("S"),
	}
	local selected_page = find_page_by_name(props.SelectedPage)
	local window

	local function select_page(page)
		if not page then return end

		selected_page = page
		print("Selecting page: " .. tostring(page.Name))
		local viewport

		for _, child in ipairs(content_panel:GetChildren()) do
			if child:GetName() == "viewport" then
				viewport = child

				break
			end
		end

		if viewport then
			viewport:RemoveChildren()

			if page and page.Create then
				local content = page.Create()
				viewport:AddChild(content)
				update_layout_now(viewport)
			end
		else
			print("Could not find viewport in content_panel")
		end
	end

	local function rebuild_gallery()
		if not window or not window:IsValid() then return end

		local position = window.transform:GetPosition()
		local size = window.transform:GetSize()

		if position.Copy then position = position:Copy() end

		if size.Copy then size = size:Copy() end

		local replacement = build_gallery{
			Key = props.Key,
			Position = position,
			Size = size,
			SelectedPage = selected_page and selected_page.Name or nil,
		}
		window:Remove()
		Panel.World:Ensure(replacement)
	end

	local page_buttons = {}

	for _, page in ipairs(pages) do
		table.insert(
			page_buttons,
			Button{
				Text = page.Name or "Unnamed Page",
				OnClick = function()
					select_page(page)
				end,
				layout = {
					GrowWidth = 1,
					FitWidth = false,
				},
				TextLayout = {
					GrowWidth = 1,
					FitWidth = false,
				},
				AlignX = "left",
			}
		)
	end

	local sidebar_children = {
		Text{
			Text = "Theme",
			Font = "body_strong S",
			Color = "text_foreground",
			IgnoreMouseInput = true,
		},
		Dropdown{
			Text = theme.GetPresetLabel(theme.GetPresetName()),
			Options = (function()
				local options = {}

				for _, name in ipairs(theme.GetPresetNames()) do
					table.insert(options, {
						Text = theme.GetPresetLabel(name),
						Value = name,
					})
				end

				return options
			end)(),
			GetText = function()
				return theme.GetPresetLabel(theme.GetPresetName())
			end,
			OnSelect = function(name)
				theme.SetPreset(name)
				rebuild_gallery()
			end,
			layout = {
				GrowWidth = 1,
			},
			Padding = "XS",
		},
	}

	for _, button in ipairs(page_buttons) do
		table.insert(sidebar_children, button)
	end

	local world_panel = Panel.World
	window = Window{
		Key = props.Key or "GalleryWindow",
		Title = "UI GALLERY",
		Size = props.Size or Vec2(800, 600),
		Padding = "none",
		Position = props.Position or (world_panel.transform:GetSize() - Vec2(800, 600)) / 2,
		layout = {
			FitHeight = false,
			FitWidth = false,
		},
	}{
		Splitter{
			InitialSize = 220,
		}{
			ScrollablePanel{
				Color = theme.GetColor("black"):Copy():SetAlpha(0.3),
				layout = {
					GrowHeight = 1,
				},
				Padding = Rect() + theme.GetPadding("XXS"),
			}{
				Column{
					layout = {
						ChildGap = 4,
						GrowWidth = 1,
						AlignmentX = "stretch",
					},
				}(sidebar_children),
			},
			content_panel,
		},
	}

	timer.Delay(0, function()
		if not window:IsValid() then return end

		select_page(selected_page or pages[1])
	end)

	return window
end

return function(props)
	return build_gallery(props or {})
end
