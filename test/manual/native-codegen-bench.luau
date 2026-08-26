--!lune
--!optimize 2
--!native
-- Submit this once as-is (native), then again with the --!native line above
-- deleted (interpreted). Compare the printed elapsed time. Native codegen
-- should be roughly 5-10x faster on this kind of tight numeric loop; if the
-- two runs come back close, codegen isn't actually kicking in.
--
-- Note: allowCodegen is only true for direct Discord runs, not the web UI
-- (see src/discord/tasks.js vs src/web/index.js) - submit via Discord.

local start = os.clock()

local sum = 0
for i = 1, 50000000 do
	sum += (i % 7) * 1.0001 - (i % 3)
end

local elapsed = os.clock() - start
print(("elapsed: %.3fs  result: %.2f"):format(elapsed, sum))
