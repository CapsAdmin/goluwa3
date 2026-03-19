local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/ecs/entity.lua")
local debug_enabled = false
local overlay_font = fonts.New{Weight = "Regular", Size = 12}
local identity_rotation = Quat(0, 0, 0, 1)
local zero_vec = Vec3(0, 0, 0)
local unit_box_poly
local unit_sphere_poly
local convex_mesh_cache = setmetatable({}, {__mode = "k"})
local polyhedron_mesh_cache = setmetatable({}, {__mode = "k"})
local debug_entries = setmetatable({}, {__mode = "k"})
local debug_materials = {}
local rigid_body_component
local shape_colors = {
	sphere = Color(0.25, 0.85, 1.0, 0.35),
	box = Color(1.0, 0.7, 0.2, 0.35),
	convex = Color(0.35, 1.0, 0.45, 0.35),
	compound = Color(1.0, 0.3, 0.9, 0.25),
}

local function get_shape_color(shape_type)
	return shape_colors[shape_type] or Color(1, 0.2, 0.2, 0.35)
end

local function format_number(value)
	if type(value) ~= "number" then return tostring(value) end

	if math.abs(value) < 0.0005 then value = 0 end

	return string.format("%.2f", value)
end

local function format_vec(vec)
	if not vec then return "0.00, 0.00, 0.00" end

	return string.format(
		"%s, %s, %s",
		format_number(vec.x or 0),
		format_number(vec.y or 0),
		format_number(vec.z or 0)
	)
end

local function yes_no(value)
	return value and "yes" or "no"
end

local function get_debug_shape_summary(body)
	local shape = body:GetPhysicsShape() or body.Shape
	local shape_type = body:GetShapeType() or
		shape and
		shape.GetTypeName and
		shape:GetTypeName()
		or
		"unknown"
	local colliders = body.GetColliders and body:GetColliders() or {}

	if shape_type == "box" and shape and shape.GetSize then
		return string.format("box (%s)", format_vec(shape:GetSize()))
	end

	if shape_type == "sphere" and shape and shape.GetRadius then
		return string.format("sphere (r=%s)", format_number(shape:GetRadius()))
	end

	if shape_type == "capsule" and shape and shape.GetRadius and shape.GetHeight then
		return string.format(
			"capsule (r=%s, h=%s)",
			format_number(shape:GetRadius()),
			format_number(shape:GetHeight())
		)
	end

	if shape_type == "convex" and shape and shape.GetResolvedHull then
		local hull = shape:GetResolvedHull(body)

		if hull and hull.vertices then
			return string.format("convex (%d verts)", #hull.vertices)
		end
	end

	if shape_type == "compound" then
		local child_count = shape and shape.GetChildren and #(shape:GetChildren() or {}) or #colliders
		return string.format("compound (%d parts)", child_count)
	end

	if shape_type == "mesh" then return "mesh collider" end

	return tostring(shape_type)
end

local function get_debug_snapshot(body)
	local owner = body:GetOwner()
	local velocity = body:GetVelocity()
	local angular_velocity = body:GetAngularVelocity()
	local position = body:GetPosition()
	local colliders = body.GetColliders and body:GetColliders() or {}
	return {
		owner = owner,
		owner_name = owner and owner.Name or "unnamed",
		motion_type = body:GetMotionType(),
		shape = get_debug_shape_summary(body),
		collider_count = #colliders,
		mass = body:GetMass(),
		computed_mass = body.ComputedMass or 0,
		automatic_mass = body:GetAutomaticMass(),
		awake = body:GetAwake(),
		grounded = body:GetGrounded(),
		friction = body:GetFriction(),
		restitution = body:GetRestitution(),
		gravity_scale = body:GetGravityScale(),
		linear_speed = velocity and velocity.GetLength and velocity:GetLength() or 0,
		angular_speed = angular_velocity and
			angular_velocity.GetLength and
			angular_velocity:GetLength() or
			0,
		position = position and position.Copy and position:Copy() or position,
		velocity = velocity and velocity.Copy and velocity:Copy() or velocity,
		angular_velocity = angular_velocity and
			angular_velocity.Copy and
			angular_velocity:Copy() or
			angular_velocity,
	}
end

local function get_look_body_hit()
	local cam = render3d.GetCamera()

	if not cam then return nil, nil end

	local hit = physics.Trace(
		cam:GetPosition(),
		cam:GetRotation():GetForward(),
		4096,
		nil,
		nil,
		{
			UseRenderMeshes = false,
			IgnoreRigidBodies = false,
			IgnoreKinematicBodies = false,
		}
	)
	local body = hit and (hit.rigid_body or hit.entity and hit.entity.rigid_body) or nil
	return body, hit
end

local function build_overlay_lines(body, hit)
	local snapshot = body and get_debug_snapshot(body) or nil

	if not snapshot then return nil end

	local lines = {
		"Rigid body",
		"Entity: " .. tostring(snapshot.owner_name or "unnamed"),
	}

	if hit and hit.distance then
		lines[#lines + 1] = "Distance: " .. format_number(hit.distance)
	end

	lines[#lines + 1] = string.format(
		"Mode: %s | Awake: %s | Grounded: %s",
		tostring(snapshot.motion_type or "unknown"),
		yes_no(snapshot.awake),
		yes_no(snapshot.grounded)
	)
	lines[#lines + 1] = "Shape: " .. tostring(snapshot.shape or "unknown")
	lines[#lines + 1] = string.format(
		"Mass: %s (%s)",
		format_number(snapshot.mass or 0),
		snapshot.automatic_mass and "auto" or "manual"
	)

	if snapshot.automatic_mass == false then
		lines[#lines + 1] = "Computed mass: " .. format_number(snapshot.computed_mass or 0)
		lines[#lines + 1] = string.format(
			"Friction: %s | Restitution: %s",
			format_number(snapshot.friction or 0),
			format_number(snapshot.restitution or 0)
		)
	else
		lines[#lines + 1] = string.format(
			"Friction: %s | Speed: %s",
			format_number(snapshot.friction or 0),
			format_number(snapshot.linear_speed or 0)
		)
	end

	lines[#lines + 1] = "Angular speed: " .. format_number(snapshot.angular_speed or 0)
	lines[#lines + 1] = "Position: " .. format_vec(snapshot.position)
	return lines
end

local function draw_hovered_body_info()
	if not debug_enabled then return end

	local body, hit = get_look_body_hit()

	if not body then return end

	local lines = build_overlay_lines(body, hit)

	if not (lines and lines[1]) then return end

	fonts.SetFont(overlay_font)
	render2d.SetTexture(nil)
	local font = fonts.GetFont()
	local x = 12
	local y = 52
	local line_gap = 4
	local padding = 8
	local width = 0
	local height = padding * 2

	for _, line in ipairs(lines) do
		local line_width, line_height = font:GetTextSize(line)
		width = math.max(width, line_width)
		height = height + line_height + line_gap
	end

	render2d.SetColor(0, 0, 0, 0.72)
	render2d.DrawRect(x - padding, y - padding, width + padding * 2, height)

	for i, line in ipairs(lines) do
		local _, line_height = font:GetTextSize(line)
		render2d.SetColor(i == 1 and 0.9 or 1, i == 1 and 0.95 or 1, i == 1 and 1 or 1, 1)
		font:DrawText(line, x, y)
		y = y + line_height + line_gap
	end
end

local function get_debug_material(shape_type)
	local material = debug_materials[shape_type]

	if material then return material end

	material = Material.New{
		AlbedoTexture = nil,
		ColorMultiplier = get_shape_color(shape_type),
		EmissiveMultiplier = Color(0.15, 0.15, 0.15, 1.0),
		AlbedoAlphaIsEmissive = true,
		IgnoreZ = true,
		Translucent = true,
		DoubleSided = true,
		MetallicMultiplier = 0,
		RoughnessMultiplier = 1,
	}
	debug_materials[shape_type] = material
	return material
end

local function make_matrix(position, rotation, scale)
	local m = Matrix44():Identity()
	m:SetRotation(rotation or identity_rotation)

	if scale then m:Scale(scale.x, scale.y, scale.z) end

	m:SetTranslation(position.x, position.y, position.z)
	return m
end

local function get_unit_box_poly()
	if unit_box_poly then return unit_box_poly end

	local poly = Polygon3D.New()
	poly:CreateCube(0.5)
	poly:Upload()
	unit_box_poly = poly
	return unit_box_poly
end

local function get_unit_sphere_poly()
	if unit_sphere_poly then return unit_sphere_poly end

	local poly = Polygon3D.New()
	poly:CreateSphere(1, 18, 10)
	poly:Upload()
	unit_sphere_poly = poly
	return unit_sphere_poly
end

local function build_convex_poly(hull)
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

local function build_polyhedron_poly(polyhedron_data)
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

local function add_primitive(model, polygon3d, shape_type, local_matrix)
	if not polygon3d then return end

	model:AddPrimitive(polygon3d, get_debug_material(shape_type))
	local primitive = model.Primitives[#model.Primitives]
	primitive.local_matrix = local_matrix
end

local function append_shape(model, body, shape, local_matrix)
	if not shape then return end

	local shape_type = shape.GetTypeName and shape:GetTypeName() or "unknown"

	if shape_type == "sphere" then
		local radius = shape:GetRadius()
		add_primitive(
			model,
			get_unit_sphere_poly(),
			shape_type,
			make_matrix(zero_vec, identity_rotation, Vec3(radius, radius, radius)):GetMultiplied(local_matrix)
		)
		return
	end

	if shape_type == "box" then
		add_primitive(model, build_polyhedron_poly(shape:GetPolyhedron()), shape_type, local_matrix)
		return
	end

	if shape_type == "convex" then
		add_primitive(model, build_convex_poly(shape:GetResolvedHull(body)), shape_type, local_matrix)
		return
	end

	if shape_type == "mesh" then
		for _, poly in ipairs(shape.GetMeshPolygons and shape:GetMeshPolygons(body) or {}) do
			add_primitive(model, poly, shape_type, local_matrix)
		end

		return
	end

	if shape_type == "compound" then
		for _, child in ipairs(shape:GetChildren() or {}) do
			local child_matrix = make_matrix(child.Position or zero_vec, child.Rotation or identity_rotation)
			append_shape(model, body, child.Shape, child_matrix:GetMultiplied(local_matrix))
		end

		return
	end

	add_primitive(
		model,
		build_convex_poly(shape.GetResolvedHull and shape:GetResolvedHull(body) or nil),
		shape_type,
		local_matrix
	)
end

local function get_shape_signature(body)
	local shape = body:GetPhysicsShape() or body.Shape
	local shape_type = body:GetShapeType()
	local hull = shape and shape.GetResolvedHull and shape:GetResolvedHull(body) or nil
	local children = shape and shape.GetChildren and shape:GetChildren() or nil
	return shape, shape_type, hull, children and #children or 0
end

local function sync_debug_transform(body, debug_ent)
	if not (debug_ent and debug_ent.transform) then return end

	local position = body.GetPosition and body:GetPosition() or zero_vec
	local rotation = body.GetRotation and body:GetRotation() or identity_rotation
	local owner = body.Owner

	if owner and owner.transform then
		local render_position, render_rotation = owner.transform:GetRenderPositionRotation()
		position = render_position or owner.transform:GetPosition() or position
		rotation = render_rotation or owner.transform:GetRotation() or rotation
	end

	debug_ent.transform:SetPosition(position:Copy())
	debug_ent.transform:SetRotation(rotation:Copy())
	debug_ent.transform:SetScale(Vec3(1, 1, 1))
end

local function rebuild_debug_model(body, entry)
	local owner = body.Owner

	if not (owner and owner.IsValid and owner:IsValid()) then return end

	local debug_ent = entry.entity

	if not (debug_ent and debug_ent.IsValid and debug_ent:IsValid()) then
		debug_ent = Entity.New{Name = "physics_debug_mesh"}
		debug_ent.PhysicsNoCollision = true
		debug_ent:AddComponent("transform")
		debug_ent.transform:SetPosition(Vec3(0, 0, 0))
		debug_ent.transform:SetRotation(identity_rotation:Copy())
		debug_ent.transform:SetScale(Vec3(1, 1, 1))
		debug_ent:AddComponent("model", {
			UseOcclusionCulling = false,
			CastShadows = false,
		})
		entry.entity = debug_ent
	end

	sync_debug_transform(body, debug_ent)
	debug_ent.model:RemovePrimitives()
	append_shape(debug_ent.model, body, body:GetPhysicsShape() or body.Shape, Matrix44():Identity())
	debug_ent.model:BuildAABB()
	debug_ent.model:SetVisible(debug_enabled)
	entry.shape, entry.shape_type, entry.hull, entry.child_count = get_shape_signature(body)
	entry.owner = owner
end

local function ensure_debug_model(body)
	local entry = debug_entries[body]

	if not entry then
		entry = {}
		debug_entries[body] = entry
	end

	local shape, shape_type, hull, child_count = get_shape_signature(body)
	local debug_ent = entry.entity

	if
		not debug_ent or
		not debug_ent.IsValid or
		not debug_ent:IsValid()
		or
		entry.owner ~= body.Owner or
		entry.shape ~= shape or
		entry.shape_type ~= shape_type or
		entry.hull ~= hull or
		entry.child_count ~= child_count
	then
		rebuild_debug_model(body, entry)
	elseif debug_ent.model:GetVisible() ~= debug_enabled then
		debug_ent.model:SetVisible(debug_enabled)
	end

	sync_debug_transform(body, entry.entity)
end

local function cleanup_removed_bodies()
	for body, entry in pairs(debug_entries) do
		if not (body and body.Owner and body.Owner.IsValid and body.Owner:IsValid()) then
			if entry.entity and entry.entity.IsValid and entry.entity:IsValid() then
				entry.entity:Remove()
			end

			debug_entries[body] = nil
		end
	end
end

event.AddListener("KeyInput", "physics_debug_toggle", function(key, press)
	if not press then return end

	if key == "n" then
		debug_enabled = not debug_enabled

		for _, entry in pairs(debug_entries) do
			if entry.entity and entry.entity.IsValid and entry.entity:IsValid() then
				entry.entity.model:SetVisible(debug_enabled)
			end
		end

		if debug_enabled then
			event.AddListener("Draw2D", "physics_debug_hover_info", draw_hovered_body_info)
		else
			event.RemoveListener("Draw2D", "physics_debug_hover_info")
		end

		print("[Physics Debug] " .. (debug_enabled and "Enabled" or "Disabled"))

		if debug_enabled then
			local RigidBodyComponent = import("goluwa/physics/rigid_body.lua")

			event.AddListener("Update", "physics_debug_sync", function()
				cleanup_removed_bodies()

				for _, body in ipairs(RigidBodyComponent.Instances or {}) do
					if not (body and body.Owner and body.Owner.IsValid and body.Owner:IsValid()) then
						goto continue
					end

					if not body.CollisionEnabled then goto continue end

					if body.Owner.PhysicsNoCollision or body.Owner.NoPhysicsCollision then
						goto continue
					end

					ensure_debug_model(body)

					::continue::
				end
			end)
		else
			event.RemoveListener("Update", "physics_debug_sync")
		end
	end
end)
