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
local realPluginManager = PluginManager
local realRaycastParams = RaycastParams
local realOverlapParams = OverlapParams
local infrastructureCheck = type(native) == "table" and native.isSessionInfrastructure
local function isInfrastructure(instance)
	return infrastructureCheck ~= nil and infrastructureCheck(instance)
end
local function checkInfrastructure(instance)
	assert(not isInfrastructure(instance), "worker infrastructure is not accessible in the sandbox")
end
-- Referencing this drops inlining in this module only, never in user code (accepted).
local realGetfenv = getfenv

local LOCKED = "The metatable is locked"
local NIL = newproxy(false)
local WORLDROOT_EXTRA = { GetBoundingBox = true, GetExtentsSize = true }

local Sandbox = {}

local states = setmetatable({}, { __mode = "k" })
local proxyKind = setmetatable({}, { __mode = "k" })
local dtReal = setmetatable({}, { __mode = "k" })
local sigStates = setmetatable({}, { __mode = "k" })
local rootWorld = {}
local shadowInfo = {}
local worlds = {}
-- Extension definitions belong to a context, not to the VM or shared class cache.
local extensionOwners = {}
local function attachExtensions(context, root)
	local function attach(instance)
		extensionOwners[instance] = context
		context.extensionInstances[instance] = true
	end
	attach(root)
	for _, instance in root:GetDescendants() do attach(instance) end
end

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
	if ls.onConnect then
		ls.onConnect()
	end
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
	if isInfrastructure(real) then return true end
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
local serviceGetters = {}
local MOCKED = { DataStoreService = true, MemoryStoreService = true, MessagingService = true }
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
		checkInfrastructure(st.real)
		return st.real
	end
	local dt = dtReal[v]
	if dt then
		return dt
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
		checkInfrastructure(st.real)
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
	if out and table.isfrozen(v) then
		table.freeze(out)
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
		local cache = world.signalCache
		local p = cache[v]
		if not p then
			p = makeSignal(world, { v })
			cache[v] = p
		end
		return p
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
	checkInfrastructure(st.real)
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
	local className = if st.fake then st.fake.className else st.real.ClassName
	error(`{k} is not a valid member of {className} "{virtualFullName(st)}"`, 0)
end

--// Script Source and Enabled
-- On a headless Studio worker a game Script can't read or write Source, and an enabled Script a
-- run parents into the place would run unsandboxed (Open Cloud never runs them). So Source lives
-- here when the engine refuses it, and Enabled always does: real Scripts are switched off first.
local virtualSource = setmetatable({}, { __mode = "k" })
local virtualEnabled = setmetatable({}, { __mode = "k" })

local function sourceOf(real)
	local own = virtualSource[real]
	if own ~= nil then
		return own
	end
	-- Scripts a run imported belong to its broker, which can read them.
	local context = extensionOwners[real]
	local read = context and not context.dead and context.hooks and context.hooks.readSource
	if read then
		local ok, source = pcall(read, real)
		if ok and type(source) == "string" then
			return source
		end
	end
	local ok, source = pcall(index, real, "Source")
	return if ok then source else ""
end

local function setSource(real, v)
	if type(v) ~= "string" then
		error(`Unable to assign property Source. string expected, got {typeName(v)}`, 0)
	end
	if pcall(setIndex, real, "Source", v) then
		virtualSource[real] = nil
	else
		virtualSource[real] = v
	end
end

local function enabledOf(real)
	local own = virtualEnabled[real]
	if own == nil then
		return real.Enabled
	end
	return own
end

local function setEnabled(real, v)
	if type(v) ~= "boolean" then
		error(`Unable to assign property Enabled. bool expected, got {typeName(v)}`, 0)
	end
	virtualEnabled[real] = v
end

local function disableScripts(real)
	if not (real:IsA("BaseScript") or real:FindFirstChildWhichIsA("BaseScript", true)) then
		return
	end
	local tree = real:GetDescendants()
	table.insert(tree, real)
	for _, instance in tree do
		if instance:IsA("BaseScript") and instance.Enabled then
			if virtualEnabled[instance] == nil then
				virtualEnabled[instance] = true
			end
			instance.Enabled = false
		end
	end
end

-- Carries a tree's own Source and Enabled to its clone, pairing children the way Clone copies them.
local function copyVirtual(original, copy)
	if original:IsA("LuaSourceContainer") then
		virtualSource[copy] = virtualSource[original] or (if extensionOwners[original] then sourceOf(original) else nil)
		virtualEnabled[copy] = virtualEnabled[original]
	end
	local children, i = copy:GetChildren(), 1
	for _, child in original:GetChildren() do
		if child.Archivable then
			local cloned = children[i]
			if not cloned or cloned.ClassName ~= child.ClassName then
				return
			end
			copyVirtual(child, cloned)
			i += 1
		end
	end
end

-- luau_native adds these to every Instance; they leak the real full name and memory address.
local NATIVE_MEMBERS = table.freeze({ GetNativeInfo = true, CountDescendants = true, NativeAddress = true })

local function slowIndex(st, k)
	local world, real = st.world, st.real
	if NATIVE_MEMBERS[k] then
		memberError(st, k)
	end
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
		disableScripts(real)
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

-- Shared-instance writes apply this world's overlay to the real one, write, and restore it without
-- yielding, so the engine handles linked props (ClockTime/TimeOfDay) and validation unobserved.
local CAPTURE_METHODS = { Lighting = true }

local function readWritable(real, class)
	local values = {}
	for name, info in class.props do
		if info.write and name ~= "Parent" then
			local ok, v = pcall(index, real, name)
			if ok then
				values[name] = box(v)
			end
		end
	end
	return values
end

local function withVirtual(st, fn, ...)
	local real, class, ov = st.real, st.class, st.ov
	local original = readWritable(real, class)
	for name, v in ov.props do
		pcall(setIndex, real, name, unbox(v))
	end
	local before = readWritable(real, class)
	local result = table.pack(pcall(fn, real, ...))
	local after = readWritable(real, class)
	for name, v in original do
		pcall(setIndex, real, name, unbox(v))
	end
	if not result[1] then
		error(rewrite(st.world, result[2]), 0)
	end
	for name, v in after do
		if v ~= before[name] then
			ov.props[name] = v
			localFire(ov.changed, name)
			local ps = ov.propSignals[name]
			if ps then
				localFire(ps)
			end
		end
	end
	return table.unpack(result, 2, result.n)
end

local captureCache = {}
local function captureMethodWrapper(k)
	local m = captureCache[k]
	if m then
		return m
	end
	m = function(self, ...)
		local st = selfState(self, k)
		local world = st.world
		return wrapN(world, withVirtual(st, function(real, ...)
			return real[k](real, ...)
		end, unwrapN(world, ...)))
	end
	captureCache[k] = m
	return m
end

-- Mock engine-only classes (LocalPlayer, its PlayerGui) are real instances underneath: the proxy
-- reports the stand-in class and members, and the rest is the real one's.
local function fakeIsA(self, class)
	return selfState(self, "IsA").fake.classes[class] == true
end

local extensionBases = {}
local function extensionFor(st, name)
	if st.kind ~= "owned" then return nil end
	local context = extensionOwners[st.real]
	if not context or context.dead then return nil end
	local className = st.real.ClassName
	while className do
		local members = context.extensions[className]
		if members and members[name] then return members[name], context end
		local base = extensionBases[className]
		if base == nil then
			local reflected = ReflectionService:GetClass(className)
			base = reflected and reflected.Superclass or false
			extensionBases[className] = base
		end
		className = base or nil
	end
	return nil
end

local function makeProxy(world, real, kind)
	local p = newproxy(true)
	local mt = getmetatable(p)
	local class = getClass(real.ClassName)
	local fake = world.fakes[real]
	local st = { real = real, world = world, kind = kind, class = class, proxy = p, fake = fake }
	states[p] = st
	proxyKind[p] = "Instance"
	local props, methods = class.props, class.methods
	if kind == "owned" then
		mt.__index = function(_, k)
			checkInfrastructure(real)
			if fake then
				if k == "ClassName" then
					return fake.className
				elseif k == "IsA" or k == "isA" then
					return fakeIsA
				end
				local g = fake.get[k]
				if g then
					return g(st)
				end
				local fm = fake.methods[k]
				if fm then
					return fm
				end
			end
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
			if not st.class.events[k] then
				local extension = extensionFor(st, k)
				if extension then
					if extension.method then return extension.method end
					return extension.get(p)
				end
			end
			if fake then
				local child = real:FindFirstChild(k)
				if child then
					return wrap(world, child)
				end
				memberError(st, k)
			end
			return slowIndex(st, k)
		end
		mt.__newindex = function(_, k, v)
			checkInfrastructure(real)
			if fake and (fake.get[k] or k == "Parent") then
				error(`Unable to assign property {k}. Property is read only`, 0)
			end
			if k == "Parent" then
				return setParent(st, v)
			end
			if k == "Source" and real:IsA("LuaSourceContainer") then
				return setSource(real, v)
			elseif k == "Enabled" and real:IsA("BaseScript") then
				return setEnabled(real, v)
			elseif k == "Disabled" and real:IsA("BaseScript") then
				return setEnabled(real, if type(v) == "boolean" then not v else v)
			end
			if not props[k] and not methods[k] and not st.class.events[k] then
				local extension = extensionFor(st, k)
				if extension then
					if not extension.set then error(`Unable to assign property {k}. Property is read only`, 0) end
					return extension.set(p, v)
				end
			end
			local ok, err = pcall(setIndex, real, k, unwrapArg(world, v))
			if not ok then
				error(rewrite(world, err), 0)
			end
		end
	else
		st.ov = ovFor(world, real)
		local svc = serviceMethods[real.ClassName]
		local sgets = serviceGetters[real.ClassName]
		local mocked = MOCKED[real.ClassName]
		local isWs = real == realWorkspace
		mt.__index = function(_, k)
			checkInfrastructure(real)
			if sgets then
				local g = sgets[k]
				if g then
					return g(st)
				end
			end
			if svc then
				local m = svc[k]
				if m then
					return m
				end
				if mocked and methods[k] then
					error(`{k} is not available in the sandbox`, 0)
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
				if CAPTURE_METHODS[real.ClassName] and not string.find(k, "Async$") then
					return captureMethodWrapper(k)
				end
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
			checkInfrastructure(real)
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
			local value = unwrapArg(world, v)
			withVirtual(st, function(r)
				r[k] = value
			end)
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
	if isInfrastructure(real) then return nil end
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
		-- Hide a headless worker's runner Script (not Archivable, so LuauBot's boot reset keeps it).
		if real:IsA("LuaSourceContainer") and not real.Archivable then
			return nil
		end
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

-- the engine disconnects real connections on Destroy; follow it
local function isConnected(conn)
	if not conn.connected then
		return false
	end
	local hasReal = false
	for _, r in conn.reals do
		if realTypeof(r) == "RBXScriptConnection" then
			if r.Connected then
				return true
			end
			hasReal = true
		end
	end
	if hasReal then
		disconnect(conn)
		return false
	end
	return true
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
			return isConnected(conn)
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
	-- engine deliveries only honour an explicit Disconnect: deferred events like Destroying
	-- arrive after the engine has already dropped the real connection
	local function deliver(...)
		if not conn.connected then
			return
		end
		if once then
			disconnect(conn)
		end
		-- a running or waiting handler keeps the run alive; one that errored is dead and stops counting
		local co = coroutine.running()
		world.handlers[co] = true
		fn(...)
		world.handlers[co] = nil
	end
	local function fire(...)
		if isConnected(conn) then
			deliver(...)
		end
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
				deliver(wrapN(world, ...))
			end)
		)
	end
	if s.loc then
		table.insert(conn.reals, localConnect(s.loc, fire))
	end
	table.insert(conn.reals, localConnect(s.fire, fire))
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

-- the engine accepts any value and hands back an already-disconnected connection
local function deadConnection(s)
	return makeConnection({ connected = false, reals = {}, world = s.world })
end

signalMethods.Connect = function(self, fn)
	local s = sigState(self, "Connect")
	if type(fn) ~= "function" then
		return deadConnection(s)
	end
	return connect(s, fn, false)
end
signalMethods.connect = signalMethods.Connect
signalMethods.ConnectParallel = signalMethods.Connect
signalMethods.Once = function(self, fn)
	local s = sigState(self, "Once")
	if type(fn) ~= "function" then
		return deadConnection(s)
	end
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
	sigStates[p] = { world = world, sources = sources, loc = loc, filter = filter, fire = newLocal() }
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
-- Like the engine, nil isn't an error: everything descends from nil and nothing is its ancestor
-- (UI libraries pass the object under the mouse, which can be nil).
common("IsDescendantOf", function(self, other)
	local st = selfState(self, "IsDescendantOf")
	if other == nil then
		return true
	elseif not states[other] then
		error("Unable to cast value to Object", 0)
	end
	return isAncestorProxy(other, st)
end)
common("isDescendantOf", ownedMethods.IsDescendantOf)
common("IsAncestorOf", function(self, other)
	selfState(self, "IsAncestorOf")
	if other == nil then
		return false
	end
	local ost = states[other]
	if not ost then
		error("Unable to cast value to Object", 0)
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
	if st.real:IsA("LuaSourceContainer") or st.real:FindFirstChildWhichIsA("LuaSourceContainer", true) then
		copyVirtual(st.real, c)
	end
	local context = extensionOwners[st.real]
	if context and not context.dead then attachExtensions(context, c) end
	return wrap(st.world, c)
end
-- the engine hands out a new signal object per call; one proxy per name keeps firesignal working
local function ownedSignalGetter(k, prefix)
	return function(self, name)
		local st = selfState(self, k)
		local ok, real = pcall(st.real[k], st.real, name)
		if not ok then
			error(rewrite(st.world, real), 0)
		end
		return signalFor(st, prefix .. tostring(name), function()
			return makeSignal(st.world, { real })
		end)
	end
end
ownedMethods.GetPropertyChangedSignal = ownedSignalGetter("GetPropertyChangedSignal", "prop:")
ownedMethods.GetAttributeChangedSignal = ownedSignalGetter("GetAttributeChangedSignal", "attr:")
ownedMethods.Clone = ownedClone
ownedMethods.clone = ownedClone
ownedGetters.Source = function(st)
	if st.real:IsA("LuaSourceContainer") then
		return sourceOf(st.real)
	end
	return slowIndex(st, "Source")
end
ownedGetters.Enabled = function(st)
	if st.real:IsA("BaseScript") then
		return enabledOf(st.real)
	end
	return slowIndex(st, "Enabled")
end
ownedGetters.Disabled = function(st)
	if st.real:IsA("BaseScript") then
		return not enabledOf(st.real)
	end
	return slowIndex(st, "Disabled")
end

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
		error(`The Parent property of {nameOf(st)} is locked`, 0)
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

--// Mock stores (sandbox only; data lasts as long as the user's world)

local HttpService = realGame:GetService("HttpService")
local InsertService = realGame:GetService("InsertService")
local virtualStates = setmetatable({}, { __mode = "k" })
local MAX_EXPIRATION = 3888000
local MAX_VALUE = 4 * 1024 * 1024

local function vstate(self, k)
	local vs = virtualStates[self]
	if not vs then
		error(`Expected ':' not '.' calling member function {k}`, 0)
	end
	return vs
end

local function virtualIsA(self, class)
	return vstate(self, "IsA").classes[class] == true
end

local function makeVirtual(world, className, name, members, props, bases)
	local p = newproxy(true)
	local mt = getmetatable(p)
	local classes = { Instance = true, [className] = true }
	for _, b in bases or {} do
		classes[b] = true
	end
	props = props or {}
	virtualStates[p] = { world = world, classes = classes }
	proxyKind[p] = "Instance"
	mt.__index = function(_, k)
		if k == "ClassName" then
			return className
		elseif k == "Name" then
			return name
		elseif k == "Parent" then
			return nil
		elseif k == "IsA" or k == "isA" then
			return virtualIsA
		end
		local m = members[k]
		if m ~= nil then
			return m
		end
		local v = props[k]
		if type(v) == "function" then
			return v()
		elseif v ~= nil then
			return v
		end
		error(`{k} is not a valid member of {className} "{name}"`, 0)
	end
	mt.__newindex = function(_, k)
		error(`Unable to assign property {k}. Property is read only`, 0)
	end
	mt.__tostring = function()
		return name
	end
	setOps(mt)
	return p
end

local function method(k, fn)
	return function(self, ...)
		vstate(self, k)
		return fn(...)
	end
end

local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function checkStorable(v, seen)
	local t = typeName(v)
	if t == "nil" or t == "boolean" or t == "buffer" then
		return
	elseif t == "string" then
		if not utf8.len(v) then
			error("104: Cannot store string in data store. Data stores can only accept valid UTF-8 characters.", 0)
		end
		return
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			error("104: Cannot store NaN or infinite numbers in data store.", 0)
		end
		return
	elseif t == "table" then
		if seen[v] then
			error("104: Cannot store tables with cyclic references in data store.", 0)
		end
		seen[v] = true
		local n, count = #v, 0
		for k, x in v do
			count += 1
			local tk = type(k)
			if tk == "number" then
				if k ~= math.floor(k) or k < 1 or k > n then
					error("104: Cannot store Array with non-sequential indices in data store.", 0)
				end
			elseif tk ~= "string" then
				error(`104: Cannot store table with {tk} keys in data store.`, 0)
			end
			checkStorable(x, seen)
		end
		if n > 0 and count ~= n then
			error("104: Cannot store mixed tables in data store.", 0)
		end
		seen[v] = nil
		return
	end
	error(`104: Cannot store {t} in data store. Data stores can only accept valid UTF-8 characters.`, 0)
end

local function storable(v, limit)
	checkStorable(v, {})
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, v)
	if ok and #encoded > limit then
		error(`105: Serialized value exceeds {math.floor(limit / 1024)} KB limit.`, 0)
	end
	return deepCopy(v)
end

local function checkKey(key, what)
	if key == nil then
		error("Argument 1 missing or nil", 0)
	end
	key = tostring(key)
	if #key == 0 then
		error(`101: {what} can't be empty.`, 0)
	elseif #key > 50 then
		error(`101: {what} exceeds the 50 character limit.`, 0)
	end
	return key
end

local function storeRoot(world)
	local s = world.stores
	if not s then
		s = { data = {}, hash = {}, sorted = {}, queues = {}, topics = {}, version = 0 }
		world.stores = s
	end
	return s
end

local function paginate(items, pageSize)
	local pages, cur = {}, {}
	for _, it in items do
		table.insert(cur, it)
		if #cur >= pageSize then
			table.insert(pages, cur)
			cur = {}
		end
	end
	if #cur > 0 or #pages == 0 then
		table.insert(pages, cur)
	end
	return pages
end

local function makePages(world, className, pages)
	local i = 1
	return makeVirtual(world, className, className, {
		GetCurrentPage = method("GetCurrentPage", function()
			return table.clone(pages[i] or {})
		end),
		AdvanceToNextPageAsync = method("AdvanceToNextPageAsync", function()
			task.wait()
			if i < #pages then
				i += 1
			end
		end),
	}, {
		IsFinished = function()
			return i >= #pages
		end,
	}, { "Pages" })
end

local function nowMs()
	return DateTime.now().UnixTimestampMillis
end

local function keyInfo(world, e, version)
	return makeVirtual(world, "DataStoreKeyInfo", "DataStoreKeyInfo", {
		GetUserIds = method("GetUserIds", function()
			return table.clone(e.userIds or {})
		end),
		GetMetadata = method("GetMetadata", function()
			return deepCopy(e.metadata or {})
		end),
	}, { Version = version or e.version, CreatedTime = e.created, UpdatedTime = e.updated })
end

local function optionMetadata(options)
	if options == nil then
		return nil
	end
	local ok, md = pcall(function()
		return options:GetMetadata()
	end)
	return ok and md or nil
end

local function makeDataStore(world, name, ordered)
	local root = storeRoot(world)
	local data = {}
	local function nextVersion()
		root.version += 1
		return string.format("%016X", root.version)
	end
	local function write(key, value, userIds, metadata)
		local now = nowMs()
		local e = data[key]
		if not e then
			e = { created = now, versions = {} }
			data[key] = e
		end
		e.value, e.version, e.updated, e.deleted = value, nextVersion(), now, false
		e.userIds = userIds and table.clone(userIds) or nil
		e.metadata = metadata and deepCopy(metadata) or nil
		table.insert(e.versions, { version = e.version, created = now, value = value, deleted = false })
		return e
	end
	local function value(v)
		if ordered then
			if type(v) ~= "number" or v ~= math.floor(v) then
				error("OrderedDataStore can only store integers.", 0)
			end
			return v
		end
		return storable(v, MAX_VALUE)
	end
	local function live(key)
		local e = data[key]
		if e and not e.deleted then
			return e
		end
		return nil
	end
	local function info(e)
		if ordered or e == nil then
			return nil
		end
		return keyInfo(world, e)
	end

	local members = {}
	members.GetAsync = method("GetAsync", function(key)
		key = checkKey(key, "Key name")
		task.wait()
		local e = live(key)
		if not e then
			return nil, nil
		end
		return deepCopy(e.value), info(e)
	end)
	members.SetAsync = method("SetAsync", function(key, v, userIds, options)
		key = checkKey(key, "Key name")
		v = value(v)
		task.wait()
		return write(key, v, userIds, optionMetadata(options)).version
	end)
	members.UpdateAsync = method("UpdateAsync", function(key, fn)
		key = checkKey(key, "Key name")
		if type(fn) ~= "function" then
			error("Argument 2 missing or nil", 0)
		end
		task.wait()
		local e = live(key)
		local new, userIds, metadata = fn(e and deepCopy(e.value), info(e))
		if new == nil then
			return nil
		end
		local ne = write(key, value(new), userIds, metadata)
		return deepCopy(ne.value), info(ne)
	end)
	members.IncrementAsync = method("IncrementAsync", function(key, delta, userIds)
		key = checkKey(key, "Key name")
		delta = if delta == nil then 1 else tonumber(delta)
		if not delta then
			error("Unable to cast value to int", 0)
		end
		task.wait()
		local e = live(key)
		local cur = e and e.value or 0
		if type(cur) ~= "number" then
			error("102: Cannot increment a non-numeric value.", 0)
		end
		local ne = write(key, cur + math.floor(delta), userIds, e and e.metadata)
		return ne.value, info(ne)
	end)
	members.RemoveAsync = method("RemoveAsync", function(key)
		key = checkKey(key, "Key name")
		task.wait()
		local e = live(key)
		if not e then
			return nil, nil
		end
		local old, oldInfo = deepCopy(e.value), info(e)
		e.deleted = true
		table.insert(e.versions, { version = nextVersion(), created = nowMs(), deleted = true })
		return old, oldInfo
	end)
	if ordered then
		members.GetSortedAsync = method("GetSortedAsync", function(ascending, pageSize, minValue, maxValue)
			pageSize = tonumber(pageSize)
			if not pageSize or pageSize < 1 or pageSize > 100 then
				error("PageSize must be within a predefined range of 1 to 100.", 0)
			end
			task.wait()
			local items = {}
			for k, e in data do
				if
					not e.deleted
					and (minValue == nil or e.value >= minValue)
					and (maxValue == nil or e.value <= maxValue)
				then
					table.insert(items, { key = k, value = e.value })
				end
			end
			table.sort(items, function(a, b)
				if a.value == b.value then
					return a.key < b.key
				end
				if ascending then
					return a.value < b.value
				end
				return a.value > b.value
			end)
			return makePages(world, "DataStorePages", paginate(items, pageSize))
		end)
	else
		members.ListKeysAsync = method("ListKeysAsync", function(prefix, pageSize, _, excludeDeleted)
			task.wait()
			local keys = {}
			for k, e in data do
				if (prefix == nil or k:sub(1, #prefix) == prefix) and not (excludeDeleted and e.deleted) then
					table.insert(keys, k)
				end
			end
			table.sort(keys)
			local items = {}
			for _, k in keys do
				table.insert(items, makeVirtual(world, "DataStoreKey", "DataStoreKey", {}, { KeyName = k }))
			end
			return makePages(world, "DataStoreKeyPages", paginate(items, tonumber(pageSize) or 50))
		end)
		members.GetVersionAsync = method("GetVersionAsync", function(key, version)
			key = checkKey(key, "Key name")
			task.wait()
			local e = data[key]
			for _, v in e and e.versions or {} do
				if v.version == version then
					if v.deleted then
						return nil, nil
					end
					return deepCopy(v.value), keyInfo(world, e, v.version)
				end
			end
			return nil, nil
		end)
		members.ListVersionsAsync = method("ListVersionsAsync", function(key, sortDirection, minDate, maxDate, pageSize)
			key = checkKey(key, "Key name")
			task.wait()
			local e = data[key]
			local items = {}
			for _, v in e and e.versions or {} do
				local afterMin = minDate == nil or minDate == 0 or v.created >= minDate
				local beforeMax = maxDate == nil or maxDate == 0 or v.created <= maxDate
				if afterMin and beforeMax then
					table.insert(
						items,
						makeVirtual(world, "DataStoreObjectVersionInfo", "DataStoreObjectVersionInfo", {}, {
							Version = v.version,
							CreatedTime = v.created,
							IsDeleted = v.deleted,
						})
					)
				end
			end
			if sortDirection == Enum.SortDirection.Descending then
				local reversed = {}
				for i = #items, 1, -1 do
					table.insert(reversed, items[i])
				end
				items = reversed
			end
			return makePages(world, "DataStoreVersionPages", paginate(items, tonumber(pageSize) or 1))
		end)
	end
	return makeVirtual(world, ordered and "OrderedDataStore" or "DataStore", name, members, {}, { "GlobalDataStore" })
end

local function getStore(self, k, name, scope, ordered)
	local world = selfState(self, k).world
	local root = storeRoot(world)
	name = checkKey(name, "DataStore name")
	scope = if scope == nil then "global" else tostring(scope)
	local id = (ordered and "o\0" or "d\0") .. name .. "\0" .. scope
	local s = root.data[id]
	if not s then
		s = { proxy = makeDataStore(world, name, ordered), name = name, ordered = ordered, created = nowMs() }
		root.data[id] = s
	end
	return s.proxy
end

serviceMethods.DataStoreService = {
	GetDataStore = function(self, name, scope)
		return getStore(self, "GetDataStore", name, scope, false)
	end,
	GetGlobalDataStore = function(self)
		return getStore(self, "GetGlobalDataStore", "GlobalDataStore", "global", false)
	end,
	GetOrderedDataStore = function(self, name, scope)
		return getStore(self, "GetOrderedDataStore", name, scope, true)
	end,
	GetRequestBudgetForRequestType = function(self)
		selfState(self, "GetRequestBudgetForRequestType")
		return 60000
	end,
	ListDataStoresAsync = function(self, prefix, pageSize)
		local world = selfState(self, "ListDataStoresAsync").world
		task.wait()
		local created = {}
		for _, s in storeRoot(world).data do
			if not s.ordered and (prefix == nil or s.name:sub(1, #prefix) == prefix) then
				created[s.name] = created[s.name] or s.created
			end
		end
		local names = {}
		for n in created do
			table.insert(names, n)
		end
		table.sort(names)
		local items = {}
		for _, n in names do
			table.insert(
				items,
				makeVirtual(world, "DataStoreInfo", "DataStoreInfo", {}, {
					DataStoreName = n,
					CreatedTime = created[n],
					UpdatedTime = created[n],
				})
			)
		end
		return makePages(world, "DataStoreListingPages", paginate(items, tonumber(pageSize) or 32))
	end,
}

local function expiry(exp, arg)
	exp = tonumber(exp)
	if exp == nil then
		error(`Argument {arg} missing or nil`, 0)
	elseif exp <= 0 or exp > MAX_EXPIRATION then
		error(`Expiration must be between 0 and {MAX_EXPIRATION} seconds.`, 0)
	end
	return os.clock() + exp
end

local function memValue(v)
	return storable(v, 32 * 1024)
end

local function expiringItems()
	local items = {}
	local function live(key)
		local e = items[key]
		if e and e.expires > os.clock() then
			return e
		end
		items[key] = nil
		return nil
	end
	return items, live
end

local function makeHashMap(world, name)
	local items, live = expiringItems()
	return makeVirtual(world, "MemoryStoreHashMap", name, {
		GetAsync = method("GetAsync", function(key)
			key = checkKey(key, "Key")
			task.wait()
			local e = live(key)
			return e and deepCopy(e.value)
		end),
		SetAsync = method("SetAsync", function(key, v, exp)
			key = checkKey(key, "Key")
			v = memValue(v)
			local expires = expiry(exp, 3)
			task.wait()
			items[key] = { value = v, expires = expires }
			return true
		end),
		UpdateAsync = method("UpdateAsync", function(key, fn, exp)
			key = checkKey(key, "Key")
			local expires = expiry(exp, 3)
			task.wait()
			local e = live(key)
			local new = fn(e and deepCopy(e.value))
			if new == nil then
				return nil
			end
			new = memValue(new)
			items[key] = { value = new, expires = expires }
			return deepCopy(new)
		end),
		RemoveAsync = method("RemoveAsync", function(key)
			key = checkKey(key, "Key")
			task.wait()
			items[key] = nil
		end),
		ListItemsAsync = method("ListItemsAsync", function(count)
			task.wait()
			local keys = {}
			for k in items do
				if live(k) then
					table.insert(keys, k)
				end
			end
			table.sort(keys)
			local list = {}
			for _, k in keys do
				table.insert(list, { key = k, value = deepCopy(items[k].value) })
			end
			return makePages(world, "MemoryStoreHashMapPages", paginate(list, tonumber(count) or 10))
		end),
	})
end

local function sortKeyLess(a, b)
	if a == b then
		return false
	elseif a == nil then
		return true
	elseif b == nil then
		return false
	end
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta == "number"
	end
	return a < b
end

local function entryLess(a, b)
	if a.sortKey ~= b.sortKey then
		return sortKeyLess(a.sortKey, b.sortKey)
	end
	return a.key < b.key
end

local function makeSortedMap(world, name)
	local items, live = expiringItems()
	return makeVirtual(world, "MemoryStoreSortedMap", name, {
		GetAsync = method("GetAsync", function(key)
			key = checkKey(key, "Key")
			task.wait()
			local e = live(key)
			if not e then
				return nil
			end
			return deepCopy(e.value), e.sortKey
		end),
		SetAsync = method("SetAsync", function(key, v, exp, sortKey)
			key = checkKey(key, "Key")
			v = memValue(v)
			local expires = expiry(exp, 3)
			task.wait()
			local isNew = live(key) == nil
			items[key] = { key = key, value = v, expires = expires, sortKey = sortKey }
			return isNew
		end),
		UpdateAsync = method("UpdateAsync", function(key, fn, exp)
			key = checkKey(key, "Key")
			local expires = expiry(exp, 3)
			task.wait()
			local e = live(key)
			local new, sortKey = fn(e and deepCopy(e.value), e and e.sortKey)
			if new == nil then
				return nil
			end
			new = memValue(new)
			items[key] = { key = key, value = new, expires = expires, sortKey = sortKey }
			return deepCopy(new), sortKey
		end),
		RemoveAsync = method("RemoveAsync", function(key)
			key = checkKey(key, "Key")
			task.wait()
			items[key] = nil
		end),
		GetRangeAsync = method("GetRangeAsync", function(direction, count, lower, upper)
			count = tonumber(count)
			if not count or count < 1 or count > 200 then
				error("Count must be between 1 and 200.", 0)
			end
			task.wait()
			local list = {}
			for k in items do
				local e = live(k)
				if e then
					local after = lower == nil or entryLess({ key = lower.key or "", sortKey = lower.sortKey }, e)
					local before = upper == nil or entryLess(e, { key = upper.key or "\255", sortKey = upper.sortKey })
					if after and before then
						table.insert(list, e)
					end
				end
			end
			table.sort(list, entryLess)
			if direction == Enum.SortDirection.Descending then
				local reversed = {}
				for i = #list, 1, -1 do
					table.insert(reversed, list[i])
				end
				list = reversed
			end
			local out = {}
			for i = 1, math.min(count, #list) do
				table.insert(out, { key = list[i].key, value = deepCopy(list[i].value), sortKey = list[i].sortKey })
			end
			return out
		end),
	})
end

local function makeQueue(world, name, invisibility)
	invisibility = tonumber(invisibility) or 30
	local items, reads = {}, {}
	local readId, order = 0, 0
	local function prune()
		local now = os.clock()
		for i = #items, 1, -1 do
			if items[i].expires <= now then
				table.remove(items, i)
			end
		end
	end
	local function visible()
		prune()
		local now = os.clock()
		local out = {}
		for _, it in items do
			if it.hiddenUntil <= now then
				table.insert(out, it)
			end
		end
		table.sort(out, function(a, b)
			if a.priority ~= b.priority then
				return a.priority > b.priority
			end
			return a.order < b.order
		end)
		return out
	end
	return makeVirtual(world, "MemoryStoreQueue", name, {
		AddAsync = method("AddAsync", function(v, exp, priority)
			v = memValue(v)
			local expires = expiry(exp, 2)
			task.wait()
			order += 1
			table.insert(items, {
				value = v,
				expires = expires,
				priority = tonumber(priority) or 0,
				order = order,
				hiddenUntil = 0,
			})
		end),
		ReadAsync = method("ReadAsync", function(count, allOrNothing, waitTimeout)
			count = tonumber(count) or 1
			waitTimeout = tonumber(waitTimeout) or -1
			local deadline = if waitTimeout >= 0 then os.clock() + waitTimeout else math.huge
			task.wait()
			while true do
				local vis = visible()
				local enough = #vis >= count or (not allOrNothing and #vis > 0)
				if enough or os.clock() >= deadline then
					if #vis == 0 or (allOrNothing and #vis < count) then
						return {}, nil
					end
					local out, taken = {}, {}
					for i = 1, math.min(count, #vis) do
						vis[i].hiddenUntil = os.clock() + invisibility
						table.insert(out, deepCopy(vis[i].value))
						table.insert(taken, vis[i])
					end
					readId += 1
					local id = tostring(readId)
					reads[id] = taken
					return out, id
				end
				task.wait(0.1)
			end
		end),
		RemoveAsync = method("RemoveAsync", function(id)
			task.wait()
			for _, it in reads[id] or {} do
				local i = table.find(items, it)
				if i then
					table.remove(items, i)
				end
			end
			reads[id] = nil
		end),
		GetSizeAsync = method("GetSizeAsync", function(excludeInvisible)
			task.wait()
			if excludeInvisible then
				return #visible()
			end
			prune()
			return #items
		end),
	})
end

local function memoryGetter(kind, bucketName, make)
	return function(self, name, extra)
		local world = selfState(self, "Get" .. kind).world
		name = checkKey(name, kind .. " name")
		local bucket = storeRoot(world)[bucketName]
		local s = bucket[name]
		if not s then
			s = make(world, name, extra)
			bucket[name] = s
		end
		return s
	end
end

serviceMethods.MemoryStoreService = {
	GetHashMap = memoryGetter("HashMap", "hash", makeHashMap),
	GetSortedMap = memoryGetter("SortedMap", "sorted", makeSortedMap),
	GetQueue = memoryGetter("Queue", "queues", makeQueue),
}

serviceMethods.MessagingService = {
	PublishAsync = function(self, topic, message)
		local world = selfState(self, "PublishAsync").world
		topic = tostring(topic)
		if #topic > 80 then
			error("Topic name exceeds the 80 character limit.", 0)
		end
		local data = storable(message, 1024)
		task.wait()
		for _, sub in storeRoot(world).topics[topic] or {} do
			if sub.connected then
				task.defer(sub.fn, { Data = deepCopy(data), Sent = os.time() })
			end
		end
	end,
	SubscribeAsync = function(self, topic, callback)
		local world = selfState(self, "SubscribeAsync").world
		checkFn(callback)
		topic = tostring(topic)
		task.wait()
		local topics = storeRoot(world).topics
		topics[topic] = topics[topic] or {}
		local entry = { fn = callback, connected = true }
		table.insert(topics[topic], entry)
		local conn = {
			connected = true,
			world = world,
			reals = {
				{
					Disconnect = function()
						entry.connected = false
					end,
				},
			},
		}
		world.conns[conn] = true
		return makeConnection(conn)
	end,
}

--// Virtual LogService / ScriptContext (per world; real ones would show other runs)

local MAX_LOG = 1000

local function logState(world)
	local l = world.log
	if not l then
		l = { entries = {}, out = newLocal(), err = newLocal(), silent = newLocal() }
		world.log = l
	end
	return l
end

local function emitLog(world, message, messageType)
	local l = logState(world)
	table.insert(l.entries, { message = message, messageType = messageType, timestamp = os.time() })
	if #l.entries > MAX_LOG then
		table.remove(l.entries, 1)
	end
	localFire(l.out, message, messageType)
end

local function localSignal(name, pick)
	return function(st)
		return signalFor(st, name, function()
			return makeSignal(st.world, {}, pick(logState(st.world)), nil, name)
		end)
	end
end

serviceGetters.LogService = {
	MessageOut = localSignal("MessageOut", function(l)
		return l.out
	end),
	HttpResultOut = localSignal("HttpResultOut", function(l)
		return l.silent
	end),
	OnHttpResultApproved = localSignal("OnHttpResultApproved", function(l)
		return l.silent
	end),
	ServerMessageOut = localSignal("ServerMessageOut", function(l)
		return l.silent
	end),
}
-- AssetService's EditableImage methods are blocked on these servers, so runs get Image-library
-- EditableImages instead (LoadEnv's hooks.editableImages)
local function editableProvider(self, k)
	local provider = selfState(self, k).world.editableImages
	if not provider then
		error("EditableImage is not available in this run", 0)
	end
	return provider
end
serviceMethods.AssetService = {
	CreateEditableImage = function(self, options)
		local image = editableProvider(self, "CreateEditableImage").create(options)
		proxyKind[image] = "Object"
		return image
	end,
	CreateEditableImageAsync = function(self, content)
		local image = editableProvider(self, "CreateEditableImageAsync").load(content)
		proxyKind[image] = "Object"
		return image
	end,
}
serviceMethods.LogService = {
	GetLogHistory = function(self)
		local world = selfState(self, "GetLogHistory").world
		local out = {}
		for i, e in logState(world).entries do
			out[i] = table.clone(e)
		end
		return out
	end,
	ClearOutput = function(self)
		table.clear(logState(selfState(self, "ClearOutput").world).entries)
	end,
}
serviceGetters.ScriptContext = {
	Error = localSignal("Error", function(l)
		return l.err
	end),
}

--// Players: a mock LocalPlayer (PlayerGui, Backpack) for client-style code. It is the run's
--// Discord user; a web run gets Player1 / -1 like a Studio test player.

local realPlayers = realGame:GetService("Players")

local function fakeChildOfClass(st, class, inherited)
	for _, child in st.real:GetChildren() do
		local fake = st.world.fakes[child]
		local matches
		if fake then
			matches = if inherited then fake.classes[class] == true else fake.className == class
		else
			matches = if inherited then child:IsA(class) else child.ClassName == class
		end
		if matches then
			return wrap(st.world, child)
		end
	end
	return nil
end

local function fakeMethod(k, fn)
	return function(self, ...)
		return fn(selfState(self, k), ...)
	end
end

local function constant(v)
	return function()
		return v
	end
end

-- GetGuiObjectsAtPosition on the real ScreenGui underneath is Roblox-script-only, so the mock
-- PlayerGui hit-tests itself: visible GuiObjects holding the point, topmost first.
local function guiObjectsAt(st, x, y)
	if type(x) ~= "number" or type(y) ~= "number" then
		error("GetGuiObjectsAtPosition expects two numbers", 0)
	end
	local hits = {}
	local function walk(inst, layer, clipped)
		local children = inst:GetChildren()
		if layer.ZIndexBehavior == Enum.ZIndexBehavior.Sibling then
			-- siblings draw by ZIndex, ties in tree order
			for i, c in children do
				children[i] = { c, i }
			end
			table.sort(children, function(a, b)
				local za = if a[1]:IsA("GuiObject") then a[1].ZIndex else 0
				local zb = if b[1]:IsA("GuiObject") then b[1].ZIndex else 0
				return if za ~= zb then za < zb else a[2] < b[2]
			end)
			for i, entry in children do
				children[i] = entry[1]
			end
		end
		for _, child in children do
			if child:IsA("ScreenGui") then
				if child.Enabled then
					walk(child, child, false)
				end
			elseif child:IsA("GuiObject") then
				if child.Visible then
					local p, s = child.AbsolutePosition, child.AbsoluteSize
					local within = x >= p.X and y >= p.Y and x < p.X + s.X and y < p.Y + s.Y
					if within and not clipped then
						table.insert(hits, { child, layer, #hits })
					end
					walk(child, layer, clipped or (child.ClipsDescendants and not within))
				end
			elseif not child:IsA("LayerCollector") then
				walk(child, layer, clipped)
			end
		end
	end
	walk(st.real, st.real, false)
	-- later in draw order is on top: higher DisplayOrder, then (Global) ZIndex, then tree order
	table.sort(hits, function(a, b)
		if a[2].DisplayOrder ~= b[2].DisplayOrder then
			return a[2].DisplayOrder > b[2].DisplayOrder
		end
		if a[2] == b[2] and a[2].ZIndexBehavior == Enum.ZIndexBehavior.Global and a[1].ZIndex ~= b[1].ZIndex then
			return a[1].ZIndex > b[1].ZIndex
		end
		return a[3] > b[3]
	end)
	local out = {}
	for i, hit in hits do
		out[i] = wrap(st.world, hit[1])
	end
	return out
end

local function containerFake(className, base)
	local classes = { Instance = true, [className] = true }
	if base then
		classes[base] = true
	end
	return { className = className, classes = classes, get = {}, methods = {} }
end

local function playerFake(userId)
	local function event(name)
		return function(st)
			return signalFor(st, name, function()
				return makeSignal(st.world, {}, newLocal(), nil, name)
			end)
		end
	end
	return {
		className = "Player",
		classes = { Instance = true, Player = true },
		get = {
			UserId = constant(userId),
			DisplayName = function(st)
				return st.real.Name
			end,
			AccountAge = constant(0),
			MembershipType = constant(Enum.MembershipType.None),
			LocaleId = constant("en-us"),
			Character = constant(nil),
			Team = constant(nil),
			Neutral = constant(true),
			CharacterAdded = event("CharacterAdded"),
			CharacterAppearanceLoaded = event("CharacterAppearanceLoaded"),
			CharacterRemoving = event("CharacterRemoving"),
			Chatted = event("Chatted"),
		},
		methods = {
			FindFirstChildOfClass = fakeMethod("FindFirstChildOfClass", function(st, class)
				return fakeChildOfClass(st, class, false)
			end),
			FindFirstChildWhichIsA = fakeMethod("FindFirstChildWhichIsA", function(st, class)
				return fakeChildOfClass(st, class, true)
			end),
			IsInGroup = fakeMethod("IsInGroup", constant(false)),
			GetRankInGroup = fakeMethod("GetRankInGroup", constant(0)),
			GetRoleInGroup = fakeMethod("GetRoleInGroup", constant("Guest")),
			HasAppearanceLoaded = fakeMethod("HasAppearanceLoaded", constant(false)),
			Kick = fakeMethod("Kick", function(_, message)
				error(if message then `You were kicked: {message}` else "You were kicked from this experience", 0)
			end),
		},
	}
end

local function localPlayer(world)
	if world.localPlayer then
		return world.localPlayer
	end
	local user = world.user
	local name, userId = "Player1", -1
	if user and string.match(tostring(user.UserId), "^%d+$") then
		-- Discord ids pass 2^53, so the number keeps only the leading 16 digits; user.UserId is exact
		name, userId = tostring(user.Name), tonumber(user.UserId)
	end
	local real = realInstance.new("Folder")
	real.Name = name
	world.fakes[real] = playerFake(userId)
	-- PlayerGui is a ScreenGui underneath so the renderer draws the ScreenGuis in it as a screen
	for _, container in { { "PlayerGui", "ScreenGui", "BasePlayerGui" }, { "Backpack", "Folder" } } do
		local child = realInstance.new(container[2])
		child.Name = container[1]
		local fake = containerFake(container[1], container[3])
		if container[1] == "PlayerGui" then
			fake.methods.GetGuiObjectsAtPosition = fakeMethod("GetGuiObjectsAtPosition", guiObjectsAt)
		end
		world.fakes[child] = fake
		child.Parent = real
	end
	real.Parent = shadowFor(world, realPlayers)
	world.localPlayer = wrap(world, real)
	return world.localPlayer
end

serviceGetters.Players = {
	LocalPlayer = function(st)
		return localPlayer(st.world)
	end,
}
serviceMethods.Players = {
	GetPlayers = function(self)
		return { localPlayer(selfState(self, "GetPlayers").world) }
	end,
	GetPlayerByUserId = function(self, userId)
		local player = localPlayer(selfState(self, "GetPlayerByUserId").world)
		return if userId == player.UserId then player else nil
	end,
}
serviceMethods.Players.getPlayers = serviceMethods.Players.GetPlayers

--// RunService frame events. Open Cloud only fires Heartbeat, so each world fires the rest in
--// client order (measured in Studio): BindToRenderStep by priority, FRAME_EVENTS, then the real
--// Heartbeat. Handlers are deferred, and what they defer runs before the next event.

local realRunService = realGame:GetService("RunService")
local FRAME_EVENTS = { "RenderStepped", "PreRender", "PreAnimation", "Stepped", "PreSimulation", "PostSimulation" }
local DEFER_DEPTH = 4
-- time() stays 0 on an Open Cloud server; Stepped's time is how long the server has run
local SERVER_START = os.clock()

local function drainDeferred()
	local th = coroutine.running()
	for _ = 1, DEFER_DEPTH do
		task.defer(th)
		coroutine.yield()
	end
end

local function runState(world)
	local r = world.run
	if r then
		return r
	end
	r = { signals = {}, bindings = {}, order = 0, driving = false }
	world.run = r
	local function active()
		if next(r.bindings) then
			return true
		end
		for _, ls in r.signals do
			if next(ls.listeners) then
				return true
			end
		end
		return false
	end
	local function stage(ls, ...)
		if next(ls.listeners) then
			localFire(ls, ...)
			drainDeferred()
		end
	end
	-- frame N's events run after Heartbeat N-1 and before Heartbeat N
	function r.start()
		if r.driving then
			return
		end
		r.driving = true
		task.spawn(function()
			while true do
				local dt = realRunService.Heartbeat:Wait()
				if not active() then
					break
				end
				if next(r.bindings) then
					local list = {}
					for _, b in r.bindings do
						table.insert(list, b)
					end
					table.sort(list, function(a, b)
						if a.priority ~= b.priority then
							return a.priority < b.priority
						end
						return a.order < b.order
					end)
					for _, b in list do
						task.defer(b.fn, dt)
					end
					drainDeferred()
				end
				local s = r.signals
				stage(s.RenderStepped, dt)
				stage(s.PreRender, dt)
				stage(s.PreAnimation, dt)
				stage(s.Stepped, os.clock() - SERVER_START, dt)
				stage(s.PreSimulation, dt)
				stage(s.PostSimulation, dt)
			end
			r.driving = false
		end)
	end
	for _, name in FRAME_EVENTS do
		local ls = newLocal()
		ls.onConnect = r.start
		r.signals[name] = ls
	end
	return r
end

local function frameSignal(name)
	return function(st)
		return signalFor(st, name, function()
			return makeSignal(st.world, {}, runState(st.world).signals[name], nil, name)
		end)
	end
end

serviceGetters.RunService = {}
for _, name in FRAME_EVENTS do
	serviceGetters.RunService[name] = frameSignal(name)
end
serviceMethods.RunService = {
	BindToRenderStep = function(self, name, priority, fn)
		local world = selfState(self, "BindToRenderStep").world
		if type(name) ~= "string" then
			error(`Argument 1 missing or nil`, 0)
		end
		if type(priority) ~= "number" then
			error(`Unable to cast {typeName(priority)} to int`, 0)
		end
		if type(fn) ~= "function" then
			error(`Argument 3 missing or nil`, 0)
		end
		local r = runState(world)
		r.order += 1
		r.bindings[name] = { priority = priority, fn = fn, order = r.order }
		r.start()
	end,
	UnbindFromRenderStep = function(self, name)
		local world = selfState(self, "UnbindFromRenderStep").world
		runState(world).bindings[tostring(name)] = nil
	end,
}

local function joinArgs(...)
	local t = table.pack(...)
	for i = 1, t.n do
		t[i] = tostring(t[i])
	end
	return table.concat(t, " ", 1, t.n)
end

--// Demo helpers: nothing simulates physics here, so events can be fired by hand

local function firesignal(signal, ...)
	local s = sigStates[signal]
	if not s then
		error(`invalid argument #1 to 'firesignal' (RBXScriptSignal expected, got {typeName(signal)})`, 2)
	end
	localFire(s.fire, ...)
end

local function fireevent(instance, name, ...)
	if not states[instance] and not virtualStates[instance] then
		error(`invalid argument #1 to 'fireevent' (Instance expected, got {typeName(instance)})`, 2)
	end
	if type(name) ~= "string" then
		error(`invalid argument #2 to 'fireevent' (string expected, got {typeName(name)})`, 2)
	end
	local signal = instance[name]
	if typeName(signal) ~= "RBXScriptSignal" then
		error(`{name} is not an event of {instance.ClassName}`, 2)
	end
	firesignal(signal, ...)
end

--[[GLOBALS]]
-- generated by scripts/sync-globals.js; do not edit by hand
local GLOBALS = {
	Axes = "pure",
	BrickColor = "pure",
	CFrame = "pure",
	CatalogSearchParams = "pure",
	Color3 = "pure",
	ColorSequence = "pure",
	ColorSequenceKeypoint = "pure",
	Content = "pure",
	DateTime = "pure",
	DebuggerManager = "pure",
	Delay = "pure",
	DockWidgetPluginGuiInfo = "pure",
	ElapsedTime = "pure",
	Enum = "pure",
	Faces = "pure",
	FloatCurveKey = "pure",
	Font = "pure",
	Game = "handled",
	Instance = "handled",
	InstanceHandle = "wrap",
	NumberRange = "pure",
	NumberSequence = "pure",
	NumberSequenceKeypoint = "pure",
	OverlapParams = "handled",
	Path2DControlPoint = "pure",
	PathWaypoint = "pure",
	PhysicalProperties = "pure",
	PluginManager = "handled",
	Random = "pure",
	Ray = "pure",
	RaycastParams = "handled",
	Rect = "pure",
	Region3 = "pure",
	Region3int16 = "pure",
	RotationCurveKey = "pure",
	Secret = "pure",
	SecurityCapabilities = "pure",
	SharedTable = "pure",
	Stats = "handled",
	TweenInfo = "pure",
	UDim = "pure",
	UDim2 = "pure",
	User = "wrap",
	UserSettings = "handled",
	ValueCurveKey = "pure",
	Vector2 = "pure",
	Vector2int16 = "pure",
	Vector3 = "pure",
	Vector3int16 = "pure",
	Version = "pure",
	Wait = "pure",
	Workspace = "handled",
	_G = "handled",
	_VERSION = "pure",
	assert = "pure",
	bit32 = "pure",
	buffer = "pure",
	collectgarbage = "pure",
	coroutine = "handled",
	debug = "pure",
	delay = "handled",
	elapsedTime = "pure",
	error = "pure",
	game = "handled",
	gcinfo = "pure",
	getfenv = "pure",
	getmetatable = "pure",
	ipairs = "pure",
	loadstring = "handled",
	math = "pure",
	newproxy = "pure",
	next = "pure",
	os = "pure",
	pairs = "pure",
	pcall = "pure",
	plugin = "pure",
	print = "handled",
	rawequal = "pure",
	rawget = "pure",
	rawlen = "pure",
	rawset = "pure",
	require = "handled",
	script = "handled",
	select = "pure",
	setfenv = "pure",
	setmetatable = "pure",
	settings = "handled",
	shared = "handled",
	spawn = "handled",
	stats = "handled",
	string = "pure",
	table = "pure",
	task = "handled",
	tick = "pure",
	time = "pure",
	tonumber = "pure",
	tostring = "pure",
	type = "pure",
	typeof = "handled",
	unpack = "pure",
	utf8 = "pure",
	vector = "pure",
	wait = "pure",
	warn = "handled",
	workspace = "handled",
	xpcall = "pure",
}
local GLOBAL_VALUES = {
	InstanceHandle = InstanceHandle,
	User = User,
}
--[[/GLOBALS]]

--// Globals the sandbox has no dedicated wrapper for (new Roblox APIs included)

local function autoWrap(world, v)
	local tv = realTypeof(v)
	if tv == "Instance" then
		return wrap(world, v)
	elseif tv == "function" then
		return function(...)
			local results = table.pack(v(unwrapN(world, ...)))
			for i = 1, results.n do
				results[i] = copyWrap(world, results[i])
			end
			return table.unpack(results, 1, results.n)
		end
	elseif tv == "table" then
		local cache = {}
		return setmetatable({}, {
			__index = function(_, k)
				local c = cache[k]
				if c == nil then
					c = autoWrap(world, v[k])
					cache[k] = c
				end
				return c
			end,
			__newindex = function()
				error("attempt to modify a readonly table", 2)
			end,
			__iter = function()
				local key
				return function()
					local value
					key, value = next(v, key)
					if key == nil then
						return nil
					end
					return key, autoWrap(world, value)
				end
			end,
		})
	end
	return v
end

for name, kind in GLOBALS do
	if kind == "auto" and GLOBAL_VALUES[name] ~= nil then
		warn(`[Sandbox] unclassified global: {name} (auto-wrapped; run scripts/sync-globals.js)`)
	end
end

--// RaycastParams / OverlapParams: the engine only accepts real Instances

local function makeParamsLib(world, realLib, kind)
	local function wrapParams(real)
		local p = newproxy(true)
		local mt = getmetatable(p)
		proxyKind[p] = kind
		dtReal[p] = real
		local methods = {}
		mt.__index = function(_, k)
			local ok, v = pcall(index, real, k)
			if not ok then
				error(v, 0)
			end
			if type(v) ~= "function" then
				return copyWrap(world, v)
			end
			local m = methods[k]
			if not m then
				m = function(self, ...)
					local r = table.pack(pcall(v, if self == p then real else unwrapArg(world, self), unwrapN(world, ...)))
					if not r[1] then
						error(string.gsub(tostring(r[2]), "^.-:%d+: ", ""), 2)
					end
					return wrapN(world, table.unpack(r, 2, r.n))
				end
				methods[k] = m
			end
			return m
		end
		mt.__newindex = function(_, k, v)
			local ok, err = pcall(setIndex, real, k, unwrapArg(world, v))
			if not ok then
				error(err, 0)
			end
		end
		mt.__tostring = function()
			return tostring(real)
		end
		setOps(mt)
		return p
	end
	return table.freeze({
		new = function(...)
			local ok, real = pcall(realLib.new, unwrapN(world, ...))
			if not ok then
				error(real, 2)
			end
			return wrapParams(real)
		end,
	})
end

--// Context

local Context = {}
Context.__index = Context

-- Worlds must be inside the DataModel for spatial queries, but anything in it is reachable from a
-- --!nosandbox run, so a world is only parented while its owner is running and no such run is active.
local nosandboxRuns = 0

local function placeWorld(w)
	local parent = if w.live > 0 and nosandboxRuns == 0 then realWorkspace else nil
	if w.ws.Parent ~= parent then
		pcall(function()
			w.ws.Parent = parent
		end)
	end
end

local function placeAll()
	for _, w in worlds do
		placeWorld(w)
	end
end

function Sandbox.getWorld(userId)
	local key = tostring(userId)
	local w = worlds[key]
	if w and not w.dead then
		return w
	end
	w = setmetatable({
		id = key,
		proxies = setmetatable({}, { __mode = "kv" }),
		signalCache = setmetatable({}, { __mode = "kv" }),
		overlay = {},
		shadows = {},
		shadowCount = 0,
		pinned = {},
		shared = {},
		conns = {},
		handlers = setmetatable({}, { __mode = "k" }),
		rewrites = {},
		-- real Folder -> the class it stands in for; strong keys, an Instance's userdata can be recreated
		fakes = {},
		live = 0,
	}, World)
	w.root = realInstance.new("Folder")
	w.root.Name = "__sbx_" .. key
	w.ws = realInstance.new("WorldModel")
	w.ws.Name = "__ws_" .. key
	-- never persisted if a --!nosandbox run calls SavePlaceAsync
	w.root.Archivable = false
	w.ws.Archivable = false
	rootWorld[w.root] = w
	rootWorld[w.ws] = w
	shadowInfo[w.ws] = { world = w, shared = realWorkspace }
	w.shadows[realWorkspace] = w.ws
	addRewrite(w, "Workspace." .. w.ws.Name, "Workspace")
	addRewrite(w, w.ws.Name, "Workspace")
	-- Mask the real place/creator so a run can't tell which game it is running in.
	local gov = ovFor(w, realGame)
	gov.props.PlaceId = box(0)
	gov.props.GameId = box(0)
	gov.props.CreatorId = box(-1)
	gov.props.PrivateServerId = box("")
	gov.props.PrivateServerOwnerId = box(0)
	gov.props.JobId = box(HttpService:GenerateGUID(false):lower())
	worlds[key] = w
	return w
end

function World:idle()
	for conn in self.conns do
		disconnect(conn)
	end
	if self.run then
		table.clear(self.run.bindings)
	end
	for inst in self.pinned do
		rootWorld[inst] = nil
	end
	table.clear(self.pinned)
end

-- A world lives only while its user has runs going; the last one ending tears it down, so the next
-- run gets a fresh workspace, LocalPlayer, PlayerGui, shared table, mock stores and overlays.
function World:destroy()
	if self.dead then
		return
	end
	self.dead = true
	if worlds[self.id] == self then
		worlds[self.id] = nil
	end
	local pinned = table.clone(self.pinned)
	self:idle()
	for inst in pinned do
		pcall(inst.Destroy, inst)
	end
	for _, shadow in self.shadows do
		shadowInfo[shadow] = nil
	end
	rootWorld[self.root] = nil
	rootWorld[self.ws] = nil
	pcall(self.ws.Destroy, self.ws)
	pcall(self.root.Destroy, self.root)
	table.clear(self.shadows)
	table.clear(self.fakes)
	table.clear(self.overlay)
	table.clear(self.shared)
	self.stores, self.run, self.localPlayer = nil, nil, nil
end

function World:newContext(hooks, env)
	self.live += 1
	placeWorld(self)
	local ctx = setmetatable({ world = self, hooks = hooks, env = env, modules = {}, extensions = {}, extensionInstances = {} }, Context)
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
	for instance in self.extensionInstances do
		if extensionOwners[instance] == self then extensionOwners[instance] = nil end
	end
	table.clear(self.extensionInstances)
	table.clear(self.extensions)
	local world = self.world
	world.live -= 1
	if world.live <= 0 then
		world.live = 0
		world:destroy()
	else
		placeWorld(world)
	end
end

function Context:wrap(v)
	return copyWrap(self.world, v)
end

function Context:unwrap(v)
	return unwrapDeep(self.world, v)
end

-- Whether user code here can still run on its own: a live connection or an unfinished handler.
function Context:busy()
	for conn in self.world.conns do
		if isConnected(conn) then
			return true
		end
	end
	for co in self.world.handlers do
		if coroutine.status(co) ~= "dead" then
			return true
		end
	end
	return self.world.run ~= nil and next(self.world.run.bindings) ~= nil
end

-- Takes a real instance built outside the sandbox into this world and returns its proxy.
function Context:adopt(inst)
	assert(not self.dead, "job is closed")
	checkInfrastructure(inst)
	assert(ownerOf(inst) == nil or ownerOf(inst) == self.world, "cannot adopt another user's instance")
	pin(self.world, inst)
	attachExtensions(self, inst)
	return wrap(self.world, inst)
end

-- Trusted entry points used by LuneImports; only proxies and data cross to user code.
function Context:implementMember(className, name, getterOrMethod, setter, isMethod)
	assert(not self.dead, "job is closed")
	assert(type(className) == "string" and ReflectionService:GetClass(className), "unknown class")
	assert(type(name) == "string" and #name > 0 and #name <= 128, "invalid custom member name")
	assert(type(getterOrMethod) == "function" and (setter == nil or type(setter) == "function"), "expected callbacks")
	local class = getClass(className)
	assert(not class.props[name] and not class.methods[name] and not class.events[name], "cannot replace an engine member")
	assert(not ownedMethods[name] and not ownedGetters[name], "cannot replace a sandbox member")
	local members = self.extensions[className]
	if not members then members = {}; self.extensions[className] = members end
	if isMethod then
		local context = self
		members[name] = {method = function(instance, ...)
			local st = states[instance]
			assert(not context.dead and st and extensionOwners[st.real] == context and st.real:IsA(className), "custom method requires a job-owned instance of its class")
			return getterOrMethod(instance, ...)
		end}
	else
		members[name] = {get = getterOrMethod, set = setter}
	end
end

function Context:serializeModel(instances)
	assert(not self.dead, "job is closed")
	assert(type(instances) == "table" and #instances > 0 and #instances <= 10000, "expected an array of job-owned instances")
	assert(type(self.hooks.serializeModel) == "function", "model serialization is unavailable on this worker")
	local originals, seen, count = {}, {}, 0
	for i = 1, #instances do
		local st = states[rawget(instances, i)]
		assert(st and st.world == self.world and st.kind == "owned" and extensionOwners[st.real] == self, "model export requires job-owned instances")
		local root = st.real
		checkInfrastructure(root)
		assert(root.Archivable, "model export root must be Archivable")
		local tree = root:GetDescendants()
		table.insert(tree, root)
		for _, instance in tree do
			checkInfrastructure(instance)
			assert(not seen[instance], "duplicate or overlapping model roots")
			assert(extensionOwners[instance] == self and ownerOf(instance) == self.world, "model contains a foreign instance")
			seen[instance] = true; count += 1
			assert(count <= 10000, "model exceeds 10000 instances")
		end
		originals[i] = root
	end
	local copies, mapping = {}, {}
	local ok, result = pcall(function()
		local function pair(original, copy)
			mapping[original] = copy
			local children, index = copy:GetChildren(), 1
			for _, child in original:GetChildren() do
				if child.Archivable then
					local cloned = children[index]
					assert(cloned and cloned.ClassName == child.ClassName and cloned.Name == child.Name, "clone tree changed during export")
					pair(child, cloned); index += 1
				end
			end
		end
		for _, original in originals do
			local copy = assert(original:Clone(), "model root could not be cloned")
			table.insert(copies, copy); pair(original, copy)
		end
		-- Preserve references across separately cloned roots, omit external references.
		for original, copy in mapping do
			for name, info in getClass(original.ClassName).props do
				if info.instanceType and info.write and name ~= "Parent" then
					local readable, target = pcall(index, original, name)
					if readable and target ~= nil then copy[name] = mapping[target] end
				end
			end
		end
		-- The model keeps the run's own Source and Enabled; the trusted serializer writes the Source.
		local sources = {}
		for original, copy in mapping do
			if virtualSource[original] ~= nil then
				sources[copy] = virtualSource[original]
			end
			if original:IsA("BaseScript") then
				copy.Enabled = enabledOf(original)
			end
		end
		return self.hooks.serializeModel(copies, sources)
	end)
	for _, copy in copies do copy:Destroy() end
	if not ok then error(result, 0) end
	assert(not self.dead, "job is closed")
	return result
end

function Context:deserializeModel(contents)
	assert(not self.dead and type(self.hooks.deserializeModel) == "function", "model deserialization is unavailable on this worker")
	local roots = self.hooks.deserializeModel(contents)
	if self.dead then
		for _, root in roots do root:Destroy() end
		error("job is closed", 0)
	end
	local results = {}
	for i, root in roots do results[i] = self:adopt(root) end
	return results
end

-- The real instance a renderer may read for v, or nil if v isn't this world's. A shared
-- engine instance resolves to this world's shadow of it (workspace -> its WorldModel).
function Context:renderTarget(v)
	local st = states[v]
	if not st or st.world ~= self.world or isInfrastructure(st.real) then
		return nil
	end
	if st.kind == "shared" then
		return self.world.shadows[st.real]
	end
	if ownerOf(st.real) ~= self.world then
		return nil
	end
	return st.real
end

function Context:_apply(env)
	local world = self.world
	local hooks = self.hooks
	hooks.luneRoblox = {
		newInstance = function(...)
			assert(not self.dead, "job is closed")
			return env.Instance.new(...)
		end,
		serializeModel = function(instances) return self:serializeModel(instances) end,
		deserializeModel = function(contents) return self:deserializeModel(contents) end,
		implementMethod = function(class, name, callback) return self:implementMember(class, name, callback, nil, true) end,
		implementProperty = function(class, name, get, set) return self:implementMember(class, name, get, set, false) end,
	}
	local g = wrap(world, realGame)
	local ws = wrap(world, realWorkspace)
	local rawPrint, rawWarn = env.print, env.warn
	if type(rawPrint) == "function" then
		env.print = function(...)
			rawPrint(...)
			emitLog(world, joinArgs(...), Enum.MessageType.MessageOutput)
		end
	end
	if type(rawWarn) == "function" then
		env.warn = function(...)
			rawWarn(...)
			emitLog(world, joinArgs(...), Enum.MessageType.MessageWarning)
		end
	end
	hooks.onError = function(message, trace)
		emitLog(world, message, Enum.MessageType.MessageError)
		localFire(logState(world).err, message, trace, env.script)
	end
	hooks.sandboxBusy = function()
		return self:busy()
	end
	world.warn = env.warn
	world.user = env.user
	env.game = g
	env.Game = g
	env.workspace = ws
	env.Workspace = ws
	if hooks.module then
		env.script = wrap(world, hooks.module)
	end
	env.typeof = sandboxTypeof
	local editable = hooks.editableImages
	world.editableImages = editable
	if editable then
		-- an EditableImage from AssetService becomes a uri the renderer resolves
		env.Content = setmetatable({
			fromObject = function(object)
				local uri = editable.uriOf(object)
				if uri then
					return Content.fromUri(uri)
				end
				return Content.fromObject(unwrapArg(world, object))
			end,
		}, { __index = Content, __metatable = "The metatable is locked" })
	end
	-- Returns the real env only if it's this world's (game is our proxy); any other env or a miscounted
	-- level gets the sandbox env, so the real game never leaks. Imported only when a run names it.
	env.getfenv = function(target)
		local t = type(target)
		local e
		if target == nil then
			e = realGetfenv(2)
		elseif t == "number" then
			e = realGetfenv(if target == 0 then 0 else target + 1)
		elseif t == "function" then
			e = realGetfenv(target)
		else
			error(`invalid argument #1 to 'getfenv' (number expected, got {typeName(target)})`, 2)
		end
		if type(e) ~= "table" then
			return env
		end
		-- A real or foreign script env holds the real game/workspace, so it becomes the sandbox env;
		-- a user's own env (their chunk or a setfenv'd one) can't hold them and passes through.
		local ok1, eg = pcall(function()
			return e.game
		end)
		local ok2, ew = pcall(function()
			return e.workspace
		end)
		if (ok1 and eg == realGame) or (ok2 and ew == realWorkspace) then
			return env
		end
		return e
	end
	env.firesignal = firesignal
	env.fireevent = fireevent
	env.shared = world.shared
	env.Instance = table.freeze({
		new = function(className, parent)
			local ok, inst = pcall(realInstance.new, className)
			if not ok then
				error(inst, 0)
			end
			pin(world, inst)
			attachExtensions(self, inst)
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
			attachExtensions(self, inst)
			return wrap(world, inst)
		end,
	})
	env.stats = function()
		return wrap(world, realStats())
	end
	env.Stats = env.stats
	env.PluginManager = function()
		return wrap(world, realPluginManager())
	end
	env.RaycastParams = makeParamsLib(world, realRaycastParams, "RaycastParams")
	env.OverlapParams = makeParamsLib(world, realOverlapParams, "OverlapParams")
	for name, kind in GLOBALS do
		if (kind == "wrap" or kind == "auto") and env[name] == nil then
			local v = GLOBAL_VALUES[name]
			if v ~= nil then
				env[name] = autoWrap(world, v)
			end
		end
	end
	env.settings = function()
		return wrap(world, realSettings())
	end
	env.UserSettings = function()
		return wrap(world, realUserSettings())
	end
	local modules = self.modules
	local assetModules = {}
	-- Runs ModuleScript sources (owned, shared or asset-loaded) in this world so they never see the
	-- real game. LOADING isn't NIL because a module may return nil, which is cached as NIL.
	local LOADING = newproxy(false)
	local loadingThread = {}
	local loadErrors = setmetatable({}, { __mode = "k" })
	local requireFrom
	local function requireSource(real, scriptProxy)
		local cached = modules[real]
		if cached == LOADING then
			-- Like the engine: only the loading thread's own chain is a cycle; other threads wait.
			if loadingThread[real] == coroutine.running() then
				error(`Requested module '{real.Name}' was required recursively`, 0)
			end
			while modules[real] == LOADING do
				task.wait()
			end
			cached = modules[real]
			if cached == nil then
				error(loadErrors[real] or `Requested module '{real.Name}' experienced an error while loading`, 0)
			end
			return unbox(cached)
		elseif cached ~= nil then
			return unbox(cached)
		end
		modules[real] = LOADING
		loadingThread[real] = coroutine.running()
		local function failed(msg)
			modules[real] = nil
			loadingThread[real] = nil
			loadErrors[real] = msg
			error(msg, 0)
		end
		local modEnv = table.clone(env)
		modEnv.script = scriptProxy or wrap(world, real)
		modEnv.require = function(target)
			return requireFrom(modEnv.script, target)
		end
		local fx, compileErr = hooks.execute(real.Name, sourceOf(real), modEnv)
		if not fx then
			local line, msg = tostring(compileErr):match(":(%d+): (.+)$")
			failed(if line
				then `Syntax error in required module '{real.Name}' at line {line}: {msg}`
				else `Requested module '{real.Name}' failed to compile: {compileErr}`)
		end
		local res = table.pack(pcall(fx))
		if not res[1] then
			failed(res[2])
		end
		if res.n ~= 2 then
			failed("Module code did not return exactly one value")
		end
		modules[real] = box(res[2])
		loadingThread[real] = nil
		return res[2]
	end
	-- require-by-string resolves through proxies so paths can't climb out of this world; strings
	-- never reach the real require, which would resolve them from here.
	local function resolvePath(path, from)
		local function fail(msg)
			error(`error requiring "{path}": {msg}`, 0)
		end
		local parts = string.split(path, "/")
		local head = parts[1]
		local cur
		if head == "." or head == ".." then
			cur = from and from.Parent
			if cur and head == ".." then
				cur = cur.Parent
			end
			if not cur then
				fail("could not get parent of requiring context")
			end
		elseif string.lower(head) == "@self" then
			cur = from
			if not cur then
				fail("could not get requiring context")
			end
		elseif string.lower(head) == "@game" then
			cur = env.game
		elseif string.sub(head, 1, 1) == "@" then
			fail(`{head} is not a valid alias`)
		else
			fail("require path must start with a valid prefix: ./, ../, or @")
		end
		for i = 2, #parts do
			local name = parts[i]
			if name == ".." then
				cur = cur.Parent
				if not cur then
					fail("could not get parent of component")
				end
			elseif name ~= "." and name ~= "" then
				local child = cur:FindFirstChild(name)
				if not child then
					fail(`could not resolve child component "{name}"`)
				end
				cur = child
			end
		end
		if not cur:IsA("ModuleScript") then
			fail(`{cur:GetFullName()} is a {cur.ClassName}, not a ModuleScript`)
		end
		return cur
	end
	requireFrom = function(from, target)
		if type(target) == "string" and target:sub(1, 6) == "@lune/" then
			return env.require(target)
		end
		if type(target) == "string" and tonumber(target) == nil then
			return env.require(resolvePath(target, from))
		end
		return env.require(target)
	end
	env.require = function(target)
		if type(target) == "string" and target:sub(1, 6) == "@lune/" then
			if not hooks.luneRequire then error("Lune-style libraries are unavailable on this worker", 2) end
			return hooks.luneRequire(target)
		end
		if type(target) == "string" and tonumber(target) == nil then
			return env.require(resolvePath(target, env.script))
		end
		local st = states[target]
		if st and st.real == hooks.module then
			error("Requested module was required recursively", 0)
		end
		if st and st.real:IsA("ModuleScript") and hooks.execute then
			return requireSource(st.real, target)
		end
		-- require(assetId): load the asset and run its ModuleScript sandboxed, like require(id).
		local id = if type(target) == "number" then target else tonumber(target)
		if id and hooks.execute then
			local cached = assetModules[id]
			if cached ~= nil then
				return unbox(cached)
			end
			local ok, container = pcall(InsertService.LoadAsset, InsertService, id)
			if not ok then
				error(rewrite(world, container), 0)
			end
			-- Real require(id) runs the direct child ModuleScript named MainModule.
			local mod = if container:IsA("ModuleScript") and container.Name == "MainModule"
				then container
				else container:FindFirstChild("MainModule")
			if not mod or not mod:IsA("ModuleScript") then
				error(`Unable to find module for asset id {id}. Does the asset have a ModuleScript named 'MainModule'?`, 0)
			end
			local res = requireSource(mod)
			assetModules[id] = box(res)
			return res
		end
		return copyWrap(world, realRequire(unwrapArg(world, target)))
	end
	-- LoadEnv libraries that inspect values with the real typeof need real Instances
	for _, key in { "PacketSizeCounter" } do
		local lib = env[key]
		if type(lib) == "table" then
			local bounded = {}
			for name, v in lib do
				if type(v) == "function" then
					bounded[name] = function(...)
						return v(unwrapN(world, ...))
					end
				else
					bounded[name] = v
				end
			end
			env[key] = table.freeze(bounded)
		end
	end
	local rawExecute = env._execute
	if type(rawExecute) == "function" then
		env._execute = function(...)
			local fx, m = rawExecute(...)
			if fx and realTypeof(m) == "Instance" then
				pin(world, m)
				m = wrap(world, m)
			end
			return fx, m
		end
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

-- LuauBot refuses to run a run that expected the sandbox unless this flag is set
function Context:apply(env)
	self:_apply(env)
	self.hooks.sandboxApplied = true
end

function Sandbox.disabled(env, userId, hooks)
	-- shares `shared` with the user's sandboxed runs going at the same time, without keeping a world
	local w = worlds[tostring(userId)]
	env.shared = if w then w.shared else {}
	nosandboxRuns += 1
	placeAll()
	local done = false
	if hooks and hooks.onCleanup then
		table.insert(hooks.onCleanup, function()
			if not done then
				done = true
				nosandboxRuns -= 1
				placeAll()
			end
		end)
	end
end

Sandbox.typeof = sandboxTypeof
Sandbox._states = states
Sandbox._worlds = worlds

return Sandbox
