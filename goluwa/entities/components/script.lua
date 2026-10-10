local objects = import("goluwa/objects/objects.lua")
local prefab = import("goluwa/entities/prefab.lua")
local META = objects.CreateTemplate("script")
META.Network = {
	Source = {"string", 0.5, "reliable"},
}
-- the prefix stays on the first line of the source so error line numbers match what the editor shows
local PREFIX = "local Entity = {} "
local SUFFIX = "\nreturn Entity"
local RESERVED = {OnCreate = true, OnRemove = true}
META:StartStorable()
META:GetSet(
	"Source",
	"",
	{
		callback = "Reload",
		code = "lua",
		status = function(script)
			return script.Error
		end,
	}
)
META:EndStorable()

-- a script that failed stays off until its source changes
local function call(script, fn, ...)
	if script.Error then return end

	prefab.Suppress()
	local ok, result = xpcall(fn, debug.traceback, script.Owner, ...)
	prefab.Unsuppress()

	if not ok then
		script.Error = result
		wlog("script of %s failed: %s", script.Owner, result)
		return
	end

	return result
end

function META:OnCreate()
	self.event_names = {}
end

function META:Initialize()
	self.initialized = true
	self:Reload()
end

function META:Unload()
	local module = self.module

	if module then
		if module.OnRemove then call(self, module.OnRemove) end

		for _, name in ipairs(self.event_names) do
			self[name] = nil
		end

		self.event_names = {}
		self:RemoveEvent("Update")
		self.module = nil
	end

	self.Error = nil
end

function META:Reload()
	if not self.initialized then return end

	self:Unload()

	if self.Source:find("^%s*$") then return end

	local name = self.Owner:GetName()
	local chunk, err = loadstring(PREFIX .. self.Source .. SUFFIX, "=script:" .. (name ~= "" and name or "entity"))

	if not chunk then
		self.Error = err
		wlog("script of %s does not compile: %s", self.Owner, err)
		return
	end

	local ok, module = xpcall(chunk, debug.traceback)

	if not ok then
		self.Error = module
		wlog("script of %s failed to load: %s", self.Owner, module)
		return
	end

	if type(module) ~= "table" then
		self.Error = "the Entity table must stay a table"
		wlog("script of %s: %s", self.Owner, self.Error)
		return
	end

	self.module = module

	-- every On* function is a local event of the owner, CallLocalEvent finds them on the component
	for key, fn in pairs(module) do
		if type(fn) == "function" and key:starts_with("On") and not RESERVED[key] and self[key] == nil then
			self.event_names[#self.event_names + 1] = key
			self[key] = function(_, a, b, c, d, e, f, g)
				return call(self, fn, a, b, c, d, e, f, g)
			end
		end
	end

	if module.Update then self:AddGlobalEvent("Update") end

	if module.OnCreate then
		prefab.WhenBuilt(function()
			if self.module == module then call(self, module.OnCreate) end
		end)
	end
end

function META:OnUpdate(dt)
	call(self, self.module.Update, dt)
end

function META:OnRemove()
	self:Unload()
end

return META:Register()
