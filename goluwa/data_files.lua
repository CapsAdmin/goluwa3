local vfs = import("goluwa/vfs.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local data_files = {}

local function get_constructor(key)
	if type(key) ~= "string" then return end

	if key == "ShapeSize" then return Vec3 end

	if key == "EmissiveMultiplier" or key:find("Color") then return Color end
end

function data_files.IsColorKey(key)
	return get_constructor(key) == Color
end

function data_files.Realize(value)
	for key, child in pairs(value) do
		if type(child) == "table" then
			local constructor = get_constructor(key)

			if constructor and #child >= 3 then
				value[key] = constructor(unpack(child))
			else
				data_files.Realize(child)
			end
		end
	end

	return value
end

local META = {}
META.__index = META

function data_files.New(directory, key_priority)
	return setmetatable({Directory = directory, KeyPriority = key_priority, Source = {}}, META)
end

function META:GetPath(name)
	return self.Directory .. name .. ".lua"
end

function META:Read(name)
	return assert(loadfile(vfs.GetAbsolutePath(self:GetPath(name))))()
end

function META:Remember(name, data)
	self.Source[name] = table.copy(data)
end

function META:Save(name)
	local path = vfs.GetAbsolutePath(self:GetPath(name))
	local file = assert(io.open(path, "wb"))
	file:write(table.to_source(self.Source[name], self.KeyPriority))
	file:close()
	return path
end

return data_files
