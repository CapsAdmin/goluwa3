-- these have mostly all been thrown up by ai and likely need fixing
local ffi = require("ffi")
local ssl = {}
local callbacks = {}
local initialized_backend = nil
local initialized_loader = nil

local function load_windows_tls()
	local secur32 = ffi.load("Secur32.dll")
	local ws2 = ffi.load("ws2_32")
	local kernel32 = ffi.load("kernel32")
	local UNISP_NAME = "Microsoft Unified Security Protocol Provider"
	local SECPKG_CRED_OUTBOUND = 2
	local SECURITY_NETWORK_DREP = 0
	local SCHANNEL_CRED_VERSION = 4
	local SCH_CRED_AUTO_CRED_VALIDATION = 0x00000020
	local SCH_CRED_NO_DEFAULT_CREDS = 0x00000010
	local SCH_USE_STRONG_CRYPTO = 0x00400000
	local SECBUFFER_VERSION = 0
	local SECBUFFER_EMPTY = 0
	local SECBUFFER_DATA = 1
	local SECBUFFER_TOKEN = 2
	local SECBUFFER_ALERT = 17
	local SECBUFFER_EXTRA = 5
	local SECBUFFER_STREAM_HEADER = 7
	local SECBUFFER_STREAM_TRAILER = 6
	local SECPKG_ATTR_STREAM_SIZES = 4
	local ISC_REQ_SEQUENCE_DETECT = 0x00000008
	local ISC_REQ_REPLAY_DETECT = 0x00000004
	local ISC_REQ_CONFIDENTIALITY = 0x00000010
	local ISC_REQ_ALLOCATE_MEMORY = 0x00000100
	local ISC_REQ_STREAM = 0x00008000
	local SEC_E_OK = 0x00000000
	local SEC_I_CONTINUE_NEEDED = 0x00090312
	local SEC_I_COMPLETE_NEEDED = 0x00090313
	local SEC_I_COMPLETE_AND_CONTINUE = 0x00090314
	local SEC_E_INCOMPLETE_MESSAGE = 0x80090318
	local SEC_I_CONTEXT_EXPIRED = 0x00090317
	local WSAEWOULDBLOCK = 10035
	local WSAEINPROGRESS = 10036
	local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
	local FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200
	local SECURITY_INTEGER = ffi.typeof("struct { uint32_t LowPart; int32_t HighPart; }")
	local SecHandle = ffi.typeof("struct { uintptr_t dwLower; uintptr_t dwUpper; }")
	local SecBuffer = ffi.typeof("struct { uint32_t cbBuffer; uint32_t BufferType; void* pvBuffer; }")
	local SecBufferDesc = ffi.typeof("struct { uint32_t ulVersion; uint32_t cBuffers; $* pBuffers; }", SecBuffer)
	local SCHANNEL_CRED = ffi.typeof([[struct {
		uint32_t dwVersion;
		uint32_t cCreds;
		void* paCred;
		void* hRootStore;
		uint32_t cMappers;
		void* aphMappers;
		uint32_t cSupportedAlgs;
		void* palgSupportedAlgs;
		uint32_t grbitEnabledProtocols;
		uint32_t dwMinimumCipherStrength;
		uint32_t dwMaximumCipherStrength;
		uint32_t dwSessionLifespan;
		uint32_t dwFlags;
		uint32_t dwCredFormat;
	}]] )
	local SecBuffer1 = ffi.typeof("$[1]", SecBuffer)
	local SecBuffer2 = ffi.typeof("$[2]", SecBuffer)
	local SecBuffer4 = ffi.typeof("$[4]", SecBuffer)
	local SecHandle_arr = ffi.typeof("$[1]", SecHandle)
	local SECURITY_INTEGER_arr = ffi.typeof("$[1]", SECURITY_INTEGER)
	local SecPkgContext_StreamSizes = ffi.typeof([[struct {
		uint32_t cbHeader;
		uint32_t cbTrailer;
		uint32_t cbMaximumMessage;
		uint32_t cBuffers;
		uint32_t cbBlockSize;
	}]])
	ffi.cdef[[
		int recv(uintptr_t, void*, int, int);
		int send(uintptr_t, const void*, int, int);
		int WSAGetLastError(void);
		uint32_t AcquireCredentialsHandleA(const char*, const char*, uint32_t, void*, void*, void*, void*, void*, void*);
		uint32_t InitializeSecurityContextA(void*, void*, const char*, uint32_t, uint32_t, uint32_t, void*, uint32_t, void*, void*, uint32_t*, void*);
		uint32_t CompleteAuthToken(void*, void*);
		uint32_t EncryptMessage(void*, uint32_t, void*, uint32_t);
		uint32_t DecryptMessage(void*, void*, uint32_t, uint32_t*);
		uint32_t DeleteSecurityContext(void*);
		uint32_t FreeCredentialsHandle(void*);
		uint32_t FreeContextBuffer(void*);
		uint32_t QueryContextAttributesA(void*, uint32_t, void*);
		uint32_t FormatMessageA(
			uint32_t dwFlags,
			const void* lpSource,
			uint32_t dwMessageId,
			uint32_t dwLanguageId,
			char* lpBuffer,
			uint32_t nSize,
			void* Arguments
		);
	]]
	local security_status_names = {
		[0x00000000] = "SEC_E_OK",
		[0x00090312] = "SEC_I_CONTINUE_NEEDED",
		[0x00090313] = "SEC_I_COMPLETE_NEEDED",
		[0x00090314] = "SEC_I_COMPLETE_AND_CONTINUE",
		[0x80090318] = "SEC_E_INCOMPLETE_MESSAGE",
		[0x00090317] = "SEC_I_CONTEXT_EXPIRED",
		[0x80090301] = "SEC_E_INVALID_HANDLE",
		[0x80090300] = "SEC_E_INSUFFICIENT_MEMORY",
		[0x80090302] = "SEC_E_INTERNAL_ERROR",
		[0x80090303] = "SEC_E_INVALID_TOKEN",
		[0x80090304] = "SEC_E_LOGON_DENIED",
		[0x80090305] = "SEC_E_NO_CREDENTIALS",
		[0x80090308] = "SEC_E_TARGET_UNKNOWN",
		[0x80090311] = "SEC_E_UNSUPPORTED_FUNCTION",
		[0x80090321] = "SEC_E_WRONG_PRINCIPAL",
		[0x80090325] = "SEC_E_UNTRUSTED_ROOT",
		[0x8009030C] = "SEC_E_MESSAGE_ALTERED",
		[0x8009030D] = "SEC_E_OUT_OF_SEQUENCE",
		[0x8009030E] = "SEC_E_NO_AUTHENTICATING_AUTHORITY",
		[0x80090326] = "SEC_E_CERT_UNKNOWN",
		[0x80090327] = "SEC_E_CERT_EXPIRED",
	}

	local function get_wsa_error_string(err_code)
		local buffer = ffi.new("char[512]")
		local len = kernel32.FormatMessageA(
			bit.bor(FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS),
			nil,
			err_code,
			0,
			buffer,
			512,
			nil
		)

		if len > 0 then return ffi.string(buffer, len):gsub("[\r\n]+$", "") end

		return string.format("WSA Error %d", err_code)
	end

	local function get_security_error_string(status)
		local status_name = security_status_names[status] or string.format("0x%08X", status)
		local buffer = ffi.new("char[512]")
		local len = kernel32.FormatMessageA(
			bit.bor(FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS),
			nil,
			status,
			0,
			buffer,
			512,
			nil
		)

		if len > 0 then
			local msg = ffi.string(buffer, len):gsub("[\r\n]+$", "")
			return string.format("%s: %s", status_name, msg)
		end

		return status_name
	end

	local function create_client()
		local hCreds = ffi.new(SecHandle_arr)
		local hContext = ffi.new(SecHandle_arr)
		local tsExpiry = ffi.new(SECURITY_INTEGER_arr)
		local state = "init"
		local recv_buffer = ffi.new("uint8_t[?]", 65536)
		local recv_len = 0
		local stored_fd = nil
		local stream_sizes = nil
		local context_initialized = false
		local credentials = ffi.new(SCHANNEL_CRED)
		credentials.dwVersion = SCHANNEL_CRED_VERSION
		credentials.dwFlags = bit.bor(
			SCH_CRED_AUTO_CRED_VALIDATION,
			SCH_CRED_NO_DEFAULT_CREDS,
			SCH_USE_STRONG_CRYPTO
		)
		local status = secur32.AcquireCredentialsHandleA(
			nil,
			UNISP_NAME,
			SECPKG_CRED_OUTBOUND,
			nil,
			credentials,
			nil,
			nil,
			hCreds,
			tsExpiry
		)

		if status ~= SEC_E_OK then
			return nil,
			"AcquireCredentialsHandle failed: " .. get_security_error_string(status)
		end

		local function connect(fd, host)
			stored_fd = fd

			if state ~= "init" then return true end

			local dwSSPIFlags = bit.bor(
				ISC_REQ_SEQUENCE_DETECT,
				ISC_REQ_REPLAY_DETECT,
				ISC_REQ_CONFIDENTIALITY,
				ISC_REQ_ALLOCATE_MEMORY,
				ISC_REQ_STREAM
			)
			local host_cstr = host and ffi.cast("const char*", host) or nil

			while true do
				local outBuffers = ffi.new(SecBuffer2)
				outBuffers[0].BufferType = SECBUFFER_TOKEN
				outBuffers[0].cbBuffer = 0
				outBuffers[0].pvBuffer = nil
				outBuffers[1].BufferType = SECBUFFER_ALERT
				outBuffers[1].cbBuffer = 0
				outBuffers[1].pvBuffer = nil
				local outBufferDesc = ffi.new(SecBufferDesc, SECBUFFER_VERSION, 2, outBuffers)
				local inBuffers = nil
				local inBufferDesc = nil
				local contextAttribs = ffi.new("uint32_t[1]")

				if recv_len > 0 then
					inBuffers = ffi.new(SecBuffer2)
					inBuffers[0].BufferType = SECBUFFER_TOKEN
					inBuffers[0].cbBuffer = recv_len
					inBuffers[0].pvBuffer = recv_buffer
					inBuffers[1].BufferType = SECBUFFER_EMPTY
					inBuffers[1].cbBuffer = 0
					inBuffers[1].pvBuffer = nil
					inBufferDesc = ffi.new(SecBufferDesc, SECBUFFER_VERSION, 2, inBuffers)
				end

				local hContextPtr = context_initialized and hContext or nil
				status = secur32.InitializeSecurityContextA(
					hCreds,
					hContextPtr,
					host_cstr,
					dwSSPIFlags,
					0,
					SECURITY_NETWORK_DREP,
					inBufferDesc,
					0,
					hContext,
					outBufferDesc,
					contextAttribs,
					tsExpiry
				)
				context_initialized = true

				if status == SEC_I_COMPLETE_NEEDED or status == SEC_I_COMPLETE_AND_CONTINUE then
					local complete_status = secur32.CompleteAuthToken(hContext, outBufferDesc)

					if complete_status ~= SEC_E_OK then
						return nil, "CompleteAuthToken failed: " .. get_security_error_string(complete_status)
					end
				end

				if
					status == SEC_E_OK or
					status == SEC_I_CONTINUE_NEEDED or
					status == SEC_I_COMPLETE_NEEDED or
					status == SEC_I_COMPLETE_AND_CONTINUE
				then
					if outBuffers[0].cbBuffer > 0 and outBuffers[0].pvBuffer ~= nil then
						local sent = ws2.send(fd, outBuffers[0].pvBuffer, outBuffers[0].cbBuffer, 0)
						secur32.FreeContextBuffer(outBuffers[0].pvBuffer)

						if sent <= 0 then
							local err = ws2.WSAGetLastError()

							if err == WSAEWOULDBLOCK or err == WSAEINPROGRESS then
								return nil, "tryagain"
							end

							return nil, "Failed to send handshake data"
						end
					end

					if
						inBuffers and
						inBuffers[1].BufferType == SECBUFFER_EXTRA and
						inBuffers[1].cbBuffer > 0
					then
						local extra_offset = recv_len - inBuffers[1].cbBuffer
						ffi.copy(recv_buffer, recv_buffer + extra_offset, inBuffers[1].cbBuffer)
						recv_len = inBuffers[1].cbBuffer
					else
						recv_len = 0
					end

					if status == SEC_E_OK then
						stream_sizes = ffi.new(SecPkgContext_StreamSizes)
						local query_status = secur32.QueryContextAttributesA(hContext, SECPKG_ATTR_STREAM_SIZES, stream_sizes)

						if query_status ~= SEC_E_OK then
							return nil,
							"QueryContextAttributes failed: " .. get_security_error_string(query_status)
						end

						state = "connected"
						return true
					end

					local bytes = ws2.recv(fd, recv_buffer + recv_len, 65536 - recv_len, 0)

					if bytes > 0 then
						recv_len = recv_len + bytes
					elseif bytes == 0 then
						return nil, "Connection closed during handshake"
					else
						local err = ws2.WSAGetLastError()

						if err == WSAEWOULDBLOCK or err == WSAEINPROGRESS then
							return nil, "tryagain"
						end

						return nil, "recv failed: " .. get_wsa_error_string(err)
					end
				elseif status == SEC_E_INCOMPLETE_MESSAGE then
					local bytes = ws2.recv(fd, recv_buffer + recv_len, 65536 - recv_len, 0)

					if bytes > 0 then
						recv_len = recv_len + bytes
					elseif bytes == 0 then
						return nil, "Connection closed during handshake"
					else
						local err = ws2.WSAGetLastError()

						if err == WSAEWOULDBLOCK or err == WSAEINPROGRESS then
							return nil, "tryagain"
						end

						return nil, "recv failed: " .. get_wsa_error_string(err)
					end
				else
					return nil, "Handshake failed: " .. get_security_error_string(status)
				end
			end
		end

		local function send(data)
			if state ~= "connected" then return nil, "Not connected" end

			if not stream_sizes then return nil, "Stream sizes not initialized" end

			local msg_buffer = ffi.new("uint8_t[?]", stream_sizes.cbHeader + #data + stream_sizes.cbTrailer)
			ffi.copy(msg_buffer + stream_sizes.cbHeader, data, #data)
			local buffers = ffi.new(SecBuffer4)
			buffers[0].BufferType = SECBUFFER_STREAM_HEADER
			buffers[0].cbBuffer = stream_sizes.cbHeader
			buffers[0].pvBuffer = msg_buffer
			buffers[1].BufferType = SECBUFFER_DATA
			buffers[1].cbBuffer = #data
			buffers[1].pvBuffer = msg_buffer + stream_sizes.cbHeader
			buffers[2].BufferType = SECBUFFER_STREAM_TRAILER
			buffers[2].cbBuffer = stream_sizes.cbTrailer
			buffers[2].pvBuffer = msg_buffer + stream_sizes.cbHeader + #data
			buffers[3].BufferType = SECBUFFER_EMPTY
			buffers[3].cbBuffer = 0
			buffers[3].pvBuffer = nil
			local bufferDesc = ffi.new(SecBufferDesc, SECBUFFER_VERSION, 4, buffers)
			status = secur32.EncryptMessage(hContext, 0, bufferDesc, 0)

			if status ~= SEC_E_OK then
				return nil, "EncryptMessage failed: " .. get_security_error_string(status)
			end

			local total_len = buffers[0].cbBuffer + buffers[1].cbBuffer + buffers[2].cbBuffer
			local sent = ws2.send(stored_fd, msg_buffer, total_len, 0)

			if sent <= 0 then return nil, "Send failed" end

			return #data
		end

		local function receive(buffer, max_size)
			if state ~= "connected" then return nil, "Not connected" end

			while true do
				if recv_len == 0 then
					local bytes = ws2.recv(stored_fd, recv_buffer, 65536, 0)

					if bytes > 0 then
						recv_len = bytes
					elseif bytes == 0 then
						return ""
					else
						return nil, "tryagain"
					end
				end

				local buffers = ffi.new(SecBuffer4)
				buffers[0].BufferType = SECBUFFER_DATA
				buffers[0].cbBuffer = recv_len
				buffers[0].pvBuffer = recv_buffer
				buffers[1].BufferType = SECBUFFER_EMPTY
				buffers[1].cbBuffer = 0
				buffers[1].pvBuffer = nil
				buffers[2].BufferType = SECBUFFER_EMPTY
				buffers[2].cbBuffer = 0
				buffers[2].pvBuffer = nil
				buffers[3].BufferType = SECBUFFER_EMPTY
				buffers[3].cbBuffer = 0
				buffers[3].pvBuffer = nil
				local bufferDesc = ffi.new(SecBufferDesc, SECBUFFER_VERSION, 4, buffers)
				status = secur32.DecryptMessage(hContext, bufferDesc, 0, nil)

				if status == SEC_E_OK or status == SEC_I_CONTEXT_EXPIRED then
					local data_buffer_idx = -1
					local extra_buffer_idx = -1

					for i = 0, 3 do
						if buffers[i].BufferType == SECBUFFER_DATA then
							data_buffer_idx = i
						elseif buffers[i].BufferType == SECBUFFER_EXTRA then
							extra_buffer_idx = i
						end
					end

					if data_buffer_idx >= 0 then
						local data_len = math.min(buffers[data_buffer_idx].cbBuffer, max_size)
						ffi.copy(buffer, buffers[data_buffer_idx].pvBuffer, data_len)

						if extra_buffer_idx >= 0 and buffers[extra_buffer_idx].cbBuffer > 0 then
							ffi.copy(
								recv_buffer,
								buffers[extra_buffer_idx].pvBuffer,
								buffers[extra_buffer_idx].cbBuffer
							)
							recv_len = buffers[extra_buffer_idx].cbBuffer
						else
							recv_len = 0
						end

						return ffi.string(buffer, data_len)
					end

					return ""
				elseif status == SEC_E_INCOMPLETE_MESSAGE then
					local bytes = ws2.recv(stored_fd, recv_buffer + recv_len, 65536 - recv_len, 0)

					if bytes > 0 then
						recv_len = recv_len + bytes
					elseif bytes == 0 then
						return nil, "Connection closed while waiting for complete message"
					else
						local err = ws2.WSAGetLastError()

						if err == WSAEWOULDBLOCK or err == WSAEINPROGRESS then
							return nil, "tryagain"
						end

						return nil, "recv failed while waiting for complete message: " .. get_wsa_error_string(err)
					end
				else
					return nil, "DecryptMessage failed: " .. get_security_error_string(status)
				end
			end
		end

		local function close()
			if hContext[0].dwLower ~= 0 or hContext[0].dwUpper ~= 0 then
				secur32.DeleteSecurityContext(hContext)
			end

			secur32.FreeCredentialsHandle(hCreds)
		end

		return {
			connect = connect,
			send = send,
			receive = receive,
			close = close,
		}
	end

	return {
		create_client = create_client,
	}
end

local function load_libtls()
	local CLIB

	if jit.os == "OSX" then
		CLIB = assert(ffi.load("./libtls.dylib"))
	elseif jit.os == "Windows" then
		CLIB = assert(ffi.load("./tls.dll"))
	else
		CLIB = assert(ffi.load("./libtls.so"))
	end

	ffi.cdef([[struct tls {};
	struct tls_config {};
	const char*(tls_peer_ocsp_url)(struct tls*);
	int(tls_config_set_dheparams)(struct tls_config*,const char*);
	int(tls_config_set_keypair_file)(struct tls_config*,const char*,const char*);
	const char*(tls_conn_version)(struct tls*);
	int(tls_conn_session_resumed)(struct tls*);
	int(tls_config_set_ca_file)(struct tls_config*,const char*);
	int(tls_config_set_ciphers)(struct tls_config*,const char*);
	int(tls_ocsp_process_response)(struct tls*,const unsigned char*,unsigned long);
	int(tls_peer_ocsp_cert_status)(struct tls*);
	void(tls_config_insecure_noverifytime)(struct tls_config*);
	int(tls_config_add_keypair_mem)(struct tls_config*,const unsigned char*,unsigned long,const unsigned char*,unsigned long);
	int(tls_config_set_cert_mem)(struct tls_config*,const unsigned char*,unsigned long);
	const char*(tls_config_error)(struct tls_config*);
	int(tls_config_set_ocsp_staple_file)(struct tls_config*,const char*);
	const char*(tls_peer_ocsp_result)(struct tls*);
	void(tls_config_verify_client)(struct tls_config*);
	int(tls_config_add_keypair_ocsp_mem)(struct tls_config*,const unsigned char*,unsigned long,const unsigned char*,unsigned long,const unsigned char*,unsigned long);
	int(tls_connect_cbs)(struct tls*,long(*_read_cb)(struct tls*,void*,unsigned long,void*),long(*_write_cb)(struct tls*,const void*,unsigned long,void*),void*,const char*);
	struct tls_config*(tls_config_new)();
	void(tls_config_insecure_noverifycert)(struct tls_config*);
	int(tls_config_set_key_file)(struct tls_config*,const char*);
	long(tls_peer_ocsp_next_update)(struct tls*);
	int(tls_config_set_cert_file)(struct tls_config*,const char*);
	int(tls_handshake)(struct tls*);
	struct tls*(tls_server)();
	int(tls_config_set_crl_mem)(struct tls_config*,const unsigned char*,unsigned long);
	void(tls_config_ocsp_require_stapling)(struct tls_config*);
	int(tls_config_parse_protocols)(unsigned int*,const char*);
	void(tls_config_verify_client_optional)(struct tls_config*);
	void(tls_config_verify)(struct tls_config*);
	int(tls_config_set_alpn)(struct tls_config*,const char*);
	int(tls_connect_fds)(struct tls*,int,int,const char*);
	void(tls_config_free)(struct tls_config*);
	int(tls_config_set_ocsp_staple_mem)(struct tls_config*,const unsigned char*,unsigned long);
	void(tls_free)(struct tls*);
	int(tls_config_set_verify_depth)(struct tls_config*,int);
	int(tls_config_set_ecdhecurve)(struct tls_config*,const char*);
	long(tls_peer_ocsp_this_update)(struct tls*);
	long(tls_peer_ocsp_revocation_time)(struct tls*);
	const char*(tls_conn_cipher)(struct tls*);
	int(tls_peer_ocsp_response_status)(struct tls*);
	void(tls_unload_file)(unsigned char*,unsigned long);
	int(tls_connect)(struct tls*,const char*,const char*);
	int(tls_peer_ocsp_crl_reason)(struct tls*);
	unsigned char*(tls_load_file)(const char*,unsigned long*,char*);
	const char*(tls_default_ca_cert_file)();
	const char*(tls_conn_alpn_selected)(struct tls*);
	const char*(tls_peer_cert_hash)(struct tls*);
	int(tls_config_add_ticket_key)(struct tls_config*,unsigned int,unsigned char*,unsigned long);
	int(tls_config_set_ecdhecurves)(struct tls_config*,const char*);
	void(tls_config_prefer_ciphers_client)(struct tls_config*);
	int(tls_accept_fds)(struct tls*,struct tls**,int,int);
	long(tls_peer_cert_notafter)(struct tls*);
	long(tls_peer_cert_notbefore)(struct tls*);
	int(tls_peer_cert_provided)(struct tls*);
	int(tls_accept_cbs)(struct tls*,struct tls**,long(*_read_cb)(struct tls*,void*,unsigned long,void*),long(*_write_cb)(struct tls*,const void*,unsigned long,void*),void*);
	const char*(tls_peer_cert_subject)(struct tls*);
	int(tls_config_add_keypair_ocsp_file)(struct tls_config*,const char*,const char*,const char*);
	int(tls_accept_socket)(struct tls*,struct tls**,int);
	const char*(tls_peer_cert_issuer)(struct tls*);
	int(tls_init)();
	int(tls_peer_cert_contains_name)(struct tls*,const char*);
	int(tls_connect_servername)(struct tls*,const char*,const char*,const char*);
	const char*(tls_error)(struct tls*);
	int(tls_close)(struct tls*);
	long(tls_write)(struct tls*,const void*,unsigned long);
	long(tls_read)(struct tls*,void*,unsigned long);
	int(tls_connect_socket)(struct tls*,int,const char*);
	int(tls_config_set_crl_file)(struct tls_config*,const char*);
	struct tls*(tls_client)();
	int(tls_configure)(struct tls*,struct tls_config*);
	int(tls_config_set_keypair_mem)(struct tls_config*,const unsigned char*,unsigned long,const unsigned char*,unsigned long);
	int(tls_config_set_ca_path)(struct tls_config*,const char*);
	void(tls_config_insecure_noverifyname)(struct tls_config*);
	const char*(tls_conn_servername)(struct tls*);
	int(tls_config_set_keypair_ocsp_mem)(struct tls_config*,const unsigned char*,unsigned long,const unsigned char*,unsigned long,const unsigned char*,unsigned long);
	int(tls_config_add_keypair_file)(struct tls_config*,const char*,const char*);
	int(tls_config_set_protocols)(struct tls_config*,unsigned int);
	void(tls_reset)(struct tls*);
	int(tls_config_set_key_mem)(struct tls_config*,const unsigned char*,unsigned long);
	const unsigned char*(tls_peer_cert_chain_pem)(struct tls*,unsigned long*);
	int(tls_config_set_session_lifetime)(struct tls_config*,int);
	int(tls_config_set_keypair_ocsp_file)(struct tls_config*,const char*,const char*,const char*);
	void(tls_config_prefer_ciphers_server)(struct tls_config*);
	int(tls_config_set_ca_mem)(struct tls_config*,const unsigned char*,unsigned long);
	int(tls_config_set_session_id)(struct tls_config*,const unsigned char*,unsigned long);
	int(tls_config_set_session_fd)(struct tls_config*,int);
	void(tls_config_clear_keys)(struct tls_config*);
	]])
	local library = {
		tls_peer_ocsp_url = CLIB.tls_peer_ocsp_url,
		tls_config_set_dheparams = CLIB.tls_config_set_dheparams,
		tls_config_set_keypair_file = CLIB.tls_config_set_keypair_file,
		tls_conn_version = CLIB.tls_conn_version,
		tls_conn_session_resumed = CLIB.tls_conn_session_resumed,
		tls_config_set_ca_file = CLIB.tls_config_set_ca_file,
		tls_config_set_ciphers = CLIB.tls_config_set_ciphers,
		tls_ocsp_process_response = CLIB.tls_ocsp_process_response,
		tls_peer_ocsp_cert_status = CLIB.tls_peer_ocsp_cert_status,
		tls_config_insecure_noverifytime = CLIB.tls_config_insecure_noverifytime,
		tls_config_add_keypair_mem = CLIB.tls_config_add_keypair_mem,
		tls_config_set_cert_mem = CLIB.tls_config_set_cert_mem,
		tls_config_error = CLIB.tls_config_error,
		tls_config_set_ocsp_staple_file = CLIB.tls_config_set_ocsp_staple_file,
		tls_peer_ocsp_result = CLIB.tls_peer_ocsp_result,
		__debugbreak = CLIB.__debugbreak,
		tls_config_verify_client = CLIB.tls_config_verify_client,
		tls_config_add_keypair_ocsp_mem = CLIB.tls_config_add_keypair_ocsp_mem,
		tls_connect_cbs = CLIB.tls_connect_cbs,
		tls_config_new = CLIB.tls_config_new,
		tls_config_insecure_noverifycert = CLIB.tls_config_insecure_noverifycert,
		tls_config_set_key_file = CLIB.tls_config_set_key_file,
		tls_peer_ocsp_next_update = CLIB.tls_peer_ocsp_next_update,
		tls_config_set_cert_file = CLIB.tls_config_set_cert_file,
		tls_handshake = CLIB.tls_handshake,
		tls_server = CLIB.tls_server,
		tls_config_set_crl_mem = CLIB.tls_config_set_crl_mem,
		tls_config_ocsp_require_stapling = CLIB.tls_config_ocsp_require_stapling,
		tls_config_parse_protocols = CLIB.tls_config_parse_protocols,
		tls_config_verify_client_optional = CLIB.tls_config_verify_client_optional,
		tls_config_verify = CLIB.tls_config_verify,
		tls_config_set_alpn = CLIB.tls_config_set_alpn,
		tls_connect_fds = CLIB.tls_connect_fds,
		tls_config_free = CLIB.tls_config_free,
		tls_config_set_ocsp_staple_mem = CLIB.tls_config_set_ocsp_staple_mem,
		tls_free = CLIB.tls_free,
		tls_config_set_verify_depth = CLIB.tls_config_set_verify_depth,
		tls_config_set_ecdhecurve = CLIB.tls_config_set_ecdhecurve,
		_errno = CLIB._errno,
		tls_peer_ocsp_this_update = CLIB.tls_peer_ocsp_this_update,
		tls_peer_ocsp_revocation_time = CLIB.tls_peer_ocsp_revocation_time,
		tls_conn_cipher = CLIB.tls_conn_cipher,
		tls_peer_ocsp_response_status = CLIB.tls_peer_ocsp_response_status,
		tls_unload_file = CLIB.tls_unload_file,
		tls_connect = CLIB.tls_connect,
		tls_peer_ocsp_crl_reason = CLIB.tls_peer_ocsp_crl_reason,
		tls_load_file = CLIB.tls_load_file,
		tls_default_ca_cert_file = CLIB.tls_default_ca_cert_file,
		__threadhandle = CLIB.__threadhandle,
		tls_conn_alpn_selected = CLIB.tls_conn_alpn_selected,
		tls_peer_cert_hash = CLIB.tls_peer_cert_hash,
		tls_config_add_ticket_key = CLIB.tls_config_add_ticket_key,
		tls_config_set_ecdhecurves = CLIB.tls_config_set_ecdhecurves,
		tls_config_prefer_ciphers_client = CLIB.tls_config_prefer_ciphers_client,
		tls_accept_fds = CLIB.tls_accept_fds,
		tls_peer_cert_notafter = CLIB.tls_peer_cert_notafter,
		tls_peer_cert_notbefore = CLIB.tls_peer_cert_notbefore,
		tls_peer_cert_provided = CLIB.tls_peer_cert_provided,
		tls_accept_cbs = CLIB.tls_accept_cbs,
		tls_peer_cert_subject = CLIB.tls_peer_cert_subject,
		tls_config_add_keypair_ocsp_file = CLIB.tls_config_add_keypair_ocsp_file,
		tls_accept_socket = CLIB.tls_accept_socket,
		tls_peer_cert_issuer = CLIB.tls_peer_cert_issuer,
		tls_init = CLIB.tls_init,
		tls_peer_cert_contains_name = CLIB.tls_peer_cert_contains_name,
		tls_connect_servername = CLIB.tls_connect_servername,
		tls_error = CLIB.tls_error,
		tls_close = CLIB.tls_close,
		tls_write = CLIB.tls_write,
		tls_read = CLIB.tls_read,
		tls_connect_socket = CLIB.tls_connect_socket,
		tls_config_set_crl_file = CLIB.tls_config_set_crl_file,
		tls_client = CLIB.tls_client,
		tls_configure = CLIB.tls_configure,
		_set_errno = CLIB._set_errno,
		tls_config_set_keypair_mem = CLIB.tls_config_set_keypair_mem,
		_get_errno = CLIB._get_errno,
		tls_config_set_ca_path = CLIB.tls_config_set_ca_path,
		tls_config_insecure_noverifyname = CLIB.tls_config_insecure_noverifyname,
		tls_conn_servername = CLIB.tls_conn_servername,
		tls_config_set_keypair_ocsp_mem = CLIB.tls_config_set_keypair_ocsp_mem,
		tls_config_add_keypair_file = CLIB.tls_config_add_keypair_file,
		tls_config_set_protocols = CLIB.tls_config_set_protocols,
		tls_reset = CLIB.tls_reset,
		tls_config_set_key_mem = CLIB.tls_config_set_key_mem,
		tls_peer_cert_chain_pem = CLIB.tls_peer_cert_chain_pem,
		tls_config_set_session_lifetime = CLIB.tls_config_set_session_lifetime,
		tls_config_set_keypair_ocsp_file = CLIB.tls_config_set_keypair_ocsp_file,
		__mingw_get_crt_info = CLIB.__mingw_get_crt_info,
		tls_config_prefer_ciphers_server = CLIB.tls_config_prefer_ciphers_server,
		__threadid = CLIB.__threadid,
		tls_config_set_ca_mem = CLIB.tls_config_set_ca_mem,
		tls_config_set_session_id = CLIB.tls_config_set_session_id,
		tls_config_set_session_fd = CLIB.tls_config_set_session_fd,
		tls_config_clear_keys = CLIB.tls_config_clear_keys,
	}
	library.e = {
		HEADER_TLS_H = 1,
		TLS_API = 20180210,
		TLS_PROTOCOL_TLSv1_0 = 2,
		TLS_PROTOCOL_TLSv1_1 = 4,
		TLS_PROTOCOL_TLSv1_2 = 8,
		TLS_PROTOCOLS_DEFAULT = 8,
		TLS_WANT_POLLIN = -2,
		TLS_WANT_POLLOUT = -3,
		TLS_OCSP_RESPONSE_SUCCESSFUL = 0,
		TLS_OCSP_RESPONSE_MALFORMED = 1,
		TLS_OCSP_RESPONSE_INTERNALERROR = 2,
		TLS_OCSP_RESPONSE_TRYLATER = 3,
		TLS_OCSP_RESPONSE_SIGREQUIRED = 4,
		TLS_OCSP_RESPONSE_UNAUTHORIZED = 5,
		TLS_OCSP_CERT_GOOD = 0,
		TLS_OCSP_CERT_REVOKED = 1,
		TLS_OCSP_CERT_UNKNOWN = 2,
		TLS_CRL_REASON_UNSPECIFIED = 0,
		TLS_CRL_REASON_KEY_COMPROMISE = 1,
		TLS_CRL_REASON_CA_COMPROMISE = 2,
		TLS_CRL_REASON_AFFILIATION_CHANGED = 3,
		TLS_CRL_REASON_SUPERSEDED = 4,
		TLS_CRL_REASON_CESSATION_OF_OPERATION = 5,
		TLS_CRL_REASON_CERTIFICATE_HOLD = 6,
		TLS_CRL_REASON_REMOVE_FROM_CRL = 8,
		TLS_CRL_REASON_PRIVILEGE_WITHDRAWN = 9,
		TLS_CRL_REASON_AA_COMPROMISE = 10,
		TLS_MAX_SESSION_ID_LENGTH = 32,
		TLS_TICKET_KEY_SIZE = 48,
	}
	library.clib = CLIB
	library.tls_init()

	local function create_client()
		local client = library.tls_client()

		if client == nil then return nil, "Failed to create libtls client" end

		if library.tls_configure(client, nil) < 0 then
			local err = library.tls_error(client)
			library.tls_free(client)
			return nil, err ~= nil and ffi.string(err) or "tls_configure failed"
		end

		local function connect(fd, host)
			if library.tls_connect_socket(client, fd, host) < 0 then
				return nil, ffi.string(library.tls_error(client))
			end

			if library.tls_handshake(client) < 0 then
				return nil, ffi.string(library.tls_error(client))
			end

			return true
		end

		local function send(data)
			local len = library.tls_write(client, data, #data)

			if len < 0 then return nil, ffi.string(library.tls_error(client)) end

			return len
		end

		local function receive(buffer, max_size)
			local len = library.tls_read(client, buffer, max_size)

			if len < 0 then return nil, ffi.string(library.tls_error(client)) end

			return ffi.string(buffer, len)
		end

		local function close()
			library.tls_close(client)
			library.tls_free(client)
		end

		return {
			connect = connect,
			send = send,
			receive = receive,
			close = close,
		}
	end

	return {
		create_client = create_client,
		library = library,
	}
end

local function load_openssl()
	local crypto_libs = {
		"/opt/homebrew/opt/openssl/lib/libcrypto.dylib",
		"crypto",
		"libcrypto.so.3",
		"libcrypto.so.1.1",
		"libcrypto.so",
	}
	local lib_crypto = nil

	for _, name in ipairs(crypto_libs) do
		local success, loaded = pcall(ffi.load, name)

		if success then
			lib_crypto = loaded

			break
		end
	end

	local ssl_libs = {
		"/opt/homebrew/opt/openssl/lib/libssl.dylib",
		"ssl",
		"libssl.so.3",
		"libssl.so.1.1",
		"libssl.so",
	}
	local lib_ssl = nil

	for _, name in ipairs(ssl_libs) do
		local success, loaded = pcall(ffi.load, name)

		if success then
			lib_ssl = loaded

			break
		end
	end

	if not lib_ssl then error("Could not load OpenSSL") end

	ffi.cdef([[
		typedef struct ssl_st SSL;
		typedef struct ssl_ctx_st SSL_CTX;
		typedef struct ssl_method_st SSL_METHOD;
		unsigned long ERR_get_error(void);
		char* ERR_error_string(unsigned long e, char *buf);
		SSL_CTX* SSL_CTX_new(const SSL_METHOD *method);
		void SSL_CTX_free(SSL_CTX *ctx);
		SSL* SSL_new(SSL_CTX *ctx);
		int SSL_set_fd(SSL *ssl, int fd);
		int SSL_connect(SSL *ssl);
		int SSL_write(SSL *ssl, const void *buf, int num);
		int SSL_read(SSL *ssl, void *buf, int num);
		int SSL_get_error(SSL *ssl, int ret);
		int SSL_shutdown(SSL *ssl);
		void SSL_free(SSL *ssl);
		long SSL_ctrl(SSL *ssl, int cmd, long larg, void *parg);
	]])
	local initialized = false
	local modern_init = pcall(function()
		ffi.cdef([[int OPENSSL_init_ssl(uint64_t opts, void *settings);]])
		local ret = lib_ssl.OPENSSL_init_ssl(0, nil)

		if ret ~= 1 then error("OPENSSL_init_ssl failed") end
	end)

	if modern_init then
		initialized = true
	else
		local legacy_init = pcall(function()
			ffi.cdef([[
				void SSL_load_error_strings(void);
				int SSL_library_init(void);
				void OpenSSL_add_all_algorithms(void);
			]])
			lib_ssl.SSL_library_init()
			lib_ssl.SSL_load_error_strings()

			if lib_crypto then lib_crypto.OpenSSL_add_all_algorithms() end
		end)

		if legacy_init then initialized = true end
	end

	if not initialized then error("Failed to initialize OpenSSL") end

	local method = nil
	local modern_ok = pcall(function()
		ffi.cdef([[const SSL_METHOD* TLS_client_method(void);]])
		method = lib_ssl.TLS_client_method()
	end)

	if not modern_ok or method == nil then
		local legacy_ok = pcall(function()
			ffi.cdef([[const SSL_METHOD* SSLv23_client_method(void);]])
			method = lib_ssl.SSLv23_client_method()
		end)

		if not legacy_ok then
			pcall(function()
				ffi.cdef([[const SSL_METHOD* TLSv1_2_client_method(void);]])
				method = lib_ssl.TLSv1_2_client_method()
			end)
		end
	end

	if method == nil then
		error("Failed to get SSL method - OpenSSL library may be incompatible")
	end

	local SSL_CTRL_SET_TLSEXT_HOSTNAME = 55
	local TLSEXT_NAMETYPE_host_name = 0

	local function get_error_string()
		local err = lib_ssl.ERR_get_error()

		if err == 0 then return "Unknown SSL error" end

		local buf = ffi.new("char[256]")
		lib_ssl.ERR_error_string(err, buf)
		return ffi.string(buf)
	end

	local function create_client()
		local ctx = lib_ssl.SSL_CTX_new(method)

		if ctx == nil then return nil, "Failed to create SSL context" end

		local ssl_conn = nil
		local state = "connecting"
		local host_name_buffer = nil

		local function connect(fd, host)
			if state == "connecting" then
				ssl_conn = lib_ssl.SSL_new(ctx)

				if ssl_conn == nil then return nil, "Failed to create SSL connection" end

				if lib_ssl.SSL_set_fd(ssl_conn, fd) ~= 1 then
					return nil, "Failed to set file descriptor"
				end

				if host then
					host_name_buffer = ffi.new("char[?]", #host + 1)
					ffi.copy(host_name_buffer, host)
					local ret = lib_ssl.SSL_ctrl(
						ssl_conn,
						SSL_CTRL_SET_TLSEXT_HOSTNAME,
						TLSEXT_NAMETYPE_host_name,
						ffi.cast("void*", host_name_buffer)
					)

					if ret == 0 then return nil, "Failed to set SNI hostname" end
				end

				state = "handshaking"
			end

			if state == "handshaking" then
				local ret = lib_ssl.SSL_connect(ssl_conn)

				if ret == 1 then
					state = "connected"
					return true
				end

				local err = lib_ssl.SSL_get_error(ssl_conn, ret)

				if err == 2 or err == 3 then return nil, "tryagain", err end

				return nil, get_error_string()
			end

			if state == "connected" then return true end

			return nil, "tryagain"
		end

		local function send(data_str)
			if state ~= "connected" or not ssl_conn then
				return nil, "context not connected"
			end

			local ret = lib_ssl.SSL_write(ssl_conn, data_str, #data_str)

			if ret > 0 then return ret end

			local err = lib_ssl.SSL_get_error(ssl_conn, ret)

			if err == 2 or err == 3 then return nil, "tryagain", err end

			return nil, get_error_string()
		end

		local function receive(buffer_ptr, buffer_size)
			if state ~= "connected" or not ssl_conn then
				return nil, "context not connected"
			end

			local ret = lib_ssl.SSL_read(ssl_conn, buffer_ptr, buffer_size)

			if ret > 0 then return ffi.string(buffer_ptr, ret) end

			if ret == 0 then return "" end

			local err = lib_ssl.SSL_get_error(ssl_conn, ret)

			if err == 2 or err == 3 then return nil, "tryagain", err end

			return nil, get_error_string()
		end

		local function close()
			if state == "closed" then return true end

			state = "closed"

			if ssl_conn then
				lib_ssl.SSL_shutdown(ssl_conn)
				lib_ssl.SSL_free(ssl_conn)
				ssl_conn = nil
			end

			lib_ssl.SSL_CTX_free(ctx)
		end

		return {
			connect = connect,
			send = send,
			receive = receive,
			close = close,
		}
	end

	return {
		create_client = create_client,
		lib_ssl = lib_ssl,
		lib_crypto = lib_crypto,
	}
end

local function load_security_framework_tls()
	local lib = ffi.load("/System/Library/Frameworks/Security.framework/Security")
	local cf = ffi.load("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
	ffi.cdef([[
		typedef void* SSLContextRef;
		SSLContextRef SSLCreateContext(void* alloc, int protocolSide, int connectionType);
		int SSLClose(SSLContextRef context);
		void CFRelease(void* cf);
		int SSLSetConnection(SSLContextRef context, void* connection);
		int SSLSetPeerDomainName(SSLContextRef context, const char* peerName, size_t peerNameLen);
		typedef int (*SSLReadFunc)(void* connection, void* data, size_t* dataLength);
		typedef int (*SSLWriteFunc)(void* connection, const void* data, size_t* dataLength);
		int SSLSetIOFuncs(SSLContextRef context, SSLReadFunc readFunc, SSLWriteFunc writeFunc);
		int SSLHandshake(SSLContextRef context);
		int SSLWrite(SSLContextRef context, const void* data, size_t dataLength, size_t* processed);
		int SSLRead(SSLContextRef context, void* data, size_t dataLength, size_t* processed);
		ssize_t read(int fd, void* buf, size_t count);
		ssize_t write(int fd, const void* buf, size_t count);
		int* __error(void);
		void *SecCopyErrorMessageString(int32_t status, void *reserved);
		const char* CFStringGetCStringPtr(void *theString, unsigned long encoding);
		signed long CFStringGetLength(void *theString);
		signed long CFStringGetMaximumSizeForEncoding(signed long length, unsigned long encoding);
		unsigned char CFStringGetCString(void *theString, char *buffer, signed long bufferSize, unsigned long encoding);
	]])
	local errSecSuccess = 0
	local errSSLWouldBlock = -9803
	local errSSLClosedGraceful = -9805
	local errSSLClosedAbort = -9806
	local kSSLClientSide = 1
	local kSSLStreamType = 0
	local kCFStringEncodingUTF8 = 0x08000100

	local function status_to_msg(code)
		local cfStr = lib.SecCopyErrorMessageString(code, nil)

		if cfStr == nil then return "Unknown error code: " .. code end

		local length = cf.CFStringGetLength(cfStr)
		local maxSize = cf.CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1
		local buffer = ffi.new("char[?]", maxSize)
		local success = cf.CFStringGetCString(cfStr, buffer, maxSize, kCFStringEncodingUTF8)
		cf.CFRelease(cfStr)

		if success then return ffi.string(buffer) end

		return nil
	end

	local function get_errno()
		return ffi.C.__error()[0]
	end

	local EAGAIN = 35
	callbacks.read = callbacks.read or
		ffi.cast("SSLReadFunc", function(connection, data, dataLength)
			local fd_ptr = ffi.cast("int*", connection)
			local fd = fd_ptr[0]
			local len = tonumber(dataLength[0])
			local result = ffi.C.read(fd, data, len)

			if result > 0 then
				dataLength[0] = result
				return errSecSuccess
			elseif result == 0 then
				dataLength[0] = 0
				return errSSLClosedGraceful
			end

			local errno = get_errno()

			if errno == EAGAIN then
				dataLength[0] = 0
				return errSSLWouldBlock
			end

			dataLength[0] = 0
			return errSSLClosedAbort
		end)
	callbacks.write = callbacks.write or
		ffi.cast("SSLWriteFunc", function(connection, data, dataLength)
			local fd_ptr = ffi.cast("int*", connection)
			local fd = fd_ptr[0]
			local len = tonumber(dataLength[0])
			local result = ffi.C.write(fd, data, len)

			if result > 0 then
				dataLength[0] = result
				return errSecSuccess
			elseif result == 0 then
				dataLength[0] = 0
				return errSSLClosedAbort
			end

			local errno = get_errno()

			if errno == EAGAIN then
				dataLength[0] = 0
				return errSSLWouldBlock
			end

			dataLength[0] = 0
			return errSSLClosedAbort
		end)

	local function create_client()
		local ctx = lib.SSLCreateContext(nil, kSSLClientSide, kSSLStreamType)

		if ctx == nil then return nil, "Failed to create SSL context" end

		if lib.SSLSetIOFuncs(ctx, callbacks.read, callbacks.write) ~= 0 then
			cf.CFRelease(ctx)
			return nil, "Failed to set I/O functions"
		end

		local fd_ref = ffi.new("int[1]")
		local state = "connecting"

		local function connect(fd, host)
			fd_ref[0] = fd

			if state == "connecting" then
				local status = lib.SSLSetConnection(ctx, fd_ref)

				if status ~= 0 then
					return nil, string.format("SSLSetConnection: %s", status_to_msg(status))
				end

				if host then
					status = lib.SSLSetPeerDomainName(ctx, host, #host)

					if status ~= 0 then
						return nil, string.format("SSLSetPeerDomainName: %s", status_to_msg(status))
					end
				end

				state = "handshaking"
			end

			if state == "handshaking" then
				local status = lib.SSLHandshake(ctx)

				if status == errSSLWouldBlock then
					return nil, "tryagain", status
				elseif status ~= 0 then
					return nil, string.format("SSLHandshake: %s", status_to_msg(status))
				end

				state = "connected"
			end

			if state == "connected" then return true end

			return nil, "tryagain"
		end

		local function send(data_str)
			if state ~= "connected" then return nil, "context not connected" end

			local processed = ffi.new("size_t[1]")
			local data_len = #data_str
			local data_buf = ffi.new("uint8_t[?]", data_len)
			ffi.copy(data_buf, data_str, data_len)
			local status = lib.SSLWrite(ctx, data_buf, data_len, processed)

			if status == 0 then return tonumber(processed[0]) end

			if status == errSSLWouldBlock then return nil, "tryagain", status end

			return nil, string.format("SSLWrite: %s", status_to_msg(status))
		end

		local function receive(buffer_ptr, buffer_size)
			if state ~= "connected" then return nil, "context not connected" end

			local processed = ffi.new("size_t[1]")
			local status = lib.SSLRead(ctx, buffer_ptr, buffer_size, processed)

			if status == 0 then
				local len = tonumber(processed[0])

				if len == 0 then return "" end

				return ffi.string(buffer_ptr, len)
			end

			if status == errSSLWouldBlock then return nil, "tryagain", status end

			return nil, string.format("SSLRead: %s", status_to_msg(status))
		end

		local function close()
			if state == "closed" then return true end

			state = "closed"
			lib.SSLClose(ctx)
			cf.CFRelease(ctx)
		end

		return {
			connect = connect,
			send = send,
			receive = receive,
			close = close,
		}
	end

	return {
		create_client = create_client,
	}
end

local function get_candidate_loaders()
	if jit.os == "Windows" then
		return {
			load_windows_tls,
			load_libtls,
			load_openssl,
		}
	end

	if jit.os == "OSX" then
		return {
			load_openssl,
			load_libtls,
			load_security_framework_tls,
		}
	end

	return {
		load_libtls,
		load_openssl,
	}
end

function ssl.initialize()
	if initialized_backend then return initialized_backend end

	local errors = {}

	for _, loader in ipairs(get_candidate_loaders()) do
		local success, result = pcall(loader)

		if success then
			initialized_backend = result
			initialized_loader = loader
			ssl.loader = loader
			ssl.backend = result
			return result
		end

		table.insert(errors, result)
	end

	error(
		"No SSL/TLS implementation available for " .. tostring(jit.os) .. ": " .. table.concat(errors, "\n\n")
	)
end

function ssl.tls_client()
	local backend = ssl.initialize()
	return assert(backend.create_client())
end

function ssl.get_initialized_loader()
	return initialized_loader
end

return ssl
