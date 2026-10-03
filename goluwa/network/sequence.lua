local bit = require("bit")
local sequence = {}
sequence.WINDOW_SIZE = 64
sequence.MAX_SEQUENCE = 2147483648

function sequence.Compare(a, b)
	if a == b then return 0 end

	local diff = a - b

	if diff > sequence.MAX_SEQUENCE then
		return -1
	elseif diff < -sequence.MAX_SEQUENCE then
		return 1
	end

	if diff > 0 then return 1 else return -1 end
end

function sequence.Before(a, b)
	return sequence.Compare(a, b) < 0
end

function sequence.After(a, b)
	return sequence.Compare(a, b) > 0
end

local Sender = {}
Sender.__index = Sender

function Sender.New()
	local self = setmetatable({}, Sender)
	self.next_sequence = 1
	return self
end

function Sender:AllocateSequence()
	local seq = self.next_sequence
	self.next_sequence = bit.band(self.next_sequence + 1, 0xFFFFFFFF)
	return seq
end

local Receiver = {}
Receiver.__index = Receiver

function Receiver.New()
	local self = setmetatable({}, Receiver)
	self.expected_next = 1
	self.window_size = sequence.WINDOW_SIZE
	self.window_mask = bit.band(self.window_size - 1, 0xFFFFFFFF)
	self.bitmap = {}
	self.window_start = 0
	self.received_count = 0
	return self
end

function Receiver:Initialize(sequence_number)
	self.expected_next = sequence_number
	self.window_start = sequence_number
	self.bitmap[0] = bit.lshift(1, 0)
	self.received_count = 1
end

function Receiver:IsDuplicate(sequence_number)
	local diff = bit.band(sequence_number - self.window_start, 0xFFFFFFFF)

	if diff >= self.window_size then return false end

	local index = bit.band(diff, self.window_mask)
	local word_index = math.floor(index / 32)
	local bit_index = bit.band(index % 32, 0xFFFFFFFF)
	local word = self.bitmap[word_index] or 0
	return bit.band(word, bit.lshift(1, bit_index)) ~= 0
end

function Receiver:Receive(sequence_number)
	if self.received_count == 0 then
		self:Initialize(sequence_number)
		return true
	end

	local diff = sequence_number - self.window_start

	if diff < 0 then diff = diff + 0x100000000 end

	if diff >= self.window_size then return false end

	if self:IsDuplicate(sequence_number) then return false end

	local index = bit.band(diff, self.window_mask)
	local word_index = math.floor(index / 32)
	local bit_index = bit.band(index % 32, 0xFFFFFFFF)
	self.bitmap[word_index] = bit.bor(self.bitmap[word_index] or 0, bit.lshift(1, bit_index))
	self.received_count = self.received_count + 1
	return true
end

function Receiver:AdvanceWindow()
	local current_diff = 0

	while true do
		if current_diff >= self.window_size then break end

		local index = bit.band(current_diff, self.window_mask)
		local word_index = math.floor(index / 32)
		local bit_index = bit.band(index % 32, 0xFFFFFFFF)
		local word = self.bitmap[word_index] or 0

		if bit.band(word, bit.lshift(1, bit_index)) == 0 then break end

		self.bitmap[word_index] = bit.band(word, bit.bnot(bit.lshift(1, bit_index)))
		self.expected_next = bit.band(self.expected_next + 1, 0xFFFFFFFF)
		self.window_start = bit.band(self.window_start + 1, 0xFFFFFFFF)
		current_diff = current_diff + 1
	end
end

function Receiver:GetReceivedCount()
	return self.received_count
end

function Receiver:GetTotalReceived()
	return self.received_count
end

local ChannelState = {}
ChannelState.__index = ChannelState

function ChannelState.New()
	local self = setmetatable({}, ChannelState)
	self.sender = Sender.New()
	self.receiver = Receiver.New()
	return self
end

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

function PeerState:GetChannel(channel_id)
	if not self.channels[channel_id + 1] then
		self.channels[channel_id + 1] = ChannelState.New()
	end

	return self.channels[channel_id + 1]
end

sequence.Sender = Sender
sequence.Receiver = Receiver
sequence.PeerState = PeerState
sequence.ChannelState = ChannelState
return sequence
