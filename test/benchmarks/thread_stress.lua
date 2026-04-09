local threads = import("goluwa/bindings/threads.lua")
local system = import("goluwa/system.lua")
local ffi = require("ffi")
local io = require("io")

local args = {...}
local rounds = tonumber(args[1]) or 200
local batch_size = tonumber(args[2]) or (ffi.os == "Windows" and 1 or math.max(threads.get_thread_count() * 4, 8))
local payload_size = tonumber(args[3]) or 256
local log_path = args[4] or "game/storage/logs/thread_stress.log"

local function log_line(...)
	local parts = {}

	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end

	local line = table.concat(parts, " ")
	print(line)

	local handle = assert(io.open(log_path, "a"))

	if handle then
		handle:write(line, "\n")
		handle:flush()
		handle:close()
	end
	end

local function make_payload(tag, round, index)
	return string.rep(string.char(65 + ((round + index) % 26)), payload_size) .. ":" .. tag .. ":" .. round .. ":" .. index
end

local function should_log_worker(round, index)
	if round == 0 then return true end
	if index <= 4 then return true end
	return index % 8 == 0 or index == batch_size
end

local serialized_worker = [=[
	local input = ...
	local threads = import("goluwa/bindings/threads.lua")
	local checksum = 0

	for i = 1, #input.payload do
		checksum = (checksum + input.payload:byte(i) * i) % 2147483647
	end

	threads.sleep(input.sleep_ms)
	return {
		round = input.round,
		index = input.index,
		checksum = checksum,
		payload_len = #input.payload,
	}
]=]

ffi.cdef[[
	typedef struct {
		int round;
		int index;
		int iterations;
		int checksum;
		volatile int done;
	} stress_shared_t;
]]

local shared_worker = [=[
	local shared_ptr = ...
	local ffi = require("ffi")
	local threads = import("goluwa/bindings/threads.lua")
	ffi.cdef[[
		typedef struct {
			int round;
			int index;
			int iterations;
			int checksum;
			volatile int done;
		} stress_shared_t;
	]]
	local job = ffi.cast("stress_shared_t*", shared_ptr)
	local checksum = 0

	for i = 1, job.iterations do
		checksum = (checksum + ((job.round + job.index + i) % 97)) % 2147483647
	end

	threads.sleep((job.index % 3) + 1)
	job.checksum = checksum
	job.done = 1
]=]

local run_shared_phase = ffi.os ~= "Windows"

local function start_serialized_batch(round)
	local workers = {}

	for index = 1, batch_size do
		if should_log_worker(round, index) then
			log_line("round", round, "phase", "serialized", "new", index)
		end

		local worker = threads.new(serialized_worker)

		if should_log_worker(round, index) then
			log_line("round", round, "phase", "serialized", "run", index)
		end

		worker:run({
			round = round,
			index = index,
			payload = make_payload("serialized", round, index),
			sleep_ms = (index % 4) + 1,
		})
		workers[index] = worker
	end

	return workers
end

local function join_serialized_batch(round, workers)
	local combined = 0

	for index = 1, #workers do
		if should_log_worker(round, index) then
			log_line("round", round, "phase", "serialized", "join", index)
		end

		local result, err = workers[index]:join()

		if err then error(string.format("serialized round %d worker %d failed: %s", round, index, tostring(err))) end

		if not result or result.round ~= round or result.index ~= index then
			error(string.format("serialized round %d worker %d returned invalid result", round, index))
		end

		combined = (combined + result.checksum + result.payload_len) % 2147483647
	end

	for index = 1, #workers do
		assert(workers[index]:close())
		workers[index] = nil
	end

	return combined
end

local function start_shared_batch(round)
	local jobs = {}
	local workers = {}

	for index = 1, batch_size do
		local job = ffi.new("stress_shared_t[1]")
		job[0].round = round
		job[0].index = index
		job[0].iterations = payload_size * 32 + index
		job[0].checksum = 0
		job[0].done = 0
		jobs[index] = job

		if should_log_worker(round, index) then
			log_line("round", round, "phase", "shared", "new", index)
		end

		local worker = threads.new(shared_worker)

		if should_log_worker(round, index) then
			log_line("round", round, "phase", "shared", "run", index)
		end

		worker:run(job, true)
		workers[index] = worker
	end

	return jobs, workers
end

local function join_shared_batch(round, jobs, workers)
	local combined = 0

	for index = 1, #workers do
		if should_log_worker(round, index) then
			log_line("round", round, "phase", "shared", "join", index)
		end

		local _, err = workers[index]:join()

		if err then error(string.format("shared round %d worker %d failed: %s", round, index, tostring(err))) end

		if jobs[index][0].done ~= 1 then
			error(string.format("shared round %d worker %d did not mark completion", round, index))
		end

		combined = (combined + jobs[index][0].checksum) % 2147483647
	end

	for index = 1, #workers do
		assert(workers[index]:close())
		workers[index] = nil
		jobs[index] = nil
	end

	return combined
end

local function churn_gc()
	collectgarbage()
	collectgarbage()
end

local function preflight_create_only(count)
	log_line("preflight", "create_only", "start", count)
	local workers = {}

	for index = 1, count do
		log_line("preflight", "create_only", "new", index)
		workers[index] = threads.new(serialized_worker)
	end

	for index = 1, count do
		assert(workers[index]:close())
		workers[index] = nil
	end

	churn_gc()
	log_line("preflight", "create_only", "done", count)
end

local function preflight_single_serialized()
	log_line("preflight", "single_serialized", "start")
	local worker = threads.new(serialized_worker)
	worker:run({
		round = 0,
		index = 1,
		payload = make_payload("serialized", 0, 1),
		sleep_ms = 1,
	})
	local checksum = join_serialized_batch(0, {worker})
	log_line("preflight", "single_serialized", "checksum", checksum)
end

local function preflight_single_shared()
	if not run_shared_phase then
		log_line("preflight", "single_shared", "skipped", ffi.os)
		return
	end

	log_line("preflight", "single_shared", "start")
	local job = ffi.new("stress_shared_t[1]")
	job[0].round = 0
	job[0].index = 1
	job[0].iterations = payload_size * 32 + 1
	job[0].checksum = 0
	job[0].done = 0
	local worker = threads.new(shared_worker)
	worker:run(job, true)
	local checksum = join_shared_batch(0, {job}, {worker})
	log_line("preflight", "single_shared", "checksum", checksum)
end

local started = system.GetTime()
log_line("thread_stress", "rounds=", rounds, "batch=", batch_size, "payload=", payload_size)
preflight_create_only(math.min(batch_size, 8))
preflight_single_serialized()
preflight_single_shared()

for round = 1, rounds do
	log_line("round", round, "phase", "serialized", "start")
	local serialized_workers = start_serialized_batch(round)
	churn_gc()
	local serialized_checksum = join_serialized_batch(round, serialized_workers)
	log_line("round", round, "phase", "serialized", "checksum", serialized_checksum)

	if run_shared_phase then
		log_line("round", round, "phase", "shared", "start")
		local jobs, shared_workers = start_shared_batch(round)
		churn_gc()
		local shared_checksum = join_shared_batch(round, jobs, shared_workers)
		log_line("round", round, "phase", "shared", "checksum", shared_checksum)
	else
		log_line("round", round, "phase", "shared", "skipped", ffi.os)
	end

	if round % 10 == 0 then
		log_line("progress", round, "/", rounds, "elapsed", string.format("%.3f", system.GetTime() - started))
	end
end

log_line("done", "elapsed", string.format("%.3f", system.GetTime() - started))