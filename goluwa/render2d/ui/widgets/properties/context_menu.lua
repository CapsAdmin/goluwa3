local Panel = import("goluwa/render2d/ui/panel.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local copy_icon = "https://api.iconify.design/material-symbols-light/content-copy.svg"
local paste_icon = "https://api.iconify.design/material-symbols-light/content-paste-rounded.svg"
local reset_icon = "https://api.iconify.design/material-symbols-light/reset-iso-rounded.svg"

local function on_copy(item)
	clipboard.Set(item.Encoded)
end

local function on_paste(item)
	item.Control:SetValue(item.Control:DecodeValue(item.Encoded), true)
end

local function on_context_action(item)
	item.Action.OnClick(item.Control)
end

-- an action is {Text, OnClick} or {Text, Items = {actions}} for a submenu
local function build_action_item(control, action)
	if action.Items then
		return MenuItem{
			Text = action.Text,
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
			IconSource = copy_icon,
			Disabled = current == nil,
			OnClick = on_copy,
		},
		MenuItem{
			Control = control,
			Encoded = clipboard_text,
			Text = "Paste",
			IconSource = paste_icon,
			Disabled = not can_paste,
			OnClick = on_paste,
		},
		MenuItem{
			Control = control,
			Encoded = default,
			Text = "Reset",
			IconSource = reset_icon,
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
