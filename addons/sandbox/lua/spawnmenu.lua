local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local physics = import("goluwa/physics.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local previews = import("lua/asset_preview.lua")
local spawnlists = import("lua/spawnlists.lua")
local weapons = import("lua/weapons.lua")
local npcs = import("lua/npcs.lua")
local interactives = import("lua/interactives.lua")
local props = import("lua/props.lua")
local game_history = import("lua/game_history.lua")
local toolgun = import("lua/toolgun.lua")
local clients = import("goluwa/network/clients.lua")
local spawnmenu = {}
local TILE_SIZE = 84
local LABELED_TILE_SIZE = 120
local LABEL_HEIGHT = 20
local PAGE_LAYOUT = {
	GrowWidth = 1,
	GrowHeight = 1,
	FitHeight = false,
	Direction = "y",
	AlignmentX = "stretch",
}
local SPAWN_RANGE = 40
local DEFAULT_DISTANCE = 3
local TRACE_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
local LEFT_TABS = {"Spawnlists", "Weapons", "Interactive", "NPCs"}
local root = NULL
local shown_setter
local colors = {}

local function refresh_colors()
	local active = theme.active

	if colors.theme == active then return end

	colors.theme = active
	colors.text = active:GetColor("text")
	colors.primary = active:GetColor("primary")
	colors.border = active:GetColor("border")
	colors.fill = active:GetColor("surface_alt")
	colors.preview_background = {r = 0.2, g = 0.21, b = 0.24, a = 1}
	colors.pulse = {r = colors.text.r, g = colors.text.g, b = colors.text.b, a = 0.15}
	colors.font = active:GetFont("body", "XS")
end

local function get_aim()
	local camera = render3d.GetCamera()
	local origin = camera:GetPosition()
	local forward = camera:GetRotation():GetForward()
	local hit = physics.Sweep(origin, forward * SPAWN_RANGE, 0, _G.PLAYER_RIG, nil, TRACE_OPTIONS)
	local position = hit and hit.position or origin + forward * DEFAULT_DISTANCE
	local yaw = math.atan2(-forward.x, -forward.z)
	return position, yaw
end

local function make_weapon_entries()
	local entries = {}

	for _, name in ipairs(weapons.GetNames()) do
		local definition = weapons.Definitions[name]
		entries[#entries + 1] = {
			category = "prefabs",
			name = name,
			path = name,
			label = definition.DisplayName ?? name,
			spawn_name = name,
			kind = "weapon",
		}
	end

	return entries
end

local function make_interactive_entries()
	local entries = {}

	for _, name in ipairs(interactives.Names) do
		entries[#entries + 1] = {
			category = "prefabs",
			name = interactives.GetPrefabName(name),
			path = interactives.GetPrefabName(name),
			label = name,
			spawn_name = name,
			kind = "interactive",
		}
	end

	return entries
end

local function make_npc_entries(faction)
	local entries = {}

	for _, name in ipairs(npcs.GetNamesByFaction(faction)) do
		entries[#entries + 1] = {
			category = "prefabs",
			name = npcs.GetPrefabName(name),
			path = npcs.GetPrefabName(name),
			label = name,
			spawn_name = name,
			kind = "npc",
		}
	end

	return entries
end

function spawnmenu.Spawn(entry)
	local position, yaw = get_aim()

	if entry.kind == "weapon" then
		local holder = _G.PLAYER_RIG.weapon_holder

		for _, weapon in ipairs(holder:GetWeapons()) do
			if weapon:GetName() == entry.spawn_name then
				return holder:Equip(weapon, weapon.weapon:GetDefaultPlace())
			end
		end

		local weapon = weapons.Spawn(entry.spawn_name, position + Vec3(0, 0.3, 0), QuatFromAxis(yaw, Vec3(0, 1, 0)))
		weapon:SetOwnedBy(clients.GetLocalClient())
		game_history.RecordSpawn("spawn " .. entry.spawn_name, weapon)
		return weapon
	end

	if entry.kind == "interactive" then
		local interactive = interactives.Spawn(entry.spawn_name, position, yaw)
		interactive:SetOwnedBy(clients.GetLocalClient())
		game_history.RecordSpawn("spawn " .. entry.spawn_name, interactive)
		return interactive
	end

	if entry.kind == "npc" then
		local npc = npcs.Spawn(entry.spawn_name, position, yaw)
		npc:SetTransient(false)
		npc:SetOwnedBy(clients.GetLocalClient())
		game_history.RecordSpawn("spawn " .. entry.spawn_name, npc)
		return npc
	end

	props.Spawn(
		entry.path,
		position,
		QuatFromAxis(yaw, Vec3(0, 1, 0)),
		function(entity)
			entity:SetOwnedBy(clients.GetLocalClient())
			game_history.RecordSpawn("spawn " .. entity:GetName(), entity)
		end
	)
end

local function draw_tile(item, index, x, y, w, h, selected, hovered)
	refresh_colors()
	render2d.DrawBox(
		x,
		y,
		w,
		h,
		4,
		colors.preview_background,
		hovered and colors.primary or colors.border,
		hovered and -2 or -1
	)
	local label_height = item.label and LABEL_HEIGHT or 0
	local preview = previews.Request(item)
	local size = math.min(w, h - label_height) - 4

	if preview.status == "ready" then
		previews.Draw(preview, x + (w - size) / 2, y + 2, size, size)
	elseif preview.status == "loading" or preview.status == "queued" then
		colors.pulse.a = 0.12 + 0.08 * math.sin(system.GetElapsedTime() * 5 + index)
		render2d.DrawBox(x + w * 0.3, y + (h - label_height) * 0.45, w * 0.4, 6, 3, colors.pulse)
	end

	if item.label then
		if item.label_width ~= w then
			item.label_width = w
			item.elided = colors.font:ElideText(item.label, w - 4)
		end

		local tw = colors.font:GetTextSize(item.elided)
		render2d.SetTexture(nil)
		render2d.SetColor(1, 1, 1, 1)
		colors.font:DrawText(item.elided, x + (w - tw) / 2, y + h - label_height + 3, 0)
	end
end

local TileGrid = react.Component(
	|props|-> do
		local hovered, set_hovered = react.UseState()
		local size = props.Items[1] and props.Items[1].label and LABELED_TILE_SIZE or TILE_SIZE
		return ui.Column{
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
				FitHeight = false,
				ChildGap = 4,
				AlignmentX = "stretch",
			},
		}{
			ui.VirtualGrid{
				Items = props.Items,
				CellWidth = size,
				ExtraHeight = 0,
				Gap = 4,
				ContentPadding = 4,
				OnDrawItem = draw_tile,
				OnClick = spawnmenu.Spawn,
				OnHoverItem = set_hovered,
				layout = {GrowWidth = 1, GrowHeight = 1},
			},
			ui.Text{
				Text = hovered ? hovered.path : "",
				Color = "text_disabled",
				Elide = true,
				layout = {GrowWidth = 1, FitWidth = false},
			},
		}
	end
)

local function make_tree_items(roots, counter)
	local items = {}

	for _, node in ipairs(roots) do
		counter.count += 1
		items[#items + 1] = {
			Key = "list" .. counter.count,
			Text = node.Name,
			Icon = #node.Children > 0 and
				(
					|_,expanded|->expanded and
					"folder_open" or
					"folder"
				)
				or
				"layers",
			List = node,
			Children = make_tree_items(node.Children, counter),
		}
	end

	return items
end

local SpawnlistsPage = react.Component(
	||-> do
		local roots = react.UseMemo(spawnlists.Load, {})
		local everything = react.UseMemo(||->spawnlists.GetEntries(roots), {roots})
		local tree_items = react.UseMemo(
			||->{
				{
					Key = "root",
					Text = "Your Spawnlists",
					Icon = "folder_open",
					Children = make_tree_items(roots, {count = 0}),
				},
			},
			{roots}
		)
		local list, set_list = react.UseState(roots[1])
		local query, set_query = react.UseState("")
		local applied_query = react.UseDebounce(query, 0.12)
		local expanded = react.UseRef({root = true})
		local tree = react.UseRef()
		local items = react.UseMemo(
			||-> do
				local text = applied_query:lower():match("^%s*(.-)%s*$")

				if text == "" then return list and list.Entries ?? {} end

				local found = {}

				for _, entry in ipairs(everything) do
					if entry.lower_path:find(text, 1, true) then found[#found + 1] = entry end
				end

				return found
			end,
			{list, applied_query, everything}
		)
		react.UseLayoutEffect(
			||-> do
				if tree.current then
					tree.current:SetSelectedKey(tree_items[1].Children[1].Key)
				end
			end,
			{}
		)

		if #roots == 0 then
			return ui.Text{
				Text = "no spawnlists found, mount Garry's Mod to get settings/spawnlist_default",
				Color = "text_disabled",
				Wrap = true,
				layout = {GrowWidth = 1},
			}
		end

		return ui.Column{
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
				FitHeight = false,
				ChildGap = 6,
				AlignmentX = "stretch",
			},
		}{
			ui.TextEdit{
				Hint = "Search",
				Wrap = false,
				ScrollX = false,
				ScrollY = false,
				ScrollbarVisible = false,
				Size = Vec2(0, 26),
				MinSize = Vec2(0, 26),
				MaxSize = Vec2(0, 26),
				OnTextChanged = |_,text|->set_query(text),
				layout = {GrowWidth = 1},
			},
			ui.Splitter{InitialSize = 220, layout = {GrowWidth = 1, GrowHeight = 1}}{
				ui.ScrollablePanel{
					Padding = Rect(),
					ScrollX = false,
					ScrollY = true,
					layout = {GrowWidth = 1, GrowHeight = 1},
				}{
					ui.Tree{
						Ref = tree,
						Items = tree_items,
						LabelGrow = true,
						layout = {GrowWidth = 1, FitHeight = true},
						OnIsExpanded = |_,_,key|->expanded.current[key] == true,
						OnToggle = |_,is_expanded,key|-> do
							expanded.current[key] = is_expanded == true
						end,
						OnSelect = |node|-> do
							if node then set_list(node.List) end
						end,
					},
				},
				TileGrid{Items = items},
			},
		}
	end
)
local LEFT_PANE_SHARE = 0.54
local LEFT_PANE_INSET = 118
local NPC_GRID_GAP = 4
local NPC_GRID_PADDING = 4
local FactionGrid = react.Component(
	|props|-> do
		local items = react.UseMemo(||->make_npc_entries(props.Faction), {props.Faction})
		local columns = math.max(
			math.floor((Panel.World.transform:GetSize().x * LEFT_PANE_SHARE - LEFT_PANE_INSET) / (LABELED_TILE_SIZE + NPC_GRID_GAP)),
			1
		)
		local height = math.ceil(#items / columns) * (LABELED_TILE_SIZE + NPC_GRID_GAP * 2) + NPC_GRID_PADDING * 2 + NPC_GRID_GAP * 2
		return ui.VirtualGrid{
			Items = items,
			CellWidth = LABELED_TILE_SIZE,
			ExtraHeight = 0,
			Gap = NPC_GRID_GAP,
			ContentPadding = NPC_GRID_PADDING,
			OnDrawItem = draw_tile,
			OnClick = spawnmenu.Spawn,
			Size = Vec2(0, height),
			MinSize = Vec2(0, height),
			MaxSize = Vec2(0, height),
			layout = {GrowWidth = 1},
		}
	end
)
local NpcsPage = react.Component(
	||->ui.ScrollablePanel{
		Padding = "XS",
		ScrollX = false,
		ScrollY = true,
		layout = {GrowWidth = 1, GrowHeight = 1},
	}{
		ui.Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = "XS", AlignmentX = "stretch"}}{
			list.map(
				npcs.Factions,
				|faction|->ui.Collapsible{Key = faction, Title = faction:sub(1, 1):upper() .. faction:sub(2), HeaderMode = "text"}{
					FactionGrid{Faction = faction},
				}
			),
		},
	}
)
local ListPage = react.Component(
	|props|-> do
		local items = react.UseMemo(props.Make, {})
		return TileGrid{Items = items}
	end
)
local UtilitiesPage = react.Component(
	|props|-> do
		local version, set_version = react.UseState(0)
		local selected, set_selected = react.UseState("Sun")
		local programs = react.UseMemo(
			||->list.filter(desktop.GetPrograms(), |program|->program.Content ~= nil),
			{version}
		)
		local program = list.find(programs, |candidate|->candidate.Name == selected) ?? programs[1]
		react.UseEvent("DesktopChanged", ||->set_version(|current|->current + 1))
		local categories = react.UseMemo(
			||-> do
				local result = {}
				local by_name = {}

				for _, candidate in ipairs(programs) do
					local name = candidate.Category ?? "desktop"

					if not by_name[name] then
						by_name[name] = {Name = name, Programs = {}}
						result[#result + 1] = by_name[name]
					end

					list.insert(by_name[name].Programs, candidate)
				end

				return result
			end,
			{programs}
		)
		return ui.Splitter{InitialSize = 180, layout = {GrowWidth = 1, GrowHeight = 1}}{
			ui.ScrollablePanel{
				Padding = "XS",
				ScrollX = false,
				ScrollY = true,
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				ui.Column{
					layout = {GrowWidth = 1, FitHeight = true, ChildGap = "XXS", AlignmentX = "stretch"},
				}{
					list.map(
						categories,
						|category|->ui.Collapsible{Key = category.Name, Title = category.Name, HeaderMode = "text"}{
							list.map(
								category.Programs,
								|candidate|->ui.MenuItem{
									Key = candidate.Name,
									Text = candidate.Name,
									Icon = candidate.Icon,
									Padding = "S",
									Selected = candidate == program,
									OnClick = ||->set_selected(candidate.Name),
								}
							),
						}
					),
				},
			},
			ui.Column{
				layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false, AlignmentX = "stretch"},
			}{
				program and
				program.Content{Key = program.Name, Shown = props.Shown, BarHidden = false},
			},
		}
	end
)
local function select_tool(name)
	toolgun.Select(name)
	local holder = _G.PLAYER_RIG.weapon_holder
	local weapon = holder:FindWeapon("weapon_toolgun")

	if weapon then holder:Equip(weapon, "right") end
end

local function build_tool_items(tool, on_change)
	local children = {}

	for i, setting in ipairs(tool.Settings) do
		children[i] = {
			Key = setting.Key,
			Text = setting.Text,
			Type = setting.Type,
			Value = toolgun.GetSetting(_G.PLAYER_RIG, tool.Name, setting.Key),
			Default = setting.Default,
			Min = setting.Min,
			Max = setting.Max,
			Precision = setting.Precision,
			ShowSlider = setting.Min ~= nil and setting.Max ~= nil,
			Options = setting.Options,
			Description = setting.Description,
			OnChange = |_,value|->on_change(setting.Key, value),
		}
	end

	return {{Key = tool.Name, Text = "Settings", Expanded = true, Children = children}}
end

local ToolsPage = react.Component(
	||-> do
		local selected, set_selected = react.UseState(toolgun.GetSelected(_G.PLAYER_RIG))
		local revision, set_revision = react.UseState(0)
		local editing = react.UseRef(false)
		local tool = toolgun.Tools[selected]
		react.UseEvent(
			"ToolgunChanged",
			|name,key|-> do
				if not key then
					set_selected(name)
				elseif not editing.current then
					set_revision(|current|->current + 1)
				end
			end
		)
		local on_change = react.UseCallback(
			|key,value|-> do
				editing.current = true
				toolgun.SetSetting(selected, key, value)
				editing.current = false
			end,
			{selected}
		)
		local items = react.UseMemo(||->build_tool_items(tool, on_change), {selected, revision})
		return ui.Splitter{InitialSize = 190, layout = {GrowWidth = 1, GrowHeight = 1}}{
			ui.ScrollablePanel{
				Padding = "XS",
				ScrollX = false,
				ScrollY = true,
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				ui.Column{
					layout = {GrowWidth = 1, FitHeight = true, ChildGap = "XXS", AlignmentX = "stretch"},
				}{
					list.map(
						toolgun.Categories,
						|category|->ui.Collapsible{Key = category, Title = category, HeaderMode = "text"}{
							list.map(
								toolgun.GetTools(category),
								|candidate|->ui.MenuItem{
									Key = candidate.Name,
									Text = candidate.DisplayName,
									Padding = "S",
									Selected = candidate.Name == selected,
									OnClick = ||->select_tool(candidate.Name),
								}
							),
						}
					),
				},
			},
			ui.ScrollablePanel{
				Padding = "M",
				ScrollX = false,
				ScrollY = true,
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				ui.Column{
					layout = {GrowWidth = 1, FitHeight = true, ChildGap = "S", AlignmentX = "stretch"},
				}{
					ui.Text{Key = "title", Text = tool.DisplayName, Font = "heading L", IgnoreMouseInput = true},
					ui.Text{
						Key = "description",
						Text = tool.Description,
						Color = "text_disabled",
						Wrap = true,
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1, FitWidth = false},
					},
					tool.Settings[1] and
					ui.PropertyEditor{Key = selected .. revision, Items = items, layout = {GrowWidth = 1}},
				},
			},
		}
	end
)
local LEFT_PAGES = {
	Spawnlists = ||->SpawnlistsPage{},
	Weapons = ||->ListPage{Make = make_weapon_entries},
	Interactive = ||->ListPage{Make = make_interactive_entries},
	NPCs = ||->NpcsPage{},
}
local SpawnMenu = react.Component(
	||-> do
		local shown, set_shown = react.UseState(false)
		local tab, set_tab = react.UseState("Spawnlists")
		local right_tab, set_right_tab = react.UseState("Tools")
		local width = react.UseMemo(||->Panel.World.transform:GetSize().x, {})
		react.UseEffect(
			||-> do
				shown_setter = set_shown
				return ||-> do
					shown_setter = nil
				end
			end,
			{}
		)
		return ui.Panel{
			Ref = |entity|-> do
				root = entity ?? NULL
			end,
			transform = true,
			layout = {Direction = "x", AlignmentY = "stretch", Padding = Rect() + 48},
			visual = true,
			mouse_input = {RequestMouse = true},
			OnMouseInput = |_,button,press|-> do
				if button == "button_1" and press and MouseInput.GetHoveredObject() == root then
					spawnmenu.Hide()
				end
			end,
		}{
			ui.Splitter{InitialSize = width * 0.54 - 48, layout = {GrowWidth = 1, GrowHeight = 1}}{
				ui.Tabs{
					Value = tab,
					OnChange = set_tab,
					Backed = true,
					layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false},
				}{
					list.map(
						LEFT_TABS,
						|name|->ui.Frame{Key = name, Tab = name, Padding = "S", layout = PAGE_LAYOUT}{LEFT_PAGES[name]()}
					),
				},
				ui.Tabs{
					Value = right_tab,
					OnChange = set_right_tab,
					Backed = true,
					layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false},
				}{
					ui.Frame{Key = "tools", Tab = "Tools", Padding = "S", layout = PAGE_LAYOUT}{ToolsPage{}},
					ui.Frame{Key = "utilities", Tab = "Utilities", Padding = "S", layout = PAGE_LAYOUT}{
						UtilitiesPage{Shown = shown},
					},
				},
			},
		}
	end
)

function spawnmenu.IsShown()
	return root:IsValid() and root.visual:GetVisible()
end

function spawnmenu.Show()
	if not root:IsValid() then react.Mount(SpawnMenu{}, Panel.World) end

	root.transform:SetSize(Panel.World.transform:GetSize())
	root.visual:SetVisible(true)
	shown_setter(true)
	_G.PLAYER_RIG.player_input:SetKeyboardMovement(true)
end

function spawnmenu.Hide()
	if not spawnmenu.IsShown() then return end

	root.visual:SetVisible(false)
	shown_setter(false)
	_G.PLAYER_RIG.player_input:SetKeyboardMovement(false)
end

function spawnmenu.IsEditing()
	local focused = objects.GetFocusedObject()
	return focused and
		focused:IsValid() and
		focused.text and
		focused.text:GetEditable() or
		false
end

function spawnmenu.Hold()
	if spawnmenu.IsShown() then spawnmenu.Hide() else spawnmenu.Show() end
end

function spawnmenu.Release()
	if not spawnmenu.IsEditing() then spawnmenu.Hide() end
end

return spawnmenu
