-- luau_native's C++ image encoders and filters, where a headless Studio worker loads the mod (the
-- `native` global): same results as the Luau code, several times faster. A native call can't
-- yield, so it blocks every run on that Studio; work past these limits stays in Luau.
-- Runs get `exports` as _native, never the native table (its hookMethod/defineProperty change
-- Instances for every script in the Studio).
local MAX_PIXEL_BYTES = 16 * 1024 * 1024 -- RGBA bytes of one PNG, or of all of a GIF's frames
local MAX_FILTER_WORK = 2 ^ 26 -- width * height * kernel weights

local lib = if type(native) == "table" then native else {}
local encodePng, encodeGif = lib.encodePng, lib.encodeGif
local convolveSeparable, convolve2D = lib.convolveSeparable, lib.convolve2D

local Native = {}

-- PNG bytes for an Image, or nil when the Luau encoder has to do it.
function Native.png(image): string?
	if not encodePng then
		return nil
	end
	local ok, png = pcall(function()
		local width, height = image.Size.X, image.Size.Y
		if width * height * 4 > MAX_PIXEL_BYTES then
			return nil
		end
		return encodePng(width, height, image.imageBuffer)
	end)
	return if ok then png else nil
end

-- GIF bytes for equally sized Images, or nil when the Luau encoder has to do it.
function Native.gif(frames, durations, options): string?
	if not encodeGif then
		return nil
	end
	local ok, gif = pcall(function()
		local width, height = frames[1].Size.X, frames[1].Size.Y
		if #frames * width * height * 4 > MAX_PIXEL_BYTES then
			return nil
		end
		local pixels = table.create(#frames)
		for i, frame in frames do
			if frame.Size.X ~= width or frame.Size.Y ~= height then
				return nil
			end
			pixels[i] = frame.imageBuffer
		end
		return encodeGif(width, height, pixels, durations, options and options.loop or 0)
	end)
	return if ok then gif else nil
end

-- These filter in place and return whether they did; a kernel native rejects (GaussianBlur(0)'s
-- NaN weights, say) is left to Luau.
function Native.separable(pixels: buffer, width: number, height: number, kernel: { number }): boolean
	if not convolveSeparable or width * height * #kernel > MAX_FILTER_WORK then
		return false
	end
	return (pcall(convolveSeparable, width, height, pixels, kernel))
end

function Native.kernel2D(pixels: buffer, width: number, height: number, kernel: { number }, size: number, divisor: number?, bias: number?): boolean
	if not convolve2D or width * height * size * size > MAX_FILTER_WORK then
		return false
	end
	return (pcall(convolve2D, width, height, pixels, kernel, size, divisor or 1, bias or 0))
end

local function area(width, height): number
	return if type(width) == "number" and type(height) == "number" then width * height else 0
end

local function tooLarge(what: string)
	error(`{what} is too large for _native; the Image library does it in Luau instead`, 3)
end

local exports = { clock = lib.clock, fnv1a = lib.fnv1a }
if encodePng then
	exports.encodePng = function(width, height, pixels, compression)
		if area(width, height) * 4 > MAX_PIXEL_BYTES then
			tooLarge("the image")
		end
		return encodePng(width, height, pixels, compression)
	end
end
if encodeGif then
	exports.encodeGif = function(width, height, frames, delays, loops)
		if type(frames) == "table" and #frames * area(width, height) * 4 > MAX_PIXEL_BYTES then
			tooLarge("the animation")
		end
		return encodeGif(width, height, frames, delays, loops)
	end
end
if convolveSeparable then
	exports.convolveSeparable = function(width, height, pixels, kernel)
		if type(kernel) == "table" and area(width, height) * #kernel > MAX_FILTER_WORK then
			tooLarge("the filter")
		end
		return convolveSeparable(width, height, pixels, kernel)
	end
end
if convolve2D then
	exports.convolve2D = function(width, height, pixels, weights, size, divisor, bias)
		if type(size) == "number" and area(width, height) * size * size > MAX_FILTER_WORK then
			tooLarge("the filter")
		end
		return convolve2D(width, height, pixels, weights, size, divisor, bias)
	end
end
Native.exports = if next(exports) then table.freeze(exports) else nil

return Native
