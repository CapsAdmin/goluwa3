local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local input = import("goluwa/input.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Gizmo = import("lua/gizmo.lua")
local highlight = import("lua/highlight.lua")
local brush_editor = import("lua/brush_editor.lua")
local Breadcrumb = react.Element(import("goluwa/render2d/ui/widgets/breadcrumb.lua"))
local IconButton = react.Element(import("goluwa/render2d/ui/widgets/icon_button.lua"))
local MenuBar = react.Element(import("goluwa/render2d/ui/widgets/menu_bar.lua"))
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local PropertyEditor = react.Element(import("goluwa/render2d/ui/widgets/property_editor.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local Splitter = react.Element(import("goluwa/render2d/ui/elements/splitter.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local EntityTree = react.Element(import("goluwa/render2d/ui/widgets/entity_tree.lua"))
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local PanelElement = react.Element(Panel)
local nearby = import("lua/nearby.lua")
local scene = import("goluwa/entities/scene.lua")
local prefab = import("goluwa/entities/prefab.lua")
local prefab_tools = import("lua/prefab_tools.lua")
local network = import("goluwa/network/network.lua")
local scene_sync = import("goluwa/network/scene_sync.lua")
local name_prompt = import("lua/name_prompt.lua")
local AssetBrowser = import("lua/asset_browser.lua")
local vfs = import("goluwa/vfs.lua")
local View = import("goluwa/render3d/view.lua")
local camera = import("lua/camera.lua")
local picker = import("lua/picker.lua")
local editor_history = import("lua/editor_history.lua")
local HistoryPanel = import("lua/history_panel.lua")
local kit = import("lua/editor_kit.lua")
local history = editor_history.history
-- the order the components of an entity are listed in the property editor, the rest follows alphabetically
local COMPONENT_ORDER = {
	"prefab",
	"script",
	"transform",
	"model",
	"visual",
	"rigid_body",
	"network",
}
local NEARBY_COUNT = 10
local NEARBY_SETTLE_TIME = 0.3

local function is_hidden(entity, editor_window)
	if entity == editor_window then return true end

	if entity.Type == "panel_context_menu" then return true end

	if entity:GetName() == "TooltipOverlay" then return true end

	if entity.visual_primitive then return true end

	return false
end

local function entity_tree_filter_callback(entity, editor_window)
	if is_hidden(entity, editor_window) then return true end

	local parent = entity:GetRoot(1) or NULL

	if parent:IsValid() and is_hidden(parent, editor_window) then return true end

	return false
end

local function get_focus_bounds(entity)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
	local found = false

	local function add(visual)
		local aabb = visual:GetWorldAABB()

		if aabb and aabb.min_x <= aabb.max_x then
			found = true
			min_x, min_y, min_z = math.min(min_x, aabb.min_x), math.min(min_y, aabb.min_y), math.min(min_z, aabb.min_z)
			max_x, max_y, max_z = math.max(max_x, aabb.max_x), math.max(max_y, aabb.max_y), math.max(max_z, aabb.max_z)
		end
	end

	if entity.visual then add(entity.visual) end

	for _, child in ipairs(entity:GetChildrenList()) do
		if child.visual then add(child.visual) end
	end

	if found then
		local dx, dy, dz = max_x - min_x, max_y - min_y, max_z - min_z
		return Vec3((min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2),
		math.sqrt(dx * dx + dy * dy + dz * dz) / 2
	end

	if entity.transform then return entity.transform:GetWorldPosition(), 0 end
end

local function view_from_front(entity)
	local center, radius = get_focus_bounds(entity)

	if not center then return end

	camera.ViewFromFront(
		center,
		math.max(radius * 2.2, 2),
		entity.transform:GetWorldMatrix():GetRotation()
	)
end

local function go_to_entity(entity)
	local center, radius = get_focus_bounds(entity)

	if not center then return end

	camera.SetPosition(center - camera.GetRotation():GetForward() * math.max(radius * 2.2, 2))
end

local function can_edit_components(entity)
	return entity ~= Entity.World and entity ~= Panel.World and not entity:GetSingleton()
end

-- h is what the editor hands to its menus: the actions and the state they depend on (h.f)
local function make_menu_items(h)
	local f = h.f

	return {
		{
			Text = "FILE",
			Items = function()
				return {
					MenuItem{
						Text = "asset browser",
						Icon = "folder",
						OnClick = function()
							AssetBrowser{Key = "AssetBrowserWindow"}
						end,
					},
					MenuItem{
						Text = "save scene",
						Icon = "save",
						OnClick = function()
							name_prompt{
								Title = "SAVE SCENE",
								Text = f.scene_name or "scene",
								OnSubmit = function(name)
									name = name:gsub("[^%w_%-%. ]", "_")
									f.scene_name = name
									logn("saved ", scene.Save(name), " root entities to ", scene.GetPath(name))
								end,
							}
						end,
					},
					MenuItem{
						Text = "load scene",
						Icon = "folder_open",
						Items = function()
							local items = {}

							for _, file_name in ipairs(vfs.Find(scene.GetDirectory()) or {}) do
								local name = file_name:match("^(.+)%.scene$")

								if name then
									items[#items + 1] = MenuItem{
										Text = name,
										Icon = "file",
										OnClick = function()
											f.scene_name = name
											editor_history.Barrier("a scene was loaded")
											scene.LoadAsync(name)
										end,
									}
								end
							end

							return items
						end,
					},
				}
			end,
		},
		{
			Text = "EDIT",
			Items = function()
				local entries = history:GetEntries()
				local undo_entry = entries[history:GetIndex()]
				local redo_entry = entries[history:GetIndex() + 1]
				return {
					MenuItem{
						Text = undo_entry and ("Undo " .. undo_entry.Name) or "Undo",
						Icon = "undo",
						Disabled = not undo_entry,
						OnClick = function()
							history:Undo()
						end,
					},
					MenuItem{
						Text = redo_entry and ("Redo " .. redo_entry.Name) or "Redo",
						Icon = "redo",
						Disabled = not redo_entry,
						OnClick = function()
							history:Redo()
						end,
					},
					MenuSpacer{},
					MenuItem{
						Text = "History",
						Icon = "menu",
						OnClick = function()
							HistoryPanel()
						end,
					},
					MenuItem{
						Text = "Clear history",
						Icon = "trash",
						Disabled = #entries == 0,
						OnClick = function()
							history:Clear()
						end,
					},
				}
			end,
		},
		{
			Text = "GIZMO",
			Items = function()
				local function add_gizmo_menu_item(icon, label, setter, value, current)
					if value == current then label = label .. " (active)" end

					return MenuItem{
						Text = label,
						Icon = icon,
						OnClick = function()
							setter(value)
						end,
					}
				end

				return {
					add_gizmo_menu_item("move", "Move", Gizmo.SetMode, "move", Gizmo.GetMode()),
					add_gizmo_menu_item("rotate", "Rotate", Gizmo.SetMode, "rotate", Gizmo.GetMode()),
					add_gizmo_menu_item("scale", "Scale", Gizmo.SetMode, "scale", Gizmo.GetMode()),
					add_gizmo_menu_item("transform", "Combined", Gizmo.SetMode, "combined", Gizmo.GetMode()),
					MenuSpacer{},
					add_gizmo_menu_item("cube", "Local Space", Gizmo.SetSpace, "local", Gizmo.GetSpace()),
					add_gizmo_menu_item("world", "World Space", Gizmo.SetSpace, "world", Gizmo.GetSpace()),
				}
			end,
		},
		{
			Text = "OPTIONS",
			Items = function()
				return {
					MenuItem{
						Text = "Show transient entities" .. (f.transient and " (on)" or " (off)"),
						Icon = "eye",
						OnClick = function()
							h.set_transient(not f.transient)
						end,
					},
					MenuItem{
						Text = "Show nearby" .. (f.nearby and " (on)" or " (off)"),
						Icon = "target",
						OnClick = function()
							f.nearby = not f.nearby
							f.nearby_dirty = true
							h.tree.current:SetNearbyRoot(f.nearby and Entity.World or nil)
						end,
					},
				}
			end,
		},
	}
end

local function open_node_menu(node, h)
	local f = h.f

	if node.OwnerGroup then
		if node.Root ~= Entity.World then return false end

		Panel.OpenContextMenu(
			{
				OnClose = function(self)
					self:Remove()
				end,
			},
			{
				MenuItem{
					Text = "Entity",
					Icon = "cube",
					OnClick = function()
						h.create_child_entity(node.Root, node.Owner)
					end,
				},
				MenuItem{
					Text = "Prefab",
					Icon = "layers",
					OnClick = function()
						h.pick_child_prefab(node.Root, node.Owner)
					end,
				},
				h.can_paste(node.Root) and
				MenuItem{
					Text = "Paste " .. f.cut:GetName(),
					Icon = "paste",
					OnClick = function()
						h.paste_into(node.Root, node.Owner)
					end,
				} or
				nil,
			}
		)
		return true
	end

	local entity = node.Entity

	if not entity then return false end

	local editing = f.stack[#f.stack]
	local can_create_shapes = entity:GetRoot() == Entity.World
	local is_edit_root = entity == editing
	local can_remove = can_edit_components(entity) and not is_edit_root

	if not can_create_shapes and not can_remove then return false end

	local has_above_remove = can_create_shapes
	Panel.OpenContextMenu(
		{
			OnClose = function(self)
				self:Remove()
			end,
		},
		{
			can_create_shapes and
			MenuItem{
				Text = "Go to",
				Icon = "target",
				OnClick = function()
					go_to_entity(entity)
				end,
			} or
			nil,
			can_create_shapes and
			MenuSpacer{} or
			nil,
			is_edit_root and
			MenuItem{
				Text = "Exit prefab",
				Icon = "arrow_left",
				OnClick = function()
					h.exit_prefab_edit()
				end,
			} or
			nil,
			not is_edit_root and
			entity.prefab and
			entity.prefab.definition and
			MenuItem{
				Text = "Edit prefab",
				Icon = "layers",
				OnClick = function()
					h.enter_prefab_edit(entity)
				end,
			} or
			nil,
			can_create_shapes and
			can_remove and
			MenuItem{
				Text = "Cut",
				Icon = "move",
				OnClick = function()
					f.cut = entity
				end,
			} or
			nil,
			can_create_shapes and
			h.can_paste(entity) and
			MenuItem{
				Text = "Paste " .. f.cut:GetName(),
				Icon = "paste",
				OnClick = function()
					h.paste_into(entity)
				end,
			} or
			nil,
			can_create_shapes and
			MenuItem{
				Text = "Entity",
				Icon = "cube",
				OnClick = function()
					h.create_child_entity(entity)
				end,
			} or
			nil,
			can_create_shapes and
			MenuItem{
				Text = "Prefab",
				Icon = "layers",
				OnClick = function()
					h.pick_child_prefab(entity)
				end,
			} or
			nil,
			can_create_shapes and
			can_remove and
			not scene.IsTransientEntity(entity) and
			MenuItem{
				Text = "Clone",
				Icon = "copy",
				OnClick = function()
					local clone = scene.Clone(entity)
					editor_history.RecordCreate("clone " .. entity:GetName(), clone)
					h.set_selected_target(clone)
				end,
			} or
			nil,
			can_create_shapes and
			can_remove and
			network.IsConnected() and
			MenuItem{
				Text = "Send to server",
				Icon = "upload",
				OnClick = function()
					scene_sync.Push(entity)
				end,
			} or
			nil,
			can_create_shapes and
			can_remove and
			network.IsConnected() and
			MenuItem{
				Text = "Remove on server",
				Icon = "trash",
				OnClick = function()
					scene_sync.RemoveOnServer(entity)
				end,
			} or
			nil,
			can_create_shapes and
			can_remove and
			prefab_tools.GetMenuItem(entity, h.set_selected_target) or
			nil,
			can_remove and
			has_above_remove and
			MenuSpacer{} or
			nil,
			can_remove and
			MenuItem{
				Text = "Remove",
				Icon = "trash",
				OnClick = function()
					local parent = entity:GetParent()

					if parent:IsValid() then h.set_selected_target(parent) end

					if entity:GetRoot() == Entity.World then
						editor_history.RemoveEntity(entity)
					else
						entity:Remove()
						prefab.MarkStructureDirty(parent)
						editor_history.Barrier("a 2D panel was removed")
					end
				end,
			} or
			nil,
		}
	)
	return true
end

-- a button that floats over a corner of another panel and follows it
local CornerButton = react.Component(|props| -> do
	local button = react.UseRef()

	local follow = || -> do
		local anchor = props.Anchor.current

		if not (anchor and anchor:IsValid()) then return end

		local _, _, x, y = anchor.transform:GetWorldRectFast()
		local size = button.current.transform:GetSize()
		button.current.transform:SetPosition(
			button.current:GetParent().transform:GlobalToLocal(Vec2(x - size.x + props.OffsetX, y - size.y + props.OffsetY))
		)
	end

	-- in place before the first frame, then it follows the panel when the window moves or resizes
	react.UseLayoutEffect(follow, {})
	react.UseEvent("Update", follow)

	return IconButton{
		Ref = button,
		Name = props.Name,
		Icon = props.Icon,
		Size = Vec2(28, 28),
		Padding = "XXS",
		Mode = "outline",
		Active = props.Active,
		Tooltip = props.Tooltip,
		layout = {Floating = true},
		OnClick = props.OnClick,
	}
end)
local Editor = react.Component(|props| -> do
	local window = react.UseRef()
	local tree = react.UseRef()
	local tree_scroll = react.UseRef()
	local property_scroll = react.UseRef()
	local property_editor = react.UseRef()
	local flags = react.UseRef({stack = {}, transient = false, nearby = false, nearby_dirty = true})
	local edit_stack, set_edit_stack = react.UseState({})
	local playing, set_playing = react.UseState(false)
	local sync, sync_properties = react.UseState(0)
	local search, set_search = react.UseState("")
	local applied_search = react.UseDebounce(search, 0.25)
	local picking = react.UsePoll(picker.IsActive)
	local size = react.UseMemo(|| -> Vec2(400, Panel.World.transform:GetSize().y), {})
	local view = react.UseResource(|| -> View.New{Priority = 10}:Activate(), |view| -> view:Remove(), {})
	-- the actions of the editor, they keep their identity and read the state that changes through h.f
	local h = react.UseMemo(|| -> do
		local f = flags.current
		local h = {f = f, tree = tree}
		picker.include_transient = false

		function h.set_transient(show)
			f.transient = show
			picker.include_transient = show
			tree.current:Refresh(true)
		end

		-- what is inside an instance is only visible while that instance is edited, anything else selects the instance
		function h.resolve_target(target)
			local editing = f.stack[#f.stack]
			local stop = editing and editing.prefab or nil

			while target.prefab_owner and target.prefab_owner ~= stop do
				target = target.prefab_owner.Owner
			end

			return target
		end

		function h.set_selected_target(target)
			target = h.resolve_target(target)

			if not f.transient and target:IsRuntime() then h.set_transient(true) end

			Gizmo.EnableGizmo(target)
			prefab_tools.Watch(target)
			tree.current:SelectEntity(target)
			tree.current:ExpandToEntity(target)
			tree.current:EnsureEntityVisible(target)
			sync_properties(|n| -> n + 1)
		end

		function h.add_child_entity(entity, parent_entity, owner, name)
			local world_position = camera.GetPosition() + camera.GetRotation():GetForward() * 2
			entity:SetParent(parent_entity)

			if owner then entity:SetOwnedBy(owner) end

			if parent_entity.transform then
				entity.transform:SetPosition(parent_entity.transform:GetWorldMatrixInverse():TransformVector(world_position))
			else
				entity.transform:SetPosition(world_position)
			end

			editor_history.RecordCreate("create " .. name, entity)
			h.set_selected_target(entity)
		end

		function h.create_child_entity(parent_entity, owner)
			local entity = Entity.New{Name = "entity", Transient = false}
			entity:AddComponent("transform")
			h.add_child_entity(entity, parent_entity, owner, "entity")
		end

		function h.pick_child_prefab(parent_entity, owner)
			AssetBrowser{
				Key = "AssetPicker",
				PickerCategory = "prefabs",
				OnPick = function(asset)
					local entity = Entity.New{Name = asset.name, prefab = {Path = asset.name}}
					entity:SetTransient(false)
					h.add_child_entity(entity, parent_entity, owner, asset.name)
				end,
			}
		end

		-- the entity that was cut stays where it is until it is pasted so it can be taken across prefab mode and the scene
		function h.can_cut(entity)
			return can_edit_components(entity) and entity ~= f.stack[#f.stack]
		end

		function h.can_paste(target)
			local cut = f.cut

			if not (cut and cut:IsValid()) then return false end

			if target == cut or target:ContainsParent(cut) then return false end

			local root = cut:GetRoot()

			return target == root or target:GetRoot() == root
		end

		function h.paste_into(target, owner)
			if not h.can_paste(target) then return end

			local entity = f.cut
			local old_parent = entity:GetParent()
			f.cut = nil

			if old_parent == target and not owner then return end

			local transform = entity.transform
			local keep_world = transform and not transform.Is2D and target.transform and transform.Attachment == "root"
			local world_position, world_rotation

			if keep_world then
				world_position = transform:GetWorldPosition()
				world_rotation = transform:GetWorldMatrix():GetRotation()
			end

			entity.prefab_patch = nil
			entity:SetParent(target)

			if owner then entity:SetOwnedBy(owner) end

			if keep_world then
				transform:SetPosition(transform:WorldToLocalPosition(world_position))
				transform:SetRotation(target.transform:GetWorldMatrix():GetRotation():GetConjugated() * world_rotation)
			end

			editor_history.RecordReparent(entity, old_parent, target)
			h.set_selected_target(entity)
		end

		-- prefab mode: the instances whose definition is edited, the last one is the one the tree is rooted on
		function h.set_stack(stack)
			f.stack = stack
			set_edit_stack(stack)
			local editing = stack[#stack]
			prefab.SetEditing(editing and editing.prefab or nil)

			if editing then
				tree.current:SetGroupByOwner(false)
				tree.current:SetRootLabels({[editing] = editing:GetName()})
				tree.current:SetRootEntities({editing})
			else
				tree.current:SetGroupByOwner(true)
				tree.current:SetRootLabels({[Entity.World] = "3D World", [Panel.World] = "2D World"})
				tree.current:SetRootEntities({Entity.World, Panel.World})
			end

			tree.current:ExpandRoots()
		end

		function h.enter_prefab_edit(entity)
			local stack = {table.unpack(f.stack)}
			stack[#stack + 1] = entity
			h.set_stack(stack)
			h.set_selected_target(entity)
		end

		function h.exit_prefab_edit()
			local stack = {table.unpack(f.stack)}
			local left = table.remove(stack)

			if not left then return end

			h.set_stack(stack)

			if left:IsValid() then h.set_selected_target(left) end
		end

		function h.set_playing(value)
			if f.playing == value then return end

			f.playing = value

			if value then
				if picker.IsActive() then picker.Stop() end

				f.playing_selection = tree.current:GetSelectedEntity()
				Gizmo.EnableGizmo(nil)
			elseif f.playing_selection and f.playing_selection:IsValid() then
				Gizmo.EnableGizmo(f.playing_selection)
			end

			window.current.visual:SetVisible(not value)
			set_playing(value)
			event.Call("EditorControlsChanged", value)
		end

		function h.filter(entity)
			if entity_tree_filter_callback(entity, window.current) then return true end

			local editing = f.stack[#f.stack]

			if editing then
				return entity ~= editing and entity.prefab_owner ~= editing.prefab
			end

			return entity.prefab_owner ~= nil or
				(
					not f.transient and
					entity ~= Entity.World and
					entity ~= Panel.World and
					entity:IsRuntime()
				)
		end

		function h.on_select(node, key)
			local target = node and (node.Entity or node.Object) or objects.GetObjectByGUID(key)
			Gizmo.EnableGizmo(target)
			prefab_tools.Watch(target)
			sync_properties(|n| -> n + 1)
			_G.SELECTED_OBJECT = target
		end

		function h.on_hover(node, key, path, row_info, hovered)
			highlight.SetEntity(hovered and node and node.Entity or nil)
		end

		function h.is_dimmed(node)
			return f.cut ~= nil and node.Entity == f.cut
		end

		function h.on_double_click(node)
			local entity = node.Entity

			if entity and entity.prefab and entity.prefab.definition and entity ~= f.stack[#f.stack] then
				h.enter_prefab_edit(entity)
				return true
			end
		end

		function h.on_context_menu(node)
			return open_node_menu(node, h)
		end

		function h.on_category_menu(_, name, entity)
			if not entity.component_list or not can_edit_components(entity) then return end

			return {
				MenuItem{
					Text = "Remove",
					Icon = "trash",
					OnClick = function()
						editor_history.RemoveComponent(entity, name)
					end,
				},
			}
		end

		function h.on_breadcrumb(index)
			while #f.stack >= index do
				h.exit_prefab_edit()
			end
		end

		h.menu_items = make_menu_items(h)
		return h
	end, {})
	local f = h.f

	react.UseEvent("Update", |dt| -> do
		local stack = f.stack

		if stack[1] then
			local pruned = {table.unpack(stack)}

			while pruned[1] and not pruned[#pruned]:IsValid() do
				pruned[#pruned] = nil
			end

			if #pruned ~= #stack then h.set_stack(pruned) end
		end

		local focused = objects:GetFocusedObject()
		local hovered = MouseInput.GetHoveredObject()
		local gizmo_status = Gizmo.GetStatus()
		camera.SetBlockMovement(
			(
				focused:IsValid() and
				window.current:ContainsParent(focused) and
				(
					focused.text ~= nil or
					focused.Name == "TextEdit"
				)
			) or
				f.playing
		)
		camera.SetBlockDragging(
			f.playing or
				(
					hovered:IsValid() and
					hovered ~= Panel.World
				)
				or
				gizmo_status.active_drag or
				gizmo_status.hovered_handle or
				brush_editor.IsBusy()
		)
		camera.Update(dt)
		view:SetPosition(camera.GetPosition():Copy())
		view:SetRotation(camera.GetRotation():Copy())
		local position = camera.GetPosition()

		if not f.camera_position or (position - f.camera_position):GetLength() > 0.001 then
			f.camera_position = position:Copy()
			f.camera_moved = system.GetElapsedTime()
			f.nearby_dirty = true
		elseif f.nearby and f.nearby_dirty and system.GetElapsedTime() - f.camera_moved >= NEARBY_SETTLE_TIME then
			f.nearby_dirty = false
			tree.current:SetNearby(nearby.Collect(position, NEARBY_COUNT))
		end
	end)

	react.UseEffect(|| -> tree.current:SetSearch(applied_search), {applied_search})

	-- the properties of what is selected, rebuilding them again is for a change that is not a value that was edited (that would drop the control that is being dragged)
	react.UseEffect(|| -> do
		local target = tree.current:GetSelectedEntity()

		if target then
			tree.current:BlockMutations()
			property_editor.current:SetObject(target)
			property_editor.current:ExpandAll()
			tree.current:UnblockMutations()
		end
	end, {sync})

	react.UseEvent("EditorSelect", |target| -> h.set_selected_target(target))
	react.UseEvent("PrefabInputsChanged", || -> sync_properties(|n| -> n + 1))
	react.UseEvent("EntityTreeReparent", |entity, old_parent, new_parent| -> editor_history.RecordReparent(entity, old_parent, new_parent))
	react.UseEvent("KeyInput", |key, press| -> do
		if press and key == "e" and input.IsControlDown() then
			h.set_playing(not f.playing)
			return true
		end
	end)
	react.UseEvent("WindowKeyInput", |_, key, press| -> do
		if not press or not input.IsControlDown() then return end

		local focused = objects:GetFocusedObject()

		if focused:IsValid() and window.current:ContainsParent(focused) and (focused.text ~= nil or focused.Name == "TextEdit") then
			return
		end

		if Gizmo.GetStatus().active_drag then return end

		if key == "x" then
			local entity = tree.current:GetSelectedEntity()

			if entity and entity:GetRoot() == Entity.World and h.can_cut(entity) then
				f.cut = entity
				return true
			end
		end

		if key == "v" then
			local entity = tree.current:GetSelectedEntity()

			if entity and h.can_paste(entity) then
				h.paste_into(entity)
				return true
			end
		end

		if key == "z" and not input.IsShiftDown() then
			history:Undo()
			return true
		end

		if key == "y" or key == "z" and input.IsShiftDown() then
			history:Redo()
			return true
		end
	end)

	react.UseEffect(|| -> do
		local removers = {}

		for _, world in ipairs({Entity.World, Panel.World}) do
			removers[#removers + 1] = world:AddLocalListener("OnEntityComponentChanged", |_, entity, _, name| -> do
				local selected_entity = tree.current:GetSelectedEntity()

				if selected_entity and entity == selected_entity then
					sync_properties(|n| -> n + 1)
					prefab_tools.Watch(selected_entity)
				end

				if name == "prefab" or name == "script" then tree.current:Refresh() end
			end)
		end

		return || -> do
			for _, remove in ipairs(removers) do
				remove()
			end

			event.Call("EditorControlsChanged", false)
			highlight.SetEntity()
			prefab_tools.Watch(nil)
			prefab.SetEditing(nil)
			Gizmo.Clear()
			render3d.GetCamera():SetViewport(Rect(0, 0, Panel.World.transform:GetSize().x, Panel.World.transform:GetSize().y))
		end
	end, {})

	-- the window is what the desktop program drives, the tree scrolls to the selected entity so it needs the layout
	react.UseLayoutEffect(|| -> do
		local entity = window.current

		function entity:SetPlaying(value)
			h.set_playing(value)
		end

		function entity:IsPlaying()
			return f.playing == true
		end

		camera.SetPosition(render3d.GetCamera():GetPosition():Copy())
		camera.SetRotation(render3d.GetCamera():GetRotation():Copy())
		tree.current:CollapseOwnerGroup(Entity.World, Entity.World)

		if not props.SelectedEntityGUID then
			local player = _G.PLAYER_RIG
			local outfit = player and player:IsValid() and player.player_avatar.outfit

			if outfit and outfit:IsValid() then
				h.set_selected_target(outfit)
			else
				local closest = nearby.Collect(camera.GetPosition(), 1)[1]

				if closest then h.set_selected_target(closest.entity) end
			end
		end

		local selected = tree.current:GetSelectedEntity()

		if selected and selected:IsValid() and selected.transform then view_from_front(selected) end
	end, {})

	local names = {}

	if edit_stack[1] then
		names[1] = "scene"

		for i, entity in ipairs(edit_stack) do
			names[i + 1] = entity.prefab.Path
		end
	end

	return Window{
		Ref = window,
		RequestMouse = props.RequestMouse,
		Title = "ENTITY EDITOR",
		Name = "entity editor",
		Size = size,
		Position = Vec2(0, 0),
		Padding = Rect(),
		MinSize = Vec2(320, 320),
		OnClose = |self| -> props.OnClose(self, tree.current:GetSelectedEntityGUID()),
	}{
		MenuBar{MenuKey = "EditorMenuBarContextMenu", Items = h.menu_items, layout = {GrowWidth = 1}},
		Splitter{
			InitialSize = math.floor(size.y * 0.45),
			MinSplitSize = 120,
			Vertical = true,
			Padding = Rect(),
			layout = {GrowWidth = 1, GrowHeight = 1},
		}{
			Column{
				layout = {
					Direction = "y",
					GrowWidth = 1,
					GrowHeight = 1,
					FitHeight = false,
					ChildGap = 2,
					AlignmentX = "stretch",
				},
			}{
				TextEdit{
					Hint = "search: name, model:path, name:text",
					Size = Vec2(0, 28),
					MinSize = Vec2(100, 28),
					MaxSize = Vec2(0, 28),
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					OnTextChanged = |_, text| -> set_search(text),
					layout = {GrowWidth = 1},
				},
				Breadcrumb{Items = names, Icons = {scene = "world"}, OnSelect = h.on_breadcrumb},
				ScrollablePanel{
					Ref = tree_scroll,
					ScrollX = false,
					ScrollY = true,
					Padding = Rect(),
					layout = {GrowWidth = 1, GrowHeight = 1},
				}{
					EntityTree{
						Ref = tree,
						RootEntities = {Entity.World, Panel.World},
						RootLabels = {[Entity.World] = "3D World", [Panel.World] = "2D World"},
						SelectedKey = props.SelectedEntityGUID,
						ShowVirtualChildren = true,
						GroupByOwner = true,
						FilterCallback = h.filter,
						layout = {GrowWidth = 1, FitHeight = true},
						OnSelect = h.on_select,
						OnNodeHover = h.on_hover,
						OnIsNodeDimmed = h.is_dimmed,
						OnNodeDoubleClick = h.on_double_click,
						OnNodeContextMenu = h.on_context_menu,
					},
				},
			},
			ScrollablePanel{
				Ref = property_scroll,
				ScrollX = false,
				ScrollY = true,
				Padding = "none",
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				PanelElement{
					Name = "PropertyEditorFrame",
					transform = true,
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						FitWidth = false,
						MinSize = Vec2(size.x - 24, 0),
						Padding = Rect(2, 2, 2, 2),
					},
				}{
					PropertyEditor{
						Ref = property_editor,
						OnPropertyEdited = editor_history.RecordProperty,
						CategoryOrder = COMPONENT_ORDER,
						OnContextActions = prefab_tools.GetPropertyActions,
						OnCategoryContextMenu = h.on_category_menu,
						OnGetCategoryBadge = prefab_tools.GetCategoryBadge,
						OnGetPropertyBadge = prefab_tools.GetPropertyBadge,
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							FitWidth = false,
							MinSize = Vec2(size.x - 28, 0),
						},
					},
				},
			},
		},
		CornerButton{
			Name = "PickerButton",
			Icon = "target",
			Tooltip = "pick an entity in the scene",
			Anchor = tree_scroll,
			OffsetX = -4,
			OffsetY = 0,
			Active = picking,
			OnClick = |self| -> do
				if picker.IsActive() then
					picker.Stop()
				else
					self.mouse_input:SetCursorOverride("crosshair")
					picker.Start{
						mode = "entity",
						on_pick = |target| -> h.set_selected_target(target),
						on_stop = || -> self.mouse_input:ClearCursorOverride(),
					}
				end

				return true
			end,
		},
		CornerButton{
			Name = "AddComponentButton",
			Icon = "plus",
			Tooltip = "add a component to the selected entity",
			Anchor = property_scroll,
			OffsetX = -16,
			OffsetY = -8,
			OnClick = || -> do
				local entity = tree.current:GetSelectedEntity()

				if not entity or not can_edit_components(entity) then return true end

				AssetBrowser{
					Key = "AssetPicker",
					PickerCategory = "components",
					ComponentTarget = entity,
					OnPick = |asset| -> editor_history.AddComponent(entity, asset.name),
				}

				return true
			end,
		},
	}
end)

return function(props)
	return kit.OpenOnce(props.Key, || -> react.Mount(
		Editor{
			RequestMouse = props.RequestMouse,
			SelectedEntityGUID = props.SelectedEntityGUID,
			OnClose = props.OnClose,
		},
		Panel.World
	):GetEntity())
end
