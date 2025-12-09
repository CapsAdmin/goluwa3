local prototype = require("prototype")
local Matrix44 = require("structs.matrix").Matrix44
local Matrix33 = require("structs.matrix").Matrix33
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Rect = require("structs.rect")
local camera = {}

do
	local META = prototype.CreateTemplate("camera")

	function camera.CreateCamera()
		local self = prototype.CreateObject("camera")
		self.matrix_stack = {}
		self.shader_variables = {
			projection = Matrix44(),
			view = Matrix44(),
			world = Matrix44(),
			projection_inverse = Matrix44(),
			view_inverse = Matrix44(),
			world_inverse = Matrix44(),
			projection_view = Matrix44(),
			view_world = Matrix44(),
			projection_view_world = Matrix44(),
			projection_view_inverse = Matrix44(),
			view_world_inverse = Matrix44(),
			normal_matrix = Matrix33(), -- Use Matrix33 to avoid re-allocation in Rebuild
		}
		self:Rebuild()
		return self
	end

	META:StartStorable()
	META:GetSet("Position", Vec3(0, 0, 0), {callback = "InvalidateView"})
	META:GetSet("Angles", Ang3(0, 0, 0), {callback = "InvalidateView"})
	META:GetSet("FOV", math.pi / 2, {callback = "InvalidateProjection"})
	META:GetSet("Zoom", 1, {callback = "InvalidateView"})
	META:GetSet("NearZ", 0.1, {callback = "InvalidateProjection"})
	META:GetSet("FarZ", 32000, {callback = "InvalidateProjection"})
	META:GetSet("Viewport", Rect(0, 0, 1000, 1000), {callback = "InvalidateProjection"})
	META:GetSet("3D", true, {callback = "Invalidate"})
	META:GetSet("Ortho", false, {callback = "InvalidateProjection"})
	META:EndStorable()
	META:GetSet("Projection", nil, {callback = "InvalidateProjection"})
	META:GetSet("View", nil, {callback = "InvalidateView"})
	META:GetSet("World", Matrix44(), {callback = "InvalidateWorld"})

	do
		META.matrix_stack_i = 1

		function META:PushWorldEx(pos, ang, scale, dont_multiply)
			self.matrix_stack[self.matrix_stack_i] = self.World

			if dont_multiply then
				self.World = Matrix44()
			else
				self.World = self.matrix_stack[self.matrix_stack_i]:Copy()
			end

			-- source engine style world orientation
			if pos then
				self:TranslateWorld(-pos.y, -pos.x, -pos.z) -- Vec3(left/right, back/forth, down/up)
			end

			if ang then
				self:RotateWorld(-ang.y, 0, 0, 1)
				self:RotateWorld(-ang.z, 0, 1, 0)
				self:RotateWorld(-ang.x, 1, 0, 0)
			end

			if scale then self:ScaleWorld(scale.x, scale.y, scale.z) end

			self.matrix_stack_i = self.matrix_stack_i + 1
			self:InvalidateWorld()
			return self.World
		end

		function META:PushWorld(mat, dont_multiply)
			self.matrix_stack[self.matrix_stack_i] = self.World

			if dont_multiply then
				if mat then self.World = mat else self.World = Matrix44() end
			else
				if mat then
					self.World = self.matrix_stack[self.matrix_stack_i] * mat
				else
					self.World = self.matrix_stack[self.matrix_stack_i]:Copy()
				end
			end

			self.matrix_stack_i = self.matrix_stack_i + 1
			self:InvalidateWorld()
			return self.World
		end

		function META:PopWorld()
			self.matrix_stack_i = self.matrix_stack_i - 1
			--if self.matrix_stack_i < 1 then
			--	error("stack underflow", 2)
			--end
			self.World = self.matrix_stack[self.matrix_stack_i]
			self:InvalidateWorld()
		end

		-- world matrix helper functions
		function META:TranslateWorld(x, y, z)
			self.World:Translate(x, y, z)
			self:InvalidateWorld()
		end

		function META:RotateWorld(a, x, y, z)
			self.World:Rotate(a, x, y, z)
			self:InvalidateWorld()
		end

		function META:ScaleWorld(x, y, z)
			self.World:Scale(x, y, z)
			self:InvalidateWorld()
		end

		function META:ShearWorld(x, y, z)
			self.World:SetShear(x, y, z)
			self:InvalidateWorld()
		end

		function META:LoadIdentityWorld()
			self.World:LoadIdentity()
			self:InvalidateWorld()
		end
	end

	do -- 3d 2d
		function META:Start3D2DEx(pos, ang, scale)
			pos = pos or Vec3(0, 0, 0)
			ang = ang or Ang3(0, 0, 0)
			scale = scale or
				Vec3(
					4 * (self.Viewport.w / self.Viewport.h),
					4 * (self.Viewport.w / self.Viewport.h),
					1
				)
			self:Set3D(true)
			self.oldpos, self.oldang, self.oldfov = self:GetPosition(), self:GetAngles(), self:GetFOV()
			self:SetPosition(render3d.camera:GetPosition())
			self:SetAngles(render3d.camera:GetAngles())
			self:SetFOV(render3d.camera:GetFOV())
			self:PushWorldEx(pos, ang, Vec3(scale.x / self.Viewport.w, scale.y / self.Viewport.h, 1))
			self:Rebuild()
		end

		function META:Start3D2D(mat, dont_multiply)
			--self:Set3D(true)
			self:Rebuild()
			self:PushWorld(mat, dont_multiply)
		end

		function META:End3D2D()
			self:PopWorld()
			self:Set3D(false)
			self:SetPosition(self.oldpos)
			self:SetAngles(self.oldang)
			self:SetFOV(self.oldfov)
			self:Rebuild()
		end

		function META:ScreenToWorld(x, y)
			local m = (self:GetWorldMatrix() * self:GetViewMatrix()):GetInverse()

			if self:Get3D() then
				x = ((x / self.Viewport.w) - 0.5) * 2
				y = ((y / self.Viewport.h) - 0.5) * 2
				local cursor_x, cursor_y, cursor_z = m:TransformVector(self:GetProjectionMatrix():GetInverse():TransformVector(x, -y, 1))
				local camera_x, camera_y, camera_z = m:TransformVector(0, 0, 0)
				--local intersect = camera + ( camera.z / ( camera.z - cursor.z ) ) * ( cursor - camera )
				local z = camera_z / (camera_z - cursor_z)
				local intersect_x = camera_x + z * (cursor_x - camera_x)
				local intersect_y = camera_y + z * (cursor_y - camera_y)
				return intersect_x, intersect_y
			else
				local x, y = m:TransformVector(x, y, 1)
				return x, y
			end
		end
	end

	do
		local function normallize_plane(plane)
			local mag = math.sqrt(plane.x * plane.x + plane.y * plane.y + plane.z * plane.z)
			plane.x = plane.x / mag
			plane.y = plane.y / mag
			plane.z = plane.z / mag
			plane.w = plane.w / mag
		end

		function META:GetFrustum(normalize, mat)
			mat = mat or self:GetProjectionViewMatrix()
			local frustum = {}
			frustum.left = {
				x = mat.m03 + mat.m00,
				y = mat.m13 + mat.m10,
				z = mat.m23 + mat.m20,
				w = mat.m33 + mat.m30,
			}
			frustum.right = {
				x = mat.m03 - mat.m00,
				y = mat.m13 - mat.m10,
				z = mat.m23 - mat.m20,
				w = mat.m33 - mat.m30,
			}
			frustum.top = {
				x = mat.m03 - mat.m01,
				y = mat.m13 - mat.m11,
				z = mat.m23 - mat.m21,
				w = mat.m33 - mat.m31,
			}
			frustum.bottom = {
				x = mat.m03 + mat.m01,
				y = mat.m13 + mat.m11,
				z = mat.m23 + mat.m21,
				w = mat.m33 + mat.m31,
			}
			frustum.near = {
				x = mat.m02,
				y = mat.m12,
				z = mat.m22,
				w = mat.m32,
			}
			frustum.far = {
				x = mat.m03 - mat.m02,
				y = mat.m13 - mat.m12,
				z = mat.m23 - mat.m22,
				w = mat.m33 - mat.m32,
			}

			if normalize then
				normallize_plane(frustum.left)
				normallize_plane(frustum.right)
				normallize_plane(frustum.top)
				normallize_plane(frustum.bottom)
				normallize_plane(frustum.near)
				normallize_plane(frustum.far)
			end

			frustum.tbli = {
				frustum.near,
				frustum.left,
				frustum.right,
				frustum.bottom,
				frustum.top,
				frustum.far,
			}
			return frustum
		end

		function META:IsAABBVisible(aabb, cam_distance, bounding_sphere)
			if cam_distance > bounding_sphere ^ 6 then return false end

			local frustum = self:GetCachedFrustum()

			for i = 1, 6 do
				local plane = frustum.tbli[i]

				if
					(
						plane.x * (
							plane.x > 0 and
							aabb.max_x or
							aabb.min_x
						)
					) + (
						plane.y * (
							plane.y > 0 and
							aabb.max_y or
							aabb.min_y
						)
					) + (
						plane.z * (
							plane.z > 0 and
							aabb.max_z or
							aabb.min_z
						)
					) < -plane.w
				then
					return false
				end
			end

			return true
		end
	end

	function META:Rebuild(what)
		local vars = self.shader_variables

		if what == nil or what == "projection" then
			if self.Projection then
				vars.projection = self.Projection
			else
				local proj = vars.projection
				proj:Identity()

				if self.Ortho then
					local mult = 100 * self.FOV
					local ratio = self.Viewport.h / self.Viewport.w
					proj:Ortho(-mult, mult, ratio * -mult, ratio * mult, 0, self.FarZ)
				else
					if self:Get3D() then
						proj:SetTranslation(self.Viewport.x, self.Viewport.y, 0)
						proj:Perspective(self.FOV, self.NearZ, self.FarZ, self.Viewport.w / self.Viewport.h)
					else
						proj:Ortho(self.Viewport.x, self.Viewport.w, self.Viewport.y, self.Viewport.h, -1, 1)
					end
				end

				vars.projection = proj
			end
		end

		if what == nil or what == "view" then
			if self.View then
				vars.view = self.View
			else
				local view = vars.view
				view:Identity()

				if self:Get3D() then
					view:Rotate(self.Angles.z, 0, 0, 1)
					view:Rotate(self.Angles.x + math.pi / 2, 1, 0, 0)
					view:Rotate(self.Angles.y, 0, 0, 1)
					view:Translate(self.Position.y, self.Position.x, self.Position.z)
				else
					local x, y
					x, y = self.Viewport.w / 2, self.Viewport.h / 2
					view:Translate(x, y, 0)
					view:Rotate(self.Angles.y, 0, 0, 1)
					view:Translate(-x, -y, 0)
					view:Translate(self.Position.x, self.Position.y, 0)
					x, y = self.Viewport.w / 2, self.Viewport.h / 2
					view:Translate(x, y, 0)
					view:Scale(self.Zoom, self.Zoom, 1)
					view:Translate(-x, -y, 0)
				end

				vars.view = view
			end
		end

		if what == nil or what == "projection" or what == "view" then
			if vars.projection_inverse then
				vars.projection:GetInverse(vars.projection_inverse)
			end

			if vars.view_inverse then vars.view:GetInverse(vars.view_inverse) end

			if vars.projection_view then
				vars.projection:GetMultiplied(vars.view, vars.projection_view)
			end

			if vars.projection_view_inverse then
				vars.projection_view:GetInverse(vars.projection_view_inverse)
			end

			vars.frustum = self:GetFrustum(true, vars.projection_view)
		end

		if what == nil or what == "view" or what == "world" then
			vars.world = self.World

			if vars.view_world then vars.view:GetMultiplied(vars.world, vars.view_world) end

			if vars.view_world_inverse and vars.view_world then
				vars.view_world:GetInverse(vars.view_world_inverse)
			end

			if vars.normal_matrix and vars.view_world_inverse then
				-- Copy and transpose in one step (transposed: swap row/col)
				-- normal_matrix[row][col] = view_world_inverse[col][row]
				local vwi = vars.view_world_inverse
				local nm = vars.normal_matrix
				nm.m00 = vwi.m00
				nm.m01 = vwi.m10 -- transposed
				nm.m02 = vwi.m20 -- transposed
				nm.m10 = vwi.m01 -- transposed
				nm.m11 = vwi.m11
				nm.m12 = vwi.m21 -- transposed
				nm.m20 = vwi.m02 -- transposed
				nm.m21 = vwi.m12 -- transposed
				nm.m22 = vwi.m22
			end
		end

		if vars.world_inverse then
			if type == nil or type == "world" then
				vars.world:GetInverse(vars.world_inverse)
			end
		end

		if vars.projection_view_world then
			vars.projection:GetMultiplied(vars.view_world, vars.projection_view_world)
		end
	end

	function META:InvalidateProjection()
		if self.rebuild_matrix then
			self.rebuild_matrix = true
			return
		end

		self.rebuild_matrix = "projection"
	end

	function META:InvalidateView()
		if
			self.rebuild_matrix and
			self.rebuild_matrix ~= "view" and
			self.rebuild_matrix ~= "projection"
		then
			return
		end

		self.rebuild_matrix = "view"
	end

	function META:InvalidateWorld()
		if self.rebuild_matrix and self.rebuild_matrix ~= "world" then return end

		self.rebuild_matrix = "world"
	end

	function META:Invalidate()
		self.rebuild_matrix = true
	end

	function META:GetMatrices()
		if self.rebuild_matrix then
			if self.rebuild_matrix == true then
				self:Rebuild()
			else
				self:Rebuild(self.rebuild_matrix)
			end

			self.rebuild_matrix = false
		end

		return self.shader_variables
	end

	-- Optimized getters that only rebuild what's needed
	function META:GetProjectionMatrix()
		if self.rebuild_matrix == "projection" or self.rebuild_matrix == true then
			self:Rebuild("projection")

			if self.rebuild_matrix == "projection" then
				self.rebuild_matrix = false
			end
		end

		return self.shader_variables.projection
	end

	function META:GetViewMatrix()
		if self.rebuild_matrix == "view" or self.rebuild_matrix == true then
			self:Rebuild("view")

			if self.rebuild_matrix == "view" then self.rebuild_matrix = false end
		end

		return self.shader_variables.view
	end

	function META:GetWorldMatrix()
		if self.rebuild_matrix == "world" or self.rebuild_matrix == true then
			self:Rebuild("world")

			if self.rebuild_matrix == "world" then self.rebuild_matrix = false end
		end

		return self.shader_variables.world
	end

	function META:GetProjectionViewMatrix()
		if self.rebuild_matrix and self.rebuild_matrix ~= "world" then
			self:Rebuild(self.rebuild_matrix == true and nil or self.rebuild_matrix)

			if self.rebuild_matrix ~= true then self.rebuild_matrix = false end
		end

		return self.shader_variables.projection_view
	end

	function META:GetViewWorldMatrix()
		if self.rebuild_matrix then
			if self.rebuild_matrix == true then
				self:Rebuild()
			elseif self.rebuild_matrix ~= "projection" then
				self:Rebuild(self.rebuild_matrix)
			end

			if self.rebuild_matrix ~= true and self.rebuild_matrix ~= "projection" then
				self.rebuild_matrix = false
			end
		end

		return self.shader_variables.view_world
	end

	function META:GetProjectionViewWorldMatrix()
		if self.rebuild_matrix then
			if self.rebuild_matrix == true then
				self:Rebuild()
			else
				self:Rebuild(self.rebuild_matrix)
			end

			self.rebuild_matrix = false
		end

		return self.shader_variables.projection_view_world
	end

	function META:GetNormalMatrix()
		if self.rebuild_matrix then
			if self.rebuild_matrix == true then
				self:Rebuild()
			elseif self.rebuild_matrix ~= "projection" then
				self:Rebuild(self.rebuild_matrix)
			end

			if self.rebuild_matrix ~= true and self.rebuild_matrix ~= "projection" then
				self.rebuild_matrix = false
			end
		end

		return self.shader_variables.normal_matrix
	end

	function META:GetCachedFrustum()
		if self.rebuild_matrix and self.rebuild_matrix ~= "world" then
			self:Rebuild(self.rebuild_matrix == true and nil or self.rebuild_matrix)

			if self.rebuild_matrix ~= true then self.rebuild_matrix = false end
		end

		return self.shader_variables.frustum
	end

	META:Register()
end

return camera
