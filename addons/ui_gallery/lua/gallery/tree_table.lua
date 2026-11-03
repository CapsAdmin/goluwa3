local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local TABLE_HEIGHT = 300

local function format_bytes(bytes)
	if bytes < 1024 then return ("%d B"):format(bytes) end

	if bytes < 1024 * 1024 then return ("%.1f KB"):format(bytes / 1024) end

	return ("%.1f MB"):format(bytes / 1024 / 1024)
end

local function file(path, name, extension, size)
	return {Key = path .. name .. extension, Text = name .. extension, Size = size, Type = extension:sub(2)}
end

local function folder(path, name, children)
	return {
		Key = path .. name .. "/",
		Text = name,
		IsFolder = true,
		Children = children,
		Size = #children,
		Type = "folder",
	}
end

local function build_items()
	local items = {}
	local seed = 7

	local function random(low, high)
		seed = (seed * 1103515245 + 12345) % 2147483648

		return low + seed % (high - low + 1)
	end

	local function files(path, base, extension, count, low, high)
		local out = {}

		for index = 1, count do
			out[index] = file(path, base .. index, extension, random(low, high))
		end

		return out
	end

	local water = {folder("ambient/water/", "rain", files("ambient/water/rain/", "drop", ".wav", 5, 20000, 300000))}

	for _, stream in ipairs(files("ambient/water/", "stream", ".ogg", 4, 100000, 2500000)) do
		water[#water + 1] = stream
	end

	items[#items + 1] = folder("", "ambient", {
		folder("ambient/", "fire", files("ambient/fire/", "flame", ".wav", 9, 40000, 900000)),
		folder("ambient/", "water", water),
		file("ambient/", "wind", ".ogg", 1800000),
	})
	items[#items + 1] = folder("", "weapons", {
		folder("weapons/", "pistol", files("weapons/pistol/", "fire", ".wav", 6, 30000, 120000)),
		folder("weapons/", "rifle", files("weapons/rifle/", "burst", ".wav", 7, 60000, 400000)),
		file("weapons/", "reload", ".wav", 220000),
	})
	items[#items + 1] = folder("", "empty", {})
	items[#items + 1] = file("", "readme", ".txt", 1250)
	items[#items + 1] = file("", "intro", ".mp3", 4200000)
	items[#items + 1] = file("", "ping", ".wav", 18000)
	return items
end

local ITEMS = build_items()
local COLUMNS = {
	{Key = "Text", Text = "Name", Grow = true, MinWidth = 140},
	{
		Key = "Size",
		Text = "Size",
		Width = 110,
		Format = |value,node|->node.IsFolder and (value .. (value == 1 and " item" or " items")) or format_bytes(value),
	},
	{Key = "Type", Text = "Type", Width = 80},
}
return {
	Name = "tree table",
	Section = "Data",
	Order = 3,
	View = react.Component(
		||-> do
			local mode, set_mode = react.UseState("tree")
			local readout, set_readout = react.UseState("nothing happened yet")
			local frame = {MinSize = Vec2(0, TABLE_HEIGHT), MaxSize = Vec2(0, TABLE_HEIGHT), FitHeight = false}
			return kit.Page{
				Title = "Tree table",
				Description = "A details view for files and other records: sortable, resizable columns, in two modes. The hybrid tree mode expands folders inline, the list mode shows the rows it was given.",
			}{
				kit.Section{
					Title = "Modes",
					Description = "Mode is tree or list. Click a header to sort (twice to reverse), drag the border between headers to resize, arrow keys move and expand, enter and double click activate.",
				}{
					kit.Group{
						ui.Button{
							Key = "tree",
							Text = "Tree",
							Mode = "outline",
							Active = mode == "tree",
							OnClick = ||->set_mode("tree"),
						},
						ui.Button{
							Key = "list",
							Text = "List",
							Mode = "outline",
							Active = mode == "list",
							OnClick = ||->set_mode("list"),
						},
					},
					ui.TreeTable{
						Mode = mode,
						Items = mode == "tree" and ITEMS or ITEMS[1].Children,
						Columns = COLUMNS,
						OnSelect = |node|->set_readout("OnSelect " .. (node and node.Text or "nil")),
						OnActivate = |node|->set_readout("OnActivate " .. node.Text),
						OnToggle = |node,expanded|->set_readout((expanded and "expanded " or "collapsed ") .. node.Text),
						OnSort = |column,descending|->set_readout(
							"sorted by " .. column.Text .. (descending and " descending" or " ascending")
						),
						layout = frame,
					},
					ui.Text{Text = readout, Color = "text_disabled", IgnoreMouseInput = true},
				},
				kit.Section{
					Title = "Initial sort",
					Description = "SortKey and SortDescending set the order, FoldersFirst = false mixes folders in with the files.",
				}{
					ui.TreeTable{
						Mode = "list",
						Items = ITEMS,
						Columns = COLUMNS,
						SortKey = "Size",
						SortDescending = true,
						FoldersFirst = false,
						layout = frame,
					},
				},
			}
		end
	),
}
