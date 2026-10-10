local autocomplete = library()
autocomplete.lists = autocomplete.lists or {}
autocomplete.names = autocomplete.names or {}
local index_cache = setmetatable({}, {__mode = "k"})
local MAX_PER_BUCKET = 1000

function autocomplete.AddList(id, source, options)
	autocomplete.RemoveList(id)
	table.insert(autocomplete.lists, {id = id, source = source, options = options or {}})
end

function autocomplete.RemoveList(id)
	for i, entry in ipairs(autocomplete.lists) do
		if entry.id == id then
			table.remove(autocomplete.lists, i)
			return true
		end
	end

	return false
end

function autocomplete.HasList(id)
	for _, entry in ipairs(autocomplete.lists) do
		if entry.id == id then return true end
	end

	return false
end

function autocomplete.GetLists()
	local ids = {}

	for i, entry in ipairs(autocomplete.lists) do
		ids[i] = entry.id
	end

	return ids
end

function autocomplete.SetListName(id, name)
	autocomplete.names[id] = name
end

function autocomplete.GetListName(id)
	local name = autocomplete.names[id]

	if type(name) == "function" then return name() end

	return name
end

local function get_value(item)
	if type(item) == "table" then return item.val end

	return item
end

local function get_lowercase_index(source)
	local index = index_cache[source]

	if not index or index.count ~= #source then
		index = {count = #source, lower = {}}

		for i = 1, #source do
			index.lower[i] = get_value(source[i]):lower()
		end

		index_cache[source] = index
	end

	return index.lower
end

local function compare_index(a, b)
	return a.index < b.index
end

local function compare_alphabetical(a, b)
	if a.value ~= b.value then return a.value < b.value end

	return a.index < b.index
end

local function compare_matches(a, b)
	if a.length ~= b.length then return a.length < b.length end

	return a.index < b.index
end

local function search_source(entry, text, options)
	local source = entry.source

	if type(source) == "function" then
		source = source(text)

		if type(source) == "string" then source = {source} end
	end

	if not source then return {} end

	if entry.options.NoFilter then
		local all = {}

		for i = 1, #source do
			local item = source[i]
			all[i] = {
				val = get_value(item),
				id = entry.id,
				start = 1,
				stop = 0,
				detail = type(item) == "table" and item.detail or nil,
				hint = type(item) == "table" and item.hint or nil,
			}
		end

		return all
	end

	local case_sensitive = options.CaseSensitive or entry.options.CaseSensitive
	local match_prefix_only = (options.Match or entry.options.Match) == "prefix"
	local keep_order = entry.options.KeepOrder
	local alphabetical = entry.options.Alphabetical
	local query = case_sensitive and text or text:lower()
	local haystack

	if case_sensitive then
		haystack = {}

		for i = 1, #source do
			haystack[i] = get_value(source[i])
		end
	elseif type(entry.source) == "table" then
		haystack = get_lowercase_index(source)
	else
		haystack = {}

		for i = 1, #source do
			haystack[i] = get_value(source[i]):lower()
		end
	end

	local prefix_matches = {}
	local word_matches = {}
	local other_matches = {}
	local query_length = #query

	for i = 1, #haystack do
		local position = haystack[i]:find(query, 1, true)

		if position then
			local match = {index = i, position = position, length = #haystack[i], value = haystack[i]}

			if position == 1 or keep_order then
				prefix_matches[#prefix_matches + 1] = match

				if #prefix_matches >= MAX_PER_BUCKET then break end
			elseif not match_prefix_only then
				if haystack[i]:sub(position - 1, position - 1):find("%w") then
					if #other_matches < MAX_PER_BUCKET then
						other_matches[#other_matches + 1] = match
					end
				elseif #word_matches < MAX_PER_BUCKET then
					word_matches[#word_matches + 1] = match
				end
			end
		end
	end

	local max = options.MaxPerList or options.Max or 50
	local found = {}

	for _, bucket in ipairs{prefix_matches, word_matches, other_matches} do
		table.sort(bucket, keep_order and compare_index or (alphabetical and compare_alphabetical or compare_matches))

		for _, match in ipairs(bucket) do
			if #found >= max then return found end

			local item = source[match.index]
			found[#found + 1] = {
				val = get_value(item),
				id = entry.id,
				start = match.position,
				stop = match.position + query_length - 1,
				detail = type(item) == "table" and item.detail or nil,
			}
		end
	end

	return found
end

function autocomplete.Search(text, options)
	options = options or {}
	local results = {}

	if text == "" and not options.MatchEmpty then return results end

	local entries = autocomplete.lists

	if options.Lists then
		entries = {}

		for _, id in ipairs(options.Lists) do
			if type(id) == "table" then
				entries[#entries + 1] = id
			else
				for _, entry in ipairs(autocomplete.lists) do
					if entry.id == id then entries[#entries + 1] = entry end
				end
			end
		end
	end

	local max = options.Max or 50

	for _, entry in ipairs(entries) do
		for _, result in ipairs(search_source(entry, text, options)) do
			results[#results + 1] = result

			if #results >= max then return results end
		end
	end

	return results
end

function autocomplete.Random(count, options)
	options = options or {}
	local wanted

	if options.Lists then
		wanted = {}

		for _, id in ipairs(options.Lists) do
			wanted[id] = true
		end
	end

	local pools = {}
	local total = 0

	for _, entry in ipairs(autocomplete.lists) do
		if type(entry.source) == "table" and (not wanted or wanted[entry.id]) and #entry.source > 0 then
			pools[#pools + 1] = entry
			total = total + #entry.source
		end
	end

	local results = {ungrouped = true}
	local seen = {}
	local state = (options.Seed or os.time()) % 4294967296

	for _ = 1, count * 4 do
		if #results >= count or #results >= total then break end

		state = (state * 1664525 + 1013904223) % 4294967296
		local pick = math.floor(state / 4294967296 * total) + 1

		for _, entry in ipairs(pools) do
			if pick <= #entry.source then
				local value = get_value(entry.source[pick])

				if not seen[value] then
					seen[value] = true
					results[#results + 1] = {val = value, id = entry.id, start = 1, stop = 0}
				end

				break
			end

			pick = pick - #entry.source
		end
	end

	return results
end

local Session = {}
Session.__index = Session

local function default_get_query(text)
	return "", text
end

function autocomplete.NewSession(config)
	config = config or {}
	local session = setmetatable(
		{
			Lists = config.Lists,
			Max = config.Max or 50,
			MaxPerList = config.MaxPerList,
			Match = config.Match,
			CaseSensitive = config.CaseSensitive,
			MinLength = config.MinLength or 1,
			MatchEmpty = config.MatchEmpty,
			RandomCount = config.RandomCount or 0,
			GetQuery = config.GetQuery or default_get_query,
			text = "",
			prefix = "",
			query = "",
			results = {},
			selected = 1,
			dismissed = false,
			explicit = false,
			cycling = nil,
			force = true,
			version = 0,
		},
		Session
	)
	session:Reseed()
	return session
end

function Session:touch()
	self.version = self.version + 1
end

function Session:Reseed(seed)
	self.seed = seed or os.time() + math.floor(os.clock() * 1000000)
	self.random_results = nil
	self.random_next = 1
end

function Session:SetText(text, cursor)
	if self.cycling then
		if self.cycling == text then return end

		self.cycling = nil
		self.text = nil
	end

	if text == self.text and not self.force then return end

	self.force = false
	self.text = text
	local lists, match_empty
	self.prefix, self.query, lists, match_empty = self.GetQuery(text, cursor or #text + 1)
	self.current_lists = lists
	self.dismissed = false
	self.explicit = false
	self.selected = 1

	if #self.query >= self.MinLength or match_empty then
		self.results = autocomplete.Search(
			self.query,
			{
				Lists = lists or self.Lists,
				Max = self.Max,
				MaxPerList = self.MaxPerList,
				Match = self.Match,
				CaseSensitive = self.CaseSensitive,
				MatchEmpty = self.MatchEmpty or match_empty,
			}
		)
	else
		self.results = {}
	end

	while self.results[self.selected] and self.results[self.selected].hint and self.selected < #self.results do
		self.selected = self.selected + 1
	end

	self:touch()
end

function Session:GetResults()
	return self.results
end

function Session:HasResults()
	return #self.results > 0 and not self.dismissed
end

function Session:HasSelectable()
	if self.dismissed then return false end

	for _, result in ipairs(self.results) do
		if not result.hint then return true end
	end

	return false
end

function Session:IsExplicit()
	return self.explicit
end

function Session:GetSelectedIndex()
	return self.selected
end

function Session:GetSelected()
	return self.results[self.selected]
end

function Session:Select(index)
	local count = #self.results

	if count == 0 or not self:HasSelectable() then return end

	self.selected = (index - 1) % count + 1

	while self.results[self.selected].hint do
		self.selected = self.selected % count + 1
	end

	self.explicit = true
	self:touch()
end

function Session:Move(delta)
	self:Select(self.selected + delta)
end

function Session:GetCompletion()
	local selected = self.results[self.selected]

	if selected and not selected.hint then return self.prefix .. selected.val end
end

function Session:GetGhost()
	local selected = self.results[self.selected]

	if self.dismissed or self.cycling or not selected or selected.hint or selected.start ~= 1 then
		return ""
	end

	return selected.val:sub(#self.query + 1)
end

function Session:Dismiss()
	if self.dismissed then return end

	self.dismissed = true
	self:touch()
end

function Session:Accept()
	local completion = self:GetCompletion()

	if not completion then return end

	self.text = completion
	self.cycling = nil
	self.dismissed = true
	self.explicit = false
	self:touch()
	return completion
end

function Session:Cycle(delta)
	if #self.results == 0 then
		if self.query ~= "" or self.RandomCount == 0 or self.current_lists then return end

		self.random_results = self.random_results or
			autocomplete.Random(self.RandomCount, {Lists = self.Lists, Seed = self.seed})

		if #self.random_results == 0 then return end

		self.results = self.random_results
		self.selected = self.random_next
	elseif self.cycling then
		self:Move(delta)
	end

	if self.results == self.random_results then
		self.random_next = self.selected % #self.results + 1
	end

	local completion = self:GetCompletion()

	if not completion then return end

	self.cycling = completion
	self.dismissed = false
	self:touch()
	return completion
end

function Session:Clear()
	self.text = ""
	self.prefix = ""
	self.query = ""
	self.results = {}
	self.selected = 1
	self.dismissed = false
	self.explicit = false
	self.cycling = nil
	self.force = true
	self:touch()
end

return autocomplete
