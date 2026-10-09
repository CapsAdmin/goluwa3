local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local vfs = import("goluwa/vfs.lua")
local META = Panel:CreateTemplate("ui_gallery")
META.Base = Window
META.Title = "UI GALLERY"
META:StartStorable()
META:GetSet("SelectedPage", nil)
META:EndStorable()
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

local function on_page_click(item)
	item.Gallery:SelectPage(item.Page)
end

local function on_theme_select(name, text, index, dropdown)
	theme.LoadTheme(name)
	dropdown.Gallery:Rebuild()
end

function META.PropDefaults(_, props)
	local size = props.Size or Vec2(1280, 760)
	return {
		Padding = "none",
		Size = size,
		Position = (Panel.World.transform:GetSize() - size) / 2,
	}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._pages = load_pages()
	local sidebar = Column{
		layout = {
			ChildGap = "XXS",
			GrowWidth = 1,
			AlignmentX = "stretch",
		},
	}
	local options = {}

	for index, name in ipairs(theme.GetAvailable()) do
		options[index] = name
	end

	sidebar:AddChild(
		Text{
			Text = "THEME",
			Font = "body_strong XS",
			Color = "text_disabled",
			IgnoreMouseInput = true,
			layout = {Padding = "XS"},
		}
	)
	sidebar:AddChild(
		Dropdown{
			Gallery = self,
			Options = options,
			Value = theme.active:GetName(),
			Padding = "XS",
			OnSelect = on_theme_select,
		}
	)
	self._page_items = {}
	local current_section

	for _, page in ipairs(self._pages) do
		if page.Section ~= current_section then
			current_section = page.Section
			sidebar:AddChild(
				Text{
					Text = current_section:upper(),
					Font = "body_strong XS",
					Color = "text_disabled",
					IgnoreMouseInput = true,
					layout = {Padding = Rect(8, 16, 8, 4)},
				}
			)
		end

		self._page_items[page] = sidebar:AddChild(
			MenuItem{
				Gallery = self,
				Page = page,
				Text = page.Name,
				Padding = "S",
				OnClick = on_page_click,
			}
		)
	end

	self._page_scroll = ScrollablePanel{
		Padding = "M",
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
		},
	}
	self:AddChild(
		Splitter{
			InitialSize = 220,
		}{
			ScrollablePanel{
				layout = {GrowHeight = 1},
				Padding = "XS",
			}{sidebar},
			self._page_scroll,
		}
	)
	self:SelectPage(self:find_page(self.SelectedPage) or self._pages[1])
end

function META:find_page(name)
	for _, page in ipairs(self._pages) do
		if page.Name == name then return page end
	end
end

function META:SelectPage(page)
	for other, item in pairs(self._page_items) do
		item:SetSelected(other == page)
	end

	self.SelectedPage = page.Name
	self._page_scroll:RemoveChildren()
	self._page_scroll:AddChild(page.Create())
	self._page_scroll:GetViewport().transform:SetScroll(Vec2(0, 0))
end

function META:Rebuild()
	local gallery = META.New{
		Key = self:GetKey(),
		Position = self.transform:GetPosition():Copy(),
		Size = self.transform:GetSize():Copy(),
		SelectedPage = self.SelectedPage,
	}

	if self:IsValid() then self:Remove() end

	return gallery
end

return META:Register()
