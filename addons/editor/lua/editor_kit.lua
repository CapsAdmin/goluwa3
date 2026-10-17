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

-- a panel the viewer draws into and reads the mouse from, pass callbacks that keep their identity (UseCallback)
function kit.Canvas(props)
	return PanelElement{
		Name = props.Name,
		transform = true,
		layout = props.layout ?? {GrowWidth = 1, GrowHeight = 1},
		mouse_input = {Cursor = props.Cursor ?? "arrow"},
		visual = {OnDraw = props.OnDraw},
		OnMouseInput = props.OnMouseInput,
		OnMouseMove = props.OnMouseMove,
		Ref = props.Ref,
	}
end

function kit.InfoRow(props)
	return Row{layout = {Direction = "x", GrowWidth = 1, FitHeight = true, AlignmentY = "center", ChildGap = 4}}{
		Text{Text = props.Label, Font = "body XS", Color = "text_disabled", IgnoreMouseInput = true, layout = {FitWidth = true}},
		Text{Text = props.Value, Font = "body XS", IgnoreMouseInput = true, layout = {GrowWidth = 1}},
	}
end

do
	local open = {}

	-- one window per key, opening it again brings the one that is already there to the front and returns it
	function kit.OpenOnce(key, create)
		local existing = open[key]

		if existing and existing:IsValid() then
			existing:BringToFront()

			return existing
		end

		local window = create()
		open[key] = window
		return window
	end
end

return kit
