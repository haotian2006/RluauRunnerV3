-- Native metadata stays shallow; graph traversal uses the caller's sandbox view.
return function(shallow, kindOf)
	local LIMIT = 10000
	local SLOT_LIMIT = 10000
	local function slots(info)
		local storage = info.table
		if storage and storage.layoutAvailable then
			return storage.arrayCapacity + storage.hashSlots
		end
		return nil
	end
	local function inspect(value)
		local result = shallow(value)
		result.type = kindOf(value)
		local total, count, work = 0, 0, 0
		local partial, truncated = result.estimatePartial, false
		local scannedSlots = 0
		local seen, queue = {}, {}
		local tail = 0
		local function enqueue(v)
			work += 1
			if work > LIMIT then
				truncated = true
				return
			end
			local kind = type(v)
			-- Primitive slots are already included in their owning table's capacity.
			if kind == "nil" or kind == "boolean" or kind == "number" or kind == "vector" then
				return
			end
			if not seen[v] then
				seen[v] = true
				tail += 1
				queue[tail] = v
			end
		end
		enqueue(value)
		if tail == 0 then total = result.shallowBytes end
		local head = 1
		while head <= tail do
			local current = queue[head]
			queue[head] = nil
			head += 1
			local info = if head == 2 then result else shallow(current)
			total += info.shallowBytes
			count += 1
			partial = partial or info.estimatePartial
			local kind = kindOf(current)
			if not truncated and kind == "Instance" then
				-- Sandbox proxies filter these children before they reach the inspector.
				for _, child in current:GetChildren() do
					enqueue(child)
					if truncated then break end
				end
			elseif not truncated and type(current) == "table" then
				local capacity = slots(info)
				-- next() also scans empty slots, so reference counts alone cannot bound it.
				if capacity == nil or capacity > SLOT_LIMIT - scannedSlots then
					truncated = true
				else
					scannedSlots += capacity
					for key, item in next, current do
						enqueue(key)
						enqueue(item)
						if truncated then break end
					end
				end
			end
		end
		result.estimatedTotalBytes = total
		result.visitedObjects = count
		result.scannedTableSlots = scannedSlots
		result.truncated = truncated
		result.estimatePartial = partial or truncated
		result.estimateScope = "table keys/values and visible Instance descendants; excludes metatables, prototypes, function captures, class member graphs, allocator overhead and unknown engine allocations"
		if type(value) == "table" then
			local entries, n = {}, 0
			local capacity = slots(result)
			if capacity == nil or capacity > SLOT_LIMIT then
				result.entriesTruncated = true
			else
				for key, item in next, value do
					if n == 64 then result.entriesTruncated = true; break end
					local k, v = shallow(key), shallow(item)
					k.type, v.type = kindOf(key), kindOf(item)
					n += 1
					entries[n] = { key = k, value = v }
				end
			end
			result.entries = entries
		end
		return result
	end
	return inspect
end
