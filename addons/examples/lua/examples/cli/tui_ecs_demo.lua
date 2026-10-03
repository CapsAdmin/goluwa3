local HOTRELOAD = _G.HOTRELOAD
_G.HOTRELOAD = false
local TuiPanel = import("goluwa/cli/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local repl = import("goluwa/cli/repl.lua")
local Rect = import("goluwa/structs/rect.lua")

local function Node(config, extra_components)
	config.ComponentSet = config.ComponentSet or {}

	for _, c in ipairs({"layout", "tui_element"}) do
		local found = false

		for _, v in ipairs(config.ComponentSet) do
			if v == c then
				found = true

				break
			end
		end

		if not found then table.insert(config.ComponentSet, c) end
	end

	if extra_components then
		for _, c in ipairs(extra_components) do
			table.insert(config.ComponentSet, c)
		end
	end

	return TuiPanel.New(config)
end

local function BorderBox(config)
	return Node(config, {"tui_border"})
end

local function TextNode(config)
	return Node(config, {"tui_text"})
end

TuiPanel.World:RemoveChildren()
local root = Node{
	Name = "root",
	Parent = TuiPanel.World,
	layout = {
		Direction = "y",
		GrowWidth = 1,
		GrowHeight = 1,
	},
}
local header = BorderBox{
	Name = "header",
	Parent = root,
	tui_element = {ForegroundColor = {100, 180, 220}},
	tui_border = {Title = "TUI ECS Demo"},
	layout = {
		Direction = "x",
		GrowWidth = 1,
		MinSize = Vec2(0, 3),
		MaxSize = Vec2(0, 3),
		Padding = Rect(1, 1, 1, 1),
		ChildGap = 2,
		AlignmentY = "center",
	},
}
local header_title = TextNode{
	Name = "header_title",
	Parent = header,
	tui_element = {ForegroundColor = {180, 240, 255}},
	tui_text = {Text = "**Terminal UI** powered by the ECS layout engine"},
	layout = {GrowWidth = 1, FitHeight = true},
}
local header_status = TextNode{
	Name = "header_status",
	Parent = header,
	tui_element = {ForegroundColor = {120, 120, 120}},
	tui_text = {Text = "ctrl+c → repl"},
	layout = {FitWidth = true, FitHeight = true},
}
local main = Node{
	Name = "main",
	Parent = root,
	layout = {
		Direction = "x",
		GrowWidth = 1,
		GrowHeight = 1,
		ChildGap = 1,
	},
}
local sidebar = BorderBox{
	Name = "sidebar",
	Parent = main,
	ComponentSet = {"tui_resizable"},
	tui_element = {ForegroundColor = {120, 100, 160}},
	tui_border = {Title = "Components"},
	tui_resizable = {MinimumSize = Vec2(10, 0)},
	layout = {
		Direction = "y",
		MinSize = Vec2(22, 0),
		MaxSize = Vec2(22, 0),
		GrowHeight = 1,
		Padding = Rect(1, 1, 1, 1),
		ChildGap = 0,
	},
}
local sidebar_items = {
	{label = "tui_element", color = {140, 200, 140}},
	{label = "tui_text", color = {200, 200, 120}},
	{label = "tui_border", color = {160, 140, 220}},
	{label = "layout (2d)", color = {120, 180, 220}},
	{label = "transform(2d)", color = {200, 140, 120}},
}
local selected_sidebar = 1
local sidebar_rows = {}

for i, item in ipairs(sidebar_items) do
	local dim_color = {item.color[1] * 0.55, item.color[2] * 0.55, item.color[3] * 0.55}
	local row = Node(
		{
			Name = "sidebar_item_" .. i,
			Parent = sidebar,
			tui_element = {ForegroundColor = i == selected_sidebar and item.color or dim_color},
			layout = {GrowWidth = 1, FitHeight = true},
		},
		{"tui_text", "tui_mouse_input", "tui_clickable", "tui_animation"}
	)
	sidebar_rows[i] = row
	row.tui_text:SetText((i == selected_sidebar and "> " or "  ") .. item.label)
	row.tui_mouse_input:SetFocusOnClick(false)
	local my_i = i
	local my_item = item
	local my_dim = dim_color

	function row:OnHover(hovered)
		if selected_sidebar ~= my_i then
			local c = hovered and my_item.color or my_dim
			self.tui_animation:AnimateForeground("fg", c, 0.12)
		end
	end

	function row:OnClick()
		local old = sidebar_rows[selected_sidebar]

		if old and old:IsValid() then
			local old_item = sidebar_items[selected_sidebar]
			local old_dim = {
				old_item.color[1] * 0.55,
				old_item.color[2] * 0.55,
				old_item.color[3] * 0.55,
			}
			old.tui_animation:AnimateForeground("fg", old_dim, 0.2)
			old.tui_text:SetText("  " .. old_item.label)
		end

		selected_sidebar = my_i
		self.tui_animation:AnimateForeground("fg", my_item.color, 0.2)
		self.tui_text:SetText("> " .. my_item.label)
		TuiPanel.NeedsRedraw()
	end
end

local content = BorderBox{
	Name = "content",
	Parent = main,
	tui_element = {ForegroundColor = {100, 100, 100}},
	tui_border = {Title = "Output"},
	layout = {
		Direction = "y",
		GrowWidth = 1,
		GrowHeight = 1,
		Padding = Rect(1, 1, 1, 1),
		ChildGap = 1,
	},
}
local text_demo = BorderBox{
	Name = "text_demo",
	Parent = content,
	tui_element = {ForegroundColor = {80, 80, 80}},
	tui_border = {Title = "tui_text rendering"},
	layout = {
		Direction = "y",
		GrowWidth = 1,
		FitHeight = true,
		Padding = Rect(1, 1, 1, 1),
	},
}
local text_demo_content = TextNode{
	Name = "text_demo_content",
	Parent = text_demo,
	tui_element = {ForegroundColor = {200, 200, 200}},
	tui_text = {
		Text = table.concat(
			{
				"**Bold** text and __italic__ text via markdown-lite markup.",
				"",
				"- Bullet item one",
				"- Bullet item two",
				"- Bullet item three",
				"",
				"```",
				"local x = TuiPanel.New({ ... })",
				"```",
			},
			"\n"
		),
	},
	layout = {GrowWidth = 1, FitHeight = true},
}
local flex_demo = BorderBox{
	Name = "flex_demo",
	Parent = content,
	tui_element = {ForegroundColor = {80, 80, 80}},
	tui_border = {Title = "layout flexbox (GrowWidth)"},
	layout = {
		Direction = "x",
		GrowWidth = 1,
		MinSize = Vec2(0, 5),
		MaxSize = Vec2(0, 5),
		Padding = Rect(1, 1, 1, 1),
		ChildGap = 1,
		AlignmentY = "center",
	},
}
local flex_items = {
	{label = "1×", grow = 1, color = {180, 80, 80}},
	{label = "2×", grow = 2, color = {80, 160, 80}},
	{label = "3×", grow = 3, color = {80, 100, 200}},
}

for _, fi in ipairs(flex_items) do
	local box = BorderBox{
		Name = "flex_box_" .. fi.label,
		Parent = flex_demo,
		tui_element = {ForegroundColor = fi.color},
		tui_border = {},
		layout = {
			Direction = "y",
			GrowWidth = fi.grow,
			GrowHeight = 1,
			AlignmentX = "center",
			AlignmentY = "center",
			Padding = Rect(1, 1, 1, 1),
		},
	}
	TextNode{
		Name = "flex_label",
		Parent = box,
		tui_element = {ForegroundColor = fi.color},
		tui_text = {Text = fi.label},
		layout = {FitWidth = true, FitHeight = true},
	}
end

local align_demo = BorderBox{
	Name = "align_demo",
	Parent = content,
	tui_element = {ForegroundColor = {80, 80, 80}},
	tui_border = {Title = "AlignmentX: start / center / end"},
	layout = {
		Direction = "y",
		GrowWidth = 1,
		MinSize = Vec2(0, 5),
		MaxSize = Vec2(0, 5),
		Padding = Rect(1, 1, 1, 1),
		ChildGap = 0,
	},
}
local align_row = Node{
	Name = "align_row",
	Parent = align_demo,
	layout = {
		Direction = "x",
		GrowWidth = 1,
		GrowHeight = 1,
		ChildGap = 1,
	},
}
local align_items = {
	{label = "start", align = "start", color = {200, 140, 80}},
	{label = "center", align = "center", color = {80, 200, 140}},
	{label = "end", align = "end", color = {140, 80, 200}},
}

for _, ai in ipairs(align_items) do
	local col = Node{
		Name = "align_col_" .. ai.label,
		Parent = align_row,
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
			AlignmentX = ai.align,
			AlignmentY = "center",
		},
	}
	local inner = BorderBox{
		Name = "align_item_" .. ai.label,
		Parent = col,
		tui_element = {ForegroundColor = ai.color},
		tui_border = {},
		layout = {
			MinSize = Vec2(9, 3),
			MaxSize = Vec2(9, 3),
		},
	}
	TextNode{
		Name = "align_label",
		Parent = inner,
		tui_element = {ForegroundColor = ai.color},
		tui_text = {Text = ai.label},
		layout = {
			Margin = Rect(1, 1, 1, 0),
			FitWidth = true,
			FitHeight = true,
		},
	}
end

local input_demo = BorderBox{
	Name = "input_demo",
	Parent = content,
	tui_element = {ForegroundColor = {80, 80, 80}},
	tui_border = {Title = "tui_text (Editable=true, click to focus)"},
	layout = {
		Direction = "y",
		GrowWidth = 1,
		MinSize = Vec2(0, 7),
		MaxSize = Vec2(0, 7),
		Padding = Rect(1, 1, 1, 1),
	},
}
local input_field = TextNode{
	Name = "input_field",
	Parent = input_demo,
	tui_element = {ForegroundColor = {200, 200, 200}},
	tui_text = {
		Editable = true,
		ShowLinePrefix = true,
		ShowScrollbar = true,
		Text = "Type here...",
	},
	layout = {GrowWidth = 1, GrowHeight = 1},
}
local footer = BorderBox{
	Name = "footer",
	Parent = root,
	tui_element = {ForegroundColor = {80, 80, 80}},
	tui_border = {},
	layout = {
		Direction = "x",
		GrowWidth = 1,
		MinSize = Vec2(0, 3),
		MaxSize = Vec2(0, 3),
		Padding = Rect(1, 1, 1, 1),
		ChildGap = 1,
		AlignmentY = "center",
	},
}
local footer_cols = {
	{text = "ecs.tui_panel", color = {160, 160, 160}},
	{text = "layout reused from ecs.2d", color = {120, 180, 120}},
	{text = "ctrl+c → REPL", color = {180, 120, 120}},
}

for i, fc in ipairs(footer_cols) do
	TextNode{
		Name = "footer_col_" .. i,
		Parent = footer,
		tui_element = {ForegroundColor = fc.color},
		tui_text = {Text = fc.text},
		layout = {GrowWidth = 1, FitHeight = true},
	}
end

local popup = BorderBox{
	Name = "popup",
	Parent = root,
	ComponentSet = {"tui_mouse_input", "tui_draggable", "tui_animation"},
	tui_element = {ForegroundColor = {200, 160, 80}},
	tui_border = {Title = " drag me "},
	layout = {
		Floating = true,
		MinSize = Vec2(24, 5),
		MaxSize = Vec2(24, 5),
		FitWidth = true,
		FitHeight = true,
		Direction = "y",
		Padding = Rect(1, 1, 1, 1),
	},
}
popup.transform:SetSize(Vec2(24, 5))
popup.transform:SetPosition(Vec2(4, -5))
popup.tui_animation:AnimatePosition("slide_in", Vec2(4, 6), 0.35, "out_cubic")
TextNode{
	Name = "popup_text",
	Parent = popup,
	tui_element = {ForegroundColor = {220, 200, 140}},
	tui_text = {Text = "I'm a floating panel.\nDrag me anywhere!"},
	layout = {GrowWidth = 1, FitHeight = true},
}

root:AddLocalListener("OnLayoutUpdated", function()
	TuiPanel.NeedsRedraw()
end)

event.AddListener("TerminalResized", "tui_ecs_demo_resize", function(w, h)
	root.transform:SetSize(Vec2(w, h))
end)

if HOTRELOAD then repl.SetEnabled(false) end
