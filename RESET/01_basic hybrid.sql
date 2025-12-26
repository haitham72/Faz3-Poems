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
    query_normalized TEXT;
    query_words TEXT[];
    meaningful_words TEXT[];
    current_word TEXT;
BEGIN
    query_normalized := normalize_arabic(query_text);
    query_words := string_to_array(trim(query_text), ' ');
    
    meaningful_words := ARRAY[]::TEXT[];
    FOREACH current_word IN ARRAY query_words
    LOOP
        IF NOT is_common_particle(current_word) THEN
            meaningful_words := array_append(meaningful_words, current_word);
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
            e."Title_cleaned" as title_cleaned,
            'title'::text as match_location,
            
            (CASE
                WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 
                    THEN 100.0
                WHEN position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0 
                    THEN 98.0
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
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Title_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 60.0 + (array_length(meaningful_words, 1) * 2)
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
                    THEN 40.0 + (
                        SELECT COUNT(*)::numeric * 8
                        FROM unnest(meaningful_words) w
                        WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                           OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                    )
                ELSE 0
            END)::numeric as title_score,
            
            (CASE
                WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 
                     OR position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0
                    THEN 'exact_phrase'
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
                    THEN 'consecutive_words'
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(position(lower(w) IN lower(e."Title_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 'all_words_scattered'
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
                    THEN 'partial_words'
                ELSE 'no_match'
            END)::text as match_type,
            
            -- Simple array of matched text for title
            COALESCE(
                (
                    SELECT jsonb_agg(DISTINCT match_text)
                    FROM (
                        SELECT query_text as match_text
                        WHERE position(normalize_arabic(query_text) IN normalize_arabic(e."Title_cleaned")) > 0
                        
                        UNION
                        
                        SELECT w as match_text
                        FROM unnest(meaningful_words) w
                        WHERE EXISTS (
                            SELECT 1 FROM unnest(string_to_array(e."Title_cleaned", ' ')) title_check
                            WHERE normalize_arabic(title_check) LIKE '%' || normalize_arabic(w) || '%'
                        )
                    ) t
                ),
                '[]'::jsonb
            ) as title_matches_json
            
        FROM "Exact_search" e
        WHERE 
            position(lower(query_text) IN lower(e."Title_cleaned")) > 0
            OR position(query_normalized IN normalize_arabic(e."Title_cleaned")) > 0
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
            )
        ORDER BY e.poem_id, 
                 (CASE WHEN position(lower(query_text) IN lower(e."Title_cleaned")) > 0 THEN 100.0 ELSE 0 END) DESC
    ),
    
    poem_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            e."Poem_line_cleaned" as poem_line_cleaned,
            'poem_line'::text as match_location,
            
            (CASE
                WHEN position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0 
                    THEN 95.0
                WHEN position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0 
                    THEN 93.0
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
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 55.0 + (array_length(meaningful_words, 1) * 2)
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
            END)::numeric as poem_score,
            
            (CASE
                WHEN position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0 
                     OR position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0
                    THEN 'exact_phrase'
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
                    THEN 'consecutive_words'
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 'all_words_scattered'
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                )
                    THEN 'partial_words'
                ELSE 'no_match'
            END)::text as match_type,
            
            -- Poem line matches with matched_words array format
            jsonb_build_object(
                'matched_words', COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'text', match_info.matched_text,
                                'positions', CASE 
                                    WHEN array_length(match_info.word_positions, 1) = 1 
                                    THEN (match_info.word_positions[1])::text
                                    WHEN array_length(match_info.word_positions, 1) > 1 
                                    THEN (match_info.word_positions[1])::text || '-' || (match_info.word_positions[array_length(match_info.word_positions, 1)])::text
                                    ELSE ''
                                END,
                                'score', match_info.match_score
                            ) ORDER BY match_info.match_score DESC
                        )
                        FROM (
                            SELECT 
                                query_text as matched_text,
                                array_agg(DISTINCT pos ORDER BY pos) as word_positions,
                                100 as match_score
                            FROM (
                                SELECT (idx - 1)::int as pos
                                FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(poem_word, idx),
                                     unnest(string_to_array(normalize_arabic(query_text), ' ')) AS query_word
                                WHERE normalize_arabic(poem_word) = query_word
                            ) positions
                            WHERE position(normalize_arabic(query_text) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                            GROUP BY query_text
                            
                            UNION ALL
                            
                            SELECT 
                                w as matched_text,
                                array_agg(DISTINCT pos ORDER BY pos) as word_positions,
                                50 as match_score
                            FROM unnest(meaningful_words) w,
                                 LATERAL (
                                     SELECT (idx - 1)::int as pos
                                     FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(poem_word, idx)
                                     WHERE normalize_arabic(poem_word) LIKE '%' || normalize_arabic(w) || '%'
                                 ) positions
                            WHERE EXISTS (
                                SELECT 1 FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) poem_check
                                WHERE normalize_arabic(poem_check) LIKE '%' || normalize_arabic(w) || '%'
                            )
                            AND NOT (position(normalize_arabic(query_text) IN normalize_arabic(e."Poem_line_cleaned")) > 0)
                            GROUP BY w
                        ) match_info
                    ),
                    '[]'::jsonb
                )
            ) as poem_matches_json
            
        FROM "Exact_search" e
        WHERE 
            position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0
            OR position(query_normalized IN normalize_arabic(e."Poem_line_cleaned")) > 0
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
            )
    ),
    
    all_matches AS (
        SELECT 
            tm.poem_id, tm.row_id, tm.title_raw, tm.poem_line_raw,
            tm.title_cleaned, NULL::text as poem_line_cleaned,
            tm.title_score as final_score, 
            ARRAY[tm.match_location] as match_location,
            tm.match_type, tm.title_matches_json as matches_json
        FROM title_matches tm
        WHERE tm.title_score > 0
        
        UNION ALL
        
        SELECT 
            pm.poem_id, pm.row_id, pm.title_raw, pm.poem_line_raw,
            NULL::text as title_cleaned, pm.poem_line_cleaned,
            pm.poem_score as final_score, 
            ARRAY[pm.match_location] as match_location,
            pm.match_type, pm.poem_matches_json as matches_json
        FROM poem_matches pm
        WHERE pm.poem_score > 0
    ),
    
    best_per_poem AS (
        SELECT 
            am.poem_id,
            MIN(am.row_id) as row_id,
            (array_agg(am.title_raw ORDER BY am.final_score DESC))[1] as title_raw,
            (array_agg(am.poem_line_raw ORDER BY am.final_score DESC))[1] as poem_line_raw,
            MAX(am.final_score) as final_score,
            array_agg(DISTINCT unnest_val) as match_locations,
            (array_agg(am.match_type ORDER BY am.final_score DESC))[1] as match_type,
            
            jsonb_build_object(
                'title', COALESCE(
                    (SELECT am3.matches_json
                     FROM all_matches am3 
                     WHERE am3.poem_id = am.poem_id AND 'title' = ANY(am3.match_location) 
                     ORDER BY am3.final_score DESC
                     LIMIT 1),
                    '[]'::jsonb
                ),
                'poem_line', COALESCE(
                    (SELECT am4.matches_json
                     FROM all_matches am4 
                     WHERE am4.poem_id = am.poem_id AND 'poem_line' = ANY(am4.match_location) 
                     ORDER BY am4.final_score DESC
                     LIMIT 1),
                    '{}'::jsonb
                )
            ) as match
        FROM all_matches am
        CROSS JOIN LATERAL unnest(am.match_location) as unnest_val
        WHERE am.final_score >= min_score
        GROUP BY am.poem_id
    )
    
    SELECT 
        bpp.poem_id,
        bpp.row_id,
        bpp.title_raw,
        bpp.poem_line_raw,
        round(bpp.final_score, 1) as score,
        bpp.match_locations,
        bpp.match_type,
        bpp.match
    FROM best_per_poem bpp
    ORDER BY 
        bpp.final_score DESC,
        bpp.poem_id ASC
    LIMIT match_limit;
    
END;
$$;