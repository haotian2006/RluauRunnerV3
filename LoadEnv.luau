--Put this under LuauBot

return function(thread, env)
	-- you can add custom environment variables here
	-- these will be global variables thats loaded into the environment (not via getfenv/setfenv)
	env.GLOBAL = {}
end
