local Vec2 = import("goluwa/structs/vec2.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function on_text_changed(text_edit, text)
	text_edit.Readout.text:SetText(#text .. " characters")
end

return {
	Name = "text input",
	Section = "Controls",
	Order = 4,
	Create = function()
		local count = Text{Text = "0 characters", Color = "text_disabled", IgnoreMouseInput = true}
		return kit.Page{
			Title = "Text input",
			Description = "TextEdit wraps an editable Text inside a ScrollablePanel. Click to focus, Ctrl+A selects all.",
		}{
			kit.Section{
				Title = "Single line",
				Description = "Hint is shown while the field is empty. OnTextChanged(text_edit, text, old_text).",
			}{
				TextEdit{
					Hint = "type something",
					Readout = count,
					OnTextChanged = on_text_changed,
				},
				count,
			},
			kit.Section{
				Title = "Multiline",
				Description = "Wrap = true and ScrollY = true give a scrolling text area.",
			}{
				TextEdit{
					Text = "Edit this text.\n\nLines wrap at the field width and the field scrolls when the content grows.\n\nSecond paragraph.",
					Size = Vec2(0, 140),
					MinSize = Vec2(100, 140),
					MaxSize = Vec2(0, 140),
					Wrap = true,
					ScrollY = true,
				},
			},
			kit.Section{
				Title = "Auto resizing",
				Description = "AutoResize grows the field up to MaxLines as you type.",
			}{
				TextEdit{
					Hint = "press enter to add lines",
					Wrap = true,
					ScrollY = true,
					AutoResize = true,
					MaxLines = 5,
				},
			},
			kit.Section{
				Title = "Read only",
				Description = "Editable = false keeps selection and copy but blocks typing.",
			}{
				TextEdit{
					Text = "This text can be selected and copied but not edited.",
					Editable = false,
				},
			},
		}
	end,
}
