local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local ModelPreview = import("goluwa/render3d/model_preview.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local previews = import("lua/asset_preview.lua")
local PREVIEW_SIZE = 512
-- edits a copy of the material on a sphere, the material it was opened from is never changed
return function(source, title)
	local material = source:Copy()
	local orbit = OrbitCamera.New()
	local preview = ModelPreview.New{Width = PREVIEW_SIZE, Height = PREVIEW_SIZE, Padding = 1.1}
	local sphere = previews.GetMaterialSphere()
	local auto_rotate = true
	local ready = false
	local drag_x
	local drag_y
	local press_x
	local press_y
	local dragging = false
	local editor
	local window = Window{
		Title = title,
		Size = Vec2(1000, 680),
		Padding = "none",
		Position = Panel.World.transform:GetSize() / 2 - Vec2(1000, 680) / 2,
	}{
		Splitter{InitialSize = 400}{
			Column{
				layout = {
					GrowWidth = 1,
					GrowHeight = 1,
					FitHeight = false,
					AlignmentX = "stretch",
					ChildGap = 6,
					Padding = Rect() + theme.active:GetPadding("S"),
				},
			}{
				Row{layout = {GrowWidth = 1, AlignmentY = "center", ChildGap = 6}}{
					Text{
						Text = "PROPERTIES",
						Font = "heading XS",
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1},
					},
					Button{
						Text = "Reset",
						Icon = "refresh",
						Mode = "outline",
						Tooltip = "go back to the material this was opened from",
						OnClick = function()
							material = source:Copy()
							editor:SetObject(material)
							editor:ExpandAll()
						end,
					},
				},
				ScrollablePanel{
					ScrollX = false,
					ScrollY = true,
					layout = {GrowWidth = 1, GrowHeight = 1},
				}{
					PropertyEditor{
						Ref = function(self)
							editor = self
							self:SetObject(material)
							self:ExpandAll()
						end,
						layout = {GrowWidth = 1, FitWidth = false},
					},
				},
			},
			Panel.New{
				Name = "MaterialPreview",
				transform = true,
				layout = {GrowWidth = 1, GrowHeight = 1},
				mouse_input = {Cursor = "sizeall"},
				visual = {
					OnDraw = function(self)
						local size = self.Owner.transform:GetSize()
						render2d.SetTexture(nil)
						render2d.SetColor(0.2, 0.21, 0.24, 1)
						render2d.DrawRect(0, 0, size.x, size.y)

						if not ready then return end

						local side = math.min(size.x, size.y)
						preview:Draw((size.x - side) / 2, (size.y - side) / 2, side, side)
					end,
				},
				OnMouseInput = function(self, button, press)
					if button ~= "button_1" then return end

					if press then
						drag_x, drag_y = system.GetWindow():GetMousePosition():Unpack()
						press_x, press_y = drag_x, drag_y
						dragging = true
					else
						dragging = false
						local x, y = system.GetWindow():GetMousePosition():Unpack()

						if math.abs(x - press_x) + math.abs(y - press_y) < 3 then
							auto_rotate = not auto_rotate
						end
					end

					return true
				end,
			},
		},
	}
	window:AddGlobalEvent("Update")

	function window:OnUpdate(dt)
		if not ready then ready = previews.IsMaterialReady(material) end

		if not ready then return end

		if dragging then
			local x, y = system.GetWindow():GetMousePosition():Unpack()
			orbit:Rotate(x - drag_x, y - drag_y)
			drag_x, drag_y = x, y

			if math.abs(x - press_x) + math.abs(y - press_y) >= 3 then auto_rotate = false end
		end

		if auto_rotate then orbit:Rotate(-dt * 60, 0) end

		preview:SetViewOffset(orbit:GetViewOffset())
		local visual = sphere.visual
		visual:SetMaterialOverride(material)
		preview:SetTarget(visual)
		preview:Refresh()
		preview:SetTarget(nil)
		visual:SetMaterialOverride(nil)
	end

	window:CallOnRemove(
		function()
			preview:Remove()
		end,
		"material_viewer_cleanup"
	)
	return window
end
