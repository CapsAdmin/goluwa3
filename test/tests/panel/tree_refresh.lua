local T = import("test/environment.lua")
local Tree = import("goluwa/render2d/ui/widgets/tree.lua")

local function make_items()
	return {
		{
			Key = "root",
			Text = "root",
			Children = {{Key = "a", Text = "a"}, {Key = "b", Text = "b"}},
		},
		{Key = "other", Text = "other"},
	}
end

T.Test2D("tree rebuilds its rows instead of adding another copy on every refresh", function()
	local tree = Tree{Items = make_items()}
	local count = #tree:GetChildren()
	T(count)[">"](0)

	for _ = 1, 3 do
		tree:SetItems(make_items())
		T(#tree:GetChildren())["=="](count)
	end

	tree:Remove()
end)
