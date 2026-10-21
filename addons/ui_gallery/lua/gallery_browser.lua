local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Dropdown = react.Element(import("goluwa/render2d/ui/widgets/dropdown.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local MenuItem = react.Element(import("goluwa/render2d/ui/elements/context_menu_item.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local Splitter = react.Element(import("goluwa/render2d/ui/elements/splitter.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local theme = import("goluwa/render2d/ui/theme.lua")
local vfs = import("goluwa/vfs.lua")
local ErrorBoundary = react.ErrorBoundary
local section_order = {
	"Foundations",
	"Controls",
	"Containers",
	"Layout",
	"Data",
	"Overlays",
	"Graphics",
}

local function load_pages()
	local pages = {}

	for _, file in ipairs(vfs.Find("lua/gallery/%.lua$")) do
		local ok, page = pcall(import, "lua/gallery/" .. file)

		if ok then
			pages[#pages + 1] = page
		else
			print("failed to load gallery page " .. file .. ": " .. tostring(page))
		end
	end

	local rank = {}

	for index, name in ipairs(section_order) do
		rank[name] = index
	end

	table.sort(pages, function(a, b)
		if a.Section ~= b.Section then return rank[a.Section] < rank[b.Section] end

		return (a.Order or 100) < (b.Order or 100)
	end)

	return pages
end

local GalleryContext = react.CreateContext()
local SidebarItem = react.Memo(
	react.Component(
		|props|-> do
			local gallery = react.UseContext(GalleryContext)
			return MenuItem{
				Text = props.Page.Name,
				Padding = "S",
				Selected = props.Selected,
				OnClick = ||->gallery.select(props.Page),
			}
		end
	)
)

local function page_error(err)
	return Text{
		Text = "this page failed: " .. tostring(err),
		Color = "text_disabled",
		Wrap = true,
		layout = {GrowWidth = 1},
	}
end

local GalleryView = react.Component(
	|props|-> do
		local pages = react.UseState(load_pages)
		local selected, set_selected = react.UseState(props.SelectedPage)
		local theme_version, set_theme_version = react.UseState(0)
		local gallery = react.UseMemo(||->{select = |page|->set_selected(page.Name)}, {})
		local size = props.Size ?? Vec2(1280, 760)
		local position = react.UseMemo(||->props.Position ?? (Panel.World.transform:GetSize() - size) / 2, {})
		local current = pages[1]
		react.UseEvent("ThemeChanged", ||->set_theme_version(|version|->version + 1))

		for _, page in ipairs(pages) do
			if page.Name == selected then current = page end
		end

		local entries = {
			Text{
				Key = "theme label",
				Text = "THEME",
				Font = "body_strong XS",
				Color = "text_disabled",
				IgnoreMouseInput = true,
				layout = {Padding = "XS"},
			},
			Dropdown{
				Key = "theme",
				Options = theme.GetAvailable(),
				Value = theme.active:GetName(),
				Padding = "XS",
				OnSelect = |name|->theme.LoadTheme(name),
			},
		}
		local current_section

		for _, page in ipairs(pages) do
			if page.Section ~= current_section then
				current_section = page.Section
				entries[#entries + 1] = Text{
					Key = "section " .. current_section,
					Text = current_section:upper(),
					Font = "body_strong XS",
					Color = "text_disabled",
					IgnoreMouseInput = true,
					layout = {Padding = Rect(8, 16, 8, 4)},
				}
			end

			entries[#entries + 1] = SidebarItem{Key = page.Name, Page = page, Selected = page == current}
		end

		return GalleryContext.Provider{Value = gallery}{
			Window{
				Title = "UI GALLERY",
				Padding = "none",
				Size = size,
				Position = position,
			}{
				Splitter{InitialSize = 220}{
					ScrollablePanel{layout = {GrowHeight = 1}, Padding = "XS"}{
						Column{layout = {ChildGap = "XXS", GrowWidth = 1, AlignmentX = "stretch"}}{entries},
					},
					ScrollablePanel{
						Key = "page " .. current.Name .. " " .. theme_version,
						Padding = "M",
						layout = {GrowWidth = 1, GrowHeight = 1},
					}{
						ErrorBoundary{Fallback = page_error}{current.View{}},
					},
				},
			},
		}
	end
)
return function(props)
	return react.Mount(GalleryView(props), Panel.World):GetEntity()
end
