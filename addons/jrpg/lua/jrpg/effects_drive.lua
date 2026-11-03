local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local effects_drive = {}
effects_drive.Types = {"sweep"}
effects_drive.Defaults = {sweep = {Type = "sweep", Length = 2.4, Time = 1}}
local TYPES = {}

function TYPES.sweep(state, t)
	local stage = state.Stage
	local right = Vec3(stage.Toward.z, 0, -stage.Toward.x)
	state.Position = stage.Chest + right * ((t * 2 - 1) * state.Spec.Length / 2)
end

function effects_drive.Start(spec, stage)
	local state = {Spec = spec, Stage = stage, Start = system.GetElapsedTime(), Position = Vec3()}
	effects_drive.Step(state)
	return state
end

function effects_drive.Step(state)
	local t = (system.GetElapsedTime() - state.Start) / state.Spec.Time
	state.T = math.min(t, 1)
	TYPES[state.Spec.Type](state, state.T)
	return t < 1
end

return effects_drive
