-- Tests for reliable send + retransmit timer (Step 4)

local T = import("test/environment.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")

-- Count entries in a hash table
local function count_hash(t)
	local count = 0

	for _ in pairs(t) do count = count + 1 end

	return count
end


T.Test("Reliability levels are defined", function()
	T(reliable_send.RELIABILITY.UNRELIABLE)["=="](0)
	T(reliable_send.RELIABILITY.UNRELIABLE_SEQUENCED)["=="](1)
	T(reliable_send.RELIABILITY.RELIABLE)["=="](2)
end)

T.Test("UnackedPacket tracks send time and retry count", function()
	local packet = reliable_send.UnackedPacket.New(100, "data", reliable_send.RELIABILITY.RELIABLE)
	T(packet.sequence_number)["=="](100)
	T(packet.payload)["=="]("data")
	T(packet.reliability)["=="](2)
	T(packet.retry_count)["=="](0)
	T(packet.acked)["=="](false)
end)

T.Test("UnackedPacket:NeedsRetransmission returns false before timeout", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	packet.send_time = os.clock() * 1000 - 100 -- 100ms ago
	T(packet:NeedsRetransmission(os.clock() * 1000))["=="](false)
end)

T.Test("UnackedPacket:NeedsRetransmission returns true after timeout", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	packet.send_time = os.clock() * 1000 - 1000 -- 1 second ago
	T(packet:NeedsRetransmission(os.clock() * 1000))["=="](true)
end)

T.Test("UnackedPacket:Ack marks packet as acknowledged", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	packet:Ack()
	T(packet.acked)["=="](true)
	T(packet:NeedsRetransmission(os.clock() * 1000))["=="](false)
end)

T.Test("UnackedPacket:OnTimeout increases retry count and backoff", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	local initial_timeout = packet.timeout

	packet:OnTimeout()
	T(packet.retry_count)["=="](1)
	-- Timeout should be approximately 2x initial (with ±10% jitter)
	local expected = initial_timeout * reliable_send.DEFAULT_MULTIPLIER
	T(packet.timeout)[">="](expected * 0.9)
	T(packet.timeout)["<="](expected * 1.1)
end)

T.Test("UnackedPacket:OnTimeout applies exponential backoff", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	packet:OnTimeout() -- retry 1: 2x
	packet:OnTimeout() -- retry 2: 4x
	packet:OnTimeout() -- retry 3: 8x

	T(packet.retry_count)["=="](3)
	-- Timeout should be approximately 8x initial (with ±10% jitter per step)
	local expected = reliable_send.DEFAULT_INITIAL_TIMEOUT * 8
	T(packet.timeout)[">="](expected * 0.7)
	T(packet.timeout)["<="](expected * 1.3)
end)

T.Test("UnackedPacket:OnTimeout caps at maximum timeout", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)

	-- Force many retries to exceed max timeout
	for i = 1, 20 do
		packet:OnTimeout()
	end

	T(packet.timeout)["<="](reliable_send.DEFAULT_MAX_TIMEOUT * 1.1) -- Allow 10% jitter
end)

T.Test("UnackedPacket:HasExceededMaxRetries returns false initially", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	T(packet:HasExceededMaxRetries())["=="](false)
end)

T.Test("UnackedPacket:HasExceededMaxRetries returns true after max retries", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)

	for i = 1, reliable_send.DEFAULT_MAX_RETRIES do
		packet:OnTimeout()
	end

	T(packet:HasExceededMaxRetries())["=="](true)
end)

T.Test("RetransmissionTracker tracks sent packets", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data1", 2)
	tracker:TrackPacket(101, "data2", 2)

	T(tracker.total_sent)["=="](2)
	T(tracker.unacked[100])["~="](nil)
	T(tracker.unacked[101])["~="](nil)
end)

T.Test("RetransmissionTracker:AckPacket removes acknowledged packet", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)

	local result = tracker:AckPacket(100)
	T(result)["=="](true)
	T(tracker.total_acked)["=="](1)
	T(count_hash(tracker.unacked))["=="](0)
end)

T.Test("RetransmissionTracker:AckPacket returns false for unknown sequence", function()
	local tracker = reliable_send.CreateTracker()
	local result = tracker:AckPacket(999)
	T(result)["=="](false)
end)

T.Test("RetransmissionTracker:GetRetransmitQueue returns timed-out packets", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)
	tracker:TrackPacket(101, "data", 2)

	-- Advance time past timeout for first packet only
	for _, packet in pairs(tracker.unacked) do
		if packet.sequence_number == 100 then
			packet.send_time = os.clock() * 1000 - 1000 -- 1 second ago
		else
			packet.send_time = os.clock() * 1000 - 10   -- 10ms ago
		end
	end

	local retransmit = tracker:GetRetransmitQueue(os.clock() * 1000)
	T(#retransmit)["=="](1)
	T(retransmit[1].sequence_number)["=="](100)
end)

T.Test("RetransmissionTracker:OnTimeout processes retransmissions", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)

	-- Set packet to need retransmission
	for _, packet in pairs(tracker.unacked) do
		packet.send_time = os.clock() * 1000 - 1000
	end

	local retransmit, failed = tracker:OnTimeout(os.clock() * 1000)
	T(#retransmit)["=="](1)
	T(#failed)["=="](0)
	T(tracker.total_retransmitted)["=="](1)
end)

T.Test("RetransmissionTracker:OnTimeout removes failed packets", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)

	-- Force max retries to fail
	local packet = tracker.unacked[100]

	for i = 1, reliable_send.DEFAULT_MAX_RETRIES do
		packet:OnTimeout()
	end

	-- Set send_time far enough in the past to exceed the (capped) timeout
	packet.send_time = os.clock() * 1000 - 31000

	local retransmit, failed = tracker:OnTimeout(os.clock() * 1000)
	T(#failed)["=="](1)
	T(tracker.total_failed)["=="](1)
	T(count_hash(tracker.unacked))["=="](0)
end)

T.Test("RetransmissionTracker:Cleanup removes old acknowledged packets", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)

	-- Manually ack without removing from unacked (simulates pending ack)
	local packet = tracker.unacked[100]
	packet:Ack()

	-- Packet is still in unacked but marked as acked
	T(count_hash(tracker.unacked))["=="](1)

	-- Cleanup with short max_age
	local cleaned = tracker:Cleanup(0) -- 0ms = remove immediately
	T(cleaned)["=="](1)
	T(count_hash(tracker.unacked))["=="](0)
end)

T.Test("RetransmissionTracker:GetStats returns correct counts", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)
	tracker:TrackPacket(101, "data", 2)

	-- Manually ack one packet (don't use AckPacket which removes from unacked)
	local packet100 = tracker.unacked[100]
	packet100:Ack()
	tracker.total_acked = tracker.total_acked + 1

	local stats = tracker:GetStats()
	-- Both packets still in unacked (100 is acked but not removed, 101 is unacked)
	T(count_hash(tracker.unacked))["=="](2)
	T(stats.total_sent)["=="](2)
	T(stats.total_acked)["=="](1)
	T(stats.total_retransmitted)["=="](0)
	T(stats.total_failed)["=="](0)
end)

T.Test("End-to-end: send, ack, and retransmit flow", function()
	local tracker = reliable_send.CreateTracker()

	-- Send 3 packets
	tracker:TrackPacket(1, "payload1", 2)
	tracker:TrackPacket(2, "payload2", 2)
	tracker:TrackPacket(3, "payload3", 2)

	T(tracker.total_sent)["=="](3)

	-- Ack packet 1 and 2
	tracker:AckPacket(1)
	tracker:AckPacket(2)

	T(tracker.total_acked)["=="](2)
	T(tracker.unacked[3])["~="](nil)

	-- Force packet 3 to timeout and retransmit
	for _, packet in pairs(tracker.unacked) do
		packet.send_time = os.clock() * 1000 - 1000
	end

	local retransmit, _ = tracker:OnTimeout(os.clock() * 1000)
	T(#retransmit)["=="](1)
	T(retransmit[1].sequence_number)["=="](3)
	T(tracker.total_retransmitted)["=="](1)

	-- Finally ack packet 3
	tracker:AckPacket(3)
	T(tracker.total_acked)["=="](3)
	T(count_hash(tracker.unacked))["=="](0)
end)

return {}
