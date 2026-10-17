local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Splitter = react.Element(import("goluwa/render2d/ui/elements/splitter.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local PropertyEditor = react.Element(import("goluwa/render2d/ui/widgets/property_editor.lua"))
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local ModelPreview = import("goluwa/render3d/model_preview.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local previews = import("lua/asset_preview.lua")
local kit = import("lua/editor_kit.lua")
local ViewerWindow = kit.ViewerWindow
local Canvas = kit.Canvas
local PREVIEW_SIZE = 512
local WINDOW_SIZE = Vec2(1000, 680)
-- edits a copy of the material on a sphere, the material it was opened from is never changed
local MaterialView = react.Component(|props| -> do
	local source = props.Source
	local material, set_material = react.UseState(|| -> source:Copy())
	local editor = react.UseRef()
	-- what the preview and the mouse change every frame lives here, none of it is a reason to render again, the preview goes with the window
	local view = react.UseResource(|| -> {
		orbit = OrbitCamera.New(),
		preview = ModelPreview.New{Width = PREVIEW_SIZE, Height = PREVIEW_SIZE, Padding = 1.1},
		sphere = previews.GetMaterialSphere(),
		auto_rotate = true,
		ready = false,
		dragging = false,
	}, |view| -> view.preview:Remove(), {})

	react.UseEffect(|| -> do
		editor.current:SetObject(material)
		editor.current:ExpandAll()
	end, {material})

	react.UseEvent("Update", |dt| -> do
		if not view.ready then view.ready = previews.IsMaterialReady(material) end

		if not view.ready then return end

		if view.dragging then
			local x, y = system.GetWindow():GetMousePosition():Unpack()
			view.orbit:Rotate(x - view.drag_x, y - view.drag_y)
			view.drag_x, view.drag_y = x, y

			if math.abs(x - view.press_x) + math.abs(y - view.press_y) >= 3 then
				view.auto_rotate = false
			end
		end

		if view.auto_rotate then view.orbit:Rotate(-dt * 60, 0) end

		view.preview:SetViewOffset(view.orbit:GetViewOffset())
		local visual = view.sphere.visual
		visual:SetMaterialOverride(material)
		view.preview:SetTarget(visual)
		view.preview:Refresh()
		view.preview:SetTarget(nil)
		visual:SetMaterialOverride(nil)
	end)

	local draw = react.UseCallback(|self| -> do
		local size = self.Owner.transform:GetSize()
		render2d.SetTexture(nil)
		render2d.SetColor(0.2, 0.21, 0.24, 1)
		render2d.DrawRect(0, 0, size.x, size.y)

		if not view.ready then return end

		local side = math.min(size.x, size.y)
		view.preview:Draw((size.x - side) / 2, (size.y - side) / 2, side, side)
	end, {})
	local on_mouse_input = react.UseCallback(|self, button, press| -> do
		if button ~= "button_1" then return end

		if press then
			view.drag_x, view.drag_y = system.GetWindow():GetMousePosition():Unpack()
			view.press_x, view.press_y = view.drag_x, view.drag_y
			view.dragging = true
		else
			view.dragging = false
			local x, y = system.GetWindow():GetMousePosition():Unpack()

			if math.abs(x - view.press_x) + math.abs(y - view.press_y) < 3 then
				view.auto_rotate = not view.auto_rotate
			end
		end

		return true
	end, {})

	return ViewerWindow{Title = props.Title, Size = WINDOW_SIZE}{
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
						OnClick = || -> set_material(source:Copy()),
					},
				},
				ScrollablePanel{ScrollX = false, ScrollY = true, layout = {GrowWidth = 1, GrowHeight = 1}}{
					PropertyEditor{Ref = editor, layout = {GrowWidth = 1, FitWidth = false}},
				},
			},
			Canvas{Name = "MaterialPreview", Cursor = "sizeall", OnDraw = draw, OnMouseInput = on_mouse_input},
		},
	}
end)

return function(source, title)
	return react.Mount(MaterialView{Source = source, Title = title}, Panel.World):GetEntity()
end
