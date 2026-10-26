--!lune
--!optimize 2
--!native
-- Run once as-is and once without --!native; native should be ~5-10x faster.
-- Submit via Discord: the web UI doesn't set allowCodegen.

local start = os.clock()

local sum = 0
for i = 1, 50000000 do
	sum += (i % 7) * 1.0001 - (i % 3)
end

local elapsed = os.clock() - start
print(("elapsed: %.3fs  result: %.2f"):format(elapsed, sum))
