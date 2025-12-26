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
    -- [FIX: Aggressive Trimming]
    q_norm := TRIM(normalize_arabic(query_text));
    query_words := string_to_array(trim(query_text), ' ');
    
    meaningful_words := ARRAY[]::TEXT[];
    FOREACH current_word IN ARRAY query_words
    LOOP
        -- [FIX: Exclude name connectors from "meaningful" to prevent low-quality matches]
        IF NOT is_common_particle(current_word) 
           AND normalize_arabic(current_word) NOT IN ('بن', 'ابن', 'بو', 'ابو', 'ال') 
        THEN
            meaningful_words := array_append(meaningful_words, current_word);
        END IF;
    END LOOP;
    
    -- Safety: If query was only "bin", use it anyway
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
            
            -- [SCORING: ORIGINAL COMPLEX LOGIC RESTORED]
            (CASE
                -- 1. Exact Whole Word -> 110 (Title Boost)
                WHEN (' ' || normalize_arabic(e."Title_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') 
                    THEN 110.0
                
                -- 2. Substring -> 110 (Title Boost)
                WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0 
                    THEN 110.0

                -- 3. Consecutive Words (Original Strict Logic Restored)
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
                                       -- STRICT NEIGHBOR CHECK
                                       AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2
                                 )
                             )
                             FROM unnest(meaningful_words) mw
                         )
                     )
                    THEN 90.0 + (array_length(meaningful_words, 1) * 2)

                -- 4. All Words Scattered (Original Logic Restored)
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Title_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 60.0 + (array_length(meaningful_words, 1) * 2)

                -- 5. Partial/Fuzzy Words (Boosted for Titles)
                WHEN EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
                    THEN 
                        -- Title Boost: Start at 85
                        85.0 + (
                            SELECT COUNT(*)::numeric * 10
                            FROM unnest(meaningful_words) w
                            WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                               OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                        )
                ELSE 0
            END)::numeric as field_score,
            
            -- [MATCH TYPE: ORIGINAL LOGIC RESTORED]
            (CASE
                WHEN (' ' || normalize_arabic(e."Title_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 'exact_phrase'
                WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 'partial_match'
                -- Strict Consecutive Check
                WHEN array_length(meaningful_words, 1) > 1 AND EXISTS (SELECT 1 FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(word, idx) WHERE (SELECT bool_and(EXISTS (SELECT 1 FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2) WHERE normalize_arabic(u2.word2) = normalize_arabic(mw) AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2)) FROM unnest(meaningful_words) mw)) THEN 'consecutive_words'
                WHEN array_length(meaningful_words, 1) > 1 AND (SELECT bool_and(position(lower(w) IN lower(e."Title_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0) FROM unnest(meaningful_words) w) THEN 'all_words_scattered'
                WHEN EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0) THEN 'partial_words'
                ELSE 'no_match'
            END)::text as match_type,
            
            -- [TITLE JSON: Fixed Context Scoring]
            COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'text', match_info.pw,
                    'positions', (match_info.pos[1])::text,
                    'score', match_info.scr
                ) ORDER BY match_info.scr DESC)
                FROM (
                    SELECT 
                        pw, array_agg(idx-1) as pos, 
                        -- Context Score: If title matches query, give 110 to all words
                        CASE WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 110 ELSE 50 END as scr
                    FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(pw, idx)
                    WHERE pw <> '' 
                    AND (position(normalize_arabic(pw) IN q_norm) > 0 OR position(q_norm IN normalize_arabic(pw)) > 0)
                    GROUP BY pw
                ) match_info
            ), '[]'::jsonb) as matches_json
            
        FROM "Exact_search" e
        WHERE 
            position(lower(query_text) IN lower(e."Title_cleaned")) > 0
            OR position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
            )
        ORDER BY e.poem_id, field_score DESC
    ),
    
    poem_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            e."Poem_line_cleaned" as poem_line_cleaned,
            'poem_line'::text as loc,
            
            -- [SCORING: ORIGINAL COMPLEX LOGIC RESTORED]
            (CASE
                -- 1. Exact Whole Word -> 100
                WHEN (' ' || normalize_arabic(e."Poem_line_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') 
                    THEN 100.0
                
                -- 2. Substring (Partial) -> 10.0 (Low Score Fix)
                WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 
                    THEN 10.0
                
                -- 3. Consecutive Words (Original Strict Logic Restored)
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
                                       -- STRICT NEIGHBOR CHECK
                                       AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2
                                 )
                             )
                             FROM unnest(meaningful_words) mw
                         )
                     )
                    THEN 85.0 + (array_length(meaningful_words, 1) * 2)

                -- 4. All Words Scattered (Original Logic Restored)
                WHEN array_length(meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(meaningful_words) w)
                    THEN 55.0 + (array_length(meaningful_words, 1) * 2)

                -- 5. Partial Words (Original Logic Restored)
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
            
            -- [MATCH TYPE: ORIGINAL LOGIC RESTORED]
            (CASE
                WHEN (' ' || normalize_arabic(e."Poem_line_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 'exact_phrase'
                WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 'partial_match'
                -- Strict Consecutive Check
                WHEN array_length(meaningful_words, 1) > 1 AND EXISTS (SELECT 1 FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(word, idx) WHERE (SELECT bool_and(EXISTS (SELECT 1 FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2) WHERE normalize_arabic(u2.word2) = normalize_arabic(mw) AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2)) FROM unnest(meaningful_words) mw)) THEN 'consecutive_words'
                WHEN array_length(meaningful_words, 1) > 1 AND (SELECT bool_and(position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0) FROM unnest(meaningful_words) w) THEN 'all_words_scattered'
                WHEN EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0) THEN 'partial_words'
                ELSE 'no_match'
            END)::text as match_type,
            
            -- [POEM JSON: Fixed Context Scoring]
            jsonb_build_object(
                'row_id', e."Row_ID",
                'matched_words', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', mi.pw,
                        'positions', CASE WHEN array_length(mi.pos, 1) > 1 THEN (mi.pos[1])::text || '-' || (mi.pos[array_length(mi.pos, 1)])::text ELSE (mi.pos[1])::text END,
                        'score', mi.scr
                    ) ORDER BY mi.scr DESC)
                    FROM (
                        SELECT 
                            pw, array_agg(idx-1) as pos,
                            -- Context Score: If line matches query, give 100 to all words
                            CASE 
                                WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 100
                                WHEN (' '||normalize_arabic(pw)||' ') LIKE ('% '||q_norm||' %') THEN 100
                                ELSE 50
                            END as scr
                        FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(pw, idx)
                        WHERE pw <> '' 
                        AND (
                            (position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 AND position(normalize_arabic(pw) IN q_norm) > 0)
                            OR normalize_arabic(pw) LIKE '%' || q_norm || '%'
                            OR EXISTS (SELECT 1 FROM unnest(meaningful_words) mw WHERE normalize_arabic(pw) LIKE '%'||normalize_arabic(mw)||'%')
                        )
                        AND (length(normalize_arabic(pw)) > 1) 
                        GROUP BY pw
                    ) mi
                ), '[]'::jsonb)
            ) as matches_json
            
        FROM "Exact_search" e
        WHERE 
            position(lower(query_text) IN lower(e."Poem_line_cleaned")) > 0
            OR position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) w
                WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0
                   OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
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
                'title', COALESCE((SELECT matches_json FROM all_matches a2 WHERE a2.poem_id = am.poem_id AND 'title' = ANY(a2.loc) ORDER BY a2.score DESC LIMIT 1), '[]'::jsonb),
                
                'poem_line', COALESCE((
                    SELECT matches_json 
                    FROM all_matches a3 
                    WHERE a3.poem_id = am.poem_id 
                      AND 'poem_line' = ANY(a3.loc) 
                      AND (a3.row_id = (array_agg(am.row_id ORDER BY CASE WHEN 'poem_line' = ANY(am.loc) THEN 1 ELSE 0 END DESC, am.score DESC))[1]) 
                    LIMIT 1), '{}'::jsonb)
            ) as match
        FROM all_matches am
        CROSS JOIN LATERAL unnest(am.loc) as unnest_val
        WHERE am.score >= min_score
        GROUP BY am.poem_id
    )
    
    SELECT 
        bpp.poem_id, bpp.row_id, bpp.title_raw, bpp.poem_line_raw, round(bpp.final_score, 1) as score, bpp.match_locations, bpp.match_type, bpp.match
    FROM best_per_poem bpp
    ORDER BY bpp.final_score DESC, bpp.poem_id ASC
    LIMIT match_limit;
END;
$$;