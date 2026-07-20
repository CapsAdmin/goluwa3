local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Entity = import("goluwa/entities/entity.lua")
local objects = import("goluwa/objects/objects.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local SVG = import("goluwa/render2d/ui/elements/svg.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local EntityTree = import("goluwa/render2d/ui/widgets/entity_tree.lua")
local shapes = _G.GRAPHICS_3D and import("lua/shapes.lua") or {}
local ICON_SOURCES = {
	folder = "https://api.iconify.design/ic/baseline-folder.svg",
	file = "https://api.iconify.design/ic/round-insert-drive-file.svg",
	entity = "https://api.iconify.design/ic/round-bubble-chart.svg",
}
return {
	Name = "entity_tree",
	Create = function()
		local state = {
			show_virtual = true,
			selected_guid = nil,
		}
		local tree_view
		local detail_title
		local detail_meta
		local detail_body

		local function set_text(panel, value)
			if panel and panel:IsValid() then panel.text:SetText(value or "") end
		end

		local function refresh_details(entity)
			if not (entity and entity.IsValid and entity:IsValid()) then
				set_text(detail_title, "Nothing selected")
				set_text(detail_meta, "")
				set_text(detail_body, "Select an entity from the tree to inspect it.")
				return
			end

			state.selected_guid = entity:GetGUID()
			local child_count = #entity:GetChildren()
			local comp_count = #entity.component_list
			local meta = "Type: " .. (entity.Type or "entity")

			if child_count > 0 then
				meta = meta .. "  |  " .. child_count .. " child" .. (child_count == 1 and "" or "ren")
			end

			if comp_count > 0 then
				meta = meta .. "  |  " .. comp_count .. " component" .. (comp_count == 1 and "" or "s")
			end

			local parent = entity:GetParent()

			if parent and parent:IsValid() then
				meta = meta .. "  |  parent: " .. (parent:GetName() or parent:GetKey() or parent.Type)
			end

			set_text(detail_title, entity:GetName() or entity:GetKey() or entity.Type)
			set_text(detail_meta, meta)
			set_text(detail_body, "GUID: " .. entity:GetGUID())
		end

		local function create_test_entity()
			if not _G.GRAPHICS_3D then return end

			-- Create a material so the entity has a virtual child reference
			local Material = import("goluwa/render3d/material.lua")
			local test_material = Material.New()
			test_material:SetName("TestMaterial")

			local config = {
				Name = "Test Box",
				Collision = false,
				RigidBody = false,
				PhysicsNoCollision = true,
				Material = test_material,
			}
			local entity = shapes.Box(config)

			if entity:HasComponent("rigid_body") then
				entity:RemoveComponent("rigid_body")
			end

			entity:SetParent(Entity.World)
			refresh_details(entity)

			if tree_view and tree_view:IsValid() then
				tree_view:SelectEntity(entity)
				tree_view:ExpandToEntity(entity)
				tree_view:EnsureEntityVisible(entity, Rect(0, 12, 0, 12))
			end
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Entity Tree",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Live reflection of the 3D entity hierarchy. Nodes are keyed by entity GUID, expansion state is preserved, and drag-and-drop reparenting is supported.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
					AlignmentX = "stretch",
				},
			}{
				Button{
					Text = "Expand All",
					OnClick = function()
						if tree_view and tree_view:IsValid() then tree_view:ExpandAll() end
					end,
				},
				Button{
					Text = "Collapse All",
					Mode = "outline",
					OnClick = function()
						if tree_view and tree_view:IsValid() then tree_view:CollapseAll() end
					end,
				},
				Button{
					Text = "Add test entity",
					Mode = "outline",
					OnClick = create_test_entity,
				},
				Button{
					Text = "Refresh",
					Mode = "outline",
					OnClick = function()
						if tree_view and tree_view:IsValid() then tree_view:Refresh() end
					end,
				},
				Row{
					layout = {
						FitWidth = true,
						ChildGap = 8,
						AlignmentY = "center",
						GrowWidth = 1,
					},
				}{
					Checkbox{
						Value = state.show_virtual,
						OnChange = function(value)
							state.show_virtual = value

							if tree_view and tree_view:IsValid() then
								tree_view:SetShowVirtualChildren(value)
							end
						end,
					},
					Text{
						Text = "Show virtual children",
						IgnoreMouseInput = true,
					},
				},
			},
			Splitter{
				InitialSize = 280,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, 320),
					MaxSize = Vec2(0, 320),
				},
			}{
				Frame{
					Padding = "XS",
					layout = {GrowHeight = 1, GrowWidth = 1},
				}{
					ScrollablePanel{
						layout = {GrowHeight = 1, GrowWidth = 1},
						Padding = "XXS",
					}{
						EntityTree{
							RootEntities = {Entity.World},
							RootLabels = {[Entity.World] = "3D World"},
							ShowVirtualChildren = state.show_virtual,
							Ref = function(self)
								tree_view = self
							end,
							OnSelect = function(node, key, path)
								local entity = node and node.Entity

								if entity and entity:IsValid() then refresh_details(entity) end
							end,
							layout = {
								GrowWidth = 1,
								FitHeight = true,
							},
						},
					},
				},
				Frame{
					Padding = "S",
					layout = {GrowHeight = 1, GrowWidth = 1},
				}{
					Column{
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							AlignmentX = "stretch",
							ChildGap = 8,
						},
					}{
						Text{
							Ref = function(self)
								detail_title = self
							end,
							Text = "Nothing selected",
							Font = "body_strong S",
							IgnoreMouseInput = true,
						},
						Text{
							Ref = function(self)
								detail_meta = self
							end,
							Text = "",
							Color = "text_disabled",
							IgnoreMouseInput = true,
							layout = {GrowWidth = 1},
						},
						Text{
							Ref = function(self)
								detail_body = self
							end,
							Text = "Select an entity from the tree to inspect it.",
							IgnoreMouseInput = true,
						},
						Text{
							Text = "Notes",
							Font = "body_strong S",
							IgnoreMouseInput = true,
						},
						Text{
							Text = "Only Entity.World is reflected to avoid recursion (Panel.World contains the UI itself). Use SetRootEntities() to change roots, SetFilterCallback() to hide entities, and SetShowVirtualChildren() to display shared-object references.",
							Wrap = true,
							IgnoreMouseInput = true,
							layout = {GrowWidth = 1},
						},
					},
				},
			},
		}
	end,
}
