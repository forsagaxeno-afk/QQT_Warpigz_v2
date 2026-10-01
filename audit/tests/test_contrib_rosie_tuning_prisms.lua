-- Contributed test (@RadicalDadical55, Misc Fixes 2026-09-30), run from the
-- Rosie folder as its author wrote it (audit/tests/contrib/rosie_tuning_prisms.lua).
local here = (debug.getinfo(1, 'S').source:match('^@(.*)/audit/tests/') or '.')
package.path = here .. '/Rosie/?.lua;' .. package.path
dofile(here .. '/audit/tests/contrib/rosie_tuning_prisms.lua')
