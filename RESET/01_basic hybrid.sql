-- ============================================
-- HYBRID SEARCH V1: TITLE + POEM LINE ONLY
-- Scores normalized 0-10
-- ============================================

DROP FUNCTION IF EXISTS hybrid_search_v1_core(TEXT, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION hybrid_search_v1_core(
    query_text TEXT,
    match_limit INT DEFAULT 10,
    min_score NUMERIC DEFAULT 0.3
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_raw TEXT,
    poem_line_raw TEXT,
    score NUMERIC,
    match_location TEXT,
    match_type TEXT,
    matched_fragments TEXT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    query_normalized TEXT;
    query_words TEXT[];
    meaningful_words TEXT[];
    word TEXT;
BEGIN
    query_normalized := normalize_arabic(query_text);
    query_words := string_to_array(trim(query_text), ' ');
    
    meaningful_words := ARRAY[]::TEXT[];
    FOREACH word IN ARRAY query_words
    LOOP
        IF NOT is_common_particle(word) THEN
            meaningful_words := array_append(meaningful_words, word);
        END IF;
    END LOOP;
    
    RETURN QUERY
    WITH 
    title_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            'title'::text as match_location,
            
            (CASE
                -- LEVEL 1: EXACT FULL PHRASE (8.0 for title)
                WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 
                    THEN 8.0
                WHEN position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0 
                    THEN 7.8
                WHEN similarity(query_text, e."Title_cleaned") > 0.7
                    THEN 7.5 * similarity(query_text, e."Title_cleaned")
                    
                -- LEVEL 2: ALL MEANINGFUL WORDS PRESENT (6.0-6.5)
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Title_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 6.0 + (array_length(meaningful_words, 1) * 0.2)
                    
                -- LEVEL 3: ANY MEANINGFUL WORD PRESENT (4.0-5.0)
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
                    THEN 4.0 + (
                        SELECT COUNT(*)::numeric * 0.4
                        FROM unnest(meaningful_words) w
                        WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                           OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                    )
                    
                -- FUZZY FALLBACK (3.0-4.0)
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE similarity(w, e."Title_cleaned") > 0.5
                )
                    THEN 3.0 + (
                        SELECT MAX(similarity(w, e."Title_cleaned"))
                        FROM unnest(meaningful_words) w
                    )
                    
                ELSE 0
            END)::numeric as title_score,
            
            (CASE
                WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 
                    THEN 'exact_phrase'
                WHEN position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0 
                    THEN 'normalized_phrase'
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(position(lower(w) IN lower(e."Title_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 'all_words'
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
                    THEN 'partial_words'
                ELSE 'fuzzy'
            END)::text as match_type,
            
            ARRAY(
                SELECT w FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                   OR similarity(w, e."Title_cleaned") > 0.5
            ) as matched_fragments
            
        FROM "Exact_search" e
        WHERE 
            position(lower(query_text) IN lower(e."Title_cleaned")) > 0
            OR position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0
            OR similarity(query_text, e."Title_cleaned") > 0.5
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                   OR similarity(w, e."Title_cleaned") > 0.4
            )
    ),
    
    poem_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            'poem_line'::text as match_location,
            
            (CASE
                -- LEVEL 1: EXACT FULL PHRASE (10.0 - HIGHEST for poem)
                WHEN position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0 
                    THEN 10.0
                WHEN position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0 
                    THEN 9.8
                WHEN similarity(query_text, e."Poem_line_cleaned") > 0.6
                    THEN 9.5 * similarity(query_text, e."Poem_line_cleaned")
                    
                -- LEVEL 2: ALL MEANINGFUL WORDS PRESENT (7.0-7.5)
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 7.0 + (array_length(meaningful_words, 1) * 0.2)
                    
                -- LEVEL 3: ANY MEANINGFUL WORD PRESENT (5.0-6.5)
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                )
                    THEN 5.0 + (
                        SELECT COUNT(*)::numeric * 0.5
                        FROM unnest(meaningful_words) w
                        WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                           OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                    )
                    
                -- FUZZY FALLBACK (3.0-5.0)
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE similarity(w, e."Poem_line_cleaned") > 0.4
                )
                    THEN 3.0 + 2.0 * (
                        SELECT MAX(similarity(w, e."Poem_line_cleaned"))
                        FROM unnest(meaningful_words) w
                    )
                    
                ELSE 0
            END)::numeric as poem_score,
            
            (CASE
                WHEN position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0 
                    THEN 'exact_phrase'
                WHEN position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0 
                    THEN 'normalized_phrase'
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 'all_words'
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                )
                    THEN 'partial_words'
                ELSE 'fuzzy'
            END)::text as match_type,
            
            ARRAY(
                SELECT w FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                   OR similarity(w, e."Poem_line_cleaned") > 0.4
            ) as matched_fragments
            
        FROM "Exact_search" e
        WHERE 
            position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0
            OR position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0
            OR similarity(query_text, e."Poem_line_cleaned") > 0.4
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                   OR similarity(w, e."Poem_line_cleaned") > 0.3
            )
    ),
    
    all_matches AS (
        SELECT 
            tm.poem_id, tm.row_id, tm.title_raw, tm.poem_line_raw, 
            tm.title_score as final_score, 
            tm.match_location, tm.match_type, tm.matched_fragments
        FROM title_matches tm
        WHERE tm.title_score > 0
        
        UNION ALL
        
        SELECT 
            pm.poem_id, pm.row_id, pm.title_raw, pm.poem_line_raw, 
            pm.poem_score as final_score, 
            pm.match_location, pm.match_type, pm.matched_fragments
        FROM poem_matches pm
        WHERE pm.poem_score > 0
    ),
    
    best_per_poem AS (
        SELECT DISTINCT ON (am.poem_id)
            am.poem_id,
            am.row_id,
            am.title_raw,
            am.poem_line_raw,
            am.final_score,
            am.match_location,
            am.match_type,
            am.matched_fragments
        FROM all_matches am
        WHERE am.final_score >= min_score
        ORDER BY am.poem_id, am.final_score DESC
    )
    
    SELECT 
        bpp.poem_id,
        bpp.row_id,
        bpp.title_raw,
        bpp.poem_line_raw,
        round(bpp.final_score, 2) as score,
        bpp.match_location,
        bpp.match_type,
        bpp.matched_fragments
    FROM best_per_poem bpp
    ORDER BY bpp.final_score DESC, bpp.poem_id ASC
    LIMIT match_limit;
    
END;
$$;