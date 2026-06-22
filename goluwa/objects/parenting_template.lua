return function(META)
	META:GetSet("Parent", NULL)
	META:GetSet("Children", {})
	META:GetSet("ChildrenMap", {})

	do -- child order
		META:GetSet("ChildOrder", 0)

		local function child_order_sort(a, b)
			local order_a = a.ChildOrder or 0
			local order_b = b.ChildOrder or 0

			if order_a == order_b then
				return (a._child_insert_order or 0) < (b._child_insert_order or 0)
			end

			return order_a < order_b
		end

		local function refresh_child_insert_order(parent)
			local children = parent.Children

			for i = 1, #children do
				children[i]._child_insert_order = i
			end

			parent._child_insert_serial = #children
		end

		local function move_child(parent, obj, index)
			local children = parent.Children
			local current_index

			for i = 1, #children do
				if children[i] == obj then
					current_index = i

					break
				end
			end

			if not current_index then return false end

			if current_index == index then return true end

			table.remove(children, current_index)

			if index > #children + 1 then index = #children + 1 end

			if index < 1 then index = 1 end

			table.insert(children, index, obj)
			refresh_child_insert_order(parent)
			parent:InvalidateChildrenList()
			return true
		end

		function META:BringToFront()
			local parent = self:GetParent()

			if parent:IsValid() then move_child(parent, self, #parent.Children) end
		end

		META.BringToTop = META.BringToFront

		function META:SendToBack()
			local parent = self:GetParent()

			if parent:IsValid() then move_child(parent, self, 1) end
		end

		META.SendToBottom = META.SendToBack

		function META:SetChildOrder(pos)
			self.ChildOrder = pos

			if self:HasParent() then
				list.sort(self.Parent.Children, child_order_sort)
				self.Parent:InvalidateChildrenList()
			end
		end
	end

	do -- children
		local function clear_children_traversal_cache(obj)
			obj.children_list = nil
			obj.children_traversal_cache = nil
		end

		function META:GetChildren()
			return self.Children
		end

		local function add_recursive(obj, tbl, index)
			local source = obj.Children

			for i = 1, #source do
				tbl[index] = source[i]
				index = index + 1
				index = add_recursive(source[i], tbl, index)
			end

			return index
		end

		local function build_children_list(self)
			local tbl = {}
			add_recursive(self, tbl, 1)
			return tbl
		end

		function META:GetCachedChildrenTraversal(cache_key, builder)
			local cache = self.children_traversal_cache

			if not cache then
				cache = {}
				self.children_traversal_cache = cache
			end

			local traversal = cache[cache_key]

			if traversal == nil then
				traversal = builder(self)
				cache[cache_key] = traversal
			end

			return traversal
		end

		function META:GetChildrenList()
			if not self.children_list then
				self.children_list = self:GetCachedChildrenTraversal("children_list", build_children_list)
			end

			return self.children_list
		end

		function META:InvalidateChildrenList()
			clear_children_traversal_cache(self)

			for _, parent in ipairs(self:GetParentList()) do
				clear_children_traversal_cache(parent)
			end
		end
	end

	do -- parent
		function META:SetParent(obj)
			if obj and not obj.IsValid then
				table.print(obj)
				debug.trace()
			end

			if not obj or not obj:IsValid() then
				self:UnParent()
				return false
			else
				return obj:AddChild(self)
			end
		end

		function META:ContainsParent(obj)
			for _, v in ipairs(self:GetParentList()) do
				if v == obj then return true end
			end
		end

		local function quick_copy(input)
			local output = {}

			for i = 1, #input do
				output[i + 1] = input[i]
			end

			return output
		end

		local function invalidate_parent_list_recursive(obj)
			obj.parent_list = nil

			for _, child in ipairs(obj:GetChildren()) do
				invalidate_parent_list_recursive(child)
			end
		end

		function META:GetParentList()
			if not self.parent_list then
				if self.Parent and self.Parent:IsValid() then
					self.parent_list = quick_copy(self.Parent:GetParentList())
					self.parent_list[1] = self.Parent
				else
					self.parent_list = {}
				end
			end

			return self.parent_list
		end

		function META:InvalidateParentList()
			invalidate_parent_list_recursive(self)
		end

		function META:InvalidateParentListPartial(parent_list, parent)
			self.parent_list = quick_copy(parent_list)
			self.parent_list[1] = parent

			for _, child in ipairs(self:GetChildren()) do
				child:InvalidateParentListPartial(self.parent_list, self)
			end
		end
	end

	function META:AddChild(obj, pos)
		if self.PreChildAdd and self:PreChildAdd(obj, pos) == false then return false end

		if not obj.HasParent then for k, v in pairs(obj) do
			print(k, v)
		end end

		if not obj or not obj:IsValid() then
			self:UnParent()
			return
		end

		if self == obj or self:ContainsParent(obj) then return false end

		if obj:HasParent() then obj:UnParent() end

		obj.Parent = self

		if not self:HasChild(obj) then
			self.ChildrenMap[obj] = obj
			self._child_insert_serial = (self._child_insert_serial or 0) + 1
			obj._child_insert_order = self._child_insert_serial

			if pos then
				list.insert(self.Children, pos, obj)
			else
				list.insert(self.Children, obj)
			end
		end

		self:InvalidateChildrenList()
		obj:CallLocalEvent("OnParent", self)

		if not obj.suppress_child_add then
			obj.suppress_child_add = true
			self:CallLocalEvent("OnChildAdd", obj)
			obj.suppress_child_add = nil
		end

		if self:HasParent() then self:GetParent():SortChildren() end

		-- why would we need to sort obj's children
		-- if it is completely unmodified?
		obj:SortChildren()
		self:SortChildren()
		obj:InvalidateParentListPartial(self:GetParentList(), self)
		return true
	end

	do
		local function sort(a, b)
			local order_a = a.ChildOrder or 0
			local order_b = b.ChildOrder or 0

			if order_a == order_b then
				return (a._child_insert_order or 0) < (b._child_insert_order or 0)
			end

			return order_a < order_b
		end

		function META:SortChildren() -- todo
		-- Preserve insertion order by default; explicit SetChildOrder already sorts when needed.
		end
	end

	function META:HasParent()
		return self.Parent:IsValid()
	end

	function META:HasChildren()
		return self.Children[1] ~= nil
	end

	function META:HasChild(obj)
		return self.ChildrenMap[obj] ~= nil
	end

	function META:GetRoot()
		local list = self:GetParentList()

		if list[1] then return list[#list] end

		return self
	end

	function META:RemoveChildren()
		if self.PreRemoveChildren and self:PreRemoveChildren() == false then return end

		if self.__skip_remove_children then
			self.__skip_remove_children = nil
			return
		end

		if not self.Children[1] then
			self.Children = {}
			self.ChildrenMap = {}
			return
		end

		self:InvalidateChildrenList()
		local children = self:GetChildren()
		local remove_list = {}
		self.bulk_removing_children = true

		for i = #children, 1, -1 do
			local root = children[i]
			local stack = {root}

			while #stack > 0 do
				local obj = stack[#stack]

				if obj.__bulk_remove_mark then
					stack[#stack] = nil
					remove_list[#remove_list + 1] = obj
				else
					obj.__bulk_remove_mark = true
					obj.__skip_remove_children = true
					local obj_children = obj:GetChildren()

					for j = #obj_children, 1, -1 do
						stack[#stack + 1] = obj_children[j]
					end
				end
			end
		end

		for i = 1, #remove_list do
			local obj = remove_list[i]
			obj.__bulk_remove_mark = nil
			obj:Remove()
		end

		self.bulk_removing_children = nil
		self.Children = {}
		self.ChildrenMap = {}
	end

	function META:UnParent()
		local parent = self:GetParent()

		if parent:IsValid() then parent:RemoveChild(self) end
	end

	function META:RemoveChild(obj)
		if self.ChildrenMap[obj] == nil then return end

		self.ChildrenMap[obj] = nil

		if self.bulk_removing_children and self.Children[#self.Children] == obj then
			self.Children[#self.Children] = nil
			obj.Parent = NULL
			obj:InvalidateParentList()
			obj:CallLocalEvent("OnUnParent", self)
			self:CallLocalEvent("OnChildRemove", obj)
			return
		end

		for i, val in ipairs(self.Children) do
			if val == obj then
				table.remove(self.Children, i)
				self:InvalidateChildrenList()
				obj.Parent = NULL
				obj:InvalidateParentList()
				obj:CallLocalEvent("OnUnParent", self)
				self:CallLocalEvent("OnChildRemove", obj)

				break
			end
		end
	end

	do
		function META:CallRecursive(func, a, b, c)
			assert(c == nil, "EXTEND ME")

			if self[func] then self[func](self, a, b, c) end

			for _, child in ipairs(self:GetChildrenList()) do
				if child[func] then child[func](child, a, b, c) end
			end
		end

		function META:CallRecursiveOnType(type_name, func, a, b, c)
			assert(c == nil, "EXTEND ME")

			if self[func] and self.Type == type_name then
				self[func](self, a, b, c)
			end

			for _, child in ipairs(self:GetChildrenList()) do
				if child[func] and self.Type == type_name then
					child[func](child, a, b, c)
				end
			end
		end

		function META:SetKeyValueRecursive(key, val)
			self[key] = val

			for _, child in ipairs(self:GetChildrenList()) do
				child[key] = val
			end
		end
	end
end
