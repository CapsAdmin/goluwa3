local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Entity = import("goluwa/ecs/entity.lua")
local debug_enabled = false
local identity_rotation = Quat(0, 0, 0, 1)
local zero_vec = Vec3(0, 0, 0)
local debug_entries = setmetatable({}, {__mode = "k"})
local body_overlay_states = setmetatable({}, {__mode = "k"})
local rigid_body_component
local get_debug_snapshot
local focused_body
local overlay_config = {
	contact_marker_radius = 4,
	contact_normal_length = 0.35,
	hit_marker_radius = 0.05,
	hit_normal_length = 0.5,
	contact_draw_limit = 6,
	partner_draw_limit = 3,
	partner_link_limit = 3,
	label_offset = 24,
	max_distance = 2200,
	transition_window = 1.2,
	debug_draw_time = 0.12,
	broadphase_alpha = 0.12,
}

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

local function copy_vec(vec, fallback)
	if vec and vec.Copy then return vec:Copy() end

	return fallback and fallback:Copy() or Vec3(0, 0, 0)
end

local function get_body_debug_id(body)
	return tostring(body)
end

local function get_local_player_entity()
	local world = Entity.World

	if world and world.GetKeyed then
		local rig = world:GetKeyed("player_camera_rig")

		if rig and rig.IsValid and rig:IsValid() then return rig end
	end

	return nil
end

local function get_body_render_position_rotation(body)
	local position = body.GetPosition and body:GetPosition() or zero_vec
	local rotation = body.GetRotation and body:GetRotation() or identity_rotation
	local owner = body.Owner

	if owner and owner.transform then
		local render_position, render_rotation = owner.transform:GetRenderPositionRotation()
		position = render_position or owner.transform:GetPosition() or position
		rotation = render_rotation or owner.transform:GetRotation() or rotation
	end

	return position, rotation
end

local function get_world_up()
	local up = physics.Up
	return up and up.Copy and up:Copy() or Vec3(0, 1, 0)
end

local function get_body_label_height(body)
	local shape = body.GetPhysicsShape and body:GetPhysicsShape() or body.Shape
	local shape_type = body.GetShapeType and body:GetShapeType() or nil

	if shape_type == "sphere" and shape and shape.GetRadius then
		return shape:GetRadius() + 0.16
	end

	if shape_type == "box" and shape and shape.GetSize then
		local size = shape:GetSize()
		return math.max(size.y * 0.6, 0.2) + 0.08
	end

	if shape_type == "capsule" and shape and shape.GetRadius and shape.GetHeight then
		return shape:GetRadius() + shape:GetHeight() * 0.5 + 0.16
	end

	if shape_type == "compound" then return 0.55 end

	return 0.4
end

local function get_body_label_anchor(body)
	local position = get_body_render_position_rotation(body)
	return position + get_world_up() * get_body_label_height(body)
end

local function get_body_overlay_state(body, awake)
	local state = body_overlay_states[body]

	if not state then
		state = {
			awake = awake,
			transition_label = awake and "wake" or "sleep",
			transition_started = os.clock(),
		}
		body_overlay_states[body] = state
		return state
	end

	if state.awake ~= awake then
		state.awake = awake
		state.transition_label = awake and "wake" or "sleep"
		state.transition_started = os.clock()
	end

	return state
end

local function get_transition_text(state)
	if not (state and state.transition_started and state.transition_label) then
		return nil
	end

	local elapsed = os.clock() - state.transition_started

	if elapsed > overlay_config.transition_window then return nil end

	return string.format("%s %.2fs", state.transition_label, elapsed)
end

local function get_awake_color(snapshot)
	if snapshot.awake then return 0.97, 0.84, 0.35 end

	return 0.52, 0.72, 1.0
end


local function get_pair_manifold(body_a, body_b)
	local solver = physics.solver

	if not (solver and solver.PersistentManifolds) then return nil end

	local row = solver.PersistentManifolds[body_a]

	if row and row[body_b] then return row[body_b] end

	row = solver.PersistentManifolds[body_b]
	return row and row[body_a] or nil
end

local function build_pair_contact_markers(body_a, body_b, manifold_data, normal)
	local markers = {}

	for _, contact in ipairs(manifold_data and manifold_data.contacts or {}) do
		local point_a = body_a:LocalToWorld(contact.local_point_a)
		local point_b = body_b:LocalToWorld(contact.local_point_b)
		markers[#markers + 1] = {
			position = (point_a + point_b) * 0.5,
			normal = normal,
			normal_impulse = contact.normal_impulse or 0,
		}
	end

	return markers
end

local function collect_body_contacts(body)
	local contacts = {}
	local collision_pairs = physics.collision_pairs

	if not collision_pairs then return contacts end
	local seen_pairs = setmetatable({}, {__mode = "k"})
	local seen_world = setmetatable({}, {__mode = "k"})

	local function append_pair_contacts(entries)
		for _, pair in ipairs(entries or {}) do
			if not seen_pairs[pair] and (pair.body_a == body or pair.body_b == body) then
				seen_pairs[pair] = true
				local other_body = pair.body_a == body and pair.body_b or pair.body_a
				local normal = pair.normal and copy_vec(pair.normal, zero_vec) or Vec3(0, 1, 0)

				if pair.body_b == body then normal = normal * -1 end

				local manifold_data = get_pair_manifold(pair.body_a, pair.body_b)
				local markers = build_pair_contact_markers(pair.body_a, pair.body_b, manifold_data, normal)
				contacts[#contacts + 1] = {
					kind = "body",
					other_body = other_body,
					other_name = other_body and other_body.Owner and other_body.Owner.Name or "body",
					normal = normal,
					overlap = pair.overlap or 0,
					contact_count = #(manifold_data and manifold_data.contacts or {}),
					markers = markers,
				}
			end
		end
	end

	local function append_world_contacts(entries)
		for _, entry in ipairs(entries or {}) do
			if not seen_world[entry] and entry.body == body then
				seen_world[entry] = true
				contacts[#contacts + 1] = {
					kind = "world",
					other_name = entry.entity and entry.entity.Name or "world",
					normal = entry.normal and copy_vec(entry.normal, zero_vec) or Vec3(0, 1, 0),
					overlap = entry.overlap or 0,
					contact_count = 1,
					markers = entry.hit and
						entry.hit.position and
						{
							{
								position = entry.hit.position:Copy(),
								normal = entry.normal and copy_vec(entry.normal, zero_vec) or Vec3(0, 1, 0),
								normal_impulse = 0,
							},
						} or
						{},
				}
			end
		end
	end

	append_pair_contacts(collision_pairs.PreviousCollisionEntries)
	append_pair_contacts(collision_pairs.CurrentCollisionEntries)
	append_world_contacts(collision_pairs.PreviousWorldCollisionEntries)
	append_world_contacts(collision_pairs.CurrentWorldCollisionEntries)

	table.sort(contacts, function(a, b)
		return (a.overlap or 0) > (b.overlap or 0)
	end)

	return contacts
end

local function get_contact_marker_total(contacts)
	local total = 0

	for _, entry in ipairs(contacts) do
		total = total + math.max(entry.contact_count or 0, 1)
	end

	return total
end

local function get_partner_badge_lines(body, contact)
	if not contact.other_body then return nil end

	local snapshot = get_debug_snapshot(contact.other_body)
	return {
		tostring(contact.other_name or "body"),
		string.format(
			"%s | v %s",
			snapshot.awake and "awake" or "sleep",
			format_number(snapshot.linear_speed or 0)
		),
	}
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

function get_debug_snapshot(body)
	local owner = body:GetOwner()
	local velocity = body:GetVelocity()
	local angular_velocity = body:GetAngularVelocity()
	local position = body:GetPosition()
	local colliders = body.GetColliders and body:GetColliders() or {}
	local broadphase = body.GetBroadphaseAABB and body:GetBroadphaseAABB() or nil
	local overlay_state = get_body_overlay_state(body, body:GetAwake())
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
		collision_enabled = body:GetCollisionEnabled(),
		collision_group = body:GetCollisionGroup(),
		collision_mask = body:GetCollisionMask(),
		friction = body:GetFriction(),
		restitution = body:GetRestitution(),
		gravity_scale = body:GetGravityScale(),
		sleep_timer = body.SleepTimer or 0,
		wake_grace_timer = body.WakeGraceTimer or 0,
		ground_normal = body.GetGroundNormal and body:GetGroundNormal() or Vec3(0, 1, 0),
		ground_body = body.GetGroundBody and body:GetGroundBody() or nil,
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
		broadphase = broadphase,
		transition = get_transition_text(overlay_state),
	}
end

local function get_look_body_hit()
	local cam = render3d.GetCamera()

	if not cam then return nil, nil end

	local origin = cam:GetPosition()
	local ignore_entity = get_local_player_entity()
	local hit = physics.Trace(
		origin,
		cam:GetRotation():GetForward(),
		4096,
		ignore_entity,
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

local function build_focus_overlay_lines(body, snapshot, hit, contacts)
	local top_contact = contacts[1]
	local lines = {
		tostring(snapshot.owner_name or "rigid body"),
		string.format(
			"%s | %s | grounded %s",
			tostring(snapshot.motion_type or "unknown"),
			snapshot.awake and "awake" or "sleep",
			yes_no(snapshot.grounded)
		),
		string.format(
			"v %s | %s",
			format_number(snapshot.linear_speed or 0),
			format_vec(snapshot.velocity)
		),
		string.format(
			"w %s | %s",
			format_number(snapshot.angular_speed or 0),
			format_vec(snapshot.angular_velocity)
		),
		string.format(
			"contacts %d | markers %d | sleep %s",
			#contacts,
			get_contact_marker_total(contacts),
			format_number(snapshot.sleep_timer or 0)
		),
		string.format(
			"group %s | mask %s | collide %s",
			tostring(snapshot.collision_group),
			tostring(snapshot.collision_mask),
			yes_no(snapshot.collision_enabled)
		),
	}

	if hit and hit.distance then
		lines[#lines + 1] = "distance " .. format_number(hit.distance)
	end

	if top_contact then
		lines[#lines + 1] = string.format(
			"top %s | overlap %s | points %d",
			tostring(top_contact.other_name or top_contact.kind or "contact"),
			format_number(top_contact.overlap or 0),
			math.max(top_contact.contact_count or 0, 1)
		)
		lines[#lines + 1] = "normal " .. format_vec(top_contact.normal)
	end

	if snapshot.grounded and snapshot.ground_body and snapshot.ground_body.Owner then
		lines[#lines + 1] = "ground " .. tostring(snapshot.ground_body.Owner.Name or "body")
	end

	if snapshot.broadphase then
		local bounds = snapshot.broadphase
		lines[#lines + 1] = string.format(
			"aabb %s",
			format_vec(
				Vec3(
					bounds.max_x - bounds.min_x,
					bounds.max_y - bounds.min_y,
					bounds.max_z - bounds.min_z
				)
			)
		)
	end

	if (snapshot.wake_grace_timer or 0) > 0.001 then
		lines[#lines + 1] = "wake grace " .. format_number(snapshot.wake_grace_timer)
	end

	if snapshot.transition then lines[#lines + 1] = snapshot.transition end

	return lines
end

local function draw_trace_hit(body, hit)
	if not (hit and hit.position) then return end

	local hit_id = "physics_debug_trace_hit_" .. get_body_debug_id(body)
	local normal = hit.normal or hit.face_normal or get_world_up()
	local end_pos = hit.position + normal * overlay_config.hit_normal_length
	debug_draw.DrawSphere({
		id = hit_id .. "_point",
		position = hit.position,
		radius = overlay_config.hit_marker_radius,
		color = {0.95, 0.15, 0.95, 0.95},
		ignore_z = true,
		time = overlay_config.debug_draw_time,
	})
	debug_draw.DrawLine({
		id = hit_id .. "_normal",
		from = hit.position,
		to = end_pos,
		color = {1.0, 0.45, 1.0, 0.95},
		width = 2,
		time = overlay_config.debug_draw_time,
	})
end

local function draw_broadphase_bounds(body, snapshot)
	local bounds = snapshot.broadphase

	if not bounds then return end

	debug_draw.DrawWireAABB({
		id = "physics_debug_broadphase_" .. get_body_debug_id(body),
		aabb = bounds,
		color = {0.4, 0.95, 1.0, 0.95},
		width = 1,
		time = overlay_config.debug_draw_time,
	})
end

local function draw_contact_markers(body, contacts)
	local drawn = 0

	for contact_index, contact in ipairs(contacts) do
		for marker_index, marker in ipairs(contact.markers or {}) do
			if drawn >= overlay_config.contact_draw_limit then return end

			local marker_id = string.format(
				"physics_debug_contact_%s_%d_%d",
				get_body_debug_id(body),
				contact_index,
				marker_index
			)
			local normal = marker.normal or get_world_up()
			local end_pos = marker.position + normal * overlay_config.contact_normal_length
			debug_draw.DrawSphere({
				id = marker_id .. "_point",
				position = marker.position,
				radius = 0.045,
				color = {1.0, 0.38, 0.24, 0.95},
				ignore_z = true,
				time = overlay_config.debug_draw_time,
			})
			debug_draw.DrawLine({
				id = marker_id .. "_normal",
				from = marker.position,
				to = end_pos,
				color = {1.0, 0.75, 0.28, 0.95},
				width = 2,
				time = overlay_config.debug_draw_time,
			})

			if marker.normal_impulse and marker.normal_impulse > 0.01 then
				debug_draw.DrawText({
					id = marker_id .. "_impulse",
					position = marker.position,
					lines = {"imp " .. format_number(marker.normal_impulse)},
					offset = {8, -8},
					padding = 4,
					line_gap = 0,
					background_alpha = 0.55,
					time = overlay_config.debug_draw_time,
				})
			end

			drawn = drawn + 1
		end
	end
end

local function draw_partner_badges(body, contacts)
	local drawn = 0

	for contact_index, contact in ipairs(contacts) do
		if drawn >= overlay_config.partner_draw_limit then return end

		local other_body = contact.other_body

		if other_body and other_body ~= body then
			local lines = get_partner_badge_lines(body, contact)

			if lines then
				debug_draw.DrawText({
					id = string.format("physics_debug_partner_%s_%d", get_body_debug_id(body), contact_index),
					position = get_body_label_anchor(other_body),
					lines = lines,
					offset = {12, -10},
					padding = 6,
					line_gap = 1,
					background_alpha = 0.55,
					title_color = {0.86, 0.92, 1.0},
					time = overlay_config.debug_draw_time,
				})
				drawn = drawn + 1
			end
		end
	end
end

local function draw_contact_links(body, contacts)
	local drawn = 0
	local start = get_body_label_anchor(body)

	for contact_index, contact in ipairs(contacts) do
		if drawn >= overlay_config.partner_link_limit then return end

		local target = nil

		if contact.other_body and contact.other_body ~= body then
			target = get_body_label_anchor(contact.other_body)
		elseif contact.markers and contact.markers[1] then
			target = contact.markers[1].position
		end

		if target then
			debug_draw.DrawLine({
				id = string.format("physics_debug_link_%s_%d", get_body_debug_id(body), contact_index),
				from = start,
				to = target,
				color = {0.6, 0.85, 1.0, 0.7},
				width = 1,
				time = overlay_config.debug_draw_time,
			})
			drawn = drawn + 1
		end
	end
end

local function draw_hovered_body_info()
	if not debug_enabled then return end

	local body, hit = get_look_body_hit()
	focused_body = body

	if not body then return end

	local snapshot = get_debug_snapshot(body)

	if hit and hit.distance and hit.distance > overlay_config.max_distance then
		return
	end

	local anchor = get_body_label_anchor(body)
	local screen_pos = debug_draw.ProjectWorldPosition(anchor)

	if not screen_pos then return end

	local contacts = collect_body_contacts(body)
	local lines = build_focus_overlay_lines(body, snapshot, hit, contacts)
	local title_r, title_g, title_b = get_awake_color(snapshot)
	draw_trace_hit(body, hit)
	draw_broadphase_bounds(body, snapshot)
	draw_contact_markers(body, contacts)
	draw_contact_links(body, contacts)
	draw_partner_badges(body, contacts)
	debug_draw.DrawTextBlock(
		lines,
		screen_pos.x + overlay_config.label_offset,
		screen_pos.y - 14,
		{
			padding = 8,
			line_gap = 3,
			background_alpha = 0.74,
			title_color = {title_r, title_g, title_b, 1},
		}
	)
end

local function add_primitive(model, polygon3d, shape_type, local_matrix)
	if not polygon3d then return end

	model:AddPrimitive(polygon3d, debug_draw.GetMaterial({shape_type = shape_type}))
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
			debug_draw.GetUnitSpherePolygon(),
			shape_type,
			debug_draw.MakeMatrix(zero_vec, identity_rotation, Vec3(radius, radius, radius)):GetMultiplied(local_matrix)
		)
		return
	end

	if shape_type == "box" then
		add_primitive(model, debug_draw.BuildPolyhedronPolygon(shape:GetPolyhedron()), shape_type, local_matrix)
		return
	end

	if shape_type == "convex" then
		add_primitive(model, debug_draw.BuildConvexPolygon(shape:GetResolvedHull(body)), shape_type, local_matrix)
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
			local child_matrix = debug_draw.MakeMatrix(child.Position or zero_vec, child.Rotation or identity_rotation)
			append_shape(model, body, child.Shape, child_matrix:GetMultiplied(local_matrix))
		end

		return
	end

	add_primitive(
		model,
		debug_draw.BuildConvexPolygon(shape.GetResolvedHull and shape:GetResolvedHull(body) or nil),
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

	local position, rotation = get_body_render_position_rotation(body)
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
	debug_ent.model:SetVisible(debug_enabled and body == focused_body)
	entry.shape, entry.shape_type, entry.hull, entry.child_count = get_shape_signature(body)
	entry.owner = owner
end

local function update_debug_visibility()
	for body, entry in pairs(debug_entries) do
		if entry.entity and entry.entity.IsValid and entry.entity:IsValid() then
			entry.entity.model:SetVisible(debug_enabled and body == focused_body)
		end
	end
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
	elseif debug_ent.model:GetVisible() ~= (debug_enabled and body == focused_body) then
		debug_ent.model:SetVisible(debug_enabled and body == focused_body)
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
		focused_body = nil

		update_debug_visibility()

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
				focused_body = get_look_body_hit()

				if
					focused_body and
					focused_body.Owner and
					focused_body.Owner.IsValid and
					focused_body.Owner:IsValid() and
					focused_body.CollisionEnabled and
					not focused_body.Owner.PhysicsNoCollision and
					not focused_body.Owner.NoPhysicsCollision
				then
					ensure_debug_model(focused_body)
				end

				update_debug_visibility()

			end)
		else
			event.RemoveListener("Update", "physics_debug_sync")
		end
	end
end)
