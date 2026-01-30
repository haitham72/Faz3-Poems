-- =====================================================
-- FULL SEARCH - NO AMBIGUITY VERSION
-- =====================================================

DROP FUNCTION IF EXISTS full_search(TEXT, JSONB, INT) CASCADE;

CREATE OR REPLACE FUNCTION full_search(
    search_query TEXT,
    enabled_columns JSONB DEFAULT '{"title": true, "line": true, "entities": false, "places": false, "events": false, "religion": false, "subjects": false, "animals": false, "sentiments": false}'::jsonb,
    result_limit INT DEFAULT 20
)
RETURNS TABLE(
    result_type TEXT,        -- 'poem_only' or 'line_match'
    display_type TEXT,       -- 'carousel' or 'list'
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,  -- NULL for carousel items
    matched_columns TEXT[],
    highlight_words JSONB,   -- Words to highlight {entities: ["حمدان"], animals: ["الخيل"], places: ["سوق الغلا"]}
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
    
    -- Sanitize query: remove quotes, brackets, and other JSON-breaking characters
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
            
            -- Check if title matched
            CASE 
                WHEN use_exact_match THEN 
                    (search_title AND d."Title_cleaned" ILIKE '%' || q || '%')
                ELSE 
                    (search_title AND (
                        SELECT COUNT(*) = word_count
                        FROM unnest(words) w 
                        WHERE d."Title_cleaned" ILIKE '%' || w || '%'
                    ))
            END as title_matched,
            
            -- Check if line matched
            CASE 
                WHEN use_exact_match THEN 
                    (search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%')
                ELSE 
                    (search_line AND (
                        SELECT COUNT(*) = word_count
                        FROM unnest(words) w 
                        WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%'
                    ))
            END as line_matched,
            
            -- Matched columns array
            ARRAY(
                SELECT DISTINCT col FROM (
                    SELECT unnest(ARRAY[
                        CASE 
                            WHEN use_exact_match AND search_title AND d."Title_cleaned" ILIKE '%' || q || '%' 
                            THEN 'title'
                            WHEN NOT use_exact_match AND search_title AND (
                                SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%'
                            ) THEN 'title'
                        END,
                        CASE 
                            WHEN use_exact_match AND search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%' 
                            THEN 'line'
                            WHEN NOT use_exact_match AND search_line AND (
                                SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%'
                            ) THEN 'line'
                        END,
                        CASE WHEN search_entities AND d.entities IS NOT NULL AND jsonb_typeof(d.entities) = 'array' AND EXISTS(
                            SELECT 1 FROM jsonb_array_elements(d.entities) e
                            WHERE e->>'name' ILIKE '%' || q || '%' 
                            OR e->>'relation' ILIKE '%' || q || '%'
                            OR EXISTS(
                                SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf
                                WHERE rf ILIKE '%' || q || '%'
                            )
                        ) THEN 'entities' END,
                        CASE WHEN search_places AND d.places IS NOT NULL AND jsonb_typeof(d.places) = 'array' AND EXISTS(
                            SELECT 1 FROM jsonb_array_elements(d.places) p
                            WHERE p->>'name' ILIKE '%' || q || '%' OR p->>'type' ILIKE '%' || q || '%'
                        ) THEN 'places' END,
                        CASE WHEN search_events AND d.events::text ILIKE '%' || q || '%' THEN 'events' END,
                        CASE WHEN search_religion AND d.religion::text ILIKE '%' || q || '%' THEN 'religion' END,
                        CASE WHEN search_subjects AND d.subjects::text ILIKE '%' || q || '%' THEN 'subjects' END,
                        CASE WHEN search_animals AND d.animals IS NOT NULL AND jsonb_typeof(d.animals) = 'array' AND EXISTS(
                            SELECT 1 FROM jsonb_array_elements(d.animals) a
                            WHERE a->>'name' ILIKE '%' || q || '%' 
                            OR a->>'type' ILIKE '%' || q || '%'
                            OR EXISTS(
                                SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') rf
                                WHERE rf ILIKE '%' || q || '%'
                            )
                        ) THEN 'animals' END,
                        CASE WHEN search_sentiments AND d.sentiments IS NOT NULL AND d.sentiments ILIKE '%' || q || '%' THEN 'sentiments' END
                    ]) as col
                ) t WHERE col IS NOT NULL
            ) as matched_cols,
            
            -- Build highlight words JSON for client-side highlighting
            jsonb_build_object(
                'entities', CASE WHEN search_entities AND d.entities IS NOT NULL THEN (
                    SELECT jsonb_agg(DISTINCT word)
                    FROM jsonb_array_elements(d.entities) e,
                    LATERAL (
                        SELECT jsonb_array_elements_text(e->'resolved_from') as word
                        UNION
                        SELECT e->>'name' as word
                    ) words
                ) ELSE '[]'::jsonb END,
                'animals', CASE WHEN search_animals AND d.animals IS NOT NULL THEN (
                    SELECT jsonb_agg(DISTINCT word)
                    FROM jsonb_array_elements(d.animals) a,
                    LATERAL (
                        SELECT jsonb_array_elements_text(a->'resolved_from') as word
                        UNION
                        SELECT a->>'name' as word
                    ) words
                ) ELSE '[]'::jsonb END,
                'places', CASE WHEN search_places AND d.places IS NOT NULL THEN (
                    SELECT jsonb_agg(p->>'name')
                    FROM jsonb_array_elements(d.places) p
                ) ELSE '[]'::jsonb END,
                'sentiments', CASE WHEN search_sentiments AND d.sentiments IS NOT NULL THEN 
                    jsonb_build_array(d.sentiments)
                ELSE '[]'::jsonb END
            ) as highlight_data,
            
            -- Priority
            CASE 
                WHEN (use_exact_match AND d."Title_cleaned" ILIKE '%' || q || '%' AND d."Poem_line_cleaned" ILIKE '%' || q || '%')
                  OR (NOT use_exact_match AND 
                      (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%') AND
                      (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%'))
                THEN 1
                WHEN (use_exact_match AND d."Title_cleaned" ILIKE '%' || q || '%')
                  OR (NOT use_exact_match AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%'))
                THEN 2
                WHEN (use_exact_match AND d."Poem_line_cleaned" ILIKE '%' || q || '%')
                  OR (NOT use_exact_match AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%'))
                THEN 3
                ELSE 4
            END as calc_priority
            
        FROM "Diwan_Hamdan" d
        WHERE 
            -- Exact match (4+ words)
            (use_exact_match AND (
                (search_title AND d."Title_cleaned" ILIKE '%' || q || '%') OR
                (search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%') OR
                (search_entities AND d.entities IS NOT NULL AND jsonb_typeof(d.entities) = 'array' AND EXISTS(
                    SELECT 1 FROM jsonb_array_elements(d.entities) e
                    WHERE e->>'name' ILIKE '%' || q || '%' 
                    OR e->>'relation' ILIKE '%' || q || '%'
                    OR EXISTS(
                        SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf
                        WHERE rf ILIKE '%' || q || '%'
                    )
                )) OR
                (search_places AND d.places IS NOT NULL AND jsonb_typeof(d.places) = 'array' AND EXISTS(
                    SELECT 1 FROM jsonb_array_elements(d.places) p
                    WHERE p->>'name' ILIKE '%' || q || '%'
                    OR p->>'type' ILIKE '%' || q || '%'
                )) OR
                (search_events AND d.events::text ILIKE '%' || q || '%') OR
                (search_religion AND d.religion::text ILIKE '%' || q || '%') OR
                (search_subjects AND d.subjects::text ILIKE '%' || q || '%') OR
                (search_animals AND d.animals IS NOT NULL AND jsonb_typeof(d.animals) = 'array' AND EXISTS(
                    SELECT 1 FROM jsonb_array_elements(d.animals) a
                    WHERE a->>'name' ILIKE '%' || q || '%' 
                    OR a->>'type' ILIKE '%' || q || '%'
                    OR EXISTS(
                        SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') rf
                        WHERE rf ILIKE '%' || q || '%'
                    )
                )) OR
                (search_sentiments AND d.sentiments IS NOT NULL AND d.sentiments ILIKE '%' || q || '%')
            ))
            OR
            -- OR match (1-3 words)
            (NOT use_exact_match AND (
                (search_title AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%')) OR
                (search_line AND (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%')) OR
                (search_entities AND d.entities IS NOT NULL AND jsonb_typeof(d.entities) = 'array' AND (
                    SELECT COUNT(DISTINCT w) = word_count
                    FROM unnest(words) w
                    WHERE EXISTS(
                        SELECT 1 FROM jsonb_array_elements(d.entities) e
                        WHERE e->>'name' ILIKE '%' || w || '%' 
                        OR e->>'relation' ILIKE '%' || w || '%'
                        OR EXISTS(
                            SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf
                            WHERE rf ILIKE '%' || w || '%'
                        )
                    )
                )) OR
                (search_places AND d.places IS NOT NULL AND jsonb_typeof(d.places) = 'array' AND (
                    SELECT COUNT(DISTINCT w) = word_count
                    FROM unnest(words) w
                    WHERE EXISTS(
                        SELECT 1 FROM jsonb_array_elements(d.places) p
                        WHERE p->>'name' ILIKE '%' || w || '%'
                        OR p->>'type' ILIKE '%' || w || '%'
                    )
                )) OR
                (search_events AND EXISTS(SELECT 1 FROM unnest(words) w WHERE d.events::text ILIKE '%' || w || '%')) OR
                (search_religion AND EXISTS(SELECT 1 FROM unnest(words) w WHERE d.religion::text ILIKE '%' || w || '%')) OR
                (search_subjects AND EXISTS(SELECT 1 FROM unnest(words) w WHERE d.subjects::text ILIKE '%' || w || '%')) OR
                (search_animals AND d.animals IS NOT NULL AND jsonb_typeof(d.animals) = 'array' AND (
                    SELECT COUNT(DISTINCT w) = word_count
                    FROM unnest(words) w
                    WHERE EXISTS(
                        SELECT 1 FROM jsonb_array_elements(d.animals) a
                        WHERE a->>'name' ILIKE '%' || w || '%' 
                        OR a->>'type' ILIKE '%' || w || '%'
                        OR EXISTS(
                            SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') rf
                            WHERE rf ILIKE '%' || w || '%'
                        )
                    )
                )) OR
                (search_sentiments AND d.sentiments IS NOT NULL AND 
                    EXISTS(SELECT 1 FROM unnest(words) w WHERE d.sentiments ILIKE '%' || w || '%')
                )
            ))
    ),
    
    final_results AS (
        -- Poem-only results (carousel - no lines shown)
        -- Title matched but no line matches in entire poem
        SELECT 
            'poem_only'::TEXT as res_type,
            'carousel'::TEXT as disp_type,
            am.poem_id as p_id,
            MIN(am."Row_ID") as r_id,
            MAX(am."Title_cleaned") as t_clean,
            NULL::TEXT as pl_clean,
            MAX(am.matched_cols) as m_cols,
            (array_agg(am.highlight_data))[1] as h_data,
            2 as prio
        FROM all_matches am
        WHERE am.title_matched = TRUE
        AND am.poem_id NOT IN (
            SELECT am2.poem_id FROM all_matches am2 WHERE am2.line_matched = TRUE
        )
        GROUP BY am.poem_id
        
        UNION ALL
        
        -- Line match results OR metadata-only matches (list - show individual lines)
        SELECT 
            'line_match'::TEXT as res_type,
            'list'::TEXT as disp_type,
            am.poem_id as p_id,
            am."Row_ID" as r_id,
            am."Title_cleaned" as t_clean,
            am."Poem_line_cleaned" as pl_clean,
            am.matched_cols as m_cols,
            am.highlight_data as h_data,
            am.calc_priority as prio
        FROM all_matches am
        WHERE am.line_matched = TRUE
           OR (am.line_matched = FALSE AND am.title_matched = FALSE AND array_length(am.matched_cols, 1) > 0)
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