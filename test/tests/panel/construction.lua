local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local TabBar = import("goluwa/render2d/ui/widgets/tab_bar.lua")
local Collapsible = import("goluwa/render2d/ui/widgets/collapsible.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local MenuContainer = import("goluwa/render2d/ui/elements/menu_container.lua")
local MenuBar = import("goluwa/render2d/ui/widgets/menu_bar.lua")
local order_log

T.Test("derma skin images are available locally", function()
	local resource = import("goluwa/resource.lua")
	local vfs = import("goluwa/vfs.lua")
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/extras/", true)
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/", true)

	for _, path in ipairs{"textures/gui/skins/gmod.png", "textures/gui/skins/dark.png"} do
		if not vfs.GetAbsolutePath(path) then
			local done = false
			resource.Download(path):Then(function()
				done = true
			end)
			T.WaitUntilReal(function()
				return done
			end, 60, "downloading " .. path)
		end

		T(vfs.GetAbsolutePath(path) ~= nil)["=="](true)
	end
end)

local function create_ordered_template(name)
	local META = Panel:CreateTemplate(name)
	META.CMP.transform = {}
	META.CMP.layout = {}
	META:GetSet("Alpha", 0)
	META:GetSet("Beta", 0)
	META:GetSet("Gamma", 0)

	function META:SetAlpha(value)
		table.insert(order_log, "Alpha")
		self.Alpha = value
	end

	function META:SetBeta(value)
		table.insert(order_log, "Beta")
		self.Beta = value
	end

	function META:SetGamma(value)
		table.insert(order_log, "Gamma")
		self.Gamma = value
	end

	function META:SetZeta(value)
		table.insert(order_log, "Zeta")
	end

	function META:SetEta(value)
		table.insert(order_log, "Eta")
	end

	META:Register()
	return META
end

T.Test("props are applied in declaration order, then alphabetically for undeclared setters", function()
	local Ordered = create_ordered_template("test_ordered_props")

	for _ = 1, 5 do
		order_log = {}
		local panel = Ordered.New{Zeta = 1, Gamma = 1, Eta = 1, Beta = 1, Alpha = 1}
		T(table.concat(order_log, ","))["=="]("Alpha,Beta,Gamma,Eta,Zeta")
		panel:Remove()
	end
end)

T.Test("OnCreate runs after props are applied and never receives a props table", function()
	local META = Panel:CreateTemplate("test_oncreate_props")
	META.CMP.transform = {}
	META:GetSet("Label", "")
	local seen

	function META:OnCreate()
		META.BaseClass.OnCreate(self)
		seen = {label = self.Label, extra = self.Extra, argc = select("#", self)}
	end

	META:Register()
	local panel = META.New{Label = "hello", Extra = 42}
	T(seen.label)["=="]("hello")
	T(seen.extra)["=="](42)
	T(seen.argc)["=="](1)
	panel:Remove()
end)

T.Test("PropDefaults chain: derived defaults win over base, caller wins over both, nested tables merge", function()
	local Base = Panel:CreateTemplate("test_defaults_base")
	Base.CMP.transform = {}
	Base.CMP.layout = {}
	Base:GetSet("Mode", "a")
	Base:GetSet("Level", 0)

	function Base.PropDefaults(_, props)
		return {Mode = "base", Level = 1, layout = {GrowWidth = 1, GrowHeight = 1}}
	end

	Base:Register()
	local Derived = Panel:CreateTemplate("test_defaults_derived")
	Derived.Base = Base

	function Derived.PropDefaults(_, props)
		return {Level = props.Mode == "custom" and 20 or 2, layout = {GrowHeight = 0}}
	end

	Derived:Register()
	local plain = Derived.New{}
	T(plain.Mode)["=="]("base")
	T(plain.Level)["=="](2)
	T(plain.layout:GetGrowWidth())["=="](1)
	T(plain.layout:GetGrowHeight())["=="](0)
	local given = Derived.New{Mode = "custom", layout = {GrowWidth = 0.5}}
	T(given.Mode)["=="]("custom")
	T(given.Level)["=="](20)
	T(given.layout:GetGrowWidth())["=="](0.5)
	T(given.layout:GetGrowHeight())["=="](0)
	plain:Remove()
	given:Remove()
end)

T.Test("construction does not mutate the caller's props", function()
	local called
	local props = {
		Name = "Untouched",
		Ref = function(self)
			called = self
		end,
		Tooltip = "tip",
		layout = {GrowWidth = 1},
		transform = {Size = Vec2(10, 10)},
	}
	local panel = Panel.New(props)
	T(called)["=="](panel)
	T(props.Ref ~= nil)["=="](true)
	T(props.Tooltip)["=="]("tip")
	T(props.layout.GrowWidth)["=="](1)
	T(props.transform.Size.x)["=="](10)
	panel:Remove()
end)

T.Test2D("Ref and Parent are handled by the core for every widget", function()
	local parent = Panel.New{}
	local ref local
	button = Button{
		Text = "x",
		Parent = parent,
		Ref = function(self)
			ref = self
		end,
	}
	T(ref)["=="](button)
	T(button:GetParent())["=="](parent)
	T(button.Tooltip)["=="](nil)
	parent:Remove()
end)

T.Test("nested prop tables and children merge into a flat construction", function()
	local child = Panel.New{Name = "child"}
	local panel = Panel.New{
		Name = "first",
		{Name = "second", layout = {GrowWidth = 1}},
		child,
		{layout = {GrowHeight = 1}},
	}
	T(panel.Name)["=="]("second")
	T(panel.layout:GetGrowWidth())["=="](1)
	T(panel.layout:GetGrowHeight())["=="](1)
	T(child:GetParent())["=="](panel)
	panel:Remove()
end)

T.Test2D("theme tokens are re-resolved when the theme changes", function()
	local original = theme.active:GetName()
	theme.LoadTheme("base")
	local panel = Panel.New{
		layout = {Padding = "L", ChildGap = "M"},
		transform = {Size = "XL"},
	}
	local button = Button{Text = "hi", Font = "heading", Padding = "M"}
	local base_padding = panel.layout:GetPadding().x
	local base_font = button.label.text:GetFont()
	theme.LoadTheme("playful")
	T(panel.layout:GetPadding().x)["=="](theme.active:GetSize("L"))
	T(panel.layout:GetChildGap())["=="](theme.active:GetSize("M"))
	T(panel.transform:GetSize().x)["=="](theme.active:GetSize("XL"))
	T(button.label.text:GetFont() ~= base_font)["=="](true)
	T(button.label.text:GetFont():GetSize())["=="](theme.active:ResolveFontSize("M"))
	theme.LoadTheme("base")
	T(panel.layout:GetPadding().x)["=="](base_padding)
	panel:Remove()
	button:Remove()
	theme.LoadTheme(original)
end)

T.Test2D("theme switching keeps values the user set explicitly afterwards", function()
	local original = theme.active:GetName()
	theme.LoadTheme("base")
	local panel = Panel.New{layout = {Padding = "L"}}
	panel.layout:SetPadding(Rect() + 3)
	theme.LoadTheme("playful")
	T(panel.layout:GetPadding().x)["=="](3)
	panel:Remove()
	theme.LoadTheme(original)
end)

T.Test2D("dynamic theme defaults follow the theme", function()
	local original = theme.active:GetName()
	theme.LoadTheme("base")
	local button = Button{Text = "dyn"}
	local base_height = button.layout:GetMinSize().y
	T(base_height)["=="](theme.active:GetInputHeight("M"))
	theme.LoadTheme("jrpg")
	T(button.layout:GetMinSize().y)["=="](theme.active:GetInputHeight("M"))
	local fixed = Button{Text = "fixed", layout = {MinSize = Vec2(0, 99)}}
	theme.LoadTheme("base")
	T(fixed.layout:GetMinSize().y)["=="](99)
	button:Remove()
	fixed:Remove()
	theme.LoadTheme(original)
end)

T.Test2D("retro theme draws text with a shadow", function()
	local original = theme.active:GetName()
	theme.LoadTheme("retro")
	local shadow_x, shadow_y, shadow = theme.active:GetTextShadow(theme.active:GetColor("text"))
	T(shadow_x)["=="](1)
	T(shadow_y)["=="](1)
	T(shadow ~= nil)["=="](true)
	theme.LoadTheme("base")
	T(theme.active:GetTextShadow(theme.active:GetColor("text")))["=="](nil)
	theme.LoadTheme(original)
end)

T.Test2D("themes can draw their icons aliased", function()
	local active = theme.active
	local style = active:GetIconStyle()
	T(active:GetIcon("close"):GetAliased())["=="](false)
	active:SetIconStyle(active:MergeTables(style, {Aliased = true}))
	T(active:GetIcon("close"):GetAliased())["=="](true)
	active:SetIconStyle(style)
	T(active:GetIcon("close"):GetAliased())["=="](false)
end)

T.Test2D("retro theme draws its icons aliased", function()
	local original = theme.active:GetName()
	theme.LoadTheme("retro")
	T(theme.active:GetIcon("close"):GetAliased())["=="](true)
	theme.LoadTheme(original)
end)

T.Test2D("every theme defines a color for text inside inputs", function()
	local original = theme.active:GetName()

	for _, name in ipairs(theme.GetAvailable()) do
		theme.LoadTheme(name)
		T(theme.active:HasPaletteToken("text_input"))["=="](true)
	end

	theme.LoadTheme(original)
end)

T.Test2D("derma theme loads its skin texture and samples its colors", function()
	local original = theme.active:GetName()
	theme.LoadTheme("derma")
	T(theme.active.SkinImage.width)["=="](512)
	T(theme.active.SkinTexture ~= nil)["=="](true)
	T(theme.active:GetColor("text_input").r < 0.2)["=="](true)
	T(theme.active:ResolveButtonStyleContext({mode = "menu"}).foreground_token)["=="](nil)
	T(theme.active:ResolveButtonStyleContext({mode = "menu", button_color = "positive"}).foreground_token)["=="](nil)
	T(theme.active:ResolveButtonStyleContext({mode = "text"}).foreground_token)["=="](nil)
	T(theme.active:ResolveButtonStyleContext({mode = "text", disabled = true}).foreground_token)["=="]("text_disabled")
	T(theme.active:ResolveButtonStyleContext({mode = "outline", theme_role = "dropdown"}).foreground_token)["=="]("text_combo")
	T(theme.active:ResolveButtonStyleContext({mode = "outline"}).foreground_token ~= "text_combo")["=="](true)
	theme.LoadTheme(original)
end)

T.Test2D("buttons recompute their style when the theme changes", function()
	local original = theme.active:GetName()
	theme.LoadTheme("base")
	local button = Button{Text = "x", ButtonColor = "positive"}
	T(button.style:GetForegroundColor())["=="]("text_on_accent")
	theme.LoadTheme("retro")
	T(button.style:GetForegroundColor())["=="]("ink")
	theme.LoadTheme("base")
	T(button.style:GetForegroundColor())["=="]("text_on_accent")
	button:Remove()
	theme.LoadTheme(original)
end)

T.Test2D("dropdowns tag themselves with a theme role", function()
	local dropdown = Dropdown{Options = {"a", "b"}, Value = "a"}
	T(dropdown:GetState("theme_role"))["=="]("dropdown")
	dropdown:Remove()
end)

T.Test2D("tabs overlap their neighbours by one pixel in every theme", function()
	local original = theme.active:GetName()

	for _, name in ipairs(theme.GetAvailable()) do
		theme.LoadTheme(name)
		local tab_bar = TabBar{Tabs = {"One", "Two", "Three"}, Value = "One"}
		tab_bar.layout:UpdateLayout()
		local first = tab_bar._buttons[1].transform
		local second = tab_bar._buttons[2].transform
		local third = tab_bar._buttons[3].transform
		T(second:GetX())["=="](first:GetX() + first:GetWidth() - 1)
		T(third:GetX())["=="](second:GetX() + second:GetWidth() - 1)
		tab_bar:Remove()
	end

	theme.LoadTheme(original)
end)

T.Test2D("content surfaces take their text color from the theme", function()
	local original = theme.active:GetName()
	theme.LoadTheme("base")
	local frame = Frame{}
	local window = Window{Title = "x"}
	local menu = MenuContainer{}
	local bar = MenuBar{Items = {{Text = "File", Items = {}}}}
	local collapsible = Collapsible{Title = "x"}
	local styles = {frame.style, window._content.style, menu.style, bar.style, collapsible._body.style}
	T(#styles)["=="](5)

	for i = 1, 5 do
		T(styles[i]:GetForegroundColor())["=="](nil)
	end

	theme.active:SetContentForeground("heading")
	frame:OnThemeChanged()
	window:OnThemeChanged()
	menu:OnThemeChanged()
	bar:OnThemeChanged()
	collapsible:OnThemeChanged()

	for i = 1, 5 do
		T(styles[i]:GetForegroundColor())["=="]("heading")
	end

	theme.active:SetContentForeground(nil)
	frame:OnThemeChanged()
	T(frame.style:GetForegroundColor())["=="](nil)
	T(collapsible._header:GetState("theme_role"))["=="]("collapsible_header")
	frame:Remove()
	window:Remove()
	menu:Remove()
	bar:Remove()
	collapsible:Remove()
	theme.LoadTheme(original)
end)

T.Test2D("derma_dark is the derma theme with another skin image", function()
	local original = theme.active:GetName()
	theme.LoadTheme("derma")
	local derma_path = theme.active.SkinPath
	T(derma_path:ends_with("gmod.png"))["=="](true)
	theme.LoadTheme("derma_dark")
	T(theme.active:GetName())["=="]("derma_dark")
	T(theme.active.SkinPath ~= derma_path)["=="](true)
	T(theme.active.SkinImage.width)["=="](512)
	theme.LoadTheme(original)
end)

T.Test2D("derma picks readable text colors from the luminance of the skin regions", function()
	local original = theme.active:GetName()

	for _, name in ipairs{"derma", "derma_dark"} do
		theme.LoadTheme(name)
		local panel_text = theme.active:GetColor("text_content")
		local panel = theme.active.SkinPanelColor
		local panel_luma = panel.r * 0.299 + panel.g * 0.587 + panel.b * 0.114
		local text_luma = panel_text.r * 0.299 + panel_text.g * 0.587 + panel_text.b * 0.114
		T((panel_luma > 0.5) == (text_luma < 0.5))["=="](true)
	end

	theme.LoadTheme(original)
end)

T.Test2D("derma gives content surfaces their readable text color", function()
	local original = theme.active:GetName()
	theme.LoadTheme("base")
	local frame = Frame{}
	local window = Window{Title = "x"}
	local menu = MenuContainer{}
	local bar = MenuBar{Items = {{Text = "File", Items = {}}}}
	local collapsible = Collapsible{Title = "x"}
	local styles = {frame.style, window._content.style, menu.style, bar.style, collapsible._body.style}

	for _, name in ipairs{"derma", "derma_dark", "base"} do
		theme.LoadTheme(name)

		for i = 1, 5 do
			T(styles[i]:GetForegroundColor())["=="](name ~= "base" and "text_content" or nil)
		end
	end

	frame:Remove()
	window:Remove()
	menu:Remove()
	bar:Remove()
	collapsible:Remove()
	theme.LoadTheme(original)
end)
