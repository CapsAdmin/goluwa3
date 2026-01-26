local ecs = require("ecs.ecs")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local transform_2d = require("ecs.components.2d.transform")
local rect_2d = require("ecs.components.2d.rect")
local text_2d = require("ecs.components.2d.text")
local mouse_input_2d = require("ecs.components.2d.mouse_input")
local key_input_2d = require("ecs.components.2d.key_input")
local resizable_2d = require("ecs.components.2d.resizable")
local animations_2d = require("ecs.components.2d.animations")
local layout_2d = require("ecs.components.2d.layout")
ecs.Clear2DWorld()

do -- mouse input
	local entity = ecs.CreateEntity("my_button", ecs.Get2DWorld())
	entity:AddComponent(require("ecs.components.2d.gui_element"))
	local tr = entity:AddComponent(transform_2d)
	tr:SetPosition(Vec2(50, 50))
	tr:SetSize(Vec2(60, 20))
	local rect = entity:AddComponent(rect_2d)
	rect:SetColor(Color(1, 0, 0, 1))
	local mouse = entity:AddComponent(mouse_input_2d)
	mouse:SetCursor("hand")
	mouse:SetDragEnabled(true)
	mouse:SetFocusOnClick(true)
	entity:AddComponent(key_input_2d)
	entity:AddComponent(animations_2d)
	local label = ecs.CreateEntity("label", entity)
	local txt = label:AddComponent(text_2d)
	txt:SetText("Drag Me!")
	txt:SetColor(Color(1, 1, 1, 1))
	label:AddComponent(layout_2d):CenterSimple()

	function entity:OnHover(hovered)
		if hovered then
			self.animations_2d:Animate({
				var = "DrawScaleOffset",
				to = Vec2(1.5, 1.5),
				time = 0.1,
			})
			self.animations_2d:Animate({
				var = "DrawColor",
				to = Color(0, 1, 1, 0),
				time = 0.2,
			})
		else
			self.animations_2d:Animate({
				var = "DrawScaleOffset",
				to = Vec2(1, 1),
				time = 0.1,
			})
			self.animations_2d:Animate({
				var = "DrawColor",
				to = Color(0, 0, 0, 0),
				time = 0.2,
			})
		end
	end

	function entity:OnFocus()
		print("Entity focused!")
		rect:SetColor(Color(0, 1, 0, 1))
	end

	function entity:OnUnfocus()
		print("Entity unfocused!")
		rect:SetColor(Color(1, 0, 0, 1))
	end

	function entity:OnMouseInput(button, press, pos)
		print("Button clicked!", button, press, pos)
	end

	function entity:OnKeyInput(key, press)
		print("Key input!", key, press)
	end

	function entity:OnCharInput(char)
		print("Char input!", char)
	end
end

do -- drag
	local parent = ecs.CreateEntity("draggable_parent", ecs.Get2DWorld())
	parent:AddComponent(require("ecs.components.2d.gui_element"))
	parent:AddComponent(transform_2d)
	parent.transform_2d:SetPosition(Vec2(200, 200))
	parent.transform_2d:SetSize(Vec2(200, 200))
	parent:AddComponent(rect_2d):SetColor(Color(0.2, 0.2, 0.2, 0.8))
	local p_mouse = parent:AddComponent(mouse_input_2d)
	p_mouse:SetDragEnabled(true)
	p_mouse:SetBringToFrontOnClick(true)
	p_mouse:SetFocusOnClick(true)
	local layout = parent:AddComponent(layout_2d)
	layout:SetPadding(Rect(10, 10, 10, 10))
	local child = ecs.CreateEntity("child_button", parent)
	child:AddComponent(transform_2d)
	child.transform_2d:SetPosition(Vec2(50, 50))
	child.transform_2d:SetSize(Vec2(100, 30))
	child:AddComponent(rect_2d):SetColor(Color(0, 0.5, 1, 1))
	local c_mouse = child:AddComponent(mouse_input_2d)
	c_mouse:SetCursor("ibeam")
	local c_layout = child:AddComponent(layout_2d)
	c_layout:SetLayout({"FillX", "CenterY"})

	function child:OnHover(hovered)
		if hovered then
			self.rect_2d:SetColor(Color(0.2, 0.7, 1, 1))
		else
			self.rect_2d:SetColor(Color(0, 0.5, 1, 1))
		end
	end
end

do -- scroll
	local scroll_panel = ecs.CreateEntity("scroll_panel", ecs.Get2DWorld())
	scroll_panel:AddComponent(require("ecs.components.2d.gui_element"))
	local tr = scroll_panel:AddComponent(transform_2d)
	tr:SetPosition(Vec2(500, 100))
	tr:SetSize(Vec2(150, 150))
	tr:SetScrollEnabled(true)
	local rect = scroll_panel:AddComponent(rect_2d)
	rect:SetColor(Color(0.1, 0.1, 0.1, 1))
	scroll_panel.gui_element_2d:SetClipping(true)
	scroll_panel.gui_element_2d:SetBorderRadius(10)
	scroll_panel:AddComponent(mouse_input_2d)
	local s_layout = scroll_panel:AddComponent(layout_2d)
	s_layout:SetStack(true)
	s_layout:SetStackRight(false)
	s_layout:SetPadding(Rect(5, 5, 5, 5))

	for i = 1, 10 do
		local item = ecs.CreateEntity("scroll_item_" .. i, scroll_panel)
		item:AddComponent(transform_2d)
		item.transform_2d:SetSize(Vec2(130, 30))
		local item_rect = item:AddComponent(rect_2d)
		item_rect:SetColor(Color(math.random(), math.random(), math.random(), 1))
		item.gui_element_2d:SetBorderRadius(5)
		item:AddComponent(mouse_input_2d):SetCursor("hand")
		item:AddComponent(layout_2d):SetMargin(Rect(0, 0, 0, 5))
		local label = ecs.CreateEntity("label", item)
		local txt = label:AddComponent(text_2d)
		txt:SetText("Item #" .. i)
		label:AddComponent(layout_2d):CenterSimple()
	end
end

do -- flex box (RGB)
	local flex_panel = ecs.CreateEntity("flex_panel", ecs.Get2DWorld())
	flex_panel:AddComponent(require("ecs.components.2d.gui_element"))
	flex_panel:AddComponent(transform_2d):SetPosition(Vec2(50, 200))
	flex_panel.transform_2d:SetSize(Vec2(120, 200))
	flex_panel:AddComponent(rect_2d):SetColor("#333333")
	local fl = flex_panel:AddComponent(layout_2d)
	fl:SetFlex(true)
	fl:SetFlexDirection("column")
	fl:SetFlexGap(10)
	fl:SetFlexJustifyContent("center")
	fl:SetPadding(Rect(10, 10, 10, 10))

	for i = 1, 3 do
		local item = ecs.CreateEntity("flex_item_" .. i, flex_panel)
		item:AddComponent(transform_2d):SetSize(Vec2(100, 30))
		item:AddComponent(rect_2d):SetColor(i == 1 and "#ff0000" or (i == 2 and "#00ff00" or "#0000ff"))
		item:AddComponent(layout_2d)
		local label = ecs.CreateEntity("label", item)
		local txt = label:AddComponent(text_2d)
		txt:SetText(i == 1 and "Red" or (i == 2 and "Green" or "Blue"))
		label:AddComponent(layout_2d):CenterSimple()
	end
end

do -- shadows
	local shadow_panel = ecs.CreateEntity("shadow_panel", ecs.Get2DWorld())
	shadow_panel:AddComponent(require("ecs.components.2d.gui_element"))
	shadow_panel:AddComponent(transform_2d)
	shadow_panel.transform_2d:SetPosition(Vec2(700, 100))
	shadow_panel.transform_2d:SetSize(Vec2(200, 200))
	local s_rect = shadow_panel:AddComponent(rect_2d)
	s_rect:SetColor("#2d2d2d")
	shadow_panel.gui_element_2d:SetBorderRadius(15)
	shadow_panel.gui_element_2d:SetShadows(true)
	shadow_panel.gui_element_2d:SetShadowSize(20)
	shadow_panel.gui_element_2d:SetShadowOffset(Vec2(5, 5))
	shadow_panel.gui_element_2d:SetShadowColor(Color(0, 0, 0, 0.7))
	shadow_panel:AddComponent(mouse_input_2d):SetDragEnabled(true)
	local shadow_label = ecs.CreateEntity("shadow_label", shadow_panel)
	shadow_label:AddComponent(transform_2d)
	shadow_label.transform_2d:SetPosition(Vec2(20, 20))
	shadow_label.transform_2d:SetSize(Vec2(160, 40))
	local l_rect = shadow_label:AddComponent(rect_2d)
	l_rect:SetColor("#ffffff")
	shadow_label.gui_element_2d:SetBorderRadius(20)
	shadow_label.gui_element_2d:SetShadows(true)
	shadow_label.gui_element_2d:SetShadowSize(10)
	shadow_label.gui_element_2d:SetShadowOffset(Vec2(0, 2))
	local label = ecs.CreateEntity("label", shadow_label)
	local txt = label:AddComponent(text_2d)
	txt:SetText("Shadowy Text")
	txt:SetColor(Color(0.2, 0.2, 0.2, 1))
	label:AddComponent(layout_2d):CenterSimple()
end

do -- resizable panel
	local resizable_panel = ecs.CreateEntity("resizable_panel", ecs.Get2DWorld())
	resizable_panel:AddComponent(require("ecs.components.2d.gui_element"))
	resizable_panel:AddComponent(transform_2d)
	resizable_panel.transform_2d:SetPosition(Vec2(100, 450))
	resizable_panel.transform_2d:SetSize(Vec2(200, 150))
	local r_rect = resizable_panel:AddComponent(rect_2d)
	r_rect:SetColor(Color(0.1, 0.4, 0.1, 0.8))
	resizable_panel.gui_element_2d:SetBorderRadius(10)
	resizable_panel:AddComponent(layout_2d)
	local mouse = resizable_panel:AddComponent(mouse_input_2d)
	mouse:SetDragEnabled(true)
	local resizer = resizable_panel:AddComponent(resizable_2d)
	resizer:SetResizable(true)
	resizer:SetMinimumSize(Vec2(100, 100))
	local label = ecs.CreateEntity("label", resizable_panel)
	local txt = label:AddComponent(text_2d)
	txt:SetText("Resizable Panel")
	label:AddComponent(layout_2d):SetLayout({"CenterSimple"})
end
