local ffi = require("ffi")
local threads = import("goluwa/bindings/threads.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local pvars = import("goluwa/cli/pvars.lua")
local thread_pool = library()
thread_pool.inline_threshold = thread_pool.inline_threshold or 16384
local MAX_THREADS = 8

if thread_pool.pool then thread_pool.pool:shutdown() end

thread_pool.pool = nil
thread_pool.inflight = {}
thread_pool.inflight_count = 0
thread_pool.queue = {}
thread_pool.queue_head = 1
thread_pool.queue_tail = 0
local dispatcher = [[
	local work = ...
	_G.thread_pool_job = true
	local cache = _G.thread_pool_job_cache

	if not cache then
		cache = {}
		_G.thread_pool_job_cache = cache
	end

	local fn = cache[work.source]

	if not fn then
		fn = assert(load(work.source, "=thread_pool_job"))
		cache[work.source] = fn
	end

	return fn(work.input)
]]
local job_meta = {}
job_meta.__index = job_meta
local inline_cache = {}

local function normalize_blob(blob)
	if blob == nil then return nil end

	if type(blob) == "string" then
		return {ptr = ffi.cast("const uint8_t *", blob), len = #blob, owner = blob}
	end

	return {ptr = blob, len = ffi.sizeof(blob), owner = blob}
end

local function on_error(err)
	return debug.traceback(tostring(err), 2)
end

local function finish(job, meta, err, blob)
	job.done = true
	job.meta = meta
	job.err = err
	job.blob = blob
	local callbacks = job.callbacks
	job.callbacks = nil

	if callbacks then
		for i = 1, #callbacks do
			local ok, callback_err = xpcall(callbacks[i], on_error, job)

			if not ok then print("thread_pool callback error:", callback_err) end
		end
	end
end

function thread_pool.GetMaxThreads()
	if _G.thread_pool_job then return 0 end

	return pvars.Get("r_codec_threads")
end

function thread_pool.Shutdown()
	if thread_pool.pool then
		thread_pool.pool:shutdown()
		thread_pool.pool = nil
	end

	thread_pool.inflight = {}
	thread_pool.inflight_count = 0
	thread_pool.queue = {}
	thread_pool.queue_head = 1
	thread_pool.queue_tail = 0
end

local function run_inline(job)
	local fn = inline_cache[job.source]

	if not fn then
		fn = assert(load(job.source, "=thread_pool_job"))
		inline_cache[job.source] = fn
	end

	local ok, meta, blob = xpcall(fn, on_error, job.input)

	if ok then
		finish(job, meta, nil, normalize_blob(blob))
	else
		finish(job, nil, meta, nil)
	end
end

function thread_pool.Update()
	local pool = thread_pool.pool

	if not pool then return end

	for thread_id, job in pairs(thread_pool.inflight) do
		if pool:is_done(thread_id) then
			thread_pool.inflight[thread_id] = nil
			thread_pool.inflight_count = thread_pool.inflight_count - 1
			local meta, err, blob = pool:wait(thread_id)
			finish(job, meta, err, blob)
		end
	end

	while thread_pool.queue_head <= thread_pool.queue_tail do
		local thread_id

		for i = 1, pool.num_threads do
			if not pool:is_busy(i) and pool:is_spawned(i) then
				thread_id = i

				break
			end
		end

		if not thread_id then
			for i = 1, pool.num_threads do
				if not pool:is_busy(i) then
					thread_id = i

					break
				end
			end
		end

		if not thread_id then break end

		local job = thread_pool.queue[thread_pool.queue_head]
		thread_pool.queue[thread_pool.queue_head] = nil
		thread_pool.queue_head = thread_pool.queue_head + 1
		pool:submit(thread_id, {source = job.source, input = job.input})
		thread_pool.inflight[thread_id] = job
		thread_pool.inflight_count = thread_pool.inflight_count + 1
	end
end

function thread_pool.Run(source, input, size)
	assert(type(source) == "string", "thread_pool.Run requires a job source string")
	local job = setmetatable({source = source, input = input, done = false}, job_meta)
	local max_threads = thread_pool.GetMaxThreads()
	size = size or (type(input) == "string" and #input) or math.huge

	if max_threads == 0 or size < thread_pool.inline_threshold then
		run_inline(job)
		return job
	end

	local pool = thread_pool.pool

	if not pool then
		pool = threads.new_pool(dispatcher, math.min(max_threads, MAX_THREADS))
		thread_pool.pool = pool
	end

	thread_pool.queue_tail = thread_pool.queue_tail + 1
	thread_pool.queue[thread_pool.queue_tail] = job
	thread_pool.Update()
	return job
end

function job_meta:IsDone()
	return self.done
end

function job_meta:OnDone(callback)
	if self.done then
		callback(self)
		return self
	end

	self.callbacks = self.callbacks or {}
	table.insert(self.callbacks, callback)
	return self
end

function job_meta:Await()
	if not self.done then
		if tasks.GetActiveTask() then
			while not self.done do
				thread_pool.Update()

				if self.done then break end

				tasks.Wait()
			end
		else
			while not self.done do
				thread_pool.Update()

				if self.done then break end

				threads.sleep(1)
			end
		end
	end

	if self.err then error(self.err, 0) end

	return self.meta, self.blob
end

pvars.Setup2{
	key = "r_codec_threads",
	default = math.min(MAX_THREADS, math.max(1, threads.get_thread_count() - 1)),
	type = "number",
	min = 0,
	max = MAX_THREADS,
	integer = true,
	help = "number of worker threads for decoding assets, 0 decodes inline",
	callback = function(val)
		local pool = thread_pool.pool

		if
			pool and
			pool.num_threads ~= val and
			thread_pool.inflight_count == 0 and
			thread_pool.queue_head > thread_pool.queue_tail
		then
			thread_pool.Shutdown()
		end
	end,
}

event.AddListener("Update", "thread_pool", function()
	if
		thread_pool.inflight_count > 0 or
		thread_pool.queue_head <= thread_pool.queue_tail
	then
		thread_pool.Update()
	end
end)

event.AddListener("ShutDown", "thread_pool", function()
	thread_pool.Shutdown()
end)

return thread_pool
