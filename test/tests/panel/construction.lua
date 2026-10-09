local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local order_log

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
