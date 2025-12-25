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
    match_location TEXT[],
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
    SELECT DISTINCT ON (e.poem_id)
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        'title'::text as match_location,
        
        (CASE
            -- LEVEL 1: EXACT FULL PHRASE
            WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 
                THEN 10.0
            WHEN position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0 
                THEN 9.8
            WHEN similarity(query_text, e."Title_cleaned") > 0.7
                THEN 9.5 * similarity(query_text, e."Title_cleaned")
            
            -- LEVEL 2: ALL MEANINGFUL WORDS PRESENT
            WHEN array_length(meaningful_words, 1) > 1 AND
                 (SELECT bool_and(
                     position(lower(w) IN lower(e."Title_cleaned")) > 0 
                     OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                 ) FROM unnest(meaningful_words) w)
                THEN 9.2 + (array_length(meaningful_words, 1) * 0.1)  -- Changed from 6.0
            
            -- LEVEL 3: ANY MEANINGFUL WORD PRESENT (PARTIAL)
            WHEN EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
            )
                THEN 9.0 + (  -- Changed from 4.0 to 9.0 (above poem exact match)
                    SELECT COUNT(*)::numeric * 0.05
                    FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
            
            -- FUZZY FALLBACK
            WHEN EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE similarity(w, e."Title_cleaned") > 0.5
            )
                THEN 8.5 + 0.5 * (  -- Changed from 3.0
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
        ORDER BY e.poem_id, 
                 (CASE WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 THEN 10.0 ELSE 0 END) DESC
    ),
    
    poem_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            'poem_line'::text as match_location,
            
            (CASE
                WHEN position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0 
                    THEN 9.0
                WHEN position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0 
                    THEN 8.8
                WHEN similarity(query_text, e."Poem_line_cleaned") > 0.6
                    THEN 8.5 * similarity(query_text, e."Poem_line_cleaned")
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 7.0 + (array_length(meaningful_words, 1) * 0.2)
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
            ARRAY[tm.match_location] as match_location,
            tm.match_type, tm.matched_fragments
        FROM title_matches tm
        WHERE tm.title_score > 0
        
        UNION ALL
        
        SELECT 
            pm.poem_id, pm.row_id, pm.title_raw, pm.poem_line_raw, 
            pm.poem_score as final_score, 
            ARRAY[pm.match_location] as match_location,
            pm.match_type, pm.matched_fragments
        FROM poem_matches pm
        WHERE pm.poem_score > 0
    ),
    
    best_per_poem AS (
        SELECT 
            am.poem_id,
            am.row_id,
            am.title_raw,
            am.poem_line_raw,
            MAX(am.final_score) as final_score,
            array_agg(DISTINCT unnest_val) as match_locations,
            (array_agg(am.match_type ORDER BY am.final_score DESC))[1] as match_type,
            (SELECT am2.matched_fragments FROM all_matches am2 WHERE am2.poem_id = am.poem_id ORDER BY am2.final_score DESC LIMIT 1) as matched_fragments
        FROM all_matches am
        CROSS JOIN LATERAL unnest(am.match_location) as unnest_val
        WHERE am.final_score >= min_score
        GROUP BY am.poem_id, am.row_id, am.title_raw, am.poem_line_raw
    )
    
    SELECT 
        bpp.poem_id,
        bpp.row_id,
        bpp.title_raw,
        bpp.poem_line_raw,
        round(bpp.final_score, 2) as score,
        bpp.match_locations,
        bpp.match_type,
        bpp.matched_fragments
    FROM best_per_poem bpp
    ORDER BY 
    bpp.final_score DESC, 
    CASE WHEN 'title' = ANY(bpp.match_locations) THEN 0 ELSE 1 END,  -- Title first
    bpp.poem_id ASC
    LIMIT match_limit;
    
END;
$$;