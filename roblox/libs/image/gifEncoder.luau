--!native
--!optimize 2

-- Dictionary: (prefixCode, byte) -> code, one u32 per slot. Each entry stores
-- generation * 4096 + code, so a reset is a generation bump instead of a 4MB clear.
local DICT_BYTES = 4096 * 256 * 4

local function u16le(n: number): string
	return string.char(bit32.band(n, 0xFF), bit32.band(bit32.rshift(n, 8), 0xFF))
end

local function lzwCompress(idx: buffer, count: number, minCodeSize: number, dict: buffer, codes: buffer, gen: number): string
	local CLEAR = bit32.lshift(1, minCodeSize)
	local EOI = CLEAR + 1

	local codeSize = minCodeSize + 1
	local limit = bit32.lshift(1, codeSize)
	local nextCode = EOI + 1

	local acc = 0
	local accBits = 0
	local wp = 0

	acc = CLEAR
	accBits = codeSize
	while accBits >= 8 do
		buffer.writeu8(codes, wp, bit32.band(acc, 0xFF))
		wp += 1
		acc = bit32.rshift(acc, 8)
		accBits -= 8
	end

	if count > 0 then
		local prefix = buffer.readu8(idx, 0)

		for i = 1, count - 1 do
			local k = buffer.readu8(idx, i)
			local key = prefix * 1024 + k * 4
			local e = buffer.readu32(dict, key)

			if bit32.rshift(e, 12) == gen then
				prefix = bit32.band(e, 0xFFF)
			else
				acc = bit32.bor(acc, bit32.lshift(prefix, accBits))
				accBits += codeSize
				while accBits >= 8 do
					buffer.writeu8(codes, wp, bit32.band(acc, 0xFF))
					wp += 1
					acc = bit32.rshift(acc, 8)
					accBits -= 8
				end

				if nextCode < 4096 then
					buffer.writeu32(dict, key, gen * 4096 + nextCode)
					nextCode += 1
					if nextCode > limit and codeSize < 12 then
						codeSize += 1
						limit = bit32.lshift(1, codeSize)
					end
				end

				if nextCode >= 4096 then
					acc = bit32.bor(acc, bit32.lshift(CLEAR, accBits))
					accBits += codeSize
					while accBits >= 8 do
						buffer.writeu8(codes, wp, bit32.band(acc, 0xFF))
						wp += 1
						acc = bit32.rshift(acc, 8)
						accBits -= 8
					end

					gen += 1
					nextCode = EOI + 1
					codeSize = minCodeSize + 1
					limit = bit32.lshift(1, codeSize)
				end

				prefix = k
			end
		end

		acc = bit32.bor(acc, bit32.lshift(prefix, accBits))
		accBits += codeSize
		while accBits >= 8 do
			buffer.writeu8(codes, wp, bit32.band(acc, 0xFF))
			wp += 1
			acc = bit32.rshift(acc, 8)
			accBits -= 8
		end
	end

	acc = bit32.bor(acc, bit32.lshift(EOI, accBits))
	accBits += codeSize
	while accBits >= 8 do
		buffer.writeu8(codes, wp, bit32.band(acc, 0xFF))
		wp += 1
		acc = bit32.rshift(acc, 8)
		accBits -= 8
	end

	if accBits > 0 then
		buffer.writeu8(codes, wp, bit32.band(acc, 0xFF))
		wp += 1
	end

	-- The trailing terminator byte is already 0.
	local out = buffer.create(wp + math.ceil(wp / 255) + 1)
	local sp = 0
	local dp = 0
	while sp < wp do
		local n = math.min(255, wp - sp)
		buffer.writeu8(out, dp, n)
		dp += 1
		buffer.copy(out, dp, codes, sp, n)
		dp += n
		sp += n
	end

	return buffer.tostring(out), gen
end

local function expand5(v: number): number
	return bit32.bor(bit32.lshift(v, 3), bit32.rshift(v, 2))
end

local function channelOf(k: number, c: number): number
	if c == 0 then
		return bit32.rshift(k, 10)
	elseif c == 1 then
		return bit32.band(bit32.rshift(k, 5), 31)
	end
	return bit32.band(k, 31)
end

-- Same integer steps as image_encoding.cpp so both give the same bytes.
local function buildPalette(frames, pause: () -> ()): (string, buffer)
	local hist = buffer.create(32768 * 4)
	for _, img in frames do
		local buf = img.imageBuffer
		local n = buffer.len(buf)
		local p = 0
		while p < n do
			local px = buffer.readu32(buf, p)
			local o = (bit32.band(bit32.rshift(px, 3), 31) * 1024 + bit32.band(bit32.rshift(px, 11), 31) * 32 + bit32.band(bit32.rshift(px, 19), 31)) * 4
			buffer.writeu32(hist, o, buffer.readu32(hist, o) + 1)
			p += 4
		end
		pause()
	end
	local bins = {}
	for k = 0, 32767 do
		if buffer.readu32(hist, k * 4) > 0 then
			table.insert(bins, k)
		end
	end
	local function count(k)
		return buffer.readu32(hist, k * 4)
	end

	-- a box is { start, end (exclusive), count, range, channel } over bins
	local function measure(start, e)
		local lo0, lo1, lo2, hi0, hi1, hi2, total = 31, 31, 31, 0, 0, 0, 0
		for i = start, e - 1 do
			local k = bins[i]
			local v0, v1, v2 = channelOf(k, 0), channelOf(k, 1), channelOf(k, 2)
			lo0, hi0 = math.min(lo0, v0), math.max(hi0, v0)
			lo1, hi1 = math.min(lo1, v1), math.max(hi1, v1)
			lo2, hi2 = math.min(lo2, v2), math.max(hi2, v2)
			total += count(k)
		end
		local range, channel = -1, 0
		for c, r in { hi0 - lo0, hi1 - lo1, hi2 - lo2 } do
			if r > range then
				range, channel = r, c - 1
			end
		end
		return { start, e, total, range, channel }
	end

	local boxes = {}
	if #bins > 0 then
		boxes[1] = measure(1, #bins + 1)
	end
	local sorted = table.create(#bins)
	while #boxes < 256 do
		local best, bestScore = nil, 0
		for i, box in boxes do
			local score = box[3] * (box[4] + 1)
			if box[4] > 0 and score > bestScore then
				best, bestScore = i, score
			end
		end
		if not best then
			break
		end
		local box = boxes[best]
		local start, e, ch = box[1], box[2], box[5]
		local starts = table.create(33, 0)
		for i = start, e - 1 do
			local v = channelOf(bins[i], ch) + 2
			starts[v] += 1
		end
		for v = 1, 32 do
			starts[v + 1] += starts[v]
		end
		for i = start, e - 1 do
			local k = bins[i]
			local v = channelOf(k, ch) + 1
			sorted[start + starts[v]] = k
			starts[v] += 1
		end
		for i = start, e - 1 do
			bins[i] = sorted[i]
		end
		local seen, cut = 0, e - 1
		for i = start, e - 2 do
			seen += count(bins[i])
			if seen * 2 >= box[3] then
				cut = i + 1
				break
			end
		end
		boxes[best] = measure(start, cut)
		table.insert(boxes, measure(cut, e))
		pause()
	end

	local rgb = buffer.create(768)
	for i, box in boxes do
		local s0, s1, s2 = 0, 0, 0
		for j = box[1], box[2] - 1 do
			local k = bins[j]
			local n = count(k)
			s0 += n * expand5(channelOf(k, 0))
			s1 += n * expand5(channelOf(k, 1))
			s2 += n * expand5(channelOf(k, 2))
		end
		local total = box[3]
		local o = (i - 1) * 3
		buffer.writeu8(rgb, o, (s0 + total // 2) // total)
		buffer.writeu8(rgb, o + 1, (s1 + total // 2) // total)
		buffer.writeu8(rgb, o + 2, (s2 + total // 2) // total)
	end
	local map = buffer.create(32768)
	for n, k in bins do
		local r, g, b = expand5(channelOf(k, 0)), expand5(channelOf(k, 1)), expand5(channelOf(k, 2))
		local best, bestDistance = 0, math.huge
		for i = 0, #boxes - 1 do
			local dr = r - buffer.readu8(rgb, i * 3)
			local dg = g - buffer.readu8(rgb, i * 3 + 1)
			local db = b - buffer.readu8(rgb, i * 3 + 2)
			local d = dr * dr + dg * dg + db * db
			if d < bestDistance then
				best, bestDistance = i, d
			end
		end
		buffer.writeu8(map, k, best)
		if n % 256 == 0 then
			pause()
		end
	end
	return buffer.tostring(rgb), map
end

-- Shared across calls: every lzwCompress call takes a fresh generation and never
-- yields, so a concurrent encode can only waste generations, not corrupt state.
local dict = buffer.create(DICT_BYTES)
local gen = 0

return function(frames, durations, options, println)
	local line = println("GIF: Starting encoding...")
	options = options or {}
	local loopCount = options.loop or 0
	local yieldTime = options.yield or 1 / 60
	assert(#frames > 0)
	assert(#frames == #durations)
	local width = frames[1].Size.X
	local height = frames[1].Size.Y

	local out = {}
	out[#out + 1] = "GIF89a"
	out[#out + 1] = u16le(width) .. u16le(height) .. string.char(0xF7, 0x00, 0x00)

	println("GIF: Building palette...", line)
	task.wait()
	local paused = os.clock()
	local palette, map = buildPalette(frames, function()
		if os.clock() - paused > yieldTime then
			task.wait()
			paused = os.clock()
		end
	end)
	out[#out + 1] = palette

	out[#out + 1] = "\x21\xFF\x0BNETSCAPE2.0\x03\x01" .. u16le(loopCount) .. "\x00"

	println(string.format("GIF: Encoding %d frames...", #frames), line)
	task.wait()

	local pixels = width * height
	local idx = buffer.create(math.max(pixels, 1))
	local codes = buffer.create(math.max(pixels * 2, 1) + 64)

	local s = os.clock()
	for i = 1, #frames do
		local img = frames[i]
		local delay = math.floor(durations[i] * 100 + 0.5)

		println(string.format("GIF: Frame %d/%d - Quantizing pixels...", i, #frames), line)
		task.wait()

		out[#out + 1] = "\x21\xF9\x04" .. string.char(0x00) .. u16le(delay) .. string.char(0x00, 0x00)
		out[#out + 1] = "\x2C" .. u16le(0) .. u16le(0) .. u16le(width) .. u16le(height) .. string.char(0x00)

		local buf = img.imageBuffer
		local w = 0
		for y = 0, height - 1 do
			local p = y * width * 4
			for _ = 1, width do
				local px = buffer.readu32(buf, p)
				buffer.writeu8(idx, w, buffer.readu8(map, bit32.band(bit32.rshift(px, 3), 31) * 1024
					+ bit32.band(bit32.rshift(px, 11), 31) * 32 + bit32.band(bit32.rshift(px, 19), 31)))
				p += 4
				w += 1
			end

			if os.clock() - s > yieldTime then
				task.wait()
				s = os.clock()
				println(
					string.format(
						"GIF: Frame %d/%d - Quantizing pixels... (%d%%)",
						i,
						#frames,
						(y / height * 100)
					),
					line
				)
			end
		end

		println(string.format("GIF: Frame %d/%d - LZW compressing...", i, #frames), line)

		out[#out + 1] = string.char(8)
		gen += 1

		-- gen * 4096 + code has to stay inside a u32, so wrap with a real clear.
		if gen >= 1048000 then
			buffer.fill(dict, 0, 0, DICT_BYTES)
			gen = 1
		end

		local blocks, lastGen = lzwCompress(idx, pixels, 8, dict, codes, gen)
		out[#out + 1] = blocks
		gen = lastGen
	end

	println("GIF: Finalizing...", line)
	task.wait()

	out[#out + 1] = string.char(0x3B)

	println("GIF: Encoding complete!", line)
	task.wait()

	return table.concat(out)
end
