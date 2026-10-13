--!text: tools/test/fixtures/MAINT-113-ends-in-bracket.txt, tools/test/fixtures/MAINT-113-ends-in-level-bracket.txt
-- MAINT-113-long_string_boundary_test.lua
--
-- MAINTENANCE row 113 (row 87's defect, fixed in FertilizerDepot by #80): the runner's
-- luaLongString (tools/test/run-tests.mjs) picked the long bracket's level from the text alone,
-- so a --!text file whose LAST characters meet the closing bracket (a text ending in "]" at
-- level 0, or in "]=" at level 1) closed the string early and the whole bar failed to load. The
-- level is now chosen from the text with a closing "]" appended, which sees that join.
--
-- THE ENTRY POINT IS THE REAL RUNNER: the two fixtures are read and embedded by run-tests.mjs
-- exactly as every --!text file is, and this bar reads back what the runner handed it
-- (SOURCE_TEXT[path]). Both fixtures have NO trailing newline, which is the only shape that meets the
-- closer (every production --!text file ends in a newline, so nothing hits this today).
--
--   B1 a text ending in "]" with no "]]" in it (level 0) arrives whole
--   B2 a text containing "]]" and ending in "]=" (level 1) arrives whole
--
-- Before the fix neither row runs: the file fails to load ("unexpected symbol"), which is the
-- battery's kill (mutate_maint113_long_string.py), attributed to this file alone.

local A = "tools/test/fixtures/MAINT-113-ends-in-bracket.txt"
local B = "tools/test/fixtures/MAINT-113-ends-in-level-bracket.txt"

T.eq("B1 a --!text file ending in ']' with no trailing newline arrives whole",
    type(SOURCE_TEXT) == "table" and SOURCE_TEXT[A] or "(missing)", "a text that ends in a bracket]")
T.eq("B2 a --!text file containing ']]' and ending in ']=' arrives whole",
    type(SOURCE_TEXT) == "table" and SOURCE_TEXT[B] or "(missing)", "a text with a]] pair that ends in ]=")
