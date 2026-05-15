local system = import("goluwa/system.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")

function gine.env.system.HasFocus()
	local wnd = system.GetCurrentWindow()
	return wnd and wnd:IsFocused() or false
end

function gine.env.system.IsWindowed()
	return true
end

function gine.env.SetClipboardText(str)
	clipboard.Set(str)
end