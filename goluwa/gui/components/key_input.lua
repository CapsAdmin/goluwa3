return function(META)
	function META:OnPreKeyInput(key, press) end

	function META:OnKeyInput(key, press) end

	function META:OnPostKeyInput(key, press) end

	function META:OnCharInput(key, press) end

	function META:KeyInput(button, press)
		local b

		if self:OnPreKeyInput(button, press) ~= false then
			b = self:OnKeyInput(button, press)
			self:OnPostKeyInput(button, press)
		end

		return b
	end

	function META:CharInput(char)
		return self:OnCharInput(char)
	end
end
