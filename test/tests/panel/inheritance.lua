local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
-- Create a parent widget type with components defined via CMP
local ParentWidget = Panel:CreateTemplate("test_parent_widget")
ParentWidget.Base = Panel
ParentWidget.CMP.transform = {}
ParentWidget.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
}
ParentWidget.CMP.animation = {}
ParentWidget.CMP.visual = {}
ParentWidget.CMP.mouse_input = {}

function ParentWidget:OnCreate(props)
	ParentWidget.BaseClass.OnCreate(self, props)
end

ParentWidget:Register()
-- Create a child widget type that inherits from ParentWidget
local ChildWidget = Panel:CreateTemplate("test_child_widget")
ChildWidget.Base = ParentWidget

function ChildWidget:OnCreate(props)
	ChildWidget.BaseClass.OnCreate(self, props)
end

ChildWidget:Register()

T.Test("inheritance - derived panel has parent components", function()
	local child = ChildWidget.New{}
	T(child:IsValid())["=="](true)
	-- Components defined in ParentWidget should be available on ChildWidget instances
	T(child.transform)["~="](nil, "transform component should be inherited")
	T(child.layout)["~="](nil, "layout component should be inherited")
	T(child.animation)["~="](nil, "animation component should be inherited")
	T(child.visual)["~="](nil, "visual component should be inherited")
	T(child.mouse_input)["~="](nil, "mouse_input component should be inherited")
	child:Remove()
end)

T.Test("inheritance - derived panel ComponentSet includes parent components", function()
	-- The prepared metatable should have a ComponentSet that includes all parent components
	local objects = import("goluwa/objects/objects.lua")
	local child_meta = objects.GetRegistered("panel_test_child_widget")
	T(child_meta)["~="](nil)
	T(child_meta.ComponentSet)["~="](nil, "ComponentSet should exist")
	-- Check that parent's components are in the ComponentSet
	local has_transform = false
	local has_layout = false
	local has_animation = false

	for _, name in ipairs(child_meta.ComponentSet) do
		if name == "transform" then has_transform = true end

		if name == "layout" then has_layout = true end

		if name == "animation" then has_animation = true end
	end

	T(has_transform)["=="](true, "transform should be in ComponentSet")
	T(has_layout)["=="](true, "layout should be in ComponentSet")
	T(has_animation)["=="](true, "animation should be in ComponentSet")
end)

T.Test("inheritance - BaseClass points to direct parent", function()
	local objects = import("goluwa/objects/objects.lua")
	local child_meta = objects.GetRegistered("panel_test_child_widget")
	local parent_meta = objects.GetRegistered("panel_test_parent_widget")
	T(child_meta.BaseClass)["~="](nil, "BaseClass should be set")
	T(child_meta.BaseClass.Type)["=="]("panel_test_parent_widget", "BaseClass should point to direct parent")
	-- Parent's BaseClass should point to Panel
	T(parent_meta.BaseClass)["~="](nil, "Parent's BaseClass should be set")
end)

T.Test("inheritance - derived panel OnCreate chain works", function()
	-- If we get here without errors, the OnCreate chain works.
	-- The key test is that the instance has all components from the inheritance chain.
	local child = ChildWidget.New{}
	T(child:IsValid())["=="](true, "instance should be valid after OnCreate chain")
	T(child.transform)["~="](nil, "transform from parent should exist")
	T(child.animation)["~="](nil, "animation from parent should exist")
	child:Remove()
end)

T.Test2D("inheritance - tree widget with items produces rows", function()
	-- Reproduce the gallery tree demo scenario: create a derived tree with items and callbacks
	local Tree = import("goluwa/render2d/ui/widgets/tree.lua")
	local DerivedTree = Panel:CreateTemplate("test_derived_tree2")
	DerivedTree.Base = Tree

	function DerivedTree:OnCreate(props)
		DerivedTree.BaseClass.OnCreate(self, props)
	end

	DerivedTree:Register()
	local items = {
		{
			Key = "root",
			Text = "Root Folder",
			Expanded = true,
			Children = {
				{Key = "file1", Text = "file1.lua"},
				{Key = "file2", Text = "file2.lua"},
			},
		},
	}
	local on_get_text_called = false
	local tree_view = DerivedTree.New{
		Items = items,
		SelectedKey = "file1",
		OnGetText = function(node, path)
			on_get_text_called = true
			return node.Text or "Item"
		end,
		OnSelect = function() end,
	}
	T(tree_view:IsValid())["=="](true)
	T(#tree_view._items)["=="](1, "should have 1 root item")
	T(#tree_view._row_order)[">"](#items, "should have rows for root + children")
	T(#tree_view:GetChildren())[">"](#items, "should have child panels for rows")
	-- Verify the callback was used (proves inheritance of callback mechanism works)
	T(on_get_text_called)["=="](true, "OnGetText callback should have been called during row creation")
	-- Verify row info is populated
	local root_info = tree_view._row_infos["root"]
	T(root_info)["~="](nil, "row info for root should exist")
	T(root_info.node.Key)["=="]("root")
	T(root_info.has_children)["=="](true)
	tree_view:Remove()
end)
