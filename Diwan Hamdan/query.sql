
-- SELECT * FROM live_search('را', 25);
--    → Finds: "راشد", "راجل", "رافد"
--    → Returns: Full word "راشد" at idx [2]

-- Typo query (TRIGRAM mode):
-- SELECT * FROM live_search('محمد بن', 25);
--    → Fuzzy matches: "راشد بن محمد"
--    → Returns: idx [2, 4, 5]

-- Multi-word (TRIGRAM mode):
SELECT * FROM live_search('  افضل قائد لهذه الأمه بن زايد', 25);
--    → Exact matches all three words
--    → Returns: idx [4, 5, 6]
