if not SERVER then return end

local message = import("goluwa/network/message.lua")
local NetworkComponent = import("goluwa/entities/components/network.lua")
local system = import("goluwa/system.lua")
local collider_debug = import("lua/collider_debug.lua")
local trace_debug = import("lua/trace_debug.lua")
local MAX_RADIUS = 30
local MAX_BODIES = 24

message.AddListener("net_debug_request", function(client, radius)
	local player = _G.GetPlayerEntity(client)

	if not (player and player:IsValid() and type(radius) == "number") then return end

	trace_debug.enabled = true
	radius = math.min(radius, MAX_RADIUS)
	local center = player.transform:GetPosition()
	local bodies = {}

	for id, component in pairs(NetworkComponent.GetAllNetworked()) do
		local entity = component.Owner
		local body = entity.rigid_body

		if body and body.Colliders and entity ~= player then
			local position = body:GetPosition()

			if position:Distance(center) <= radius and #bodies < MAX_BODIES then
				local rotation = body:GetRotation()
				local shapes = {}

				for i, collider in ipairs(body:GetColliders()) do
					if i > 4 then break end

					shapes[i] = collider_debug.Describe(collider)
				end

				bodies[#bodies + 1] = {
					id,
					entity:GetName(),
					body:GetMotionType(),
					position.x,
					position.y,
					position.z,
					rotation.x,
					rotation.y,
					rotation.z,
					rotation.w,
					shapes,
				}
			end
		end
	end

	local traces = {}

	for kind, record in pairs(trace_debug.last[player] or {}) do
		traces[#traces + 1] = {
			kind,
			record.origin.x,
			record.origin.y,
			record.origin.z,
			record.hit.x,
			record.hit.y,
			record.hit.z,
			record.has_hit,
			record.entity,
			system.GetTime() - record.time,
		}
	end

	message.Send("net_debug_response", client, bodies, traces)
end)
