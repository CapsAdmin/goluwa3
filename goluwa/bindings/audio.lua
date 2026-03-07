local ffi = require("ffi")

local function try_load(paths)
	local errors = {}

	for _, p in ipairs(paths) do
		local ok, lib = pcall(ffi.load, p)

		if ok then return lib end

		table.insert(errors, lib)
	end

	return nil, table.concat(errors, "\n")
end

local function find_library_linux(name)
	local lib = try_load({name .. ".so", name .. ".so.2", name .. ".so.1"})

	if lib then return lib end

	-- On NixOS, libasound's internal dlopen of the PipeWire plugin needs
	-- libpipewire-0.3.so.0 to already be in the global symbol table.
	-- Strategy:
	--   1. Parse /etc/alsa/conf.d to find the native PipeWire plugin path.
	--   2. Use ldd to find libpipewire and the exact libasound it was built against.
	--   3. Preload libpipewire with RTLD_GLOBAL so ALSA can dlopen the plugin.
	--   4. Load the matching libasound.
	if name == "libasound" then
		-- On NixOS, /etc/alsa/conf.d/ files are symlinks; grep -r won't traverse them,
		-- so use cat with glob expansion via shell.
		local conf_handle = io.popen("cat /etc/alsa/conf.d/*.conf 2>/dev/null")
		local plugin_path

		if conf_handle then
			for line in conf_handle:lines() do
				local p = line:match("libs%.native%s*=%s*(/nix/store/%S+%.so)")

				if p and p:find("pcm_pipewire") then
					plugin_path = p

					break
				end
			end

			conf_handle:close()
		end

		if plugin_path then
			-- find libpipewire and libasound paths from the plugin's ldd output
			local ldd_handle = io.popen("ldd " .. plugin_path .. " 2>/dev/null")
			local pipewire_path, asound_path

			if ldd_handle then
				for line in ldd_handle:lines() do
					if line:find("libpipewire") and not pipewire_path then
						pipewire_path = line:match("=> (/nix/store/%S+)")
					end

					if line:find("libasound") and not asound_path then
						asound_path = line:match("=> (/nix/store/%S+)")
					end
				end

				ldd_handle:close()
			end

			-- preload libpipewire with RTLD_GLOBAL so that when libasound
			-- internally dlopens the PipeWire plugin, it can find libpipewire-0.3.so.0
			if pipewire_path then
				local ok_xffi, xffi = pcall(require, "nattlua.other.xffi")

				if ok_xffi then xffi.dl.load(pipewire_path, true) end
			end

			if asound_path then
				local ok, lib2 = pcall(ffi.load, asound_path)

				if ok then return lib2 end
			end
		end
	end

	-- generic /nix/store fallback
	local handle = io.popen("find /nix/store -maxdepth 4 -name '" .. name .. ".so*' 2>/dev/null | head -1")

	if handle then
		local path = handle:read("*l")
		handle:close()

		if path and path ~= "" then
			local ok, lib2 = pcall(ffi.load, path)

			if ok then return lib2 end
		end
	end

	error("Could not load " .. name)
end

local audio = {}

if ffi.os == "OSX" then
	local AudioToolbox = ffi.load("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
	ffi.cdef[[
		typedef struct OpaqueAudioQueue *AudioQueueRef;
		typedef struct AudioQueueBuffer {
			const uint32_t  mAudioDataBytesCapacity;
			void * const    mAudioData;
			uint32_t        mAudioDataByteSize;
			void *          mUserData;
			uint32_t        mPacketDescriptionCapacity;
			void *          mPacketDescriptions;
			uint32_t        mPacketDescriptionCount;
		} AudioQueueBuffer;
		typedef struct {
			double   mSampleRate;
			uint32_t mFormatID;
			uint32_t mFormatFlags;
			uint32_t mBytesPerPacket;
			uint32_t mFramesPerPacket;
			uint32_t mBytesPerFrame;
			uint32_t mChannelsPerFrame;
			uint32_t mBitsPerChannel;
			uint32_t mReserved;
		} AudioStreamBasicDescription;
		typedef void (*AudioQueueOutputCallback)(void *inUserData, AudioQueueRef inAQ, AudioQueueBuffer *inBuffer);
		int32_t AudioQueueNewOutput(const AudioStreamBasicDescription *inFormat, AudioQueueOutputCallback inCallbackProc, void *inUserData, void *inCallbackRunLoop, void *inCallbackRunLoopMode, uint32_t inFlags, AudioQueueRef *outAQ);
		int32_t AudioQueueAllocateBuffer(AudioQueueRef inAQ, uint32_t inBufferByteSize, AudioQueueBuffer **outBuffer);
		int32_t AudioQueueEnqueueBuffer(AudioQueueRef inAQ, AudioQueueBuffer *inBuffer, uint32_t inNumPacketDescs, const void *inPacketDescs);
		int32_t AudioQueueStart(AudioQueueRef inAQ, const void *inStartTime);
		int32_t AudioQueueStop(AudioQueueRef inAQ, bool inImmediate);
		int32_t AudioQueueDispose(AudioQueueRef inAQ, bool inImmediate);

		// GCD semaphore -- available in libSystem (always loaded)
		typedef void *dispatch_semaphore_t;
		dispatch_semaphore_t dispatch_semaphore_create(long value);
		long                 dispatch_semaphore_wait(dispatch_semaphore_t dsema, uint64_t timeout);
		long                 dispatch_semaphore_signal(dispatch_semaphore_t dsema);
		void                 dispatch_release(void *object);
	]]
	local kAudioFormatLinearPCM = 0x6C70636D
	local kAudioFormatFlagIsFloat = 1
	local kAudioFormatFlagIsPacked = 8
	local DISPATCH_TIME_FOREVER = ffi.cast("uint64_t", 0xFFFFFFFFFFFFFFFFULL)

	function audio.start(config)
		config = config or {}
		config.sample_rate = config.sample_rate or 44100
		config.buffer_size = config.buffer_size or 512
		config.channels = config.channels or 2
		local BPF = 4 * config.channels -- 32-bit float * channels
		local format = ffi.new(
			"AudioStreamBasicDescription",
			{
				mSampleRate = config.sample_rate,
				mFormatID = kAudioFormatLinearPCM,
				mFormatFlags = kAudioFormatFlagIsFloat + kAudioFormatFlagIsPacked,
				mBytesPerPacket = BPF,
				mFramesPerPacket = 1,
				mBytesPerFrame = BPF,
				mChannelsPerFrame = config.channels,
				mBitsPerChannel = 32,
			}
		)
		-- Semaphore starts at 0; callback posts when it returns a buffer
		local sem = ffi.C.dispatch_semaphore_create(0)
		audio._sem = sem
		audio._ready_buf = ffi.new("AudioQueueBuffer*[1]")

		local function buffer_callback(user_data, queue, buffer)
			-- store the returned buffer and wake update()
			audio._ready_buf[0] = buffer
			ffi.C.dispatch_semaphore_signal(sem)
		end

		audio._callback_ref = ffi.cast("AudioQueueOutputCallback", buffer_callback)
		local queue = ffi.new("AudioQueueRef[1]")
		local st = AudioToolbox.AudioQueueNewOutput(format, audio._callback_ref, nil, nil, nil, 0, queue)

		if st ~= 0 then error("AudioQueueNewOutput: " .. st) end

		audio._queue = queue
		audio._config = config
		-- Allocate one buffer, pre-fill it, and enqueue it to prime the queue
		local buf = ffi.new("AudioQueueBuffer*[1]")
		st = AudioToolbox.AudioQueueAllocateBuffer(queue[0], config.buffer_size * BPF, buf)

		if st ~= 0 then error("AudioQueueAllocateBuffer: " .. st) end

		local nsamples = config.buffer_size * config.channels
		audio.callback(ffi.cast("float*", buf[0].mAudioData), nsamples, config)
		buf[0].mAudioDataByteSize = buf[0].mAudioDataBytesCapacity
		AudioToolbox.AudioQueueEnqueueBuffer(queue[0], buf[0], 0, nil)
		st = AudioToolbox.AudioQueueStart(queue[0], nil)

		if st ~= 0 then error("AudioQueueStart: " .. st) end

		return config
	end

	-- Blocks until AudioQueue returns a buffer (i.e. the hardware consumed the last one),
	-- fills it, and re-enqueues it.  Self-pacing, just like snd_pcm_writei on Linux.
	function audio.update()
		local config = audio._config
		local nsamples = config.buffer_size * config.channels
		-- wait for the callback to signal that a buffer is available
		ffi.C.dispatch_semaphore_wait(audio._sem, DISPATCH_TIME_FOREVER)
		local buf = audio._ready_buf[0]
		audio.callback(ffi.cast("float*", buf.mAudioData), nsamples, config)
		buf.mAudioDataByteSize = buf.mAudioDataBytesCapacity
		AudioToolbox.AudioQueueEnqueueBuffer(audio._queue[0], buf, 0, nil)
	end

	function audio.stop()
		AudioToolbox.AudioQueueStop(audio._queue[0], true)
		AudioToolbox.AudioQueueDispose(audio._queue[0], true)
		ffi.C.dispatch_release(audio._sem)
		audio._callback_ref:free()
		audio._queue = nil
		audio._callback_ref = nil
		audio._sem = nil
		audio._ready_buf = nil
		audio._config = nil
	end
elseif ffi.os == "Windows" then
	pcall(
		ffi.cdef,
		[[
		typedef struct {
			uint16_t wFormatTag;
			uint16_t nChannels;
			uint32_t nSamplesPerSec;
			uint32_t nAvgBytesPerSec;
			uint16_t nBlockAlign;
			uint16_t wBitsPerSample;
			uint16_t cbSize;
		} WAVEFORMATEX;
		typedef struct {
			char     *lpData;
			uint32_t  dwBufferLength;
			uint32_t  dwBytesRecorded;
			uintptr_t dwUser;
			uint32_t  dwFlags;
			uint32_t  dwLoops;
			void     *lpNext;
			uintptr_t reserved;
		} WAVEHDR;
		typedef void *HWAVEOUT;
		uint32_t waveOutOpen(HWAVEOUT *phwo, uint32_t uDeviceID, const WAVEFORMATEX *pwfx, uintptr_t dwCallback, uintptr_t dwInstance, uint32_t fdwOpen);
		uint32_t waveOutPrepareHeader(HWAVEOUT hwo, WAVEHDR *pwh, uint32_t cbwh);
		uint32_t waveOutUnprepareHeader(HWAVEOUT hwo, WAVEHDR *pwh, uint32_t cbwh);
		uint32_t waveOutWrite(HWAVEOUT hwo, WAVEHDR *pwh, uint32_t cbwh);
		uint32_t waveOutReset(HWAVEOUT hwo);
		uint32_t waveOutClose(HWAVEOUT hwo);
	]]
	)
	pcall(
		ffi.cdef,
		[[
		void *CreateEventA(void *lpEventAttributes, int bManualReset, int bInitialState, const char *lpName);
		uint32_t WaitForSingleObject(void *hHandle, uint32_t dwMilliseconds);
		int CloseHandle(void *hObject);
	]]
	)
	local winmm = ffi.load("winmm")
	local WAVE_FORMAT_IEEE_FLOAT = 3
	local WAVE_MAPPER = 0xFFFFFFFF
	local CALLBACK_EVENT = 0x00050000
	local WHDR_DONE = 0x00000001
	local INFINITE = 0xFFFFFFFF

	function audio.start(config)
		config = config or {}
		config.sample_rate = config.sample_rate or 44100
		config.buffer_size = config.buffer_size or 512
		config.channels = config.channels or 2
		local bytes_per_frame = 4 * config.channels
		local wfx = ffi.new(
			"WAVEFORMATEX",
			{
				wFormatTag = WAVE_FORMAT_IEEE_FLOAT,
				nChannels = config.channels,
				nSamplesPerSec = config.sample_rate,
				nAvgBytesPerSec = config.sample_rate * bytes_per_frame,
				nBlockAlign = bytes_per_frame,
				wBitsPerSample = 32,
				cbSize = 0,
			}
		)
		-- Auto-reset event: signaled whenever a buffer completes
		local hEvent = ffi.C.CreateEventA(nil, 0, 0, nil)
		audio._hEvent = hEvent
		local hwo = ffi.new("HWAVEOUT[1]")
		local err = winmm.waveOutOpen(hwo, WAVE_MAPPER, wfx, ffi.cast("uintptr_t", hEvent), 0, CALLBACK_EVENT)

		if err ~= 0 then error("waveOutOpen failed: " .. err) end

		audio._hwo = hwo[0]
		audio._config = config
		-- Two ping-pong buffers to keep the device fed while we fill the other
		local buf_bytes = config.buffer_size * bytes_per_frame
		audio._bufs = {}
		audio._hdrs = {}

		for i = 1, 2 do
			local data = ffi.new("float[?]", config.buffer_size * config.channels)
			local hdr = ffi.new("WAVEHDR", {lpData = ffi.cast("char*", data), dwBufferLength = buf_bytes})
			audio._bufs[i] = data
			audio._hdrs[i] = hdr
		end

		-- Pre-fill and enqueue both buffers to prime the device
		local nsamples = config.buffer_size * config.channels

		for i = 1, 2 do
			audio.callback(audio._bufs[i], nsamples, config)
			winmm.waveOutPrepareHeader(audio._hwo, audio._hdrs[i], ffi.sizeof("WAVEHDR"))
			winmm.waveOutWrite(audio._hwo, audio._hdrs[i], ffi.sizeof("WAVEHDR"))
		end

		audio._next = 1
		return config
	end

	-- Waits for the next buffer to be consumed, then fills and re-submits it.
	function audio.update()
		local config = audio._config
		local nsamples = config.buffer_size * config.channels
		local i = audio._next
		local hdr = audio._hdrs[i]

		-- spin-wait until this buffer is marked done by the driver
		while bit.band(hdr.dwFlags, WHDR_DONE) == 0 do
			ffi.C.WaitForSingleObject(audio._hEvent, INFINITE)
		end

		winmm.waveOutUnprepareHeader(audio._hwo, hdr, ffi.sizeof("WAVEHDR"))
		audio.callback(audio._bufs[i], nsamples, config)
		hdr.dwFlags = 0
		winmm.waveOutPrepareHeader(audio._hwo, hdr, ffi.sizeof("WAVEHDR"))
		winmm.waveOutWrite(audio._hwo, hdr, ffi.sizeof("WAVEHDR"))
		audio._next = (i % 2) + 1
	end

	function audio.stop()
		winmm.waveOutReset(audio._hwo)

		for i = 1, 2 do
			winmm.waveOutUnprepareHeader(audio._hwo, audio._hdrs[i], ffi.sizeof("WAVEHDR"))
		end

		winmm.waveOutClose(audio._hwo)
		ffi.C.CloseHandle(audio._hEvent)
		audio._hwo = nil
		audio._hEvent = nil
		audio._bufs = nil
		audio._hdrs = nil
		audio._config = nil
	end
elseif ffi.os == "Linux" then
	local alsa = find_library_linux("libasound")
	ffi.cdef[[
		typedef struct _snd_pcm snd_pcm_t;
		int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
		int snd_pcm_set_params(snd_pcm_t *pcm, int format, int access,
		                       unsigned int channels, unsigned int rate,
		                       int soft_resample, unsigned int latency);
		long snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned long size);
		int snd_pcm_drain(snd_pcm_t *pcm);
		int snd_pcm_close(snd_pcm_t *pcm);
		int snd_pcm_recover(snd_pcm_t *pcm, int err, int silent);
		const char *snd_strerror(int errnum);
	]]
	local SND_PCM_STREAM_PLAYBACK = 0
	local SND_PCM_ACCESS_RW_INTERLEAVED = 3
	local SND_PCM_FORMAT_FLOAT_LE = 14 -- 32-bit IEEE float, little-endian
	-- ensure XDG_RUNTIME_DIR is set so PipeWire ALSA plugin can find its socket
	pcall(ffi.cdef, [[int setenv(const char *name, const char *value, int overwrite);]])

	if not os.getenv("XDG_RUNTIME_DIR") then
		local uid = tonumber(io.popen("id -u"):read("*l")) or 1000
		ffi.C.setenv("XDG_RUNTIME_DIR", "/run/user/" .. uid, 0)
	end

	function audio.start(config)
		config = config or {}
		config.sample_rate = config.sample_rate or 44100
		config.buffer_size = config.buffer_size or 512
		config.channels = config.channels or 2
		local pcm_ptr = ffi.new("snd_pcm_t*[1]")
		local err = alsa.snd_pcm_open(pcm_ptr, "default", SND_PCM_STREAM_PLAYBACK, 0)

		if err < 0 then error("snd_pcm_open: " .. ffi.string(alsa.snd_strerror(err))) end

		local pcm = pcm_ptr[0]
		err = alsa.snd_pcm_set_params(
			pcm,
			SND_PCM_FORMAT_FLOAT_LE,
			SND_PCM_ACCESS_RW_INTERLEAVED,
			config.channels,
			config.sample_rate,
			1, -- soft resample
			50000 -- 50ms latency
		)

		if err < 0 then
			alsa.snd_pcm_close(pcm)
			error("snd_pcm_set_params: " .. ffi.string(alsa.snd_strerror(err)))
		end

		audio._pcm = pcm
		audio._config = config
		audio._buf = ffi.new("float[?]", config.buffer_size * config.channels)
		return config
	end

	-- Fill and write one buffer. Blocks until the hardware accepts it (~buffer_size/sample_rate seconds).
	-- Call this in a loop to drive audio from the main thread, or run the loop
	-- inside a thread via require("bindings.threads").run_thread / threads.new.
	function audio.update()
		local config = audio._config
		local nsamples = config.buffer_size * config.channels
		audio.callback(audio._buf, nsamples, config)
		local ret = alsa.snd_pcm_writei(audio._pcm, audio._buf, config.buffer_size)

		if ret < 0 then alsa.snd_pcm_recover(audio._pcm, ret, 0) end
	end

	function audio.stop()
		alsa.snd_pcm_drain(audio._pcm)
		alsa.snd_pcm_close(audio._pcm)
		audio._pcm = nil
		audio._config = nil
		audio._buf = nil
	end
end

function audio.callback(buffer, num_samples, config)
	for i = 0, num_samples - 1 do
		buffer[i] = 0
	end
end

return audio