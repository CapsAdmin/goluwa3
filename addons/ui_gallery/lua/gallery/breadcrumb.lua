local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Breadcrumb = import("goluwa/render2d/ui/widgets/breadcrumb.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function on_select(index, bar)
	bar:SetItems(list.slice(bar.Items, 1, index))
	bar.Readout.text:SetText("OnSelect(" .. index .. ")")
end

local function push(button)
	local bar = button.Bar
	local items = table.shallow_copy(bar.Items)
	items[#items + 1] = "level " .. (#items + 1)
	bar:SetItems(items)
end

return {
	Name = "breadcrumb",
	Section = "Containers",
	Order = 4,
	Create = function()
		local readout = Text{
			Text = "OnSelect has not fired yet",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local dynamic_readout = Text{
			Text = "Clicking a crumb truncates the path to it",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local dynamic = Breadcrumb{
			Items = {"scene", "house.prefab", "door.prefab"},
			Readout = dynamic_readout,
			OnSelect = on_select,
		}
		local sizes = {}

		for _, size in ipairs{"S", "M", "L"} do
			sizes[#sizes + 1] = kit.Labeled(
				"FontSize = " .. size,
				Breadcrumb{
					Items = {"Home", "Assets", "Models"},
					FontSize = size,
					layout = {MinSize = Vec2(320, 0), GrowWidth = 0},
				}
			)
		end

		return kit.Page{
			Title = "Breadcrumb",
			Description = "The path to the current location. Every crumb but the last one navigates back to it.",
		}{
			kit.Section{
				Title = "Breadcrumb",
				Description = "Items is the list of names, the last one is the current location. OnSelect(index, breadcrumb) fires when an earlier crumb is clicked.",
			}{
				Breadcrumb{
					Items = {"scene", "house.prefab", "door.prefab", "handle.prefab"},
					Readout = readout,
					OnSelect = function(index, bar)
						bar.Readout.text:SetText("OnSelect(" .. index .. ")")
					end,
				},
				readout,
			},
			kit.Section{
				Title = "Icons",
				Description = "Icons maps a name to an icon shown before the label.",
			}{
				Breadcrumb{
					Items = {"scene", "house.prefab", "door.prefab"},
					Icons = {scene = "world", ["house.prefab"] = "layers"},
				},
			},
			kit.Section{
				Title = "Changing the path",
				Description = "SetItems takes a list of names and only rebuilds when it changed.",
			}{
				dynamic,
				kit.Group{Button{Text = "Go deeper", Mode = "outline", Bar = dynamic, OnClick = push}},
				dynamic_readout,
			},
			kit.Section{
				Title = "Font size",
				Description = "FontSize sizes the labels.",
			}{kit.Group(sizes, {AlignmentY = "start", WrapChildren = true})},
		}
	end,
}
