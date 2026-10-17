local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local PanelElement = react.Element(Panel)
local kit = {}

-- the window of a viewer, centered where it opens and left where the user puts it
kit.ViewerWindow = react.Component(|props| -> do
	local position = react.UseMemo(|| -> (Panel.World.transform:GetSize() - props.Size) / 2, {})

	return Window{
		Title = props.Title,
		Size = props.Size,
		Padding = "none",
		Position = position,
		layout = props.layout,
		Ref = props.Ref,
	}{props.children}
end)

-- a panel the viewer draws into and reads the mouse from, pass callbacks that keep their identity (UseCallback), or Drag (react.UseDrag)
function kit.Canvas(props)
	return PanelElement{
		Name = props.Name,
		transform = true,
		layout = props.layout ?? {GrowWidth = 1, GrowHeight = 1},
		mouse_input = {Cursor = props.Cursor ?? "arrow"},
		visual = {OnDraw = props.OnDraw},
		OnMouseInput = props.Drag && props.Drag.OnMouseInput || props.OnMouseInput,
		OnGlobalMouseMove = props.Drag && props.Drag.OnGlobalMouseMove,
		OnGlobalMouseInput = props.Drag && props.Drag.OnGlobalMouseInput,
		OnMouseMove = props.OnMouseMove,
		Ref = props.Ref,
	}
end

-- the mouse of a preview with an orbit camera, view is {orbit, auto_rotate}: dragging rotates it and stops the spin, a click toggles the spin. Give the result to a Canvas as Drag
function kit.UseOrbitDrag(view)
	return react.UseDrag{
		OnDrag = |_, _, dx, dy, moved| -> do
			view.orbit:Rotate(dx, dy)

			if moved then view.auto_rotate = false end
		end,
		OnEnd = |moved| -> do
			if not moved then view.auto_rotate = not view.auto_rotate end
		end,
	}
end

function kit.InfoRow(props)
	return Row{layout = {Direction = "x", GrowWidth = 1, FitHeight = true, AlignmentY = "center", ChildGap = 4}}{
		Text{Text = props.Label, Font = "body XS", Color = "text_disabled", IgnoreMouseInput = true, layout = {FitWidth = true}},
		Text{Text = props.Value, Font = "body XS", IgnoreMouseInput = true, layout = {GrowWidth = 1}},
	}
end

return kit
