-- Contributed test (@RadicalDadical55, Misc Fixes 2026-09-30), run from the
-- Batmobile folder as its author wrote it (audit/tests/contrib/batmobile_enigma.lua).
local here = (debug.getinfo(1, 'S').source:match('^@(.*)/audit/tests/') or '.')
package.path = here .. '/Batmobile/?.lua;' .. package.path
dofile(here .. '/audit/tests/contrib/batmobile_enigma.lua')
