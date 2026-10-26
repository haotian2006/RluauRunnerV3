--!optimize 2

local M = {}

local defaults = {}
local function defaultOf(class, prop)
	local byClass = defaults[class]
	if not byClass then
		byClass = {}
		defaults[class] = byClass
	end
	local v = byClass[prop]
	if v == nil then
		local ok, inst = pcall(Instance.new, class)
		if ok then
			local okProp, value = pcall(function()
				return inst[prop]
			end)
			v = if okProp then { value } else false
			inst:Destroy()
		else
			v = false
		end
		byClass[prop] = v
	end
	return v
end

-- One compound selector: { class?, tags = {}, name?, states = {}, pseudo? }
local function parseCompound(text)
	local c = { tags = {}, states = {} }
	local pseudo = string.match(text, "::([%w_]+)")
	if pseudo then
		c.pseudo = pseudo
		text = string.gsub(text, "::[%w_]+", "")
	end
	c.class = string.match(text, "^([%a_][%w_]*)")
	for tag in string.gmatch(text, "%.([%w_%-]+)") do
		table.insert(c.tags, tag)
	end
	c.name = string.match(text, "#([%w_%-]+)")
	for state in string.gmatch(text, ":([%w_]+)") do
		table.insert(c.states, state)
	end
	return c
end

-- A selector list as alternatives of { compound, combinator, compound, ... } chains.
local function parseSelector(selector: string)
	local alternatives = {}
	for alt in string.gmatch(selector, "[^,]+") do
		local chain = {}
		local s = string.gsub(alt, ">>", " \1 ")
		s = string.gsub(s, ">", " \2 ")
		for token in string.gmatch(s, "%S+") do
			if token == "\1" then
				table.insert(chain, ">>")
			elseif token == "\2" then
				table.insert(chain, ">")
			else
				if #chain > 0 and type(chain[#chain]) == "table" then
					table.insert(chain, ">>")
				end
				table.insert(chain, parseCompound(token))
			end
		end
		if #chain > 0 then
			table.insert(alternatives, chain)
		end
	end
	return alternatives
end

local function matchesCompound(inst, c)
	if #c.states > 0 then
		return false
	end
	if c.class and not inst:IsA(c.class) then
		return false
	end
	if c.name and inst.Name ~= c.name then
		return false
	end
	for _, tag in c.tags do
		if not inst:HasTag(tag) then
			return false
		end
	end
	return true
end

-- Whether inst matches the chain ending at position i, looking no higher than scope.
local function matchesChain(inst, chain, i, scope)
	if not matchesCompound(inst, chain[i]) then
		return false
	end
	if i == 1 then
		return true
	end
	local combinator = chain[i - 1]
	local parent = inst.Parent
	if combinator == ">" then
		return parent ~= nil and parent ~= scope.Parent and matchesChain(parent, chain, i - 2, scope)
	end
	while parent and parent ~= scope.Parent do
		if matchesChain(parent, chain, i - 2, scope) then
			return true
		end
		parent = parent.Parent
	end
	return false
end

-- Token value for "$Name" from the sheet or the sheets it derives from.
local function token(sheet, name, seen)
	seen = seen or {}
	if seen[sheet] then
		return nil
	end
	seen[sheet] = true
	local v = sheet:GetAttribute(name)
	if v ~= nil then
		return v
	end
	local ok, derives = pcall(sheet.GetDerives, sheet)
	if ok then
		for _, d in derives do
			local found = token(d, name, seen)
			if found ~= nil then
				return found
			end
		end
	end
	return nil
end

-- Rules of a sheet, its nested rules (selectors joined to their parent's) and derived sheets'
-- rules (first, so the sheet's own win), as { selector, properties, priority, order }.
local function collectRules(sheet, out, seen)
	if seen[sheet] then
		return
	end
	seen[sheet] = true
	local okDerives, derives = pcall(sheet.GetDerives, sheet)
	if okDerives then
		for _, d in derives do
			collectRules(d, out, seen)
		end
	end
	local function addRule(rule, prefix)
		local selector = rule.Selector
		if prefix then
			selector = if string.match(selector, "^%s*[>:]") then prefix .. selector else prefix .. " " .. selector
		end
		local okProps, props = pcall(rule.GetProperties, rule)
		table.insert(out, {
			selector = selector, properties = if okProps then props else {}, priority = rule.Priority,
			order = #out, sheet = sheet,
		})
		for _, child in rule:GetChildren() do
			if child:IsA("StyleRule") then
				addRule(child, selector)
			end
		end
	end
	local okRules, rules = pcall(sheet.GetStyleRules, sheet)
	if not okRules then
		rules = {}
		for _, c in sheet:GetChildren() do
			if c:IsA("StyleRule") then
				table.insert(rules, c)
			end
		end
	end
	for _, rule in rules do
		addRule(rule, nil)
	end
end

local function apply(inst, properties, sheet)
	for prop, value in properties do
		if type(value) == "string" and string.sub(value, 1, 1) == "$" then
			value = token(sheet, string.sub(value, 2))
			if value == nil then
				continue
			end
		end
		local okCur, current = pcall(function()
			return inst[prop]
		end)
		local default = defaultOf(inst.ClassName, prop)
		if okCur and default and current == default[1] then
			pcall(function()
				inst[prop] = value
			end)
		end
	end
end

-- Applies every StyleLink's sheet inside root (and the extra links, for a root cut out of a
-- styled tree) to root's descendants.
function M.apply(root: Instance, extraLinks: { StyleLink }?)
	local links = {}
	for _, d in root:GetDescendants() do
		if d:IsA("StyleLink") then
			table.insert(links, d)
		end
	end
	for _, l in extraLinks or {} do
		table.insert(links, l)
	end
	if #links == 0 then
		return
	end
	local targets = root:GetDescendants()
	table.insert(targets, 1, root)
	for _, link in links do
		local sheet = link.StyleSheet
		if not sheet then
			continue
		end
		local scope = if link:IsDescendantOf(root) then link.Parent else root
		local rules = {}
		collectRules(sheet, rules, {})
		table.sort(rules, function(a, b)
			if a.priority ~= b.priority then
				return a.priority < b.priority
			end
			return a.order < b.order
		end)
		for _, rule in rules do
			local chains = parseSelector(rule.selector)
			for _, inst in targets do
				if inst ~= scope and not inst:IsDescendantOf(scope) then
					continue
				end
				for _, chain in chains do
					if matchesChain(inst, chain, #chain, scope) then
						local last = chain[#chain]
						local target = inst
						if last.pseudo then
							target = inst:FindFirstChild("__style_" .. last.pseudo)
							if not target then
								local ok, created = pcall(Instance.new, last.pseudo)
								if not ok then
									break
								end
								created.Name = "__style_" .. last.pseudo
								created.Parent = inst
								target = created
							end
						end
						apply(target, rule.properties, rule.sheet)
						break
					end
				end
			end
		end
	end
end

return M
