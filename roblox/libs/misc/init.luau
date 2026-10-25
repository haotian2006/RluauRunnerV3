--[[ 
   ~a       : not a
   a ^ b    : a and b
   a v b    : a or b
   a -> b   : (not a) or b
   a <-> b  : a == b
--]]

local function and_(a, b)
	return a and b
end
local function or_(a, b)
	return a or b
end
local function cond(a, b)
	return (not a) or b
end
local function bicond(a, b)
	return a == b
end
local function not_(a)
	return not a
end

local function tokenize(input: string)
	local tokens = {}
	local i = 1
	while i <= #input do
		local c = input:sub(i, i)
		if c:match("%s") then
			i += 1
		elseif c:match("[%a_]") then
			local j = i
			while j <= #input and input:sub(j, j):match("[%w_]") do
				j += 1
			end
			table.insert(tokens, { type = "var", value = input:sub(i, j - 1) })
			i = j
		elseif input:sub(i, i + 2) == "<->" then
			table.insert(tokens, { type = "op", value = "<->" })
			i += 3
		elseif input:sub(i, i + 1) == "->" then
			table.insert(tokens, { type = "op", value = "->" })
			i += 2
		elseif c == "^" or c == "v" or c == "~" or c == "(" or c == ")" then
			table.insert(tokens, { type = "op", value = c })
			i += 1
		else
			error("Unexpected character at " .. i .. ": " .. c)
		end
	end
	return tokens
end

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens)
	return setmetatable({ tokens = tokens, pos = 1 }, Parser)
end

function Parser:peek()
	return self.tokens[self.pos]
end

function Parser:consume()
	local tok = self.tokens[self.pos]
	self.pos += 1
	return tok
end

-- expr    := bicond
-- bicond  := implies ("<->" implies)*
-- implies := orexpr ("->" orexpr)*
-- orexpr  := andexpr ("v" andexpr)*
-- andexpr := unary ("^" unary)*
-- unary   := "~" unary | primary
-- primary := VAR | "(" expr ")"

function Parser:parseExpr()
	return self:parseBicond()
end

function Parser:parseBicond()
	local left = self:parseImplies()
	while self:peek() and self:peek().value == "<->" do
		self:consume()
		local right = self:parseImplies()
		left = { "bicond", left, right }
	end
	return left
end

function Parser:parseImplies()
	local left = self:parseOr()
	while self:peek() and self:peek().value == "->" do
		self:consume()
		local right = self:parseOr()
		left = { "cond", left, right }
	end
	return left
end

function Parser:parseOr()
	local left = self:parseAnd()
	while self:peek() and self:peek().value == "v" do
		self:consume()
		local right = self:parseAnd()
		left = { "or", left, right }
	end
	return left
end

function Parser:parseAnd()
	local left = self:parseUnary()
	while self:peek() and self:peek().value == "^" do
		self:consume()
		local right = self:parseUnary()
		left = { "and", left, right }
	end
	return left
end

function Parser:parseUnary()
	if self:peek() and self:peek().value == "~" then
		self:consume()
		return { "not", self:parseUnary() }
	end
	return self:parsePrimary()
end

function Parser:parsePrimary()
	local tok = self:consume()
	if tok.type == "var" then
		return { "var", tok.value }
	elseif tok.value == "(" then
		local expr = self:parseExpr()
		assert(self:peek() and self:peek().value == ")", "missing )")
		self:consume()
		return expr
	else
		error("Unexpected token: " .. tok.value)
	end
end

local function compile(ast, vars)
	if ast[1] == "var" then
		vars[ast[2]] = true
		return ast[2]
	elseif ast[1] == "not" then
		return "not_(" .. compile(ast[2], vars) .. ")"
	elseif ast[1] == "and" then
		return "and_(" .. compile(ast[2], vars) .. "," .. compile(ast[3], vars) .. ")"
	elseif ast[1] == "or" then
		return "or_(" .. compile(ast[2], vars) .. "," .. compile(ast[3], vars) .. ")"
	elseif ast[1] == "cond" then
		return "cond(" .. compile(ast[2], vars) .. "," .. compile(ast[3], vars) .. ")"
	elseif ast[1] == "bicond" then
		return "bicond(" .. compile(ast[2], vars) .. "," .. compile(ast[3], vars) .. ")"
	end
end

local function parseFormula(str, varsOrder)
	str = string.gsub(str,'v',' v ')
	local tokens = tokenize(str)
	local parser = Parser.new(tokens)
	local body
	local pass = pcall(function()
		local ast = parser:parseExpr()
		local vars = {}
		body = compile(ast, vars)
	end)

	if not pass then
		return nil
	end

	local f = loadstring(`return function({table.concat(varsOrder, ",")}) return {body} end`)()
	local env = getfenv(f)
	env.and_ = and_
	env.or_ = or_
	env.cond = cond
	env.bicond = bicond
	env.not_ = not_

	return f
end

local function truthTable(vars)
	local n = #vars
	local rows = {}
	for i = 0, 2 ^ n - 1 do
		local row = {}
		for j = 1, n do
			local bit = bit32.band(bit32.rshift(i, (n - j)), 1)
			row[vars[j]] = (bit ~= 1)
		end
		table.insert(rows, row)
	end
	return rows
end

local function calculate(print,var: string, ...)
	local vars = var:lower():split("")
	local tbl = truthTable(vars)
	local callbacks = { ... }

	local headers = {}
	for i = 1, #vars do
		headers[i] = vars[i]
	end
	for i = 1, #callbacks do
		headers[#vars + i] = callbacks[i]
	end

	local compiled = {}
	for i, expr in ipairs(callbacks) do
		compiled[i] = parseFormula(expr, vars)
		if not compiled[i] then
			print("Failed to parse expression " .. i .. ": [" .. expr .. "]") 
			return
		end
		print(`e{i} = {expr}`)
		headers[#vars + i] = `e{i}`
	end

	local colWidths = {}
	for i, h in headers do
		colWidths[i] = #h
	end

	local function pad(str, width)
		return str .. string.rep(" ", width - #str)
	end

	local headerLine = {}
	for i, h in headers do
		headerLine[i] = pad(h, colWidths[i])
	end
	print(table.concat(headerLine, " | "))

	local sep = {}
	for i, w in colWidths do
		sep[i] = string.rep("-", w)
	end
	print(table.concat(sep, "-+-"))

	for _, row in tbl do
		local result = {}
		for i = 1, #vars do
			local val = row[vars[i]] and "T" or "F"
			colWidths[i] = math.max(colWidths[i], #val)
			result[i] = pad(val, colWidths[i])
		end
		for i, func in compiled do
			local ok, res = pcall(
				func,
				table.unpack((function()
					local t = {}
					for j = 1, #vars do
						t[j] = row[vars[j]]
					end
					return t
				end)())
			)
			if not ok then
				error(`Error evaluating expression {i}: {res}`)
			end
			local val = res and "T" or "F"
			colWidths[#vars + i] = math.max(colWidths[#vars + i], #val)
			result[#vars + i] = pad(val, colWidths[#vars + i])
		end
		print(table.concat(result, " | "))
	end
end

return {
	calculate = calculate,
	truth = truthTable,
	uwuify = script:FindFirstChild("ModuleScript") and  require(script.ModuleScript)
}
