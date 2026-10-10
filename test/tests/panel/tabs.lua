local T = import("test/environment.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local TabBar = import("goluwa/render2d/ui/widgets/tab_bar.lua")
local Tabs = import("goluwa/render2d/ui/widgets/tabs.lua")

T.Test2D("tab bar marks the active tab and only fires OnChange when another tab is clicked", function()
	local changes = {}
	local bar = TabBar{
		Tabs = {"One", "Two", "Three"},
		Value = "Two",
		OnChange = function(name)
			changes[#changes + 1] = name
		end,
	}
	local buttons = bar:GetChildren()
	T(#buttons)["=="](3)
	T(buttons[1]:GetState("mode"))["=="]("tab")
	T(buttons[1]:GetState("active"))["=="](false)
	T(buttons[2]:GetState("active"))["=="](true)
	buttons[2]:CallLocalEvent("OnClick")
	T(#changes)["=="](0)
	buttons[3]:CallLocalEvent("OnClick")
	T(changes[1])["=="]("Three")
	T(bar.Value)["=="]("Three")
	T(buttons[2]:GetState("active"))["=="](false)
	T(buttons[3]:GetState("active"))["=="](true)
	bar:SetValue("One")
	T(#changes)["=="](1)
	T(buttons[1]:GetState("active"))["=="](true)
	T(buttons[3]:GetState("active"))["=="](false)
	bar:Remove()
end)

T.Test2D("tab bar keeps its buttons while the tabs stay the same and hides when it has none", function()
	local bar = TabBar{Tabs = {"One", "Two"}}
	local first = bar:GetChildren()[1]
	bar:SetTabs({"One", "Two"})
	T(bar:GetChildren()[1] == first)["=="](true)
	bar:SetTabs({"One", "Two", "Three"})
	T(#bar:GetChildren())["=="](3)
	T(bar.visual:GetVisible())["=="](true)
	bar:SetTabs({})
	T(#bar:GetChildren())["=="](0)
	T(bar.visual:GetVisible())["=="](false)
	bar:Remove()
end)

T.Test2D("tabs takes its tab names from the pages and only lays out the page of the active tab", function()
	local changes = {}
	local one = Column{Tab = "One"}
	local two = Column{Tab = "Two"}
	local tabs = Tabs{
		OnChange = function(name)
			changes[#changes + 1] = name
		end,
	}{one, two}
	T(tabs.Value)["=="]("One")
	T(tabs:GetPage("Two") == two)["=="](true)
	T(one.visual:GetVisible())["=="](true)
	T(two.visual:GetVisible())["=="](false)
	tabs._bar:GetChildren()[2]:CallLocalEvent("OnClick")
	T(changes[1])["=="]("Two")
	T(tabs.Value)["=="]("Two")
	T(one.visual:GetVisible())["=="](false)
	T(two.visual:GetVisible())["=="](true)
	tabs:SetValue("One")
	T(#changes)["=="](1)
	T(one.visual:GetVisible())["=="](true)
	T(two.visual:GetVisible())["=="](false)
	tabs:Remove()
end)

T.Test2D("property editor lists the categories of the active tab only", function()
	local editor = PropertyEditor{
		Items = {
			{
				Key = "a",
				Text = "A",
				Tab = "One",
				Children = {{Key = "a/x", Text = "X", Type = "number", Value = 1}},
			},
			{
				Key = "b",
				Text = "B",
				Tab = "Two",
				Children = {{Key = "b/x", Text = "X", Type = "number", Value = 2}},
			},
		},
	}
	local buttons = editor._tab_bar:GetChildren()
	T(#buttons)["=="](2)
	T(editor._tab_bar.Value)["=="]("One")
	T(editor._row_infos["a/x"] ~= nil)["=="](true)
	T(editor._row_infos["b/x"] == nil)["=="](true)
	buttons[2]:CallLocalEvent("OnClick")
	T(editor:GetActiveTab())["=="]("Two")
	T(editor._row_infos["a/x"] == nil)["=="](true)
	T(editor._row_infos["b/x"] ~= nil)["=="](true)
	T(editor._tab_bar:GetChildren()[2] == buttons[2])["=="](true)
	editor:SetItems({{Key = "c", Text = "C", Children = {{Key = "c/x", Text = "X", Type = "number", Value = 3}}}})
	T(editor._tab_bar.visual:GetVisible())["=="](false)
	editor:Remove()
end)
