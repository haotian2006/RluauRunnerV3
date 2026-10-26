--!native
--!optimize 2

local crc0 = buffer.create(1024)
local crc1 = buffer.create(1024)
local crc2 = buffer.create(1024)
local crc3 = buffer.create(1024)

for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if c % 2 == 1 then
			c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
		else
			c = bit32.rshift(c, 1)
		end
	end
	buffer.writeu32(crc0, i * 4, c)
end

for i = 0, 255 do
	local c = buffer.readu32(crc0, i * 4)
	c = bit32.bxor(bit32.rshift(c, 8), buffer.readu32(crc0, bit32.band(c, 0xFF) * 4))
	buffer.writeu32(crc1, i * 4, c)
	c = bit32.bxor(bit32.rshift(c, 8), buffer.readu32(crc0, bit32.band(c, 0xFF) * 4))
	buffer.writeu32(crc2, i * 4, c)
	c = bit32.bxor(bit32.rshift(c, 8), buffer.readu32(crc0, bit32.band(c, 0xFF) * 4))
	buffer.writeu32(crc3, i * 4, c)
end

local function crc32buf(buf: buffer, offset: number, len: number): number
	local c = 0xFFFFFFFF
	local i = offset
	local stop = offset + len - 3

	while i < stop do
		local v = bit32.bxor(c, buffer.readu32(buf, i))
		c = bit32.bxor(
			bit32.bxor(
				buffer.readu32(crc3, bit32.band(v, 0xFF) * 4),
				buffer.readu32(crc2, bit32.band(bit32.rshift(v, 8), 0xFF) * 4)
			),
			bit32.bxor(
				buffer.readu32(crc1, bit32.band(bit32.rshift(v, 16), 0xFF) * 4),
				buffer.readu32(crc0, bit32.rshift(v, 24) * 4)
			)
		)
		i += 4
	end

	local last = offset + len
	while i < last do
		c = bit32.bxor(
			bit32.rshift(c, 8),
			buffer.readu32(crc0, bit32.band(bit32.bxor(c, buffer.readu8(buf, i)), 0xFF) * 4)
		)
		i += 1
	end

	return bit32.bxor(c, 0xFFFFFFFF)
end

local function crc32str(data: string): number
	local c = 0xFFFFFFFF
	for i = 1, #data do
		c = bit32.bxor(
			bit32.rshift(c, 8),
			buffer.readu32(crc0, bit32.band(bit32.bxor(c, string.byte(data, i)), 0xFF) * 4)
		)
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function pack32be(value: number): string
	return string.char(
		bit32.band(bit32.rshift(value, 24), 0xFF),
		bit32.band(bit32.rshift(value, 16), 0xFF),
		bit32.band(bit32.rshift(value, 8), 0xFF),
		bit32.band(value, 0xFF)
	)
end

local function createChunk(chunkType: string, data: string): string
	local typeAndData = chunkType .. data
	return pack32be(#data) .. typeAndData .. pack32be(crc32str(typeAndData))
end

-- Deferred modulo: 2^20-byte chunks can't overflow s2 in a double.
local function adler32buf(buf: buffer, len: number): number
	local s1 = 1
	local s2 = 0
	local i = 0

	while i < len do
		local stop = i + math.min(1048576, len - i)
		local quad = stop - 3

		while i < quad do
			local px = buffer.readu32(buf, i)
			local b0 = bit32.band(px, 0xFF)
			local b1 = bit32.band(bit32.rshift(px, 8), 0xFF)
			local b2 = bit32.band(bit32.rshift(px, 16), 0xFF)
			local b3 = bit32.rshift(px, 24)
			s2 += 4 * s1 + 4 * b0 + 3 * b1 + 2 * b2 + b3
			s1 += b0 + b1 + b2 + b3
			i += 4
		end

		while i < stop do
			s1 += buffer.readu8(buf, i)
			s2 += s1
			i += 1
		end

		s1 %= 65521
		s2 %= 65521
	end

	return s2 * 65536 + s1
end

-- DEFLATE (RFC 1951 §3.2.6) sends Huffman codes MSB-first and everything else LSB-first, so the
-- fixed codes are pre-reversed and written like any other field.
local litCode = buffer.create(288 * 2)
local litBits = buffer.create(288)
local distCode = buffer.create(30 * 2)

local function reverseBits(code: number, len: number): number
	local r = 0
	for _ = 1, len do
		r = bit32.bor(bit32.lshift(r, 1), bit32.band(code, 1))
		code = bit32.rshift(code, 1)
	end
	return r
end

for i = 0, 287 do
	local code, len
	if i <= 143 then
		code, len = 0x30 + i, 8
	elseif i <= 255 then
		code, len = 0x190 + i - 144, 9
	elseif i <= 279 then
		code, len = i - 256, 7
	else
		code, len = 0xC0 + i - 280, 8
	end
	buffer.writeu16(litCode, i * 2, reverseBits(code, len))
	buffer.writeu8(litBits, i, len)
end

for i = 0, 29 do
	buffer.writeu16(distCode, i * 2, reverseBits(i, 5))
end

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }

local lenSym = buffer.create(259 * 2)
local lenExtraBits = buffer.create(259)
local lenExtraVal = buffer.create(259)

for i = 1, 29 do
	local base = LEN_BASE[i]
	local extra = LEN_EXTRA[i]
	local last = if i == 29 then 258 else LEN_BASE[i + 1] - 1
	for len = base, last do
		buffer.writeu16(lenSym, len * 2, 256 + i)
		buffer.writeu8(lenExtraBits, len, extra)
		buffer.writeu8(lenExtraVal, len, len - base)
	end
end

local distSym = buffer.create(32769)
local distExtraBits = buffer.create(32769)
local distExtraVal = buffer.create(32769 * 2)

for i = 1, 30 do
	local base = DST_BASE[i]
	local extra = DST_EXTRA[i]
	local last = if i == 30 then 32768 else DST_BASE[i + 1] - 1
	for d = base, last do
		buffer.writeu8(distSym, d, i - 1)
		buffer.writeu8(distExtraBits, d, extra)
		buffer.writeu16(distExtraVal, d * 2, d - base)
	end
end

local HASH_BITS = 15
local HASH_SIZE = bit32.lshift(1, HASH_BITS)
local HASH_MASK = HASH_SIZE - 1
local MAX_DIST = 32768
local MAX_MATCH = 258
local MIN_MATCH = 3
local MAX_CHAIN = 8
local NICE_MATCH = 64

local head = buffer.create(HASH_SIZE * 4)
local prev: buffer = buffer.create(4)

local function deflateFixed(raw: buffer, rawLen: number, out: buffer, outPos: number): number
	if buffer.len(prev) < rawLen * 4 then
		prev = buffer.create(math.max(rawLen, 1) * 4)
	end
	buffer.fill(head, 0, 0, HASH_SIZE * 4)

	buffer.writeu8(out, outPos, 0x78)
	buffer.writeu8(out, outPos + 1, 0x01)
	local wp = outPos + 2

	local acc = 0
	local accBits = 0

	acc = 3
	accBits = 3

	local i = 0
	local lastHash = rawLen - MIN_MATCH

	while i < rawLen do
		local sym, extraBits, extraVal
		local matchLen = 0
		local matchDist = 0

		if i <= lastHash then
			local h = bit32.band(
				bit32.bxor(
					bit32.bxor(bit32.lshift(buffer.readu8(raw, i), 10), bit32.lshift(buffer.readu8(raw, i + 1), 5)),
					buffer.readu8(raw, i + 2)
				),
				HASH_MASK
			)

			local cand = buffer.readu32(head, h * 4) -- stores position + 1
			local maxLen = math.min(MAX_MATCH, rawLen - i)
			local chain = MAX_CHAIN
			local floorPos = i - MAX_DIST

			while cand ~= 0 and chain > 0 do
				local p = cand - 1
				if p <= floorPos then
					break
				end

				if buffer.readu8(raw, p + matchLen) == buffer.readu8(raw, i + matchLen) then
					local n = 0
					while n < maxLen and buffer.readu8(raw, p + n) == buffer.readu8(raw, i + n) do
						n += 1
					end
					if n > matchLen then
						matchLen = n
						matchDist = i - p
						if n >= NICE_MATCH or n >= maxLen then
							break
						end
					end
				end

				cand = buffer.readu32(prev, p * 4)
				chain -= 1
			end

			buffer.writeu32(prev, i * 4, buffer.readu32(head, h * 4))
			buffer.writeu32(head, h * 4, i + 1)
		end

		if matchLen >= MIN_MATCH then
			sym = buffer.readu16(lenSym, matchLen * 2)
			extraBits = buffer.readu8(lenExtraBits, matchLen)
			extraVal = buffer.readu8(lenExtraVal, matchLen)

			acc = bit32.bor(acc, bit32.lshift(buffer.readu16(litCode, sym * 2), accBits))
			accBits += buffer.readu8(litBits, sym)
			while accBits >= 8 do
				buffer.writeu8(out, wp, bit32.band(acc, 0xFF))
				wp += 1
				acc = bit32.rshift(acc, 8)
				accBits -= 8
			end

			if extraBits > 0 then
				acc = bit32.bor(acc, bit32.lshift(extraVal, accBits))
				accBits += extraBits
				while accBits >= 8 do
					buffer.writeu8(out, wp, bit32.band(acc, 0xFF))
					wp += 1
					acc = bit32.rshift(acc, 8)
					accBits -= 8
				end
			end

			local dsym = buffer.readu8(distSym, matchDist)
			acc = bit32.bor(acc, bit32.lshift(buffer.readu16(distCode, dsym * 2), accBits))
			accBits += 5
			while accBits >= 8 do
				buffer.writeu8(out, wp, bit32.band(acc, 0xFF))
				wp += 1
				acc = bit32.rshift(acc, 8)
				accBits -= 8
			end

			local dExtra = buffer.readu8(distExtraBits, matchDist)
			if dExtra > 0 then
				acc = bit32.bor(acc, bit32.lshift(buffer.readu16(distExtraVal, matchDist * 2), accBits))
				accBits += dExtra
				while accBits >= 8 do
					buffer.writeu8(out, wp, bit32.band(acc, 0xFF))
					wp += 1
					acc = bit32.rshift(acc, 8)
					accBits -= 8
				end
			end

			local stop = math.min(i + matchLen, lastHash + 1)
			local j = i + 1
			while j < stop do
				local h = bit32.band(
					bit32.bxor(
						bit32.bxor(
							bit32.lshift(buffer.readu8(raw, j), 10),
							bit32.lshift(buffer.readu8(raw, j + 1), 5)
						),
						buffer.readu8(raw, j + 2)
					),
					HASH_MASK
				)
				buffer.writeu32(prev, j * 4, buffer.readu32(head, h * 4))
				buffer.writeu32(head, h * 4, j + 1)
				j += 1
			end

			i += matchLen
		else
			local lit = buffer.readu8(raw, i)
			acc = bit32.bor(acc, bit32.lshift(buffer.readu16(litCode, lit * 2), accBits))
			accBits += buffer.readu8(litBits, lit)
			while accBits >= 8 do
				buffer.writeu8(out, wp, bit32.band(acc, 0xFF))
				wp += 1
				acc = bit32.rshift(acc, 8)
				accBits -= 8
			end
			i += 1
		end
	end

	acc = bit32.bor(acc, bit32.lshift(buffer.readu16(litCode, 256 * 2), accBits))
	accBits += buffer.readu8(litBits, 256)
	while accBits >= 8 do
		buffer.writeu8(out, wp, bit32.band(acc, 0xFF))
		wp += 1
		acc = bit32.rshift(acc, 8)
		accBits -= 8
	end
	if accBits > 0 then
		buffer.writeu8(out, wp, bit32.band(acc, 0xFF))
		wp += 1
	end

	buffer.writeu32(out, wp, bit32.byteswap(adler32buf(raw, rawLen)))
	return wp + 4
end

local function filterRows(src: buffer, width: number, height: number, raw: buffer)
	local rowBytes = width * 4
	local stride = rowBytes + 1

	for y = 0, height - 1 do
		local rowOff = y * rowBytes
		local prevOff = rowOff - rowBytes
		local dst = y * stride
		local topRow = y == 0

		local sNone = 0
		local sSub = 0
		local sUp = 0
		local sPaeth = 0

		local x = 0
		while x < rowBytes do
			local groupEnd = math.min(x + 4, rowBytes)
			for o = x, groupEnd - 1 do
				local cur = buffer.readu8(src, rowOff + o)
				local a = if o >= 4 then buffer.readu8(src, rowOff + o - 4) else 0
				local b = if topRow then 0 else buffer.readu8(src, prevOff + o)
				local c = if o >= 4 and not topRow then buffer.readu8(src, prevOff + o - 4) else 0

				local p = a + b - c
				local pa = if p > a then p - a else a - p
				local pb = if p > b then p - b else b - p
				local pc = if p > c then p - c else c - p
				local pred = if pa <= pb and pa <= pc then a elseif pb <= pc then b else c

				local fSub = bit32.band(cur - a, 0xFF)
				local fUp = bit32.band(cur - b, 0xFF)
				local fPaeth = bit32.band(cur - pred, 0xFF)

				sNone += if cur < 128 then cur else 256 - cur
				sSub += if fSub < 128 then fSub else 256 - fSub
				sUp += if fUp < 128 then fUp else 256 - fUp
				sPaeth += if fPaeth < 128 then fPaeth else 256 - fPaeth
			end
			x += 16
		end

		if sNone <= sSub and sNone <= sUp and sNone <= sPaeth then
			buffer.writeu8(raw, dst, 0)
			buffer.copy(raw, dst + 1, src, rowOff, rowBytes)
		elseif sSub <= sUp and sSub <= sPaeth then
			buffer.writeu8(raw, dst, 1)
			for o = 0, 3 do
				buffer.writeu8(raw, dst + 1 + o, buffer.readu8(src, rowOff + o))
			end
			for o = 4, rowBytes - 1 do
				buffer.writeu8(
					raw,
					dst + 1 + o,
					bit32.band(buffer.readu8(src, rowOff + o) - buffer.readu8(src, rowOff + o - 4), 0xFF)
				)
			end
		elseif sUp <= sPaeth then
			buffer.writeu8(raw, dst, 2)
			if topRow then
				buffer.copy(raw, dst + 1, src, rowOff, rowBytes)
			else
				for o = 0, rowBytes - 1 do
					buffer.writeu8(
						raw,
						dst + 1 + o,
						bit32.band(buffer.readu8(src, rowOff + o) - buffer.readu8(src, prevOff + o), 0xFF)
					)
				end
			end
		else
			buffer.writeu8(raw, dst, 4)
			for o = 0, rowBytes - 1 do
				local cur = buffer.readu8(src, rowOff + o)
				local a = if o >= 4 then buffer.readu8(src, rowOff + o - 4) else 0
				local b = if topRow then 0 else buffer.readu8(src, prevOff + o)
				local c = if o >= 4 and not topRow then buffer.readu8(src, prevOff + o - 4) else 0

				local p = a + b - c
				local pa = if p > a then p - a else a - p
				local pb = if p > b then p - b else b - p
				local pc = if p > c then p - c else c - p
				local pred = if pa <= pb and pa <= pc then a elseif pb <= pc then b else c

				buffer.writeu8(raw, dst + 1 + o, bit32.band(cur - pred, 0xFF))
			end
		end
	end
end

return function(image, println, timmeout)
	local line = println("PNG: Starting encoding...")
	local width = image.Size.X
	local height = image.Size.Y
	local src = image.imageBuffer

	local ihdr = pack32be(width)
		.. pack32be(height)
		.. string.char(
			8,
			6,
			0,
			0,
			0
		)

	println("PNG: Filtering scanlines...", line)
	task.wait()

	local rowBytes = width * 4
	local rawLen = (rowBytes + 1) * height
	local raw = buffer.create(math.max(rawLen, 1))
	filterRows(src, width, height, raw)

	println("PNG: Compressing...", line)
	task.wait()

	-- Fixed Huffman expands incompressible data by at most 9/8, plus zlib header, block header and Adler-32.
	local idat = buffer.create(4 + 2 + math.ceil(rawLen * 9 / 8) + 16)
	buffer.writestring(idat, 0, "IDAT")
	local idatLen = deflateFixed(raw, rawLen, idat, 4)

	local exact = buffer.create(idatLen)
	buffer.copy(exact, 0, idat, 0, idatLen)

	local png = table.concat({
		string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A),
		createChunk("IHDR", ihdr),
		pack32be(idatLen - 4),
		buffer.tostring(exact),
		pack32be(crc32buf(exact, 0, idatLen)),
		createChunk("IEND", ""),
	})

	println("PNG: Encoding complete!", line)
	task.wait()

	return png
end
