local module = {}

function module.CreateServices(services)
	local world_contact_services = import("goluwa/physics/world_contacts.lua")
	local contact_resolution_services = import("goluwa/physics/contact_resolution.lua")
	local world_contacts = world_contact_services.CreateServices(services)
	local contact_resolution = contact_resolution_services.CreateServices(services)
	return {
		SolveBodyContacts = world_contacts.SolveBodyContacts,
		GetPointVelocity = contact_resolution.GetPointVelocity,
		ApplyImpulseToMotion = contact_resolution.ApplyImpulseToMotion,
		SetBodyMotionFromCurrentState = contact_resolution.SetBodyMotionFromCurrentState,
		ResolvePairPenetration = contact_resolution.ResolvePairPenetration,
		ApplyPairImpulse = contact_resolution.ApplyPairImpulse,
		MarkPairGrounding = contact_resolution.MarkPairGrounding,
	}
end

return module