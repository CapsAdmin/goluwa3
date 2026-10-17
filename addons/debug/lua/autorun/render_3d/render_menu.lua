local pvars = import("goluwa/cli/pvars.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
-- the passes that can be skipped to see what the image is without them (the rest are the gbuffer and the output)
local PASSES = {
	"clouds",
	"ambient_occlusion",
	"ddgi",
	"reflections",
	"lighting",
	"ocean",
	"volumetric_fog",
	"particles",
	"translucent",
	"forward_overlay",
	"motion_blur",
}

-- menu items are made again every time a menu opens, a closed menu removes its items
local function get_anti_aliasing_items()
	local items = {}
	local current = pvars.Get("r_aa")

	for _, mode in ipairs(pvars.GetObject("r_aa"):GetInfo().enums) do
		items[#items + 1] = MenuItem{
			Text = mode,
			Selected = mode == current,
			OnClick = function()
				pvars.SetSession("r_aa", mode)
			end,
		}
	end

	return items
end

local function get_pass_items()
	local items = {}

	for _, name in ipairs(PASSES) do
		local key = "r_pass_" .. name
		local enabled = pvars.Get(key)
		items[#items + 1] = MenuItem{
			Text = name .. (enabled and "" or "  (off)"),
			Selected = enabled,
			OnClick = function()
				pvars.SetSession(key, not enabled)
			end,
		}
	end

	return items
end

-- session only, nothing here is written to the user's pvars
desktop.RegisterMenu{
	Text = "RENDER",
	Items = function()
		return {
			MenuItem{Text = "Anti aliasing", Icon = "sparkle", Items = get_anti_aliasing_items},
			MenuItem{Text = "Passes", Icon = "layers", Items = get_pass_items},
		}
	end,
}
