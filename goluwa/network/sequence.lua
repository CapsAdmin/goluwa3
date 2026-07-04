-- Sequencing and duplicate detection for reliable UDP transport layer
--
-- Implements per-peer, per-channel sequence tracking with:
-- - 32-bit monotonically increasing sequence numbers (wraparound safe)
-- - Receive window with bitmap for duplicate detection
-- - Out-of-order packet buffering

local bit = require("bit")
local sequence = {}

-- Configuration
sequence.WINDOW_SIZE = 64 -- Number of packets in receive window (must be power of 2)
sequence.MAX_SEQUENCE = 2147483648 -- 2^31, half of uint32 range for wraparound comparison

-- --- Sequence Number Utilities ---

-- Compare two sequence numbers with wraparound handling
-- Returns: -1 if a < b, 0 if a == b, 1 if a > b
function sequence.Compare(a, b)
	if a == b then return 0 end

	-- Calculate signed difference
	local diff = a - b

	-- Handle wraparound: if difference is more than half the range,
	-- the smaller number actually wrapped around
	if diff > sequence.MAX_SEQUENCE then
		return -1 -- a wrapped around, so a < b
	elseif diff < -sequence.MAX_SEQUENCE then
		return 1 -- b wrapped around, so a > b
	end

	-- Normal comparison (no wraparound)
	if diff > 0 then return 1
	else return -1
	end
end

-- Check if sequence a is before b (a < b)
function sequence.Before(a, b)
	return sequence.Compare(a, b) < 0
end

-- Check if sequence a is after b (a > b)
function sequence.After(a, b)
	return sequence.Compare(a, b) > 0
end

-- --- Sender State ---

local Sender = {}
Sender.__index = Sender

function Sender.New()
	local self = setmetatable({}, Sender)
	self.next_sequence = 1 -- Start at 1 (0 reserved)
	return self
end

-- Assign next sequence number to a packet
function Sender:AllocateSequence()
	local seq = self.next_sequence
	self.next_sequence = bit.band(self.next_sequence + 1, 0xFFFFFFFF)
	return seq
end

-- --- Receiver State ---

local Receiver = {}
Receiver.__index = Receiver

function Receiver.New()
	local self = setmetatable({}, Receiver)
	self.expected_next = 1 -- Next expected sequence number
	self.window_size = sequence.WINDOW_SIZE
	self.window_mask = bit.band(self.window_size - 1, 0xFFFFFFFF)
	self.bitmap = {} -- Bitmask array (each entry is a uint32)
	self.window_start = 0 -- Start of current window
	self.received_count = 0 -- Total packets received (for statistics)
	return self
end

-- Initialize the receive window with the first packet
function Receiver:Initialize(sequence_number)
	self.expected_next = sequence_number
	-- Place the first packet at the start of the window
	self.window_start = sequence_number

	-- Set bit for the first packet (it's at index 0)
	self.bitmap[0] = bit.lshift(1, 0)
	self.received_count = 1
end

-- Check if a packet is a duplicate (already received)
function Receiver:IsDuplicate(sequence_number)
	local diff = bit.band(sequence_number - self.window_start, 0xFFFFFFFF)

	-- Outside the window (window covers [window_start, window_start + window_size - 1])
	if diff >= self.window_size then return false end

	local index = bit.band(diff, self.window_mask)
	local word_index = math.floor(index / 32)
	local bit_index = bit.band(index % 32, 0xFFFFFFFF)

	local word = self.bitmap[word_index] or 0
	return bit.band(word, bit.lshift(1, bit_index)) ~= 0
end

-- Mark a packet as received (does not advance window — call AdvanceWindow explicitly)
function Receiver:Receive(sequence_number)
	-- Initialize window on first packet
	if self.received_count == 0 then
		self:Initialize(sequence_number)
		return true
	end

	-- Check if packet is outside the receive window
	local diff = sequence_number - self.window_start

	-- Handle wraparound: convert to unsigned 32-bit
	if diff < 0 then diff = diff + 0x100000000 end

	if diff >= self.window_size then return false end

	-- Check for duplicates
	if self:IsDuplicate(sequence_number) then return false end

	-- Mark as received
	local index = bit.band(diff, self.window_mask)
	local word_index = math.floor(index / 32)
	local bit_index = bit.band(index % 32, 0xFFFFFFFF)

	self.bitmap[word_index] = bit.bor(self.bitmap[word_index] or 0, bit.lshift(1, bit_index))
	self.received_count = self.received_count + 1

	return true
end

-- Advance the receive window past contiguous received packets
function Receiver:AdvanceWindow()
	local current_diff = 0

	while true do
		-- Stop if we've advanced past the window
		if current_diff >= self.window_size then break end

		local index = bit.band(current_diff, self.window_mask)
		local word_index = math.floor(index / 32)
		local bit_index = bit.band(index % 32, 0xFFFFFFFF)

		local word = self.bitmap[word_index] or 0

		-- Stop if this packet hasn't been received yet
		if bit.band(word, bit.lshift(1, bit_index)) == 0 then break end

		-- Clear the bit (packet acknowledged)
		self.bitmap[word_index] = bit.band(word, bit.bnot(bit.lshift(1, bit_index)))
		-- Advance to next sequence
		self.expected_next = bit.band(self.expected_next + 1, 0xFFFFFFFF)
		self.window_start = bit.band(self.window_start + 1, 0xFFFFFFFF)
		current_diff = current_diff + 1
	end
end

-- Get the number of packets received in the current window
function Receiver:GetReceivedCount()
	return self.received_count
end

-- Get the total number of packets received (since connection start)
function Receiver:GetTotalReceived()
	return self.received_count
end

-- --- Per-Channel State ---

-- Channel state tracks sender and receiver for a single channel
local ChannelState = {}
ChannelState.__index = ChannelState

function ChannelState.New()
	local self = setmetatable({}, ChannelState)
	self.sender = Sender.New()
	self.receiver = Receiver.New()
	return self
end

-- --- Peer State ---

-- Peer state tracks all channels for a single peer
local PeerState = {}
PeerState.__index = PeerState

function PeerState.New(max_channels)
	local self = setmetatable({}, PeerState)
	self.max_channels = max_channels or 1
	self.channels = {}

	for i = 0, self.max_channels - 1 do
		self.channels[i + 1] = ChannelState.New()
	end

	return self
end

-- Get channel state (creates if needed)
function PeerState:GetChannel(channel_id)
	if not self.channels[channel_id + 1] then
		self.channels[channel_id + 1] = ChannelState.New()
	end

	return self.channels[channel_id + 1]
end

-- Export constructors for testing and external use
sequence.Sender = Sender
sequence.Receiver = Receiver
sequence.PeerState = PeerState
sequence.ChannelState = ChannelState

return sequence
