local T = import("test/environment.lua")
local prototype = import("goluwa/prototype.lua")

T.Test("prototype property listeners", function()
	local META = prototype.CreateTemplate("test_property_listeners")
	META:GetSet("Val", 0)
	META:GetSet("Name", "hello")
	META:Register()
	local obj = prototype.CreateObject(META)
	local any_calls = {}
	local named_calls = {}
	local remove_any = obj:AddPropertyListener(function(_, key, value, old_value)
		any_calls[#any_calls + 1] = {key = key, value = value, old_value = old_value}
	end)
	local remove_named = obj:AddPropertyListenerFor("Val", function(_, key, value, old_value)
		named_calls[#named_calls + 1] = {key = key, value = value, old_value = old_value}
	end)
	obj:SetVal(4)
	T(#any_calls)["=="](1)
	T(any_calls[1].key)["=="]("Val")
	T(any_calls[1].old_value)["=="](0)
	T(any_calls[1].value)["=="](4)
	T(#named_calls)["=="](1)
	T(named_calls[1].key)["=="]("Val")
	obj:SetVal(4)
	T(#any_calls)["=="](1)
	T(#named_calls)["=="](1)
	obj:SetName("world")
	T(#any_calls)["=="](2)
	T(any_calls[2].key)["=="]("Name")
	T(any_calls[2].old_value)["=="]("hello")
	T(any_calls[2].value)["=="]("world")
	T(#named_calls)["=="](1)
	remove_any()
	obj:SetVal(9)
	T(#any_calls)["=="](2)
	T(#named_calls)["=="](2)
	T(named_calls[2].old_value)["=="](4)
	T(named_calls[2].value)["=="](9)
	remove_named()
	obj:SetVal(10)
	T(#any_calls)["=="](2)
	T(#named_calls)["=="](2)
end)

T.Test("prototype commit property from overridden setter", function()
	local META = prototype.CreateTemplate("test_commit_property")
	local callback_count = 0
	local listener_count = 0

	function META:OnChanged()
		callback_count = callback_count + 1
	end

	META:GetSet("Val", 0, {callback = "OnChanged"})

	function META:SetVal(val)
		self.override_calls = (self.override_calls or 0) + 1
		prototype.CommitProperty(self, "Val", val)
	end

	META:Register()
	local obj = prototype.CreateObject(META)
	local remove_listener = obj:AddPropertyListenerFor("Val", function()
		listener_count = listener_count + 1
	end)
	prototype.SetProperty(obj, "Val", 7)
	T(obj:GetVal())["=="](7)
	T(obj.override_calls)["=="](1)
	T(callback_count)["=="](1)
	T(listener_count)["=="](1)
	obj:SetVal(7)
	T(obj.override_calls)["=="](2)
	T(callback_count)["=="](1)
	T(listener_count)["=="](1)
	obj:SetVal(nil)
	T(obj:GetVal())["=="](0)
	T(obj.override_calls)["=="](3)
	T(callback_count)["=="](2)
	T(listener_count)["=="](2)
	remove_listener()
	obj:SetVal(12)
	T(obj:GetVal())["=="](12)
	T(listener_count)["=="](2)
end)
