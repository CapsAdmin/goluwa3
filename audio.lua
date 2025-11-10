local ffi = require("ffi")
local AudioToolbox = ffi.load("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
ffi.cdef[[
    typedef struct OpaqueAudioQueue* AudioQueueRef;
    typedef struct AudioQueueBuffer {
        const uint32_t mAudioDataBytesCapacity;
        void* const mAudioData;
        uint32_t mAudioDataByteSize;
        void* mUserData;
        uint32_t mPacketDescriptionCapacity;
        void* mPacketDescriptions;
        uint32_t mPacketDescriptionCount;
    } AudioQueueBuffer;
    
    typedef struct AudioStreamBasicDescription {
        double mSampleRate;
        uint32_t mFormatID;
        uint32_t mFormatFlags;
        uint32_t mBytesPerPacket;
        uint32_t mFramesPerPacket;
        uint32_t mBytesPerFrame;
        uint32_t mChannelsPerFrame;
        uint32_t mBitsPerChannel;
        uint32_t mReserved;
    } AudioStreamBasicDescription;
    
    typedef void (*AudioQueueOutputCallback)(
        void* inUserData,
        AudioQueueRef inAQ,
        AudioQueueBuffer* inBuffer
    );
    
    // Audio Queue functions
    int32_t AudioQueueNewOutput(
        const AudioStreamBasicDescription* inFormat,
        AudioQueueOutputCallback inCallbackProc,
        void* inUserData,
        void* inCallbackRunLoop,
        void* inCallbackRunLoopMode,
        uint32_t inFlags,
        AudioQueueRef* outAQ
    );
    
    int32_t AudioQueueAllocateBuffer(
        AudioQueueRef inAQ,
        uint32_t inBufferByteSize,
        AudioQueueBuffer** outBuffer
    );
    
    int32_t AudioQueueEnqueueBuffer(
        AudioQueueRef inAQ,
        AudioQueueBuffer* inBuffer,
        uint32_t inNumPacketDescs,
        const void* inPacketDescs
    );
    
    int32_t AudioQueueStart(
        AudioQueueRef inAQ,
        const void* inStartTime
    );
    
    int32_t AudioQueueStop(
        AudioQueueRef inAQ,
        bool inImmediate
    );
    
    int32_t AudioQueueDispose(
        AudioQueueRef inAQ,
        bool inImmediate
    );
]]
local audio = {}
local kAudioFormatLinearPCM = 0x6C70636D -- 'lpcm'
local kAudioFormatFlagIsFloat = 1
local kAudioFormatFlagIsPacked = 8

function audio.start(config)
	config = config or {}
	config.sample_rate = config.sample_rate or 44100
	config.buffer_size = config.buffer_size or 512
	config.channels = config.channels or 2
	local BITS_PER_CHANNEL = 32
	local BYTES_PER_FRAME = (BITS_PER_CHANNEL / 8) * config.channels
	local NUM_BUFFERS = 3
	local BUFFER_BYTE_SIZE = config.buffer_size * BYTES_PER_FRAME
	local format = ffi.new(
		"AudioStreamBasicDescription",
		{
			mSampleRate = config.sample_rate,
			mFormatID = kAudioFormatLinearPCM,
			mFormatFlags = kAudioFormatFlagIsFloat + kAudioFormatFlagIsPacked,
			mBytesPerPacket = BYTES_PER_FRAME,
			mFramesPerPacket = 1,
			mBytesPerFrame = BYTES_PER_FRAME,
			mChannelsPerFrame = config.channels,
			mBitsPerChannel = BITS_PER_CHANNEL,
			mReserved = 0,
		}
	)

	local function buffer_callback(user_data, queue, buffer)
		local buffer_data = ffi.cast("float*", buffer.mAudioData)
		local num_samples = buffer.mAudioDataBytesCapacity / 4
		audio.callback(buffer_data, num_samples, config)
		buffer.mAudioDataByteSize = buffer.mAudioDataBytesCapacity
		AudioToolbox.AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
	end

	audio.callback_ref = ffi.cast("AudioQueueOutputCallback", buffer_callback)
	local queue = ffi.new("AudioQueueRef[1]")
	audio.queue = queue
	local status = AudioToolbox.AudioQueueNewOutput(format, audio.callback_ref, nil, nil, nil, 0, queue)

	if status ~= 0 then error("Failed to create audio queue: " .. status) end

	audio.buffers = {}

	for i = 1, NUM_BUFFERS do
		local buffer = ffi.new("AudioQueueBuffer*[1]")
		status = AudioToolbox.AudioQueueAllocateBuffer(queue[0], BUFFER_BYTE_SIZE, buffer)

		if status ~= 0 then error("Failed to allocate buffer: " .. status) end

		audio.buffers[i] = buffer[0]
		local buffer_data = ffi.cast("float*", buffer[0].mAudioData)
		local num_samples = buffer[0].mAudioDataBytesCapacity / 4
		audio.callback(buffer_data, num_samples, config)
		buffer[0].mAudioDataByteSize = buffer[0].mAudioDataBytesCapacity
		AudioToolbox.AudioQueueEnqueueBuffer(queue[0], buffer[0], 0, nil)
	end

	status = AudioToolbox.AudioQueueStart(queue[0], nil)

	if status ~= 0 then error("Failed to start audio queue: " .. status) end

	return config
end

function audio.callback(buffer, num_samples, config)
	for i = 0, num_samples - 1, 2 do
		for j = 0, config.channels - 1 do
			buffer[i + j] = 0
			buffer[i + j] = 0
		end
	end
end

function audio.stop()
	AudioToolbox.AudioQueueStop(audio.queue[0], true)
	AudioToolbox.AudioQueueDispose(audio.queue[0], true)
	audio.callback_ref:free()
	audio.queue = nil
	audio.callback_ref = nil
	audio.buffers = nil
end

return audio
