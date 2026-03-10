local HOTRELOAD = _G.HOTRELOAD
_G.HOTRELOAD = false
local TuiPanel = require("ecs.tui_panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local event = require("event")
local repl = require("repl")
local Agent = require("llamacpp.agent")
local tasks = require("tasks")
local palette = {
	panel = {100, 100, 100},
	header = {100, 180, 220},
	header_text = {180, 240, 255},
	user_border = {120, 180, 120},
	user_text = {180, 220, 180},
	assistant_border = {100, 100, 100},
	assistant_text = {200, 200, 200},
	thinking_text = {120, 120, 120},
	tool_border = {180, 180, 50},
	tool_text = {220, 220, 100},
	muted = {120, 120, 120},
	scrollbar = {150, 150, 150},
}

local function clamp(value, min, max)
	if value < min then return min end

	if value > max then return max end

	return value
end

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

local function Spacer(parent, name)
	return Node(
		{
			Name = name,
			Parent = parent,
			layout = {
				GrowWidth = 1,
				MinSize = Vec2(1, 0),
			},
		}
	)
end

local function get_text(node)
	if not node or not node:IsValid() then return "" end

	return node.tui_text:GetText() or ""
end

TuiPanel.World:RemoveChildren()
local state = {
	history = {},
	tool_slots = {},
	auto_follow = true,
	running = false,
	current_assistant = nil,
	last_tool_name = nil,
	focused_once = false,
	last_input_lines = 0,
	last_input_height = 0,
}
local root = Node(
	{
		Name = "root",
		Parent = TuiPanel.World,
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
			ChildGap = 1,
		},
	}
)
local header = BorderBox(
	{
		Name = "header",
		Parent = root,
		tui_element = {ForegroundColor = palette.header},
		tui_border = {Title = "TUI ECS Chat"},
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
)
local header_title = TextNode(
	{
		Name = "header_title",
		Parent = header,
		tui_element = {ForegroundColor = palette.header_text},
		tui_text = {Text = "**Chat UI** powered by ecs.tui_panel + llamacpp.agent"},
		layout = {GrowWidth = 1, FitHeight = true},
	}
)
local header_status = TextNode(
	{
		Name = "header_status",
		Parent = header,
		tui_element = {ForegroundColor = palette.muted},
		tui_text = {Text = "idle"},
		layout = {FitWidth = true, FitHeight = true},
	}
)
local history_shell = BorderBox(
	{
		Name = "history_shell",
		Parent = root,
		tui_element = {ForegroundColor = palette.panel},
		tui_border = {Title = "Conversation"},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
			Padding = Rect(1, 1, 1, 1),
		},
	}
)
local history_viewport = Node(
	{
		Name = "history_viewport",
		Parent = history_shell,
		ComponentSet = {"tui_mouse_input"},
		tui_element = {Clipping = true},
		transform = {ScrollEnabled = true},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
			AlignmentY = "start",
			AlignmentX = "stretch",
			MinSize = Vec2(1, 1),
			MaxSize = Vec2(0, 1),
		},
		OnMouseWheel = function(self, delta)
			local content = self.layout.content_size
			local height = self.transform:GetHeight()

			if not content or content.y <= height then return true end

			local max_scroll = math.max(0, content.y - height)
			local scroll = self.transform:GetScroll():Copy()
			scroll.y = clamp(scroll.y - delta * 3, 0, max_scroll)
			self.transform:SetScroll(scroll)
			state.auto_follow = scroll.y >= max_scroll - 1
			TuiPanel.NeedsRedraw()
			return true
		end,
	}
)
local history_content = Node(
	{
		Name = "history_content",
		Parent = history_viewport,
		layout = {
			Direction = "y",
			GrowWidth = 1,
			FitHeight = true,
			ChildGap = 1,
			AlignmentX = "stretch",
			AlignmentY = "start",
		},
	}
)
local history_scrollbar = Node(
	{
		Name = "history_scrollbar",
		Parent = history_shell,
		tui_element = {ForegroundColor = palette.scrollbar},
		layout = {Floating = true},
		OnDraw = function(self, term, abs_x, abs_y, w, h)
			local content = history_viewport.layout.content_size

			if not content or content.y <= h or h <= 0 then return end

			for i = 0, h - 1 do
				term:SetCaretPosition(abs_x, abs_y + i)
				term:WriteText("░")
			end

			local total_h = content.y
			local scroll = history_viewport.transform:GetScroll().y
			local bar_h = math.max(1, math.floor(h * (h / total_h)))
			local max_scroll = math.max(1, total_h - h)
			local fraction = scroll / max_scroll
			local bar_y = abs_y + math.floor((h - bar_h) * fraction)

			for i = 0, bar_h - 1 do
				term:SetCaretPosition(abs_x, bar_y + i)
				term:WriteText("█")
			end
		end,
	}
)
local composer = BorderBox(
	{
		Name = "composer",
		Parent = root,
		tui_element = {ForegroundColor = palette.panel},
		tui_border = {Title = "Compose"},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			MinSize = Vec2(0, 3),
			MaxSize = Vec2(0, 3),
			Padding = Rect(1, 1, 1, 1),
		},
	}
)
local input_field = TextNode(
	{
		Name = "input_field",
		Parent = composer,
		tui_element = {ForegroundColor = palette.assistant_text},
		tui_text = {
			Editable = true,
			ShowLinePrefix = true,
			ShowScrollbar = true,
			Text = "",
		},
		layout = {GrowWidth = 1, GrowHeight = 1},
	}
)
local footer = BorderBox(
	{
		Name = "footer",
		Parent = root,
		tui_element = {ForegroundColor = palette.panel},
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
)
local footer_model = TextNode(
	{
		Name = "footer_model",
		Parent = footer,
		tui_element = {ForegroundColor = {160, 160, 160}},
		tui_text = {Text = "Qwen3.5-35B-A3B-UD-Q4_K_XL"},
		layout = {GrowWidth = 1, FitHeight = true},
	}
)
local footer_stats = TextNode(
	{
		Name = "footer_stats",
		Parent = footer,
		tui_element = {ForegroundColor = {120, 180, 120}},
		tui_text = {Text = "messages: 0"},
		layout = {GrowWidth = 1, FitHeight = true},
	}
)
local footer_help = TextNode(
	{
		Name = "footer_help",
		Parent = footer,
		tui_element = {ForegroundColor = {180, 120, 120}},
		tui_text = {Text = "enter → send  ·  alt+enter → newline  ·  ctrl+c → repl"},
		layout = {GrowWidth = 1, FitHeight = true},
	}
)

local function sync_status()
	header_status.tui_text:SetText(state.running and "thinking..." or "idle")
	footer_stats.tui_text:SetText("messages: " .. tostring(#state.history))
	TuiPanel.NeedsRedraw()
end

local function sync_scrollbar_geometry()
	local w = history_shell.transform:GetWidth()
	local h = history_shell.transform:GetHeight()
	history_scrollbar.transform:SetPosition(Vec2(math.max(1, w - 2), 2))
	history_scrollbar.transform:SetSize(Vec2(1, math.max(0, h - 2)))
end

local function get_history_bubble_width()
	local inner_w = math.max(18, history_viewport.transform:GetWidth())
	return clamp(math.floor(inner_w * 0.72), 24, math.max(24, inner_w))
end

local function update_wrapped_height(text_node, width)
	local text = get_text(text_node)
	local wanted_h = 0

	if text ~= "" then
		local _, text_h = text_node.tui_text:GetTextSize(math.max(1, width))
		wanted_h = math.max(1, text_h)
	end

	if text_node._wrapped_width == width and text_node._wrapped_height == wanted_h then
		return
	end

	text_node._wrapped_width = width
	text_node._wrapped_height = wanted_h
	text_node.layout:SetMinSize(Vec2(0, wanted_h))
	text_node.layout:SetMaxSize(Vec2(0, wanted_h))
end

local function update_message_layout(msg)
	if not msg or not msg.bubble:IsValid() then return end

	local bubble_w = get_history_bubble_width()

	if msg.bubble_width ~= bubble_w then
		msg.bubble_width = bubble_w
		msg.bubble.layout:SetMinSize(Vec2(bubble_w, 0))
		msg.bubble.layout:SetMaxSize(Vec2(bubble_w, 0))
	end

	local inner_w = math.max(1, bubble_w - 2)
	update_wrapped_height(msg.thoughts, inner_w)
	update_wrapped_height(msg.content, inner_w)
end

local function sync_history_scroll(force_bottom)
	local content = history_viewport.layout.content_size
	local height = history_viewport.transform:GetHeight()

	if not content then return end

	local max_scroll = math.max(0, content.y - height)
	local scroll = history_viewport.transform:GetScroll():Copy()
	local target_y

	if force_bottom == true then
		target_y = max_scroll
	elseif type(force_bottom) == "number" then
		target_y = clamp(force_bottom, 0, max_scroll)
	elseif state.auto_follow then
		target_y = max_scroll
	else
		target_y = clamp(scroll.y, 0, max_scroll)
	end

	if scroll.y ~= target_y then
		scroll.y = target_y
		history_viewport.transform:SetScroll(scroll)
	end
end

local function refresh_history_layout(force_bottom)
	for _, msg in ipairs(state.history) do
		update_message_layout(msg)
	end

	history_content.layout:InvalidateLayout()
	history_viewport.layout:InvalidateLayout()
	sync_history_scroll(force_bottom)
	TuiPanel.NeedsRedraw()
end

local function create_message(role, options)
	options = options or {}
	local align = options.align or "left"
	local id = tostring(#state.history + 1)
	local row = Node(
		{
			Name = "chat_row_" .. id,
			Parent = history_content,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				FitHeight = true,
			},
		}
	)

	if align == "right" then Spacer(row, "spacer_l_" .. id) end

	local bubble = BorderBox(
		{
			Name = "chat_bubble_" .. id,
			Parent = row,
			tui_element = {ForegroundColor = options.border_color},
			tui_border = {
				Title = options.title or role,
				TitleAlign = align == "right" and "right" or "left",
			},
			layout = {
				Direction = "y",
				FitHeight = true,
				Padding = Rect(1, 1, 1, 1),
				ChildGap = 1,
				MinSize = Vec2(24, 0),
				MaxSize = Vec2(24, 0),
			},
		}
	)

	if align ~= "right" then Spacer(row, "spacer_r_" .. id) end

	local thoughts = TextNode(
		{
			Name = "thoughts_" .. id,
			Parent = bubble,
			tui_element = {ForegroundColor = options.thought_color or palette.thinking_text},
			tui_text = {Text = ""},
			layout = {GrowWidth = 1, FitHeight = true},
		}
	)
	local content = TextNode(
		{
			Name = "content_" .. id,
			Parent = bubble,
			tui_element = {ForegroundColor = options.text_color},
			tui_text = {Text = options.text or ""},
			layout = {GrowWidth = 1, FitHeight = true},
		}
	)
	local msg = {
		role = role,
		align = align,
		row = row,
		bubble = bubble,
		thoughts = thoughts,
		content = content,
	}

	bubble:AddLocalListener("OnLayoutUpdated", function()
		update_message_layout(msg)
	end)

	bubble:AddLocalListener("OnTransformChanged", function()
		update_message_layout(msg)
	end)

	table.insert(state.history, msg)
	update_message_layout(msg)
	sync_status()
	return msg
end

local function ensure_assistant_message()
	if state.current_assistant and state.current_assistant.bubble:IsValid() then
		return state.current_assistant
	end

	local last = state.history[#state.history]

	if
		last and
		last.role == "assistant" and
		get_text(last.content) == "" and
		get_text(last.thoughts) == ""
	then
		state.current_assistant = last
		return last
	end

	state.current_assistant = create_message(
		"assistant",
		{
			title = "assistant",
			align = "left",
			border_color = palette.assistant_border,
			text_color = palette.assistant_text,
			thought_color = palette.thinking_text,
		}
	)
	return state.current_assistant
end

local function append_to_node(node, chunk)
	if not node or not node:IsValid() then return end

	node.tui_text:SetText(get_text(node) .. chunk)
end

local function set_node_text(node, text)
	if not node or not node:IsValid() then return end

	node.tui_text:SetText(text or "")
end

local function normalize_error_message(err)
	err = tostring(err or "unknown error")
	local prefix, rest = err:match("^(.-:%d+:)%s*(.+)$")

	if prefix and rest then
		local duplicated = prefix .. " "

		if rest:sub(1, #duplicated) == duplicated then
			rest = rest:sub(#duplicated + 1)
		elseif rest:sub(1, #prefix) == prefix then
			rest = rest:sub(#prefix + 1):gsub("^%s*", "")
		end

		return rest ~= "" and rest or err
	end

	return err
end

local function show_agent_error(err)
	state.running = false
	state.last_tool_name = nil
	state.current_assistant = nil
	local msg = create_message(
		"assistant",
		{
			title = "assistant",
			align = "left",
			border_color = palette.assistant_border,
			text_color = palette.assistant_text,
		}
	)
	set_node_text(msg.content, "Error: " .. normalize_error_message(err))
	refresh_history_layout(state.auto_follow)
	sync_status()
	return msg
end

local function find_latest_tool_message(name)
	local msg = state.tool_slots[name]

	if msg and msg.bubble:IsValid() then return msg end

	for i = #state.history, 1, -1 do
		local item = state.history[i]

		if item.role == "tool" and item.tool_name == name then return item end
	end
end

local function ensure_tool_message(name, args)
	local msg = find_latest_tool_message(name)

	if msg then
		if args and args ~= "" and get_text(msg.content) == "[Tool: " .. name .. "]" then
			set_node_text(msg.content, "[Tool: " .. name .. "]\n" .. args)
		end

		return msg
	end

	msg = create_message(
		"tool",
		{
			title = "tool",
			align = "left",
			border_color = palette.tool_border,
			text_color = palette.tool_text,
		}
	)
	msg.tool_name = name
	state.tool_slots[name] = msg
	set_node_text(
		msg.content,
		"[Tool: " .. name .. "]" .. (args and args ~= "" and "\n" .. args or "")
	)
	return msg
end

local agent = Agent.New("Qwen3.5-35B-A3B-UD-Q4_K_XL")
agent:AddMessage(
	{
		role = "system",
		content = "You are a helpful assistant directly integrated into a TUI. Keep your responses concise and naturally formatted.",
	},
	true
)

function agent:OnLogEvent(ev)
	if ev.type == "role" then
		if ev.role == "user" then
			state.current_assistant = nil
			create_message(
				"user",
				{
					title = "user",
					align = "right",
					border_color = palette.user_border,
					text_color = palette.user_text,
				}
			)
		elseif ev.role == "assistant" then
			local last = state.history[#state.history]

			if
				not (
					last and
					last.role == "assistant" and
					get_text(last.content) == "" and
					get_text(last.thoughts) == ""
				)
			then
				ensure_assistant_message()
			else
				state.current_assistant = last
			end
		end
	elseif ev.type == "message_content" then
		local last = state.history[#state.history]

		if last then append_to_node(last.content, tostring(ev.content or "")) end
	elseif ev.type == "content_token" then
		append_to_node(ensure_assistant_message().content, tostring(ev.content or ""))
	elseif ev.type == "reasoning_token" then
		append_to_node(ensure_assistant_message().thoughts, tostring(ev.content or ""))
	elseif ev.type == "tool_call_start" then
		state.last_tool_name = ev.name
		ensure_tool_message(ev.name, ev.args)
	elseif ev.type == "tool_call_arg_fragment" then
		if state.last_tool_name then
			local msg = ensure_tool_message(state.last_tool_name)
			append_to_node(msg.content, tostring(ev.fragment or ""))
		end
	elseif ev.type == "tool_execute" then
		local msg = ensure_tool_message(ev.name, ev.args)
		append_to_node(msg.content, "\n[Executing " .. tostring(ev.name) .. "...]")
	elseif ev.type == "tool_result" then
		local msg = ensure_tool_message(ev.slot_id or state.last_tool_name or "tool")
		append_to_node(msg.content, "\n[Result: " .. tostring(ev.result) .. "]")
	elseif ev.type == "tool_error" then
		local msg = ensure_tool_message(ev.slot_id or state.last_tool_name or "tool")
		append_to_node(msg.content, "\n[Error: " .. tostring(ev.error) .. "]")
	elseif ev.type == "tool_waiting" then
		state.running = true
	elseif ev.type == "finished" or ev.type == "run_end" or ev.type == "truncated" then
		state.running = false
		state.current_assistant = nil
		state.last_tool_name = nil
	end

	refresh_history_layout(state.auto_follow)
	sync_status()
end

local function submit_input()
	if state.running then return true end

	local text = input_field.tui_text:GetEditorText() or ""

	if text == "" then return true end

	state.running = true
	sync_status()
	agent:AddMessage({role = "user", content = text})
	tasks.CreateTask(
		function()
			agent:RunAsync()
		end,
		nil,
		true,
		function(_, err)
			show_agent_error(err)
		end
	)
	local editor = input_field.tui_text:GetEditor()

	if editor then
		editor:SetText("")
		editor:SetCursor(1)
		editor:SetSelectionStart(nil)
	end

	input_field:RequestFocus()
	refresh_history_layout(state.auto_follow)
	return true
end

function input_field:OnKeyInput(key, press, modifiers)
	if not press then return end

	if key == "enter" or key == "return" or key == "kp_enter" then
		if modifiers and modifiers.alt then return end

		return submit_input()
	end
end

history_content:AddLocalListener("OnLayoutUpdated", function()
	sync_history_scroll(false)
	sync_scrollbar_geometry()
	TuiPanel.NeedsRedraw()
end)

history_viewport:AddLocalListener("OnLayoutUpdated", function()
	sync_history_scroll(false)
	sync_scrollbar_geometry()
	TuiPanel.NeedsRedraw()
end)

history_shell:AddLocalListener("OnLayoutUpdated", function()
	sync_scrollbar_geometry()
	refresh_history_layout(false)
end)

history_shell:AddLocalListener("OnTransformChanged", function()
	sync_scrollbar_geometry()
	refresh_history_layout(false)
end)

root:AddLocalListener("OnLayoutUpdated", function()
	TuiPanel.NeedsRedraw()
end)

event.AddListener("TerminalResized", "tui_ecs_chat_resize", function(w, h)
	root.transform:SetSize(Vec2(w, h))
	refresh_history_layout(false)
end)

event.AddListener("Update", "tui_ecs_chat_tick", function()
	if repl.GetEnabled() then
		state.focused_once = false
		return
	end

	if not state.focused_once then
		state.focused_once = true
		input_field:RequestFocus()
	end

	local editor = input_field.tui_text:GetEditor()

	if editor then
		local line_count = #(editor.Buffer:GetLines())
		local max_height = math.max(3, math.floor(root.transform:GetHeight() / 2))
		local wanted_height = clamp(line_count + 2, 3, max_height)

		if line_count ~= state.last_input_lines or wanted_height ~= state.last_input_height then
			state.last_input_lines = line_count
			state.last_input_height = wanted_height
			composer.layout:SetMinSize(Vec2(0, wanted_height))
			composer.layout:SetMaxSize(Vec2(0, wanted_height))
			composer.layout:InvalidateLayout()
			TuiPanel.NeedsRedraw()
		end
	end
end)

create_message(
	"assistant",
	{
		title = "assistant",
		align = "left",
		border_color = palette.assistant_border,
		text_color = palette.assistant_text,
	}
)
set_node_text(
	state.history[#state.history].content,
	"Hello. Ask anything, scroll through history with the mouse wheel, and use alt+enter for multiline input."
)
refresh_history_layout(true)
sync_status()
repl.SetEnabled(false)

if HOTRELOAD then repl.SetEnabled(false) end