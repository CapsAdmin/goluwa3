local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local SIZE = Vec2(360, 160)
local NamePrompt = react.Component(
	|props|-> do
		local edit = react.UseRef()
		local error_text, set_error_text = react.UseState("")
		local position = react.UseMemo(||->(Panel.World.transform:GetSize() - SIZE) / 2, {})
		react.UseEffect(||->edit.current:RequestTextFocus(), {})

		local function submit()
			local name = edit.current:GetText():match("^%s*(.-)%s*$")

			if name == "" then return end

			local err = props.Validate and props.Validate(name)

			if err then
				set_error_text(err)
				return
			end

			props.Close()
			props.OnSubmit(name)
		end

		return Window{
			Title = props.Title,
			Size = SIZE,
			Position = position,
			Padding = "S",
			layout = {FitHeight = false, FitWidth = false},
		}{
			Column{
				layout = {Direction = "y", GrowWidth = 1, ChildGap = "S", AlignmentX = "stretch"},
			}{
				TextEdit{
					Ref = edit,
					Text = props.Text ?? "",
					Hint = props.Hint ?? "name",
					Size = Vec2(0, 28),
					MinSize = Vec2(100, 28),
					MaxSize = Vec2(0, 28),
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					OnKeyInput = |_,key,press|-> do
						if press and key == "enter" then
							submit()
							return true
						end
					end,
					OnTextChanged = ||->set_error_text(""),
					layout = {GrowWidth = 1},
				},
				Text{Text = error_text, Color = "negative", Wrap = true, layout = {GrowWidth = 1}},
				Row{}{
					Button{Text = "OK", OnClick = submit},
					Button{Text = "Cancel", OnClick = props.Close},
				},
			},
		}
	end
)
return function(props)
	return react.OpenWindow(
		"NamePrompt",
		NamePrompt,
		{
			Title = props.Title,
			Text = props.Text,
			Hint = props.Hint,
			Validate = props.Validate,
			OnSubmit = props.OnSubmit,
		}
	)
end
