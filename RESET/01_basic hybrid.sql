DROP FUNCTION IF EXISTS hybrid_search_v1_core(JSONB, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION hybrid_search_v1_core(
    search_payload JSONB, -- <--- NEW: Accepts the full N8N JSON (Step 3)
    match_limit INT DEFAULT 50,
    min_score NUMERIC DEFAULT 0.3
)
RETURNS TABLE(
    query_tag TEXT,       -- <--- NEW: Returns the tag (e.g., "Bo Khaled", "MBZ")
    confidence_score INT, -- <--- NEW: From N8N
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
    -- Variables for your original logic
    rec record;
    q_norm TEXT;
    query_words TEXT[];
    meaningful_words TEXT[];
    current_word TEXT;
BEGIN
    RETURN QUERY
    -- 1. Unpack N8N JSON (The only major structural addition)
    WITH inputs AS (
        SELECT 
            (elem->>'query')::text AS raw_query,
            (elem->>'tag')::text AS tag,
            COALESCE((elem->>'confidence_score')::int, 100) AS conf_score
        FROM jsonb_array_elements(search_payload->'N8N_query'->'expanded_queries') AS elem
        UNION ALL
        SELECT 
            (search_payload->'N8N_query'->>'Exact_query')::text,
            (search_payload->'N8N_query'->>'tag')::text,
            (search_payload->'N8N_query'->>'confidence_score')::int
    ),
    
    -- 2. Processing (Wrapping YOUR original logic in a lateral join)
    processed_queries AS (
        SELECT 
            i.raw_query,
            i.tag,
            i.conf_score,
            TRIM(normalize_arabic(i.raw_query)) as q_norm,
            string_to_array(trim(i.raw_query), ' ') as query_words,
            -- Your exact Particle Filtering Logic
            ARRAY(
                SELECT word 
                FROM unnest(string_to_array(trim(i.raw_query), ' ')) AS word
                WHERE NOT is_common_particle(word) 
                AND normalize_arabic(word) NOT IN ('بن', 'ابن', 'بو', 'ابو', 'ال')
            ) as meaningful_words
        FROM inputs i
    ),

    title_matches AS (
        SELECT 
            pq.tag,
            pq.conf_score,
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            'title'::text as loc,
            
            -- YOUR ORIGINAL TIERED LOGIC (PRESERVED)
            (CASE
                -- TIER 1: Exact Whole Word / Full Substring
                WHEN (' ' || normalize_arabic(e."Title_cleaned") || ' ') LIKE ('% ' || pq.q_norm || ' %') THEN 110.0
                WHEN position(pq.q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 110.0

                -- TIER 2: Consecutive Words (Complex Loop Logic Preserved via Arrays)
                WHEN array_length(pq.meaningful_words, 1) > 1 AND
                     EXISTS (
                         SELECT 1
                         FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(word, idx)
                         WHERE (
                             SELECT bool_and(
                                 EXISTS (
                                     SELECT 1 
                                     FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2)
                                     WHERE normalize_arabic(u2.word2) = normalize_arabic(mw)
                                       AND idx2 BETWEEN idx AND idx + array_length(pq.meaningful_words, 1) + 2
                                 )
                             )
                             FROM unnest(pq.meaningful_words) mw
                         )
                     )
                    THEN 90.0 + (array_length(pq.meaningful_words, 1) * 2)

                -- TIER 3: All Words Scattered
                WHEN array_length(pq.meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Title_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                     ) FROM unnest(pq.meaningful_words) w)
                    THEN 60.0 + (array_length(pq.meaningful_words, 1) * 2)

                -- TIER 4: Partial/Fuzzy Words
                WHEN EXISTS (
                    SELECT 1 FROM unnest(pq.meaningful_words) w
                    WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                       OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                )
                    THEN 85.0 + (
                        SELECT COUNT(*)::numeric * 10
                        FROM unnest(pq.meaningful_words) w
                        WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0
                           OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0
                    )
                ELSE 0
            END)::numeric as field_score,
            
            -- Your Match Type Logic
            (CASE
                WHEN (' ' || normalize_arabic(e."Title_cleaned") || ' ') LIKE ('% ' || pq.q_norm || ' %') THEN 'exact_phrase'
                WHEN position(pq.q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 'partial_match'
                -- (Shortened for brevity, but assumes your full logic here)
                ELSE 'partial_words'
            END)::text as match_type,
            
            -- YOUR JSON BUILDING LOGIC (PRESERVED)
            COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'text', match_info.pw,
                    'positions', (match_info.pos[1])::text,
                    'score', match_info.scr
                ) ORDER BY match_info.scr DESC)
                FROM (
                    SELECT 
                        pw, array_agg(idx-1) as pos, 
                        CASE WHEN position(pq.q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 110 ELSE 50 END as scr
                    FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(pw, idx)
                    WHERE pw <> '' 
                    AND (
                        position(normalize_arabic(pw) IN pq.q_norm) > 0 
                        OR position(pq.q_norm IN normalize_arabic(pw)) > 0
                        OR EXISTS (SELECT 1 FROM unnest(pq.meaningful_words) mw WHERE normalize_arabic(pw) LIKE '%'||normalize_arabic(mw)||'%')
                    )
                    GROUP BY pw
                ) match_info
            ), '[]'::jsonb) as matches_json

        FROM processed_queries pq
        JOIN "Exact_search" e ON 
             position(lower(pq.raw_query) IN lower(e."Title_cleaned")) > 0 
             OR position(pq.q_norm IN normalize_arabic(e."Title_cleaned")) > 0 
             OR EXISTS (SELECT 1 FROM unnest(pq.meaningful_words) w WHERE position(lower(w) IN lower(e."Title_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0)
    ),

    poem_matches AS (
        SELECT 
            pq.tag,
            pq.conf_score,
            e.poem_id, 
            e."Row_ID" as row_id, 
            e."Title_raw" as title_raw, 
            e."Poem_line_raw" as poem_line_raw, 
            'poem_line'::text as loc,
            
            -- YOUR ORIGINAL POEM TIERS (PRESERVED)
            (CASE
                -- TIER 1: Exact Whole Word
                WHEN (' ' || normalize_arabic(e."Poem_line_cleaned") || ' ') LIKE ('% ' || pq.q_norm || ' %') THEN 100.0
                -- TIER 2: Substring
                WHEN position(pq.q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 90.0
                -- TIER 3: Scattered/Fuzzy (Preserved)
                WHEN array_length(pq.meaningful_words, 1) > 1 AND
                     (SELECT bool_and(
                         position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 
                         OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                     ) FROM unnest(pq.meaningful_words) w)
                    THEN 55.0 + (array_length(pq.meaningful_words, 1) * 2)
                ELSE 0
            END)::numeric as field_score,
            
            'partial_match'::text as match_type, -- Simplified for the wrapper example, put your full CASE here

            -- YOUR POEM JSON LOGIC
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
                            100 as scr
                        FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(pw, idx)
                        WHERE pw <> '' 
                        AND (
                            normalize_arabic(pw) LIKE '%' || pq.q_norm || '%'
                            OR EXISTS (SELECT 1 FROM unnest(pq.meaningful_words) mw WHERE normalize_arabic(pw) LIKE '%'||normalize_arabic(mw)||'%')
                        )
                        GROUP BY pw
                    ) mi
                ), '[]'::jsonb)
            ) as matches_json
            
        FROM processed_queries pq
        JOIN "Exact_search" e ON 
            position(lower(pq.raw_query) IN lower(e."Poem_line_cleaned")) > 0 
            OR position(pq.q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 
            OR EXISTS (SELECT 1 FROM unnest(pq.meaningful_words) w WHERE position(lower(w) IN lower(e."Poem_line_cleaned")) > 0 OR position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0)
    ),

    all_matches AS (
        SELECT tag, conf_score, poem_id, row_id, title_raw, poem_line_raw, field_score, loc, match_type, matches_json FROM title_matches WHERE field_score > 0
        UNION ALL
        SELECT tag, conf_score, poem_id, row_id, title_raw, poem_line_raw, field_score, loc, match_type, matches_json FROM poem_matches WHERE field_score > 0
    )

    -- 3. Final Selection (Modified to group by Poem ID but keep Tags)
    SELECT 
        (array_agg(am.tag))[1] as query_tag, -- The tag that triggered it
        (array_agg(am.conf_score))[1] as confidence_score,
        am.poem_id,
        (array_agg(am.row_id ORDER BY am.field_score DESC))[1] as row_id,
        (array_agg(am.title_raw))[1] as title_raw,
        (array_agg(am.poem_line_raw ORDER BY am.field_score DESC))[1] as poem_line_raw,
        MAX(am.field_score) as score,
        array_agg(DISTINCT am.loc) as match_location,
        (array_agg(am.match_type ORDER BY am.field_score DESC))[1] as match_type,
        
        -- Merge your JSON objects for Step 6
        jsonb_build_object(
            'title', COALESCE((SELECT matches_json FROM all_matches a2 WHERE a2.poem_id = am.poem_id AND a2.loc = 'title' LIMIT 1), '[]'::jsonb),
            'poem_line', COALESCE((SELECT matches_json FROM all_matches a3 WHERE a3.poem_id = am.poem_id AND a3.loc = 'poem_line' LIMIT 1), '{}'::jsonb)
        ) as match
        
    FROM all_matches am
    GROUP BY am.poem_id
    ORDER BY score DESC
    LIMIT match_limit;
END;
$$;