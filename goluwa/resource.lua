local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/fs.lua")
local crypto = import("goluwa/crypto.lua")
local callback = import("goluwa/callback.lua")
local codec = import("goluwa/codec.lua")
local http = import("goluwa/sockets/http.lua")
local event = import("goluwa/event.lua")
local resource = library()
resource.providers = resource.providers or {}
local DOWNLOAD_FOLDER = vfs.GetStorageDirectory("shared") .. "downloads/"
local R = vfs.GetAbsolutePath
local etags_file = DOWNLOAD_FOLDER .. "resource_etags.txt"
--os.execute("rm -rf " .. R(DOWNLOAD_FOLDER))
local ok, err = vfs.CreateDirectory("os:" .. DOWNLOAD_FOLDER)

if not ok then wlog(err) end

vfs.Mount("os:" .. DOWNLOAD_FOLDER, "os:downloads")

local function delete_download_cache(path)
	local abs_path = vfs.GetAbsolutePath(path, true) or vfs.GetAbsolutePath(path)

	if not abs_path then return true end

	if fs.is_file(abs_path) then return fs.remove_file(abs_path) end

	local function delete_recursive(dir)
		local files, err = fs.get_files(dir)

		if not files then return nil, err end

		for _, name in ipairs(files) do
			local found_path = dir .. "/" .. name
			local typ = fs.get_type(found_path)

			if typ == "file" then
				local ok, remove_err = fs.remove_file(found_path)

				if not ok then return nil, remove_err end
			elseif typ == "directory" then
				local ok, remove_err = delete_recursive(found_path)

				if not ok then return nil, remove_err end
			end
		end

		return fs.remove_directory(dir)
	end

	return delete_recursive(abs_path:gsub("/$", ""))
end

function resource.AddProvider(provider, no_autodownload)
	for i, v in ipairs(resource.providers) do
		if v == provider then
			list.remove(resource.providers, i)

			break
		end
	end

	list.insert(resource.providers, provider)

	if no_autodownload then return end

	http.Download(provider .. "auto_download.txt"):Then(function(str)
		for _, v in ipairs(codec.Decode("newline", str)) do
			resource.Download(v)
		end
	end)
end

local function download(
	from,
	to,
	callback,
	on_fail,
	on_header,
	check_etag,
	etag_path_override,
	need_extension,
	ext_override
)
	if check_etag then
		local etag = codec.LookupInFile("luadata", etags_file, etag_path_override or from)

		if VERBOSE then
			llog("checking if ", etag_path_override or from, " has been modified.")
		end

		return http.Request{
			method = "HEAD",
			url = from,
			error_callback = function(reason)
				llog(from, ": unable to fetch etag, socket error: ", reason)
				check_etag()
			end,
			code_callback = function(code)
				if code ~= 200 then
					llog(from, ": unable to fetch etag, server returned code ", code)
					check_etag()
					return false
				end
			end,
			header_callback = function(header)
				local res = header.etag or header["last-modified"]

				if not res then
					llog(from, ": no etag found")
					check_etag()
					return false
				end

				if res ~= etag then
					if etag then
						llog(from, ": etag has changed ", res)
					else
						llog(from, ": no previous etag stored", res)
					end

					download(
						from,
						to,
						callback,
						on_fail,
						on_header,
						nil,
						etag_path_override,
						need_extension,
						ext_override
					)
					return false
				else
					if VERBOSE then llog(from, ": etag is the same") end

					check_etag()
					return false
				end
			end,
		}
	end

	local file
	local base_to = to
	local current_to = to
	local current_temp_path
	local local_done = false
	local client

	local function fail(...)
		if local_done then return end

		local_done = true

		if file then
			file:Close()
			file = nil
		end

		on_fail(...)

		if client and client:IsValid() then client:Close() end
	end

	client = http.DownloadSocket(
		from,
		function()
			if local_done then return end

			local_done = true

			if file then
				file:Close()
				file = nil
			end

			local full_path = R("os:" .. DOWNLOAD_FOLDER .. current_to .. ".temp")

			if full_path then
				local ok, err = vfs.Rename(full_path, full_path:gsub(".+/(.+)%.temp$", "%1"))

				if not ok then
					fail(("unable to rename %q: %s\n"):format(full_path, err))
					return
				end

				local full_path = R("os:" .. DOWNLOAD_FOLDER .. current_to)

				if not full_path then
					fail(("open error: %q not found!\n"):format("data/downloads/" .. current_to))
					return
				end

				callback(full_path, true)
				return
			end

			fail(
				(
					"open error: %q not found!\n"
				):format("data/downloads/" .. DOWNLOAD_FOLDER .. to .. ".temp")
			)
		end,
		fail,
		function(chunk)
			if not file then
				fail(("unable to write chunk for %q: file not open\n"):format(from))
				return
			end

			local ok, err = file:Write(chunk)

			if ok == false then
				fail(("unable to write chunk for %q: %s\n"):format(from, err or "unknown error"))
			end
		end,
		function(header)
			local dir = base_to
			local next_to = base_to

			if ext_override then
				next_to = next_to .. "/file." .. ext_override
			elseif need_extension then
				local ext = from:match("%.([%a%d]+)$") or from:match("%.([%a%d]+)%?")

				if not ext then
					ext = header["content-type"] and
						(
							header["content-type"]:match(".-/(.-);") or
							header["content-type"]:match(".-/(.+)")
						)
						or
						"dat"
				end

				if ext == "dat" or ext == "octet-stream" then
					ext = from:match("%.([%a%d]+)$") or from:match("%.([%a%d]+)%?") or ext
				end

				if ext == "jpeg" then ext = "jpg" end

				next_to = next_to .. "/file." .. ext
			end

			local next_temp_path = "os:" .. DOWNLOAD_FOLDER .. next_to .. ".temp"

			if current_temp_path and current_temp_path ~= next_temp_path then
				if file then
					file:Close()
					file = nil
				end

				if vfs.Exists(current_temp_path) then vfs.Delete(current_temp_path) end
			end

			current_to = next_to
			current_temp_path = next_temp_path

			if file then
				file:Close()
				file = nil
			end

			local ok, err = vfs.CreateDirectoriesFromPath("os:" .. DOWNLOAD_FOLDER .. current_to)

			if not ok then
				fail(
					llog(
						"unable to create directories %q download error: %s",
						"os:" .. DOWNLOAD_FOLDER .. current_to,
						err
					)
				)
				return
			end

			if resource.debug then
				codec.WriteFile(
					"luadata",
					"os:" .. DOWNLOAD_FOLDER .. dir .. "info.txt",
					{header = header, url = from}
				)
			end

			local file_, err = vfs.Open(current_temp_path, "write")
			file = file_

			if not file then
				fail(("unable to open file for writing %q: %s\n"):format(current_temp_path, err))
				return
			end

			local etag = header.etag or header["last-modified"]

			if etag then
				codec.StoreInFile("luadata", etags_file, etag_path_override or from, etag)
			end

			local ok, res, extra = pcall(on_header, header)

			if not ok then
				fail(res)
				return
			end

			if res == false and type(extra) == "string" then fail(extra) end
		end
	)
	return {socket = client}
end

local function download_from_providers(path, callback, on_fail, check_etag)
	if event.Call("ResourceDownload", path, callback, on_fail) ~= nil then
		on_fail("ResourceDownload hook returned not nil\n")
		return
	end

	if #resource.providers == 0 then
		on_fail("no providers added\n")
		return
	end

	-- if not check_etag then
	-- 	llog("downloading ", path)
	-- end
	local failed = 0
	local max = #resource.providers

	-- this does not work very well if a resource provider is added during download
	for _, provider in ipairs(resource.providers) do
		local client
		client = download(
			provider .. path,
			path,
			callback,
			function(...)
				failed = failed + 1

				if failed == max then on_fail(...) end
			end,
			function(header)
				for _, other_provider in ipairs(resource.providers) do
					if provider ~= other_provider then
						http.StopDownload(other_provider .. path)
						event.Call("DownloadStop", client.socket, path, nil, "download found in " .. provider)
					end
				end
			end,
			check_etag,
			path
		)

		-- TODO
		if not gmod and client.socket then client.socket.url = provider .. path end
	end
end

local ohno = false
resource.Download = callback.WrapKeyedTask(
	function(self, path, crc, mixed_case, check_etag, ext)
		local resolve = function(...)
			self.callbacks.resolve(...)
		end
		local reject = self.callbacks.reject

		if resource.virtual_files[path] then
			return resource.virtual_files[path](resolve, reject)
		end

		local url
		local existing_path

		if path:find("^.-://") then
			url = path
			local crc = crc or crypto.CRC32(path)
			local found = vfs.Find("os:" .. DOWNLOAD_FOLDER .. "url/" .. crc .. "/file", true)

			if found[1] and found[1]:ends_with(".temp") then
				llog("deleting unfinished download: ", path)
				delete_download_cache("os:" .. DOWNLOAD_FOLDER .. "url/" .. crc .. "/")
				found = {}
			end

			if found[1] and vfs.IsDirectory(found[1]) then
				llog("deleting bad cache data:", path)
				delete_download_cache("os:" .. DOWNLOAD_FOLDER .. "url/" .. crc .. "/")
				found = {}
			end

			path = "url/" .. crc

			if found[1] then
				existing_path = found[1]
			else
				existing_path = false
			end
		else
			existing_path = R(path) or R(path:lower())

			if mixed_case and not existing_path then
				existing_path = vfs.FindMixedCasePath(path)
			end
		end

		if not existing_path then check_etag = nil end

		if not ohno then
			local old = resolve
			resolve = function(path, changed)
				if event.Call("ResourceDownloaded", path, url) ~= false then
					old(path, changed)
				end
			end
		end

		if existing_path and not check_etag then
			ohno = true
			resolve(existing_path)
			ohno = false
			return true
		end

		if check_etag then check_etag = function()
			resolve(existing_path)
		end end

		if url then
			-- if not check_etag then
			-- 	llog("downloading ", url)
			-- end
			download(
				url,
				path,
				resolve,
				function(...)
					reject(... or path .. " not found")
				end,
				function(header)
					-- check file crc stuff here/
					return true
				end,
				check_etag,
				nil,
				true,
				ext
			)
		elseif not resource.skip_providers then
			download_from_providers(
				path,
				resolve,
				function(...)
					reject(... or path .. " not found")
				end,
				check_etag
			)
		end

		return true
	end,
	nil,
	nil,
	true
)

function resource.ClearDownloads()
	delete_download_cache("os:" .. DOWNLOAD_FOLDER)
end

function resource.CheckDownloadedFiles()
	local files = codec.ReadFile("luadata", etags_file)
	local count = table.count(files)
	llog("checking " .. count .. " files for updates..")
	local i = 0

	for path, etag in pairs(files) do
		resource.Download(path, nil, nil, true):Then(function()
			i = i + 1

			if i == count then llog("done checking for file updates") end
		end)
	end
end

resource.virtual_files = {}

function resource.CreateVirtualFile(where, callback)
	resource.virtual_files[where] = function(on_success, on_error)
		callback(
			function(path)
				vfs.CreateDirectory("os:" .. DOWNLOAD_FOLDER .. where)
				local ok, err = vfs.Write("os:" .. DOWNLOAD_FOLDER .. where, vfs.Read(path))

				if not ok then on_error(err) else on_success(where) end
			end,
			on_error
		)
	end
end

function resource.ValidateCache()
	for _, path in ipairs(vfs.Find("os:" .. DOWNLOAD_FOLDER .. "url/", true)) do
		if vfs.IsFile(path) then
			local crc, ext = path:match(".+/(%d+)(.+)")

			if crc then
				local data = vfs.Read(path)
				local new_path = "os:" .. DOWNLOAD_FOLDER .. "url/" .. crc .. "/file" .. ext

				if vfs.CreateDirectoriesFromPath(new_path) then
					llog("moving %s -> %s", path, new_path)
					vfs.Delete(path)
					vfs.Write(new_path, data)
				end
			else
				llog("bad file in downloads/url folder: %s", path)
				vfs.Delete(path)
			end
		end
	end
end

return resource