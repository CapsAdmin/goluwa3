local prototype = require("prototype")
local Vec3 = require("structs.vec3")
local Matrix44 = require("structs.matrix44")
local Quat = require("structs.quat")
local Rect = require("structs.rect")
local META = prototype.CreateTemplate("camera3d")

do
	META:GetSet("OrthoMode", false, {callback = "InvalidateProjectionMatrix"})
	META:GetSet("FOV", math.rad(90), {callback = "InvalidateProjectionMatrix"})
	META:GetSet("NearZ", 0.1, {callback = "InvalidateProjectionMatrix"})
	META:GetSet("FarZ", 32000, {callback = "InvalidateProjectionMatrix"})
	META:GetSet("Viewport", Rect(0, 0, 1000, 1000), {callback = "InvalidateProjectionMatrix"})

	function META:InvalidateProjectionMatrix()
		self.ProjectionMatrix = nil
	end

	function META:BuildProjectionMatrix()
		if self.ProjectionMatrix then return self.ProjectionMatrix end

		self.ProjectionMatrix = Matrix44()
		self.ProjectionMatrix:Translate(self.Viewport.x, self.Viewport.y, 0)

		if self.OrthoMode then
			local mult = 100 * self.FOV
			local ratio = self.Viewport.h / self.Viewport.w
			self.ProjectionMatrix:Ortho(-mult, mult, mult * ratio, -mult * ratio, -32000 * 2, 32000)
		else
			self.ProjectionMatrix:Perspective(self.FOV, self.NearZ, self.FarZ, self.Viewport.w / self.Viewport.h)
		end

		return self.ProjectionMatrix
	end
end

do
	META:GetSet("Position", Vec3(0, 0, 0), {callback = "InvalidateViewMatrix"})
	META:GetSet("Rotation", Quat(0, 0, 0, 1), {callback = "InvalidateViewMatrix"})

	function META:InvalidateViewMatrix()
		self.ViewMatrix = nil
	end

	function META:BuildViewMatrix()
		if self.ViewMatrix then return self.ViewMatrix end

		self.ViewMatrix = Matrix44()
		local p = self.Position
		self.ViewMatrix:Translate(-p.x, -p.y, -p.z)
		self.ViewMatrix:Multiply(self.Rotation:GetConjugated():GetMatrix())
		return self.ViewMatrix
	end

	function META:GetAngles()
		return self.Rotation:GetAngles()
	end

	function META:SetAngles(ang)
		self.Rotation:SetAngles(ang)
		self:InvalidateViewMatrix()
	end
end

function META.New()
	return META:CreateObject()
end

META:Register()
return META
