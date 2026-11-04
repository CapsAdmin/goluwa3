local players = import("lua/players.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local easing = import("goluwa/math/easing.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local weapons = import("lua/weapons.lua")
local weapon_categories = import("lua/weapon_categories.lua")
local inventory_menu = import("lua/inventory_menu.lua")
local inventory_ui = {}
local PANEL_WIDTH = 560
local PANEL_PADDING = 36
local PANEL_FADE = 140
local PLACE_NAMES = {right = "Right hand", left = "Left hand"}
local MAX_FRAME = 1 / 30
local OPEN_TIME = 0.45
local CLOSE_TIME = 0.25
local ROW_STAGGER = 0.05
local root = NULL
local mounted
local closing
local panel = NULL
local appear_state = setmetatable({}, {__mode = "k"})

local function pre_draw(entity)
	render2d.PushAlphaMultiplier(appear_state[entity].value)
end

local function post_draw()
	render2d.PopAlphaMultiplier()
end

local function make_appear(entity, distance)
	appear_state[entity] = {value = 0, distance = distance}
	entity.transform:SetDrawPositionOffset(Vec2(-distance, 0))
end

local function appear_to(entity, target, time, delay, ease, callback)
	local state = appear_state[entity]
	local total = delay + time
	entity.animation:Animate{
		id = "appear",
		get = function()
			return state.value
		end,
		set = function(value)
			state.value = value
			entity.transform:SetDrawPositionOffset(Vec2((value - 1) * state.distance, 0))
		end,
		to = target,
		time = total,
		max_dt = MAX_FRAME,
		interpolation = function(t)
			return easing[ease](math.clamp((t * total - delay) / time, 0, 1))
		end,
		callback = callback,
	}
end

local function draw_backdrop(panel)
	theme.active:DrawSidePanel(panel.transform:GetSize())
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

local Appear = react.Component(
	|props|-> do
		local ref = react.UseRef()
		react.UseLayoutEffect(
			||-> do
				appear_to(ref.current, 1, props.Time ?? 0.3, props.Delay ?? 0, "outCubic")
			end,
			{}
		)
		return ui.Panel{
			Ref = |entity|-> do
				ref.current = entity
				if entity then make_appear(entity, props.Distance ?? 32) end
			end,
			transform = true,
			visual = true,
			animation = true,
			OnPreDraw = pre_draw,
			OnPostDraw = post_draw,
			layout = {Direction = "y", GrowWidth = 1, FitHeight = true, AlignmentX = "stretch"},
		}{props.children}
	end
)
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
		react.UseLayoutEffect(
			||-> do
				appear_to(panel, 1, OPEN_TIME, 0, "outExpo")
			end,
			{}
		)

		for i, other in ipairs(subjects) do
			names[i] = players.IsLocal(other) and "You" or (other:GetName() .. " " .. i)
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
				Ref = |entity|-> do
					panel = entity ?? NULL
					if entity then make_appear(entity, PANEL_WIDTH * 0.6) end
				end,
				transform = true,
				visual = true,
				animation = true,
				OnPreDraw = pre_draw,
				OnPostDraw = post_draw,
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
					|name, i|->Appear{Key = name, Delay = 0.12 + i * ROW_STAGGER, Time = 0.35}{
						ui.MenuItem{
							Text = get_place_name(name) .. "   " .. get_title(holder:GetWeapon(name)),
							Icon = get_icon(holder:GetWeapon(name)),
							Padding = "S",
							Selected = name == place,
							OnClick = ||->inventory_menu.SetPlace(name),
						},
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
							|weapon, i|->Appear{
								Key = place .. ":" .. (weapon and weapon:GetName() or "empty"),
								Delay = (i - 1) * 0.03,
								Time = 0.25,
								Distance = 24,
							}{
								ui.MenuItem{
									Icon = get_icon(weapon),
									Text = get_title(weapon) .. ((weapon or false) == (current or false) and "   (equipped)" or ""),
									Padding = "S",
									Selected = (weapon or false) == (current or false),
									OnClick = ||->inventory_menu.Equip(weapon, place),
								},
							}
						),
					},
				},
				current && Appear{Key = place .. ":" .. current:GetName(), Time = 0.3, Distance = 20}{
					ui.Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = "XXS", AlignmentX = "stretch"}}{
					ui.Row{layout = {ChildGap = "S", AlignmentY = "center"}}{
						ui.Icon{Icon = get_icon(current), IconColor = get_category(current).Color},
						ui.Text{Text = get_title(current), FontSize = "M", Color = get_rarity_color(current)},
					},
					list.map(
						get_stats(current.weapon),
						|row|->Stat{Key = row[1], Label = row[1], Value = row[2]}
					),
				},
			},
				ui.Button{Text = "Close", Padding = "S", OnClick = inventory_menu.Close},
			},
		}
	end
)

function inventory_ui.Sync()
	if inventory_menu.IsOpen() then
		if mounted and not closing then return end

		if mounted then mounted:Unmount() end

		closing = false
		mounted = react.Mount(InventoryMenu{}, Panel.World)
		root.transform:SetSize(Panel.World.transform:GetSize())
	elseif mounted and not closing then
		closing = true
		local closing_mount = mounted
		appear_to(
			panel,
			0,
			CLOSE_TIME,
			0,
			"inCubic",
			function()
				if mounted ~= closing_mount then return end

				mounted:Unmount()
				mounted = nil
				closing = false
			end
		)
	end
end

event.AddListener("InventoryMenuChanged", "inventory_ui", inventory_ui.Sync)
return inventory_ui
