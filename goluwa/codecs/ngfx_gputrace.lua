local ffi = require("ffi")
local bit = require("bit")
local lz4 = import("goluwa/codecs/lz4.lua")
local protobuf = import("goluwa/codecs/protobuf.lua")
local ngfx_gputrace = {}
local Trace = {}
Trace.__index = Trace
local uint8_ptr_t = ffi.typeof("const uint8_t *")
local uint32_ptr_t = ffi.typeof("const uint32_t *")
local byte_array_t = ffi.typeof("uint8_t[?]")
local Decode, Find, FindAll, String = protobuf.Decode, protobuf.Find, protobuf.FindAll, protobuf.String
local ROOT_MESSAGES = 1
local ROOT_INFO = 2
local ROOT_SESSION = 4
local ROOT_API = 5
local ROOT_PROCESSES = 9
local API_CALL_LISTS = 10
local API_SCREENSHOT = 3
local GRAPHICS, COMPUTE, RAYTRACING = "VK_PIPELINE_BIND_POINT_GRAPHICS",
"VK_PIPELINE_BIND_POINT_COMPUTE",
"VK_PIPELINE_BIND_POINT_RAY_TRACING_KHR"
local EVENT_BIND_POINTS = {
	vkCmdDraw = GRAPHICS,
	vkCmdDrawIndexed = GRAPHICS,
	vkCmdDrawIndirect = GRAPHICS,
	vkCmdDrawIndexedIndirect = GRAPHICS,
	vkCmdDrawIndirectCount = GRAPHICS,
	vkCmdDrawIndexedIndirectCount = GRAPHICS,
	vkCmdDrawMeshTasksEXT = GRAPHICS,
	vkCmdDispatch = COMPUTE,
	vkCmdDispatchIndirect = COMPUTE,
	vkCmdDispatchBase = COMPUTE,
	vkCmdTraceRaysKHR = RAYTRACING,
	vkCmdTraceRaysIndirectKHR = RAYTRACING,
}
local parse_cubin
-- a warp sample with stall reason n is STALL_REASONS[n]: the order of the PCSampler stall metrics in the
-- Ada GPU Trace config, checked against shaders built to stall on each
ngfx_gputrace.STALL_REASONS = {
	"drain",
	"imc_miss",
	"barrier",
	"membar",
	"sleeping",
	"branch_resolving",
	"wait",
	"long_scoreboard_rtcore",
	"long_scoreboard",
	"short_scoreboard",
	"no_instruction",
	"math_pipe_throttle",
	"tex_throttle",
	"mio_throttle_rtcore",
	"lg_throttle",
	"mio_throttle",
	"dispatch_stall",
	"selected",
	"not_selected",
	"misc",
}
local PIPELINE_NAMES_DIRECTORY = "./storage/shader_source/pipelines/"
local PIPELINE_KINDS = {[1] = "graphics", [2] = "compute", [3] = "raytracing"}

local function read_u64(ptr, pos)
	local words = ffi.cast(uint32_ptr_t, ptr + pos)
	return words[0] + words[1] * 4294967296
end

do
	local uint16_ptr_t = ffi.typeof("const uint16_t *")
	local SECTION_MAGIC = 0x1234
	local CHUNK_MAGIC = 0x4321
	local CHUNK_STORED, CHUNK_LZ4 = 0, 1
	local SUPPORTED_VERSIONS = {[10] = true, [11] = true}

	-- WRPV header, then sections {u16 magic, u16 is_report, u16 is_counters, u16, u32 chunk count, u32, u64 size}
	-- each followed by chunks {u16 magic, u16 compression, u32, u64 stored size, u64 size} and their data
	function ngfx_gputrace.Open(path)
		local file = assert(io.open(path, "rb"))
		local data = file:read("*a")
		file:close()
		local ptr = ffi.cast(uint8_ptr_t, data)

		if #data < 8 or ffi.string(ptr, 4) ~= "WRPV" then
			error(path .. " is not a ngfx-gputrace file", 2)
		end

		local self = setmetatable({data = data, ptr = ptr, sections = {}, decoded = {}}, Trace)
		self.version = ffi.cast(uint32_ptr_t, ptr + 4)[0]

		if not SUPPORTED_VERSIONS[self.version] then
			error(path .. " is WRPV version " .. self.version .. ", only 10 and 11 are known", 2)
		end

		local pos = 8

		while pos < #data do
			local header = ffi.cast(uint16_ptr_t, ptr + pos)

			if header[0] ~= SECTION_MAGIC then
				error("bad section magic at offset " .. pos, 2)
			end

			local section = {
				is_report = header[1] == 1,
				is_counters = header[2] == 1,
				size = read_u64(ptr, pos + 16),
				chunks = {},
			}
			local chunk_count = ffi.cast(uint32_ptr_t, ptr + pos + 8)[0]
			pos = pos + 24

			for i = 1, chunk_count do
				local chunk_header = ffi.cast(uint16_ptr_t, ptr + pos)

				if chunk_header[0] ~= CHUNK_MAGIC then
					error("bad chunk magic at offset " .. pos, 2)
				end

				if chunk_header[1] ~= CHUNK_STORED and chunk_header[1] ~= CHUNK_LZ4 then
					error("unknown chunk compression " .. chunk_header[1] .. " at offset " .. pos, 2)
				end

				local stored_size = read_u64(ptr, pos + 8)
				section.chunks[i] = {
					pos = pos + 24,
					stored_size = stored_size,
					size = read_u64(ptr, pos + 16),
					lz4 = chunk_header[1] == CHUNK_LZ4,
				}
				pos = pos + 24 + stored_size
			end

			table.insert(self.sections, section)

			if section.is_report then self.report_section = #self.sections end

			if section.is_counters then self.counter_section = #self.sections end
		end

		if not self.report_section then error(path .. " has no report section", 2) end

		return self
	end

	function Trace:GetSection(index)
		local decoded = self.decoded[index]

		if decoded then return decoded.ptr, decoded.size end

		local section = self.sections[index]
		local out = byte_array_t(section.size)
		local offset = 0

		for _, chunk in ipairs(section.chunks) do
			if chunk.lz4 then
				local part = lz4.DecodeBlock(self.ptr, chunk.pos, chunk.pos + chunk.stored_size, chunk.size)
				ffi.copy(out + offset, part, chunk.size)
			else
				ffi.copy(out + offset, self.ptr + chunk.pos, chunk.size)
			end

			offset = offset + chunk.size
		end

		if offset ~= section.size then
			error(
				"section " .. index .. " chunks hold " .. offset .. " of " .. section.size .. " bytes",
				2
			)
		end

		decoded = {ptr = out, size = section.size}
		self.decoded[index] = decoded
		return out, section.size
	end
end

function Trace:GetRoot()
	if not self.root then
		local ptr, size = self:GetSection(self.report_section)
		self.root = Decode(ptr, 0, size)
	end

	return self.root, self.decoded[self.report_section].ptr
end

function Trace:GetMessages()
	local root, ptr = self:GetRoot()
	local out = {}

	for _, message in ipairs(FindAll(root, ROOT_MESSAGES)) do
		local field = Find(Decode(ptr, message[3], message[4]), 2)
		out[#out + 1] = String(ptr, field)
	end

	return out
end

-- {{name = "GPU", entries = {{"Device Name", "NVIDIA GeForce RTX 4090"}, ...}}, ...}
function Trace:GetInfo()
	local root, ptr = self:GetRoot()
	local groups = {}

	for _, group in ipairs(FindAll(root, ROOT_INFO)) do
		local fields = Decode(ptr, group[3], group[4])
		local entries = {}

		for _, entry in ipairs(FindAll(fields, 2)) do
			local kv = Decode(ptr, entry[3], entry[4])
			local key, value = Find(kv, 1), Find(kv, 2)
			entries[#entries + 1] = {String(ptr, key), value and String(ptr, value) or ""}
		end

		groups[#groups + 1] = {name = String(ptr, Find(fields, 1)), entries = entries}
	end

	return groups
end

function Trace:GetInfoValue(group_name, key)
	for _, group in ipairs(self:GetInfo()) do
		if group.name == group_name then
			for _, entry in ipairs(group.entries) do
				if entry[1] == key then return entry[2] end
			end
		end
	end
end

function Trace:GetProcesses()
	local root, ptr = self:GetRoot()
	local list = Find(root, ROOT_PROCESSES)
	local out = {}

	for _, process in ipairs(FindAll(Decode(ptr, list[3], list[4]), 2)) do
		local fields = Decode(ptr, process[3], process[4])
		out[#out + 1] = {pid = Find(fields, 1)[3], name = String(ptr, Find(fields, 2))}
	end

	return out
end

-- returns the png file contents and the size of the frame that was captured
function Trace:GetScreenshot()
	local root, ptr = self:GetRoot()
	local api = Decode(ptr, Find(root, ROOT_API)[3], Find(root, ROOT_API)[4])
	local shot = Find(api, API_SCREENSHOT)
	local fields = Decode(ptr, shot[3], shot[4])
	local image = Find(fields, 3)
	local png = Find(Decode(ptr, image[3], image[4]), 2)
	return {
		png = String(ptr, png),
		width = Find(fields, 5)[3],
		height = Find(fields, 6)[3],
		present_mode = String(ptr, Find(fields, 8)),
		format = String(ptr, Find(fields, 9)),
	}
end

do
	local ENUM, UINT, FLAGS, POINTER, HANDLE, STRUCT, ARRAY = 1, 3, 4, 8, 9, 10, 11
	local decode_arg

	local function decode_members(ptr, field)
		local members = {}

		for _, member in ipairs(FindAll(Decode(ptr, field[3], field[4]), 1)) do
			local name, value = decode_arg(ptr, member)
			members[name] = value
		end

		return members
	end

	-- an argument is {1 = name, 2 = kind, 3 = type name, 100 + kind = value}
	function decode_arg(ptr, arg)
		local fields = Decode(ptr, arg[3], arg[4])
		local name = String(ptr, Find(fields, 1))
		local kind = Find(fields, 2)
		kind = kind and kind[3] or 0
		local value = Find(fields, 100 + kind)

		if not value or value[2] ~= protobuf.WIRE_LENGTH then return name, nil end

		if kind == STRUCT then return name, decode_members(ptr, value) end

		if kind == ARRAY then
			local items = {}

			for _, item in ipairs(FindAll(Decode(ptr, value[3], value[4]), 1)) do
				items[#items + 1] = select(2, decode_arg(ptr, item))
			end

			return name, items
		end

		local inner = Decode(ptr, value[3], value[4])

		if kind == ENUM or kind == FLAGS then
			local text = Find(inner, 2)

			if text then return name, String(ptr, text) end
		elseif kind == HANDLE then
			return name, String(ptr, Find(inner, 1))
		end

		local first = inner[1]

		if not first then return name, 0 end

		if first[2] == protobuf.WIRE_LENGTH then return name, String(ptr, first) end

		return name, first[3]
	end

	-- every recorded call: {name = "vkCmdDispatch", args = {commandBuffer = "0x...", groupCountX = 8}, list = n}
	-- list is which captured call list the call came from (a queue submit and each command buffer get one)
	-- the gpu timestamps of a call list: {next_call = index of the first call after it, ptimer = int64 ns}
	local function decode_timestamps(ptr, fields)
		local timestamps = {}

		for _, timestamp in ipairs(FindAll(fields, 2)) do
			local timestamp_fields = Decode(ptr, timestamp[3], timestamp[4])
			local value = Find(timestamp_fields, 1)
			local next_call = Find(timestamp_fields, 2)

			if value then
				local ptimer = Find(Decode(ptr, value[3], value[4]), 2)

				if ptimer then
					timestamps[#timestamps + 1] = {
						next_call = next_call and next_call[3] or 0,
						ptimer = ffi.cast("int64_t", ptimer[3]),
					}
				end
			end
		end

		return timestamps
	end

	function Trace:GetApiCalls()
		if self.api_calls then return self.api_calls end

		local root, ptr = self:GetRoot()
		local api = Find(root, ROOT_API)
		local session = Find(Decode(ptr, api[3], api[4]), 2)
		local calls = {}
		self.call_lists = {}

		for list_index, list in ipairs(FindAll(Decode(ptr, session[3], session[4]), API_CALL_LISTS)) do
			local list_fields = Decode(ptr, list[3], list[4])
			local list_calls = {}

			for call_index, call in ipairs(FindAll(list_fields, 1)) do
				local fields = Decode(ptr, call[3], call[4])
				local args = {}

				for _, arg in ipairs(FindAll(fields, 3)) do
					local name, value = decode_arg(ptr, arg)
					args[name] = value
				end

				local entry = {
					name = String(ptr, Find(fields, 1)),
					args = args,
					list = list_index,
					index = call_index - 1,
				}
				calls[#calls + 1] = entry
				list_calls[call_index] = entry
			end

			self.call_lists[list_index] = {calls = list_calls, timestamps = decode_timestamps(ptr, list_fields)}
		end

		self.api_calls = calls
		return calls
	end
end

function Trace:GetProcessId()
	local root, ptr = self:GetRoot()
	local list = Find(root, ROOT_PROCESSES)
	return Find(Decode(ptr, list[3], list[4]), 1)[3]
end

-- the shader profiler report: code regions on the gpu with the pipeline that owns them
function Trace:GetPipelines()
	if self.pipelines then return self.pipelines, self.regions end

	local root, ptr = self:GetRoot()
	local api = Decode(ptr, Find(root, ROOT_API)[3], Find(root, ROOT_API)[4])
	local profile = Find(api, 8)
	local report = Find(Decode(ptr, profile[3], profile[4]), 3)
	local body = Find(Decode(ptr, report[3], report[4]), 1)
	local fields = Decode(ptr, body[3], body[4])
	local pipelines = {}

	for i, entry in ipairs(FindAll(fields, 7)) do
		local wrapper = Decode(ptr, entry[3], entry[4])[1]
		local info = Decode(ptr, wrapper[3], wrapper[4])
		pipelines[i] = {
			index = i - 1,
			handle = String(ptr, Find(info, 1)),
			kind = PIPELINE_KINDS[wrapper[1]],
			regions = {},
		}
	end

	local regions = {}

	for _, entry in ipairs(FindAll(fields, 9)) do
		local wrapper = Decode(ptr, entry[3], entry[4])[1]
		local info = Decode(ptr, wrapper[3], wrapper[4])
		local range = Decode(ptr, Find(info, 1)[3], Find(info, 1)[4])
		local pipeline = pipelines[Find(info, 6)[3] + 1]
		local cubin = Find(info, 5)

		-- {1 = {1 = blob index}}
		if cubin then
			cubin = Decode(ptr, cubin[3], cubin[4])[1]
			cubin = Find(Decode(ptr, cubin[3], cubin[4]), 1)[3]
		end

		local region = {
			address = Find(range, 1)[3],
			size = Find(range, 2)[3],
			stage = Find(info, 2)[3],
			pipeline = pipeline,
			cubin_blob = cubin,
		}
		table.insert(pipeline.regions, region)
		table.insert(regions, region)
	end

	local ok, err = pcall(self.AddRayTracingRegions, self, fields, pipelines, regions)

	if not ok then self.ray_tracing_error = err end

	table.sort(regions, function(a, b)
		return a.address < b.address
	end)

	local names = io.open(PIPELINE_NAMES_DIRECTORY .. self:GetProcessId() .. ".tsv")

	if names then
		local by_handle = {}

		for _, pipeline in ipairs(pipelines) do
			by_handle[pipeline.handle] = pipeline
		end

		for line in names:lines() do
			local handle, _, name = line:match("^(%S+)\t(%S+)\t(.*)$")

			if by_handle[handle] then by_handle[handle].name = name end
		end

		names:close()
	end

	self.pipelines = pipelines
	self.regions = regions
	return pipelines, regions
end

-- returns the region whose code contains the program counter
function Trace:FindRegion(pc)
	local regions = select(2, self:GetPipelines())
	local lo, hi = 1, #regions

	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local region = regions[mid]

		if pc < region.address then
			hi = mid - 1
		elseif pc >= region.address + region.size then
			lo = mid + 1
		else
			return region
		end
	end
end

-- Warp state samples. Every sm has time slices (timestamp, running sample count) and 16 byte samples
-- {pc, 0, warp slot (0-47), stall reason, flag}. Times are nanoseconds from the first slice of the trace.
do
	local sample_t = ffi.typeof(
		"struct { uint64_t pc; uint32_t reserved; uint8_t warp; uint8_t reason; uint8_t flag; uint8_t pad; }"
	)
	local sample_ptr_t = ffi.typeof("$ *", sample_t)
	local uint64_ptr_t = ffi.typeof("const uint64_t *")
	local MAX_PIPELINE_SEGMENT_GAP = 2

	-- false when the trace was taken without the real-time shader profiler
	function Trace:GetWarpSampling()
		if self.warp_sampling ~= nil then return self.warp_sampling end

		local root, ptr = self:GetRoot()
		local session = Find(root, ROOT_SESSION)
		local profile = Find(Decode(ptr, session[3], session[4]), 3)
		local sms = {}
		local base

		for _, entry in ipairs(FindAll(Decode(ptr, profile[3], profile[4]), 8)) do
			local fields = Decode(ptr, entry[3], entry[4])
			local times, samples = Find(fields, 3), Find(fields, 4)
			local sm = {
				index = Find(fields, 1) and Find(fields, 1)[3] or 0,
				slices = ffi.cast(uint64_ptr_t, ptr + times[3]),
				slice_count = (times[4] - times[3]) / 16,
				samples = ffi.cast(sample_ptr_t, ptr + samples[3]),
				sample_count = (samples[4] - samples[3]) / 16,
			}
			local first = sm.slices[0]

			if not base or first < base then base = first end

			sms[#sms + 1] = sm
		end

		if not sms[1] then
			self.warp_sampling = false
			return false
		end

		local sampling = {sms = sms, base = base, sample_t = sample_t}
		local deltas = {}

		for i = 1, 64 do
			local slices = sms[1].slices
			deltas[#deltas + 1] = tonumber(slices[i * 2] - slices[i * 2 - 2])
		end

		table.sort(deltas)
		sampling.slice_ns = deltas[math.floor(#deltas / 2)]
		sampling.sample_interval_cycles = tonumber(self:GetInfoValue("Session Settings", "Warp State Sampling Interval"))
		self.warp_sampling = sampling
		return sampling
	end
end

-- Warp samples folded per pipeline. active_ns is the time at least one sample of the pipeline was
-- seen in (a lower bound of its gpu time), stalls counts samples per raw stall reason index.
-- buckets[n] is slice n of the trace: {total = samples, [pipeline index + 1] = samples}, index 0 is unattributed
function Trace:GetPipelineProfile()
	if self.pipeline_profile ~= nil then return self.pipeline_profile end

	local pipelines = self:GetPipelines()
	local sampling = self:GetWarpSampling()

	if not sampling then
		self.pipeline_profile = false
		return false
	end

	local slice_ns, base = sampling.slice_ns, sampling.base
	local profiles = {}

	for i, pipeline in ipairs(pipelines) do
		profiles[i] = {
			pipeline = pipeline,
			samples = 0,
			stalls = {},
			active_buckets = {},
			active_ns = 0,
		}
	end

	local unattributed = {pipeline = false, samples = 0, stalls = {}, active_buckets = {}, active_ns = 0}
	local buckets = {}
	local total = 0
	local last_min, last_max, last_profile, last_region = 1, 0, nil, nil
	local regions = select(2, self:GetPipelines())
	local find_region = self.FindRegion

	for _, region in ipairs(regions) do
		region.pc_samples = {}
	end

	for _, sm in ipairs(sampling.sms) do
		local previous = 0

		for slice = 0, sm.slice_count - 1 do
			local count = tonumber(sm.slices[slice * 2 + 1])
			local bucket = math.floor(tonumber(sm.slices[slice * 2] - base) / slice_ns) + 1
			local entry = buckets[bucket]

			if not entry then
				entry = {total = 0}
				buckets[bucket] = entry
			end

			for i = previous, count - 1 do
				local sample = sm.samples[i]
				local pc = sample.pc
				local profile

				if pc >= last_min and pc <= last_max then
					profile = last_profile
				else
					local region = find_region(self, tonumber(pc))
					profile = region and profiles[region.pipeline.index + 1] or unattributed

					if region then
						last_min, last_max, last_profile, last_region = region.address, region.address + region.size - 1, profile, region
					end
				end

				if profile ~= unattributed then
					local offset = tonumber(pc) - last_region.address
					local pc_samples = last_region.pc_samples
					local at = pc_samples[offset]

					if not at then
						at = {samples = 0, stalls = {}}
						pc_samples[offset] = at
					end

					at.samples = at.samples + 1
					at.stalls[sample.reason] = (at.stalls[sample.reason] or 0) + 1
				end

				profile.samples = profile.samples + 1
				profile.stalls[sample.reason] = (profile.stalls[sample.reason] or 0) + 1
				profile.active_buckets[bucket] = true
				local key = profile.pipeline and profile.pipeline.index + 1 or 0
				entry[key] = (entry[key] or 0) + 1
				entry.total = entry.total + 1
				total = total + 1
			end

			previous = count
		end
	end

	profiles[#profiles + 1] = unattributed
	local bucket_count = 0

	for bucket in pairs(buckets) do
		bucket_count = math.max(bucket_count, bucket)
	end

	for _, profile in ipairs(profiles) do
		local first, last

		for bucket in pairs(profile.active_buckets) do
			profile.active_ns = profile.active_ns + slice_ns
			first = math.min(first or bucket, bucket)
			last = math.max(last or bucket, bucket)
		end

		profile.active_buckets = nil
		profile.first_ns = first and (first - 1) * slice_ns
		profile.last_ns = last and last * slice_ns
		profile.share = profile.samples / total
	end

	table.sort(profiles, function(a, b)
		return a.samples > b.samples
	end)

	self.pipeline_profile = {
		profiles = profiles,
		buckets = buckets,
		bucket_count = bucket_count,
		slice_ns = slice_ns,
		duration_ns = bucket_count * slice_ns,
		sample_count = total,
		unattributed = unattributed,
	}
	return self.pipeline_profile
end

-- draws, dispatches and ray dispatches in recording order with the pipeline that was bound for them
function Trace:GetEvents()
	if self.events then return self.events end

	local pipelines = self:GetPipelines()
	local by_handle = {}

	for _, pipeline in ipairs(pipelines) do
		by_handle[pipeline.handle] = pipeline
	end

	local events = {}
	local bound = {}

	for call_index, call in ipairs(self:GetApiCalls()) do
		local name = call.name

		if name == "vkCmdBindPipeline" then
			bound[call.args.pipelineBindPoint] = by_handle[call.args.pipeline]
		elseif EVENT_BIND_POINTS[name] then
			table.insert(
				events,
				{
					call = call,
					call_index = call_index,
					pipeline = bound[EVENT_BIND_POINTS[name]],
				}
			)
		end
	end

	self.events = events
	return events
end

-- The first call list holds the queue calls, every vkQueueSubmit after it owns the next list. Frames are
-- the submits between two vkQueuePresentKHR, each frame is {event, ...}
function Trace:GetFrames()
	if self.frames then return self.frames end

	local events_by_list = {}

	for _, event in ipairs(self:GetEvents()) do
		local list = events_by_list[event.call.list]

		if not list then
			list = {}
			events_by_list[event.call.list] = list
		end

		table.insert(list, event)
	end

	local frames = {{}}
	local list_index = 1

	for _, call in ipairs(self:GetApiCalls()) do
		if call.list == 1 then
			if call.name == "vkQueueSubmit" then
				list_index = list_index + 1
				frames[#frames].lists = frames[#frames].lists or {}
				table.insert(frames[#frames].lists, list_index)

				for _, event in ipairs(events_by_list[list_index] or {}) do
					table.insert(frames[#frames], event)
				end
			elseif call.name == "vkQueuePresentKHR" then
				table.insert(frames, {})
			end
		end
	end

	if #frames[#frames] == 0 then table.remove(frames) end

	self.frames = frames
	return frames
end

-- int64 ns that times are relative to: the first warp sample slice, or the first gpu timestamp
function Trace:GetTimeOrigin()
	if self.time_origin then return self.time_origin end

	local sampling = self:GetWarpSampling()

	if sampling then
		self.time_origin = ffi.cast("int64_t", sampling.base)
	else
		self:GetApiCalls()

		for _, list in ipairs(self.call_lists) do
			for _, timestamp in ipairs(list.timestamps) do
				if
					timestamp.ptimer > 0 and
					(
						not self.time_origin or
						timestamp.ptimer < self.time_origin
					)
				then
					self.time_origin = timestamp.ptimer
				end
			end
		end
	end

	return self.time_origin
end

-- Gpu timestamps split each submitted call list into buckets; a bucket's time covers its calls:
-- {{start_ns, end_ns, buckets = {{start_ns, end_ns, calls, events}}}} per frame
function Trace:GetFrameTimings()
	if self.frame_timings then return self.frame_timings end

	self:GetApiCalls()
	local event_of = {}

	for _, event in ipairs(self:GetEvents()) do
		event_of[event.call] = event
	end

	local origin = self:GetTimeOrigin()
	local timings = {}

	for frame_index, frame in ipairs(self:GetFrames()) do
		local timing = {index = frame_index, buckets = {}}

		for _, list_index in ipairs(frame.lists or {}) do
			local list = self.call_lists[list_index]
			local timestamps = list.timestamps

			for i = 1, #timestamps - 1 do
				local from, to = timestamps[i], timestamps[i + 1]

				if from.ptimer > 0 and to.ptimer >= from.ptimer then
					local bucket = {
						start_ns = tonumber(from.ptimer - origin),
						end_ns = tonumber(to.ptimer - origin),
						calls = {},
						events = {},
					}

					for call_index = from.next_call + 1, to.next_call do
						local call = list.calls[call_index]
						bucket.calls[#bucket.calls + 1] = call

						if event_of[call] then bucket.events[#bucket.events + 1] = event_of[call] end
					end

					timing.buckets[#timing.buckets + 1] = bucket
					timing.start_ns = math.min(timing.start_ns or bucket.start_ns, bucket.start_ns)
					timing.end_ns = math.max(timing.end_ns or bucket.end_ns, bucket.end_ns)
				end
			end
		end

		if timing.buckets[1] then timings[#timings + 1] = timing end
	end

	self.frame_timings = timings
	return timings
end

-- Hardware counters of the counter section, evaluated by Nsight's PerfWorks library (ngfx_perfworks.FindLibrary).
-- A column is the max of its metrics in percent; the names are those of the metric sets' rows, and a column
-- whose metrics the capture's metric set did not collect is left out.
do
	local PCT = ".avg.pct_of_peak_sustained_elapsed"
	local COUNTER_COLUMNS = {
		{
			name = "sm",
			metrics = {
				"smsp__inst_executed" .. PCT,
				"sm__inst_executed_pipe_alu_realtime" .. PCT,
				"SM_C.TriageSCG.smsp__inst_executed_pipe_fma" .. PCT,
				"SM_C.TriageSCG.smsp__inst_executed_pipe_fmaheavy" .. PCT,
				"sm__inst_executed_pipe_xu_realtime" .. PCT,
				"sm__pipe_tensor_cycles_active_realtime" .. PCT,
			},
		},
		{
			name = "l2",
			metrics = {"LTS.TriageSCG.lts__throughput" .. PCT, "LTS.TriageAC.lts__throughput" .. PCT},
		},
		{
			name = "vram",
			metrics = {
				"FBSP.TriageSCG.dramc__throughput" .. PCT,
				"FBSP.TriageAC.dramc__throughput" .. PCT,
			},
		},
		{name = "rt", metrics = {"rtcore__cycles_executed" .. PCT}},
		{
			name = "rop",
			metrics = {
				"ROP.TriageSCG.crop__throughput" .. PCT,
				"ROP.TriageSCG.zrop__throughput" .. PCT,
			},
		},
		{
			name = "raster",
			metrics = {
				"GPC_A.TriageSCG.raster__throughput" .. PCT,
				"GPC_A.TriageSCG.prop__throughput" .. PCT,
			},
		},
		{
			name = "l2hit",
			metrics = {"LTS.TriageSCG.lts__average_t_sector_hit_rate_realtime.pct"},
		},
	}

	-- {starts = {}, ends = {}, columns = {{name, values = {per range}}}}, false without counters or PerfWorks
	function Trace:GetCounters()
		if self.counters ~= nil then return self.counters end

		self.counters = false
		local ngfx_perfworks = import("goluwa/codecs/ngfx_perfworks.lua")
		local path = self.counter_section and ngfx_perfworks.FindLibrary()

		if not path then return false end

		ngfx_perfworks.Load(path)
		local image = ngfx_perfworks.OpenImage(self:GetSection(self.counter_section))
		local names = {}

		for _, column in ipairs(COUNTER_COLUMNS) do
			for _, name in ipairs(column.metrics) do
				names[#names + 1] = name
			end
		end

		local values = image:Evaluate(names)
		local origin = self:GetTimeOrigin()
		local counters = {starts = {}, ends = {}, columns = {}, chip_name = image.chip_name}

		for range = 0, image.range_count - 1 do
			local start, stop = image:GetRangeTime(range)
			counters.starts[range + 1] = tonumber(ffi.cast("int64_t", start) - origin)
			counters.ends[range + 1] = tonumber(ffi.cast("int64_t", stop) - origin)
		end

		for _, column in ipairs(COUNTER_COLUMNS) do
			local series

			for _, name in ipairs(column.metrics) do
				if values[name] then
					series = series or {}

					for range, value in ipairs(values[name]) do
						if value and (not series[range] or value > series[range]) then
							series[range] = value
						end
					end
				end
			end

			if series then
				counters.columns[#counters.columns + 1] = {name = column.name, values = series}
			end
		end

		self.counters = counters
		return counters
	end

	-- time weighted average of every counter column over [start_ns, end_ns): {[column name] = value}
	function Trace:GetCounterAverages(start_ns, end_ns)
		local counters = self:GetCounters()

		if not counters then return {} end

		local starts, ends = counters.starts, counters.ends
		local lo, hi = 1, #ends

		while lo < hi do
			local mid = math.floor((lo + hi) / 2)

			if ends[mid] <= start_ns then lo = mid + 1 else hi = mid end
		end

		local out = {}

		for _, column in ipairs(counters.columns) do
			local sum, weight = 0, 0
			local range = lo

			while range <= #starts and starts[range] < end_ns do
				local overlap = math.min(ends[range], end_ns) - math.max(starts[range], start_ns)
				local value = column.values[range]

				if value and overlap > 0 then
					sum = sum + value * overlap
					weight = weight + overlap
				end

				range = range + 1
			end

			if weight > 0 then out[column.name] = sum / weight end
		end

		return out
	end
end

-- the frame the warp samples were taken in, else the first timed frame
function Trace:GetTracedFrame()
	local timings = self:GetFrameTimings()

	if self:GetWarpSampling() then
		for _, timing in ipairs(timings) do
			if timing.end_ns > 0 and timing.start_ns < self:GetPipelineProfile().duration_ns then
				return timing
			end
		end
	end

	return timings[1]
end

do
	local KEYSTREAM_PATH = "./storage/ngfx_keystream.bin"
	local SHADER_CACHE_DIRECTORY = "./storage/cache/shaders/"
	local COMPRESSION_NONE, DEPRECATED_COMPRESSION_LZ4, COMPRESSION_LZ4 = 1, 2, 3
	local OBFUSCATION_NONE, DEPRECATED_OBFUSCATION_SIMPLE, OBFUSCATION_SIMPLE = 1, 2, 3
	local COMPRESSIONS = {
		[COMPRESSION_NONE] = true,
		[DEPRECATED_COMPRESSION_LZ4] = true,
		[COMPRESSION_LZ4] = true,
	}
	local OBFUSCATIONS = {
		[OBFUSCATION_NONE] = true,
		[DEPRECATED_OBFUSCATION_SIMPLE] = true,
		[OBFUSCATION_SIMPLE] = true,
	}
	local SPIRV_MAGIC = 0x07230203
	local ELF_MAGIC = 0x464C457F
	local bxor = bit.bxor
	local keystream

	function ngfx_gputrace.GetKeystream()
		if keystream == nil then
			keystream = false
			local file = io.open(KEYSTREAM_PATH, "rb")

			if file then
				local data = file:read("*a")
				file:close()
				keystream = {data = data, ptr = ffi.cast(uint8_ptr_t, data), size = #data}
			end
		end

		return keystream or nil
	end

	function Trace:GetBlobs()
		if self.blobs then return self.blobs end

		local root, ptr = self:GetRoot()
		local api = Find(root, ROOT_API)
		local profile = Find(Decode(ptr, api[3], api[4]), 8)
		local list = Find(Decode(ptr, profile[3], profile[4]), 6)
		local blobs = {}

		for _, entry in ipairs(FindAll(Decode(ptr, list[3], list[4]), 1)) do
			local fields = Decode(ptr, entry[3], entry[4])
			local data = Find(fields, 2)
			local size, compression, obfuscation = Find(fields, 3), Find(fields, 4), Find(fields, 5)
			blobs[#blobs + 1] = {
				pos = data[3],
				length = data[4] - data[3],
				size = size and size[3] or data[4] - data[3],
				compression = compression and compression[3] or COMPRESSION_NONE,
				obfuscation = obfuscation and obfuscation[3] or OBFUSCATION_NONE,
			}
		end

		self.blobs = blobs
		self.blob_data = {}
		return blobs
	end

	-- index is 0 based, as referenced from the report
	local function xor_keystream(data, length, index)
		local key = ngfx_gputrace.GetKeystream()

		if not key or key.size < length then
			error(
				string.format(
					"blob %d needs %d bytes of keystream, %s has %d: run luajit glw ngfx --calibrate",
					index,
					length,
					KEYSTREAM_PATH,
					key and key.size or 0
				),
				3
			)
		end

		local plain = byte_array_t(length)

		for i = 0, length - 1 do
			plain[i] = bxor(data[i], key.ptr[i])
		end

		return plain
	end

	-- Nsight 2026.4 xors the lz4 data (value 3 of both enums), older versions compress the xored plain text
	-- (DEPRECATED_COMPRESSION_LZ4 and DEPRECATED_OBFUSCATION_SIMPLE, value 2); the keystream is the same
	function Trace:GetBlob(index)
		local blobs = self:GetBlobs()
		local cached = self.blob_data[index]

		if cached then return cached, blobs[index + 1].size end

		local blob = blobs[index + 1]
		local _, ptr = self:GetRoot()
		local compression, obfuscation = blob.compression, blob.obfuscation

		if not COMPRESSIONS[compression] or not OBFUSCATIONS[obfuscation] then
			error(
				string.format(
					"blob %d has unknown compression %d or obfuscation %d",
					index,
					compression,
					obfuscation
				),
				2
			)
		end

		local data = byte_array_t(blob.length)
		ffi.copy(data, ptr + blob.pos, blob.length)

		if obfuscation == OBFUSCATION_SIMPLE then
			data = xor_keystream(data, blob.length, index)
		end

		if compression ~= COMPRESSION_NONE then
			data = lz4.DecodeBlock(data, 0, blob.length, blob.size)
		end

		if obfuscation == DEPRECATED_OBFUSCATION_SIMPLE then
			data = xor_keystream(data, blob.size, index)
		end

		self.blob_data[index] = data
		return data, blob.size
	end

	function Trace:GetBlobKind(index)
		local data, size = self:GetBlob(index)

		if size < 4 then return "code" end

		local magic = ffi.cast(uint32_ptr_t, data)[0]

		if magic == SPIRV_MAGIC then return "spirv" end

		if magic == ELF_MAGIC then return "cubin" end

		return "code"
	end

	function Trace:Calibrate()
		local fs = import("goluwa/filesystem/fs.lua")
		local by_size = {}

		for _, name in ipairs(fs.get_files(SHADER_CACHE_DIRECTORY) or {}) do
			local file = io.open(SHADER_CACHE_DIRECTORY .. name, "rb")
			local header = file:read(16)
			file:close()

			if header and #header == 16 then
				local size = ffi.cast(uint32_ptr_t, ffi.cast("const char *", header) + 8)[0]
				by_size[size] = by_size[size] or {}
				table.insert(by_size[size], SHADER_CACHE_DIRECTORY .. name)
			end
		end

		local key = ngfx_gputrace.GetKeystream()
		local known = key and key.data or ""
		local longest = known
		local _, ptr = self:GetRoot()

		for _, blob in ipairs(self:GetBlobs()) do
			local current = blob.obfuscation == OBFUSCATION_SIMPLE and blob.compression == COMPRESSION_LZ4
			local deprecated = blob.obfuscation == DEPRECATED_OBFUSCATION_SIMPLE and
				blob.compression == DEPRECATED_COMPRESSION_LZ4

			if
				(
					current and
					blob.length > #longest or
					deprecated and
					blob.size > #longest
				)
				and
				by_size[blob.size]
			then
				local decoded = deprecated and lz4.DecodeBlock(ptr + blob.pos, 0, blob.length, blob.size)

				for _, path in ipairs(by_size[blob.size]) do
					local file = io.open(path, "rb")
					local data = file:read("*a")
					file:close()
					local spirv = ffi.cast(uint8_ptr_t, data) + 16
					local length, cipher, plain = blob.size, decoded, spirv

					if current then
						plain, length = lz4.EncodeBlock(spirv, blob.size)
						cipher = ptr + blob.pos
					end

					if length == (current and blob.length or blob.size) then
						local bytes = byte_array_t(length)

						for i = 0, length - 1 do
							bytes[i] = bxor(plain[i], cipher[i])
						end

						local candidate = ffi.string(bytes, length)
						local overlap = math.min(#longest, length)

						if candidate:sub(1, overlap) == longest:sub(1, overlap) then
							longest = candidate

							break
						end
					end
				end
			end
		end

		if #longest > #known then
			local file = assert(io.open(KEYSTREAM_PATH, "wb"))
			file:write(longest)
			file:close()
			keystream = nil
		end

		return #longest
	end
end

do
	local uint16_ptr_t = ffi.typeof("const uint16_t *")
	local band = bit.band
	local SPIRV_LINE_OFFSET = 6
	local STAGE_MODELS = {
		vs = 0,
		hs = 1,
		ds = 2,
		gs = 3,
		ps = 4,
		cs = 5,
		ts = 5364,
		ms = 5365,
		rgs = 5313,
		its = 5314,
		ahs = 5315,
		chs = 5316,
		rms = 5317,
		cls = 5318,
	}
	local STAGE_EXTENSIONS = {
		vs = "vert",
		hs = "tesc",
		ds = "tese",
		gs = "geom",
		ps = "frag",
		cs = "comp",
		ts = "task",
		ms = "mesh",
		rgs = "rgen",
		its = "rint",
		ahs = "rahit",
		chs = "rchit",
		rms = "rmiss",
		cls = "rcall",
	}
	local NO_CODE = {
		[248] = true,
		[8] = true,
		[317] = true,
		[247] = true,
		[246] = true,
		[54] = true,
		[56] = true,
	}
	local OP_STRING, OP_EXT_INST_IMPORT, OP_EXT_INST, OP_ENTRY_POINT, OP_CONSTANT = 7, 11, 12, 15, 43
	local OP_LINE, OP_NO_LINE, OP_LABEL, OP_FUNCTION_END = 8, 317, 248, 56
	local DEBUG_FUNCTION, DEBUG_FUNCTION_DEFINITION = 20, 101
	local DEBUG_SOURCE, DEBUG_SOURCE_CONTINUED, DEBUG_LINE, DEBUG_NO_LINE = 35, 102, 103, 104

	local function uleb(ptr, pos)
		local result, scale = 0, 1

		while true do
			local b = ptr[pos]
			pos = pos + 1
			result = result + band(b, 127) * scale

			if b < 128 then return result, pos end

			scale = scale * 128
		end
	end

	local function sleb(ptr, pos)
		local result, scale = 0, 1

		while true do
			local b = ptr[pos]
			pos = pos + 1
			result = result + band(b, 127) * scale
			scale = scale * 128

			if b < 128 then
				if band(b, 64) ~= 0 then result = result - scale end

				return result, pos
			end
		end
	end

	-- {stage = "cs", addresses = {...}, lines = {...}, functions = {{address, size}}, relocated}, rows sorted by
	-- address. Ray tracing cubins place their functions at absolute addresses and relocate the line table to them.
	function parse_cubin(ptr)
		local section_offset = read_u64(ptr, 0x28)
		local entry_size = ffi.cast(uint16_ptr_t, ptr + 0x3a)[0]
		local count = ffi.cast(uint16_ptr_t, ptr + 0x3c)[0]
		local names_index = ffi.cast(uint16_ptr_t, ptr + 0x3e)[0]
		local names_offset = read_u64(ptr, section_offset + names_index * entry_size + 0x18)
		local sections = {}

		for i = 0, count - 1 do
			local header = section_offset + i * entry_size
			local name = ffi.string(ptr + names_offset + ffi.cast(uint32_ptr_t, ptr + header)[0])
			sections[name] = {offset = read_u64(ptr, header + 0x18), size = read_u64(ptr, header + 0x20)}
		end

		local functions, symbol_values = {}, {}
		local symbols = sections[".symtab"]

		if symbols then
			for i = 0, symbols.size / 24 - 1 do
				local symbol = symbols.offset + i * 24
				local value = read_u64(ptr, symbol + 8)
				symbol_values[i] = value

				if band(ptr[symbol + 4], 0xF) == 2 and value ~= 0 then
					functions[#functions + 1] = {address = value, size = read_u64(ptr, symbol + 16)}
				end
			end
		end

		local relocations = {}
		local rela = sections[".rela.debug_line"]

		if rela then
			for i = 0, rela.size / 24 - 1 do
				local entry = rela.offset + i * 24
				relocations[read_u64(ptr, entry)] = symbol_values[ffi.cast(uint32_ptr_t, ptr + entry + 12)[0]] + read_u64(ptr, entry + 16)
			end
		end

		local result = {
			functions = functions,
			addresses = {},
			lines = {},
			relocated = next(relocations) ~= nil,
		}
		local line_section = sections[".debug_line"]

		if not line_section then return result end

		local line_offset, line_size = line_section.offset, line_section.size
		local rows = {}
		local stage
		local pos = line_offset
		local stop = line_offset + line_size

		while pos < stop do
			local unit_end = pos + 4 + ffi.cast(uint32_ptr_t, ptr + pos)[0]
			local header_length = ffi.cast(uint32_ptr_t, ptr + pos + 6)[0]
			local q = pos + 10
			local min_instruction = ptr[q]
			local line_base = ptr[q + 2] >= 128 and ptr[q + 2] - 256 or ptr[q + 2]
			local line_range = ptr[q + 3]
			local opcode_base = ptr[q + 4]
			local argument_counts = {}

			for i = 1, opcode_base - 1 do
				argument_counts[i] = ptr[q + 4 + i]
			end

			local directory = q + 4 + opcode_base

			while ptr[directory] ~= 0 do
				local name = ffi.string(ptr + directory)
				stage = stage or name:match("stage>(%w+)")
				directory = directory + #name + 1
			end

			local address, line = 0, 1
			local i = pos + 10 + header_length

			while i < unit_end do
				local op = ptr[i]
				i = i + 1

				if op >= opcode_base then
					local adjusted = op - opcode_base
					address = address + math.floor(adjusted / line_range) * min_instruction
					line = line + line_base + adjusted % line_range
					rows[#rows + 1] = {address, line}
				elseif op == 0 then
					local length
					length, i = uleb(ptr, i)
					local sub = ptr[i]

					if sub == 1 then
						address, line = 0, 1
					elseif sub == 2 then
						address = relocations[i + 1 - line_offset] or
							(
								length == 9 and
								read_u64(ptr, i + 1) or
								ffi.cast(uint32_ptr_t, ptr + i + 1)[0]
							)
					end

					i = i + length
				elseif op == 1 then
					rows[#rows + 1] = {address, line}
				elseif op == 2 then
					local value
					value, i = uleb(ptr, i)
					address = address + value * min_instruction
				elseif op == 3 then
					local value
					value, i = sleb(ptr, i)
					line = line + value
				elseif op == 8 then
					address = address + math.floor((255 - opcode_base) / line_range) * min_instruction
				elseif op == 9 then
					address = address + ffi.cast(uint16_ptr_t, ptr + i)[0]
					i = i + 2
				elseif op ~= 6 and op ~= 7 then
					for _ = 1, argument_counts[op] do
						local _
						_, i = uleb(ptr, i)
					end
				end
			end

			pos = unit_end
		end

		table.sort(rows, function(a, b)
			return a[1] < b[1]
		end)

		for i, row in ipairs(rows) do
			result.addresses[i], result.lines[i] = row[1], row[2]
		end

		result.stage = stage
		return result
	end

	-- {models = {[model] = true}, sources = {[id] = {name, text}}, source_of = {}, line_of = {}, code = {}}
	-- where the per instruction tables are indexed by instruction number (0 = first after the header), and
	-- function_at holds {name, source, line} at the instructions that define a function
	local function parse_spirv(ptr, size)
		local words = ffi.cast(uint32_ptr_t, ptr)
		local word_count = size / 4
		local strings, constants, debug_sets, sources, debug_functions = {}, {}, {}, {}, {}
		local module = {
			models = {},
			sources = sources,
			source_of = {},
			line_of = {},
			code = {},
			function_at = {},
		}
		local current_source, current_line
		local last_source
		local index = 0
		local i = 5

		while i < word_count do
			local word = words[i]
			local length = bit.rshift(word, 16)
			local op = band(word, 0xFFFF)

			if op == OP_STRING then
				strings[words[i + 1]] = ffi.string(ffi.cast("const char *", words + i + 2))
			elseif op == OP_CONSTANT and length == 4 then
				constants[words[i + 2]] = words[i + 3]
			elseif op == OP_EXT_INST_IMPORT then
				if
					ffi.string(ffi.cast("const char *", words + i + 2)):find("^NonSemantic%.Shader%.DebugInfo")
				then
					debug_sets[words[i + 1]] = true
				end
			elseif op == OP_ENTRY_POINT then
				module.models[words[i + 1]] = true
			elseif op == OP_LINE then
				current_source, current_line = words[i + 1], words[i + 2]
			elseif op == OP_NO_LINE or op == OP_LABEL or op == OP_FUNCTION_END then
				current_source, current_line = nil, nil
			end

			local is_debug = op == OP_EXT_INST and debug_sets[words[i + 3]]

			if is_debug then
				local instruction = words[i + 4]

				if instruction == DEBUG_SOURCE then
					last_source = {
						name = strings[words[i + 5]] or "",
						text = length > 6 and strings[words[i + 6]] or "",
					}
					sources[words[i + 2]] = last_source
				elseif instruction == DEBUG_FUNCTION then
					debug_functions[words[i + 2]] = {
						name = strings[words[i + 5]],
						source = words[i + 7],
						line = constants[words[i + 8]],
					}
				elseif instruction == DEBUG_FUNCTION_DEFINITION then
					module.function_at[index] = debug_functions[words[i + 5]]
				elseif instruction == DEBUG_SOURCE_CONTINUED and last_source then
					last_source.text = last_source.text .. (strings[words[i + 5]] or "")
				elseif instruction == DEBUG_LINE then
					current_source, current_line = words[i + 5], constants[words[i + 6]]
				elseif instruction == DEBUG_NO_LINE then
					current_source, current_line = nil, nil
				end
			end

			module.source_of[index] = current_source
			module.line_of[index] = current_line
			module.code[index] = not is_debug and not NO_CODE[op]
			index = index + 1
			i = i + length
		end

		module.instruction_count = index
		return module
	end

	function Trace:GetModule(index)
		self.modules = self.modules or {}

		if not self.modules[index] then
			local data, size = self:GetBlob(index)
			self.modules[index] = parse_spirv(data, size)
		end

		return self.modules[index]
	end

	-- the cubin of a region and the spir-v module it was compiled from: the modules of a pipeline are
	-- stored right before its first code blob. The match is checked against the line table.
	function Trace:GetRegionCubin(region)
		if region.cubin == nil then
			region.cubin = region.cubin_blob and
				self:GetBlobKind(region.cubin_blob) == "cubin" and
				parse_cubin(self:GetBlob(region.cubin_blob)) or
				false
		end

		return region.cubin
	end

	-- ray tracing stages are not code regions of the report: their cubins (entry 3 = {1 = {1 = {1 = blob}},
	-- 3 = pipeline}) and the driver's traversal code (entry 4) list functions at absolute addresses
	function Trace:AddRayTracingRegions(fields, pipelines, regions)
		local _, ptr = self:GetRoot()
		local internal = {
			index = #pipelines,
			handle = "",
			kind = "raytracing",
			name = "ray tracing internal",
			regions = {},
		}
		local seen = {}

		for _, region in ipairs(regions) do
			seen[region.address] = true
		end

		for _, entry in ipairs(FindAll(fields, 8)) do
			local wrapper = Decode(ptr, entry[3], entry[4])[1]

			if wrapper[1] == 3 or wrapper[1] == 4 then
				local info = Decode(ptr, wrapper[3], wrapper[4])
				local ref = Decode(ptr, Find(info, 1)[3], Find(info, 1)[4])[1]
				local blob = Find(Decode(ptr, ref[3], ref[4]), 1)
				blob = blob and blob[3] or 0
				local pipeline = internal

				if wrapper[1] == 3 then
					local index = Find(info, 3)
					pipeline = pipelines[(index and index[3] or 0) + 1]
				end

				local cubin = parse_cubin(self:GetBlob(blob))

				for _, fn in ipairs(cubin.functions) do
					if not seen[fn.address] then
						seen[fn.address] = true
						local region = {
							address = fn.address,
							size = fn.size,
							pipeline = pipeline,
							cubin_blob = blob,
							cubin = cubin,
						}
						table.insert(pipeline.regions, region)
						table.insert(regions, region)
					end
				end
			end
		end

		if internal.regions[1] then
			pipelines[#pipelines + 1] = internal
			self.internal_pipeline = internal
		end
	end

	local function line_score(cubin, module)
		local good = 0

		for _, line in ipairs(cubin.lines) do
			if module.code[line - SPIRV_LINE_OFFSET] then good = good + 1 end
		end

		return good / #cubin.lines
	end

	local function split_lines(text)
		local lines = {}

		for line in (text .. "\n"):gmatch("(.-)\r?\n") do
			lines[#lines + 1] = line
		end

		return lines
	end

	-- glslang numbers lines in the preprocessed copy of the source, which the spir-v holds after the original,
	-- and a `#line n` directive sets the number of the line below it, so the numbers of code after a snippet
	-- with `#line 1 id` restart at 1. Several physical lines can share a number: a function body starts at
	-- its declaration (name and number from DebugFunction), and the physical line of an instruction is the
	-- candidate closest to the one before it.
	local function resolve_source_lines(module)
		if module.lines_resolved then return end

		module.lines_resolved = true
		local candidates_of = {}

		for id, source in pairs(module.sources) do
			local text = source.text
			local first = text:find("#version", 1, true)
			local second = first and text:find("#version", first + 1, true)
			local preprocessed = split_lines(second and text:sub(second) or text)
			source.line_texts = second and split_lines(text:sub(1, second - 1)) or preprocessed
			local candidates = {}
			local number = 1

			for physical, line in ipairs(preprocessed) do
				local directive = line:match("^%s*#%s*line%s+(%d+)")

				if directive then
					number = tonumber(directive)
				else
					candidates[number] = candidates[number] or {}
					table.insert(candidates[number], physical)
					number = number + 1
				end
			end

			candidates_of[id] = candidates
		end

		local cursor = 1
		local last_number, last_source, last_physical

		for index = 0, module.instruction_count - 1 do
			local declared = module.function_at[index]

			if declared then
				for _, physical in ipairs(candidates_of[declared.source][declared.line] or {}) do
					if module.sources[declared.source].line_texts[physical]:find(declared.name, 1, true) then
						cursor = physical

						break
					end
				end

				last_number = nil
			end

			local number = module.line_of[index]
			local source = module.source_of[index]

			if number and candidates_of[source] then
				if number ~= last_number or source ~= last_source then
					last_number, last_source, last_physical = number, source, nil
					local best_distance

					for _, physical in ipairs(candidates_of[source][number] or {}) do
						local distance = math.abs(physical - cursor)

						if not best_distance or distance < best_distance then
							best_distance, last_physical = distance, physical
						end
					end

					cursor = last_physical or cursor
				end

				module.line_of[index] = last_physical
			end
		end
	end

	-- the spir-v module a cubin was compiled from. The modules of a pipeline are stored right before its
	-- first code blob; ray tracing stages share modules across pipelines, so those take the module of the
	-- same stage whose instructions fit the line table best.
	function Trace:GetRegionSource(region)
		if region.source ~= nil then return region.source end

		region.source = false
		local cubin = self:GetRegionCubin(region)

		if not cubin or not STAGE_MODELS[cubin.stage] or not cubin.lines[1] then
			return false
		end

		local model = STAGE_MODELS[cubin.stage]
		local module

		if cubin.relocated then
			local best, second = 0, 0

			for i = 0, #self:GetBlobs() - 1 do
				if self:GetBlobKind(i) == "spirv" and self:GetModule(i).models[model] then
					local score = line_score(cubin, self:GetModule(i))

					if score > best then
						best, second, module = score, best, self:GetModule(i)
					elseif score > second then
						second = score
					end
				end
			end

			if best < 0.9 or best - second < 0.05 then module = nil end
		else
			local i = region.cubin_blob - 1

			while i >= 0 and self:GetBlobKind(i) ~= "spirv" do
				i = i - 1
			end

			while i >= 0 and self:GetBlobKind(i) == "spirv" do
				if self:GetModule(i).models[model] then
					module = line_score(cubin, self:GetModule(i)) >= 0.95 and self:GetModule(i)

					break
				end

				i = i - 1
			end
		end

		if module then
			resolve_source_lines(module)
			region.source = {cubin = cubin, module = module, extension = STAGE_EXTENSIONS[cubin.stage]}
		end

		return region.source
	end

	-- warp samples of a pipeline folded per glsl line, most sampled first:
	-- {lines = {{file, line, text, samples, stalls}}, samples, unmapped}
	function Trace:GetSourceProfile(pipeline)
		self:GetPipelineProfile()
		local by_key = {}
		local lines = {}
		local total, unmapped = 0, 0

		for _, region in ipairs(pipeline.regions) do
			local source = self:GetRegionSource(region)

			for offset, entry in pairs(region.pc_samples or {}) do
				total = total + entry.samples
				local key

				if source then
					local address = source.cubin.relocated and region.address + offset or offset
					local addresses = source.cubin.addresses
					local lo, hi = 1, #addresses

					while lo < hi do
						local mid = math.ceil((lo + hi) / 2)

						if addresses[mid] <= address then lo = mid else hi = mid - 1 end
					end

					local instruction = addresses[lo] and
						addresses[lo] <= address and
						source.cubin.lines[lo] - SPIRV_LINE_OFFSET
					local module = source.module
					local source_id = instruction and module.source_of[instruction]
					local line = instruction and module.line_of[instruction]

					if source_id and line then
						key = source_id .. ":" .. line .. ":" .. source.extension

						if not by_key[key] then
							local text = module.sources[source_id]
							local file = text and
								text.name ~= "" and
								text.name or
								(
									pipeline.name or
									pipeline.handle
								) .. "." .. source.extension
							by_key[key] = {
								file = file,
								line = line,
								text = text and text.line_texts[line] or "",
								samples = 0,
								stalls = {},
							}
							lines[#lines + 1] = by_key[key]
						end
					end
				end

				if key then
					local target = by_key[key]
					target.samples = target.samples + entry.samples

					for reason, n in pairs(entry.stalls) do
						target.stalls[reason] = (target.stalls[reason] or 0) + n
					end
				else
					unmapped = unmapped + entry.samples
				end
			end
		end

		table.sort(lines, function(a, b)
			return a.samples > b.samples
		end)

		return {lines = lines, samples = total, unmapped = unmapped}
	end
end

local function describe_event(event)
	local args = event.call.args
	local name = event.call.name:gsub("^vkCmd", "")

	if args.groupCountX then
		return string.format("%s %dx%dx%d", name, args.groupCountX, args.groupCountY, args.groupCountZ)
	elseif args.vertexCount then
		return string.format("%s %d verts x%d", name, args.vertexCount, args.instanceCount)
	elseif args.indexCount then
		return string.format("%s %d indices x%d", name, args.indexCount, args.instanceCount)
	elseif args.width then
		return string.format("%s %dx%dx%d", name, args.width, args.height, args.depth)
	elseif args.maxDrawCount then
		return string.format("%s max %d", name, args.maxDrawCount)
	end

	return name
end

local function top_stalls(stalls, samples, count)
	local list = {}

	for reason, n in pairs(stalls) do
		list[#list + 1] = {reason, n}
	end

	table.sort(list, function(a, b)
		return a[2] > b[2]
	end)

	local out = {}

	for i = 1, math.min(count, #list) do
		out[i] = string.format(
			"%s %.0f%%",
			ngfx_gputrace.STALL_REASONS[list[i][1]] or "r" .. list[i][1],
			list[i][2] / samples * 100
		)
	end

	return table.concat(out, ", ")
end

-- A text summary: gpu time per frame and per timed group of calls, warp samples per pipeline and glsl line
function Trace:GetReport()
	local lines = {}
	local profile = self:GetPipelineProfile()
	local sampling = self:GetWarpSampling()

	local function add(...)
		lines[#lines + 1] = string.format(...)
	end

	add(
		"%s, driver %s, %s",
		self:GetInfoValue("GPU", "Device Name"),
		self:GetInfoValue("GPU", "Driver Version"),
		self:GetInfoValue("Session", "Command Line")
	)
	local frames = self:GetFrameTimings()
	local traced = self:GetTracedFrame()

	if frames[1] then
		local durations = {}

		for i, frame in ipairs(frames) do
			durations[i] = string.format("%.2f", (frame.end_ns - frame.start_ns) / 1e6)
		end

		add(
			"gpu time of the %d recorded frames from gpu timestamps: %s ms",
			#frames,
			table.concat(durations, ", ")
		)
	end

	if profile then
		add(
			"warp samples: %.3f ms in %d slices of %.2f us, %d sms, %d samples",
			profile.duration_ns / 1e6,
			profile.bucket_count,
			profile.slice_ns / 1e3,
			#sampling.sms,
			profile.sample_count
		)
	else
		add("no warp samples: the trace was taken without the real-time shader profiler")
	end

	local ok, counters = pcall(self.GetCounters, self)

	if not ok then
		add("hardware counters unavailable: %s", counters)
		counters = false
	elseif not counters then
		add(
			"hardware counters unavailable: no counter section or no PerfWorks library (set NGFX_NVPERF)"
		)
	end

	local counter_header, counter_format = "", ""

	if counters then
		for _, column in ipairs(counters.columns) do
			counter_header = counter_header .. string.format(" %5s", column.name)
		end

		add(
			"counters are %% of peak (l2hit is the l2 hit rate), time weighted over the row, from %s PerfWorks",
			counters.chip_name
		)
	end

	if traced then
		local frame_ns = traced.end_ns - traced.start_ns
		add("")
		add(
			"frame %d in recording order: each row is the calls between two gpu timestamps, start is from the frame start",
			traced.index
		)
		add(
			"%9s %10s %6s%s  %-10s %-4s %-32s %s",
			"start ms",
			"time us",
			"%",
			counter_header,
			"kind",
			"pipe",
			"shader",
			"calls"
		)

		for _, bucket in ipairs(traced.buckets) do
			local duration = bucket.end_ns - bucket.start_ns
			local first = bucket.events[1]

			if first or duration >= 5000 then
				local label

				if first then
					label = describe_event(first)

					if #bucket.events > 1 then
						label = label .. " (+" .. #bucket.events - 1 .. " more)"
					end
				else
					local counts, order = {}, {}

					for _, call in ipairs(bucket.calls) do
						local name = call.name:gsub("^vkCmd", "")

						if not counts[name] then order[#order + 1] = name end

						counts[name] = (counts[name] or 0) + 1
					end

					for i, name in ipairs(order) do
						order[i] = counts[name] > 1 and name .. " x" .. counts[name] or name
					end

					label = table.concat(order, ", ")
				end

				local pipeline = first and first.pipeline
				local counter_text = ""

				if counters then
					local averages = self:GetCounterAverages(bucket.start_ns, bucket.end_ns)

					for _, column in ipairs(counters.columns) do
						local value = averages[column.name]
						counter_text = counter_text .. (value and string.format(" %5.0f", value) or "     -")
					end
				end

				add(
					"%9.3f %10.1f %5.1f%%%s  %-10s %-4s %-32s %s",
					(bucket.start_ns - traced.start_ns) / 1e6,
					duration / 1e3,
					duration / frame_ns * 100,
					counter_text,
					pipeline and pipeline.kind or "",
					pipeline and tostring(pipeline.index + 1) or "",
					pipeline and (pipeline.name or pipeline.handle) or "",
					label
				)
			end
		end
	end

	if not profile then return table.concat(lines, "\n") end

	add("")
	add("pipelines by warp samples")
	add(
		"%-4s %-10s %-30s %9s %6s %10s  %s",
		"pipe",
		"kind",
		"shader",
		"samples",
		"%",
		"active us",
		"top stalls"
	)

	for i, entry in ipairs(profile.profiles) do
		if i > 25 then break end

		add(
			"%-4s %-10s %-30s %9d %5.1f%% %10.1f  %s",
			entry.pipeline and entry.pipeline.index + 1 or "-",
			entry.pipeline and entry.pipeline.kind or "unmatched",
			entry.pipeline and (entry.pipeline.name or entry.pipeline.handle) or "",
			entry.samples,
			entry.share * 100,
			entry.active_ns / 1e3,
			top_stalls(entry.stalls, math.max(entry.samples, 1), 3)
		)
	end

	add("")
	add("hot glsl lines of the most sampled pipelines, %% is of the pipeline's samples")
	local shown = 0

	for _, entry in ipairs(profile.profiles) do
		if shown >= 10 then break end

		if entry.pipeline and entry.pipeline ~= self.internal_pipeline and entry.samples > 0 then
			shown = shown + 1
			local ok, source = pcall(self.GetSourceProfile, self, entry.pipeline)

			if not ok then
				add("%s: %s", entry.pipeline.name or entry.pipeline.handle, source)

				break
			end

			add(
				"%s (%.1f%% of all samples, %.1f%% not mapped to a line)",
				entry.pipeline.name or entry.pipeline.handle,
				entry.share * 100,
				source.unmapped / math.max(source.samples, 1) * 100
			)

			for i = 1, math.min(8, #source.lines) do
				local line = source.lines[i]
				add(
					"  %5.1f%%  %-44s %-44s %s",
					line.samples / source.samples * 100,
					line.file .. ":" .. line.line,
					top_stalls(line.stalls, line.samples, 2),
					(line.text or ""):gsub("^%s+", ""):sub(1, 100)
				)
			end
		end
	end

	return table.concat(lines, "\n")
end

function Trace:GetApiCallCounts()
	local counts = {}

	for _, call in ipairs(self:GetApiCalls()) do
		counts[call.name] = (counts[call.name] or 0) + 1
	end

	return counts
end

return ngfx_gputrace
