local prototype = import("goluwa/prototype.lua")
local META = prototype.CreateTemplate("render2d_rect_batch")

local function copy_counts(input)
	local output = {}

	for key, value in pairs(input or {}) do
		output[key] = value
	end

	return output
end

local function new_frame_stats(index)
	return {
		frame_index = index or 0,
		queued_draws = 0,
		queued_segments = 0,
		flush_attempt_count = 0,
		flush_attempt_reasons = {},
		flush_count = 0,
		flush_reasons = {},
		flushed_draws = 0,
		gpu_rect_draw_calls = 0,
		draw_call_savings = 0,
		instanced_draws = 0,
		instanced_segments = 0,
		replay_draws = 0,
		max_segment_size = 0,
	}
end

local function copy_frame_stats(stats)
	local output = {}

	for key, value in pairs(stats or {}) do
		if type(value) == "table" then
			output[key] = copy_counts(value)
		else
			output[key] = value
		end
	end

	return output
end

function META.New()
	local self = META:CreateObject()
	self.pending_draws = 0
	self.flush_count = 0
	self.last_flush_reason = nil
	self.last_flushed_draws = 0
	self.total_queued_draws = 0
	self.total_queued_segments = 0
	self.total_flushed_draws = 0
	self.total_gpu_rect_draw_calls = 0
	self.frame_index = 1
	self.current_frame = new_frame_stats(self.frame_index)
	self.last_frame = new_frame_stats(0)
	self.is_flushing = false
	self.current_flush_reason = nil
	self.segments = {}
	return self
end

function META:GetStats()
	return {
		pending_draws = self.pending_draws,
		flush_count = self.flush_count,
		last_flush_reason = self.last_flush_reason,
		last_flushed_draws = self.last_flushed_draws,
		segment_count = #self.segments,
		total_queued_draws = self.total_queued_draws,
		total_queued_segments = self.total_queued_segments,
		total_flushed_draws = self.total_flushed_draws,
		total_gpu_rect_draw_calls = self.total_gpu_rect_draw_calls,
		current_frame = copy_frame_stats(self.current_frame),
		last_frame = copy_frame_stats(self.last_frame),
	}
end

function META:AdvanceFrame()
	self.last_frame = copy_frame_stats(self.current_frame)
	self.frame_index = self.frame_index + 1
	self.current_frame = new_frame_stats(self.frame_index)
	return self.last_frame
end

function META:HasPending()
	return self.pending_draws > 0
end

function META:MarkPending(count)
	self.pending_draws = self.pending_draws + (count or 1)
	return self.pending_draws
end

function META:ClearPending()
	self.pending_draws = 0
	self.segments = {}
end

function META:BeginFlush(reason)
	self.last_flush_reason = reason or "manual"
	self.current_frame.flush_attempt_count = self.current_frame.flush_attempt_count + 1
	self.current_frame.flush_attempt_reasons[self.last_flush_reason] = (self.current_frame.flush_attempt_reasons[self.last_flush_reason] or 0) + 1

	if self.is_flushing then return false end

	if self.pending_draws == 0 then return false end

	self.is_flushing = true
	self.current_flush_reason = self.last_flush_reason
	return true
end

function META:FinishFlush(flushed_draws, summary)
	if not self.is_flushing then return false end

	summary = summary or {}
	local flush_reason = self.current_flush_reason or self.last_flush_reason or "manual"
	local resolved_flushed_draws = flushed_draws or 0
	local gpu_rect_draw_calls = summary.gpu_rect_draw_calls or 0
	local draw_call_savings = math.max(0, resolved_flushed_draws - gpu_rect_draw_calls)
	self.is_flushing = false
	self.current_flush_reason = nil
	self.flush_count = self.flush_count + 1
	self.pending_draws = 0
	self.segments = {}
	self.last_flushed_draws = resolved_flushed_draws
	self.total_flushed_draws = self.total_flushed_draws + resolved_flushed_draws
	self.total_gpu_rect_draw_calls = self.total_gpu_rect_draw_calls + gpu_rect_draw_calls
	self.current_frame.flush_count = self.current_frame.flush_count + 1
	self.current_frame.flush_reasons[flush_reason] = (self.current_frame.flush_reasons[flush_reason] or 0) + 1
	self.current_frame.flushed_draws = self.current_frame.flushed_draws + resolved_flushed_draws
	self.current_frame.gpu_rect_draw_calls = self.current_frame.gpu_rect_draw_calls + gpu_rect_draw_calls
	self.current_frame.draw_call_savings = self.current_frame.draw_call_savings + draw_call_savings
	self.current_frame.instanced_draws = self.current_frame.instanced_draws + (summary.instanced_draws or 0)
	self.current_frame.instanced_segments = self.current_frame.instanced_segments + (summary.instanced_segments or 0)
	self.current_frame.replay_draws = self.current_frame.replay_draws + (summary.replay_draws or 0)
	self.current_frame.max_segment_size = math.max(self.current_frame.max_segment_size, summary.max_segment_size or 0)
	return true
end

function META:AbortFlush()
	if not self.is_flushing then return false end

	self.is_flushing = false
	self.current_flush_reason = nil
	return true
end

function META:Append(kind, key, payload)
	local segment = self.segments[#self.segments]
	local key_hash = assert(key and key.hash, "rect batch key.hash is required")
	local is_new_segment = not segment or segment.kind ~= kind or segment.key_hash ~= key_hash

	if is_new_segment then
		segment = {
			kind = kind,
			key = key,
			key_hash = key_hash,
			entries = {},
		}
		self.segments[#self.segments + 1] = segment
	end

	segment.entries[#segment.entries + 1] = payload
	self.pending_draws = self.pending_draws + 1
	self.total_queued_draws = self.total_queued_draws + 1
	self.current_frame.queued_draws = self.current_frame.queued_draws + 1

	if is_new_segment then
		self.total_queued_segments = self.total_queued_segments + 1
		self.current_frame.queued_segments = self.current_frame.queued_segments + 1
	end

	self.current_frame.max_segment_size = math.max(self.current_frame.max_segment_size, #segment.entries)
	return segment
end

META:Register()
return META
