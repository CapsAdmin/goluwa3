local ffi = require("ffi")
local string_buffer = require("string.buffer")
local callback = import("goluwa/callback.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local codec = import("goluwa/codec.lua")
local timer = import("goluwa/timer.lua")
local http = {}
import.loaded["goluwa/sockets/http.lua"] = http
http.MimeToExtension = {
	["audio/aac"] = "aac",
	["application/x-abiword"] = "abw",
	["application/x-freearc"] = "arc",
	["video/x-msvideo"] = "avi",
	["application/vnd.amazon.ebook"] = "azw",
	["application/octet-stream"] = "bin",
	["image/bmp"] = "bmp",
	["application/x-bzip"] = "bz",
	["application/x-bzip2"] = "bz2",
	["application/x-csh"] = "csh",
	["text/css"] = "css",
	["text/csv"] = "csv",
	["application/msword"] = "doc",
	["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx",
	["application/vnd.ms-fontobject"] = "eot",
	["application/epub+zip"] = "epub",
	["image/gif"] = "gif",
	["text/html"] = "html",
	["image/vnd.microsoft.icon"] = "ico",
	["text/calendar"] = "ics",
	["application/java-archive"] = "jar",
	["image/jpeg"] = "jpg",
	["text/javascript"] = "js",
	["application/json"] = "json",
	["audio/midi audio/x-midi"] = "mid",
	["application/javascript"] = "mjs",
	["audio/mpeg"] = "mp3",
	["video/mpeg"] = "mpeg",
	["application/vnd.apple.installer+xml"] = "mpkg",
	["application/vnd.oasis.opendocument.presentation"] = "odp",
	["application/vnd.oasis.opendocument.spreadsheet"] = "ods",
	["application/vnd.oasis.opendocument.text"] = "odt",
	["audio/ogg"] = "oga",
	["video/ogg"] = "ogv",
	["application/ogg"] = "ogx",
	["font/otf"] = "otf",
	["image/png"] = "png",
	["application/pdf"] = "pdf",
	["application/vnd.ms-powerpoint"] = "ppt",
	["application/vnd.openxmlformats-officedocument.presentationml.presentation"] = "pptx",
	["application/x-rar-compressed"] = "rar",
	["application/rtf"] = "rtf",
	["application/x-sh"] = "sh",
	["image/svg+xml"] = "svg",
	["application/x-shockwave-flash"] = "swf",
	["application/x-tar"] = "tar",
	["image/tiff"] = "tif",
	["font/ttf"] = "ttf",
	["text/plain"] = "txt",
	["application/vnd.visio"] = "vsd",
	["audio/wav"] = "wav",
	["audio/webm"] = "weba",
	["video/webm"] = "webm",
	["image/webp"] = "webp",
	["font/woff"] = "woff",
	["font/woff2"] = "woff2",
	["application/xhtml+xml"] = "xhtml",
	["application/vnd.ms-excel"] = "xls",
	["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] = "xlsx",
	["application/xml if not readable from casual users (RFC 3023, section 3)"] = "xml",
	["application/zip"] = "zip",
	["video/3gpp"] = "3gp",
	["video/3gpp2"] = "3g2",
	["application/x-7z-compressed"] = "7z",
	["application/vnd.microsoft.portable-executable"] = "exe",
}

function http.MixinHTTP(META)
	function META:InitializeHTTPParser()
		self.http = {
			raw_header = "",
			raw_body = string_buffer.new(),
			stage = "header",
		}
	end

	do
		-- chunked bodies are parsed as they come in: what is pending stays in a buffer and is read from its front, so a
		-- large body (or one large chunk) is not copied again for every piece received; returns whether the last chunk
		-- came, or nil and an error
		local function decode_chunks(state, data, out)
			-- what follows the last chunk is its trailer, which nothing reads
			if state.chunked_done then return true end

			local pending = state.chunk_pending

			if not pending then
				pending = string_buffer.new()
				state.chunk_pending = pending
			end

			pending:put(data)

			while true do
				local left = state.chunk_left

				if left then
					if left > 0 then
						local n = math.min(left, #pending)

						if n == 0 then return false end

						out[#out + 1] = pending:get(n)
						state.chunk_left = left - n

						if left > n then return false end
					end

					if #pending < 2 then return false end

					pending:skip(2)
					state.chunk_left = nil
				else
					local ptr, len = pending:ref()
					local line_end

					for i = 0, math.min(len, 256) - 2 do
						if ptr[i] == 13 and ptr[i + 1] == 10 then
							line_end = i

							break
						end
					end

					if not line_end then
						if len >= 256 then return nil, "chunk size line too long" end

						return false
					end

					local size = tonumber(ffi.string(ptr, line_end):match("^%x+") or "", 16)

					if not size then return nil, "bad chunk size" end

					pending:skip(line_end + 2)

					if size == 0 then return true end

					state.chunk_left = size
				end
			end
		end

		function META:WriteHTTP(chunk, is_response)
			local state = self.http

			if state.stage == "header" then
				if not is_response then
					if #state.raw_header > 4 and not state.raw_header:starts_with("HTTP") then
						return self:Error(
							"header does not start with HTTP (first 10 bytes: " .. state.raw_header:sub(10) .. ")"
						)
					end
				end

				state.raw_header = state.raw_header .. chunk
				local start, stop = state.raw_header:find("\r\n\r\n", 1, true)

				if start then
					local header = state.raw_header:sub(1, stop)
					chunk = state.raw_header:sub(stop + 1)
					state.raw_header = header

					do
						local keyvalues = {}

						for i, line in ipairs(header:split("\r\n")) do
							if i == 1 then
								local ok

								if is_response then
									state.method, state.path, state.version = line:match("^(%u+) (%S+) (HTTP/%d+%.%d+)$")

									if self:OnHTTPEvent("response") == false then
										self:InitializeHTTPParser()
										return
									end
								else
									state.version, state.code, state.status = line:match("^(HTTP/%d+%.%d+) (%d+) (.+)$")

									if self:OnHTTPEvent("status") == false then
										self:InitializeHTTPParser()
										return
									end
								end

								if state.version ~= "HTTP/1.1" and state.version ~= "HTTP/1.0" then
									return self:Error(tostring(state.version) .. " protocol not supported")
								end
							else
								local keyval = line:split(": ")
								local key, val = keyval[1], keyval[2]
								keyvalues[key:lower()] = val
							end
						end

						do
							local content_length = tonumber(keyvalues["content-length"])

							if content_length == 0 then content_length = nil end

							keyvalues["content-length"] = content_length
						end

						keyvalues["connection"] = keyvalues["connection"] and keyvalues["connection"]:lower() or nil
						keyvalues["content-encoding"] = keyvalues["content-encoding"] or "identity"
						state.header = keyvalues
					end

					if self:OnHTTPEvent("header") == false then
						self:InitializeHTTPParser()
						return
					end

					state.stage = "body"
				end
			end

			if state.stage == "body" then
				if state.header["transfer-encoding"] == "chunked" then
					local parts = {}
					local done, err = decode_chunks(state, chunk, parts)

					if done == nil then return self:Error(err) end

					if done then state.chunked_done = true end

					local decoded = table.concat(parts)
					self:WriteBody(decoded)
					state.current_body_chunk = decoded
				else
					self:WriteBody(chunk)
					state.current_body_chunk = chunk
				end

				if state.current_body_chunk and state.current_body_chunk ~= "" then
					if self:OnHTTPEvent("chunk") == false then return end
				end

				local body = nil

				if state.header["transfer-encoding"] == "chunked" then
					if state.chunked_done then body = self:GetWrittenBodyString() end
				elseif
					state.header["content-length"] and
					self:GetWrittenBodySize() >= state.header["content-length"]
				then
					body = self:GetWrittenBodyString()
				end

				if body then
					local encoding = state.header["content-encoding"]

					if encoding ~= "identity" then
						if encoding == "gzip" then
							local ok, str = pcall(codec.Decode, "gunzip", body)

							if ok == false then
								return self:Error("failed to parse " .. encoding .. " body: " .. str)
							end

							body = str
						else
							return self:Error("unknown content-encoding: " .. encoding)
						end
					end

					state.body = body
					self:OnHTTPEvent("body")
				end
			end

			return true
		end
	end

	function META:WriteBody(data)
		self.http.raw_body:put(data)
	end

	function META:GetWrittenBodySize()
		return #self.http.raw_body
	end

	function META:GetWrittenBodyString()
		return self.http.raw_body:tostring()
	end

	function META:OnHTTPEvent(what) end
end

local function default_header(header, key, val)
	if header[key] == nil then
		header[key] = val
	elseif header[key] == false then
		header[key] = nil
	end
end

local function build_http(tbl)
	local str = ""

	if tbl.method then str = str .. tbl.method .. " " end

	if tbl.path then str = str .. tbl.path .. " " end

	str = str .. tbl.protocol

	if tbl.code then str = str .. " " .. tbl.code end

	if tbl.status then str = str .. " " .. tbl.status end

	str = str .. "\r\n"

	if tbl.header then
		for k, v in pairs(tbl.header) do
			str = str .. k .. ": " .. tostring(v) .. "\r\n"
		end
	end

	str = str .. "\r\n"

	if tbl.body then str = str .. tbl.body end

	return str
end

function http.HTTPRequest(method, uri, header, body)
	header = header or {}
	default_header(header, "User-Agent", "goluwa/" .. jit.os)
	default_header(header, "Accept", "*/*")
	default_header(header, "Accept-Encoding", "identity")

	do
		local host = uri.host

		if uri.port then host = host .. ":" .. uri.port end

		default_header(header, "Host", host)
	end

	default_header(header, "Connection", "keep-alive")
	default_header(header, "DNT", "1")

	if body then
		default_header(header, "Content-Length", #body)
		default_header(header, "Content-Type", "application/octet-stream")
	end

	local str = build_http{
		protocol = "HTTP/1.1",
		method = method,
		path = uri.path,
		header = header,
		body = body,
	}
	return str
end

function http.HTTPResponse(code, status, header, body)
	header = header or {}

	if body then default_header(header, "Content-Length", #body) end

	local str = build_http{
		protocol = "HTTP/1.1",
		code = code,
		status = status,
		header = header,
		body = body,
	}
	return str
end

import("goluwa/sockets/http/request.lua")
import("goluwa/sockets/http/api.lua")
import("goluwa/sockets/http/uri.lua")
import("goluwa/sockets/http/download.lua")
return http
