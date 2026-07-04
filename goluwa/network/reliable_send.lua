-- Reliable Send + Retransmit Timer — Step 4
-- Implements per-peer unacked reliable packet tracking with exponential backoff

local bit = require("bit")
local reliable_send = {}

-- Reliability levels
reliable_send.RELIABILITY = {
	UNRELIABLE = 0,
	UNRELIABLE_SEQUENCED = 1,
	RELIABLE = 2,
}

-- Default retransmission parameters
reliable_send.DEFAULT_INITIAL_TIMEOUT = 500 -- ms
reliable_send.DEFAULT_MAX_TIMEOUT = 30000   -- ms (30 seconds)
reliable_send.DEFAULT_MULTIPLIER = 2        -- Exponential backoff factor
reliable_send.DEFAULT_JITTER = 0.1          -- 10% random jitter
reliable_send.DEFAULT_MAX_RETRIES = 8       -- Max retransmission attempts before failure

-- Unacked packet tracking
local UnackedPacket = {}
UnackedPacket.__index = UnackedPacket

function UnackedPacket.New(sequence_number, payload, reliability, send_time)
	local self = setmetatable({}, UnackedPacket)
	self.sequence_number = sequence_number
	self.payload = payload
	self.reliability = reliability
	self.send_time = send_time          -- Timestamp of last send (ms)
	self.retry_count = 0
	self.timeout = reliable_send.DEFAULT_INITIAL_TIMEOUT
	self.acked = false
	return self
end

-- Check if this packet needs retransmission
function UnackedPacket:NeedsRetransmission(current_time)
	if self.acked then return false end
	return (current_time - self.send_time) >= self.timeout
end

-- Mark packet as acknowledged
function UnackedPacket:Ack()
	self.acked = true
end

-- Handle retransmission timeout
function UnackedPacket:OnTimeout()
	self.retry_count = self.retry_count + 1

	-- Calculate new timeout with exponential backoff from initial timeout + jitter
	local backoff = math.pow(reliable_send.DEFAULT_MULTIPLIER, self.retry_count)
	local new_timeout = reliable_send.DEFAULT_INITIAL_TIMEOUT * backoff

	-- Cap at maximum timeout
	new_timeout = math.min(new_timeout, reliable_send.DEFAULT_MAX_TIMEOUT)

	-- Add random jitter (±10%)
	local jitter_range = new_timeout * reliable_send.DEFAULT_JITTER
	new_timeout = new_timeout + (math.random() * 2 * jitter_range - jitter_range)

	self.timeout = new_timeout
	self.send_time = os.clock() * 1000 -- Convert to ms

	return self.retry_count < reliable_send.DEFAULT_MAX_RETRIES
end

-- Check if we've exceeded max retries
function UnackedPacket:HasExceededMaxRetries()
	return self.retry_count >= reliable_send.DEFAULT_MAX_RETRIES
end

-- Retransmission tracker per peer
local RetransmissionTracker = {}
RetransmissionTracker.__index = RetransmissionTracker

function RetransmissionTracker.New()
	local self = setmetatable({}, RetransmissionTracker)
	self.unacked = {}       -- sequence_number -> UnackedPacket
	self.total_sent = 0
	self.total_acked = 0
	self.total_retransmitted = 0
	self.total_failed = 0
	return self
end

-- Track a newly sent packet
function RetransmissionTracker:TrackPacket(sequence_number, payload, reliability)
	local send_time = os.clock() * 1000 -- ms
	local packet = UnackedPacket.New(sequence_number, payload, reliability, send_time)
	self.unacked[sequence_number] = packet
	self.total_sent = self.total_sent + 1
	return packet
end

-- Mark a packet as acknowledged
function RetransmissionTracker:AckPacket(sequence_number)
	local packet = self.unacked[sequence_number]

	if packet then
		packet:Ack()
		self.unacked[sequence_number] = nil
		self.total_acked = self.total_acked + 1
		return true
	end

	return false
end

-- Check for packets that need retransmission
function RetransmissionTracker:GetRetransmitQueue(current_time)
	local retransmit = {}

	for seq, packet in pairs(self.unacked) do
		if packet:NeedsRetransmission(current_time) then
			retransmit[#retransmit + 1] = packet
		end
	end

	return retransmit
end

-- Process retransmission timeouts
function RetransmissionTracker:OnTimeout(current_time)
	local retransmit = self:GetRetransmitQueue(current_time)
	local failed = {}

	for _, packet in ipairs(retransmit) do
		self.total_retransmitted = self.total_retransmitted + 1

		local should_continue = packet:OnTimeout()

		if not should_continue then
			failed[#failed + 1] = packet
		end
	end

	-- Remove failed packets
	for _, packet in ipairs(failed) do
		self.unacked[packet.sequence_number] = nil
		self.total_failed = self.total_failed + 1
	end

	return retransmit, failed
end

-- Clean up old acknowledged packets (keep only recent ones for ACK processing)
function RetransmissionTracker:Cleanup(max_age_ms)
	local current_time = os.clock() * 1000
	local cleaned = 0

	for seq, packet in pairs(self.unacked) do
		if packet.acked and (current_time - packet.send_time) > max_age_ms then
			self.unacked[seq] = nil
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

-- Get statistics
function RetransmissionTracker:GetStats()
	return {
		unacked = #self.unacked,
		total_sent = self.total_sent,
		total_acked = self.total_acked,
		total_retransmitted = self.total_retransmitted,
		total_failed = self.total_failed,
	}
end

-- Export classes for testing
reliable_send.UnackedPacket = UnackedPacket
reliable_send.RetransmissionTracker = RetransmissionTracker

-- Create a tracker instance
function reliable_send.CreateTracker()
	return RetransmissionTracker.New()
end

return reliable_send
