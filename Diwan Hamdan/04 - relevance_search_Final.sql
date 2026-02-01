-- =====================================================
-- RELEVANCE RANKED SEARCH - Industry Standard
-- =====================================================
-- Single heavy query returns rich JSON payload
-- Client handles all tab filtering
-- =====================================================

DROP FUNCTION IF EXISTS relevance_search(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION relevance_search(
    search_query TEXT,
    result_limit INT DEFAULT 100
)
RETURNS TABLE(
    rank INT,
    rank_score INT,
    match_type TEXT,
    matched_tabs TEXT[],
    poem_id INT,
    row_id INT,
    display_title TEXT,
    display_line TEXT,
    data JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    q TEXT;
    words TEXT[];
    word_count INT;
    use_exact_match BOOLEAN;
BEGIN
    -- Normalize and prepare query
    q := trim(normalize_arabic(search_query));
    
    IF char_length(q) < 2 THEN
        RETURN;
    END IF;
    
    -- Split query into words and remove stopwords
    words := regexp_split_to_array(q, '\s+');
    words := ARRAY(
        SELECT word FROM unnest(words) word 
        WHERE char_length(word) > 1 
        AND word NOT IN ('في', 'من', 'على', 'إلى', 'عن', 'مع', 'كل', 'هذا', 'ذلك', 'التي', 'الذي', 'أن', 'أو', 'لا', 'ما', 'إذا')
    );
    
    word_count := COALESCE(array_length(words, 1), 0);
    use_exact_match := (word_count >= 4);
    
    RETURN QUERY
    WITH scored_results AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            
            -- PRIMARY MATCH DETECTION (title/line)
            CASE 
                WHEN use_exact_match THEN d."Title_cleaned" ILIKE '%' || q || '%'
                ELSE (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Title_cleaned" ILIKE '%' || w || '%')
            END as title_match,
            
            CASE 
                WHEN use_exact_match THEN d."Poem_line_cleaned" ILIKE '%' || q || '%'
                ELSE (SELECT COUNT(*) = word_count FROM unnest(words) w WHERE d."Poem_line_cleaned" ILIKE '%' || w || '%')
            END as line_match,
            
            -- METADATA MATCH DETECTION (search inside name and resolved_from)
            CASE 
                WHEN use_exact_match THEN 
                    EXISTS(
                        SELECT 1 FROM jsonb_array_elements(COALESCE(d.entities, '[]'::jsonb)) e 
                        WHERE e->>'name' ILIKE '%' || q || '%' 
                        OR EXISTS(
                            SELECT 1 FROM jsonb_array_elements_text(COALESCE(e->'resolved_from', '[]'::jsonb)) rf 
                            WHERE rf ILIKE '%' || q || '%'
                        )
                    )
                ELSE 
                    EXISTS(
                        SELECT 1 FROM unnest(words) w 
                        WHERE EXISTS(
                            SELECT 1 FROM jsonb_array_elements(COALESCE(d.entities, '[]'::jsonb)) e 
                            WHERE e->>'name' ILIKE '%' || w || '%' 
                            OR EXISTS(
                                SELECT 1 FROM jsonb_array_elements_text(COALESCE(e->'resolved_from', '[]'::jsonb)) rf 
                                WHERE rf ILIKE '%' || w || '%'
                            )
                        )
                    )
            END as entities_match,
            
            CASE 
                WHEN use_exact_match THEN COALESCE(d.sentiments, '') ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE COALESCE(d.sentiments, '') ILIKE '%' || w || '%')
            END as sentiments_match,
            
            CASE 
                WHEN use_exact_match THEN COALESCE(d.events, '[]'::jsonb)::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE COALESCE(d.events, '[]'::jsonb)::text ILIKE '%' || w || '%')
            END as events_match,
            
            CASE 
                WHEN use_exact_match THEN COALESCE(d.religion, '[]'::jsonb)::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE COALESCE(d.religion, '[]'::jsonb)::text ILIKE '%' || w || '%')
            END as religion_match,
            
            CASE 
                WHEN use_exact_match THEN COALESCE(d.subjects, '[]'::jsonb)::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE COALESCE(d.subjects, '[]'::jsonb)::text ILIKE '%' || w || '%')
            END as subjects_match,
            
            CASE 
                WHEN use_exact_match THEN 
                    EXISTS(
                        SELECT 1 FROM jsonb_array_elements(COALESCE(d.places, '[]'::jsonb)) p 
                        WHERE p->>'name' ILIKE '%' || q || '%' 
                        OR COALESCE(p->>'resolved_from', '') ILIKE '%' || q || '%'
                    )
                ELSE 
                    EXISTS(
                        SELECT 1 FROM unnest(words) w 
                        WHERE EXISTS(
                            SELECT 1 FROM jsonb_array_elements(COALESCE(d.places, '[]'::jsonb)) p 
                            WHERE p->>'name' ILIKE '%' || w || '%' 
                            OR COALESCE(p->>'resolved_from', '') ILIKE '%' || w || '%'
                        )
                    )
            END as places_match,
            
            CASE 
                WHEN use_exact_match THEN 
                    EXISTS(
                        SELECT 1 FROM jsonb_array_elements(COALESCE(d.animals, '[]'::jsonb)) a 
                        WHERE a->>'name' ILIKE '%' || q || '%' 
                        OR EXISTS(
                            SELECT 1 FROM jsonb_array_elements_text(COALESCE(a->'resolved_from', '[]'::jsonb)) rf 
                            WHERE rf ILIKE '%' || q || '%'
                        )
                    )
                ELSE 
                    EXISTS(
                        SELECT 1 FROM unnest(words) w 
                        WHERE EXISTS(
                            SELECT 1 FROM jsonb_array_elements(COALESCE(d.animals, '[]'::jsonb)) a 
                            WHERE a->>'name' ILIKE '%' || w || '%' 
                            OR EXISTS(
                                SELECT 1 FROM jsonb_array_elements_text(COALESCE(a->'resolved_from', '[]'::jsonb)) rf 
                                WHERE rf ILIKE '%' || w || '%'
                            )
                        )
                    )
            END as animals_match,
            
            -- Store full data for client
            jsonb_build_object(
                'entities', COALESCE(d.entities, '[]'::jsonb),
                'places', COALESCE(d.places, '[]'::jsonb),
                'events', COALESCE(d.events, '[]'::jsonb),
                'religion', COALESCE(d.religion, '[]'::jsonb),
                'subjects', COALESCE(d.subjects, '[]'::jsonb),
                'animals', COALESCE(d.animals, '[]'::jsonb),
                'sentiments', COALESCE(d.sentiments, ''),
                'meter', COALESCE(d.meter, ''),
                'qafiya', COALESCE(d.qafiya, ''),
                'rawy', COALESCE(d.rawy, '')
            ) as full_data
            
        FROM "Diwan_Hamdan" d
        WHERE 
            -- Must match at least ONE field
            (use_exact_match AND (
                d."Title_cleaned" ILIKE '%' || q || '%' OR
                d."Poem_line_cleaned" ILIKE '%' || q || '%' OR
                EXISTS(
                    SELECT 1 FROM jsonb_array_elements(COALESCE(d.entities, '[]'::jsonb)) e 
                    WHERE e->>'name' ILIKE '%' || q || '%' 
                    OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(COALESCE(e->'resolved_from', '[]'::jsonb)) rf WHERE rf ILIKE '%' || q || '%')
                ) OR
                COALESCE(d.sentiments, '') ILIKE '%' || q || '%' OR
                COALESCE(d.events, '[]'::jsonb)::text ILIKE '%' || q || '%' OR
                COALESCE(d.religion, '[]'::jsonb)::text ILIKE '%' || q || '%' OR
                COALESCE(d.subjects, '[]'::jsonb)::text ILIKE '%' || q || '%' OR
                EXISTS(
                    SELECT 1 FROM jsonb_array_elements(COALESCE(d.places, '[]'::jsonb)) p 
                    WHERE p->>'name' ILIKE '%' || q || '%' OR COALESCE(p->>'resolved_from', '') ILIKE '%' || q || '%'
                ) OR
                EXISTS(
                    SELECT 1 FROM jsonb_array_elements(COALESCE(d.animals, '[]'::jsonb)) a 
                    WHERE a->>'name' ILIKE '%' || q || '%' 
                    OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(COALESCE(a->'resolved_from', '[]'::jsonb)) rf WHERE rf ILIKE '%' || q || '%')
                )
            ))
            OR
            (NOT use_exact_match AND (
                (SELECT COUNT(*) >= 1 FROM unnest(words) w WHERE 
                    d."Title_cleaned" ILIKE '%' || w || '%' OR
                    d."Poem_line_cleaned" ILIKE '%' || w || '%' OR
                    EXISTS(
                        SELECT 1 FROM jsonb_array_elements(COALESCE(d.entities, '[]'::jsonb)) e 
                        WHERE e->>'name' ILIKE '%' || w || '%' 
                        OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(COALESCE(e->'resolved_from', '[]'::jsonb)) rf WHERE rf ILIKE '%' || w || '%')
                    ) OR
                    COALESCE(d.sentiments, '') ILIKE '%' || w || '%' OR
                    COALESCE(d.events, '[]'::jsonb)::text ILIKE '%' || w || '%' OR
                    COALESCE(d.religion, '[]'::jsonb)::text ILIKE '%' || w || '%' OR
                    COALESCE(d.subjects, '[]'::jsonb)::text ILIKE '%' || w || '%' OR
                    EXISTS(
                        SELECT 1 FROM jsonb_array_elements(COALESCE(d.places, '[]'::jsonb)) p 
                        WHERE p->>'name' ILIKE '%' || w || '%' OR COALESCE(p->>'resolved_from', '') ILIKE '%' || w || '%'
                    ) OR
                    EXISTS(
                        SELECT 1 FROM jsonb_array_elements(COALESCE(d.animals, '[]'::jsonb)) a 
                        WHERE a->>'name' ILIKE '%' || w || '%' 
                        OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(COALESCE(a->'resolved_from', '[]'::jsonb)) rf WHERE rf ILIKE '%' || w || '%')
                    )
                )
            ))
    ),
    
    final_scored AS (
        SELECT 
            sr.*,
            
            -- PRIMARY SCORE (75 max)
            CASE 
                WHEN sr.title_match AND sr.line_match THEN 75  -- exact: both
                WHEN sr.title_match THEN 70                     -- title only
                WHEN sr.line_match THEN 50                      -- line only
                ELSE 0
            END as primary_score,
            
            -- METADATA SCORE (5 per field, 35 max)
            (CASE WHEN sr.entities_match THEN 5 ELSE 0 END +
             CASE WHEN sr.sentiments_match THEN 5 ELSE 0 END +
             CASE WHEN sr.events_match THEN 5 ELSE 0 END +
             CASE WHEN sr.religion_match THEN 5 ELSE 0 END +
             CASE WHEN sr.subjects_match THEN 5 ELSE 0 END +
             CASE WHEN sr.places_match THEN 5 ELSE 0 END +
             CASE WHEN sr.animals_match THEN 5 ELSE 0 END) as metadata_score,
            
            -- MATCH TYPE
            CASE 
                WHEN sr.title_match AND sr.line_match THEN 'exact'
                WHEN sr.title_match THEN 'title'
                WHEN sr.line_match THEN 'line'
                ELSE 'metadata'
            END as computed_match_type,
            
            -- MATCHED TABS (for client-side filtering) - title/line NOT included in metadata
            ARRAY(
                SELECT tab FROM (
                    SELECT unnest(ARRAY[
                        CASE WHEN sr.entities_match THEN 'entities' END,
                        CASE WHEN sr.sentiments_match THEN 'sentiments' END,
                        CASE WHEN sr.events_match THEN 'events' END,
                        CASE WHEN sr.religion_match THEN 'religion' END,
                        CASE WHEN sr.subjects_match THEN 'subjects' END,
                        CASE WHEN sr.places_match THEN 'places' END,
                        CASE WHEN sr.animals_match THEN 'animals' END
                    ]) as tab
                ) t WHERE tab IS NOT NULL
            ) as tabs_array
            
        FROM scored_results sr
    ),
    
    -- Step 1: Calculate previous row_id for each LINE MATCH
    line_with_lag AS (
        SELECT 
            fs.*,
            LAG(fs."Row_ID") OVER (PARTITION BY fs.poem_id ORDER BY fs."Row_ID") as prev_row_id
        FROM final_scored fs
        WHERE fs.line_match = TRUE
    ),
    
    -- Step 2: Detect groups of nearby lines (±2 rows)
    line_groups AS (
        SELECT 
            lwl.*,
            SUM(CASE 
                WHEN lwl."Row_ID" - COALESCE(lwl.prev_row_id, lwl."Row_ID") > 2 
                THEN 1 
                ELSE 0 
            END) OVER (PARTITION BY lwl.poem_id ORDER BY lwl."Row_ID") as group_id
        FROM line_with_lag lwl
    ),
    
    -- Step 3: Group nearby lines and add bonus
    grouped_line_matches AS (
        SELECT 
            lg.poem_id,
            lg.group_id,
            MAX(lg."Title_cleaned") as title_cleaned,
            MAX(lg.primary_score) as primary_score,
            MAX(lg.metadata_score) as metadata_score,
            MAX(lg.computed_match_type) as match_type,
            (array_agg(lg.tabs_array::text ORDER BY lg."Row_ID"))[1]::text[] as tabs_array,
            (array_agg(lg.full_data::text ORDER BY lg."Row_ID"))[1]::jsonb as full_data,
            array_agg(lg."Row_ID" ORDER BY lg."Row_ID") as row_ids,
            array_agg(lg."Poem_line_cleaned" ORDER BY lg."Row_ID") as lines,
            COUNT(*)::INT as line_count,
            CASE WHEN COUNT(*) > 1 THEN 10 ELSE 0 END as grouping_bonus
        FROM line_groups lg
        GROUP BY lg.poem_id, lg.group_id
    ),
    
    -- Step 4: Combine grouped line matches with non-line matches
    all_results AS (
        -- Grouped line matches
        SELECT 
            glm.poem_id,
            glm.title_cleaned,
            glm.primary_score,
            glm.metadata_score,
            glm.grouping_bonus,
            glm.match_type,
            glm.tabs_array::TEXT[],
            glm.row_ids[1] as row_id,
            glm.title_cleaned as display_title,
            glm.lines[1] as display_line,
            jsonb_build_object(
                'row_ids', glm.row_ids,
                'lines', glm.lines,
                'line_count', glm.line_count,
                'grouped', (glm.line_count > 1),
                'entities', glm.full_data->'entities',
                'places', glm.full_data->'places',
                'events', glm.full_data->'events',
                'religion', glm.full_data->'religion',
                'subjects', glm.full_data->'subjects',
                'animals', glm.full_data->'animals',
                'sentiments', glm.full_data->'sentiments',
                'meter', glm.full_data->'meter',
                'qafiya', glm.full_data->'qafiya',
                'rawy', glm.full_data->'rawy'
            ) as data
        FROM grouped_line_matches glm
        
        UNION ALL
        
        -- Non-line matches (title-only, metadata-only)
        SELECT 
            fs.poem_id,
            fs."Title_cleaned" as title_cleaned,
            fs.primary_score,
            fs.metadata_score,
            0 as grouping_bonus,
            fs.computed_match_type as match_type,
            fs.tabs_array::TEXT[],
            fs."Row_ID" as row_id,
            fs."Title_cleaned" as display_title,
            fs."Poem_line_cleaned" as display_line,
            jsonb_build_object(
                'row_ids', ARRAY[fs."Row_ID"],
                'lines', ARRAY[fs."Poem_line_cleaned"],
                'line_count', 1,
                'grouped', false,
                'entities', fs.full_data->'entities',
                'places', fs.full_data->'places',
                'events', fs.full_data->'events',
                'religion', fs.full_data->'religion',
                'subjects', fs.full_data->'subjects',
                'animals', fs.full_data->'animals',
                'sentiments', fs.full_data->'sentiments',
                'meter', fs.full_data->'meter',
                'qafiya', fs.full_data->'qafiya',
                'rawy', fs.full_data->'rawy'
            ) as data
        FROM final_scored fs
        WHERE fs.line_match = FALSE
    )
    
    SELECT 
        ROW_NUMBER() OVER (ORDER BY (ar.primary_score + ar.metadata_score + ar.grouping_bonus) DESC, ar.poem_id DESC)::INT as rank,
        (ar.primary_score + ar.metadata_score + ar.grouping_bonus)::INT as rank_score,
        ar.match_type::TEXT,
        ar.tabs_array::TEXT[] as matched_tabs,
        ar.poem_id::INT,
        ar.row_id::INT,
        ar.display_title::TEXT,
        ar.display_line::TEXT,
        ar.data::JSONB as data
    FROM all_results ar
    ORDER BY rank_score DESC, ar.poem_id DESC
    LIMIT result_limit;
END;
$$;

-- =====================================================
-- USAGE EXAMPLES
-- =====================================================

-- Test query
-- SELECT * FROM relevance_search('محمد بن زايد', 20);

-- To get JSON format for API:
-- SELECT json_build_object(
--     'meta', json_build_object(
--         'query', 'محمد بن زايد',
--         'total_results', COUNT(*),
--         'poem_titles', COUNT(DISTINCT CASE WHEN match_type IN ('exact', 'title') THEN poem_id END),
--         'poem_lines', COUNT(CASE WHEN match_type IN ('exact', 'line') THEN 1 END)
--     ),
--     'results', json_agg(json_build_object(
--         'rank', rank,
--         'rank_score', rank_score,
--         'match_type', match_type,
--         'matched_tabs', matched_tabs,
--         'poem_id', poem_id,
--         'row_id', row_id,
--         'display_title', display_title,
--         'display_line', display_line,
--         'data', data
--     ))
-- )
-- FROM relevance_search('محمد بن زايد', 50);