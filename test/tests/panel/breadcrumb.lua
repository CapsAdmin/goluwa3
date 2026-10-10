local T = import("test/environment.lua")
local Breadcrumb = import("goluwa/render2d/ui/widgets/breadcrumb.lua")

T.Test2D("breadcrumb makes every crumb but the last one clickable and reports its index", function()
	local selected = {}
	local bar = Breadcrumb{
		Items = {"scene", "house", "door"},
		OnSelect = function(index)
			selected[#selected + 1] = index
		end,
	}
	local children = bar:GetChildren()
	-- crumb, separator, crumb, separator, label
	T(#children)["=="](5)
	children[1]:CallLocalEvent("OnClick")
	children[3]:CallLocalEvent("OnClick")
	T(#selected)["=="](2)
	T(selected[1])["=="](1)
	T(selected[2])["=="](2)
	bar:Remove()
end)

T.Test2D("breadcrumb only rebuilds when the items changed and hides when it has none", function()
	local bar = Breadcrumb{Items = {"a", "b"}}
	local first = bar:GetChildren()[1]
	bar:SetItems({"a", "b"})
	T(bar:GetChildren()[1] == first)["=="](true)
	bar:SetItems({"a", "b", "c"})
	T(#bar:GetChildren())["=="](5)
	T(bar.visual:GetVisible())["=="](true)
	bar:SetItems({})
	T(#bar:GetChildren())["=="](0)
	T(bar.visual:GetVisible())["=="](false)
	bar:Remove()
end)
