local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local Checkbox = react.Element(import("goluwa/render2d/ui/elements/checkbox.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local BASE_SIZE = Vec2(360, 160)
local OPTION_HEIGHT = 28
local NamePrompt = react.Component(
	|props|-> do
		local edit = react.UseRef()
		local error_text, set_error_text = react.UseState("")
		local option_definitions = props.Options ?? {}
		local size = BASE_SIZE + Vec2(0, OPTION_HEIGHT * #option_definitions)
		local position = react.UseMemo(||->(Panel.World.transform:GetSize() - size) / 2, {})
		local options = react.UseMemo(
			||-> do
				local values = {}

				for _, option in ipairs(option_definitions) do
					values[option.Key] = option.Value ?? false
				end

				return values
			end,
			{}
		)
		react.UseEffect(
			||-> do
				edit.current:RequestTextFocus()
				edit.current:SelectAll()
			end,
			{}
		)

		local function submit()
			local name = edit.current:GetText():match("^%s*(.-)%s*$")

			if name == "" then return end

			local err = props.Validate and props.Validate(name)

			if err then
				set_error_text(err)
				return
			end

			props.Close()
			props.OnSubmit(name, options)
		end

		return Window{
			Title = props.Title,
			Size = size,
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
				list.map(
					option_definitions,
					|option|->Checkbox{
						Key = option.Key,
						Text = option.Text,
						Value = options[option.Key],
						OnChange = |value|-> do
							options[option.Key] = value
						end,
					}
				),
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
			Options = props.Options,
			OnSubmit = props.OnSubmit,
		}
	)
end
