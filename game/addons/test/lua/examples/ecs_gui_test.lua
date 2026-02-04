local Text = require("ecs.entities.2d.text")
local Panel = require("ecs.entities.2d.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
require("ecs.panel").World:RemoveChildren()

do -- mouse input
	local pnl = Panel({Name = "my_button"})
	pnl.transform:SetPosition(Vec2(50, 50))
	pnl.transform:SetSize(Vec2(60, 20))
	pnl.rect:SetColor(Color(1, 0, 0, 1))
	pnl.mouse_input:SetCursor("hand")
	pnl.mouse_input:SetDragEnabled(true)
	pnl.mouse_input:SetFocusOnClick(true)
	local label = Text({Name = "label", Parent = pnl})
	label.text:SetText("Drag Me!")
	label.text:SetColor(Color(1, 1, 1, 1))
	label.mouse_input:SetIgnoreMouseInput(true)
	label.layout:CenterSimple()

	function pnl:OnHover(hovered)
		if hovered then
			self.animations:Animate(
				{
					id = "scale",
					base = self.transform:GetDrawScaleOffset(),
					get = function()
						return self.transform:GetDrawScaleOffset()
					end,
					set = function(v)
						self.transform:SetDrawScaleOffset(v)
					end,
					to = Vec2(1.5, 1.5),
					time = 0.1,
				}
			)
			self.animations:Animate(
				{
					id = "color",
					base = self.rect:GetDrawColor(),
					get = function()
						return self.rect:GetDrawColor()
					end,
					set = function(v)
						self.rect:SetDrawColor(v)
					end,
					to = Color(0, 1, 1, 0),
					time = 0.2,
				}
			)
		else
			self.animations:Animate(
				{
					id = "scale",
					base = self.transform:GetDrawScaleOffset(),
					get = function()
						return self.transform:GetDrawScaleOffset()
					end,
					set = function(v)
						self.transform:SetDrawScaleOffset(v)
					end,
					to = Vec2(1, 1),
					time = 0.1,
				}
			)
			self.animations:Animate(
				{
					id = "color",
					base = self.rect:GetDrawColor(),
					get = function()
						return self.rect:GetDrawColor()
					end,
					set = function(v)
						self.rect:SetDrawColor(v)
					end,
					to = Color(0, 0, 0, 0),
					time = 0.2,
				}
			)
		end
	end

	function pnl:OnFocus()
		print("Entity focused!")
		self.rect:SetColor(Color(0, 1, 0, 1))
	end

	function pnl:OnUnfocus()
		print("Entity unfocused!")
		self.rect:SetColor(Color(1, 0, 0, 1))
	end

	function pnl:OnMouseInput(button, press, pos)
		print("Button clicked!", button, press, pos)
	end

	function pnl:OnKeyInput(key, press)
		print("Key input!", key, press)
	end

	function pnl:OnCharInput(char)
		print("Char input!", char)
	end
end

do -- drag
	local parent = Panel({Name = "draggable_parent"})
	parent.transform:SetPosition(Vec2(200, 200))
	parent.transform:SetSize(Vec2(200, 200))
	parent.rect:SetColor(Color(0.2, 0.2, 0.2, 0.8))
	parent.mouse_input:SetDragEnabled(true)
	parent.mouse_input:SetBringToFrontOnClick(true)
	parent.mouse_input:SetFocusOnClick(true)
	parent.layout:SetPadding(Rect(10, 10, 10, 10))
	local child = Panel({Name = "child_button", Parent = parent})
	child.transform:SetPosition(Vec2(50, 50))
	child.transform:SetSize(Vec2(100, 30))
	child.rect:SetColor(Color(0, 0.5, 1, 1))
	child.mouse_input:SetCursor("ibeam")
	child.layout:SetLayout({"FillX", "CenterY"})

	function child:OnHover(hovered)
		if hovered then
			self.rect:SetColor(Color(0.2, 0.7, 1, 1))
		else
			self.rect:SetColor(Color(0, 0.5, 1, 1))
		end
	end
end

do -- scroll
	local scroll_panel = Panel({Name = "scroll_panel"})
	scroll_panel.transform:SetPosition(Vec2(500, 100))
	scroll_panel.transform:SetSize(Vec2(150, 150))
	scroll_panel.transform:SetScrollEnabled(true)
	scroll_panel.rect:SetColor(Color(0.1, 0.1, 0.1, 1))
	scroll_panel.gui_element:SetClipping(true)
	scroll_panel.gui_element:SetBorderRadius(10)
	scroll_panel.layout:SetStack(true)
	scroll_panel.layout:SetStackRight(false)
	scroll_panel.layout:SetPadding(Rect(5, 5, 5, 5))

	for i = 1, 10 do
		local item = Panel({Name = "scroll_item_" .. i, Parent = scroll_panel})
		item.transform:SetSize(Vec2(130, 30))
		item.rect:SetColor(Color(math.random(), math.random(), math.random(), 1))
		item.gui_element:SetBorderRadius(5)
		item.mouse_input:SetCursor("hand")
		item.layout:SetMargin(Rect(0, 0, 0, 5))
		local label = Text({Name = "label", Parent = item})
		label.text:SetText("Item #" .. i)
		label.layout:CenterSimple()
	end
end

do -- flex box (RGB)
	local flex_panel = Panel({Name = "flex_panel"})
	flex_panel.transform:SetPosition(Vec2(50, 200))
	flex_panel.transform:SetSize(Vec2(120, 200))
	flex_panel.rect:SetColor("#333333")
	flex_panel.layout:SetFlex(true)
	flex_panel.layout:SetFlexDirection("column")
	flex_panel.layout:SetFlexGap(10)
	flex_panel.layout:SetFlexJustifyContent("center")
	flex_panel.layout:SetPadding(Rect(10, 10, 10, 10))

	for i = 1, 3 do
		local item = Panel({Name = "flex_item_" .. i, Parent = flex_panel})
		item.transform:SetSize(Vec2(100, 30))
		item.rect:SetColor(i == 1 and "#ff0000" or (i == 2 and "#00ff00" or "#0000ff"))
		local label = Text({Name = "label", Parent = item})
		label.text:SetText(i == 1 and "Red" or (i == 2 and "Green" or "Blue"))
		label.layout:CenterSimple()
	end
end

do -- shadows
	local shadow_panel = Panel({Name = "shadow_panel"})
	shadow_panel.transform:SetPosition(Vec2(700, 100))
	shadow_panel.transform:SetSize(Vec2(200, 200))
	shadow_panel.rect:SetColor("#2d2d2d")
	shadow_panel.gui_element:SetBorderRadius(15)
	shadow_panel.gui_element:SetShadows(true)
	shadow_panel.gui_element:SetShadowSize(20)
	shadow_panel.gui_element:SetShadowOffset(Vec2(5, 5))
	shadow_panel.gui_element:SetShadowColor(Color(0, 0, 0, 0.7))
	shadow_panel.mouse_input:SetDragEnabled(true)
	local shadow_label = Panel({Name = "shadow_label", Parent = shadow_panel})
	shadow_label.transform:SetPosition(Vec2(20, 20))
	shadow_label.transform:SetSize(Vec2(160, 40))
	shadow_label.rect:SetColor("#ffffff")
	shadow_label.gui_element:SetBorderRadius(20)
	shadow_label.gui_element:SetShadows(true)
	shadow_label.gui_element:SetShadowSize(10)
	shadow_label.gui_element:SetShadowOffset(Vec2(0, 2))
	local label = Text({Name = "label", Parent = shadow_label})
	label.text:SetText("Shadowy Text")
	label.text:SetColor(Color(0.2, 0.2, 0.2, 1))
	label.layout:CenterSimple()
end

do -- resizable panel
	local resizable_panel = Panel({Name = "resizable_panel"})
	resizable_panel.transform:SetPosition(Vec2(100, 450))
	resizable_panel.transform:SetSize(Vec2(200, 150))
	resizable_panel.rect:SetColor(Color(0.1, 0.4, 0.1, 0.8))
	resizable_panel.gui_element:SetBorderRadius(10)
	resizable_panel.mouse_input:SetDragEnabled(true)
	resizable_panel.resizable:SetResizable(true)
	resizable_panel.resizable:SetMinimumSize(Vec2(100, 100))
	local label = Text({Name = "label", Parent = resizable_panel})
	label.text:SetText("Resizable Panel")
	label.layout:SetLayout({"CenterSimple"})
end
