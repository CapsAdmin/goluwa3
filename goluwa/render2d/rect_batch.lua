local prototype = import("goluwa/prototype.lua")
local META = prototype.CreateTemplate("render2d_rect_batch")

function META.New()
	local self = META:CreateObject()
	self.pending_draws = 0
	self.flush_count = 0
	self.last_flush = nil
	self.is_flushing = false
	self.current_flush_reason = nil
	self.segments = {}
	return self
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
	local flush_reason = reason or "manual"

	if self.is_flushing then return false end

	if self.pending_draws == 0 then return false end

	self.is_flushing = true
	self.current_flush_reason = flush_reason
	return true
end

function META:FinishFlush(flushed_draws, summary)
	if not self.is_flushing then return false end

	summary = summary or {}
	local flush_reason = self.current_flush_reason or "manual"
	local resolved_flushed_draws = flushed_draws or 0
	self.is_flushing = false
	self.current_flush_reason = nil
	self.flush_count = self.flush_count + 1
	self.pending_draws = 0
	self.segments = {}
	self.last_flush = {
		reason = flush_reason,
		flushed_draws = resolved_flushed_draws,
		gpu_rect_draw_calls = summary.gpu_rect_draw_calls or 0,
		instanced_draws = summary.instanced_draws or 0,
		instanced_segments = summary.instanced_segments or 0,
		replay_draws = summary.replay_draws or 0,
		max_segment_size = summary.max_segment_size or 0,
		queued_draws = summary.queued_draws or resolved_flushed_draws,
		queued_segments = summary.queued_segments or 0,
	}
	return true
end

function META:AbortFlush()
	if not self.is_flushing then return false end

	self.is_flushing = false
	self.current_flush_reason = nil
	return true
end

function META:Append(kind, key_hash, payload)
	local segment = self.segments[#self.segments]
	assert(key_hash ~= nil, "rect batch key hash is required")
	local is_new_segment = not segment or segment.kind ~= kind or segment.key_hash ~= key_hash

	if is_new_segment then
		segment = {
			kind = kind,
			key_hash = key_hash,
			entries = {},
		}
		self.segments[#self.segments + 1] = segment
	end

	segment.entries[#segment.entries + 1] = payload
	self.pending_draws = self.pending_draws + 1
	return segment
end

META:Register()
return META
