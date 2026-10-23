local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local new_event = import("goluwa/network/replicated_event.lua")
local system = import("goluwa/system.lua")
local Health = import("lua/components/health.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local surface_hazards = {}
surface_hazards.INTERVAL = 0.25
surface_hazards.FEET_RADIUS = 0.4
surface_hazards.IGNITE_STATUS = 0.25
surface_hazards.IGNITE_CHANCE = 0.3
surface_hazards.List = {
	{channel = "heat", status = "fire", threshold = 0.2, rate = 0.6},
	{channel = "frost", status = "frozen", threshold = 0.45, rate = 0.3},
	{channel = "poison", status = "poison", threshold = 0.25, rate = 0.4},
}
local visual = RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
surface_hazards.Visual = visual

local function enabled()
	return visual
end

local surface_effects = visual and import("goluwa/render3d/surface_effects.lua")
surface_hazards.Apply = new_event(
	"jrpg_surface_hazard",
	function(kind, position, radius, amount, normal)
		surface_effects.Apply(kind, position, radius, amount, normal)
	end,
	enabled
)

if not visual then return surface_hazards end

local next_think = 0

event.AddListener("Update", "jrpg_surface_hazards", function()
	local now = system.GetElapsedTime()

	if now < next_think or not network.HasAuthority() then return end

	next_think = now + surface_hazards.INTERVAL
	local has_cells = surface_effects.GetCellCount() > 0

	for _, health in ipairs(Health.Instances) do
		local entity = health.Owner

		if not health:IsDead() and entity.transform then
			local feet = entity.transform:GetPosition()

			if has_cells then
				for _, hazard in ipairs(surface_hazards.List) do
					local value = surface_effects.Query(feet, surface_hazards.FEET_RADIUS, hazard.channel)

					if value > hazard.threshold then
						status_effects.Add(entity, hazard.status, value * hazard.rate * surface_hazards.INTERVAL)
					end
				end
			end

			if
				status_effects.Get(entity, "fire") > surface_hazards.IGNITE_STATUS and
				math.random() < surface_hazards.IGNITE_CHANCE
			then
				surface_hazards.Apply("fire", feet, 0.4, 0.5)
			end
		end
	end
end)

return surface_hazards
