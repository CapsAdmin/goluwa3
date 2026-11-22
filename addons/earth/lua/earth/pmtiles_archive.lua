local fs = import("goluwa/filesystem/fs.lua")
local pmtiles = import("goluwa/codecs/pmtiles.lua")
local TileSet = import("lua/earth/tile_set.lua")
-- a remote pmtiles archive read with range requests: its header and directories are kept on disk, every read is pinned to
-- the ETag of the first one, so an archive replaced under its url fails instead of mixing releases
local Archive = {}
Archive.__index = Archive
local MAX_LEAF_DEPTH = 4

-- config: url, directory (the disk cache), host_limit, on_changed (called when the archive was replaced)
function Archive.New(config)
	return setmetatable(
		{
			url = config.url,
			directory = config.directory,
			host_limit = config.host_limit or 6,
			on_changed = config.on_changed,
			leaves = {},
			waiters = {},
		},
		Archive
	)
end

function Archive:RangeRequest(offset, length, callback)
	local header = {Range = string.format("bytes=%d-%d", offset, offset + length - 1)}

	if self.etag then header["If-Match"] = self.etag end

	TileSet.HostRequest(
		self.url,
		header,
		self.host_limit,
		function(response)
			if response.code == 206 then
				callback(response.body, response.header)
			elseif response.code == 412 then
				if self.on_changed then self.on_changed(self) end

				callback(nil, "the archive changed")
			else
				callback(nil, "http " .. tostring(response.code))
			end
		end,
		function(reason)
			callback(nil, reason)
		end
	)
end

function Archive:Load(head, etag)
	self.header = pmtiles.ParseHeader(head)
	assert(
		self.header.root_offset + self.header.root_length <= #head,
		"pmtiles: root directory beyond the first read"
	)
	self.root = pmtiles.DecodeDirectory(
		head:sub(self.header.root_offset + 1, self.header.root_offset + self.header.root_length),
		self.header.internal_compression
	)
	self.etag = etag
end

-- callback(header) once the header is read, or callback(nil, reason)
function Archive:WithHeader(callback)
	if self.header then return callback(self.header) end

	if self.loading then
		self.waiters[#self.waiters + 1] = callback
		return
	end

	local head = fs.read_file(self.directory .. "head.bin")

	if head then
		self:Load(head, fs.read_file(self.directory .. "etag.txt"))
		return callback(self.header)
	end

	self.loading = true
	self.waiters = {callback}

	self:RangeRequest(0, pmtiles.ROOT_READ_SIZE, function(body, response_header)
		self.loading = false

		if body then
			local etag = response_header.etag
			self:Load(body, etag)
			fs.create_directory_recursive(self.directory)
			fs.write_file(self.directory .. "head.bin", body)

			if etag then fs.write_file(self.directory .. "etag.txt", etag) end
		end

		local waiters = self.waiters
		self.waiters = {}

		for _, waiter in ipairs(waiters) do
			waiter(self.header, response_header)
		end
	end)
end

function Archive:WithLeaf(offset, length, callback)
	local leaf = self.leaves[offset]

	if leaf and leaf.directory then return callback(leaf.directory) end

	if leaf then
		leaf.waiters[#leaf.waiters + 1] = callback
		return
	end

	local path = self.directory .. "leaf_" .. offset .. "_" .. length .. ".bin"
	local cached = fs.read_file(path)

	if cached then
		leaf = {directory = pmtiles.DecodeDirectory(cached, self.header.internal_compression)}
		self.leaves[offset] = leaf
		return callback(leaf.directory)
	end

	leaf = {waiters = {callback}}
	self.leaves[offset] = leaf

	self:RangeRequest(self.header.leaf_offset + offset, length, function(body, reason)
		local waiters = leaf.waiters
		leaf.waiters = nil

		if body then
			fs.write_file(path, body)
			leaf.directory = pmtiles.DecodeDirectory(body, self.header.internal_compression)
		else
			self.leaves[offset] = nil
		end

		for _, waiter in ipairs(waiters) do
			waiter(leaf.directory, reason)
		end
	end)
end

function Archive:FindTile(directory, id, depth, done)
	local i = pmtiles.FindEntry(directory, id)

	if not i then return done("missing") end

	if directory.runs[i] > 0 then
		self:RangeRequest(self.header.data_offset + directory.offsets[i], directory.lengths[i], function(body, reason)
			if body then done("ok", body) else done("error", reason) end
		end)

		return
	end

	if depth >= MAX_LEAF_DEPTH then
		return done("error", "pmtiles directories nest too deep")
	end

	self:WithLeaf(directory.offsets[i], directory.lengths[i], function(leaf, reason)
		if not leaf then return done("error", reason) end

		self:FindTile(leaf, id, depth + 1, done)
	end)
end

-- done("ok", the tile's bytes as stored, see header.tile_compression), done("missing") or done("error", reason)
function Archive:Fetch(z, x, y, done)
	self:WithHeader(function(header, reason)
		if not header then return done("error", reason) end

		self:FindTile(self.root, pmtiles.TileId(z, x, y), 0, done)
	end)
end

return Archive
