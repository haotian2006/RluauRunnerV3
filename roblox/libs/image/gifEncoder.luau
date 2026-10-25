--!native
--!optimize 2

-- Dictionary: (prefixCode, byte) -> code, one u32 per slot. Each entry stores
-- generation * 4096 + code, so a reset is a generation bump instead of a 4MB clear.
local DICT_BYTES = 4096 * 256 * 4

local function u16le(n: number): string
	return string.char(bit32.band(n, 0xFF), bit32.band(bit32.rshift(n, 8), 0xFF))
end

-- LZW over a u8 buffer of palette indices. Keyed by prefixCode * 256 + byte, so
-- there is no per-pixel string build or hash lookup. Returns the GIF sub-blocks
-- and the last generation it used.
local function lzwCompress(idx: buffer, count: number, minCodeSize: number, dict: buffer, codes: buffer, gen: number): string
	local CLEAR = bit32.lshift(1, minCodeSize)
	local EOI = CLEAR + 1

	local codeSize = minCodeSize + 1
	local limit = bit32.lshift(1, codeSize)
	local nextCode = EOI + 1

	local acc = 0
	local accBits = 0
	local wp = 0

	-- Initial CLEAR
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

	-- Pack into 255-byte sub-blocks (trailing terminator byte is already 0)
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

-- Build 256-color global palette (3-3-2)
local function buildGlobalPalette(): string
	local t = table.create(256)
	for i = 0, 255 do
		local r = bit32.band(bit32.rshift(i, 5), 7)
		local g = bit32.band(bit32.rshift(i, 2), 7)
		local b = bit32.band(i, 3)
		t[i + 1] = string.char(
			math.floor(r / 7 * 255 + 0.5),
			math.floor(g / 7 * 255 + 0.5),
			math.floor(b / 3 * 255 + 0.5)
		)
	end
	return table.concat(t)
end

local globalPalette = buildGlobalPalette()

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
	out[#out + 1] = globalPalette

	-- Netscape Loop
	out[#out + 1] = "\x21\xFF\x0BNETSCAPE2.0\x03\x01" .. u16le(loopCount) .. "\x00"

	println(string.format("GIF: Encoding %d frames...", #frames), line)
	task.wait()

	-- Scratch reused across frames. Worst case LZW emits a 12-bit code per input
	-- byte, i.e. 1.5 bytes per pixel, plus the trailing codes.
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
				-- One u32 read per pixel; 3-3-2 quantize is pure bit math.
				local px = buffer.readu32(buf, p)
				buffer.writeu8(
					idx,
					w,
					bit32.band(bit32.rshift(px, 5), 7) * 32
						+ bit32.band(bit32.rshift(px, 13), 7) * 4
						+ bit32.band(bit32.rshift(px, 22), 3)
				)
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
