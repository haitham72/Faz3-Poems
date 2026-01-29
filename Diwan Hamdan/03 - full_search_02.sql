-- =====================================================
-- FULL SEARCH - FIXED
-- Handles NULL/scalar JSONB values properly
-- =====================================================

DROP FUNCTION IF EXISTS full_search(TEXT, JSONB, INT) CASCADE;

CREATE OR REPLACE FUNCTION full_search(
    search_query TEXT,
    enabled_columns JSONB DEFAULT '{"title": true, "line": true, "entities": true, "places": true, "events": true, "religion": true, "subjects": true, "sentiments": true}'::jsonb,
    result_limit INT DEFAULT 150
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    match_reasons JSONB,
    priority INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    q TEXT;
    search_title BOOLEAN;
    search_line BOOLEAN;
    search_entities BOOLEAN;
    search_places BOOLEAN;
    search_events BOOLEAN;
    search_religion BOOLEAN;
    search_subjects BOOLEAN;
    search_sentiments BOOLEAN;
BEGIN
    q := trim(normalize_arabic(search_query));
    
    IF char_length(q) < 2 THEN
        RETURN;
    END IF;
    
    -- Extract enabled columns
    search_title := COALESCE((enabled_columns->>'title')::boolean, true);
    search_line := COALESCE((enabled_columns->>'line')::boolean, true);
    search_entities := COALESCE((enabled_columns->>'entities')::boolean, false);
    search_places := COALESCE((enabled_columns->>'places')::boolean, false);
    search_events := COALESCE((enabled_columns->>'events')::boolean, false);
    search_religion := COALESCE((enabled_columns->>'religion')::boolean, false);
    search_subjects := COALESCE((enabled_columns->>'subjects')::boolean, false);
    search_sentiments := COALESCE((enabled_columns->>'sentiments')::boolean, false);
    
    RETURN QUERY
    WITH matches AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            
            -- Track which columns matched
            jsonb_build_object(
                'matched_columns', jsonb_build_array(
                    CASE WHEN search_title AND d."Title_cleaned" ILIKE '%' || q || '%' 
                         THEN 'title' ELSE NULL END,
                    CASE WHEN search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%' 
                         THEN 'line' ELSE NULL END,
                    CASE WHEN search_entities 
                         AND d.entities IS NOT NULL 
                         AND jsonb_typeof(d.entities) = 'array'
                         AND (
                        -- Match ANY text in the entire entities JSONB
                        d.entities::text ILIKE '%' || q || '%'
                    ) THEN 'entities' ELSE NULL END,
                    CASE WHEN search_places 
                         AND d.places IS NOT NULL 
                         AND jsonb_typeof(d.places) = 'array'
                         AND (
                        -- Match ANY text in the entire places JSONB
                        d.places::text ILIKE '%' || q || '%'
                    ) THEN 'places' ELSE NULL END,
                    CASE WHEN search_events 
                         AND d.events IS NOT NULL 
                         AND jsonb_typeof(d.events) = 'array'
                         AND (
                        -- Match ANY text in events array
                        d.events::text ILIKE '%' || q || '%'
                    ) THEN 'events' ELSE NULL END,
                    CASE WHEN search_religion 
                         AND d.religion IS NOT NULL 
                         AND jsonb_typeof(d.religion) = 'array'
                         AND (
                        -- Match ANY text in religion array
                        d.religion::text ILIKE '%' || q || '%'
                    ) THEN 'religion' ELSE NULL END,
                    CASE WHEN search_subjects 
                         AND d.subjects IS NOT NULL 
                         AND jsonb_typeof(d.subjects) = 'array'
                         AND (
                        -- Match ANY text in subjects array
                        d.subjects::text ILIKE '%' || q || '%'
                    ) THEN 'subjects' ELSE NULL END,
                    CASE WHEN search_sentiments AND d.sentiments ILIKE '%' || q || '%' 
                         THEN 'sentiments' ELSE NULL END
                ) - NULL, -- Remove NULL values
                
                -- Entity details (ONLY if entities search is enabled)
                'entities', CASE WHEN search_entities THEN (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'semantic_name', e->>'name',
                            'relation', e->>'relation',
                            'matched_alias', (
                                SELECT alias
                                FROM jsonb_array_elements_text(e->'resolved_from') alias
                                WHERE normalize_arabic(alias) ILIKE '%' || q || '%'
                                LIMIT 1
                            ),
                            'matched_semantic', CASE 
                                WHEN e->>'name' ILIKE '%' || q || '%' THEN true
                                ELSE false
                            END,
                            'all_aliases', e->'resolved_from'
                        )
                    )
                    FROM jsonb_array_elements(d.entities) e
                    WHERE 
                        d.entities IS NOT NULL 
                        AND jsonb_typeof(d.entities) = 'array'
                        AND (
                            e->>'name' ILIKE '%' || q || '%' OR
                            (
                                jsonb_typeof(e->'resolved_from') = 'array'
                                AND EXISTS (
                                    SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') alias
                                    WHERE normalize_arabic(alias) ILIKE '%' || q || '%'
                                )
                            )
                        )
                ) ELSE NULL END,
                
                -- Place details (ONLY if places search is enabled)
                'places', CASE WHEN search_places THEN (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'name', p->>'name',
                            'type', p->>'type',
                            'matched_field', CASE 
                                WHEN p->>'name' ILIKE '%' || q || '%' THEN 'name'
                                WHEN p->>'type' ILIKE '%' || q || '%' THEN 'type'
                                ELSE NULL
                            END
                        )
                    )
                    FROM jsonb_array_elements(d.places) p
                    WHERE 
                        d.places IS NOT NULL 
                        AND jsonb_typeof(d.places) = 'array'
                        AND (
                            p->>'name' ILIKE '%' || q || '%' OR
                            p->>'type' ILIKE '%' || q || '%'
                        )
                ) ELSE NULL END,
                
                -- Events (ONLY if events search is enabled)
                'events', CASE WHEN search_events THEN (
                    SELECT jsonb_agg(ev)
                    FROM jsonb_array_elements_text(d.events) ev
                    WHERE 
                        d.events IS NOT NULL 
                        AND jsonb_typeof(d.events) = 'array'
                        AND normalize_arabic(ev) ILIKE '%' || q || '%'
                ) ELSE NULL END,
                
                -- Religion (ONLY if religion search is enabled)
                'religion', CASE WHEN search_religion THEN (
                    SELECT jsonb_agg(rel)
                    FROM jsonb_array_elements_text(d.religion) rel
                    WHERE 
                        d.religion IS NOT NULL 
                        AND jsonb_typeof(d.religion) = 'array'
                        AND normalize_arabic(rel) ILIKE '%' || q || '%'
                ) ELSE NULL END,
                
                -- Subjects (ONLY if subjects search is enabled)
                'subjects', CASE WHEN search_subjects THEN (
                    SELECT jsonb_agg(subj)
                    FROM jsonb_array_elements_text(d.subjects) subj
                    WHERE 
                        d.subjects IS NOT NULL 
                        AND jsonb_typeof(d.subjects) = 'array'
                        AND normalize_arabic(subj) ILIKE '%' || q || '%'
                ) ELSE NULL END,
                
                -- Sentiment (ONLY if sentiment search is enabled)
                'sentiment', CASE 
                    WHEN search_sentiments AND d.sentiments ILIKE '%' || q || '%' THEN d.sentiments
                    ELSE NULL
                END
            ) as match_reasons,
            
            -- Calculate priority
            CASE 
                WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
                 AND d."Poem_line_cleaned" ILIKE '%' || q || '%' 
                THEN 1  -- Both
                WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
                THEN 2  -- Title only
                WHEN d."Poem_line_cleaned" ILIKE '%' || q || '%' 
                THEN 3  -- Line only
                ELSE 4  -- Metadata only
            END as calc_priority
            
        FROM "Diwan_Hamdan" d
        WHERE 
            (search_title AND d."Title_cleaned" ILIKE '%' || q || '%') OR
            (search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%') OR
            (search_entities 
             AND d.entities IS NOT NULL 
             AND jsonb_typeof(d.entities) = 'array'
             AND d.entities::text ILIKE '%' || q || '%') OR
            (search_places 
             AND d.places IS NOT NULL 
             AND jsonb_typeof(d.places) = 'array'
             AND d.places::text ILIKE '%' || q || '%') OR
            (search_events 
             AND d.events IS NOT NULL 
             AND jsonb_typeof(d.events) = 'array'
             AND d.events::text ILIKE '%' || q || '%') OR
            (search_religion 
             AND d.religion IS NOT NULL 
             AND jsonb_typeof(d.religion) = 'array'
             AND d.religion::text ILIKE '%' || q || '%') OR
            (search_subjects 
             AND d.subjects IS NOT NULL 
             AND jsonb_typeof(d.subjects) = 'array'
             AND d.subjects::text ILIKE '%' || q || '%') OR
            (search_sentiments AND d.sentiments ILIKE '%' || q || '%')
    )
    SELECT 
        m.poem_id,
        m."Row_ID",
        m."Title_cleaned",
        m."Poem_line_cleaned",
        m.match_reasons,
        m.calc_priority
    FROM matches m
    ORDER BY m.calc_priority, m.poem_id DESC
    LIMIT result_limit;
END;
$$;

-- =====================================================
-- KEY FIXES:
-- =====================================================
-- 1. Added: jsonb_typeof() checks before array operations
-- 2. Added: IS NOT NULL checks
-- 3. Fixed: Entity matching - now checks ALL entities
-- 4. Added: 'matched_semantic' flag to show if semantic name matched
-- =====================================================