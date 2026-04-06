local compat = {}

local function is_balatro_game(love, folder)
	if love and love.filesystem and love.filesystem.getIdentity then
		local identity = tostring(love.filesystem.getIdentity() or ""):lower()

		if identity == "balatro" then return true end
	end

	local path = tostring(folder or ""):gsub("\\", "/"):gsub("/+$", "")
	local name = path:match("([^/]+)$")
	return name and name:lower() == "balatro" or false
end

local function apply_balatro_event_patch(love, env)
	local Event = (
			env and
			env.Event
		)
		or
		(
			love and
			love._line_env and
			love._line_env.globals and
			love._line_env.globals.Event
		)

	if type(Event) ~= "table" or Event.__line_balatro_blockable_patch then return end

	local original_handle = Event.handle

	if type(original_handle) ~= "function" then return end

	Event.handle = function(self, results)
		local preserve_creation_time = not self.start_timer

		if preserve_creation_time then self.start_timer = true end

		original_handle(self, results)

		if self.blockable == false then results.blocking = false end
	end
	Event.__line_balatro_blockable_patch = true

	if love and love._line_env then love._line_env.balatro_event_patch = true end

	llog("applied balatro event compatibility patch")
end

function compat.Apply(love, env, folder)
	if not is_balatro_game(love, folder) then return end

	apply_balatro_event_patch(love, env)
end

return compat
