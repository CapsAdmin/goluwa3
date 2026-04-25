local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local MouseInput = import("goluwa/ecs/components/2d/mouse_input.lua")
local Entity = import("goluwa/ecs/entity.lua")
local input = import("goluwa/input.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local system = import("goluwa/system.lua")
local gizmo = library()
local listener_key = "gui_gizmo_service"
local CONE_SEGMENTS = 20
local RING_SEGMENTS = 48
local MOVE_CONE_LENGTH_SCALE = 0.24
local MOVE_CONE_RADIUS_SCALE = 0.5
local MOVE_SHAFT_RADIUS_SCALE = 0.1
local SCALE_BOX_SIZE_SCALE = 0.5
local SCALE_STEM_RADIUS_SCALE = 0.28
local COMBINED_RING_RADIUS_SCALE = 0.42
local COMBINED_MOVE_BASE_DISTANCE_SCALE = 0.56
local COMBINED_SCALE_BOX_DISTANCE_SCALE = 0.92
local ROTATION_RING_RADIAL_HALF_WIDTH = 0.01
local ROTATION_RING_HALF_THICKNESS = 0.01
local VIEW_ROTATION_RING_RADIUS_SCALE = 1
local ROTATION_SNAP_STEP_DEGREES = 90 / 4
local axis_colors = {
	x = Color(0.95, 0.32, 0.28, 0.65),
	y = Color(0.30, 0.82, 0.34, 0.65),
	z = Color(0.28, 0.56, 0.96, 0.65),
	view = Color(0.5, 0.5, 0.5, 0.65),
}
local state = {
	gizmo_entity = nil,
	mode = "move",
	space = "local",
	hovered_handle = nil,
	active_drag = nil,
	callback_owner = nil,
	state_changed = nil,
}
local get_transform_local_rotation
local get_transform_world_rotation
local get_viewport_size
local project_world_position
local get_screen_segment_distance
local get_projected_shape_screen_distance
local get_circle_basis
local get_active_gizmo_handles
local unit_cone_polygon
local unit_ring_polygon
local gizmo_world_to_screen_matrix = Matrix44()
local gizmo_screen_to_world_inverse = Matrix44()
local gizmo_screen_to_world_near = Matrix44()
local gizmo_screen_to_world_far = Matrix44()

local function add_mesh_triangle(poly, a, b, c, normal)
	normal = normal or (b - a):GetCross(c - a):GetNormalized()
	poly:AddVertex{pos = a, uv = Vec2(0, 0), normal = normal}
	poly:AddVertex{pos = b, uv = Vec2(1, 0), normal = normal}
	poly:AddVertex{pos = c, uv = Vec2(0.5, 1), normal = normal}
end

local function add_mesh_quad(poly, a, b, c, d)
	local normal = (a - b):GetCross(a - c):GetNormalized()
	add_mesh_triangle(poly, a, b, c, normal)
	add_mesh_triangle(poly, a, c, d, normal)
end

local function get_unit_cone_polygon()
	if unit_cone_polygon then return unit_cone_polygon end

	local poly = Polygon3D.New()
	local base_center = Vec3(0, 0, 0)
	local tip = Vec3(0, 0, -1)

	for i = 0, CONE_SEGMENTS - 1 do
		local angle_a = (i / CONE_SEGMENTS) * math.pi * 2
		local angle_b = ((i + 1) / CONE_SEGMENTS) * math.pi * 2
		local a = Vec3(math.cos(angle_a), math.sin(angle_a), 0)
		local b = Vec3(math.cos(angle_b), math.sin(angle_b), 0)
		add_mesh_triangle(poly, a, b, tip)
		add_mesh_triangle(poly, base_center, b, a, Vec3(0, 0, -1))
	end

	poly:Upload()
	unit_cone_polygon = poly
	return unit_cone_polygon
end

local function get_unit_ring_polygon()
	if unit_ring_polygon then return unit_ring_polygon end

	local poly = Polygon3D.New()
	local outer_radius = 1 + ROTATION_RING_RADIAL_HALF_WIDTH
	local inner_radius = math.max(0.001, 1 - ROTATION_RING_RADIAL_HALF_WIDTH)
	local z_min = -ROTATION_RING_HALF_THICKNESS
	local z_max = ROTATION_RING_HALF_THICKNESS

	for i = 0, RING_SEGMENTS - 1 do
		local angle_a = (i / RING_SEGMENTS) * math.pi * 2
		local angle_b = ((i + 1) / RING_SEGMENTS) * math.pi * 2
		local cos_a = math.cos(angle_a)
		local sin_a = math.sin(angle_a)
		local cos_b = math.cos(angle_b)
		local sin_b = math.sin(angle_b)
		local outer_a_bottom = Vec3(cos_a * outer_radius, sin_a * outer_radius, z_min)
		local outer_a_top = Vec3(cos_a * outer_radius, sin_a * outer_radius, z_max)
		local outer_b_bottom = Vec3(cos_b * outer_radius, sin_b * outer_radius, z_min)
		local outer_b_top = Vec3(cos_b * outer_radius, sin_b * outer_radius, z_max)
		local inner_a_bottom = Vec3(cos_a * inner_radius, sin_a * inner_radius, z_min)
		local inner_a_top = Vec3(cos_a * inner_radius, sin_a * inner_radius, z_max)
		local inner_b_bottom = Vec3(cos_b * inner_radius, sin_b * inner_radius, z_min)
		local inner_b_top = Vec3(cos_b * inner_radius, sin_b * inner_radius, z_max)
		add_mesh_quad(poly, outer_a_bottom, outer_a_top, outer_b_top, outer_b_bottom)
		add_mesh_quad(poly, inner_a_bottom, inner_b_bottom, inner_b_top, inner_a_top)
		add_mesh_quad(poly, outer_a_top, inner_a_top, inner_b_top, outer_b_top)
		add_mesh_quad(poly, inner_a_bottom, outer_a_bottom, outer_b_bottom, inner_b_bottom)
	end

	poly:Upload()
	unit_ring_polygon = poly
	return unit_ring_polygon
end

local function get_polygon_triangles(polygon)
	local cached = polygon and polygon.raycast_triangles

	if cached then return cached end

	local triangles = {}
	local vertices = polygon and polygon.Vertices or {}
	local indices = polygon and polygon.indices

	if indices and indices[1] then
		for i = 1, #indices, 3 do
			triangles[#triangles + 1] = {indices[i], indices[i + 1], indices[i + 2]}
		end
	else
		for i = 1, #vertices, 3 do
			triangles[#triangles + 1] = {i, i + 1, i + 2}
		end
	end

	polygon.raycast_triangles = triangles
	return triangles
end

local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(max_value, value))
end

local function brighten_color(color, scale)
	return Color(
		clamp(color.r * scale, 0, 1),
		clamp(color.g * scale, 0, 1),
		clamp(color.b * scale, 0, 1),
		color.a or 1
	)
end

local function get_debug_draw_color(color)
	return Color(color.r, color.g, color.b, color.a or 1)
end

local function is_valid_entity(entity)
	return entity and entity.IsValid and entity:IsValid() or false
end

local function is_gizmo_entity(entity)
	return is_valid_entity(entity) and entity ~= Entity.World and entity.transform ~= nil
end

local function is_ui_hovering()
	local hovered = MouseInput.GetHoveredObject and MouseInput.GetHoveredObject() or NULL
	return hovered and
		hovered.IsValid and
		hovered:IsValid() and
		hovered ~= Panel.World or
		false
end

local function notify_state_changed()
	if not state.state_changed then return end

	local owner = state.callback_owner

	if owner and owner.IsValid and not owner:IsValid() then
		state.callback_owner = nil
		state.state_changed = nil
		return
	end

	state.state_changed(gizmo.GetStatus())
end

local function get_entity_world_position(entity)
	if not is_gizmo_entity(entity) then return nil end

	local x, y, z = entity.transform:GetWorldMatrix():GetTranslation()
	return Vec3(x, y, z)
end

local function get_entity_local_aabb(entity)
	if not is_gizmo_entity(entity) then return nil end

	if entity.visual and entity.visual.GetAABB then return entity.visual:GetAABB() end

	if entity.transform and entity.transform.GetAABB then
		return entity.transform:GetAABB()
	end

	return nil
end

local function get_entity_pivot(entity)
	local fallback = get_entity_world_position(entity)

	if not fallback then return nil, 1 end

	if entity.visual and entity.visual.GetWorldAABB then
		local aabb = entity.visual:GetWorldAABB()

		if aabb and aabb.min_x <= aabb.max_x then
			local extent_x = aabb.max_x - aabb.min_x
			local extent_y = aabb.max_y - aabb.min_y
			local extent_z = aabb.max_z - aabb.min_z
			return Vec3(
				(aabb.min_x + aabb.max_x) * 0.5,
				(aabb.min_y + aabb.max_y) * 0.5,
				(aabb.min_z + aabb.max_z) * 0.5
			),
			math.max(extent_x, extent_y, extent_z, 1)
		end
	end

	return fallback, 1
end

local function get_gizmo_scale(center, extent)
	local cam = render3d.GetCamera()

	if not cam then return math.max(extent * 0.75, 1.5) end

	local width, height = get_viewport_size()
	local center_screen, visibility = cam:WorldPositionToScreen(center, width, height)

	if visibility ~= -1 or not center_screen then
		return math.max(extent * 0.75, 1.5)
	end

	local right = cam:GetRotation():GetRight()
	local right_screen = cam:WorldPositionToScreen(center + right, width, height)

	if not right_screen then return math.max(extent * 0.75, 1.5) end

	local pixels_per_world_unit = (right_screen - center_screen):GetLength()

	if pixels_per_world_unit <= 1e-5 then return math.max(extent * 0.75, 1.5) end

	local target_axis_pixels = 140
	local scale = target_axis_pixels / pixels_per_world_unit
	return math.max(scale, 1.5)
end

local function transform_world_point(matrix, position)
	local x, y, z = matrix:TransformVectorUnpacked(position.x, position.y, position.z)
	return Vec3(x, y, z)
end

local function create_ray(origin, direction, max_distance)
	return {
		origin = origin,
		direction = direction:GetNormalized(),
		max_distance = max_distance or math.huge,
	}
end

local function transform_ray(ray, world_to_local)
	if not world_to_local then return ray end

	local local_origin = world_to_local:TransformVector(ray.origin)
	local m = world_to_local
	local dx, dy, dz = ray.direction.x, ray.direction.y, ray.direction.z
	local local_direction = Vec3(
		m.m00 * dx + m.m10 * dy + m.m20 * dz,
		m.m01 * dx + m.m11 * dy + m.m21 * dz,
		m.m02 * dx + m.m12 * dy + m.m22 * dz
	):GetNormalized()
	return create_ray(local_origin, local_direction, ray.max_distance)
end

local function ray_triangle_intersection(ray, v0, v1, v2)
	local epsilon = 0.0000001
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local h = ray.direction:GetCross(edge2)
	local a = edge1:Dot(h)

	if a > -epsilon and a < epsilon then return false end

	local f = 1.0 / a
	local s = ray.origin - v0
	local u = f * s:Dot(h)

	if u < 0.0 or u > 1.0 then return false end

	local q = s:GetCross(edge1)
	local v = f * ray.direction:Dot(q)

	if v < 0.0 or u + v > 1.0 then return false end

	local t = f * edge2:Dot(q)

	if t > epsilon and t <= ray.max_distance then return true, t end

	return false
end

local function ray_aabb_intersection(ray, aabb)
	if not aabb then return true end

	local tmin = -math.huge
	local tmax = ray.max_distance or math.huge

	local function get_component(vec, axis_id)
		if axis_id == "x" then return vec.x end

		if axis_id == "y" then return vec.y end

		return vec.z
	end

	for _, axis in ipairs{
		{"x", aabb.min_x, aabb.max_x},
		{"y", aabb.min_y, aabb.max_y},
		{"z", aabb.min_z, aabb.max_z},
	} do
		local value = get_component(ray.origin, axis[1])
		local direction = get_component(ray.direction, axis[1])

		if math.abs(direction) < 1e-8 then
			if value < axis[2] or value > axis[3] then return false end
		else
			local inv = 1 / direction
			local near = (axis[2] - value) * inv
			local far = (axis[3] - value) * inv

			if near > far then near, far = far, near end

			tmin = math.max(tmin, near)
			tmax = math.min(tmax, far)

			if tmin > tmax then return false end
		end
	end

	return tmax >= 0
end

local function get_axis_basis(direction)
	local forward = direction:GetNormalized()
	local reference = math.abs(forward:GetDot(orientation.UP_VECTOR)) > 0.95 and
		orientation.RIGHT_VECTOR or
		orientation.UP_VECTOR
	local right = forward:GetCross(reference)

	if right:GetLength() < 1e-5 then
		right = forward:GetCross(orientation.FORWARD_VECTOR)
	end

	right = right:GetNormalized()
	local up = right:GetCross(forward):GetNormalized()
	return right, up, forward
end

local function get_gizmo_camera_vector(center)
	local cam = render3d.GetCamera()

	if cam then
		local camera_vector = cam:GetPosition() - center

		if camera_vector:GetLength() >= 1e-5 then
			return camera_vector:GetNormalized()
		end
	end

	return orientation.FORWARD_VECTOR:Copy()
end

local function get_camera_facing_axis_direction(axis_direction, camera_vector)
	local sign = axis_direction:GetDot(camera_vector) >= 0 and 1 or -1
	return axis_direction * sign, sign
end

local function get_direction_rotation(direction)
	local right, up, forward = get_axis_basis(direction)
	local backward = forward * -1
	local matrix = Matrix44():Identity()
	matrix.m00 = right.x
	matrix.m01 = right.y
	matrix.m02 = right.z
	matrix.m10 = up.x
	matrix.m11 = up.y
	matrix.m12 = up.z
	matrix.m20 = backward.x
	matrix.m21 = backward.y
	matrix.m22 = backward.z
	return matrix:GetRotation(Quat()):GetNormalized()
end

local function create_mesh_shape(polygon, position, rotation, scale)
	return {
		polygon = polygon,
		position = position,
		rotation = rotation,
		scale = scale,
		triangles = get_polygon_triangles(polygon),
	}
end

local function get_shape_matrix(shape)
	if not shape then return nil end

	return debug_draw.MakeMatrix(shape.position, shape.rotation, shape.scale)
end

local function get_shape_world_to_local(shape)
	local matrix = get_shape_matrix(shape)

	if not matrix then return nil, nil end

	return matrix:GetInverse(), matrix
end

local function get_camera_viewport_rect(cam)
	local viewport = cam and cam.GetViewport and cam:GetViewport() or nil

	if viewport and viewport.w and viewport.h and viewport.w > 0 and viewport.h > 0 then
		return viewport
	end

	local width, height = get_viewport_size()
	return {
		x = 0,
		y = 0,
		w = width,
		h = height,
	}
end

local function get_viewport_mouse_position(window, cam)
	local viewport = get_camera_viewport_rect(cam)
	local mouse_pos = window:GetMousePosition()

	if not mouse_pos then return nil, viewport, nil end

	if mouse_pos.x < viewport.x or mouse_pos.y < viewport.y then
		return nil, viewport, mouse_pos
	end

	if mouse_pos.x >= viewport.x + viewport.w or mouse_pos.y >= viewport.y + viewport.h then
		return nil, viewport, mouse_pos
	end

	return Vec2(mouse_pos.x - viewport.x, mouse_pos.y - viewport.y),
	viewport,
	mouse_pos
end

local function get_camera_viewport_ray_direction(cam, viewport_mouse_pos, viewport)
	local ndc_x = (viewport_mouse_pos.x / viewport.w) * 2 - 1
	local ndc_y = (viewport_mouse_pos.y / viewport.h) * 2 - 1
	cam:BuildViewMatrix():GetMultiplied(cam:BuildProjectionMatrix(), gizmo_world_to_screen_matrix)
	gizmo_world_to_screen_matrix:GetInverse(gizmo_screen_to_world_inverse)
	local near_pos = gizmo_screen_to_world_inverse:MultiplyVector(ndc_x, ndc_y, 0, 1, gizmo_screen_to_world_near)
	local far_pos = gizmo_screen_to_world_inverse:MultiplyVector(ndc_x, ndc_y, 1, 1, gizmo_screen_to_world_far)
	return Vec3(far_pos.m00 - near_pos.m00, far_pos.m01 - near_pos.m01, far_pos.m02 - near_pos.m02):GetNormalized()
end

local function get_mouse_world_ray(window)
	local cam = render3d.GetCamera()

	if not cam then return nil end

	local viewport_mouse_pos, viewport, mouse_pos = get_viewport_mouse_position(window, cam)

	if not viewport_mouse_pos then return nil end

	local direction = get_camera_viewport_ray_direction(cam, viewport_mouse_pos, viewport)
	return create_ray(cam:GetPosition(), direction, math.huge)
end

local function intersect_mesh_shape(ray, shape)
	local world_to_local, matrix = get_shape_world_to_local(shape)

	if not world_to_local or not matrix then return nil end

	local local_ray = transform_ray(ray, world_to_local)

	if not ray_aabb_intersection(local_ray, shape.polygon and shape.polygon.AABB) then
		return nil
	end

	local best_hit
	local best_distance = math.huge
	local vertices = shape.polygon and shape.polygon.Vertices or {}

	for _, triangle in ipairs(shape.triangles or {}) do
		local v0 = vertices[triangle[1]]
		local v1 = vertices[triangle[2]]
		local v2 = vertices[triangle[3]]

		if v0 and v1 and v2 and v0.pos and v1.pos and v2.pos then
			local hit, local_distance = ray_triangle_intersection(local_ray, v0.pos, v1.pos, v2.pos)

			if hit then
				local local_position = local_ray.origin + local_ray.direction * local_distance
				local world_position = transform_world_point(matrix, local_position)
				local world_distance = (world_position - ray.origin):GetLength()

				if world_distance < best_distance then
					best_distance = world_distance
					best_hit = {
						distance = world_distance,
						position = world_position,
					}
				end
			end
		end
	end

	return best_hit
end

local function intersect_handle(ray, handle)
	local best_hit

	for _, shape in ipairs(handle.pick_shapes or {}) do
		local hit = intersect_mesh_shape(ray, shape)

		if hit and (not best_hit or hit.distance < best_hit.distance) then
			best_hit = hit
		end
	end

	return best_hit
end

local function find_hovered_gizmo_handle_screen(gizmo_def, mouse_pos)
	local function get_handle_screen_distance(handle)
		local best_distance = math.huge

		for _, shape in ipairs(handle.pick_shapes or {}) do
			local distance = get_projected_shape_screen_distance(mouse_pos, shape)

			if distance and distance < best_distance then best_distance = distance end
		end

		if best_distance < math.huge then
			return best_distance, handle.kind == "rotate" and 12 or 10
		end

		return nil
	end

	local function add_handles(target, handles)
		for _, handle in ipairs(handles or {}) do
			target[#target + 1] = handle
		end
	end

	local handles = {}
	local best_handle
	local best_distance = math.huge

	if state.mode == "move" then
		add_handles(handles, gizmo_def.move_handles)
	elseif state.mode == "scale" then
		add_handles(handles, gizmo_def.scale_handles_3d)
	elseif state.mode == "combined" then
		add_handles(handles, gizmo_def.rotation_handles)
		add_handles(handles, gizmo_def.move_handles)
		add_handles(handles, gizmo_def.scale_handles_3d)
	else
		add_handles(handles, gizmo_def.rotation_handles)
	end

	for _, handle in ipairs(handles) do
		local distance, threshold = get_handle_screen_distance(handle)

		if distance and distance < best_distance and distance <= threshold then
			best_distance = distance
			best_handle = handle
		end
	end

	return best_handle
end

local function get_axis_value(vector, axis_id)
	if axis_id == "x" then return vector.x end

	if axis_id == "y" then return vector.y end

	return vector.z
end

local function set_axis_value(vector, axis_id, value)
	if axis_id == "x" then
		vector.x = value
		return vector
	end

	if axis_id == "y" then
		vector.y = value
		return vector
	end

	vector.z = value
	return vector
end

local function get_axis_basis_vector(axis_id)
	if axis_id == "x" then return Vec3(1, 0, 0) end

	if axis_id == "y" then return Vec3(0, 1, 0) end

	return Vec3(0, 0, 1)
end

local function get_axis_center(local_aabb)
	return Vec3(
		(local_aabb.min_x + local_aabb.max_x) * 0.5,
		(local_aabb.min_y + local_aabb.max_y) * 0.5,
		(local_aabb.min_z + local_aabb.max_z) * 0.5
	)
end

local function get_local_face_center(local_aabb, axis_id, sign)
	local face_center = get_axis_center(local_aabb)
	local face_value

	if axis_id == "x" then
		face_value = sign > 0 and local_aabb.max_x or local_aabb.min_x
	elseif axis_id == "y" then
		face_value = sign > 0 and local_aabb.max_y or local_aabb.min_y
	else
		face_value = sign > 0 and local_aabb.max_z or local_aabb.min_z
	end

	set_axis_value(face_center, axis_id, face_value)
	return face_center, face_value
end

local function get_scale_handles(entity)
	local local_aabb = get_entity_local_aabb(entity)

	if not local_aabb then return nil end

	local world_matrix = entity.transform:GetWorldMatrix()

	if not world_matrix then return nil end

	local handles = {}
	local surface_rotation = get_transform_world_rotation(entity.transform):Copy()

	for _, axis in ipairs{
		{id = "x", color = axis_colors.x},
		{id = "y", color = axis_colors.y},
		{id = "z", color = axis_colors.z},
	} do
		for _, sign in ipairs({-1, 1}) do
			local face_center, face_value = get_local_face_center(local_aabb, axis.id, sign)
			local anchor_center, anchor_value = get_local_face_center(local_aabb, axis.id, -sign)
			local world_position = transform_world_point(world_matrix, face_center)
			local anchor_position = transform_world_point(world_matrix, anchor_center)
			local world_delta = world_position - anchor_position
			local world_length = world_delta:GetLength()
			handles[#handles + 1] = {
				kind = "scale",
				axis_id = axis.id,
				sign = sign,
				color = axis.color,
				position = world_position,
				anchor_position = anchor_position,
				axis_world_length = world_length,
				outward_direction = world_length > 1e-5 and world_delta / world_length or nil,
				surface_rotation = surface_rotation,
				anchor_value = anchor_value,
			}
		end
	end

	return handles
end

local function get_scale_handle(entity, axis_id, sign)
	for _, handle in ipairs(get_scale_handles(entity) or {}) do
		if handle.axis_id == axis_id and handle.sign == sign then return handle end
	end

	return nil
end

local function transform_direction(matrix, direction)
	local ox, oy, oz = matrix:TransformVectorUnpacked(0, 0, 0)
	local tx, ty, tz = matrix:TransformVectorUnpacked(direction.x, direction.y, direction.z)
	return Vec3(tx - ox, ty - oy, tz - oz):GetNormalized()
end

function get_transform_local_rotation(transform)
	local _, interpolated_rotation = transform:GetRenderPositionRotation()
	return (transform.OverrideRotation or interpolated_rotation or transform.Rotation):GetNormalized()
end

function get_transform_world_rotation(transform)
	local rotation = get_transform_local_rotation(transform)
	local owner = transform and transform.Owner
	local parent = owner and owner:GetParent()

	if parent and parent.IsValid and parent:IsValid() and parent.transform then
		return (get_transform_world_rotation(parent.transform) * rotation):GetNormalized()
	end

	return rotation
end

local function get_gizmo_axes(entity)
	local transform = entity.transform

	if state.space == "local" and transform then
		local world_rotation = get_transform_world_rotation(transform)
		return {
			{
				id = "x",
				direction = world_rotation:Right(),
				color = axis_colors.x,
			},
			{
				id = "y",
				direction = world_rotation:Up(),
				color = axis_colors.y,
			},
			{
				id = "z",
				direction = world_rotation:Forward(),
				color = axis_colors.z,
			},
		}
	end

	return {
		{id = "x", direction = orientation.RIGHT_VECTOR:Copy(), color = axis_colors.x},
		{id = "y", direction = orientation.UP_VECTOR:Copy(), color = axis_colors.y},
		{id = "z", direction = orientation.FORWARD_VECTOR:Copy(), color = axis_colors.z},
	}
end

function get_viewport_size()
	local size = Panel.World and
		Panel.World.transform and
		Panel.World.transform:GetSize() or
		nil

	if size then return size.x, size.y end

	local window = system.GetWindow()

	if window and window.GetSize then
		size = window:GetSize()

		if size then return size.x, size.y end
	end

	size = Vec2(1, 1)
	return size.x, size.y
end

function project_world_position(position)
	return debug_draw.ProjectWorldPosition(position)
end

function get_screen_segment_distance(mouse_pos, start_pos, stop_pos)
	local dx = stop_pos.x - start_pos.x
	local dy = stop_pos.y - start_pos.y
	local len_sq = dx * dx + dy * dy

	if len_sq <= 1e-6 then
		local sx = mouse_pos.x - start_pos.x
		local sy = mouse_pos.y - start_pos.y
		return math.sqrt(sx * sx + sy * sy)
	end

	local t = clamp(((mouse_pos.x - start_pos.x) * dx + (mouse_pos.y - start_pos.y) * dy) / len_sq, 0, 1)
	local px = start_pos.x + dx * t
	local py = start_pos.y + dy * t
	local ox = mouse_pos.x - px
	local oy = mouse_pos.y - py
	return math.sqrt(ox * ox + oy * oy)
end

local function get_signed_triangle_area_2d(a, b, c)
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

local function point_in_triangle_2d(point, a, b, c)
	local epsilon = 1e-5
	local ab = get_signed_triangle_area_2d(a, b, point)
	local bc = get_signed_triangle_area_2d(b, c, point)
	local ca = get_signed_triangle_area_2d(c, a, point)
	local has_negative = ab < -epsilon or bc < -epsilon or ca < -epsilon
	local has_positive = ab > epsilon or bc > epsilon or ca > epsilon
	return not (has_negative and has_positive)
end

get_projected_shape_screen_distance = function(mouse_pos, shape)
	local vertices = shape and shape.polygon and shape.polygon.Vertices or {}
	local triangles = shape and shape.triangles or {}
	local best_distance = math.huge
	local matrix = get_shape_matrix(shape)

	if not matrix then return nil end

	for _, triangle in ipairs(triangles) do
		local v0 = vertices[triangle[1]]
		local v1 = vertices[triangle[2]]
		local v2 = vertices[triangle[3]]

		if v0 and v1 and v2 and v0.pos and v1.pos and v2.pos then
			local p0 = project_world_position(transform_world_point(matrix, v0.pos))
			local p1 = project_world_position(transform_world_point(matrix, v1.pos))
			local p2 = project_world_position(transform_world_point(matrix, v2.pos))

			if p0 and p1 and p2 then
				if point_in_triangle_2d(mouse_pos, p0, p1, p2) then return 0 end

				best_distance = math.min(
					best_distance,
					get_screen_segment_distance(mouse_pos, p0, p1),
					get_screen_segment_distance(mouse_pos, p1, p2),
					get_screen_segment_distance(mouse_pos, p2, p0)
				)
			end
		end
	end

	return best_distance < math.huge and best_distance or nil
end

function get_circle_basis(normal)
	local tangent = math.abs(normal:GetDot(orientation.UP_VECTOR)) > 0.9 and
		orientation.RIGHT_VECTOR or
		orientation.UP_VECTOR
	local u = normal:GetCross(tangent)

	if u:GetLength() < 1e-5 then u = normal:GetCross(orientation.FORWARD_VECTOR) end

	u = u:GetNormalized()
	return u, normal:GetCross(u):GetNormalized()
end

local function build_axis_rotation(axis, angle)
	return QuatFromAxis(angle, axis)
end

local function get_quat_twist_angle(rotation, axis)
	local axis_projection = rotation.x * axis.x + rotation.y * axis.y + rotation.z * axis.z
	local twist = Quat(
		axis.x * axis_projection,
		axis.y * axis_projection,
		axis.z * axis_projection,
		rotation.w
	)
	twist = twist:GetNormalized()
	return math.atan2(twist.x * axis.x + twist.y * axis.y + twist.z * axis.z, twist.w) * 2
end

local function get_rotation_snap_state(entity, axis_id, axis_direction)
	if state.space == "local" then
		local local_rotation = get_transform_local_rotation(entity.transform)
		local local_axis = get_axis_basis_vector(axis_id)
		local twist_angle = get_quat_twist_angle(local_rotation, local_axis)
		local swing = (
			local_rotation * QuatFromAxis(twist_angle, local_axis):GetConjugated()
		):GetNormalized()
		return twist_angle, swing
	end

	local world_rotation = get_transform_world_rotation(entity.transform)
	local twist_angle = get_quat_twist_angle(world_rotation, axis_direction)
	local swing = (
		QuatFromAxis(twist_angle, axis_direction):GetConjugated() * world_rotation
	):GetNormalized()
	return twist_angle, swing
end

local function intersect_ray_plane(ray, plane_origin, plane_normal)
	local denominator = ray.direction:GetDot(plane_normal)

	if math.abs(denominator) < 1e-6 then return nil end

	local distance = (plane_origin - ray.origin):GetDot(plane_normal) / denominator

	if distance < 0 or distance > ray.max_distance then return nil end

	return ray.origin + ray.direction * distance
end

local function get_axis_drag_plane_normal(axis_direction, reference_direction)
	local axis = axis_direction:GetNormalized()
	local projected_reference = reference_direction - axis * reference_direction:GetDot(axis)

	if projected_reference:GetLength() >= 1e-5 then
		return projected_reference:GetNormalized()
	end

	for _, fallback in ipairs{orientation.UP_VECTOR, orientation.RIGHT_VECTOR, orientation.FORWARD_VECTOR} do
		projected_reference = fallback - axis * fallback:GetDot(axis)

		if projected_reference:GetLength() >= 1e-5 then
			return projected_reference:GetNormalized()
		end
	end

	return nil
end

local function project_axis_drag_distance(ray, axis_origin, axis_direction, plane_normal)
	local point = intersect_ray_plane(ray, axis_origin, plane_normal)

	if not point then return nil end

	return (point - axis_origin):GetDot(axis_direction)
end

local function get_mouse_rotation_plane_vector(ray, center, axis_direction)
	if not ray then return nil end

	local point = intersect_ray_plane(ray, center, axis_direction)

	if not point then return nil end

	local plane_vector = point - center

	if plane_vector:GetLength() < 1e-5 then return nil end

	return plane_vector:GetNormalized()
end

local function get_mouse_rotation_ring_vector(center, axis_direction, radius, mouse_pos, center_screen)
	center_screen = center_screen or project_world_position(center)

	if not center_screen then return nil end

	local u, v = get_circle_basis(axis_direction)
	local u_screen = project_world_position(center + u * radius)
	local v_screen = project_world_position(center + v * radius)

	if not (u_screen and v_screen) then return nil end

	local ux = u_screen.x - center_screen.x
	local uy = u_screen.y - center_screen.y
	local vx = v_screen.x - center_screen.x
	local vy = v_screen.y - center_screen.y
	local det = ux * vy - uy * vx

	if math.abs(det) < 1e-5 then return nil end

	local dx = mouse_pos.x - center_screen.x
	local dy = mouse_pos.y - center_screen.y
	local ru = (dx * vy - dy * vx) / det
	local rv = (ux * dy - uy * dx) / det
	local ring_vector = Vec2(ru, rv)

	if ring_vector:GetLength() < 1e-5 then return nil end

	return ring_vector:GetNormalized()
end

local function set_entity_world_position(entity, world_position)
	local parent = entity and entity:GetParent()

	if parent and parent:IsValid() and parent.transform then
		entity.transform:SetPosition(parent.transform:GetWorldMatrixInverse():TransformVector(world_position))
		return
	end

	entity.transform:SetPosition(world_position)
end

local function set_entity_world_rotation(entity, world_rotation)
	local parent = entity and entity:GetParent()

	if parent and parent:IsValid() and parent.transform then
		entity.transform:SetRotation(get_transform_world_rotation(parent.transform):GetConjugated() * world_rotation)
		return
	end

	entity.transform:SetRotation(world_rotation)
end

local function get_entity_local_rotation_from_world_rotation(entity, world_rotation)
	local parent = entity and entity:GetParent()

	if parent and parent:IsValid() and parent.transform then
		return (
			get_transform_world_rotation(parent.transform):GetConjugated() * world_rotation
		):GetNormalized()
	end

	return world_rotation:GetNormalized()
end

local function get_gizmo_definition(entity)
	if not is_gizmo_entity(entity) then return nil end

	local center, extent = get_entity_pivot(entity)

	if not center then return nil end

	local scale = get_gizmo_scale(center, extent)
	local combined_mode = state.mode == "combined"
	local handle_radius = scale * 0.12
	local axis_length = scale
	local move_cone_length = handle_radius * (MOVE_CONE_LENGTH_SCALE / 0.12)
	local move_cone_radius = handle_radius * MOVE_CONE_RADIUS_SCALE
	local move_shaft_radius = handle_radius * MOVE_SHAFT_RADIUS_SCALE
	local scale_box_size = handle_radius * SCALE_BOX_SIZE_SCALE
	local scale_stem_radius = handle_radius * SCALE_STEM_RADIUS_SCALE
	local ring_radius = combined_mode and scale * COMBINED_RING_RADIUS_SCALE or scale * 0.8
	local move_cone_base_distance = combined_mode and
		scale * COMBINED_MOVE_BASE_DISTANCE_SCALE or
		(
			axis_length - move_cone_length
		)
	local scale_box_min_distance = combined_mode and
		math.max(
			scale * COMBINED_SCALE_BOX_DISTANCE_SCALE,
			move_cone_base_distance + move_cone_length + scale_box_size * 0.55
		) or
		nil
	return {
		center = center,
		camera_vector = get_gizmo_camera_vector(center),
		combined_mode = combined_mode,
		axis_length = axis_length,
		handle_radius = handle_radius,
		ring_radius = ring_radius,
		move_cone_length = move_cone_length,
		move_cone_radius = move_cone_radius,
		move_cone_base_distance = move_cone_base_distance,
		move_cone_tip_distance = move_cone_base_distance + move_cone_length,
		move_cone_only = combined_mode,
		move_shaft_radius = move_shaft_radius,
		scale_box_size = scale_box_size,
		scale_box_min_distance = scale_box_min_distance,
		scale_box_only = combined_mode,
		scale_stem_radius = scale_stem_radius,
		axes = get_gizmo_axes(entity),
		scale_handles = get_scale_handles(entity),
	}
end

local function build_move_handles(gizmo_def)
	local handles = {}
	local unit_box = debug_draw.GetUnitBoxPolygon()
	local unit_cone = get_unit_cone_polygon()
	local cone_length = math.min(gizmo_def.move_cone_length, gizmo_def.axis_length * 0.35)
	local shaft_length = math.max(gizmo_def.axis_length - cone_length, gizmo_def.move_shaft_radius * 2)

	for _, axis in ipairs(gizmo_def.axes) do
		local direction, sign = get_camera_facing_axis_direction(axis.direction, gizmo_def.camera_vector)

		if gizmo_def.move_cone_only then
			handles[#handles + 1] = {
				kind = "move",
				axis_id = axis.id,
				sign = sign,
				direction = direction,
				center = gizmo_def.center,
				axis_length = gizmo_def.move_cone_tip_distance,
				color = axis.color,
				pick_shapes = {
					create_mesh_shape(
						unit_cone,
						gizmo_def.center + direction * gizmo_def.move_cone_base_distance,
						get_direction_rotation(direction),
						Vec3(gizmo_def.move_cone_radius, gizmo_def.move_cone_radius, cone_length)
					),
				},
			}
		else
			local shaft_center = gizmo_def.center + direction * (shaft_length * 0.5)
			local cone_base = gizmo_def.center + direction * (gizmo_def.axis_length - cone_length)
			handles[#handles + 1] = {
				kind = "move",
				axis_id = axis.id,
				sign = sign,
				direction = direction,
				center = gizmo_def.center,
				axis_length = gizmo_def.axis_length,
				color = axis.color,
				pick_shapes = {
					create_mesh_shape(
						unit_box,
						shaft_center,
						get_direction_rotation(direction),
						Vec3(gizmo_def.move_shaft_radius * 2, gizmo_def.move_shaft_radius * 2, shaft_length)
					),
					create_mesh_shape(
						unit_cone,
						cone_base,
						get_direction_rotation(direction),
						Vec3(gizmo_def.move_cone_radius, gizmo_def.move_cone_radius, cone_length)
					),
				},
			}
		end
	end

	return handles
end

local function build_scale_handles(gizmo_def)
	local handles = {}
	local unit_box = debug_draw.GetUnitBoxPolygon()

	for _, handle in ipairs(gizmo_def.scale_handles or {}) do
		local outward = handle.outward_direction or
			(
				handle.position - handle.anchor_position
			):GetNormalized()
		local bbox_distance = math.max((handle.position - gizmo_def.center):Dot(outward), 0)
		local display_distance = gizmo_def.scale_box_only and
			math.max(bbox_distance, gizmo_def.scale_box_min_distance or 0) or
			nil
		local display_position = gizmo_def.scale_box_only and
			(
				gizmo_def.center + outward * display_distance
			)
			or
			handle.position
		local drag_anchor_position = handle.anchor_position
		local stem_center = (display_position + drag_anchor_position) * 0.5
		local stem_rotation = get_direction_rotation(outward)
		local box_rotation = gizmo_def.scale_box_only and handle.surface_rotation or stem_rotation
		local pick_shapes = {}

		if not gizmo_def.scale_box_only then
			pick_shapes[#pick_shapes + 1] = create_mesh_shape(
				unit_box,
				stem_center,
				stem_rotation,
				Vec3(
					gizmo_def.scale_stem_radius * 2,
					gizmo_def.scale_stem_radius * 2,
					math.max(handle.axis_world_length, 1e-3)
				)
			)
		end

		pick_shapes[#pick_shapes + 1] = create_mesh_shape(
			unit_box,
			display_position,
			box_rotation,
			Vec3(gizmo_def.scale_box_size, gizmo_def.scale_box_size, gizmo_def.scale_box_size)
		)
		local next_handle = {
			kind = "scale",
			axis_id = handle.axis_id,
			sign = handle.sign,
			color = handle.color,
			face_position = handle.position,
			position = display_position,
			anchor_position = drag_anchor_position,
			drag_position = display_position,
			drag_anchor_position = drag_anchor_position,
			axis_world_length = handle.axis_world_length,
			outward_direction = outward,
			anchor_value = handle.anchor_value,
			pick_shapes = pick_shapes,
		}
		handles[#handles + 1] = next_handle
	end

	return handles
end

local function build_rotation_handles(gizmo_def)
	local handles = {}
	local unit_ring = get_unit_ring_polygon()

	for _, axis in ipairs(gizmo_def.axes) do
		handles[#handles + 1] = {
			kind = "rotate",
			axis_id = axis.id,
			direction = axis.direction,
			center = gizmo_def.center,
			radius = gizmo_def.ring_radius,
			color = axis.color,
			pick_shapes = {
				create_mesh_shape(
					unit_ring,
					gizmo_def.center,
					get_direction_rotation(axis.direction),
					Vec3(gizmo_def.ring_radius, gizmo_def.ring_radius, gizmo_def.ring_radius)
				),
			},
		}
	end

	handles[#handles + 1] = {
		kind = "rotate",
		axis_id = "view",
		direction = gizmo_def.camera_vector,
		center = gizmo_def.center,
		radius = gizmo_def.ring_radius * VIEW_ROTATION_RING_RADIUS_SCALE,
		color = axis_colors.view,
		is_camera_aligned = true,
		pick_shapes = {
			create_mesh_shape(
				unit_ring,
				gizmo_def.center,
				get_direction_rotation(gizmo_def.camera_vector),
				Vec3(
					gizmo_def.ring_radius * VIEW_ROTATION_RING_RADIUS_SCALE,
					gizmo_def.ring_radius * VIEW_ROTATION_RING_RADIUS_SCALE,
					gizmo_def.ring_radius * VIEW_ROTATION_RING_RADIUS_SCALE
				)
			),
		},
	}
	return handles
end

local function populate_gizmo_handles(gizmo_def)
	gizmo_def.move_handles = build_move_handles(gizmo_def)
	gizmo_def.scale_handles_3d = build_scale_handles(gizmo_def)
	gizmo_def.rotation_handles = build_rotation_handles(gizmo_def)
	return gizmo_def
end

get_active_gizmo_handles = function(gizmo_def)
	if state.mode == "move" then return gizmo_def.move_handles or {} end

	if state.mode == "scale" then return gizmo_def.scale_handles_3d or {} end

	if state.mode == "rotate" then return gizmo_def.rotation_handles or {} end

	local handles = {}

	for _, handle in ipairs(gizmo_def.rotation_handles or {}) do
		handles[#handles + 1] = handle
	end

	for _, handle in ipairs(gizmo_def.move_handles or {}) do
		handles[#handles + 1] = handle
	end

	for _, handle in ipairs(gizmo_def.scale_handles_3d or {}) do
		handles[#handles + 1] = handle
	end

	return handles
end

local function find_hovered_gizmo_handle_mesh(gizmo_def, window)
	local ray = get_mouse_world_ray(window)

	if not ray then return nil, nil end

	local best_handle
	local best_hit
	local best_distance = math.huge

	for _, handle in ipairs(get_active_gizmo_handles(gizmo_def)) do
		local hit = intersect_handle(ray, handle)

		if hit and hit.distance < best_distance then
			best_distance = hit.distance
			best_handle = handle
			best_hit = hit
		end
	end

	return best_handle, best_hit
end

local function find_hovered_gizmo_handle(entity)
	local gizmo_def = get_gizmo_definition(entity)

	if not gizmo_def then return nil end

	local window = system.GetWindow()

	if not window then return nil end

	local mouse_pos = window:GetMousePosition()
	populate_gizmo_handles(gizmo_def)
	local mesh_handle = find_hovered_gizmo_handle_mesh(gizmo_def, window)
	local screen_handle = find_hovered_gizmo_handle_screen(gizmo_def, mouse_pos)
	return mesh_handle or screen_handle
end

local function begin_gizmo_drag(handle)
	local entity = state.gizmo_entity

	if not (handle and is_gizmo_entity(entity)) then return nil end

	local window = system.GetWindow()

	if not window then return nil end

	local mouse_pos = window:GetMousePosition():Copy()

	if handle.kind == "move" then
		local start_screen = handle.start_screen or project_world_position(handle.center)
		local stop_screen = handle.stop_screen or
			project_world_position(handle.center + handle.direction * handle.axis_length)

		if not (start_screen and stop_screen) then return nil end

		local axis_screen = stop_screen - start_screen
		local axis_screen_length = axis_screen:GetLength()

		if axis_screen_length < 1e-5 then return nil end

		return {
			kind = "move",
			axis_id = handle.axis_id,
			entity = entity,
			axis_direction = handle.direction,
			start_mouse_position = mouse_pos,
			axis_screen_direction = axis_screen / axis_screen_length,
			axis_screen_length = axis_screen_length,
			axis_world_length = handle.axis_length,
			start_world_position = get_entity_world_position(entity),
		}
	end

	if handle.kind == "scale" then
		local start_screen = handle.anchor_screen or
			project_world_position(handle.drag_anchor_position or handle.anchor_position)
		local stop_screen = handle.handle_screen or
			project_world_position(handle.face_position or handle.drag_position or handle.position)

		if not (start_screen and stop_screen) then return nil end

		local axis_screen = stop_screen - start_screen
		local axis_screen_length = axis_screen:GetLength()

		if axis_screen_length < 1e-5 or handle.axis_world_length < 1e-5 then
			return nil
		end

		return {
			kind = "scale",
			axis_id = handle.axis_id,
			sign = handle.sign,
			entity = entity,
			last_mouse_position = mouse_pos,
			accumulated_outward_offset = 0,
			applied_outward_offset = 0,
		}
	end

	local center_screen = handle.center_screen or project_world_position(handle.center)

	if not center_screen then return nil end

	local start_mouse_vector = mouse_pos - center_screen
	local start_ring_vector = get_mouse_rotation_ring_vector(handle.center, handle.direction, handle.radius, mouse_pos, center_screen)

	if start_mouse_vector:GetLength() < 1e-5 and not start_ring_vector then
		return nil
	end

	return {
		kind = "rotate",
		axis_id = handle.axis_id,
		entity = entity,
		axis_direction = handle.direction,
		center_screen = center_screen,
		center = handle.center,
		radius = handle.radius,
		start_mouse_vector = start_mouse_vector:GetLength() >= 1e-5 and
			start_mouse_vector:GetNormalized() or
			nil,
		start_ring_vector = start_ring_vector,
		start_world_rotation = get_transform_world_rotation(entity.transform):Copy(),
	}
end

local function finish_gizmo_drag()
	if not state.active_drag then return end

	state.active_drag = nil
	notify_state_changed()
end

local function update_gizmo_drag()
	local drag = state.active_drag

	if not drag then return end

	if not is_gizmo_entity(drag.entity) then
		finish_gizmo_drag()
		return
	end

	local window = system.GetWindow()

	if not window then return end

	local mouse_pos = window:GetMousePosition()

	if drag.kind == "move" then
		local mouse_delta = mouse_pos - drag.start_mouse_position
		local offset = mouse_delta:GetDot(drag.axis_screen_direction) / drag.axis_screen_length * drag.axis_world_length

		if input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift") then
			offset = math.floor(offset / 0.25 + 0.5) * 0.25
		end

		set_entity_world_position(drag.entity, drag.start_world_position + drag.axis_direction * offset)
		return
	end

	if drag.kind == "scale" then
		local current_handle = get_scale_handle(drag.entity, drag.axis_id, drag.sign)

		if not current_handle or current_handle.axis_world_length < 1e-5 then return end

		local start_screen = project_world_position(current_handle.anchor_position)
		local stop_screen = project_world_position(current_handle.position)

		if not (start_screen and stop_screen) then return end

		local axis_screen = stop_screen - start_screen
		local axis_screen_length = axis_screen:GetLength()

		if axis_screen_length < 1e-5 then return end

		local mouse_delta = mouse_pos - drag.last_mouse_position
		local frame_outward_offset = mouse_delta:GetDot(axis_screen / axis_screen_length) / axis_screen_length * current_handle.axis_world_length
		local raw_outward_offset = drag.accumulated_outward_offset + frame_outward_offset
		local snapped_outward_offset = raw_outward_offset

		if input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift") then
			snapped_outward_offset = math.floor(raw_outward_offset / 0.25 + 0.5) * 0.25
		end

		local outward_offset = snapped_outward_offset - drag.applied_outward_offset
		local current_local_scale = drag.entity.transform:GetScale():Copy()
		local current_local_position = drag.entity.transform:GetPosition():Copy()
		local current_axis_scale = get_axis_value(current_local_scale, drag.axis_id)
		local local_axis_direction = transform_direction(drag.entity.transform:GetLocalMatrix(), get_axis_basis_vector(drag.axis_id))
		local size = drag.entity.transform:GetSize()
		local next_axis_length = math.max(current_handle.axis_world_length + outward_offset, 1e-3)
		local next_axis_scale = current_axis_scale * (next_axis_length / current_handle.axis_world_length)
		local next_local_scale = current_local_scale:Copy()
		set_axis_value(next_local_scale, drag.axis_id, next_axis_scale)
		local position_offset = local_axis_direction * (
				(
					current_axis_scale - next_axis_scale
				) * size * current_handle.anchor_value
			)
		drag.entity.transform:SetScale(next_local_scale)
		drag.entity.transform:SetPosition(current_local_position + position_offset)
		drag.last_mouse_position = mouse_pos:Copy()
		drag.accumulated_outward_offset = raw_outward_offset
		drag.applied_outward_offset = snapped_outward_offset
		return
	end

	local current_ring_vector = get_mouse_rotation_ring_vector(drag.center, drag.axis_direction, drag.radius, mouse_pos, drag.center_screen)
	local angle

	if drag.start_ring_vector and current_ring_vector then
		angle = math.atan2(
			drag.start_ring_vector.x * current_ring_vector.y - drag.start_ring_vector.y * current_ring_vector.x,
			drag.start_ring_vector:GetDot(current_ring_vector)
		)
	else
		local current_mouse_vector = mouse_pos - drag.center_screen

		if not drag.start_mouse_vector or current_mouse_vector:GetLength() < 1e-5 then
			return
		end

		current_mouse_vector = current_mouse_vector:GetNormalized()
		angle = math.atan2(
			drag.start_mouse_vector.x * current_mouse_vector.y - drag.start_mouse_vector.y * current_mouse_vector.x,
			drag.start_mouse_vector:GetDot(current_mouse_vector)
		)
	end

	if input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift") then
		local unsnapped_world_rotation = (
			build_axis_rotation(drag.axis_direction, angle) * drag.start_world_rotation
		):GetNormalized()

		if state.space == "local" and drag.axis_id ~= "view" then
			local local_axis = get_axis_basis_vector(drag.axis_id)
			local unsnapped_local_rotation = get_entity_local_rotation_from_world_rotation(drag.entity, unsnapped_world_rotation)
			local twist_angle = get_quat_twist_angle(unsnapped_local_rotation, local_axis)
			local swing = (
				unsnapped_local_rotation * QuatFromAxis(twist_angle, local_axis):GetConjugated()
			):GetNormalized()
			local snapped_angle = math.rad(
				math.floor(math.deg(twist_angle) / ROTATION_SNAP_STEP_DEGREES + 0.5) * ROTATION_SNAP_STEP_DEGREES
			)
			drag.entity.transform:SetRotation((swing * QuatFromAxis(snapped_angle, local_axis)):GetNormalized())
		else
			local twist_angle = get_quat_twist_angle(unsnapped_world_rotation, drag.axis_direction)
			local swing = (
				QuatFromAxis(twist_angle, drag.axis_direction):GetConjugated() * unsnapped_world_rotation
			):GetNormalized()
			local snapped_angle = math.rad(
				math.floor(math.deg(twist_angle) / ROTATION_SNAP_STEP_DEGREES + 0.5) * ROTATION_SNAP_STEP_DEGREES
			)
			set_entity_world_rotation(
				drag.entity,
				(QuatFromAxis(snapped_angle, drag.axis_direction) * swing):GetNormalized()
			)
		end

		return
	end

	local next_world_rotation = (
		build_axis_rotation(drag.axis_direction, angle) * drag.start_world_rotation
	):GetNormalized()
	set_entity_world_rotation(drag.entity, next_world_rotation)
end

local function draw_move_gizmo(gizmo_def)
	for _, handle in ipairs(gizmo_def.move_handles or build_move_handles(gizmo_def)) do
		local sign_matches_hover = handle.sign == nil or
			(
				state.hovered_handle and
				state.hovered_handle.sign == handle.sign
			)
		local sign_matches_active = handle.sign == nil or
			(
				state.active_drag and
				state.active_drag.sign == handle.sign
			)
		local is_hovered = state.hovered_handle and
			state.hovered_handle.kind == "move" and
			state.hovered_handle.axis_id == handle.axis_id and
			sign_matches_hover
		local is_active = state.active_drag and
			state.active_drag.kind == "move" and
			state.active_drag.axis_id == handle.axis_id and
			sign_matches_active
		local color = handle.color
		local handle_suffix = handle.sign and (handle.sign > 0 and "positive" or "negative") or "axis"

		if is_active then
			color = brighten_color(color, 1.35)
		elseif is_hovered then
			color = brighten_color(color, 1.18)
		end

		for shape_index, shape in ipairs(handle.pick_shapes or {}) do
			local matrix = get_shape_matrix(shape)

			if matrix then
				local draw_color = get_debug_draw_color(color)
				debug_draw.DrawMesh{
					id = string.format("%s_move_%s_%s_%d", listener_key, handle.axis_id, handle_suffix, shape_index),
					polygon3d = shape.polygon,
					matrix = matrix,
					color = draw_color,
					draw_direct = true,
					ignore_z = true,
					translucent = draw_color.a < 1,
					double_sided = true,
				}
			end
		end
	end
end

local function draw_scale_gizmo(gizmo_def)
	for _, handle in ipairs(gizmo_def.scale_handles_3d or build_scale_handles(gizmo_def)) do
		local handle_suffix = handle.sign > 0 and "positive" or "negative"
		local is_hovered = state.hovered_handle and
			state.hovered_handle.kind == "scale" and
			state.hovered_handle.axis_id == handle.axis_id and
			state.hovered_handle.sign == handle.sign
		local is_active = state.active_drag and
			state.active_drag.kind == "scale" and
			state.active_drag.axis_id == handle.axis_id and
			state.active_drag.sign == handle.sign
		local color = handle.color

		if is_active then
			color = brighten_color(color, 1.35)
		elseif is_hovered then
			color = brighten_color(color, 1.18)
		end

		for shape_index, shape in ipairs(handle.pick_shapes or {}) do
			local matrix = get_shape_matrix(shape)

			if matrix then
				local draw_color = get_debug_draw_color(color)
				debug_draw.DrawMesh{
					id = string.format("%s_scale_%s_%s_%d", listener_key, handle.axis_id, handle_suffix, shape_index),
					polygon3d = shape.polygon,
					matrix = matrix,
					color = draw_color,
					draw_direct = true,
					ignore_z = true,
					translucent = draw_color.a < 1,
					double_sided = true,
				}
			end
		end
	end
end

local function draw_rotation_gizmo(gizmo_def)
	for _, handle in ipairs(gizmo_def.rotation_handles or build_rotation_handles(gizmo_def)) do
		local is_hovered = state.hovered_handle and
			state.hovered_handle.kind == "rotate" and
			state.hovered_handle.axis_id == handle.axis_id
		local is_active = state.active_drag and
			state.active_drag.kind == "rotate" and
			state.active_drag.axis_id == handle.axis_id
		local color = handle.color

		if is_active then
			color = brighten_color(color, 1.35)
		elseif is_hovered then
			color = brighten_color(color, 1.18)
		end

		for shape_index, shape in ipairs(handle.pick_shapes or {}) do
			local matrix = get_shape_matrix(shape)

			if matrix then
				local draw_color = get_debug_draw_color(color)
				debug_draw.DrawMesh{
					id = string.format("%s_rotate_%s_%d", listener_key, handle.axis_id, shape_index),
					polygon3d = shape.polygon,
					matrix = matrix,
					clip_plane_origin = not handle.is_camera_aligned and gizmo_def.center or nil,
					clip_plane_normal = not handle.is_camera_aligned and gizmo_def.camera_vector or nil,
					color = draw_color,
					draw_direct = true,
					ignore_z = true,
					translucent = draw_color.a < 1,
					double_sided = true,
				}
			end
		end
	end
end

local function draw_gizmo()
	local entity = state.gizmo_entity
	local gizmo_def = get_gizmo_definition(entity)

	if not gizmo_def then
		if
			state.gizmo_entity ~= nil or
			state.hovered_handle ~= nil or
			state.active_drag ~= nil
		then
			state.gizmo_entity = nil
			state.hovered_handle = nil
			state.active_drag = nil
			notify_state_changed()
		end

		return
	end

	populate_gizmo_handles(gizmo_def)

	if not gizmo_def.combined_mode then
		debug_draw.DrawSphere{
			id = listener_key .. "_center",
			position = gizmo_def.center,
			radius = gizmo_def.handle_radius * 0.55,
			color = Color(1, 1, 1, 1),
			draw_direct = true,
			ignore_z = true,
			translucent = false,
		}
	end

	if state.mode == "move" then
		draw_move_gizmo(gizmo_def)
	elseif state.mode == "scale" then
		draw_scale_gizmo(gizmo_def)
	elseif state.mode == "combined" then
		draw_rotation_gizmo(gizmo_def)
		draw_move_gizmo(gizmo_def)
		draw_scale_gizmo(gizmo_def)
	else
		draw_rotation_gizmo(gizmo_def)
	end
end

local function draw_overlay()
	if state.gizmo_entity ~= nil then draw_gizmo() end
end

local function handle_gizmo_mouse_input(button, press)
	if button ~= "button_1" then return end

	if press then
		if is_ui_hovering() then return end

		local handle = state.hovered_handle or find_hovered_gizmo_handle(state.gizmo_entity)

		if not handle then return end

		local drag = begin_gizmo_drag(handle)

		if not drag then return end

		state.active_drag = drag
		state.hovered_handle = nil
		notify_state_changed()
		return true
	end

	if state.active_drag then
		finish_gizmo_drag()
		return true
	end
end

local function update_hovered_handle()
	if state.active_drag then
		update_gizmo_drag()
		return
	end

	if is_ui_hovering() then
		state.hovered_handle = nil
		return
	end

	state.hovered_handle = find_hovered_gizmo_handle(state.gizmo_entity)
end

function gizmo.EnableGizmo(entity)
	local next_entity = is_gizmo_entity(entity) and entity or nil

	if state.gizmo_entity == next_entity then return next_entity end

	state.gizmo_entity = next_entity
	state.hovered_handle = nil
	state.active_drag = nil
	notify_state_changed()
	return next_entity
end

function gizmo.DisableGizmo()
	return gizmo.EnableGizmo(nil)
end

function gizmo.SetMode(mode)
	if mode ~= "move" and mode ~= "rotate" and mode ~= "scale" and mode ~= "combined" then
		return state.mode
	end

	if state.mode == mode then return state.mode end

	state.mode = mode
	state.hovered_handle = nil
	state.active_drag = nil
	notify_state_changed()
	return state.mode
end

function gizmo.GetMode()
	return state.mode
end

function gizmo.SetSpace(space)
	if space ~= "local" and space ~= "world" then return state.space end

	if state.space == space then return state.space end

	state.space = space
	state.hovered_handle = nil
	state.active_drag = nil
	notify_state_changed()
	return state.space
end

function gizmo.GetSpace()
	return state.space
end

function gizmo.GetStatus()
	return {
		mode = state.mode,
		space = state.space,
		hovered_handle = state.hovered_handle,
		active_drag = state.active_drag,
		gizmo_entity = state.gizmo_entity,
	}
end

function gizmo.SetStateChangedCallback(owner, callback)
	state.callback_owner = owner
	state.state_changed = callback
end

function gizmo.Clear(owner)
	if owner and state.callback_owner ~= owner then return end

	state.gizmo_entity = nil
	state.hovered_handle = nil
	state.active_drag = nil

	if not owner or state.callback_owner == owner then
		state.callback_owner = nil
		state.state_changed = nil
	end

	notify_state_changed()
end

event.AddListener("Draw3DForwardOverlay", listener_key, draw_overlay)
event.AddListener("Update", listener_key .. "_update", update_hovered_handle)

event.AddListener(
	"WindowMouseInput",
	listener_key .. "_window_mouse",
	function(window, button, press)
		return handle_gizmo_mouse_input(button, press)
	end,
	{priority = 101}
)

return gizmo
