local T = import("test/environment.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local utf8 = import("goluwa/utf8.lua")
local pretext = import("goluwa/pretext/init.lua")

local function new_mock_font()
	local font = {}

	function font:GetTextSize(str)
		str = tostring(str or "")
		local lines = str:split("\n", true)
		local width = 0

		for _, line in ipairs(lines) do
			width = math.max(width, utf8.length(line) * 8)
		end

		return width, math.max(1, #lines) * 8
	end

	function font:MeasureText(str)
		return self:GetTextSize(str)
	end

	function font:GetLineHeight()
		return 8
	end

	function font:GetSpaceAdvance()
		return 8
	end

	function font:GetTabAdvance(space_width, tab_size, current_width)
		return (space_width or 8) * (tab_size or 4)
	end

	function font:GetGlyphAdvance(char)
		return 8
	end

	function font:GetSpacing()
		return 0
	end

	function font:GetAscent()
		return 8
	end

	function font:GetDescent()
		return 0
	end

	function font:DrawText()
	end

	function font:WrapString(str, width)
		return pretext.wrap_text(str, width, self)
	end

	return font
end

T.Test("text component wrapped caret movement uses layout", function()
	local pnl = Panel.New{
		Name = "wrapped_text_component",
		transform = true,
		text = true,
	}

	pnl.transform:SetSize(Vec2(16, 64))
	pnl.text:SetFont(new_mock_font())
	pnl.text:SetEditable(true)
	pnl.text:SetWrap(true)
	pnl.text:SetText("abcdefgh")
	local second_line = pnl.text.wrap_layout_info.ranges[2]
	pnl.text.editor:SetCursor(1)

	T(pnl.text:GetLineColFromIndex(1))["=="](1, 1)
	pnl.text.editor:OnKeyInput("down")
	T(pnl.text.editor.Cursor)["=="](second_line.start)
	T(pnl.text:GetLineColFromIndex(pnl.text.editor.Cursor))["=="](2, 1)

	pnl:Remove()
end)

T.Test("text component wrapped hit testing uses layout", function()
	local pnl = Panel.New{
		Name = "wrapped_text_hit_test",
		transform = true,
		text = true,
	}

	pnl.transform:SetSize(Vec2(16, 64))
	pnl.text:SetFont(new_mock_font())
	pnl.text:SetWrap(true)
	pnl.text:SetText("abcdefgh")

	local lx, ly = pnl.text:GetTextOffset()
	local font = pnl.text:GetFont()
	local third_line = pnl.text.wrap_layout_info.ranges[3]
	local y = ly + font:GetLineHeight() * 2 + font:GetLineHeight() * 0.5

	local index = pnl.text:GetIndexAtPosition(lx + 1, y)
	T(index)["=="](third_line.start)
	T(pnl.text:GetLineColFromIndex(index))["=="](3, 1)

	pnl:Remove()
end)