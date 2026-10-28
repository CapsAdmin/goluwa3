local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local audio = import("goluwa/audio.lua")
local perf = import("lua/perf.lua")
local BAND_NAMES = {"low", "mid", "high"}
local BAND_COLORS = {Color(1, 0.55, 0.25, 1), Color(0.95, 0.9, 0.35, 1), Color(0.45, 0.8, 1, 1)}
local TEXT_DIM = Color(0.55, 0.6, 0.7, 1)
local UP = Vec3(0, 1, 0)
local MAP_WIDTH, MAP_HEIGHT = 270, 330
local DECAY_HEIGHT = 130
local BLOCK_SECONDS = 512 / 44100
local show_world = false

local function db(amplitude)
	if amplitude <= 0 then return "-inf" end

	return string.format("%.0f dB", 20 * math.log10(amplitude))
end

local function sound_name(sound)
	local name = sound:GetName() or ""
	name = name:match("([^/\\]+)$") or name
	return name ~= "" and name or tostring(sound)
end

local function tracer_name()
	local env = audio.acoustics

	if not env then return "off" end

	return env.tracer.pipeline and "gpu" or "cpu"
end

local function by_distance(a, b)
	return a.distance < b.distance
end

local function spatial_sounds()
	local list = {}
	local listener = audio.listener_position

	for _, sound in pairs(audio.active_sounds) do
		if sound:IsSpatial() then
			list[#list + 1] = {sound = sound, distance = (sound:GetPosition() - listener):GetLength()}
		end
	end

	table.sort(list, by_distance)
	return list
end

local function tap_count(env)
	local count, first, last = 0, math.huge, 0

	for _, tap in pairs(env.taps) do
		count = count + 1
		first = math.min(first, tap.delay)
		last = math.max(last, tap.delay)
	end

	return count, first, last
end

local function build_rows()
	local rows = {}
	local env = audio.acoustics
	local debug_state = audio.GetDebugState()
	local job = env and env.last_job
	rows[#rows + 1] = {label = "tracer", value = tracer_name(), color = "head"}

	if job then
		rows[#rows + 1] = {
			label = "rays",
			value = string.format("%d x %d", job.rays, job.bounces),
			detail = string.format("%d src %d q", #job.sources, job.query_count),
			color = "dim",
		}
	end

	rows[#rows + 1] = {
		label = "cost",
		value = string.format("gpu %.2f ms", gpu_timing.GetMilliseconds("audio_acoustics") or 0),
		detail = string.format("mix %.0f%% core", debug_state.mix_seconds / BLOCK_SECONDS * 100),
		color = "dim",
	}

	if not env then
		rows[#rows + 1] = {label = "no acoustics: free field, direct sound only", color = "dim"}
	else
		local profile = env.profile
		rows[#rows + 1] = {label = "room around the listener", color = "head"}

		for band = 1, 3 do
			rows[#rows + 1] = {
				label = "  reverb time " .. BAND_NAMES[band],
				value = string.format("%.2f s", profile.t60[band]),
				fraction = math.min(profile.t60[band] / 4, 1),
			}
		end

		rows[#rows + 1] = {
			label = "  volume",
			value = profile.volume > 1e7 and "open" or string.format("%.0f m3", profile.volume),
			detail = profile.volume < 1e7 and
				string.format("%.1f m cube", profile.volume ^ (1 / 3)) or
				nil,
		}
		rows[#rows + 1] = {
			label = "  mean free path",
			value = string.format("%.1f m", profile.mean_free_path),
		}
		rows[#rows + 1] = {
			label = "  rays escaping",
			value = string.format("%.0f%%", profile.openness * 100),
			fraction = profile.openness,
		}
		rows[#rows + 1] = {
			label = "  reverb starts after",
			value = string.format("%.0f ms", profile.predelay * 1000),
		}
		rows[#rows + 1] = {label = "  reflecting surfaces", value = tostring(#env:GetTopReflectors())}
		local bus = audio.state.buses[1]
		rows[#rows + 1] = {
			label = "other space reverb",
			value = string.format("%.1f/%.1f/%.1f s", bus.t60[0], bus.t60[1], bus.t60[2]),
			color = "dim",
		}
	end

	local sounds = spatial_sounds()
	rows[#rows + 1] = {label = string.format("spatial sounds (%d)", #sounds), color = "head"}

	for _, entry in ipairs(sounds) do
		local sound = entry.sound
		local paths = audio.ComputePaths(sound)
		local delay = (paths.ear_delay[1] + paths.ear_delay[2]) * 0.5
		local rate = 1 - (paths.ear_rate[1] + paths.ear_rate[2]) * 0.5
		rows[#rows + 1] = {
			label = sound_name(sound),
			value = string.format("%.1f m", entry.distance),
			detail = math.abs(rate - 1) > 0.002 and
				string.format("%.0f ms %.3fx", delay * 1000, rate) or
				string.format("%.0f ms", delay * 1000),
		}
		local senv = sound.audio_environment

		if senv then
			local o = senv.occlusion
			rows[#rows + 1] = {
				label = "  direct",
				value = db((paths.ear_gain[2] + paths.ear_gain[5]) * 0.5),
				detail = o[2] > 0.95 and
					"visible" or
					string.format(
						"%.0f/%.0f/%.0f dB",
						20 * math.log10(o[1]),
						20 * math.log10(o[2]),
						20 * math.log10(o[3])
					),
				fraction = o[2],
				color = o[2] < 0.5 and "warn" or nil,
			}
			rows[#rows + 1] = {
				label = "  reverb",
				value = db(math.sqrt(senv.send[1] ^ 2 + senv.send[2] ^ 2)),
				detail = string.format(
					"%s %.1f s%s",
					senv.send[2] > senv.send[1] and "other" or "room",
					senv.t60 and senv.t60[2] or 0,
					(senv.trust or 0) < 1 and string.format(" %.0f%%", (senv.trust or 0) * 100) or ""
				),
			}
			local count, first, last = tap_count(senv)
			rows[#rows + 1] = {
				label = "  reflections",
				value = tostring(count),
				detail = count > 0 and string.format("%.0f-%.0f ms", first * 1000, last * 1000) or nil,
				color = count == 0 and "dim" or nil,
			}
		end
	end

	return rows
end

local function project(map, position)
	local d = position - map.listener
	return map.cx + d:GetDot(map.right) * map.scale,
	map.cy - d:GetDot(map.forward) * map.scale
end

local function absorption_color(alpha)
	local t = math.clamp(alpha / 0.5, 0, 1)
	return 0.55 - 0.15 * t, 0.8 + 0.2 * t, 1 - 0.6 * t
end

local RoomMap = Panel:CreateTemplate("audio_room_map")
RoomMap.CMP.transform = {}
RoomMap.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
RoomMap.CMP.visual = {}
RoomMap.radius = 20

function RoomMap.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

function RoomMap:OnDraw()
	local size = self.transform:GetSize()
	render2d.SetTexture(nil)
	render2d.SetColor(0.03, 0.04, 0.07, 0.92)
	render2d.DrawRoundedRect(0, 0, size.x, size.y, 10)
	local env = audio.acoustics
	local listener = audio.listener_position
	local forward = audio.listener_forward:Copy()
	forward.y = 0

	if forward:IsZero() then forward = Vec3(0, 0, -1) end

	forward = forward:GetNormalized()
	local right = forward:GetCross(UP):GetNormalized()
	local target = 0

	for _, sound in pairs(audio.active_sounds) do
		if sound:IsSpatial() then
			target = math.max(target, (sound:GetPosition() - listener):GetLength() * 1.3)
		end
	end

	if target == 0 and env then target = env.profile.mean_free_path * 1.5 end

	target = math.max(target, 10)
	self.radius = self.radius + (math.min(target, 250) - self.radius) * 0.1
	local map = {
		listener = listener,
		forward = forward,
		right = right,
		cx = size.x / 2,
		cy = size.y / 2,
		scale = (math.min(size.x, size.y) / 2 - 10) / self.radius,
	}
	render2d.PushClipRect(4, 4, size.x - 8, size.y - 8)
	render2d.SetColor(1, 1, 1, 0.06)
	render2d.DrawCircle(map.cx, map.cy, self.radius * 0.5 * map.scale, 1, 48)
	render2d.DrawCircle(map.cx, map.cy, self.radius * map.scale, 1, 64)

	if env and env.samples then
		local s = env.samples

		for at = 0, #s - 1, 11 do
			local x, y = project(map, Vec3(s[at + 1], s[at + 2], s[at + 3]))
			local r, g, b = absorption_color(s[at + 10])
			local vertical = math.abs(s[at + 5]) > 0.7
			render2d.SetColor(r, g, b, vertical and 0.3 or 0.9)
			render2d.DrawRect(x - 1, y - 1, 3, 3)
		end
	end

	if env then
		for _, reflector in ipairs(env:GetTopReflectors()) do
			local n = Vec3(reflector.normal[1], reflector.normal[2], reflector.normal[3]):GetNormalized()
			local center = Vec3(reflector.position[1], reflector.position[2], reflector.position[3]) / reflector.count
			local x, y = project(map, center)
			local r, g, b = absorption_color(reflector.absorption[2] / reflector.count)
			render2d.SetColor(r, g, b, 1)

			if math.abs(n.y) < 0.7 then
				local along = n:GetCross(UP):GetNormalized() * math.clamp(math.sqrt(reflector.weight) * 0.5, 0.5, self.radius * 0.4)
				local ax, ay = project(map, center - along)
				local bx, by = project(map, center + along)
				local nx, ny = project(map, center + n * (self.radius * 0.05))
				render2d.DrawLine(ax, ay, bx, by, 3)
				render2d.DrawLine(x, y, nx, ny, 1)
			else
				render2d.DrawCircle(x, y, 5, 2, 12)
			end
		end
	end

	for _, sound in pairs(audio.active_sounds) do
		local senv = sound:IsSpatial() and sound.audio_environment

		if senv then
			local source = sound:GetPosition()
			local sx, sy = project(map, source)

			for _, tap in pairs(senv.taps) do
				local px, py = project(map, tap.point)
				local alpha = math.clamp(tap.gain / math.max(senv.occlusion[2], 0.05) * 2, 0.15, 0.8)
				render2d.SetColor(1, 0.85, 0.3, alpha)
				render2d.DrawLine(sx, sy, px, py, 1)
				render2d.DrawLine(px, py, map.cx, map.cy, 1)
				render2d.DrawRect(px - 2, py - 2, 5, 5)
			end

			local o = senv.occlusion[2]
			render2d.SetColor(1 - o, 0.3 + 0.7 * o, 0.3, 0.9)
			render2d.DrawLine(map.cx, map.cy, sx, sy, 2)
			render2d.SetColor(1, 1, 1, 1)
			render2d.DrawCircle(sx, sy, 5, 2, 16)
		end
	end

	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawLine(map.cx, map.cy - 8, map.cx - 5, map.cy + 5, 2)
	render2d.DrawLine(map.cx, map.cy - 8, map.cx + 5, map.cy + 5, 2)
	render2d.PopClip()
	local legend = {
		{"dots: first hits, blue hard, green soft", TEXT_DIM},
		{"bars/circles: reflecting walls/floors", TEXT_DIM},
		{"yellow: reflection paths", Color(1, 0.85, 0.3, 1)},
		{"green to red: direct path blocked", Color(0.4, 1, 0.4, 1)},
		{string.format("forward is up, outer ring %.0f m", self.radius), TEXT_DIM},
	}

	for i, line in ipairs(legend) do
		render2d.DrawText{
			text = line[1],
			x = 10,
			y = size.y - 10 - (#legend - i) * 12,
			size = 10,
			align_y = "cap_center",
			foreground_color = line[2],
		}
	end
end

RoomMap:Register()
local DecayGraph = Panel:CreateTemplate("audio_decay_graph")
DecayGraph.CMP.transform = {}
DecayGraph.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
DecayGraph.CMP.visual = {}

function DecayGraph.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

function DecayGraph:OnDraw()
	local size = self.transform:GetSize()
	render2d.SetTexture(nil)
	render2d.SetColor(0.03, 0.04, 0.07, 0.92)
	render2d.DrawRoundedRect(0, 0, size.x, size.y, 10)
	local env = audio.acoustics

	if not env then return end

	local profile = env.profile
	local x0, y0 = 12, 10
	local w, h = size.x - 24, size.y - 34
	local seconds = math.clamp(math.max(profile.t60[1], profile.t60[2], profile.t60[3]) * 1.1, 0.25, 6)
	render2d.SetColor(1, 1, 1, 0.1)

	for db_line = 0, 60, 20 do
		render2d.DrawRect(x0, y0 + h * db_line / 60, w, 1)
	end

	local start = profile.predelay

	for band = 1, 3 do
		local color = BAND_COLORS[band]
		render2d.SetColor(color.r, color.g, color.b, 1)
		local px = x0 + w * start / seconds
		local py = y0
		local t60 = profile.t60[band]

		for i = 1, 40 do
			local t = start + (seconds - start) * i / 40
			local x = x0 + w * t / seconds
			local y = y0 + h * math.min((t - start) / t60, 1)
			render2d.DrawLine(px, py, x, y, 2)
			px, py = x, y
		end

		render2d.DrawText{
			text = BAND_NAMES[band],
			x = x0 + (band - 1) * 44,
			y = size.y - 12,
			size = 11,
			align_y = "cap_center",
			foreground_color = color,
		}
	end

	render2d.DrawText{
		text = string.format("0 to -60 dB, %.1f s", seconds),
		x = x0 + 150,
		y = size.y - 12,
		size = 11,
		align_y = "cap_center",
		foreground_color = TEXT_DIM,
	}
end

DecayGraph:Register()
local RoomMapElement = react.Element(RoomMap)
local DecayGraphElement = react.Element(DecayGraph)
perf.RegisterTab(
	"AUDIO",
	8,
	react.Component(
		||->ui.Row{layout = {ChildGap = 8}}{
			ui.StatTable{
				Size = Vec2(392, MAP_HEIGHT + DECAY_HEIGHT + 8),
				Rows = react.UsePoll(build_rows, perf.POLL_INTERVAL),
			},
			ui.Column{layout = {ChildGap = 8}}{
				RoomMapElement{Size = Vec2(MAP_WIDTH, MAP_HEIGHT)},
				DecayGraphElement{Size = Vec2(MAP_WIDTH, DECAY_HEIGHT)},
			},
		}
	)
)

local function draw_world()
	local env = audio.acoustics

	if not env then return end

	local listener = audio.listener_position

	for i, reflector in ipairs(env:GetTopReflectors()) do
		local n = Vec3(reflector.normal[1], reflector.normal[2], reflector.normal[3]):GetNormalized()
		local center = Vec3(reflector.position[1], reflector.position[2], reflector.position[3]) / reflector.count
		local r, g, b = absorption_color(reflector.absorption[2] / reflector.count)
		local side = math.clamp(math.sqrt(reflector.weight) * 0.5, 0.5, 8)
		local dot = math.clamp(n:GetDot(UP), -1, 1)
		local axis = UP:GetCross(n)
		local rotation = axis:IsZero() and
			QuatFromAxis(dot > 0 and 0 or math.pi, Vec3(1, 0, 0)) or
			QuatFromAxis(math.acos(dot), axis:GetNormalized())
		debug_draw.DrawBox{
			id = "audio_reflector_" .. i,
			position = center + n * 0.05,
			rotation = rotation,
			size = Vec3(side, 0.02, side),
			color = Color(r, g, b, 0.35),
			ignore_z = false,
			translucent = true,
			double_sided = true,
			time = 0.2,
		}
		debug_draw.DrawLine{
			id = "audio_reflector_normal_" .. i,
			from = center,
			to = center + n * 0.75,
			color = Color(r, g, b, 1),
			width = 0.03,
			beam = true,
			time = 0.2,
		}
	end

	for _, sound in pairs(audio.active_sounds) do
		local senv = sound:IsSpatial() and sound.audio_environment

		if senv then
			local source = sound:GetPosition()
			local key = tostring(sound)
			local o = senv.occlusion[2]
			local toward = listener - source
			local length = toward:GetLength()
			debug_draw.DrawSphere{
				id = "audio_source_" .. key,
				position = source,
				radius = 0.2,
				color = Color(1 - o, 0.3 + 0.7 * o, 0.3, 0.6),
				time = 0.2,
			}

			if length > 1 then
				debug_draw.DrawLine{
					id = "audio_direct_" .. key,
					from = source,
					to = source + toward * ((length - 0.8) / length),
					color = Color(1 - o, 0.3 + 0.7 * o, 0.3, 0.8),
					width = 0.02,
					beam = true,
					time = 0.2,
				}
			end

			debug_draw.DrawText{
				id = "audio_label_" .. key,
				position = source + Vec3(0, 0.45, 0),
				lines = {
					sound_name(sound),
					string.format(
						"direct %s  reverb %s",
						db(senv.occlusion[2]),
						db(math.sqrt(senv.send[1] ^ 2 + senv.send[2] ^ 2))
					),
				},
				time = 0.2,
			}

			for slot, tap in pairs(senv.taps) do
				local tap_key = key .. "_" .. slot
				local to_listener = listener - tap.point
				local tap_length = to_listener:GetLength()
				debug_draw.DrawLine{
					id = "audio_tap_in_" .. tap_key,
					from = source,
					to = tap.point,
					color = Color(1, 0.85, 0.3, 0.7),
					width = 0.015,
					beam = true,
					time = 0.2,
				}

				if tap_length > 1 then
					debug_draw.DrawLine{
						id = "audio_tap_out_" .. tap_key,
						from = tap.point,
						to = tap.point + to_listener * ((tap_length - 0.8) / tap_length),
						color = Color(1, 0.85, 0.3, 0.4),
						width = 0.015,
						beam = true,
						time = 0.2,
					}
				end

				debug_draw.DrawSphere{
					id = "audio_tap_point_" .. tap_key,
					position = tap.point,
					radius = 0.08,
					color = Color(1, 0.85, 0.3, 0.9),
					time = 0.2,
				}
			end
		end
	end
end

event.AddListener("Update", "audio_acoustics_world", function()
	if show_world then draw_world() end
end)

commands.Add("audio_debug", function()
	show_world = not show_world
	logn("audio world overlay ", show_world and "on" or "off")
end)

commands.Add("audio_stats", function()
	perf.PrintRows(build_rows())
end)
