local debug_draw = library()
import.loaded["goluwa/render3d/debug_draw.lua"] = debug_draw
_G.debug_draw = debug_draw
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render = import("goluwa/render/render.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local identity_rotation = Quat(0, 0, 0, 1)
local zero_vec = Vec3(0, 0, 0)
local overlay_font = fonts.New{Weight = "Regular", Size = 12}
local unit_box_poly
local unit_sphere_poly
local convex_mesh_cache = setmetatable({}, {__mode = "k"})
local polyhedron_mesh_cache = setmetatable({}, {__mode = "k"})
local material_cache = {}
local entries = {}
local shape_colors = {
	sphere = Color(0.25, 0.85, 1.0, 0.35),
	box = Color(1.0, 0.7, 0.2, 0.35),
	convex = Color(0.35, 1.0, 0.45, 0.35),
	compound = Color(1.0, 0.3, 0.9, 0.25),
	mesh = Color(0.9, 0.5, 0.25, 0.35),
	generic = Color(1.0, 0.25, 0.25, 0.35),
}

local function clone_vec3(vec, fallback)
	if vec and vec.Copy then return vec:Copy() end

	fallback = fallback or zero_vec
	return fallback:Copy()
end

local function clone_color(color, fallback)
	if color and color.Copy then return color:Copy() end

	color = color or fallback or Color(1, 1, 1, 1)

	if color.r then return Color(color.r, color.g, color.b, color.a or 1) end

	if color[1] then
		return Color(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
	end

	return Color(1, 1, 1, 1)
end

local function unpack_color(color, fallback)
	color = clone_color(color, fallback)
	return color.r, color.g, color.b, color.a or 1
end

local function get_vec2_xy(vec, fallback_x, fallback_y)
	if vec == nil then return fallback_x or 0, fallback_y or 0 end

	if vec.x ~= nil then return vec.x, vec.y end

	return vec[1] or fallback_x or 0, vec[2] or fallback_y or 0
end

local function get_vec3_xyz(vec, fallback_x, fallback_y, fallback_z)
	if vec == nil then return fallback_x or 0, fallback_y or 0, fallback_z or 0 end

	if vec.x ~= nil then return vec.x, vec.y, vec.z end

	return vec[1] or fallback_x or 0,
	vec[2] or fallback_y or 0,
	vec[3] or fallback_z or 0
end

local function get_default_id(level)
	local info = debug.getinfo(level or 3, "Sl") or {}
	return tostring(info.source or "?") .. ":" .. tostring(info.currentline or 0)
end

local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(max_value, value))
end

local function measure_lines(font, lines)
	local width = 0
	local height = 0

	for _, line in ipairs(lines) do
		local line_width, line_height = font:GetTextSize(tostring(line))
		width = math.max(width, line_width)
		height = height + line_height
	end

	return width, height
end

local function prune_entries(now)
	now = now or system.GetElapsedTime()

	for id, entry in pairs(entries) do
		if entry.expires_at and entry.expires_at <= now then entries[id] = nil end
	end
end

local function get_drawable(entry)
	if entry.kind == "sphere" then return debug_draw.GetUnitSpherePolygon() end

	if entry.kind == "box" then return debug_draw.GetUnitBoxPolygon() end

	if entry.kind == "mesh" then return entry.drawable end

	return nil
end

local function draw_drawable(cmd, drawable)
	if not drawable then return end

	if drawable.Draw then
		drawable:Draw(cmd)
		return
	end

	if drawable.Bind then
		drawable:Bind(cmd)

		if drawable.index_buffer then
			drawable:DrawIndexed(cmd)
		else
			drawable:Draw(cmd)
		end
	end
end

local function get_entry_matrix(entry)
	if entry.matrix then return entry.matrix end

	if entry.kind == "sphere" then
		local radius = entry.radius or 1
		local scale = Vec3(radius, radius, radius)
		return debug_draw.MakeMatrix(entry.position or zero_vec, entry.rotation or identity_rotation, scale)
	end

	local scale = entry.size or entry.scale or Vec3(1, 1, 1)
	return debug_draw.MakeMatrix(entry.position or zero_vec, entry.rotation or identity_rotation, scale)
end

local function draw_shape_entry(entry, cmd)
	if entry.kind == "text" or entry.kind == "line" then return false end

	local drawable = get_drawable(entry)

	if not drawable then return false end

	local material = debug_draw.GetMaterial{
		shape_type = entry.shape_type or entry.kind,
		color = entry.color,
		ignore_z = entry.ignore_z,
		translucent = entry.translucent,
		double_sided = entry.double_sided,
		emissive = entry.emissive,
	}
	render3d.SetWorldMatrix(get_entry_matrix(entry))
	render3d.SetMaterial(material)
	render3d.UploadForwardOverlayConstants()
	draw_drawable(cmd or render.GetCommandBuffer(), drawable)
	return true
end

local function draw_shape_entries()
	local cmd = render.GetCommandBuffer()
	prune_entries()

	for _, entry in pairs(entries) do
		draw_shape_entry(entry, cmd)
	end
end

local function draw_text_entry(entry)
	local screen_pos = debug_draw.ProjectWorldPosition(entry.position)

	if not screen_pos then return end

	local offset_x, offset_y = get_vec2_xy(entry.offset, 0, 0)
	debug_draw.DrawTextBlock(
		entry.lines,
		screen_pos.x + offset_x,
		screen_pos.y + offset_y,
		{
			padding = entry.padding,
			line_gap = entry.line_gap,
			background_alpha = entry.background_alpha,
			title_color = entry.title_color,
			text_color = entry.text_color,
		}
	)
end

local function draw_line_entry(entry)
	local from = debug_draw.ProjectWorldPosition(entry.from)
	local to = debug_draw.ProjectWorldPosition(entry.to)

	if not (from and to) then return end

	render2d.SetTexture(nil)
	render2d.SetColor(unpack_color(entry.color, Color(1, 0.5, 0.2, 1)))
	gfx.DrawLine(from.x, from.y, to.x, to.y, entry.line_width or 1, entry.smooth ~= false)
end

local function draw_2d_entries()
	prune_entries()

	for _, entry in pairs(entries) do
		if entry.kind == "text" then
			draw_text_entry(entry)
		elseif entry.kind == "line" then
			draw_line_entry(entry)
		end
	end
end

local function upsert_entry(kind, options, call_depth)
	options = options or {}
	local id = options.id or get_default_id(call_depth or 4)
	local now = system.GetElapsedTime()
	local lifetime = options.time

	if lifetime == nil then lifetime = 1 end

	local entry = {
		id = id,
		kind = kind,
		expires_at = now + math.max(lifetime, 0.0001),
	}
	entries[id] = entry
	return entry
end

local function get_wire_box_corners_from_min_max(min_vec, max_vec)
	local min_x, min_y, min_z = get_vec3_xyz(min_vec)
	local max_x, max_y, max_z = get_vec3_xyz(max_vec)
	return {
		Vec3(min_x, min_y, min_z),
		Vec3(max_x, min_y, min_z),
		Vec3(max_x, max_y, min_z),
		Vec3(min_x, max_y, min_z),
		Vec3(min_x, min_y, max_z),
		Vec3(max_x, min_y, max_z),
		Vec3(max_x, max_y, max_z),
		Vec3(min_x, max_y, max_z),
	}
end

local function get_wire_box_corners_from_aabb(aabb)
	if not aabb then return nil end

	return get_wire_box_corners_from_min_max(
		Vec3(aabb.min_x, aabb.min_y, aabb.min_z),
		Vec3(aabb.max_x, aabb.max_y, aabb.max_z)
	)
end

local wire_box_edges = {
	{1, 2},
	{2, 3},
	{3, 4},
	{4, 1},
	{5, 6},
	{6, 7},
	{7, 8},
	{8, 5},
	{1, 5},
	{2, 6},
	{3, 7},
	{4, 8},
}

function debug_draw.GetShapeColor(shape_type)
	return clone_color(shape_colors[shape_type] or shape_colors.generic)
end

function debug_draw.GetMaterial(options)
	options = options or {}
	local shape_type = options.shape_type or "generic"
	local color = clone_color(options.color, debug_draw.GetShapeColor(shape_type))
	local emissive = clone_color(options.emissive, Color(0.15, 0.15, 0.15, 1.0))
	local ignore_z = options.ignore_z

	if ignore_z == nil then ignore_z = true end

	local double_sided = options.double_sided

	if double_sided == nil then double_sided = true end

	local translucent = options.translucent

	if translucent == nil then translucent = true end

	local key = table.concat(
		{
			shape_type,
			string.format("%.4f", color.r),
			string.format("%.4f", color.g),
			string.format("%.4f", color.b),
			string.format("%.4f", color.a or 1),
			string.format("%.4f", emissive.r),
			string.format("%.4f", emissive.g),
			string.format("%.4f", emissive.b),
			string.format("%.4f", emissive.a or 1),
			ignore_z and
			"1" or
			"0",
			double_sided and
			"1" or
			"0",
			translucent and
			"1" or
			"0",
		},
		"|"
	)
	local material = material_cache[key]

	if material then return material end

	material = Material.New{
		AlbedoTexture = nil,
		ColorMultiplier = color,
		EmissiveMultiplier = emissive,
		AlbedoAlphaIsEmissive = true,
		IgnoreZ = ignore_z,
		Translucent = translucent,
		DoubleSided = double_sided,
		MetallicMultiplier = 0,
		RoughnessMultiplier = 1,
	}
	material_cache[key] = material
	return material
end

function debug_draw.MakeMatrix(position, rotation, scale)
	local m = Matrix44():Identity()
	m:SetRotation(rotation or identity_rotation)

	if scale then m:Scale(scale.x, scale.y, scale.z) end

	position = position or zero_vec
	m:SetTranslation(position.x, position.y, position.z)
	return m
end

function debug_draw.GetUnitBoxPolygon()
	if unit_box_poly then return unit_box_poly end

	local poly = Polygon3D.New()
	poly:CreateCube(0.5)
	poly:Upload()
	unit_box_poly = poly
	return unit_box_poly
end

function debug_draw.GetUnitSpherePolygon()
	if unit_sphere_poly then return unit_sphere_poly end

	local poly = Polygon3D.New()
	poly:CreateSphere(1, 18, 10)
	poly:Upload()
	unit_sphere_poly = poly
	return unit_sphere_poly
end

function debug_draw.BuildConvexPolygon(hull)
	if not (hull and hull.vertices and hull.indices and hull.indices[1]) then
		return nil
	end

	local cached = convex_mesh_cache[hull]

	if cached then return cached end

	local poly = Polygon3D.New()

	for i = 1, #hull.indices, 3 do
		local a = hull.vertices[hull.indices[i]]
		local b = hull.vertices[hull.indices[i + 1]]
		local c = hull.vertices[hull.indices[i + 2]]

		if a and b and c then
			local normal = (b - a):GetCross(c - a):GetNormalized()
			poly:AddVertex{pos = a, uv = Vec2(0, 0), normal = normal}
			poly:AddVertex{pos = b, uv = Vec2(1, 0), normal = normal}
			poly:AddVertex{pos = c, uv = Vec2(0.5, 1), normal = normal}
		end
	end

	poly:Upload()
	convex_mesh_cache[hull] = poly
	return poly
end

function debug_draw.BuildPolyhedronPolygon(polyhedron_data)
	if
		not (
			polyhedron_data and
			polyhedron_data.vertices and
			polyhedron_data.faces and
			polyhedron_data.faces[1]
		)
	then
		return nil
	end

	local cached = polyhedron_mesh_cache[polyhedron_data]

	if cached then return cached end

	local poly = Polygon3D.New()

	for _, face in ipairs(polyhedron_data.faces or {}) do
		local indices = face.indices or {}
		local a = indices[1]

		for i = 2, #indices - 1 do
			local b = indices[i]
			local c = indices[i + 1]
			local va = polyhedron_data.vertices[a]
			local vb = polyhedron_data.vertices[b]
			local vc = polyhedron_data.vertices[c]

			if va and vb and vc then
				local normal = face.normal or (vb - va):GetCross(vc - va):GetNormalized()
				poly:AddVertex{pos = va, uv = Vec2(0, 0), normal = normal}
				poly:AddVertex{pos = vb, uv = Vec2(1, 0), normal = normal}
				poly:AddVertex{pos = vc, uv = Vec2(0.5, 1), normal = normal}
			end
		end
	end

	poly:Upload()
	polyhedron_mesh_cache[polyhedron_data] = poly
	return poly
end

function debug_draw.ProjectWorldPosition(position)
	local cam = render3d.GetCamera()

	if not cam then return nil, 1 end

	local screen_pos, visibility = cam:WorldPositionToScreen(position, render2d.GetSize())

	if visibility ~= -1 then return nil, visibility end

	return screen_pos, visibility
end

function debug_draw.DrawTextBlock(lines, x, y, options)
	options = options or {}
	fonts.SetFont(overlay_font)
	render2d.SetTexture(nil)
	local font = fonts.GetFont()
	local padding = options.padding or 8
	local line_gap = options.line_gap or 2
	local width, raw_height = measure_lines(font, lines)
	local line_count = math.max(#lines - 1, 0)
	local height = raw_height + line_gap * line_count
	local screen_width, screen_height = render2d.GetSize()
	x = clamp(x, 8, math.max(8, screen_width - width - padding * 2 - 8))
	y = clamp(y, 8, math.max(8, screen_height - height - padding * 2 - 8))
	render2d.SetColor(0, 0, 0, options.background_alpha or 0.72)
	render2d.DrawRect(x - padding, y - padding, width + padding * 2, height + padding * 2)

	for i, line in ipairs(lines) do
		local _, line_height = font:GetTextSize(tostring(line))

		if i == 1 and options.title_color then
			render2d.SetColor(unpack_color(options.title_color, Color(1, 1, 1, 1)))
		elseif options.text_color then
			render2d.SetColor(unpack_color(options.text_color, Color(1, 1, 1, 1)))
		else
			render2d.SetColor(1, 1, 1, 1)
		end

		font:DrawText(tostring(line), x, y)
		y = y + line_height + line_gap
	end

	return width, height
end

function debug_draw.Remove(id)
	entries[id] = nil
end

function debug_draw.Clear()
	for id in pairs(entries) do
		entries[id] = nil
	end
end

function debug_draw.DrawText(options)
	local entry = upsert_entry("text", options, 4)
	entry.position = clone_vec3(options.position or options.pos)
	entry.lines = options.lines or {options.text or ""}

	if type(entry.lines) == "string" then entry.lines = {entry.lines} end

	entry.offset = options.offset and Vec2(get_vec2_xy(options.offset)) or Vec2(0, 0)
	entry.padding = options.padding
	entry.line_gap = options.line_gap
	entry.background_alpha = options.background_alpha
	entry.title_color = options.title_color or options.color
	entry.text_color = options.text_color or options.color
	return entry.id
end

function debug_draw.DrawLine(options)
	local entry = upsert_entry("line", options, 4)
	entry.from = clone_vec3(options.from or options.start)
	entry.to = clone_vec3(options.to or options.stop)
	entry.color = clone_color(options.color, Color(1.0, 0.75, 0.28, 0.95))
	entry.line_width = options.line_width or options.width or 1
	entry.smooth = options.smooth
	return entry.id
end

function debug_draw.DrawWireBox(options)
	options = options or {}
	local corners = nil

	if options.aabb then
		corners = get_wire_box_corners_from_aabb(options.aabb)
	elseif options.min or options.max then
		corners = get_wire_box_corners_from_min_max(options.min or zero_vec, options.max or zero_vec)
	else
		local position = clone_vec3(options.position or options.pos)
		local half = clone_vec3(options.size or options.scale or Vec3(1, 1, 1), Vec3(1, 1, 1)) * 0.5
		corners = get_wire_box_corners_from_min_max(position - half, position + half)
	end

	local id = options.id or get_default_id(3)

	for i, edge in ipairs(wire_box_edges) do
		debug_draw.DrawLine{
			id = string.format("%s_edge_%d", tostring(id), i),
			from = corners[edge[1]],
			to = corners[edge[2]],
			color = options.color,
			width = options.width or options.line_width,
			smooth = options.smooth,
			time = options.time,
		}
	end

	return id
end

function debug_draw.DrawWireAABB(options)
	options = options or {}
	return debug_draw.DrawWireBox(options)
end

function debug_draw.DrawSphere(options)
	options = options or {}
	local direct = options.draw_direct == true
	local entry = direct and
		{id = options.id or get_default_id(4), kind = "sphere"} or
		upsert_entry("sphere", options, 4)
	entry.position = clone_vec3(options.position or options.pos)
	entry.rotation = options.rotation and options.rotation:Copy() or identity_rotation:Copy()
	entry.radius = options.radius or 1
	entry.matrix = options.matrix
	entry.color = clone_color(options.color, debug_draw.GetShapeColor("sphere"))
	entry.shape_type = options.shape_type or "sphere"
	entry.ignore_z = options.ignore_z

	if entry.ignore_z == nil then entry.ignore_z = true end

	entry.translucent = options.translucent
	entry.double_sided = options.double_sided

	if direct then draw_shape_entry(entry) end

	return entry.id
end

function debug_draw.DrawBox(options)
	options = options or {}
	local direct = options.draw_direct == true
	local entry = direct and
		{id = options.id or get_default_id(4), kind = "box"} or
		upsert_entry("box", options, 4)
	entry.position = clone_vec3(options.position or options.pos)
	entry.rotation = options.rotation and options.rotation:Copy() or identity_rotation:Copy()
	entry.size = clone_vec3(options.size or options.scale or Vec3(1, 1, 1), Vec3(1, 1, 1))
	entry.matrix = options.matrix
	entry.color = clone_color(options.color, debug_draw.GetShapeColor("box"))
	entry.shape_type = options.shape_type or "box"
	entry.ignore_z = options.ignore_z

	if entry.ignore_z == nil then entry.ignore_z = true end

	entry.translucent = options.translucent
	entry.double_sided = options.double_sided

	if direct then draw_shape_entry(entry) end

	return entry.id
end

function debug_draw.DrawMesh(options)
	options = options or {}
	local direct = options.draw_direct == true
	local entry = direct and
		{id = options.id or get_default_id(4), kind = "mesh"} or
		upsert_entry("mesh", options, 4)
	entry.drawable = options.polygon3d or options.polygon or options.drawable or options.mesh
	entry.position = clone_vec3(options.position or options.pos)
	entry.rotation = options.rotation and options.rotation:Copy() or identity_rotation:Copy()
	entry.scale = clone_vec3(options.scale or options.size or Vec3(1, 1, 1), Vec3(1, 1, 1))
	entry.matrix = options.matrix
	entry.color = clone_color(options.color, debug_draw.GetShapeColor(options.shape_type or "mesh"))
	entry.shape_type = options.shape_type or "mesh"
	entry.ignore_z = options.ignore_z

	if entry.ignore_z == nil then entry.ignore_z = true end

	entry.translucent = options.translucent
	entry.double_sided = options.double_sided
	entry.emissive = options.emissive

	if direct then draw_shape_entry(entry) end

	return entry.id
end

event.AddListener("Update", "debug_draw_expire", function()
	prune_entries()
end)

event.AddListener("Draw3DForwardOverlay", "debug_draw_draw_3d_overlay", function()
	draw_shape_entries()
end)

event.AddListener("Draw2D", "debug_draw_draw_2d", function()
	draw_2d_entries()
end)

return debug_draw
