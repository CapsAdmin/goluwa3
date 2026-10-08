local Panel = import("goluwa/render2d/ui/panel.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local copy_icon = "https://api.iconify.design/material-symbols-light/content-copy.svg"
local paste_icon = "https://api.iconify.design/material-symbols-light/content-paste-rounded.svg"
local reset_icon = "https://api.iconify.design/material-symbols-light/reset-iso-rounded.svg"

local function on_copy(item)
	clipboard.Set(item.Encoded)
end

local function on_paste(item)
	item.Control:SetValue(item.Control:DecodeValue(item.Encoded), true)
end

return function(control)
	control.OnBeforeContextMenu(control)
	local current = control:EncodeValue()
	local default = control:GetDefaultEncoded()
	local clipboard_text = clipboard.Get() or ""
	local _, can_paste = control:DecodeValue(clipboard_text)
	Panel.OpenContextMenu(
		{},
		{
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
	)
	return true
end
