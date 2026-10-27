local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local network = import("goluwa/network/network.lua")
local system = import("goluwa/system.lua")
local message = import("goluwa/network/message.lua")
local NetworkComponent = import("goluwa/entities/components/network.lua")
local collider_debug = import("lua/collider_debug.lua")
local trace_debug = import("lua/trace_debug.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local PREDICTED_COLOR = {0.3, 1, 0.4, 0.95}
local HISTORY_COLOR = {0.35, 0.6, 1, 0.95}
local SERVER_COLOR = {1, 0.3, 0.3, 0.95}
local ERROR_COLOR = {1, 0.9, 0.2, 1}
local LABEL_OFFSET = Vec3(0, 0.3, 0)
local server_size = Vec3()
local history_size = Vec3()
local predicted_size = Vec3()
local CLIENT_COLLIDER_COLOR = {0.3, 1, 0.4, 0.8}
local SERVER_COLLIDER_COLOR = {1, 0.3, 0.3, 0.8}
local MISMATCH_COLOR = {1, 0.9, 0.2, 1}
local CLIENT_SPHERE_COLOR = {0.3, 1, 0.4, 0.18}
local SERVER_SPHERE_COLOR = {1, 0.3, 0.3, 0.18}
local CLIENT_TRACE_COLOR = {0.3, 0.9, 1, 1}
local SERVER_TRACE_COLOR = {1, 0.3, 1, 1}
local REQUEST_INTERVAL = 0.2
local RADIUS = 8
local MAX_LINES = 1500
local enabled = false
local server_bodies = {}
local server_traces = {}
local last_request = -math.huge
local lines_drawn = 0
local corner = Vec3()

message.AddListener("net_debug_response", function(bodies, traces)
	server_bodies = {}

	for _, body in ipairs(bodies) do
		server_bodies[body[1]] = body
	end

	server_traces = traces
end)

local function line(id, from, to, color, width)
	if lines_drawn >= MAX_LINES then return end

	lines_drawn = lines_drawn + 1
	debug_draw.DrawLine{id = id, from = from, to = to, color = color, width = width or 1, time = 0.05}
end

local function draw_box(prefix, min, max, position, rotation, color)
	local corners = {}

	for index = 0, 7 do
		corner:Set(
			index % 2 == 0 and min.x or max.x,
			math.floor(index / 2) % 2 == 0 and min.y or max.y,
			math.floor(index / 4) % 2 == 0 and min.z or max.z
		)
		corners[index + 1] = position + rotation:VecMul(corner)
	end

	for i, edge in ipairs(collider_debug.BOX_EDGES) do
		line(prefix .. "_" .. i, corners[edge[1]], corners[edge[2]], color)
	end
end

local function draw_collider(prefix, collider, position, rotation, color)
	local polyhedron = collider_debug.GetPolyhedron(collider)

	if polyhedron and polyhedron.vertices then
		local vertices = {}

		for i, vertex in ipairs(polyhedron.vertices) do
			vertices[i] = position + rotation:VecMul(vertex)
		end

		for i, edge in ipairs(collider_debug.GetEdges(polyhedron)) do
			line(prefix .. "_" .. i, vertices[edge[1]], vertices[edge[2]], color)
		end

		return
	end

	local shape = collider:GetPhysicsShape()
	local sphere_color = color == SERVER_COLLIDER_COLOR and SERVER_SPHERE_COLOR or CLIENT_SPHERE_COLOR
	local radius = shape:GetRadius()
	local up = rotation:VecMul(Vec3(0, 1, 0))
	local reach = shape:GetTypeName() == "capsule" and
		math.max(shape:GetHeight() * 0.5 - radius, 0) or
		0
	debug_draw.DrawSphere{
		id = prefix .. "_a",
		position = position + up * reach,
		radius = radius,
		color = sphere_color,
		translucent = true,
		time = 0.05,
	}

	if reach > 0 then
		debug_draw.DrawSphere{
			id = prefix .. "_b",
			position = position - up * reach,
			radius = radius,
			color = sphere_color,
			translucent = true,
			time = 0.05,
		}
	end
end

local local_position = Vec3()
local local_rotation = Quat()

local function draw_server_body(prefix, body, color)
	local position = Vec3(body[4], body[5], body[6])
	local rotation = Quat(body[7], body[8], body[9], body[10])

	for i, shape in ipairs(body[11]) do
		local_position:Set(shape[9], shape[10], shape[11])
		local_rotation:Set(shape[12], shape[13], shape[14], shape[15])
		draw_box(
			prefix .. "_" .. i,
			Vec3(shape[3], shape[4], shape[5]),
			Vec3(shape[6], shape[7], shape[8]),
			position + rotation:VecMul(local_position),
			rotation * local_rotation,
			color
		)
	end
end

local function draw_bodies(rig, camera_text_lines)
	local center = rig.transform:GetPosition()

	for id, component in pairs(NetworkComponent.GetAllNetworked()) do
		local entity = component.Owner
		local body = entity.rigid_body

		if body and body.Colliders and entity ~= rig then
			local position = body:GetPosition()

			if position:Distance(center) <= RADIUS then
				local server = server_bodies[id]
				local client_types = {}
				local mismatch = false

				for i, collider in ipairs(body:GetColliders()) do
					local description = collider_debug.Describe(collider)
					client_types[i] = string.format("%s(%d)", description[1], description[2])
					local theirs = server and server[11][i]

					if not theirs or theirs[1] ~= description[1] or theirs[2] ~= description[2] then
						mismatch = true
					end

					draw_collider(
						string.format("prediction_debug_body_%d_%d", id, i),
						collider,
						collider:GetPosition(),
						collider:GetRotation(),
						CLIENT_COLLIDER_COLOR
					)
				end

				local label = {
					string.format("#%d %s", id, entity:GetName()),
					"client: " .. table.concat(client_types, " ") .. " " .. body:GetMotionType(),
				}

				if server then
					draw_server_body("prediction_debug_server_body_" .. id, server, SERVER_COLLIDER_COLOR)
					local server_types = {}

					for i, shape in ipairs(server[11]) do
						server_types[i] = string.format("%s(%d)", shape[1], shape[2])
					end

					label[3] = "server: " .. table.concat(server_types, " ") .. " " .. server[3]
					label[4] = string.format(
						"position difference %.1f mm",
						position:Distance(Vec3(server[4], server[5], server[6])) * 1000
					)
				else
					label[3] = "server: no data yet"
				end

				debug_draw.DrawText{
					id = "prediction_debug_body_text_" .. id,
					position = position,
					lines = label,
					color = mismatch and MISMATCH_COLOR or CLIENT_COLLIDER_COLOR,
					time = 0.05,
				}
			end
		end
	end
end

local function draw_trace(prefix, kind, origin, hit, has_hit, entity, color)
	local reach = has_hit and hit or origin + Vec3(0, 0, 0)
	line(prefix .. "_line", origin, reach, color, 2)

	if has_hit then
		debug_draw.DrawSphere{
			id = prefix .. "_hit",
			position = hit,
			radius = 0.05,
			color = color,
			time = 0.05,
		}
		debug_draw.DrawText{
			id = prefix .. "_text",
			position = hit,
			lines = {kind .. " -> " .. (entity ~= "" and entity or "world")},
			color = color,
			time = 0.05,
		}
	end
end

local function draw_traces(rig, label)
	local mine = trace_debug.last[rig] or {}

	for kind, record in pairs(mine) do
		if system.GetTime() - record.time < 5 then
			draw_trace(
				"prediction_debug_client_trace_" .. kind,
				"client " .. kind,
				record.origin,
				record.hit,
				record.has_hit,
				record.entity,
				CLIENT_TRACE_COLOR
			)
		end
	end

	for _, trace in ipairs(server_traces) do
		if trace[10] < 5 then
			local kind = trace[1]
			local server_hit = Vec3(trace[5], trace[6], trace[7])
			draw_trace(
				"prediction_debug_server_trace_" .. kind,
				"server " .. kind,
				Vec3(trace[2], trace[3], trace[4]),
				server_hit,
				trace[8],
				trace[9],
				SERVER_TRACE_COLOR
			)
			local client = mine[kind]

			if client and client.has_hit and trace[8] then
				label[#label + 1] = string.format(
					"%s trace: client hit %s, server hit %s, %.1f mm apart",
					kind,
					client.entity ~= "" and client.entity or "world",
					trace[9] ~= "" and trace[9] or "world",
					client.hit:Distance(server_hit) * 1000
				)
			else
				label[#label + 1] = string.format(
					"%s trace: client %s, server %s",
					kind,
					client and
						client.has_hit and
						(
							client.entity ~= "" and
							client.entity or
							"world"
						)
						or
						"no hit",
					trace[8] and (trace[9] ~= "" and trace[9] or "world") or "no hit"
				)
			end
		end
	end
end

event.AddListener(
	"Draw3DGeometry",
	"prediction_debug",
	function(cmd, dt)
		if not enabled or not network.IsConnected() then return end

		local rig = _G.PLAYER_RIG

		if not rig then return end

		local controller = rig.player_controller

		if not controller.synced then return end

		lines_drawn = 0
		trace_debug.enabled = true

		if system.GetTime() - last_request > REQUEST_INTERVAL then
			last_request = system.GetTime()
			message.Send("net_debug_request", RADIUS)
		end

		local radius, height = rig.character_movement:GetDimensions()
		server_size:Set(radius * 2, height, radius * 2)
		history_size:Set(radius * 1.9, height * 0.98, radius * 1.9)
		predicted_size:Set(radius * 1.8, height * 0.96, radius * 1.8)
		local time = dt or 0.05
		local ack = controller.last_ack
		local current = rig.rigid_body:GetPosition()
		debug_draw.DrawWireBox{
			id = "prediction_debug_predicted",
			position = current,
			size = predicted_size,
			color = PREDICTED_COLOR,
			width = 1,
			time = time,
		}

		for i, collider in ipairs(rig.rigid_body:GetColliders()) do
			draw_collider(
				"prediction_debug_player_collider_" .. i,
				collider,
				collider:GetPosition(),
				collider:GetRotation(),
				CLIENT_COLLIDER_COLOR
			)

			if ack.number ~= 0 then
				local body_rotation = rig.rigid_body:GetRotation()
				draw_collider(
					"prediction_debug_server_collider_" .. i,
					collider,
					ack.server_position + body_rotation:VecMul(collider:GetLocalPosition()),
					body_rotation * collider:GetLocalRotation(),
					SERVER_COLLIDER_COLOR
				)
			end
		end

		if ack.number == 0 then return end

		debug_draw.DrawWireBox{
			id = "prediction_debug_history",
			position = ack.predicted_position,
			size = history_size,
			color = HISTORY_COLOR,
			width = 1,
			time = time,
		}
		debug_draw.DrawWireBox{
			id = "prediction_debug_server",
			position = ack.server_position,
			size = server_size,
			color = SERVER_COLOR,
			width = 1,
			time = time,
		}
		debug_draw.DrawLine{
			id = "prediction_debug_error",
			from = ack.predicted_position,
			to = ack.server_position,
			color = ERROR_COLOR,
			width = 2,
			ignore_z = true,
			time = time,
		}
		local count, corrected, max_error, max_velocity_error = controller:GetAckStats()
		local label = {
			"green: predicted now   blue: predicted at ack   red: server at ack",
			string.format(
				"ack %d  age %.0f ms  commands ahead %d  missed %d",
				ack.number,
				(system.GetTime() - ack.time) * 1000,
				controller.number - ack.number,
				controller.ack_missed
			),
			string.format(
				"error %.2f mm  velocity error %.3f  distance error %.3f",
				ack.error * 1000,
				ack.velocity_error,
				ack.distance_error
			),
			string.format(
				"last %d acks: %d corrected  max error %.2f mm  max velocity error %.3f",
				count,
				corrected,
				max_error * 1000,
				max_velocity_error
			),
			string.format(
				"correction offset %.2f mm  total corrections %d",
				controller:GetCorrectionOffset():GetLength() * 1000,
				controller.corrections
			),
		}
		draw_traces(rig, label)
		draw_bodies(rig)
		debug_draw.DrawText{
			id = "prediction_debug_text",
			position = current + LABEL_OFFSET + Vec3(0, height * 0.5, 0),
			lines = label,
			color = ack.corrected and ERROR_COLOR or PREDICTED_COLOR,
			time = time,
		}
	end,
	{priority = -100}
)

commands.Add("net_prediction_debug", function()
	enabled = not enabled
	print("[net prediction debug] " .. (enabled and "Enabled" or "Disabled"))
end)
