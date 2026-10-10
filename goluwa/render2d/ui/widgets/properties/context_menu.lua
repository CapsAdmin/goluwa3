local Panel = import("goluwa/render2d/ui/panel.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")

local function on_copy(item)
	clipboard.Set(item.Encoded)
end

local function on_paste(item)
	item.Control:SetValue(item.Control:DecodeValue(item.Encoded), true)
end

local function on_context_action(item)
	item.Action.OnClick(item.Control)
end

-- an action is {Text, Icon, OnClick} or {Text, Icon, Items = {actions}} for a submenu
local function build_action_item(control, action)
	if action.Items then
		return MenuItem{
			Text = action.Text,
			Icon = action.Icon,
			Items = function()
				local out = {}

				for _, sub_action in ipairs(action.Items) do
					out[#out + 1] = build_action_item(control, sub_action)
				end

				return out
			end,
		}
	end

	return MenuItem{
		Control = control,
		Action = action,
		Text = action.Text,
		Icon = action.Icon,
		OnClick = on_context_action,
	}
end

return function(control)
	control.OnBeforeContextMenu(control)
	local current = control:EncodeValue()
	local default = control:GetDefaultEncoded()
	local clipboard_text = clipboard.Get() or ""
	local _, can_paste = control:DecodeValue(clipboard_text)
	local items = {
		MenuItem{
			Control = control,
			Encoded = current,
			Text = "Copy",
			Icon = "copy",
			Disabled = current == nil,
			OnClick = on_copy,
		},
		MenuItem{
			Control = control,
			Encoded = clipboard_text,
			Text = "Paste",
			Icon = "paste",
			Disabled = not can_paste,
			OnClick = on_paste,
		},
		MenuItem{
			Control = control,
			Encoded = default,
			Text = "Reset",
			Icon = "reset",
			Disabled = default == nil or default == current,
			OnClick = on_paste,
		},
	}
	local actions = control.Node and control.Node.ContextActions

	-- what only this property can do, a node lists them as {Text, OnClick}
	if actions then
		items[#items + 1] = MenuSpacer{}

		for _, action in ipairs(actions) do
			items[#items + 1] = build_action_item(control, action)
		end
	end

	Panel.OpenContextMenu({}, items)
	return true
end
