--Put this under LoadEnv
--!nocheck

local ReflectionService = game:GetService("ReflectionService")
local realGame = game
local realWorkspace = game:GetService("Workspace")
local realTypeof = typeof
local realInstance = Instance
local realRequire = require
local realStats = stats
local realSettings = settings
local realUserSettings = UserSettings

local LOCKED = "The metatable is locked"
local NIL = newproxy(false)
local WORLDROOT_EXTRA = { GetBoundingBox = true, GetExtentsSize = true }

local Sandbox = {}

local states = setmetatable({}, { __mode = "k" })
local proxyKind = setmetatable({}, { __mode = "k" })
local sigStates = setmetatable({}, { __mode = "k" })
local rootWorld = {}
local shadowInfo = {}
local worlds = {}

local function index(o, k)
	return o[k]
end

local function setIndex(o, k, v)
	o[k] = v
end

local function sandboxTypeof(v)
	return proxyKind[v] or realTypeof(v)
end

local function box(v)
	if v == nil then
		return NIL
	end
	return v
end

local function unbox(v)
	if v == NIL then
		return nil
	end
	return v
end

local function replacePlain(s, from, to)
	local out, i = {}, 1
	while true do
		local a, b = string.find(s, from, i, true)
		if not a then
			break
		end
		table.insert(out, string.sub(s, i, a - 1))
		table.insert(out, to)
		i = b + 1
	end
	if i == 1 then
		return s
	end
	table.insert(out, string.sub(s, i))
	return table.concat(out)
end

--// Reflection

local classCache = {}
local function getClass(className)
	local c = classCache[className]
	if c then
		return c
	end
	c = { props = {}, methods = {}, events = {}, fns = {} }
	local ok, props = pcall(ReflectionService.GetPropertiesOfClass, ReflectionService, className)
	if ok and props then
		for _, p in props do
			local t = p.Type or {}
			c.props[p.Name] = {
				write = p.Permits ~= nil and p.Permits.Write ~= nil,
				scriptType = t.ScriptType,
				instanceType = t.InstanceType,
				enumType = t.EnumType,
			}
		end
	end
	local ok2, methods = pcall(ReflectionService.GetMethodsOfClass, ReflectionService, className)
	if ok2 and methods then
		for _, m in methods do
			c.methods[m.Name] = true
		end
	end
	local ok3, events = pcall(ReflectionService.GetEventsOfClass, ReflectionService, className)
	if ok3 and events then
		for _, e in events do
			c.events[e.Name] = true
		end
	end
	classCache[className] = c
	return c
end

local worldRootMethods = table.clone(WORLDROOT_EXTRA)
do
	local ok, ms = pcall(ReflectionService.GetMethodsOfClass, ReflectionService, "WorldRoot", { ExcludeInherited = true })
	if ok and ms then
		for _, m in ms do
			worldRootMethods[m.Name] = true
		end
	end
end

--// Baseline

local userSettingsRoot = (pcall(realUserSettings) and realUserSettings()) or nil
local baseline = {}
local baselineProps = {}

local function isService(inst)
	if inst.Parent ~= realGame then
		return false
	end
	local ok, s = pcall(realGame.FindService, realGame, inst.ClassName)
	return ok and s == inst
end

local function snapshot(inst)
	baseline[inst] = true
	local snap = {}
	for name, info in getClass(inst.ClassName).props do
		if info.write and name ~= "Parent" then
			local ok, v = pcall(index, inst, name)
			if ok then
				snap[name] = box(v)
			end
		end
	end
	baselineProps[inst] = snap
end

snapshot(realGame)
for _, d in realGame:GetDescendants() do
	baseline[d] = true
end
for _, s in realGame:GetChildren() do
	snapshot(s)
end
pcall(snapshot, realWorkspace.Terrain)
if realWorkspace.CurrentCamera then
	snapshot(realWorkspace.CurrentCamera)
end
if userSettingsRoot then
	baseline[userSettingsRoot] = true
	for _, d in userSettingsRoot:GetDescendants() do
		baseline[d] = true
	end
end
realGame.ChildAdded:Connect(function(c)
	if not baseline[c] and isService(c) then
		snapshot(c)
	end
end)
realGame.DescendantRemoving:Connect(function(d)
	baseline[d] = nil
	baselineProps[d] = nil
end)

local function isEngine(inst)
	if inst == realGame or inst:IsDescendantOf(realGame) then
		return true
	end
	return userSettingsRoot ~= nil and (inst == userSettingsRoot or inst:IsDescendantOf(userSettingsRoot))
end

local function isEngineClass(inst)
	return inst:IsA("Camera") or inst:IsA("Terrain") or isService(inst)
end

--// Local signals (deferred like the engine)

local function newLocal()
	return { listeners = {} }
end

local function localConnect(ls, fn)
	local entry = { fn = fn }
	ls.listeners[entry] = true
	return {
		Disconnect = function()
			ls.listeners[entry] = nil
		end,
	}
end

local function localFire(ls, ...)
	for entry in ls.listeners do
		task.defer(entry.fn, ...)
	end
end

--// World

local World = {}
World.__index = World

local wrap, wrapOut, unwrapDeep, makeSignal, directChild

local function ownerOf(inst)
	local cur = inst
	while cur do
		local w = rootWorld[cur]
		if w then
			return w
		end
		cur = cur.Parent
	end
	return nil
end

local function pin(world, inst)
	if rootWorld[inst] == nil then
		rootWorld[inst] = world
		world.pinned[inst] = true
	end
end

local function unpin(world, inst)
	if world.pinned[inst] then
		world.pinned[inst] = nil
		rootWorld[inst] = nil
	end
end

local function addRewrite(world, from, to)
	table.insert(world.rewrites, { from, to })
	table.sort(world.rewrites, function(a, b)
		return #a[1] > #b[1]
	end)
end

local function rewrite(world, msg)
	if type(msg) ~= "string" then
		return msg
	end
	for _, r in world.rewrites do
		msg = replacePlain(msg, r[1], r[2])
	end
	return msg
end

local function ovFor(world, real)
	local ov = world.overlay[real]
	if not ov then
		ov = {
			props = {},
			attrs = {},
			tags = {},
			changed = newLocal(),
			propSignals = {},
			attrChanged = newLocal(),
			attrSignals = {},
			destroyed = false,
		}
		world.overlay[real] = ov
	end
	return ov
end

local function isHidden(world, real)
	local ov = world.overlay[real]
	return ov ~= nil and ov.destroyed
end

local function nameOf(st)
	if st.kind == "shared" then
		local v = st.ov.props.Name
		if v ~= nil then
			return unbox(v)
		end
		local b = baselineProps[st.real]
		if b and b.Name ~= nil then
			return unbox(b.Name)
		end
	end
	return st.real.Name
end

local function virtualParent(st)
	local real = st.real
	if st.kind == "shared" and st.ov.destroyed then
		return nil
	end
	local p = real.Parent
	if p == nil then
		return nil
	end
	return wrap(st.world, p)
end

local function virtualFullName(st)
	local parts = { nameOf(st) }
	local cur = virtualParent(st)
	while cur do
		local cst = states[cur]
		if cst.real == realGame then
			break
		end
		table.insert(parts, 1, nameOf(cst))
		cur = virtualParent(cst)
	end
	return table.concat(parts, ".")
end

local function shadowFor(world, shared)
	local s = world.shadows[shared]
	if s then
		return s
	end
	world.shadowCount += 1
	s = realInstance.new("Folder")
	s.Name = "__svc_" .. world.shadowCount
	s.Parent = world.root
	world.shadows[shared] = s
	shadowInfo[s] = { world = world, shared = shared }
	local full = s:GetFullName()
	if shared == realGame then
		addRewrite(world, full .. ".", "")
	else
		addRewrite(world, full, virtualFullName(states[wrap(world, shared)]))
	end
	return s
end

--// Proxy core

local ownedMethods, sharedMethods, ownedGetters, sharedGetters = {}, {}, {}, {}
local serviceMethods = {}
local methodCache = {}
local wsMethodCache = {}

local function typeName(v)
	return proxyKind[v] or realTypeof(v)
end

local function setOps(mt)
	local function arith(op)
		return function(a, b)
			error(`attempt to perform arithmetic ({op}) on {typeName(a)} and {typeName(b)}`, 2)
		end
	end
	mt.__add = arith("add")
	mt.__sub = arith("sub")
	mt.__mul = arith("mul")
	mt.__div = arith("div")
	mt.__idiv = arith("idiv")
	mt.__mod = arith("mod")
	mt.__pow = arith("pow")
	mt.__unm = function(a)
		error(`attempt to perform arithmetic (unm) on {typeName(a)}`, 2)
	end
	mt.__len = function(a)
		error(`attempt to get length of a {typeName(a)} value`, 2)
	end
	mt.__call = function(a)
		error(`attempt to call a {typeName(a)} value`, 2)
	end
	mt.__concat = function(a, b)
		error(`attempt to concatenate {typeName(a)} with {typeName(b)}`, 2)
	end
	mt.__lt = function(a, b)
		error(`attempt to compare {typeName(a)} < {typeName(b)}`, 2)
	end
	mt.__le = function(a, b)
		error(`attempt to compare {typeName(a)} <= {typeName(b)}`, 2)
	end
	mt.__iter = function(a)
		error(`attempt to iterate over a {typeName(a)} value`, 2)
	end
	mt.__metatable = LOCKED
end

local function wrapN(world, ...)
	local n = select("#", ...)
	if n == 0 then
		return
	elseif n == 1 then
		return wrapOut(world, ...)
	end
	local t = { ... }
	for i = 1, n do
		t[i] = wrapOut(world, t[i])
	end
	return table.unpack(t, 1, n)
end

local function wrapCallback(world, fn)
	return function(...)
		local t = table.pack(fn(wrapN(world, ...)))
		for i = 1, t.n do
			t[i] = unwrapDeep(world, t[i])
		end
		return table.unpack(t, 1, t.n)
	end
end

local function unwrapArg(world, v)
	local st = states[v]
	if st then
		return st.real
	end
	local tv = type(v)
	if tv == "table" then
		return unwrapDeep(world, v)
	elseif tv == "function" then
		return wrapCallback(world, v)
	end
	return v
end

local function unwrapN(world, ...)
	local n = select("#", ...)
	if n == 0 then
		return
	elseif n == 1 then
		return unwrapArg(world, ...)
	end
	local t = { ... }
	for i = 1, n do
		t[i] = unwrapArg(world, t[i])
	end
	return table.unpack(t, 1, n)
end

function unwrapDeep(world, v, seen)
	local st = states[v]
	if st then
		return st.real
	end
	if type(v) ~= "table" then
		return v
	end
	seen = seen or {}
	local done = seen[v]
	if done then
		return done
	end
	seen[v] = v
	local out
	for k, x in v do
		local nk = k
		if states[k] or type(k) == "table" then
			nk = unwrapDeep(world, k, seen)
		end
		local nx = x
		if states[x] or type(x) == "table" then
			nx = unwrapDeep(world, x, seen)
		end
		if nk ~= k or nx ~= x then
			if not out then
				out = table.clone(v)
				seen[v] = out
			end
			if nk ~= k then
				out[k] = nil
			end
			out[nk] = nx
		end
	end
	return out or v
end

local function wrapTable(world, t)
	local n = #t
	if n > 0 then
		local j = 0
		for i = 1, n do
			local x = wrapOut(world, t[i])
			if x ~= nil then
				j += 1
				t[j] = x
			end
		end
		for i = j + 1, n do
			t[i] = nil
		end
	else
		for k, x in t do
			local tx = realTypeof(x)
			if tx == "Instance" or tx == "table" or tx == "RBXScriptSignal" then
				t[k] = wrapOut(world, x)
			end
		end
	end
	return t
end

local function copyWrap(world, v, seen)
	local tv = realTypeof(v)
	if tv ~= "table" then
		return wrapOut(world, v)
	end
	seen = seen or {}
	if seen[v] then
		return seen[v]
	end
	seen[v] = v
	local out
	for k, x in v do
		local nx = copyWrap(world, x, seen)
		if nx ~= x then
			if not out then
				out = table.clone(v)
				seen[v] = out
			end
			out[k] = nx
		end
	end
	return out or v
end

local function wrapRaycastResult(world, r)
	local p = newproxy(true)
	local mt = getmetatable(p)
	proxyKind[p] = "RaycastResult"
	mt.__index = function(_, k)
		local v = r[k]
		if realTypeof(v) == "Instance" then
			return wrap(world, v)
		end
		return v
	end
	mt.__newindex = function(_, k)
		error(`{k} cannot be assigned to`, 2)
	end
	mt.__tostring = function()
		return tostring(r)
	end
	setOps(mt)
	return p
end

function wrapOut(world, v)
	local tv = realTypeof(v)
	if tv == "Instance" then
		return wrap(world, v)
	elseif tv == "table" then
		return wrapTable(world, v)
	elseif tv == "RBXScriptSignal" then
		return makeSignal(world, { v })
	elseif tv == "RaycastResult" then
		return wrapRaycastResult(world, v)
	end
	return v
end

local function selfState(self, k)
	local st = states[self]
	if not st then
		error(`Expected ':' not '.' calling member function {k}`, 0)
	end
	return st
end

local function finish(world, ok, ...)
	if not ok then
		error(rewrite(world, (...)), 0)
	end
	return wrapN(world, ...)
end

local function finish1(world, ok, v, ...)
	if not ok then
		error(rewrite(world, v), 0)
	end
	if select("#", ...) == 0 then
		local tv = type(v)
		if tv == "userdata" or tv == "table" then
			return wrapOut(world, v)
		end
		return v
	end
	return wrapN(world, v, ...)
end

local function methodWrapper(k)
	local m = methodCache[k]
	if m then
		return m
	end
	m = function(self, ...)
		local st = states[self]
		if not st then
			error(`Expected ':' not '.' calling member function {k}`, 0)
		end
		local real, world = st.real, st.world
		local fns = st.class.fns
		local fn = fns[k]
		if fn == nil then
			fn = real[k]
			fns[k] = fn
		end
		local n = select("#", ...)
		if n == 0 then
			return finish1(world, pcall(fn, real))
		elseif n == 1 then
			local a = ...
			local ta = type(a)
			if ta == "userdata" or ta == "table" or ta == "function" then
				a = unwrapArg(world, a)
			end
			return finish1(world, pcall(fn, real, a))
		elseif n == 2 then
			local a, b = ...
			local ta, tb = type(a), type(b)
			if ta == "userdata" or ta == "table" or ta == "function" then
				a = unwrapArg(world, a)
			end
			if tb == "userdata" or tb == "table" or tb == "function" then
				b = unwrapArg(world, b)
			end
			return finish1(world, pcall(fn, real, a, b))
		end
		return finish(world, pcall(fn, real, unwrapN(world, ...)))
	end
	methodCache[k] = m
	return m
end

local function wsMethodWrapper(k)
	local m = wsMethodCache[k]
	if m then
		return m
	end
	m = function(self, ...)
		local st = selfState(self, k)
		local world = st.world
		local ws = world.ws
		return finish(world, pcall(ws[k], ws, unwrapN(world, ...)))
	end
	wsMethodCache[k] = m
	return m
end

local function signalFor(st, k, build)
	local sigs = st.signals
	if not sigs then
		sigs = {}
		st.signals = sigs
	end
	local s = sigs[k]
	if not s then
		s = build()
		sigs[k] = s
	end
	return s
end

local function memberError(st, k)
	error(`{k} is not a valid member of {st.real.ClassName} "{virtualFullName(st)}"`, 0)
end

local function slowIndex(st, k)
	local world, real = st.world, st.real
	if st.class.events[k] then
		return signalFor(st, k, function()
			return makeSignal(world, { real[k] })
		end)
	end
	local ok, v = pcall(index, real, k)
	if not ok then
		error(rewrite(world, v), 0)
	end
	if type(v) == "function" then
		return methodWrapper(k)
	end
	return wrapOut(world, v)
end

local function setParent(st, v)
	local world, real = st.world, st.real
	local target
	if v ~= nil then
		local vs = states[v]
		if not vs then
			error(`Unable to assign property Parent. Object expected, got {typeName(v)}`, 0)
		end
		if vs.kind == "owned" then
			target = vs.real
		else
			target = vs.real == realWorkspace and world.ws or shadowFor(world, vs.real)
		end
	end
	local ok, err = pcall(setIndex, real, "Parent", target)
	if not ok then
		error(rewrite(world, err), 0)
	end
	if target == nil then
		pin(world, real)
	else
		unpin(world, real)
	end
end

local function makeProxy(world, real, kind)
	local p = newproxy(true)
	local mt = getmetatable(p)
	local class = getClass(real.ClassName)
	local st = { real = real, world = world, kind = kind, class = class, proxy = p }
	states[p] = st
	proxyKind[p] = "Instance"
	local props, methods = class.props, class.methods
	if kind == "owned" then
		mt.__index = function(_, k)
			local m = ownedMethods[k]
			if m then
				return m
			end
			local g = ownedGetters[k]
			if g then
				return g(st)
			end
			if props[k] then
				local v = real[k]
				if realTypeof(v) == "Instance" then
					return wrap(world, v)
				end
				return v
			end
			if methods[k] then
				return methodWrapper(k)
			end
			return slowIndex(st, k)
		end
		mt.__newindex = function(_, k, v)
			if k == "Parent" then
				return setParent(st, v)
			end
			local ok, err = pcall(setIndex, real, k, unwrapArg(world, v))
			if not ok then
				error(rewrite(world, err), 0)
			end
		end
	else
		st.ov = ovFor(world, real)
		local svc = serviceMethods[real.ClassName]
		local isWs = real == realWorkspace
		mt.__index = function(_, k)
			if svc then
				local m = svc[k]
				if m then
					return m
				end
			end
			local m = sharedMethods[k]
			if m then
				return m
			end
			local g = sharedGetters[k]
			if g then
				return g(st, k)
			end
			if props[k] then
				local ov = st.ov.props[k]
				if ov == nil then
					local b = baselineProps[real]
					ov = b and b[k]
				end
				local v
				if ov ~= nil then
					v = unbox(ov)
				else
					v = real[k]
				end
				if realTypeof(v) == "Instance" then
					return wrap(world, v)
				end
				return v
			end
			if isWs and worldRootMethods[k] then
				return wsMethodWrapper(k)
			end
			if methods[k] then
				return methodWrapper(k)
			end
			if st.class.events[k] then
				return slowIndex(st, k)
			end
			local child = directChild(st, k)
			if child then
				return child
			end
			if next(props) == nil then
				return slowIndex(st, k)
			end
			memberError(st, k)
		end
		mt.__newindex = function(_, k, v)
			if k == "Parent" then
				local ok, err = pcall(setIndex, real, "Parent", unwrapArg(world, v))
				if not ok then
					error(rewrite(world, err), 0)
				end
				return
			end
			local info = props[k]
			if not info then
				if next(props) == nil then
					st.ov.props[k] = box(unwrapArg(world, v))
					return
				end
				memberError(st, k)
			end
			if not info.write then
				error(`Unable to assign property {k}. Property is read only`, 0)
			end
			local value = Sandbox.coerce(info, v, k, world)
			st.ov.props[k] = box(value)
			localFire(st.ov.changed, k)
			local ps = st.ov.propSignals[k]
			if ps then
				localFire(ps)
			end
		end
	end
	mt.__tostring = function()
		return tostring(nameOf(st))
	end
	setOps(mt)
	world.proxies[real] = p
	return p
end

function wrap(world, real)
	local p = world.proxies[real]
	if p then
		return p
	end
	local sh = shadowInfo[real]
	if sh then
		if sh.world == world then
			return wrap(world, sh.shared)
		end
		return nil
	end
	local w = ownerOf(real)
	if w == world then
		return makeProxy(world, real, "owned")
	elseif w then
		return nil
	end
	if isEngine(real) then
		if baseline[real] or isEngineClass(real) then
			return makeProxy(world, real, "shared")
		end
		return nil
	end
	local top = real
	while top.Parent do
		top = top.Parent
	end
	pin(world, top)
	return makeProxy(world, real, "owned")
end

function Sandbox.coerce(info, v, k, world)
	local want = info.scriptType
	local got = typeName(v)
	if want == "Instance" then
		if v == nil then
			return nil
		end
		local vs = states[v]
		if vs and (not info.instanceType or vs.real:IsA(info.instanceType)) then
			return vs.real
		end
	elseif want == "string" then
		if got == "string" then
			return v
		elseif got == "number" then
			return tostring(v)
		end
	elseif want == "number" then
		if got == "number" then
			return v
		end
		local n = got == "string" and tonumber(v)
		if n then
			return n
		end
	elseif want == "boolean" then
		if got == "boolean" then
			return v
		end
	elseif want == "EnumItem" and info.enumType then
		local enum = Enum[info.enumType]
		if got == "EnumItem" and v.EnumType == enum then
			return v
		elseif got == "string" then
			local ok, item = pcall(enum.FromName, enum, v)
			if ok and item then
				return item
			end
		elseif got == "number" then
			local ok, item = pcall(enum.FromValue, enum, v)
			if ok and item then
				return item
			end
		end
	elseif want == nil or got == want then
		return unwrapArg(world, v)
	end
	error(`Unable to assign property {k}. {want} expected, got {got}`, 0)
end

--// Signals

local signalMethods = {}

local function disconnect(conn)
	if not conn.connected then
		return
	end
	conn.connected = false
	for _, r in conn.reals do
		r:Disconnect()
	end
	conn.world.conns[conn] = nil
end

local function makeConnection(conn)
	local p = newproxy(true)
	local mt = getmetatable(p)
	proxyKind[p] = "RBXScriptConnection"
	local function dc()
		disconnect(conn)
	end
	mt.__index = function(_, k)
		if k == "Connected" then
			return conn.connected
		elseif k == "Disconnect" or k == "disconnect" then
			return dc
		end
		error(`{k} is not a valid member of RBXScriptConnection`, 0)
	end
	mt.__newindex = function(_, k)
		error(`{k} cannot be assigned to`, 0)
	end
	mt.__tostring = function()
		return "Connection"
	end
	setOps(mt)
	return p
end

local function dropEvent(world, a)
	if realTypeof(a) ~= "Instance" then
		return false
	end
	return shadowInfo[a] ~= nil or wrap(world, a) == nil
end

local function connect(s, fn, once)
	local world = s.world
	local conn = { connected = true, reals = {}, world = world }
	local function fire(...)
		if not conn.connected then
			return
		end
		if once then
			disconnect(conn)
		end
		fn(...)
	end
	for _, rs in s.sources do
		table.insert(
			conn.reals,
			rs:Connect(function(...)
				if not conn.connected then
					return
				end
				if dropEvent(world, (...)) then
					return
				end
				if s.filter and not s.filter(...) then
					return
				end
				fire(wrapN(world, ...))
			end)
		)
	end
	if s.loc then
		table.insert(conn.reals, localConnect(s.loc, fire))
	end
	world.conns[conn] = true
	return makeConnection(conn)
end

local function sigState(self, k)
	local s = sigStates[self]
	if not s then
		error(`Expected ':' not '.' calling member function {k}`, 0)
	end
	return s
end

local function checkFn(fn)
	if type(fn) ~= "function" then
		error("Attempt to connect failed: Passed value is not a function", 0)
	end
end

signalMethods.Connect = function(self, fn)
	local s = sigState(self, "Connect")
	checkFn(fn)
	return connect(s, fn, false)
end
signalMethods.connect = signalMethods.Connect
signalMethods.ConnectParallel = signalMethods.Connect
signalMethods.Once = function(self, fn)
	local s = sigState(self, "Once")
	checkFn(fn)
	return connect(s, fn, true)
end
signalMethods.Wait = function(self)
	local s = sigState(self, "Wait")
	local th = coroutine.running()
	connect(s, function(...)
		task.spawn(th, ...)
	end, true)
	return coroutine.yield()
end
signalMethods.wait = signalMethods.Wait

function makeSignal(world, sources, loc, filter, name)
	local p = newproxy(true)
	local mt = getmetatable(p)
	proxyKind[p] = "RBXScriptSignal"
	sigStates[p] = { world = world, sources = sources, loc = loc, filter = filter }
	mt.__index = function(_, k)
		local f = signalMethods[k]
		if f then
			return f
		end
		error(`{k} is not a valid member of RBXScriptSignal`, 0)
	end
	mt.__newindex = function(_, k)
		error(`{k} cannot be assigned to`, 0)
	end
	mt.__tostring = function()
		return name and ("Signal " .. name) or (sources[1] and tostring(sources[1]) or "Signal")
	end
	setOps(mt)
	return p
end

--// Virtual members

local function isAncestorProxy(anc, st)
	local cur = virtualParent(st)
	while cur do
		if cur == anc then
			return true
		end
		cur = virtualParent(states[cur])
	end
	return false
end

local function common(name, fn)
	ownedMethods[name] = fn
	sharedMethods[name] = fn
end

common("GetFullName", function(self)
	return virtualFullName(selfState(self, "GetFullName"))
end)
common("IsDescendantOf", function(self, other)
	local st = selfState(self, "IsDescendantOf")
	if other == nil or not states[other] then
		error("Argument 1 missing or nil", 0)
	end
	return isAncestorProxy(other, st)
end)
common("isDescendantOf", ownedMethods.IsDescendantOf)
common("IsAncestorOf", function(self, other)
	selfState(self, "IsAncestorOf")
	local ost = other ~= nil and states[other]
	if not ost then
		error("Argument 1 missing or nil", 0)
	end
	return isAncestorProxy(self, ost)
end)
local function ancestorFinder(test)
	return function(self, arg)
		local st = selfState(self, "FindFirstAncestor")
		local cur = virtualParent(st)
		while cur do
			local cst = states[cur]
			if test(cst, arg) then
				return cur
			end
			cur = virtualParent(cst)
		end
		return nil
	end
end
common("FindFirstAncestor", ancestorFinder(function(cst, name)
	return nameOf(cst) == name
end))
common("FindFirstAncestorOfClass", ancestorFinder(function(cst, class)
	return cst.real.ClassName == class
end))
common("FindFirstAncestorWhichIsA", ancestorFinder(function(cst, class)
	return cst.real:IsA(class)
end))
common("GetActor", function(self)
	selfState(self, "GetActor")
	return nil
end)

ownedGetters.Parent = virtualParent
sharedGetters.Parent = virtualParent
sharedGetters.Name = function(st)
	return nameOf(st)
end

local function ownedClone(self)
	local st = selfState(self, "Clone")
	local ok, c = pcall(st.real.Clone, st.real)
	if not ok then
		error(rewrite(st.world, c), 0)
	end
	if c == nil then
		return nil
	end
	pin(st.world, c)
	return wrap(st.world, c)
end
ownedMethods.Clone = ownedClone
ownedMethods.clone = ownedClone

local function ownedDestroy(self)
	local st = selfState(self, "Destroy")
	unpin(st.world, st.real)
	st.real:Destroy()
end
ownedMethods.Destroy = ownedDestroy
ownedMethods.destroy = ownedDestroy
local function ownedRemove(self)
	setParent(selfState(self, "Remove"), nil)
end
ownedMethods.Remove = ownedRemove
ownedMethods.remove = ownedRemove

local function mergedChildren(st)
	local world, real = st.world, st.real
	local out = {}
	if st.ov.destroyed then
		return out
	end
	for _, c in real:GetChildren() do
		if not shadowInfo[c] and not isHidden(world, c) then
			local p = wrap(world, c)
			if p then
				table.insert(out, p)
			end
		end
	end
	local sh = world.shadows[real]
	if sh then
		for _, c in sh:GetChildren() do
			local p = wrap(world, c)
			if p then
				table.insert(out, p)
			end
		end
	end
	return out
end

local function mergedDescendants(st, out)
	out = out or {}
	for _, c in mergedChildren(st) do
		table.insert(out, c)
		local cst = states[c]
		if cst.kind == "shared" then
			mergedDescendants(cst, out)
		else
			for _, d in cst.real:GetDescendants() do
				local p = wrap(st.world, d)
				if p then
					table.insert(out, p)
				end
			end
		end
	end
	return out
end

local function sharedGetChildren(self)
	return mergedChildren(selfState(self, "GetChildren"))
end
sharedMethods.GetChildren = sharedGetChildren
sharedMethods.getChildren = sharedGetChildren
sharedMethods.children = sharedGetChildren
sharedMethods.GetDescendants = function(self)
	return mergedDescendants(selfState(self, "GetDescendants"))
end

local function findIn(list, test)
	for _, c in list do
		if test(states[c]) then
			return c
		end
	end
	return nil
end

function directChild(st, name)
	local world, real = st.world, st.real
	if st.ov.destroyed then
		return nil
	end
	local fast = real:FindFirstChild(name)
	if fast and not shadowInfo[fast] and not world.overlay[fast] then
		local p = wrap(world, fast)
		if p then
			return p
		end
	end
	for _, c in real:GetChildren() do
		if not shadowInfo[c] and not isHidden(world, c) then
			local cov = world.overlay[c]
			local cname = cov and cov.props.Name
			if (if cname ~= nil then unbox(cname) else c.Name) == name then
				local p = wrap(world, c)
				if p then
					return p
				end
			end
		end
	end
	local sh = world.shadows[real]
	if sh then
		local c = sh:FindFirstChild(name)
		if c then
			return wrap(world, c)
		end
	end
	return nil
end

local function sharedFindFirstChild(self, name, recursive)
	local st = selfState(self, "FindFirstChild")
	if name == nil then
		error("Argument 1 missing or nil", 0)
	end
	name = tostring(name)
	if not recursive then
		return directChild(st, name)
	end
	return findIn(mergedDescendants(st), function(cst)
		return nameOf(cst) == name
	end)
end
sharedMethods.FindFirstChild = sharedFindFirstChild
sharedMethods.findFirstChild = sharedFindFirstChild
sharedMethods.FindFirstChildOfClass = function(self, class)
	local st = selfState(self, "FindFirstChildOfClass")
	return findIn(mergedChildren(st), function(cst)
		return cst.real.ClassName == class
	end)
end
sharedMethods.FindFirstChildWhichIsA = function(self, class, recursive)
	local st = selfState(self, "FindFirstChildWhichIsA")
	local list = recursive and mergedDescendants(st) or mergedChildren(st)
	return findIn(list, function(cst)
		return cst.real:IsA(class)
	end)
end
sharedMethods.FindFirstDescendant = function(self, name)
	local st = selfState(self, "FindFirstDescendant")
	return findIn(mergedDescendants(st), function(cst)
		return nameOf(cst) == name
	end)
end
sharedMethods.QueryDescendants = function(self, selector)
	local st = selfState(self, "QueryDescendants")
	local world, real = st.world, st.real
	local out = {}
	local ok, res = pcall(real.QueryDescendants, real, selector)
	if not ok then
		error(rewrite(world, res), 0)
	end
	for _, d in res do
		local p = not shadowInfo[d] and wrap(world, d)
		if p and states[p].kind == "shared" then
			table.insert(out, p)
		end
	end
	for shared, sh in world.shadows do
		if shared == real or shared:IsDescendantOf(real) then
			for _, d in sh:QueryDescendants(selector) do
				local p = wrap(world, d)
				if p then
					table.insert(out, p)
				end
			end
		end
	end
	return out
end

local function childAddedSignal(st)
	return signalFor(st, "ChildAdded", function()
		return makeSignal(st.world, { st.real.ChildAdded, shadowFor(st.world, st.real).ChildAdded }, nil, nil, "ChildAdded")
	end)
end
for _, ev in { "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving" } do
	sharedGetters[ev] = function(st)
		if ev == "ChildAdded" then
			return childAddedSignal(st)
		end
		return signalFor(st, ev, function()
			return makeSignal(st.world, { st.real[ev], shadowFor(st.world, st.real)[ev] }, nil, nil, ev)
		end)
	end
end

sharedMethods.WaitForChild = function(self, name, timeout)
	local st = selfState(self, "WaitForChild")
	local found = sharedFindFirstChild(self, name)
	if found then
		return found
	end
	local th = coroutine.running()
	local done = false
	local conn
	conn = childAddedSignal(st):Connect(function(child)
		if not done and nameOf(states[child]) == name then
			done = true
			conn:Disconnect()
			task.spawn(th, child)
		end
	end)
	if timeout then
		task.delay(timeout, function()
			if not done then
				done = true
				conn:Disconnect()
				task.spawn(th, nil)
			end
		end)
	else
		task.delay(5, function()
			if not done and st.world.warn then
				st.world.warn(`Infinite yield possible on '{virtualFullName(st)}:WaitForChild("{name}")'`)
			end
		end)
	end
	return coroutine.yield()
end

local function sharedDestroy(self)
	local st = selfState(self, "Destroy")
	if st.real == realGame or isService(st.real) or st.real:IsA("Terrain") then
		local parent = virtualParent(st)
		error(
			`The Parent property of {nameOf(st)} is locked, current parent: {parent and nameOf(states[parent]) or "NULL"}, new parent NULL`,
			0
		)
	end
	st.ov.destroyed = true
end
sharedMethods.Destroy = sharedDestroy
sharedMethods.destroy = sharedDestroy
sharedMethods.Remove = sharedDestroy
sharedMethods.remove = sharedDestroy

sharedMethods.ClearAllChildren = function(self)
	local st = selfState(self, "ClearAllChildren")
	local world = st.world
	local sh = world.shadows[st.real]
	if sh then
		sh:ClearAllChildren()
	end
	for _, c in st.real:GetChildren() do
		if not shadowInfo[c] and not isService(c) and not c:IsA("Terrain") then
			ovFor(world, c).destroyed = true
		end
	end
end

local function sharedClone(self)
	local st = selfState(self, "Clone")
	local world = st.world
	local ok, c = pcall(st.real.Clone, st.real)
	if not ok then
		error(replacePlain(rewrite(world, c), st.real.Name, nameOf(st)), 0)
	end
	if c == nil then
		return nil
	end
	for k, v in st.ov.props do
		pcall(setIndex, c, k, unbox(v))
	end
	for k, v in st.ov.attrs do
		pcall(c.SetAttribute, c, k, unbox(v))
	end
	pin(world, c)
	return wrap(world, c)
end
sharedMethods.Clone = sharedClone
sharedMethods.clone = sharedClone

sharedGetters.Changed = function(st)
	return signalFor(st, "Changed", function()
		local b = baselineProps[st.real]
		return makeSignal(st.world, { st.real.Changed }, st.ov.changed, function(prop)
			return not (b and b[prop] ~= nil) and st.ov.props[prop] == nil
		end, "Changed")
	end)
end

sharedMethods.GetPropertyChangedSignal = function(self, prop)
	local st = selfState(self, "GetPropertyChangedSignal")
	local ok, real = pcall(st.real.GetPropertyChangedSignal, st.real, prop)
	if not ok then
		error(rewrite(st.world, real), 0)
	end
	return signalFor(st, "prop:" .. prop, function()
		local ps = st.ov.propSignals[prop]
		if not ps then
			ps = newLocal()
			st.ov.propSignals[prop] = ps
		end
		local b = baselineProps[st.real]
		local frozen = b and b[prop] ~= nil
		return makeSignal(st.world, frozen and {} or { real }, ps, function()
			return st.ov.props[prop] == nil
		end, "Changed")
	end)
end

local attrScratch = realInstance.new("Folder")

sharedMethods.SetAttribute = function(self, name, value)
	local st = selfState(self, "SetAttribute")
	local ok, err = pcall(attrScratch.SetAttribute, attrScratch, name, unwrapArg(st.world, value))
	attrScratch:SetAttribute(tostring(name), nil)
	if not ok then
		error(err, 0)
	end
	st.ov.attrs[name] = box(value)
	localFire(st.ov.attrChanged, name)
	local s = st.ov.attrSignals[name]
	if s then
		localFire(s)
	end
end
sharedMethods.GetAttribute = function(self, name)
	local st = selfState(self, "GetAttribute")
	local v = st.ov.attrs[name]
	if v ~= nil then
		return unbox(v)
	end
	return st.real:GetAttribute(name)
end
sharedMethods.GetAttributes = function(self)
	local st = selfState(self, "GetAttributes")
	local out = st.real:GetAttributes()
	for k, v in st.ov.attrs do
		out[k] = unbox(v)
	end
	return out
end
sharedGetters.AttributeChanged = function(st)
	return signalFor(st, "AttributeChanged", function()
		return makeSignal(st.world, { st.real.AttributeChanged }, st.ov.attrChanged, function(name)
			return st.ov.attrs[name] == nil
		end, "AttributeChanged")
	end)
end
sharedMethods.GetAttributeChangedSignal = function(self, name)
	local st = selfState(self, "GetAttributeChangedSignal")
	return signalFor(st, "attr:" .. tostring(name), function()
		local s = st.ov.attrSignals[name]
		if not s then
			s = newLocal()
			st.ov.attrSignals[name] = s
		end
		return makeSignal(st.world, { st.real:GetAttributeChangedSignal(name) }, s, function()
			return st.ov.attrs[name] == nil
		end, "Changed")
	end)
end

local function sharedHasTag(st, tag)
	local v = st.ov.tags[tag]
	if v ~= nil then
		return v
	end
	return st.real:HasTag(tag)
end
sharedMethods.AddTag = function(self, tag)
	selfState(self, "AddTag").ov.tags[tag] = true
end
sharedMethods.RemoveTag = function(self, tag)
	selfState(self, "RemoveTag").ov.tags[tag] = false
end
sharedMethods.HasTag = function(self, tag)
	return sharedHasTag(selfState(self, "HasTag"), tag)
end
sharedMethods.GetTags = function(self)
	local st = selfState(self, "GetTags")
	local set = {}
	for _, t in st.real:GetTags() do
		set[t] = true
	end
	for t, v in st.ov.tags do
		set[t] = v or nil
	end
	local out = {}
	for t in set do
		table.insert(out, t)
	end
	return out
end

local function tagTarget(self, inst, k)
	local st = selfState(self, k)
	local ist = inst ~= nil and states[inst]
	if not ist then
		error("Argument 1 missing or nil", 0)
	end
	return st, ist
end
serviceMethods.CollectionService = {
	AddTag = function(self, inst, tag)
		local _, ist = tagTarget(self, inst, "AddTag")
		if ist.kind == "shared" then
			ist.ov.tags[tag] = true
		else
			ist.real:AddTag(tag)
		end
	end,
	RemoveTag = function(self, inst, tag)
		local _, ist = tagTarget(self, inst, "RemoveTag")
		if ist.kind == "shared" then
			ist.ov.tags[tag] = false
		else
			ist.real:RemoveTag(tag)
		end
	end,
	HasTag = function(self, inst, tag)
		local _, ist = tagTarget(self, inst, "HasTag")
		if ist.kind == "shared" then
			return sharedHasTag(ist, tag)
		end
		return ist.real:HasTag(tag)
	end,
	GetTags = function(self, inst)
		local _, ist = tagTarget(self, inst, "GetTags")
		if ist.kind == "shared" then
			return sharedMethods.GetTags(ist.proxy)
		end
		return ist.real:GetTags()
	end,
	GetTagged = function(self, tag)
		local st = selfState(self, "GetTagged")
		local world = st.world
		local out = {}
		for _, inst in st.real:GetTagged(tag) do
			local p = wrap(world, inst)
			if p then
				local pst = states[p]
				if pst.kind ~= "shared" or sharedHasTag(pst, tag) then
					table.insert(out, p)
				end
			end
		end
		for real, ov in world.overlay do
			if ov.tags[tag] and not real:HasTag(tag) then
				local p = wrap(world, real)
				if p then
					table.insert(out, p)
				end
			end
		end
		return out
	end,
}

--// Context

local Context = {}
Context.__index = Context

function Sandbox.getWorld(userId)
	local key = tostring(userId)
	local w = worlds[key]
	if w then
		return w
	end
	w = setmetatable({
		id = key,
		proxies = setmetatable({}, { __mode = "kv" }),
		overlay = {},
		shadows = {},
		shadowCount = 0,
		pinned = {},
		shared = {},
		conns = {},
		rewrites = {},
		live = 0,
	}, World)
	w.root = realInstance.new("Folder")
	w.root.Name = "__sbx_" .. key
	w.ws = realInstance.new("WorldModel")
	w.ws.Name = "__ws_" .. key
	rootWorld[w.root] = w
	rootWorld[w.ws] = w
	shadowInfo[w.ws] = { world = w, shared = realWorkspace }
	w.shadows[realWorkspace] = w.ws
	w.ws.Parent = realWorkspace
	addRewrite(w, w.ws:GetFullName(), "Workspace")
	worlds[key] = w
	return w
end

function World:idle()
	for conn in self.conns do
		disconnect(conn)
	end
	for inst in self.pinned do
		rootWorld[inst] = nil
	end
	table.clear(self.pinned)
end

function World:newContext(hooks, env)
	self.live += 1
	local ctx = setmetatable({ world = self, hooks = hooks, env = env, modules = {} }, Context)
	if hooks.onCleanup then
		table.insert(hooks.onCleanup, function()
			ctx:destroy()
		end)
	end
	return ctx
end

function Context:destroy()
	if self.dead then
		return
	end
	self.dead = true
	local world = self.world
	world.live -= 1
	if world.live <= 0 then
		world.live = 0
		world:idle()
	end
end

function Context:wrap(v)
	return copyWrap(self.world, v)
end

function Context:unwrap(v)
	return unwrapDeep(self.world, v)
end

function Context:apply(env)
	local world = self.world
	local hooks = self.hooks
	local g = wrap(world, realGame)
	local ws = wrap(world, realWorkspace)
	world.warn = env.warn
	env.game = g
	env.Game = g
	env.workspace = ws
	env.Workspace = ws
	if hooks.module then
		env.script = wrap(world, hooks.module)
	end
	env.typeof = sandboxTypeof
	env.shared = world.shared
	env.Instance = table.freeze({
		new = function(className, parent)
			local ok, inst = pcall(realInstance.new, className)
			if not ok then
				error(inst, 0)
			end
			pin(world, inst)
			local p = wrap(world, inst)
			if parent ~= nil then
				setParent(states[p], parent)
			end
			return p
		end,
		fromExisting = function(existing)
			local ok, inst = pcall(realInstance.fromExisting, unwrapArg(world, existing))
			if not ok then
				error(inst, 0)
			end
			pin(world, inst)
			return wrap(world, inst)
		end,
	})
	env.stats = function()
		return wrap(world, realStats())
	end
	env.settings = function()
		return wrap(world, realSettings())
	end
	env.UserSettings = function()
		return wrap(world, realUserSettings())
	end
	local modules = self.modules
	env.require = function(target)
		local st = states[target]
		if st and st.kind == "owned" and st.real:IsA("ModuleScript") and hooks.execute then
			local real = st.real
			local cached = modules[real]
			if cached == NIL then
				error("Requested module was required recursively", 0)
			elseif cached ~= nil then
				return unbox(cached)
			end
			modules[real] = NIL
			local modEnv = table.clone(env)
			modEnv.script = target
			local fx, err = hooks.execute(real.Name, real.Source, modEnv)
			if not fx then
				modules[real] = nil
				error("Requested module experienced an error while loading", 0)
			end
			local res = table.pack(pcall(fx))
			if not res[1] then
				modules[real] = nil
				error(res[2], 0)
			end
			if res.n ~= 2 then
				modules[real] = nil
				error("Module code did not return exactly one value", 0)
			end
			modules[real] = box(res[2])
			return res[2]
		end
		return copyWrap(world, realRequire(unwrapArg(world, target)))
	end
	local thread = env.thread
	if type(thread) == "table" then
		local script = env.script
		env.thread = setmetatable({}, {
			__index = function(_, k)
				if k == "module" then
					return script
				end
				return thread[k]
			end,
			__newindex = function(_, k, v)
				if k ~= "module" then
					thread[k] = v
				end
			end,
			__iter = function()
				return next, thread
			end,
		})
	end
end

function Sandbox.disabled(env, userId)
	env.shared = Sandbox.getWorld(userId).shared
	if env.warn then
		env.warn("[WARNING] Sandbox disabled: changes are visible to other users")
	end
end

Sandbox.typeof = sandboxTypeof
Sandbox._states = states
Sandbox._worlds = worlds

return Sandbox
