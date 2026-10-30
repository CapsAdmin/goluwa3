local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local INITIAL = {
	{Name = "position", Color = "primary", Keys = {{Time = 0.1}, {Time = 0.45, Label = "ease out"}, {Time = 0.9}}},
	{Name = "rotation", Color = "positive", Keys = {{Time = 0.25, Until = 0.5}, {Time = 0.75}}},
	{Name = "events", Color = "negative", Round = true, Keys = {{Time = 0.6, Label = "hit"}}},
}

local function copy_rows(rows)
	local copy = {}

	for i, row in ipairs(rows) do
		copy[i] = table.shallow_copy(row)
		copy[i].Keys = {}

		for j, key in ipairs(row.Keys) do
			copy[i].Keys[j] = table.shallow_copy(key)
		end
	end

	return copy
end

return {
	Name = "timeline",
	Section = "Controls",
	Order = 20,
	View = react.Component(
		||-> do
			local rows, set_rows = react.UseState(INITIAL)
			local time, set_time = react.UseState(0.3)
			local selection, set_selection = react.UseState(nil)
			return kit.Page{
				Title = "Timeline",
				Description = "Rows of keys on a shared time axis. Click or drag the ruler to scrub, drag a key to move it, double click a row to add one, wheel zooms, middle drag pans.",
			}{
				kit.Section{Title = "Keys and events"}{
					ui.Timeline{
						Rows = rows,
						Time = time,
						Selection = selection,
						OnScrub = set_time,
						OnSelect = |row, index|->set_selection(row and {row, index}),
						OnKeyMove = |row, index, t|-> do
							local copy = copy_rows(rows)
							copy[row].Keys[index].Time = t
							set_rows(copy)
						end,
						OnKeyAdd = |row, t|-> do
							local copy = copy_rows(rows)
							table.insert(copy[row].Keys, {Time = t})
							table.sort(copy[row].Keys, |a, b|->a.Time < b.Time)
							set_rows(copy)
						end,
						layout = {GrowWidth = 1, GrowHeight = 0, MinSize = Vec2(400, 130), MaxSize = Vec2(2000, 130)},
					},
					ui.Text{
						Text = string.format("time = %.3f", time),
						Color = "text_disabled",
						IgnoreMouseInput = true,
					},
				},
			}
		end
	),
}
