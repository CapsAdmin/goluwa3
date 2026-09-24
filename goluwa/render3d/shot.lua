local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Shot = library()
local defaults = {
	settle = 2,
	settle_frames = 10,
	converge = false,
	converge_frames = 5,
	max_settle = 15,
}

local function wait(frames, seconds, cb)
	local start = system.GetElapsedTime()
	local count = 0
	local remove
	remove = event.AddListener("FrameEnd", {}, function()
		count = count + 1

		if count >= frames and system.GetElapsedTime() - start >= seconds then
			remove()
			cb()
		end
	end)
end

local function hold(view, properties, opt, cb)
	for key, value in pairs(properties) do
		view["Set" .. key](view, value)
	end

	local start_time = system.GetElapsedTime()
	local start_frame = system.GetFrameNumber()

	local function get_info(difference)
		local info = {
			seconds = system.GetElapsedTime() - start_time,
			frames = system.GetFrameNumber() - start_frame,
		}

		if difference then
			info.difference = difference
			info.converged = difference <= opt.converge
		end

		return info
	end

	local function compare(previous)
		wait(opt.converge_frames, 0, function()
			Screenshot(function(current)
				local difference = current:GetMeanDifference(previous)

				if
					difference <= opt.converge or
					system.GetElapsedTime() - start_time >= opt.max_settle
				then
					cb(current, get_info(difference))
				else
					compare(current)
				end
			end)
		end)
	end

	wait(opt.settle_frames, opt.settle, function()
		Screenshot(function(texture)
			if opt.converge then
				compare(texture)
			else
				cb(texture, get_info())
			end
		end)
	end)
end

function Shot.Capture(properties, cb, opt)
	opt = table.merge_many(defaults, opt or {})
	local view = View.New{Priority = 100}:Activate()

	hold(
		view,
		properties,
		opt,
		function(texture, info)
			view:Remove()
			cb(texture, info)
		end
	)
end

function Shot.Sequence(list_of_properties, cb, opt, done)
	opt = table.merge_many(defaults, opt or {})
	local view = View.New{Priority = 100}:Activate()

	local function run(i)
		if not list_of_properties[i] then
			view:Remove()

			if done then done() end

			return
		end

		hold(
			view,
			list_of_properties[i],
			opt,
			function(texture, info)
				cb(texture, info, i)
				run(i + 1)
			end
		)
	end

	run(1)
end

local function parse_vec3(str)
	local x, y, z = str:match("^%s*([^,]+),([^,]+),([^,]+)%s*$")

	if not x then commands.RaiseUserError("expected x,y,z, got " .. str, 2) end

	return tonumber(x), tonumber(y), tonumber(z)
end

commands.Add({
	aliases = "shot",
	argtypes = "string|nil",
	flags = {
		pos = {type = "string", description = "Camera position as x,y,z"},
		ang = {type = "string", description = "Camera angles in degrees as pitch,yaw,roll"},
		fov = {type = "number", description = "Vertical field of view in degrees"},
		ev = {type = "number", description = "Lock exposure at this EV100"},
		["local-exposure"] = {type = "number", description = "Local exposure strength, 0 for none"},
		settle = {type = "number", description = "Seconds to hold the view before capturing (2)"},
		converge = {
			type = "number",
			description = "Then wait until the mean rgb difference between captures is at most this (0-255)",
		},
		["max-settle"] = {type = "number", description = "Seconds to give up converging after (15)"},
		setup = {
			type = "string",
			description = "Lua file to run before the shot, e.g. to build a scene",
		},
	},
}, function(out, flags)
	if flags.setup then import(flags.setup) end

	local properties = {}

	if flags.pos then properties.Position = Vec3(parse_vec3(flags.pos)) end

	if flags.ang then
		properties.Rotation = Quat():SetAngles(Deg3(parse_vec3(flags.ang)))
	end

	if flags.fov then properties.FOV = math.rad(flags.fov) end

	if flags.ev then properties.ExposureLock = flags.ev end

	if flags["local-exposure"] then
		properties.LocalExposure = flags["local-exposure"]
	end

	Shot.Capture(
		properties,
		function(texture, info)
			local path = texture:SaveWithoutAlpha(out)
			logf(
				"[shot] saved %s after %.2fs (%d frames)%s\n",
				path,
				info.seconds,
				info.frames,
				info.difference and
					string.format(
						", difference %.3f%s",
						info.difference,
						info.converged and "" or " (not converged)"
					) or
					""
			)
			system.ShutDown(0)
		end,
		{
			settle = flags.settle,
			converge = flags.converge,
			max_settle = flags["max-settle"],
		}
	)
end)

return Shot
