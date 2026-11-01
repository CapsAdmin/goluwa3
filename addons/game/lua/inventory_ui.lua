local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local weapons = import("lua/weapons.lua")
local weapon_categories = import("lua/weapon_categories.lua")
local inventory_menu = import("lua/inventory_menu.lua")
local inventory_ui = {}
local PANEL_WIDTH = 560
local PANEL_PADDING = 36
local PANEL_FADE = 140
local PLACE_NAMES = {right = "Right hand", left = "Left hand"}
local root = NULL
local mounted
local fade

local function draw_backdrop(panel)
	fade = fade or render2d.CreateGradient{
		width = 1024,
		height = 1,
		angle = 90,
		stops = {
			{pos = 0, color = Color(1, 1, 1, 0.92)},
			{pos = 0.75, color = Color(1, 1, 1, 0.8)},
			{pos = 1, color = Color(1, 1, 1, 0)},
		},
	}
	local size = panel.transform:GetSize()
	render2d.SetTexture(fade)
	render2d.SetColor(0.02, 0.04, 0.1, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
end

local function get_signature()
	local subject = inventory_menu.GetSubject()
	local parts = {#inventory_menu.GetSubjects()}

	for _, place in ipairs(inventory_menu.GetPlaces()) do
		local weapon = subject.weapon_holder:GetWeapon(place)
		parts[#parts + 1] = weapon and weapon:GetName() or ""
	end

	return table.concat(parts, "|")
end

local function get_place_name(place)
	return PLACE_NAMES[place] or place:sub(1, 1):upper() .. place:sub(2)
end

local function get_title(weapon)
	return weapon and weapon.weapon:GetTitle() or "Empty"
end

local function get_category(weapon)
	return weapon_categories.Get(weapon.weapon.Category)
end

local function get_icon(weapon)
	return weapon and get_category(weapon).Icon or "minus"
end

local function get_rarity_color(weapon)
	return weapons.Roller and weapons.Roller.GetColor(weapon.weapon.Rarity) or "text"
end

local function get_stats(info)
	return {
		{"Rarity", info.Rarity ~= "" and info.Rarity or "common"},
		{"Damage", string.format("x%.2f", info:GetDamageScale())},
		{"Hands", info:IsTwoHanded() and "Two" or info:IsOffhand() and "Off" or "One"},
		{"Attributes", #info.Attributes > 0 and table.concat(info.Attributes, ", ") or "none"},
		{"Statuses", #info.Statuses > 0 and table.concat(info.Statuses, ", ") or "none"},
	}
end

local Stat = react.Component(
	|props|->ui.Row{layout = {GrowWidth = 1, AlignmentY = "center"}}{
		ui.Text{Text = props.Label, Color = "text_disabled"},
		ui.Panel{layout = {GrowWidth = 1}},
		ui.Text{Text = props.Value},
	}
)
local InventoryMenu = react.Component(
	||-> do
		local _, set_version = react.UseState(0)
		react.UseEvent("InventoryMenuChanged", ||->set_version(|version|->version + 1))
		react.UsePoll(get_signature, 0.1)
		local state = inventory_menu.GetState()
		local subjects = inventory_menu.GetSubjects()
		local subject = inventory_menu.GetSubject()
		local holder = subject.weapon_holder
		local place = state.place
		local current = holder:GetWeapon(place)
		local names = {}

		for i, other in ipairs(subjects) do
			names[i] = other == _G.PLAYER_RIG and "You" or (other:GetName() .. " " .. i)
		end

		return ui.Panel{
			Ref = |entity|-> do
				root = entity ?? NULL
			end,
			transform = true,
			layout = {Direction = "x", AlignmentY = "stretch"},
			mouse_input = {RequestMouse = true},
		}{
			ui.Panel{
				transform = true,
				visual = true,
				OnDraw = draw_backdrop,
				layout = {
					Padding = Rect(PANEL_PADDING, PANEL_PADDING, PANEL_FADE, PANEL_PADDING),
					Direction = "y",
					GrowWidth = 0,
					GrowHeight = 1,
					FitHeight = false,
					MinSize = Vec2(PANEL_WIDTH, 0),
					MaxSize = Vec2(PANEL_WIDTH, 100000),
					AlignmentX = "stretch",
					ChildGap = "S",
				},
			}{
				#subjects > 1 && ui.TabBar{
					Tabs = names,
					Value = names[state.subject],
					Backed = true,
					OnChange = |name|-> do
						for i, other in ipairs(names) do
							if other == name then inventory_menu.SetSubject(i) end
						end
					end,
				},
				ui.Text{Text = names[state.subject], FontSize = "L"},
				ui.Text{Text = "Equipment", Color = "text_disabled"},
				list.map(
					inventory_menu.GetPlaces(),
					|name|->ui.MenuItem{
						Key = name,
						Text = get_place_name(name) .. "   " .. get_title(holder:GetWeapon(name)),
						Icon = get_icon(holder:GetWeapon(name)),
						Padding = "S",
						Selected = name == place,
						OnClick = ||->inventory_menu.SetPlace(name),
					}
				),
				not inventory_menu.IsMount(place) && ui.Text{Text = "Change " .. get_place_name(place):lower(), Color = "text_disabled"},
				not inventory_menu.IsMount(place) && ui.ScrollablePanel{
					Padding = "XS",
					ScrollX = false,
					ScrollY = true,
					layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false},
				}{
					ui.Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = "XXS", AlignmentX = "stretch"}}{
						list.map(
							inventory_menu.GetCandidates(place),
							|weapon, i|->ui.MenuItem{
								Key = weapon and weapon:GetName() or "empty",
								Icon = get_icon(weapon),
								Text = get_title(weapon) .. ((weapon or false) == (current or false) and "   (equipped)" or ""),
								Padding = "S",
								Selected = (weapon or false) == (current or false),
								OnClick = ||->inventory_menu.Equip(weapon, place),
							}
						),
					},
				},
				current && ui.Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = "XXS", AlignmentX = "stretch"}}{
					ui.Row{layout = {ChildGap = "S", AlignmentY = "center"}}{
						ui.Icon{Icon = get_icon(current), IconColor = get_category(current).Color},
						ui.Text{Text = get_title(current), FontSize = "M", Color = get_rarity_color(current)},
					},
					list.map(
						get_stats(current.weapon),
						|row|->Stat{Key = row[1], Label = row[1], Value = row[2]}
					),
				},
				ui.Button{Text = "Close", Padding = "S", OnClick = inventory_menu.Close},
			},
		}
	end
)

function inventory_ui.Sync()
	if inventory_menu.IsOpen() then
		if mounted then return end

		mounted = react.Mount(InventoryMenu{}, Panel.World)
		root.transform:SetSize(Panel.World.transform:GetSize())
	elseif mounted then
		mounted:Unmount()
		mounted = nil
	end
end

event.AddListener("InventoryMenuChanged", "inventory_ui", inventory_ui.Sync)
return inventory_ui
