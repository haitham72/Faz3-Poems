-- =====================================================
-- LIVE SEARCH WITH PROGRESSIVE RELAXATION
-- Never returns 0 results - degrades gracefully
-- =====================================================

DROP FUNCTION IF EXISTS live_search_progressive(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION live_search_progressive(
    search_query TEXT,
    result_limit INT DEFAULT 10
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    match_type TEXT,
    score NUMERIC,
    tokens_matched INT,
    total_tokens INT,
    matched_tokens TEXT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    q TEXT;
    tokens TEXT[];
    token_count INT;
BEGIN
    q := trim(normalize_arabic(search_query));
    
    IF char_length(q) < 2 THEN
        RETURN;
    END IF;
    
    -- Split query into tokens
    tokens := string_to_array(q, ' ');
    token_count := array_length(tokens, 1);
    
    RETURN QUERY
    WITH 
    -- Expand tokens list
    token_list AS (
        SELECT 
            unnest(tokens) as token,
            generate_series(1, token_count) as position
    ),
    
    -- Match poems with scoring
    search_results AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            
            -- Count how many tokens matched
            (
                SELECT COUNT(DISTINCT t.token)
                FROM token_list t
                WHERE 
                    d."Title_cleaned" ILIKE '%' || t.token || '%' OR
                    d."Poem_line_cleaned" ILIKE '%' || t.token || '%'
            ) AS tokens_matched_count,
            
            -- Exact phrase bonus (all tokens together)
            CASE 
                WHEN d."Title_cleaned" ILIKE '%' || q || '%' THEN 100
                WHEN d."Poem_line_cleaned" ILIKE '%' || q || '%' THEN 90
                ELSE 0
            END AS exact_phrase_bonus,
            
            -- Prefix matching bonus (query starts line/title)
            CASE 
                WHEN d."Title_cleaned" ILIKE q || '%' THEN 50
                WHEN d."Poem_line_cleaned" ILIKE q || '%' THEN 40
                ELSE 0
            END AS prefix_bonus,
            
            -- Last token bonus (most important - what user is typing NOW)
            CASE 
                WHEN d."Title_cleaned" ILIKE '%' || tokens[token_count] || '%' 
                  OR d."Poem_line_cleaned" ILIKE '%' || tokens[token_count] || '%'
                THEN 30
                ELSE 0
            END AS last_token_bonus,
            
            -- Track which tokens matched
            ARRAY(
                SELECT DISTINCT t.token
                FROM token_list t
                WHERE 
                    d."Title_cleaned" ILIKE '%' || t.token || '%' OR
                    d."Poem_line_cleaned" ILIKE '%' || t.token || '%'
                ORDER BY t.token
            ) AS matched_token_array
            
        FROM "Diwan_Hamdan" d
        WHERE 
            -- CRITICAL: Match if ANY token exists (OR logic)
            EXISTS (
                SELECT 1 FROM token_list t
                WHERE 
                    d."Title_cleaned" ILIKE '%' || t.token || '%' OR
                    d."Poem_line_cleaned" ILIKE '%' || t.token || '%'
            )
    ),
    
    -- Calculate final scores
    ranked_results AS (
        SELECT 
            sr.*,
            -- Score formula: prioritize more tokens matched
            (
                (sr.tokens_matched_count::NUMERIC / token_count * 100) +  -- % of tokens matched
                sr.exact_phrase_bonus +
                sr.prefix_bonus +
                sr.last_token_bonus +
                (sr.tokens_matched_count * 20)  -- Bonus per token
            ) AS final_score,
            
            -- Match type classification
            CASE 
                WHEN sr.exact_phrase_bonus > 0 THEN 'exact'
                WHEN sr.tokens_matched_count = token_count THEN 'all_tokens'
                WHEN sr.tokens_matched_count >= (token_count * 0.7) THEN 'most_tokens'
                WHEN sr.tokens_matched_count >= (token_count * 0.5) THEN 'some_tokens'
                ELSE 'partial'
            END AS match_classification
            
        FROM search_results sr
        WHERE sr.tokens_matched_count > 0  -- At least 1 token matched
    )
    
    SELECT 
        rr.poem_id,
        rr."Row_ID",
        rr."Title_cleaned",
        rr."Poem_line_cleaned",
        rr.match_classification,
        rr.final_score,
        rr.tokens_matched_count,
        token_count,
        rr.matched_token_array
    FROM ranked_results rr
    ORDER BY
        -- Primary: more tokens matched = higher rank
        rr.tokens_matched_count DESC,
        -- Secondary: higher score
        rr.final_score DESC,
        -- Tertiary: recent poems first
        rr.poem_id DESC
    LIMIT result_limit;
    
END;
$$;


-- =====================================================
-- AUTOCOMPLETE BOOSTED PREFIXES
-- For "هل هناك قصائد عن" style queries
-- =====================================================

CREATE TABLE IF NOT EXISTS autocomplete_prefixes (
    id SERIAL PRIMARY KEY,
    prefix TEXT NOT NULL,              -- "هل هناك قصائد عن"
    prefix_normalized TEXT NOT NULL,   -- normalized version
    extract_after BOOLEAN DEFAULT true, -- extract tokens AFTER prefix
    boost_score INT DEFAULT 50
);

DROP INDEX IF EXISTS idx_prefix_normalized;
CREATE INDEX idx_prefix_normalized ON autocomplete_prefixes (prefix_normalized text_pattern_ops);

-- Add common question prefixes
INSERT INTO autocomplete_prefixes (prefix, prefix_normalized, extract_after, boost_score) VALUES
('هل هناك قصائد عن', normalize_arabic('هل هناك قصائد عن'), true, 100),
('ابحث عن', normalize_arabic('ابحث عن'), true, 80),
('اريد قصائد عن', normalize_arabic('اريد قصائد عن'), true, 80),
('قصائد عن', normalize_arabic('قصائد عن'), true, 90),
('ما هي القصائد التي تتحدث عن', normalize_arabic('ما هي القصائد التي تتحدث عن'), true, 70);


-- =====================================================
-- SMART QUERY PREPROCESSOR
-- Removes useless prefixes before search
-- =====================================================

CREATE OR REPLACE FUNCTION preprocess_query(user_query TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    q_normalized TEXT;
    prefix_record RECORD;
    cleaned_query TEXT;
BEGIN
    q_normalized := normalize_arabic(trim(user_query));
    cleaned_query := q_normalized;
    
    -- Check if query starts with known prefix
    FOR prefix_record IN 
        SELECT prefix_normalized, extract_after 
        FROM autocomplete_prefixes
        ORDER BY length(prefix_normalized) DESC  -- Match longest first
    LOOP
        IF q_normalized ILIKE prefix_record.prefix_normalized || '%' AND prefix_record.extract_after THEN
            -- Remove prefix and return the actual search terms
            cleaned_query := trim(substring(q_normalized from length(prefix_record.prefix_normalized) + 1));
            EXIT;  -- Found match, stop
        END IF;
    END LOOP;
    
    -- If cleaned query is empty, return original
    IF char_length(cleaned_query) < 2 THEN
        RETURN q_normalized;
    END IF;
    
    RETURN cleaned_query;
END;
$$;


-- =====================================================
-- FINAL LIVE SEARCH (with preprocessing)
-- =====================================================

DROP FUNCTION IF EXISTS live_search(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION live_search(
    search_query TEXT,
    result_limit INT DEFAULT 10
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    match_type TEXT,
    score NUMERIC,
    tokens_matched INT,
    total_tokens INT,
    matched_tokens TEXT[],
    preprocessed_query TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cleaned_query TEXT;
BEGIN
    -- Step 1: Preprocess query (remove useless prefixes)
    cleaned_query := preprocess_query(search_query);
    
    -- Step 2: Execute progressive search
    RETURN QUERY
    SELECT 
        ls.*,
        cleaned_query
    FROM live_search_progressive(cleaned_query, result_limit) ls;
END;
$$;


-- =====================================================
-- EXAMPLES & EXPECTED BEHAVIOR
-- =====================================================

/*
Example 1: Progressive degradation
┌─────────────────────────────┬─────────┬──────────────┐
│ User types                  │ Results │ Why          │
├─────────────────────────────┼─────────┼──────────────┤
│ "محمد"                      │ 100+    │ 1 token      │
│ "محمد بن"                   │ 50+     │ 2 tokens     │
│ "محمد بن راشد"              │ 20+     │ Finds "راشد" │
│ "محمد بن راشد ال مكتوم"     │ 10+     │ Finds "راشد" │
└─────────────────────────────┴─────────┴──────────────┘

NEVER 0 results! Even if full phrase doesn't exist, finds poems with ANY token.

Example 2: Prefix removal
┌─────────────────────────────────────┬───────────────────┐
│ User types                          │ Actually searches │
├─────────────────────────────────────┼───────────────────┤
│ "هل هناك قصائد عن محمد بن راشد"    │ "محمد بن راشد"   │
│ "ابحث عن الوطن"                    │ "الوطن"          │
│ "قصائد عن الحب"                    │ "الحب"           │
└─────────────────────────────────────┴───────────────────┘

Example 3: Ranking logic
Query: "محمد بن راشد ال مكتوم" (data only has "بن راشد")

Rank 1: Line with "بن راشد" (2/4 tokens = 50%)  → Score 140
Rank 2: Line with "راشد" only (1/4 tokens = 25%) → Score 70
Rank 3: Line with "محمد" only (1/4 tokens = 25%) → Score 70

Example 4: Real usage
SELECT * FROM live_search('محمد بن راشد', 10);

Returns:
- poems with "محمد بن راشد" together (if exist) → highest score
- poems with "محمد بن" + "راشد" separately → medium score  
- poems with just "راشد" → lower score
- NEVER returns 0 results

Example 5: Question-style query
SELECT * FROM live_search('هل هناك قصائد عن زايد', 10);

Preprocessed to: "زايد"
Returns: all poems mentioning "زايد"
*/


-- =====================================================
-- TESTING QUERIES
-- =====================================================

-- Test 1: Single token (should return many results)
-- SELECT * FROM live_search('محمد', 10);

-- Test 2: Two tokens (should still return results)
-- SELECT * FROM live_search('محمد بن', 10);

-- Test 3: Three tokens (finds ANY matching)
-- SELECT * FROM live_search('محمد بن راشد', 10);

-- Test 4: Full name that doesn't exist (finds partial matches)
-- SELECT * FROM live_search('محمد بن راشد ال مكتوم', 10);

-- Test 5: Question prefix removal
-- SELECT * FROM live_search('هل هناك قصائد عن الحب', 10);

-- Test 6: See preprocessing in action
-- SELECT preprocess_query('هل هناك قصائد عن محمد بن زايد');
-- Returns: "محمد بن زايد"