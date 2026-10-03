local T = import("test/environment.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")

local function count_hash(t)
	local count = 0

	for _ in pairs(t) do
		count = count + 1
	end

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
	packet.send_time = os.clock() * 1000 - 100
	T(packet:NeedsRetransmission(os.clock() * 1000))["=="](false)
end)

T.Test("UnackedPacket:NeedsRetransmission returns true after timeout", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	packet.send_time = os.clock() * 1000 - 1000
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
	local expected = initial_timeout * reliable_send.DEFAULT_MULTIPLIER
	T(packet.timeout)[">="](expected * 0.9)
	T(packet.timeout)["<="](expected * 1.1)
end)

T.Test("UnackedPacket:OnTimeout applies exponential backoff", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)
	packet:OnTimeout()
	packet:OnTimeout()
	packet:OnTimeout()
	T(packet.retry_count)["=="](3)
	local expected = reliable_send.DEFAULT_INITIAL_TIMEOUT * 8
	T(packet.timeout)[">="](expected * 0.7)
	T(packet.timeout)["<="](expected * 1.3)
end)

T.Test("UnackedPacket:OnTimeout caps at maximum timeout", function()
	local packet = reliable_send.UnackedPacket.New(1, "data", 2)

	for i = 1, 20 do
		packet:OnTimeout()
	end

	T(packet.timeout)["<="](reliable_send.DEFAULT_MAX_TIMEOUT * 1.1)
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

	for _, packet in pairs(tracker.unacked) do
		if packet.sequence_number == 100 then
			packet.send_time = os.clock() * 1000 - 1000
		else
			packet.send_time = os.clock() * 1000 - 10
		end
	end

	local retransmit = tracker:GetRetransmitQueue(os.clock() * 1000)
	T(#retransmit)["=="](1)
	T(retransmit[1].sequence_number)["=="](100)
end)

T.Test("RetransmissionTracker:OnTimeout processes retransmissions", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)

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
	local packet = tracker.unacked[100]

	for i = 1, reliable_send.DEFAULT_MAX_RETRIES do
		packet:OnTimeout()
	end

	packet.send_time = os.clock() * 1000 - 31000
	local retransmit, failed = tracker:OnTimeout(os.clock() * 1000)
	T(#failed)["=="](1)
	T(tracker.total_failed)["=="](1)
	T(count_hash(tracker.unacked))["=="](0)
end)

T.Test("RetransmissionTracker:Cleanup removes old acknowledged packets", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)
	local packet = tracker.unacked[100]
	packet:Ack()
	T(count_hash(tracker.unacked))["=="](1)
	local cleaned = tracker:Cleanup(0)
	T(cleaned)["=="](1)
	T(count_hash(tracker.unacked))["=="](0)
end)

T.Test("RetransmissionTracker:GetStats returns correct counts", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(100, "data", 2)
	tracker:TrackPacket(101, "data", 2)
	local packet100 = tracker.unacked[100]
	packet100:Ack()
	tracker.total_acked = tracker.total_acked + 1
	local stats = tracker:GetStats()
	T(count_hash(tracker.unacked))["=="](2)
	T(stats.total_sent)["=="](2)
	T(stats.total_acked)["=="](1)
	T(stats.total_retransmitted)["=="](0)
	T(stats.total_failed)["=="](0)
end)

T.Test("End-to-end: send, ack, and retransmit flow", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(1, "payload1", 2)
	tracker:TrackPacket(2, "payload2", 2)
	tracker:TrackPacket(3, "payload3", 2)
	T(tracker.total_sent)["=="](3)
	tracker:AckPacket(1)
	tracker:AckPacket(2)
	T(tracker.total_acked)["=="](2)
	T(tracker.unacked[3])["~="](nil)

	for _, packet in pairs(tracker.unacked) do
		packet.send_time = os.clock() * 1000 - 1000
	end

	local retransmit, _ = tracker:OnTimeout(os.clock() * 1000)
	T(#retransmit)["=="](1)
	T(retransmit[1].sequence_number)["=="](3)
	T(tracker.total_retransmitted)["=="](1)
	tracker:AckPacket(3)
	T(tracker.total_acked)["=="](3)
	T(count_hash(tracker.unacked))["=="](0)
end)

return {}
