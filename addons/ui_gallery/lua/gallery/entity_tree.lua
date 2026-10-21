local Vec2 = import("goluwa/structs/vec2.lua")
local Entity = import("goluwa/entities/entity.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local ROOTS = {Entity.World}
local ROOT_LABELS = {[Entity.World] = "3D World"}
return {
	Name = "entity tree",
	Section = "Data",
	Order = 2,
	View = react.Component(
		||-> do
			local tree = react.UseRef()
			local selected, set_selected = react.UseState()
			local show_virtual, set_show_virtual = react.UseState(true)
			local title = "Nothing selected"
			local meta = ""
			local body = "Select an entity from the tree to inspect it."

			if selected and selected:IsValid() then
				local children = #selected:GetChildren()
				local components = #selected.component_list
				meta = "Type: " .. (selected.Type or "entity")

				if children > 0 then meta = meta .. "  |  " .. children .. " children" end

				if components > 0 then meta = meta .. "  |  " .. components .. " components" end

				title = selected:GetName() ~= "" and selected:GetName() or selected.Type
				body = "GUID: " .. selected:GetGUID()
			end

			return kit.Page{
				Title = "Entity tree",
				Description = "A live reflection of the entity hierarchy built on Tree. Nodes are keyed by GUID, expansion survives refreshes and rows can be dragged to reparent entities.",
			}{
				kit.Section{
					Title = "Hierarchy",
					Description = "SetRootEntities, SetFilterCallback and SetShowVirtualChildren change what is shown. SetSearch filters by name or model.",
				}{
					kit.Group{
						ui.Button{Text = "Expand all", OnClick = ||->tree.current:ExpandAll()},
						ui.Button{
							Text = "Collapse all",
							Mode = "outline",
							OnClick = ||->tree.current:CollapseAll(),
						},
						ui.Button{Text = "Refresh", Mode = "outline", OnClick = ||->tree.current:Refresh()},
						ui.Button{
							Text = "Add test entity",
							Mode = "outline",
							OnClick = ||-> do
								if not RENDER_3D then return end

								local entity = import("goluwa/render3d/shapes.lua").Box{
									Name = "Test Box",
									Collision = false,
									RigidBody = false,
									PhysicsNoCollision = true,
								}
								entity:SetParent(Entity.World)
								set_selected(entity)
								tree.current:SelectEntity(entity)
								tree.current:ExpandToEntity(entity)
							end,
						},
						ui.Checkbox{Text = "Show virtual children", Value = true, OnChange = set_show_virtual},
					},
					ui.Splitter{InitialSize = 300, layout = {MinSize = Vec2(0, 320), MaxSize = Vec2(0, 320)}}{
						ui.Frame{Padding = "XS", layout = {GrowWidth = 1, GrowHeight = 1}}{
							ui.ScrollablePanel{layout = {GrowWidth = 1, GrowHeight = 1}, Padding = "XXS"}{
								ui.EntityTree{
									Ref = tree,
									RootEntities = ROOTS,
									RootLabels = ROOT_LABELS,
									ShowVirtualChildren = show_virtual,
									OnSelect = |node|->set_selected(node and node.Entity),
								},
							},
						},
						ui.Frame{Padding = "S", layout = {GrowWidth = 1, GrowHeight = 1}}{
							ui.Column{
								layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch", ChildGap = "XS"},
							}{
								ui.Text{Text = title, Font = "body_strong M", IgnoreMouseInput = true},
								ui.Text{
									Text = meta,
									Color = "text_disabled",
									Wrap = true,
									IgnoreMouseInput = true,
									layout = {GrowWidth = 1},
								},
								ui.Text{Text = body, Wrap = true, IgnoreMouseInput = true, layout = {GrowWidth = 1}},
							},
						},
					},
				},
			}
		end
	),
}
