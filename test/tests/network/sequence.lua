local T = import("test/environment.lua")
local sequence = import("goluwa/network/sequence.lua")

T.Test("Sequence comparison — equal", function()
	T(sequence.Compare(100, 100))["=="](0)
	T(sequence.Compare(0, 0))["=="](0)
	T(sequence.Compare(0xFFFFFFFF, 0xFFFFFFFF))["=="](0)
end)

T.Test("Sequence comparison — a < b", function()
	T(sequence.Compare(50, 100))["=="](-1)
	T(sequence.Compare(0, 1))["=="](-1)
	T(sequence.Compare(100, 200))["=="](-1)
end)

T.Test("Sequence comparison — a > b", function()
	T(sequence.Compare(100, 50))["=="](1)
	T(sequence.Compare(1, 0))["=="](1)
	T(sequence.Compare(200, 100))["=="](1)
end)

T.Test("Sequence comparison — wraparound a < b", function()
	-- a is just past wrap, b is just before wrap
	T(sequence.Compare(0x7FFFFFFF, 0x80000000))["=="](-1)
end)

T.Test("Sequence comparison — wraparound a > b", function()
	-- a is just before wrap, b is just past wrap
	T(sequence.Compare(0x80000000, 0x7FFFFFFF))["=="](1)
end)

T.Test("Sequence.Before helper", function()
	T(sequence.Before(50, 100))["=="](true)
	T(sequence.Before(100, 50))["=="](false)
	T(sequence.Before(100, 100))["=="](false)
end)

T.Test("Sequence.After helper", function()
	T(sequence.After(100, 50))["=="](true)
	T(sequence.After(50, 100))["=="](false)
	T(sequence.After(100, 100))["=="](false)
end)

T.Test("Sender allocates sequential sequences", function()
	local sender = sequence.Sender.New()
	T(sender:AllocateSequence())["=="](1)
	T(sender:AllocateSequence())["=="](2)
	T(sender:AllocateSequence())["=="](3)
	T(sender:AllocateSequence())["=="](4)
	T(sender:AllocateSequence())["=="](5)
end)

T.Test("Sender wraps around at uint32 boundary", function()
	local sender = sequence.Sender.New()
	-- Set next_sequence near the max
	sender.next_sequence = 0xFFFFFFFF
	T(sender:AllocateSequence())["=="](0xFFFFFFFF)
	T(sender:AllocateSequence())["=="](0)
	T(sender:AllocateSequence())["=="](1)
end)

T.Test("Receiver accepts first packet", function()
	local receiver = sequence.Receiver.New()
	T(receiver:Receive(100))["=="](true)
	T(receiver:GetReceivedCount())["=="](1)
end)

T.Test("Receiver detects duplicate", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	T(receiver:Receive(100))["=="](false) -- Duplicate
	T(receiver:GetReceivedCount())["=="](1)
end)

T.Test("Receiver accepts in-order packets", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(101)
	receiver:Receive(102)
	T(receiver:GetReceivedCount())["=="](3)
end)

T.Test("Receiver accepts out-of-order packets within window", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(102) -- Out of order
	receiver:Receive(101) -- Now in order
	T(receiver:GetReceivedCount())["=="](3)
end)

T.Test("Receiver rejects packets outside window", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	-- Send a packet far ahead (outside window)
	T(receiver:Receive(100 + sequence.WINDOW_SIZE + 10))["=="](false)
	T(receiver:GetReceivedCount())["=="](1)
end)

T.Test("Receiver advances window on contiguous packets", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(101)
	receiver:Receive(102)
	-- Manually advance window (in real usage, this happens when ACKs are sent)
	receiver:AdvanceWindow()
	T(receiver.expected_next)["=="](103)
end)

T.Test("Receiver handles window wraparound", function()
	local receiver = sequence.Receiver.New()
	-- Start near uint32 boundary
	receiver:Receive(0xFFFFFFFE)
	receiver:Receive(0xFFFFFFFF)
	receiver:Receive(0) -- Wrapped around
	receiver:Receive(1)
	T(receiver:GetReceivedCount())["=="](4)
end)

T.Test("Receiver bitmap tracks received packets correctly", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(102)
	receiver:Receive(105)

	-- All should be marked as received
	T(receiver:IsDuplicate(100))["=="](true)
	T(receiver:IsDuplicate(102))["=="](true)
	T(receiver:IsDuplicate(105))["=="](true)

	-- Others should not be duplicates
	T(receiver:IsDuplicate(101))["=="](false)
	T(receiver:IsDuplicate(103))["=="](false)
	T(receiver:IsDuplicate(104))["=="](false)
end)

T.Test("Per-channel state isolation", function()
	local peer = sequence.PeerState.New(3)
	local chan0 = peer:GetChannel(0)
	local chan1 = peer:GetChannel(1)

	-- Receive on channel 0
	chan0.receiver:Receive(100)
	chan0.receiver:Receive(101)

	-- Receive on channel 1 (independent)
	chan1.receiver:Receive(200)
	chan1.receiver:Receive(201)

	-- Channel 0 should have 2 received
	T(chan0.receiver:GetReceivedCount())["=="](2)

	-- Channel 1 should have 2 received
	T(chan1.receiver:GetReceivedCount())["=="](2)

	-- Duplicate on channel 0 doesn't affect channel 1
	T(chan0.receiver:Receive(100))["=="](false)
	T(chan1.receiver:GetReceivedCount())["=="](2)
end)

T.Test("PeerState creates channels on demand", function()
	local peer = sequence.PeerState.New(2) -- Max 2 channels

	-- Access channel 5 (beyond initial allocation)
	local chan5 = peer:GetChannel(5)
	T(chan5)["~="](nil)
	T(peer.channels[6])["~="](nil) -- 0-indexed, so channel 5 is at index 6
end)

T.Test("Sender and receiver work together", function()
	local sender = sequence.Sender.New()
	local receiver = sequence.Receiver.New()

	-- Sender allocates sequences
	local seq1 = sender:AllocateSequence()
	local seq2 = sender:AllocateSequence()
	local seq3 = sender:AllocateSequence()

	T(seq1)["=="](1)
	T(seq2)["=="](2)
	T(seq3)["=="](3)

	-- Receiver processes them
	T(receiver:Receive(seq1))["=="](true)
	T(receiver:Receive(seq2))["=="](true)
	T(receiver:Receive(seq3))["=="](true)

	T(receiver:GetReceivedCount())["=="](3)

	-- Duplicate should be rejected
	T(receiver:Receive(seq2))["=="](false)
end)

T.Test("Large sequence numbers work correctly", function()
	local sender = sequence.Sender.New()
	sender.next_sequence = 0x7FFFFFFF

	local seq1 = sender:AllocateSequence()
	local seq2 = sender:AllocateSequence()

	T(seq1)["=="](0x7FFFFFFF)

	-- Compare should still work across the boundary
	T(sequence.Compare(seq1, seq2))["=="](-1)
	T(sequence.Compare(seq2, seq1))["=="](1)
end)

T.Test("Window size configuration", function()
	T(sequence.WINDOW_SIZE)["=="](64)
	T(bit.band(sequence.WINDOW_SIZE - 1, 0xFFFFFFFF))["=="](63) -- Power of 2 check
end)
