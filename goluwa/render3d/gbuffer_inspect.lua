local gbuffer_inspect = {}
gbuffer_inspect.SHEET = 1
gbuffer_inspect.FIELD = 2
gbuffer_inspect.TARGET = 3
gbuffer_inspect.TARGETS = 4
-- which channels of a raw target are shown, the index is the channel mode of the shader
gbuffer_inspect.CHANNELS = {"rgb", "r", "g", "b", "a"}
-- the gbuffer can be written differently while it is inspected: the normal from the vertices or from the normal map
-- instead of the combined one the lighting uses, and a terrain with its layers left out (the base color only)
gbuffer_inspect.NORMAL_SOURCES = {"combined", "vertex", "map"}
local normal_source = "combined"
local terrain_only = false
local view
local preview
local entries
local sheets

-- what the gbuffer holds per pixel, decoded: every field of the layout and the fixed targets. glsl is a vec3 expression
-- of `pixel` (an ivec2), GBUFFER. is the block the shader reads the targets from
function gbuffer_inspect.GetEntries()
	if entries then return entries end

	local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
	entries = {
		{name = "albedo", sheet = "albedo", glsl = "gbuffer_albedo(pixel)"},
		{name = "alpha", sheet = "alpha", glsl = "vec3(gbuffer_alpha(pixel))"},
	}

	for _, field in ipairs(gbuffer_layout.fields) do
		local accessor = "gbuffer_" .. (field.accessor or field.name)
		local glsl = field.kind == "octa" and
			(accessor .. "(pixel) * 0.5 + 0.5") or
			string.format("vec3(%s(pixel) / %.6f)", accessor, field.max or 1)
		entries[#entries + 1] = {name = field.name, sheet = field.sheet or field.name, glsl = glsl, field = field}
	end

	entries[#entries + 1] = {name = "emissive", sheet = "emissive", glsl = "1.0 - exp(-gbuffer_emissive(pixel) / 16.0)"}
	entries[#entries + 1] = {
		name = "depth",
		sheet = "depth",
		glsl = "vec3(1.0 - exp(-gbuffer_view_distance(pixel) / 40.0))",
	}
	entries[#entries + 1] = {
		name = "velocity",
		sheet = "velocity",
		glsl = "vec3(abs(gbuffer_fetch_nearest(GBUFFER.velocity_tex, pixel).rg) * 200.0, 0.0)",
	}

	for i, entry in ipairs(entries) do
		entry.index = i - 1
	end

	return entries
end

-- the entries grouped in sheets, in the order of their first entry: {name, primary = the entry that stands for the sheet,
-- entries}. a sheet is a field's `sheet` (its own name by default), so clearcoat has its roughness, rain and normal
function gbuffer_inspect.GetSheets()
	if sheets then return sheets end

	sheets = {}
	local by_name = {}

	for _, entry in ipairs(gbuffer_inspect.GetEntries()) do
		local sheet = by_name[entry.sheet]

		if not sheet then
			sheet = {name = entry.sheet, entries = {}}
			by_name[entry.sheet] = sheet
			sheets[#sheets + 1] = sheet
		end

		sheet.entries[#sheet.entries + 1] = entry
	end

	for _, sheet in ipairs(sheets) do
		sheet.primary = sheet.entries[1]

		for _, entry in ipairs(sheet.entries) do
			if entry.name == sheet.name then sheet.primary = entry end
		end
	end

	return sheets
end

function gbuffer_inspect.GetEntry(name)
	for _, entry in ipairs(gbuffer_inspect.GetEntries()) do
		if entry.name == name then return entry end
	end

	error("no gbuffer entry " .. tostring(name), 2)
end

-- nil for the normal image, or one of
-- {mode = "sheet", names = {entry names}}: the entries in a grid, in the order of the entries (all of them without names)
-- {mode = "targets"}: every raw packed target in a grid
-- {mode = "field", name = entry name}: one entry full screen
-- {mode = "target", target = target texture name, channel = one of CHANNELS}: a raw packed target
-- the view replaces the image on screen, the preview is only rendered, for a window to draw (the view wins)
function gbuffer_inspect.SetView(new_view)
	view = new_view
end

function gbuffer_inspect.GetView()
	return view
end

function gbuffer_inspect.SetPreview(new_view)
	preview = new_view
end

function gbuffer_inspect.GetPreview()
	return preview
end

function gbuffer_inspect.SetNormalSource(source)
	assert(table.has_value(gbuffer_inspect.NORMAL_SOURCES, source), "no normal source " .. tostring(source))
	normal_source = source
end

function gbuffer_inspect.GetNormalSource()
	return normal_source
end

function gbuffer_inspect.SetTerrainOnly(enabled)
	terrain_only = enabled
end

function gbuffer_inspect.GetTerrainOnly()
	return terrain_only
end

-- what the gbuffer pass writes, only while something is inspected: 0 the combined normal, 1 the vertex normal, 2 the map normal
function gbuffer_inspect.GetNormalSourceIndex()
	if not (view or preview) then return 0 end

	return normal_source == "vertex" and 1 or normal_source == "map" and 2 or 0
end

function gbuffer_inspect.IsTerrainOnly()
	return terrain_only and (view ~= nil or preview ~= nil)
end

-- the pass renders when there is a view or a preview
function gbuffer_inspect.IsActive()
	return view ~= nil or preview ~= nil
end

function gbuffer_inspect.IsFullScreen()
	return view ~= nil
end

local function get_rendered()
	return view or preview
end

-- the entries a sheet view draws, in the order of the grid
function gbuffer_inspect.GetSheetEntries(names)
	local list = {}

	for _, entry in ipairs(gbuffer_inspect.GetEntries()) do
		if not names or table.has_value(names, entry.name) then list[#list + 1] = entry end
	end

	return list
end

-- which entries a sheet draws as two bit masks of the entry indices, and how many tiles the grid has
function gbuffer_inspect.GetTileMask()
	local rendered = get_rendered()

	if not rendered then return 0, 0, 0 end

	if rendered.mode == "targets" then
		return 0, 0, #import("goluwa/render3d/gbuffer_layout.lua").targets
	end

	local low, high, count = 0, 0, 0

	for _, entry in ipairs(gbuffer_inspect.GetSheetEntries(rendered.names)) do
		if entry.index < 32 then
			low = bit.bor(low, bit.lshift(1, entry.index))
		else
			high = bit.bor(high, bit.lshift(1, entry.index - 32))
		end

		count = count + 1
	end

	return low, high, count
end

function gbuffer_inspect.GetMode()
	local rendered = get_rendered()

	if not rendered then return 0 end

	return gbuffer_inspect[rendered.mode:upper()]
end

function gbuffer_inspect.GetEntryIndex()
	local rendered = get_rendered()
	return rendered and rendered.mode == "field" and gbuffer_inspect.GetEntry(rendered.name).index or 0
end

function gbuffer_inspect.GetTargetIndex()
	local rendered = get_rendered()

	if not (rendered and rendered.mode == "target") then return 0 end

	local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")

	for i, target in ipairs(gbuffer_layout.targets) do
		if target.texture == rendered.target then return i - 1 end
	end

	error("no gbuffer target " .. tostring(rendered.target), 2)
end

function gbuffer_inspect.GetChannelIndex()
	local rendered = get_rendered()

	if not (rendered and rendered.mode == "target") then return 0 end

	for i, channel in ipairs(gbuffer_inspect.CHANNELS) do
		if channel == (rendered.channel or "rgb") then return i - 1 end
	end

	error("no channel " .. tostring(rendered.channel), 2)
end

return gbuffer_inspect
