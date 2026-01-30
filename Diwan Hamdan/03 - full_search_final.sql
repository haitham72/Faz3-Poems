-- =====================================================
-- FULL SEARCH V2 - WITH EXACT MATCHING & EXCLUSION
-- =====================================================
-- Changes:
-- 1. Exact word matching for metadata (no substring matches)
-- 2. Exclude metadata matches if already found in title/line
-- =====================================================

DROP FUNCTION IF EXISTS full_search_v2(TEXT, JSONB, INT) CASCADE;

CREATE OR REPLACE FUNCTION full_search_v2(
    search_query TEXT,
    enabled_columns JSONB DEFAULT '{"title": true, "line": true, "entities": false, "places": false, "events": false, "religion": false, "subjects": false, "animals": false, "sentiments": false}'::jsonb,
    result_limit INT DEFAULT 20
)
RETURNS TABLE(
    result_type TEXT,
    display_type TEXT,
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    matched_columns TEXT[],
    highlight_words JSONB,
    priority INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    q TEXT;
    words TEXT[];
    word_count INT;
    use_exact_match BOOLEAN;
    search_title BOOLEAN;
    search_line BOOLEAN;
    search_entities BOOLEAN;
    search_places BOOLEAN;
    search_events BOOLEAN;
    search_religion BOOLEAN;
    search_subjects BOOLEAN;
    search_animals BOOLEAN;
    search_sentiments BOOLEAN;
BEGIN
    q := trim(normalize_arabic(search_query));
    
    -- Sanitize query
    q := regexp_replace(q, '["\[\]{}''`]', '', 'g');
    
    IF char_length(q) < 2 THEN
        RETURN;
    END IF;
    
    -- Split query into words (keep بن - it's meaningful!)
    words := regexp_split_to_array(q, '\s+');
    words := ARRAY(
        SELECT word FROM unnest(words) word 
        WHERE char_length(word) > 1 
        AND word NOT IN ('في', 'من', 'على', 'إلى', 'عن', 'مع', 'كل', 'هذا', 'ذلك', 'التي', 'الذي', 'أن', 'أو', 'لا', 'ما', 'إذا', 'إن', 'قد', 'لم', 'لن', 'هل')
    );
    
    word_count := COALESCE(array_length(words, 1), 0);
    use_exact_match := (word_count >= 4);
    
    -- Extract enabled columns
    search_title := COALESCE((enabled_columns->>'title')::boolean, true);
    search_line := COALESCE((enabled_columns->>'line')::boolean, true);
    search_entities := COALESCE((enabled_columns->>'entities')::boolean, false);
    search_places := COALESCE((enabled_columns->>'places')::boolean, false);
    search_events := COALESCE((enabled_columns->>'events')::boolean, false);
    search_religion := COALESCE((enabled_columns->>'religion')::boolean, false);
    search_subjects := COALESCE((enabled_columns->>'subjects')::boolean, false);
    search_animals := COALESCE((enabled_columns->>'animals')::boolean, false);
    search_sentiments := COALESCE((enabled_columns->>'sentiments')::boolean, false);
    
    RETURN QUERY
    WITH all_matches AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            d.entities,
            d.animals,
            d.places,
            d.sentiments,
            
            -- Check title match
            CASE 
                WHEN use_exact_match THEN 
                    (search_title AND d."Title_cleaned" ILIKE '%' || q || '%')
                ELSE 
                    (search_title AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%'))
            END as title_matched,
            
            -- Check line match
            CASE 
                WHEN use_exact_match THEN 
                    (search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%')
                ELSE 
                    (search_line AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%'))
            END as line_matched,
            
            -- Matched columns array with EXACT matching for metadata
            ARRAY(
                SELECT DISTINCT col FROM (
                    SELECT unnest(ARRAY[
                        -- Title/Line use substring matching (ILIKE)
                        CASE 
                            WHEN use_exact_match AND search_title AND d."Title_cleaned" ILIKE '%' || q || '%' THEN 'title'
                            WHEN NOT use_exact_match AND search_title AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%') THEN 'title'
                        END,
                        CASE 
                            WHEN use_exact_match AND search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%' THEN 'line'
                            WHEN NOT use_exact_match AND search_line AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%') THEN 'line'
                        END,
                        
                        -- Metadata uses FUZZY matching (similarity threshold ~0.6)
                        CASE WHEN search_entities AND d.entities IS NOT NULL AND jsonb_typeof(d.entities) = 'array' AND (
                            SELECT COUNT(DISTINCT w) = word_count
                            FROM unnest(words) w
                            WHERE EXISTS(
                                SELECT 1 FROM jsonb_array_elements(d.entities) e
                                WHERE similarity(e->>'name', w) > 0.5
                                OR similarity(e->>'relation', w) > 0.5
                                OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf WHERE similarity(rf, w) > 0.5)
                            )
                        ) THEN 'entities' END,
                        
                        CASE WHEN search_places AND d.places IS NOT NULL AND jsonb_typeof(d.places) = 'array' AND (
                            SELECT COUNT(DISTINCT w) = word_count
                            FROM unnest(words) w
                            WHERE EXISTS(
                                SELECT 1 FROM jsonb_array_elements(d.places) p
                                WHERE similarity(p->>'name', w) > 0.5 OR similarity(p->>'type', w) > 0.5
                            )
                        ) THEN 'places' END,
                        
                        CASE WHEN search_subjects AND d.subjects IS NOT NULL AND jsonb_typeof(d.subjects) = 'array' AND (
                            SELECT COUNT(DISTINCT w) = word_count
                            FROM unnest(words) w
                            WHERE EXISTS(SELECT 1 FROM jsonb_array_elements_text(d.subjects) s WHERE similarity(s, w) > 0.5)
                        ) THEN 'subjects' END,
                        
                        CASE WHEN search_animals AND d.animals IS NOT NULL AND jsonb_typeof(d.animals) = 'array' AND (
                            SELECT COUNT(DISTINCT w) = word_count
                            FROM unnest(words) w
                            WHERE EXISTS(
                                SELECT 1 FROM jsonb_array_elements(d.animals) a
                                WHERE similarity(a->>'name', w) > 0.5
                                OR similarity(a->>'type', w) > 0.5
                                OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') rf WHERE similarity(rf, w) > 0.5)
                            )
                        ) THEN 'animals' END,
                        
                        CASE WHEN search_sentiments AND d.sentiments IS NOT NULL AND similarity(d.sentiments, q) > 0.5 THEN 'sentiments' END,
                        
                        CASE WHEN search_events AND d.events IS NOT NULL AND jsonb_typeof(d.events) = 'array' AND (
                            SELECT COUNT(DISTINCT w) = word_count
                            FROM unnest(words) w
                            WHERE EXISTS(SELECT 1 FROM jsonb_array_elements_text(d.events) e WHERE similarity(e, w) > 0.5)
                        ) THEN 'events' END,
                        
                        CASE WHEN search_religion AND d.religion IS NOT NULL AND jsonb_typeof(d.religion) = 'array' AND (
                            SELECT COUNT(DISTINCT w) = word_count
                            FROM unnest(words) w
                            WHERE EXISTS(SELECT 1 FROM jsonb_array_elements_text(d.religion) r WHERE similarity(r, w) > 0.5)
                        ) THEN 'religion' END
                    ]) as col
                ) t WHERE col IS NOT NULL
            ) as all_matched_cols
            
        FROM "Diwan_Hamdan" d
        WHERE 
            -- Title/Line matching (ILIKE substring)
            (use_exact_match AND (
                (search_title AND d."Title_cleaned" ILIKE '%' || q || '%') OR
                (search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%')
            ))
            OR
            (NOT use_exact_match AND (
                (search_title AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%')) OR
                (search_line AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%'))
            ))
            OR
            -- Metadata matching (FUZZY similarity > 0.5)
            (search_entities AND d.entities IS NOT NULL AND EXISTS(
                SELECT 1 FROM unnest(words) w, jsonb_array_elements(d.entities) e
                WHERE similarity(e->>'name', w) > 0.5 OR similarity(e->>'relation', w) > 0.5
                OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf WHERE similarity(rf, w) > 0.5)
            ))
            OR
            (search_places AND d.places IS NOT NULL AND EXISTS(
                SELECT 1 FROM unnest(words) w, jsonb_array_elements(d.places) p
                WHERE similarity(p->>'name', w) > 0.5 OR similarity(p->>'type', w) > 0.5
            ))
            OR
            (search_subjects AND d.subjects IS NOT NULL AND EXISTS(
                SELECT 1 FROM unnest(words) w, jsonb_array_elements_text(d.subjects) s
                WHERE similarity(s, w) > 0.5
            ))
            OR
            (search_animals AND d.animals IS NOT NULL AND EXISTS(
                SELECT 1 FROM unnest(words) w, jsonb_array_elements(d.animals) a
                WHERE similarity(a->>'name', w) > 0.5 OR similarity(a->>'type', w) > 0.5
                OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') rf WHERE similarity(rf, w) > 0.5)
            ))
            OR
            (search_sentiments AND d.sentiments IS NOT NULL AND similarity(d.sentiments, q) > 0.5)
            OR
            (search_events AND d.events IS NOT NULL AND EXISTS(
                SELECT 1 FROM unnest(words) w, jsonb_array_elements_text(d.events) e
                WHERE similarity(e, w) > 0.5
            ))
            OR
            (search_religion AND d.religion IS NOT NULL AND EXISTS(
                SELECT 1 FROM unnest(words) w, jsonb_array_elements_text(d.religion) r
                WHERE similarity(r, w) > 0.5
            ))
    ),
    
    filtered_matches AS (
        SELECT 
            am.*,
            -- CRITICAL: Remove metadata from matched_cols if already in title/line
            ARRAY(
                SELECT col FROM unnest(am.all_matched_cols) col
                WHERE 
                    -- Keep title/line always
                    col IN ('title', 'line')
                    OR
                    -- Only keep metadata if NOT already matched in title/line
                    (col NOT IN ('title', 'line') AND NOT (am.title_matched OR am.line_matched))
            ) as matched_cols,
            
            -- Build highlight words
            jsonb_build_object(
                'entities', CASE WHEN 'entities' = ANY(am.all_matched_cols) AND am.entities IS NOT NULL THEN (
                    SELECT jsonb_agg(DISTINCT word)
                    FROM jsonb_array_elements(am.entities) e,
                    LATERAL (
                        SELECT jsonb_array_elements_text(e->'resolved_from') as word
                        UNION SELECT e->>'name' as word
                    ) words
                ) ELSE '[]'::jsonb END,
                'animals', CASE WHEN 'animals' = ANY(am.all_matched_cols) AND am.animals IS NOT NULL THEN (
                    SELECT jsonb_agg(DISTINCT word)
                    FROM jsonb_array_elements(am.animals) a,
                    LATERAL (
                        SELECT jsonb_array_elements_text(a->'resolved_from') as word
                        UNION SELECT a->>'name' as word
                    ) words
                ) ELSE '[]'::jsonb END,
                'places', CASE WHEN 'places' = ANY(am.all_matched_cols) AND am.places IS NOT NULL THEN (
                    SELECT jsonb_agg(p->>'name') FROM jsonb_array_elements(am.places) p
                ) ELSE '[]'::jsonb END,
                'sentiments', CASE WHEN 'sentiments' = ANY(am.all_matched_cols) AND am.sentiments IS NOT NULL THEN 
                    jsonb_build_array(am.sentiments)
                ELSE '[]'::jsonb END
            ) as highlight_data,
            
            -- Priority
            CASE 
                WHEN am.title_matched AND am.line_matched THEN 1
                WHEN am.title_matched THEN 2
                WHEN am.line_matched THEN 3
                ELSE 4
            END as calc_priority
        FROM all_matches am
        WHERE array_length(am.all_matched_cols, 1) > 0
    ),
    
    clean_matches AS (
        SELECT fm.*
        FROM filtered_matches fm
        WHERE 
            -- If ONLY metadata columns enabled (title AND line both OFF)
            -- Then exclude rows that matched in title/line text
            NOT (
                NOT search_title AND NOT search_line  -- Both title and line are OFF
                AND (fm.title_matched OR fm.line_matched)  -- But it matched in text anyway
            )
    ),
    
    final_results AS (
        -- Poem-only results
        SELECT 
            'poem_only'::TEXT as res_type,
            'carousel'::TEXT as disp_type,
            cm.poem_id as p_id,
            MIN(cm."Row_ID") as r_id,
            MAX(cm."Title_cleaned") as t_clean,
            NULL::TEXT as pl_clean,
            MAX(cm.matched_cols) as m_cols,
            (array_agg(cm.highlight_data))[1] as h_data,
            2 as prio
        FROM clean_matches cm
        WHERE cm.title_matched = TRUE
        AND cm.poem_id NOT IN (
            SELECT cm2.poem_id FROM clean_matches cm2 WHERE cm2.line_matched = TRUE
        )
        GROUP BY cm.poem_id
        
        UNION ALL
        
        -- Line matches OR metadata-only matches
        SELECT 
            'line_match'::TEXT as res_type,
            'list'::TEXT as disp_type,
            cm.poem_id as p_id,
            cm."Row_ID" as r_id,
            cm."Title_cleaned" as t_clean,
            cm."Poem_line_cleaned" as pl_clean,
            cm.matched_cols as m_cols,
            cm.highlight_data as h_data,
            cm.calc_priority as prio
        FROM clean_matches cm
        WHERE cm.line_matched = TRUE
           OR (cm.line_matched = FALSE AND cm.title_matched = FALSE AND array_length(cm.matched_cols, 1) > 0)
    )
    
    SELECT 
        fr.res_type,
        fr.disp_type,
        fr.p_id,
        fr.r_id,
        fr.t_clean,
        fr.pl_clean,
        fr.m_cols,
        fr.h_data,
        fr.prio
    FROM final_results fr
    ORDER BY 
        CASE WHEN fr.disp_type = 'carousel' THEN 1 ELSE 2 END,
        fr.prio,
        fr.p_id DESC
    LIMIT result_limit;
END;
$$;

-- Test
SELECT * FROM full_search_v2('حب', '{"title": false, "line": false, "sentiments": true}'::jsonb, 10);