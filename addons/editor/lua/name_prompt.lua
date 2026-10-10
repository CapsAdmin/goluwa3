local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local SIZE = Vec2(360, 160)
return function(props)
	local window
	local edit
	local error_text

	local function submit()
		local name = edit:GetText():match("^%s*(.-)%s*$")

		if name == "" then return end

		local err = props.Validate and props.Validate(name)

		if err then
			error_text.text:SetText(err)
			return
		end

		window:Remove()
		props.OnSubmit(name)
	end

	window = Panel.World:Ensure(
		Window{
			Key = "NamePrompt",
			Title = props.Title,
			Size = SIZE,
			Position = (Panel.World.transform:GetSize() - SIZE) / 2,
			Padding = "S",
			layout = {
				FitHeight = false,
				FitWidth = false,
			},
		}{
			Column{
				layout = {
					Direction = "y",
					GrowWidth = 1,
					ChildGap = "S",
					AlignmentX = "stretch",
				},
			}{
				TextEdit{
					Ref = function(self)
						edit = self
					end,
					Text = props.Text or "",
					Hint = props.Hint or "name",
					Size = Vec2(0, 28),
					MinSize = Vec2(100, 28),
					MaxSize = Vec2(0, 28),
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					OnKeyInput = function(_, key, press)
						if press and key == "enter" then
							submit()
							return true
						end
					end,
					OnTextChanged = function()
						error_text.text:SetText("")
					end,
					layout = {
						GrowWidth = 1,
					},
				},
				Text{
					Ref = function(self)
						error_text = self
					end,
					Text = "",
					Color = "negative",
					Wrap = true,
					layout = {GrowWidth = 1},
				},
				Row{}{
					Button{Text = "OK", OnClick = submit},
					Button{
						Text = "Cancel",
						OnClick = function()
							window:Remove()
						end,
					},
				},
			},
		}
	)
	edit:RequestTextFocus()
	return window
end
