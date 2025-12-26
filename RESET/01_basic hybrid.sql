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
    match JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    q_norm TEXT;
    query_words TEXT[];
    meaningful_words TEXT[];
    current_word TEXT;
BEGIN
    -- Aggressive Trimming and Normalization
    q_norm := TRIM(normalize_arabic(query_text));
    query_words := string_to_array(trim(query_text), ' ');
    
    meaningful_words := ARRAY[]::TEXT[];
    FOREACH current_word IN ARRAY query_words
    LOOP
        -- Feature: Filter Name Connectors to prevent "Ibn" from dominating results
        IF NOT is_common_particle(current_word) 
           AND normalize_arabic(current_word) NOT IN ('بن', 'ابن', 'بو', 'ابو', 'ال') 
        THEN
            meaningful_words := array_append(meaningful_words, current_word);
        END IF;
    END LOOP;
    
    IF array_length(meaningful_words, 1) IS NULL THEN
        meaningful_words := query_words;
    END IF;
    
    RETURN QUERY
    WITH 
    title_matches AS (
        SELECT DISTINCT ON (e.poem_id)
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            e."Title_cleaned" as title_cleaned,
            'title'::text as loc,
            
            (CASE
                -- TIER 1: Exact Whole Word / Full Substring -> 110 (Title Boost)
                WHEN (' ' || normalize_arabic(e."Title_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 110.0
                WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 110.0

                -- TIER 2: Consecutive Words (Compound Logic)
                WHEN array_length(meaningful_words, 1) > 1 AND
                     EXISTS (
                         SELECT 1
                         FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(word, idx)
                         WHERE (
                             SELECT bool_and(
                                 EXISTS (
                                     SELECT 1 
                                     FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2)
                                     WHERE normalize_arabic(u2.word2) = normalize_arabic(mw)
                                       AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2
                                 )
                             )
                             FROM unnest(meaningful_words) mw
                         )
                     )
                    THEN 90.0 + (array_length(meaningful_words, 1) * 2)

                -- TIER 3: All Words Scattered
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Title_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 60.0 + (array_length(meaningful_words, 1) * 2)

                -- TIER 4: Partial/Fuzzy Words (Boosted for Titles)
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
                    THEN 85.0 + (
                        SELECT COUNT(*)::numeric * 10
                        FROM unnest(meaningful_words) w
                        WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                           OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                    )
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE similarity(w, e."Title_cleaned") > 0.5
                )
                    THEN 8.5 + 0.5 * (
                        SELECT MAX(similarity(w, e."Title_cleaned"))
                        FROM unnest(meaningful_words) w
                    )
                ELSE 0
            END)::numeric as field_score,
            
            (CASE
                WHEN (' ' || normalize_arabic(e."Title_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 'exact_phrase'
                WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 'partial_match'
                WHEN array_length(meaningful_words, 1) > 1 AND EXISTS (SELECT 1 FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(word, idx) WHERE (SELECT bool_and(EXISTS (SELECT 1 FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2) WHERE normalize_arabic(u2.word2) = normalize_arabic(mw) AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2)) FROM unnest(meaningful_words) mw)) THEN 'consecutive_words'
                WHEN array_length(meaningful_words, 1) > 1 AND (SELECT bool_and(position(lower(w) IN lower(e."Title_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0) FROM unnest(meaningful_words) w) THEN 'all_words_scattered'
                WHEN EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0) THEN 'partial_words'
                ELSE 'no_match'
            END)::text as match_type,
            
            -- Include both query_text AND meaningful_words for highlighting
            CASE 
                WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 
                     OR position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0
                THEN array_prepend(query_text, ARRAY(
                    SELECT w FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                       OR similarity(w, e."Title_cleaned") > 0.5
                ))
                ELSE ARRAY(
                    SELECT w FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                       OR similarity(w, e."Title_cleaned") > 0.5
                )
            END as matched_fragments
            
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
            e.poem_id, e."Row_ID" as row_id, e."Title_raw" as title_raw, e."Poem_line_raw" as poem_line_raw, e."Poem_line_cleaned" as poem_line_cleaned, 'poem_line'::text as loc,
            
            (CASE
                -- TIER 1: Exact Whole Word -> 100
                WHEN (' ' || normalize_arabic(e."Poem_line_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 100.0
                
                -- TIER 2: Substring (The "Baghyabi" Fix) -> 10.0
                WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 10.0
                
                -- TIER 3: Consecutive Words
                WHEN array_length(meaningful_words, 1) > 1 AND
                     EXISTS (
                         SELECT 1
                         FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(word, idx)
                         WHERE (
                             SELECT bool_and(
                                 EXISTS (
                                     SELECT 1 
                                     FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2)
                                     WHERE normalize_arabic(u2.word2) = normalize_arabic(mw)
                                       AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2
                                 )
                             )
                             FROM unnest(meaningful_words) mw
                         )
                     )
                    THEN 85.0 + (array_length(meaningful_words, 1) * 2)

                -- TIER 4: All Words Scattered
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 55.0 + (array_length(meaningful_words, 1) * 2)

                -- TIER 5: Partial Words
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                )
                    THEN 35.0 + (
                        SELECT COUNT(*)::numeric * 8
                        FROM unnest(meaningful_words) w
                        WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                           OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                    )
                ELSE 0
            END)::numeric as field_score,
            
            (CASE
                WHEN (' ' || normalize_arabic(e."Poem_line_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 'exact_phrase'
                WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 'partial_match'
                WHEN array_length(meaningful_words, 1) > 1 AND EXISTS (SELECT 1 FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(word, idx) WHERE (SELECT bool_and(EXISTS (SELECT 1 FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2) WHERE normalize_arabic(u2.word2) = normalize_arabic(mw) AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2)) FROM unnest(meaningful_words) mw)) THEN 'consecutive_words'
                WHEN array_length(meaningful_words, 1) > 1 AND (SELECT bool_and(position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0) FROM unnest(meaningful_words) w) THEN 'all_words_scattered'
                WHEN EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0) THEN 'partial_words'
                ELSE 'no_match'
            END)::text as match_type,
            
            -- Include both query_text AND meaningful_words for highlighting
            CASE 
                WHEN position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0 
                     OR position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0
                THEN array_prepend(query_text, ARRAY(
                    SELECT w FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                       OR similarity(w, e."Poem_line_cleaned") > 0.6
                ))
                ELSE ARRAY(
                    SELECT w FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                       OR similarity(w, e."Poem_line_cleaned") > 0.6
                )
            END as matched_fragments
            
        FROM "Exact_search" e
        WHERE 
            position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0
            OR position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0
            OR similarity(query_text, e."Poem_line_cleaned") > 0.6
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                   OR similarity(w, e."Poem_line_cleaned") > 0.6
            )
    ),
    
    all_matches AS (
        SELECT tm.poem_id, tm.row_id, tm.title_raw, tm.poem_line_raw, tm.field_score as score, ARRAY[tm.loc] as loc, tm.match_type, tm.matches_json FROM title_matches tm WHERE tm.field_score > 0
        UNION ALL
        SELECT pm.poem_id, pm.row_id, pm.title_raw, pm.poem_line_raw, pm.field_score, ARRAY[pm.loc], pm.match_type, pm.matches_json FROM poem_matches pm WHERE pm.field_score > 0
    ),
    
    best_per_poem AS (
        SELECT 
            am.poem_id,
            (array_agg(am.row_id ORDER BY CASE WHEN 'poem_line' = ANY(am.loc) THEN 1 ELSE 0 END DESC, am.score DESC))[1] as row_id,
            (array_agg(am.title_raw ORDER BY am.score DESC))[1] as title_raw,
            (array_agg(am.poem_line_raw ORDER BY CASE WHEN 'poem_line' = ANY(am.loc) THEN 1 ELSE 0 END DESC, am.score DESC))[1] as poem_line_raw,
            MAX(am.score) as final_score,
            array_agg(DISTINCT unnest_val) as match_locations,
            (array_agg(am.match_type ORDER BY am.score DESC))[1] as match_type,
            jsonb_build_object(
                'title', COALESCE(
                    (SELECT jsonb_build_object(
                        'words', to_jsonb(am3.matched_fragments),
                        'text', am3.title_raw
                    ) FROM all_matches am3 WHERE am3.poem_id = am.poem_id AND 'title' = ANY(am3.match_location) LIMIT 1),
                    '{"words":[], "text":""}'::jsonb
                ),
                'poem_line', COALESCE(
                    (SELECT jsonb_build_object(
                        'words', to_jsonb(am4.matched_fragments),
                        'text', am4.poem_line_raw
                    ) FROM all_matches am4 WHERE am4.poem_id = am.poem_id AND 'poem_line' = ANY(am4.match_location) LIMIT 1),
                    '{"words":[], "text":""}'::jsonb
                )
            ) as highlights
        FROM all_matches am
        CROSS JOIN LATERAL unnest(am.loc) as unnest_val
        WHERE am.score >= min_score
        GROUP BY am.poem_id
    )
    
    SELECT bpp.poem_id, bpp.row_id, bpp.title_raw, bpp.poem_line_raw, round(bpp.final_score, 1) as score, bpp.match_locations, bpp.match_type, bpp.match
    FROM best_per_poem bpp
    ORDER BY bpp.final_score DESC, bpp.poem_id ASC
    LIMIT match_limit;
END;
$$;