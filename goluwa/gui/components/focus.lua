return function(META)
	function META:OnFocus() end

	function META:OnUnfocus() end

	function META:RequestFocus()
		if self.RedirectFocus:IsValid() then self = self.RedirectFocus end

		if gui.focus_panel:IsValid() and gui.focus_panel ~= self then
			gui.focus_panel:OnUnfocus()
		end

		self:OnFocus()
		gui.focus_panel = self
	end

	function META:Unfocus()
		if self.RedirectFocus:IsValid() then self = self.RedirectFocus end

		if gui.focus_panel:IsValid() and gui.focus_panel == self then
			self:OnUnfocus()
			gui.focus_panel = NULL
		end

		self.popup = nil

		if gui.popup_panel == self then gui.popup_panel = NULL end
	end

	function META:IsFocused()
		return gui.focus_panel == self
	end

	function META:MakePopup()
		self.popup = true
		gui.popup_panel = self
	end
end
