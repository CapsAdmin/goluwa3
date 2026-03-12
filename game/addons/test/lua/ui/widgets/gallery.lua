local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local vfs = import("goluwa/vfs.lua")
local theme = import("../theme.lua")
local Button = import("../elements/button.lua")
local Column = import("../elements/column.lua")
local Splitter = import("../elements/splitter.lua")
local Window = import("../elements/window.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Panel = import("goluwa/ecs/panel.lua")
local timer = import("goluwa/timer.lua")
return function(props)
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

	local content_panel = ScrollablePanel{
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
		},
		Padding = Rect() + theme.GetPadding("S"),
	}

	local function select_page(page)
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

				if content.layout then
					timer.Delay(0, function()
						if not content:IsValid() then return end

						content.layout:InvalidateLayout(true)
					end)
				end
			end
		else
			print("Could not find viewport in content_panel")
		end
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
				},
			}
		)
	end

	local world_panel = Panel.World
	return Window{
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
				Color = theme.GetColor("black"):SetAlpha(0.3),
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
				}(page_buttons),
			},
			content_panel,
		},
	}
end