local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local units = import("goluwa/source_engine/units.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local brush_editor = library()
-- Click selects a face, an edge or a vertex. Dragging the arrow of a selected face pushes or pulls it, dragging a
-- vertex or an edge moves it and holding R while starting the drag rotates it instead. Rotating a selected face works
-- the same, hold R and drag the face. X, Y or Z held while starting a rotation rotates around that world axis instead
-- of the view axis. Shift snaps.
local listener_key = "brush_editor"
local HANDLE_PIXELS = 90
local HANDLE_TIP_RADIUS_PIXELS = 7
local HANDLE_PICK_PIXELS = 14
local VERTEX_PICK_PIXELS = 10
local EDGE_PICK_PIXELS = 6
local VERTEX_RADIUS_PIXELS = 4
local SNAP_SOURCE_UNITS = 8
local SNAP_ROTATION = math.rad(15)
local LINE_LIFETIME = 0.1
local WORLD_AXES = {x = Vec3(1, 0, 0), y = Vec3(0, 1, 0), z = Vec3(0, 0, 1)}
local edge_color = Color(0.85, 0.9, 1, 0.9)
local selected_color = Color(1, 0.6, 0.15, 1)
local hovered_color = Color(1, 0.9, 0.4, 1)
local vertex_color = Color(0.6, 0.8, 1, 1)
local hovered_fill = Color(0.3, 0.75, 1, 0.18)
local selected_fill = Color(1, 0.55, 0.15, 0.32)
local state = {
	brush = nil,
	faces = {},
	vertices = {},
	edges = {},
	selected = nil,
	selected_points = nil,
	hovered = nil,
	handle_hovered = false,
	handle = nil,
	drag = nil,
}

local function is_ui_hovering()
	local hovered = MouseInput.GetHoveredObject and MouseInput.GetHoveredObject() or NULL
	return hovered and
		hovered.IsValid and
		hovered:IsValid() and
		hovered ~= Panel.World or
		false
end

local function point_in_polygon(point, polygon)
	local inside = false
	local previous = polygon[#polygon]

	for _, current in ipairs(polygon) do
		if
			(
				current.y > point.y
			) ~= (
				previous.y > point.y
			)
			and
			point.x < (
				previous.x - current.x
			) * (
				point.y - current.y
			) / (
				previous.y - current.y
			) + current.x
		then
			inside = not inside
		end

		previous = current
	end

	return inside
end

local function distance_to_segment(point, a, b)
	local dx, dy = b.x - a.x, b.y - a.y
	local length_sq = dx * dx + dy * dy
	local t = length_sq > 0 and
		math.clamp(((point.x - a.x) * dx + (point.y - a.y) * dy) / length_sq, 0, 1) or
		0
	local x, y = a.x + dx * t, a.y + dy * t
	return math.sqrt((point.x - x) ^ 2 + (point.y - y) ^ 2)
end

-- world units covered by one pixel at a position, nil when it is behind the camera
local function get_pixel_size(position)
	local cam = render3d.GetCamera()
	local depth = (position - cam:GetPosition()):GetDot(cam:GetRotation():GetForward())

	if depth < 0.05 then return nil end

	return 2 * math.tan(cam:GetFOV() / 2) * depth / cam.Viewport.h
end

local function find_nearest(points, point)
	local best, best_distance = nil, math.huge

	for i, other in ipairs(points) do
		local distance = (other - point):GetLength()

		if distance < best_distance then best, best_distance = i, distance end
	end

	return best
end

local function get_centroid(points)
	local sum = Vec3(0, 0, 0)

	for _, point in ipairs(points) do
		sum = sum + point
	end

	return sum / #points
end

-- the view ray through the mouse hits the plane through origin that faces the camera
local function intersect_view_plane(mouse_position, origin)
	local cam = render3d.GetCamera()
	local forward = cam:GetRotation():GetForward()
	local direction = cam:ScreenToWorldDirection(mouse_position)
	local ray_origin = cam:GetPosition()
	local t = (origin - ray_origin):GetDot(forward) / direction:GetDot(forward)
	return ray_origin + direction * t
end

local function rotate_around_axis(point, pivot, axis, angle)
	local offset = point - pivot
	local cos, sin = math.cos(angle), math.sin(angle)
	return pivot + offset * cos + axis:GetCross(offset) * sin + axis * (
			axis:GetDot(offset) * (
				1 - cos
			)
		)
end

-- projects the brush: its sides, the corners they share and the edges between corners
local function update_geometry()
	local brush = state.brush
	local cam = render3d.GetCamera()
	local cam_position = cam:GetPosition()
	local faces, vertices, edges = {}, {}, {}
	local source = brush:GetVertices()

	for i, point in ipairs(source) do
		local world = units.PositionToEngine(point)
		vertices[i] = {
			source = point,
			world = world,
			screen = cam:WorldPositionToScreenUnjittered(world),
			front = false,
		}
	end

	local seen = {}

	for i, side in ipairs(brush.sides) do
		local corners = brush:GetSideCorners(i)

		if corners then
			local world, screen, indices = {}, {}, {}
			local visible = true

			for k, corner in ipairs(corners) do
				world[k] = units.PositionToEngine(corner)
				screen[k] = cam:WorldPositionToScreenUnjittered(world[k])
				indices[k] = find_nearest(source, corner)

				if not screen[k] then visible = false end
			end

			local center = units.PositionToEngine(brush:GetSideCenter(i))
			local normal = units.PlaneToEngine(side).normal
			local front = normal:GetDot(cam_position - center) > 0

			for k = 1, #corners do
				local a, b = indices[k], indices[k % #corners + 1]
				local key = math.min(a, b) * 4096 + math.max(a, b)
				local edge = seen[key]

				if not edge then
					edge = {a = a, b = b, front = false}
					seen[key] = edge
					edges[#edges + 1] = edge
				end

				if front then
					edge.front = true
					vertices[a].front = true
				end
			end

			if visible then
				faces[i] = {
					world = world,
					screen = screen,
					corners = corners,
					center = center,
					normal = normal,
					depth = (center - cam_position):GetLength(),
					front = front,
				}
			end
		end
	end

	state.faces, state.vertices, state.edges = faces, vertices, edges
end

local function update_handle()
	state.handle = nil
	local face = state.faces[state.selected]

	if not face then return end

	local pixel_size = get_pixel_size(face.center)

	if not pixel_size then return end

	local length = pixel_size * HANDLE_PIXELS
	local tip = face.center + face.normal * length
	local start_screen = render3d.GetCamera():WorldPositionToScreenUnjittered(face.center)
	local tip_screen = render3d.GetCamera():WorldPositionToScreenUnjittered(tip)

	if not (start_screen and tip_screen) then return end

	state.handle = {
		start = face.center,
		tip = tip,
		length = length,
		pixel_size = pixel_size,
		start_screen = start_screen,
		tip_screen = tip_screen,
	}
end

local function find_side_through(points)
	for i, side in ipairs(state.brush.sides) do
		local touching = true

		for _, point in ipairs(points) do
			if math.abs(side.normal:Dot(point) - side.dist) > 0.1 then
				touching = false

				break
			end
		end

		if touching then return i end
	end
end

local function update_edit_drag(mouse_position)
	local drag = state.drag

	if not drag.moved and (mouse_position - drag.start_mouse):GetLength() < 1 then
		return
	end

	local shift = input.IsShiftDown()

	if
		drag.moved and
		drag.last_x == mouse_position.x and
		drag.last_y == mouse_position.y and
		drag.last_shift == shift
	then
		return
	end

	drag.moved = true
	drag.last_x, drag.last_y, drag.last_shift = mouse_position.x, mouse_position.y, shift
	local points = {}
	local moved = {}

	for i, point in ipairs(drag.start_points) do
		points[i] = point
	end

	if drag.kind == "move" then
		local delta = units.PositionFromEngine(intersect_view_plane(mouse_position, drag.grab) - drag.start_hit)

		if input.IsShiftDown() then
			local reference = drag.start_points[drag.indices[1]]
			local target = reference + delta
			delta = Vec3(
					math.floor(target.x / SNAP_SOURCE_UNITS + 0.5) * SNAP_SOURCE_UNITS,
					math.floor(target.y / SNAP_SOURCE_UNITS + 0.5) * SNAP_SOURCE_UNITS,
					math.floor(target.z / SNAP_SOURCE_UNITS + 0.5) * SNAP_SOURCE_UNITS
				) - reference
		end

		for _, index in ipairs(drag.indices) do
			points[index] = drag.start_points[index] + delta
			list.insert(moved, points[index])
		end
	else
		local current = mouse_position - drag.pivot_screen
		local angle = math.atan2(
			drag.start_vector.x * current.y - drag.start_vector.y * current.x,
			drag.start_vector:GetDot(current)
		)

		if input.IsShiftDown() then
			angle = math.floor(angle / SNAP_ROTATION + 0.5) * SNAP_ROTATION
		end

		for _, index in ipairs(drag.indices) do
			points[index] = units.PositionFromEngine(
				rotate_around_axis(
					units.PositionToEngine(drag.start_points[index]),
					drag.pivot,
					drag.axis,
					angle
				)
			)
			list.insert(moved, points[index])
		end
	end

	if state.brush:RebuildFromPoints(points, drag.start_sides, moved) then
		if drag.select_face then
			state.selected = find_side_through(moved)
		else
			state.selected_points = moved
		end
	end
end

local function update_push_pull(mouse_position)
	local drag = state.drag
	local offset = (
			mouse_position - drag.start_mouse
		):GetDot(drag.screen_direction) / drag.screen_length * drag.world_length / units.meters

	if input.IsShiftDown() then
		offset = math.floor(offset / SNAP_SOURCE_UNITS + 0.5) * SNAP_SOURCE_UNITS
	end

	state.brush:SetSideDist(drag.side, drag.start_dist + offset)
end

local function find_hovered(mouse_position)
	local best, best_distance = nil, VERTEX_PICK_PIXELS

	for i, vertex in ipairs(state.vertices) do
		if vertex.front and vertex.screen then
			local distance = (mouse_position - vertex.screen):GetLength()

			if distance < best_distance then
				best, best_distance = {kind = "vertex", index = i}, distance
			end
		end
	end

	if best then return best end

	best_distance = EDGE_PICK_PIXELS

	for i, edge in ipairs(state.edges) do
		local a, b = state.vertices[edge.a].screen, state.vertices[edge.b].screen

		if edge.front and a and b then
			local distance = distance_to_segment(mouse_position, a, b)

			if distance < best_distance then
				best, best_distance = {kind = "edge", index = i}, distance
			end
		end
	end

	if best then return best end

	best_distance = math.huge

	for i, face in pairs(state.faces) do
		if
			face.front and
			face.depth < best_distance and
			point_in_polygon(mouse_position, face.screen)
		then
			best, best_distance = {kind = "face", index = i}, face.depth
		end
	end

	return best
end

local function draw_handles()
	for i, vertex in ipairs(state.vertices) do
		local pixel_size = get_pixel_size(vertex.world)

		if vertex.front and pixel_size then
			local hovered = state.hovered and
				state.hovered.kind == "vertex" and
				state.hovered.index == i
			debug_draw.DrawSphere{
				id = listener_key .. "_vertex_" .. i,
				position = vertex.world,
				radius = pixel_size * (hovered and VERTEX_RADIUS_PIXELS * 1.6 or VERTEX_RADIUS_PIXELS),
				color = hovered and hovered_color or vertex_color,
				time = LINE_LIFETIME,
				ignore_z = true,
			}
		end
	end

	local hovered = state.hovered

	if hovered and hovered.kind == "edge" then
		local edge = state.edges[hovered.index]
		debug_draw.DrawLine{
			id = listener_key .. "_hovered_edge",
			from = state.vertices[edge.a].world,
			to = state.vertices[edge.b].world,
			color = hovered_color,
			width = 3,
			time = LINE_LIFETIME,
			ignore_z = true,
		}
	end

	local points = state.selected_points

	if points then
		for i, point in ipairs(points) do
			local world = units.PositionToEngine(point)
			debug_draw.DrawSphere{
				id = listener_key .. "_selected_point_" .. i,
				position = world,
				radius = (get_pixel_size(world) or 0) * VERTEX_RADIUS_PIXELS * 1.6,
				color = selected_color,
				time = LINE_LIFETIME,
				ignore_z = true,
			}
		end

		if #points == 2 then
			debug_draw.DrawLine{
				id = listener_key .. "_selected_edge",
				from = units.PositionToEngine(points[1]),
				to = units.PositionToEngine(points[2]),
				color = selected_color,
				width = 3,
				time = LINE_LIFETIME,
				ignore_z = true,
			}
		end
	end

	local handle = state.handle

	if handle then
		local color = (state.handle_hovered or state.drag) and hovered_color or selected_color
		debug_draw.DrawLine{
			id = listener_key .. "_handle_shaft",
			from = handle.start,
			to = handle.tip,
			color = color,
			width = 3,
			time = LINE_LIFETIME,
			ignore_z = true,
		}
		debug_draw.DrawSphere{
			id = listener_key .. "_handle_tip",
			position = handle.tip,
			radius = handle.pixel_size * HANDLE_TIP_RADIUS_PIXELS,
			color = color,
			time = LINE_LIFETIME,
			ignore_z = true,
		}
	end
end

local function update()
	local brush = state.brush

	if not brush then return end

	if not brush.Owner:IsValid() then
		brush_editor.SetEntity(nil)
		return
	end

	local mouse_position = system.GetWindow():GetMousePosition()

	if state.drag then
		if state.drag.kind == "push_pull" then
			update_push_pull(mouse_position)
		else
			update_edit_drag(mouse_position)
		end
	end

	update_geometry()
	update_handle()
	state.hovered = nil
	state.handle_hovered = false

	if not state.drag and not is_ui_hovering() then
		local handle = state.handle

		if
			handle and
			(
				(
					mouse_position - handle.tip_screen
				):GetLength() < HANDLE_PICK_PIXELS or
				distance_to_segment(mouse_position, handle.start_screen, handle.tip_screen) < HANDLE_PICK_PIXELS / 2
			)
		then
			state.handle_hovered = true
		else
			state.hovered = find_hovered(mouse_position)
		end
	end

	for i, face in pairs(state.faces) do
		if face.front or i == state.selected then
			local selected = i == state.selected
			local count = #face.world

			for k = 1, count do
				debug_draw.DrawLine{
					id = listener_key .. "_edge_" .. i .. "_" .. k,
					from = face.world[k],
					to = face.world[k % count + 1],
					color = selected and selected_color or edge_color,
					width = selected and 3 or 1,
					time = LINE_LIFETIME,
					ignore_z = true,
				}
			end
		end
	end

	draw_handles()
end

local function draw_fills()
	local brush = state.brush

	if not brush then return end

	local matrix = brush.Owner.transform:GetWorldMatrix()
	local hovered = state.hovered and state.hovered.kind == "face" and state.hovered.index

	for _, entry in ipairs{{hovered, hovered_fill}, {state.selected, selected_fill}} do
		local polygon = entry[1] and brush:GetSidePolygon(entry[1])

		if polygon then
			debug_draw.DrawMesh{
				id = listener_key .. "_fill_" .. entry[1],
				polygon3d = polygon,
				matrix = matrix,
				color = entry[2],
				draw_direct = true,
				ignore_z = true,
				translucent = true,
				double_sided = true,
			}
		end
	end
end

-- points are the source space corners to move or rotate
local function begin_edit_drag(window, points, select_face)
	local mouse_position = window:GetMousePosition():Copy()
	local start_points = state.brush:GetVertices()
	local indices = {}
	local engine = {}

	for i, point in ipairs(points) do
		indices[i] = find_nearest(start_points, point)
		engine[i] = units.PositionToEngine(start_points[indices[i]])
	end

	local drag = {
		kind = input.IsKeyDown("r") and "rotate" or "move",
		start_points = start_points,
		start_sides = state.brush.sides,
		start_mouse = mouse_position,
		indices = indices,
		select_face = select_face,
		moved = false,
	}

	if drag.kind == "move" then
		drag.grab = get_centroid(engine)
		drag.start_hit = intersect_view_plane(mouse_position, drag.grab)
	else
		local cam = render3d.GetCamera()
		local forward = cam:GetRotation():GetForward()
		local axis = forward

		for name, world_axis in pairs(WORLD_AXES) do
			if input.IsKeyDown(name) then
				axis = world_axis:GetDot(forward) >= 0 and world_axis or world_axis * -1
			end
		end

		local pivot_points = engine

		if #engine == 1 then
			pivot_points = {}

			for i, point in ipairs(start_points) do
				pivot_points[i] = units.PositionToEngine(point)
			end
		end

		drag.axis = axis
		drag.pivot = get_centroid(pivot_points)
		drag.pivot_screen = cam:WorldPositionToScreenUnjittered(drag.pivot)

		if not drag.pivot_screen then return end

		drag.start_vector = mouse_position - drag.pivot_screen

		if drag.start_vector:GetLength() < 1e-3 then return end
	end

	state.drag = drag
	return true
end

local function mouse_input(window, button, press)
	if button ~= "button_1" or not state.brush then return end

	if not press then
		if not state.drag then return end

		state.drag = nil
		state.brush:Recenter()
		return true
	end

	if is_ui_hovering() then return end

	if state.handle_hovered then
		local handle = state.handle
		local axis = handle.tip_screen - handle.start_screen
		local length = axis:GetLength()

		if length < 1e-5 then return end

		state.drag = {
			kind = "push_pull",
			side = state.selected,
			start_dist = state.brush.sides[state.selected].dist,
			start_mouse = window:GetMousePosition():Copy(),
			screen_direction = axis / length,
			screen_length = length,
			world_length = handle.length,
		}
		return true
	end

	local hovered = state.hovered

	if not hovered then
		state.selected, state.selected_points = nil, nil
		return
	end

	if hovered.kind == "face" then
		if hovered.index == state.selected and input.IsKeyDown("r") then
			return begin_edit_drag(window, state.faces[hovered.index].corners, true)
		end

		state.selected, state.selected_points = hovered.index, nil
		return
	end

	local points

	if hovered.kind == "vertex" then
		points = {state.vertices[hovered.index].source}
	else
		local edge = state.edges[hovered.index]
		points = {state.vertices[edge.a].source, state.vertices[edge.b].source}
	end

	state.selected, state.selected_points = nil, points
	return begin_edit_drag(window, points, false)
end

function brush_editor.SetEntity(entity)
	state.drag = nil
	state.selected = nil
	state.selected_points = nil
	state.hovered = nil
	state.handle_hovered = false
	state.handle = nil
	state.faces, state.vertices, state.edges = {}, {}, {}
	state.brush = entity and entity.brush

	if state.brush then state.brush:Activate() end
end

-- true while the editor wants the mouse, so the camera should not look around
function brush_editor.IsBusy()
	local hovered = state.hovered
	return state.drag ~= nil or
		state.handle_hovered or
		hovered ~= nil and
		(
			hovered.kind ~= "face" or
			hovered.index == state.selected and
			input.IsKeyDown("r")
		)
end

function brush_editor.GetSelectedSide()
	return state.selected
end

event.AddListener("Update", listener_key, update)
event.AddListener("Draw3DForwardOverlay", listener_key, draw_fills)
event.AddListener("WindowMouseInput", listener_key, mouse_input, {priority = 100})
return brush_editor
