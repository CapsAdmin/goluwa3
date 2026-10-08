local Vec2 = import("goluwa/structs/vec2.lua")
local Entity = import("goluwa/entities/entity.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local EntityTree = import("goluwa/render2d/ui/widgets/entity_tree.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function show_entity(page, entity)
	if not (entity and entity:IsValid()) then
		page.title.text:SetText("Nothing selected")
		page.meta.text:SetText("")
		page.body.text:SetText("Select an entity from the tree to inspect it.")
		return
	end

	local children = #entity:GetChildren()
	local components = #entity.component_list
	local meta = "Type: " .. (entity.Type or "entity")

	if children > 0 then meta = meta .. "  |  " .. children .. " children" end

	if components > 0 then meta = meta .. "  |  " .. components .. " components" end

	page.title.text:SetText(entity:GetName() ~= "" and entity:GetName() or entity.Type)
	page.meta.text:SetText(meta)
	page.body.text:SetText("GUID: " .. entity:GetGUID())
end

local function add_test_entity(button)
	if not RENDER_3D then return end

	local page = button.Page
	local entity = import("goluwa/render3d/shapes.lua").Box{
		Name = "Test Box",
		Collision = false,
		RigidBody = false,
		PhysicsNoCollision = true,
	}
	entity:SetParent(Entity.World)
	show_entity(page, entity)
	page.tree:SelectEntity(entity)
	page.tree:ExpandToEntity(entity)
end

return {
	Name = "entity tree",
	Section = "Data",
	Order = 2,
	Create = function()
		local page = {}
		page.title = Text{Text = "Nothing selected", Font = "body_strong M", IgnoreMouseInput = true}
		page.meta = Text{
			Text = "",
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
		page.body = Text{
			Text = "Select an entity from the tree to inspect it.",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
		page.tree = EntityTree{
			RootEntities = {Entity.World},
			RootLabels = {[Entity.World] = "3D World"},
			ShowVirtualChildren = true,
			OnSelect = function(node)
				show_entity(page, node and node.Entity)
			end,
		}
		return kit.Page{
			Title = "Entity tree",
			Description = "A live reflection of the entity hierarchy built on Tree. Nodes are keyed by GUID, expansion survives refreshes and rows can be dragged to reparent entities.",
		}{
			kit.Section{
				Title = "Hierarchy",
				Description = "SetRootEntities, SetFilterCallback and SetShowVirtualChildren change what is shown. SetSearch filters by name or model.",
			}{
				kit.Group{
					Button{
						Text = "Expand all",
						OnClick = function()
							page.tree:ExpandAll()
						end,
					},
					Button{
						Text = "Collapse all",
						Mode = "outline",
						OnClick = function()
							page.tree:CollapseAll()
						end,
					},
					Button{
						Text = "Refresh",
						Mode = "outline",
						OnClick = function()
							page.tree:Refresh()
						end,
					},
					Button{
						Page = page,
						Text = "Add test entity",
						Mode = "outline",
						OnClick = add_test_entity,
					},
					Checkbox{
						Text = "Show virtual children",
						Value = true,
						OnChange = function(value)
							page.tree:SetShowVirtualChildren(value)
						end,
					},
				},
				Splitter{InitialSize = 300, layout = {MinSize = Vec2(0, 320), MaxSize = Vec2(0, 320)}}{
					Frame{Padding = "XS", layout = {GrowWidth = 1, GrowHeight = 1}}{
						ScrollablePanel{layout = {GrowWidth = 1, GrowHeight = 1}, Padding = "XXS"}{page.tree},
					},
					Frame{Padding = "S", layout = {GrowWidth = 1, GrowHeight = 1}}{
						Column{
							layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch", ChildGap = "XS"},
						}{
							page.title,
							page.meta,
							page.body,
						},
					},
				},
			},
		}
	end,
}
