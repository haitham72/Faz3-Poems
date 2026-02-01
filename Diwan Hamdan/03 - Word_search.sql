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
            
            -- METADATA MATCH DETECTION
            CASE 
                WHEN use_exact_match THEN d.entities::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.entities::text ILIKE '%' || w || '%')
            END as entities_match,
            
            CASE 
                WHEN use_exact_match THEN d.sentiments ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.sentiments ILIKE '%' || w || '%')
            END as sentiments_match,
            
            CASE 
                WHEN use_exact_match THEN d.events::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.events::text ILIKE '%' || w || '%')
            END as events_match,
            
            CASE 
                WHEN use_exact_match THEN d.religion::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.religion::text ILIKE '%' || w || '%')
            END as religion_match,
            
            CASE 
                WHEN use_exact_match THEN d.subjects::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.subjects::text ILIKE '%' || w || '%')
            END as subjects_match,
            
            CASE 
                WHEN use_exact_match THEN d.places::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.places::text ILIKE '%' || w || '%')
            END as places_match,
            
            CASE 
                WHEN use_exact_match THEN d.animals::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.animals::text ILIKE '%' || w || '%')
            END as animals_match,
            
            -- Store full data for client
            jsonb_build_object(
                'entities', d.entities,
                'places', d.places,
                'events', d.events,
                'religion', d.religion,
                'subjects', d.subjects,
                'animals', d.animals,
                'sentiments', d.sentiments,
                'meter', d.meter,
                'qafiya', d.qafiya,
                'rawy', d.rawy
            ) as full_data
            
        FROM "Diwan_Hamdan" d
        WHERE 
            -- Must match at least ONE field
            (use_exact_match AND (
                d."Title_cleaned" ILIKE '%' || q || '%' OR
                d."Poem_line_cleaned" ILIKE '%' || q || '%' OR
                d.entities::text ILIKE '%' || q || '%' OR
                d.sentiments ILIKE '%' || q || '%' OR
                d.events::text ILIKE '%' || q || '%' OR
                d.religion::text ILIKE '%' || q || '%' OR
                d.subjects::text ILIKE '%' || q || '%' OR
                d.places::text ILIKE '%' || q || '%' OR
                d.animals::text ILIKE '%' || q || '%'
            ))
            OR
            (NOT use_exact_match AND (
                (SELECT COUNT(*) >= 1 FROM unnest(words) w WHERE 
                    d."Title_cleaned" ILIKE '%' || w || '%' OR
                    d."Poem_line_cleaned" ILIKE '%' || w || '%' OR
                    d.entities::text ILIKE '%' || w || '%' OR
                    d.sentiments ILIKE '%' || w || '%' OR
                    d.events::text ILIKE '%' || w || '%' OR
                    d.religion::text ILIKE '%' || w || '%' OR
                    d.subjects::text ILIKE '%' || w || '%' OR
                    d.places::text ILIKE '%' || w || '%' OR
                    d.animals::text ILIKE '%' || w || '%'
                )
            ))
    ),
    
    final_scored AS (
        SELECT 
            sr.*,
            
            -- PRIMARY SCORE (30 max)
            CASE 
                WHEN sr.title_match AND sr.line_match THEN 30  -- exact: both
                WHEN sr.title_match THEN 25                     -- title only
                WHEN sr.line_match THEN 20                      -- line only
                ELSE 0
            END as primary_score,
            
            -- METADATA SCORE (10 per field, 70 max)
            (CASE WHEN sr.entities_match THEN 10 ELSE 0 END +
             CASE WHEN sr.sentiments_match THEN 10 ELSE 0 END +
             CASE WHEN sr.events_match THEN 10 ELSE 0 END +
             CASE WHEN sr.religion_match THEN 10 ELSE 0 END +
             CASE WHEN sr.subjects_match THEN 10 ELSE 0 END +
             CASE WHEN sr.places_match THEN 10 ELSE 0 END +
             CASE WHEN sr.animals_match THEN 10 ELSE 0 END) as metadata_score,
            
            -- MATCH TYPE
            CASE 
                WHEN sr.title_match AND sr.line_match THEN 'exact'
                WHEN sr.title_match THEN 'title'
                WHEN sr.line_match THEN 'line'
                ELSE 'metadata'
            END as computed_match_type,
            
            -- MATCHED TABS (for client-side filtering)
            ARRAY(
                SELECT tab FROM (
                    SELECT unnest(ARRAY[
                        CASE WHEN sr.title_match THEN 'title' END,
                        CASE WHEN sr.line_match THEN 'line' END,
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
    )
    
    SELECT 
        ROW_NUMBER() OVER (ORDER BY (fs.primary_score + fs.metadata_score) DESC, fs.poem_id DESC)::INT as rank,
        (fs.primary_score + fs.metadata_score)::INT as rank_score,
        fs.computed_match_type::TEXT as match_type,
        fs.tabs_array::TEXT[] as matched_tabs,
        fs.poem_id::INT,
        fs."Row_ID"::INT as row_id,
        fs."Title_cleaned"::TEXT as display_title,
        fs."Poem_line_cleaned"::TEXT as display_line,
        fs.full_data::JSONB as data
    FROM final_scored fs
    ORDER BY rank_score DESC, fs.poem_id DESC
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