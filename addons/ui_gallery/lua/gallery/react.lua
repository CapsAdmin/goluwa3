local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local TodoRow = react.Memo(
	react.Component(|props| -> ui.Row{layout = {ChildGap = "S", AlignmentY = "center"}}{
		ui.Checkbox{
			Text = props.Item.text,
			Value = props.Item.done,
			OnChange = |done| -> props.OnToggle(props.Item.id, done),
			layout = {GrowWidth = 1},
		},
		ui.Button{Text = "x", Mode = "outline", OnClick = || -> props.OnRemove(props.Item.id)},
	})
)

return {
	Name = "react",
	Section = "Containers",
	Order = 20,
	View = react.Component(|| -> do
		local items, set_items = react.UseState({
			{id = 1, text = "write a reconciler", done = true},
			{id = 2, text = "use it for the load window", done = false},
		})
		local draft, set_draft = react.UseState("")
		local next_id = react.UseRef(3)
		local input = react.UseRef()
		local remaining = react.UseMemo(|| -> #list.filter(items, |item| -> not item.done), {items})
		local toggle = react.UseCallback(
			|id, done| -> set_items(|current| -> list.map(current, |item| -> item.id == id and table.merge({}, item, {done = done}) or item)),
			{}
		)
		local remove = react.UseCallback(|id| -> set_items(|current| -> list.filter(current, |item| -> item.id ~= id)), {})

		return kit.Page{
			Title = "React",
			Description = "A small todo list written with components, state and keyed lists. This whole gallery is built the same way.",
		}{
			kit.Section{Title = "Todos", Description = remaining .. " left"}{
				ui.Row{layout = {ChildGap = "S", AlignmentY = "center"}}{
					ui.TextEdit{
						Ref = input,
						Hint = "new todo",
						Wrap = false,
						ScrollX = false,
						ScrollY = false,
						Size = Vec2(0, 28),
						MaxSize = Vec2(0, 28),
						OnTextChanged = |_, text| -> set_draft(text),
						layout = {GrowWidth = 1},
					},
					ui.Button{
						Text = "Add",
						Disabled = draft == "",
						OnClick = || -> do
							set_items(|current| -> do
								local next_items = list.copy(current)
								next_items[#next_items + 1] = {id = next_id.current, text = draft, done = false}

								return next_items
							end)
							next_id.current = next_id.current + 1
							input.current:SetText("")
							set_draft("")
						end,
					},
				},
				list.map(items, |item| -> TodoRow{Key = item.id, Item = item, OnToggle = toggle, OnRemove = remove}),
				#items == 0 && ui.Text{Key = "empty", Text = "nothing to do", Color = "text_disabled"},
			},
		}
	end),
}
