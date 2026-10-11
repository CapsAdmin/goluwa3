local T = import("test/environment.lua")
local Tree = import("goluwa/render2d/ui/widgets/tree.lua")

T.Test2D("tree rows inherit their text color unless a node or callback sets one", function()
	local tree = Tree{Items = {{Key = "a", Text = "a"}}}
	T(tree:get_text_token({Key = "a"}, {1}, "a"))["=="](nil)
	T(tree:get_text_token({Key = "a", TextColor = "negative"}, {1}, "a"))["=="]("negative")
	T(tree:get_text_token({Key = "a", Disabled = true}, {1}, "a"))["=="]("text_disabled")
	tree.OnGetTextColor = function()
		return "positive"
	end
	T(tree:get_text_token({Key = "a", TextColor = "negative"}, {1}, "a"))["=="]("positive")
	tree:Remove()
end)
