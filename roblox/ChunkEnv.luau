-- Gives a loadstring chunk its own globals table so a run's globals (print, user, ...) aren't
-- shared by every chunk. getfenv/setfenv turn off import/fastcall optimizations in their script
-- and any env getfenv returns, so this is a separate module indexing its own env, not LuauBot's.
return function(chunk, globals)
	setfenv(chunk, setmetatable(globals or {}, { __index = getfenv(1) }))
	return chunk
end
