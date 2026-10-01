-- Contributed test (@RadicalDadical55, Misc Fixes 2026-09-30), run from the
-- HelltideRevamped folder as its author wrote it (audit/tests/contrib/helltide_tear_priority.lua).
local here = (debug.getinfo(1, 'S').source:match('^@(.*)/audit/tests/') or '.')
package.path = here .. '/HelltideRevamped/?.lua;' .. package.path
dofile(here .. '/audit/tests/contrib/helltide_tear_priority.lua')
