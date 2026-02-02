-- =====================================================
-- SMART WORD SEARCH - Grouping & Relative Scoring
-- =====================================================
-- USAGE:
-- 1. Run SQL in Supabase
-- 2. Returns grouped results: title-only poems + line matches
-- 3. Scoring is relative (0-100%) based on result set
--
-- KEY FEATURES:
-- 1. Title-only matches: single row per poem (no repeated lines)
-- 2. Title+line matches: every matching line returned
-- 3. Line-only matches: only lines that match
-- 4. Metadata preserved for filtering
-- 5. Relative scoring: highest result = 100%, others scaled
-- =====================================================

DROP FUNCTION IF EXISTS smart_word_search(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION smart_word_search(
    search_query TEXT,
    result_limit INT DEFAULT 100
)
RETURNS TABLE(
    rank INT,
    rank_score INT,
    relative_score INT,  -- NEW: 0-100% relative to max
    match_type TEXT,
    matched_tabs TEXT[],
    poem_id INT,
    row_id INT,
    is_grouped BOOLEAN,  -- NEW: true for title-only matches
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
    query_length INT;
    is_long_query BOOLEAN;
    max_score INT;
BEGIN
    -- Normalize and prepare query
    q := trim(normalize_arabic(search_query));
    query_length := char_length(q);
    
    -- Protection: truncate queries over 100 chars
    IF query_length > 100 THEN
        q := substring(q, 1, 100);
        RAISE NOTICE 'Query truncated to 100 characters';
    END IF;
    
    IF query_length < 2 THEN
        RETURN;
    END IF;
    
    -- Split into words and remove stopwords
    words := regexp_split_to_array(q, '\s+');
    words := ARRAY(
        SELECT word FROM unnest(words) word 
        WHERE char_length(word) > 1 
        AND word NOT IN ('في', 'من', 'على', 'إلى', 'عن', 'مع', 'كل', 'هذا', 'ذلك', 'التي', 'الذي', 'أن', 'أو', 'لا', 'ما', 'إذا')
    );
    
    word_count := COALESCE(array_length(words, 1), 0);
    
    -- Protection: if 8+ words, take only first 5
    is_long_query := (word_count > 8);
    IF is_long_query THEN
        words := words[1:5];
        word_count := 5;
    END IF;
    
    RETURN QUERY
    WITH scored_results AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            
            -- Match detection logic (same as before)
            CASE 
                WHEN word_count >= 3 THEN
                    d."Title_cleaned" ILIKE '%' || q || '%'
                WHEN word_count = 2 THEN
                    (SELECT COUNT(*) = 2 FROM unnest(words) w 
                     WHERE d."Title_cleaned" ~ ('\y' || w || '\y') OR
                           d."Title_cleaned" ~ ('^' || w) OR
                           d."Title_cleaned" ~ (' ' || w))
                ELSE
                    (d."Title_cleaned" ~ ('\y' || q || '\y') OR
                     d."Title_cleaned" ~ ('^' || q) OR
                     d."Title_cleaned" ~ (' ' || q))
            END as title_match,
            
            CASE 
                WHEN word_count >= 3 THEN
                    d."Poem_line_cleaned" ILIKE '%' || q || '%'
                WHEN word_count = 2 THEN
                    (SELECT COUNT(*) = 2 FROM unnest(words) w 
                     WHERE d."Poem_line_cleaned" ~ ('\y' || w || '\y') OR
                           d."Poem_line_cleaned" ~ ('^' || w) OR
                           d."Poem_line_cleaned" ~ (' ' || w))
                ELSE
                    (d."Poem_line_cleaned" ~ ('\y' || q || '\y') OR
                     d."Poem_line_cleaned" ~ ('^' || q) OR
                     d."Poem_line_cleaned" ~ (' ' || q))
            END as line_match,
            
            CASE 
                WHEN word_count >= 2 THEN
                    (SELECT COUNT(DISTINCT w) FROM unnest(words) w 
                     WHERE d."Title_cleaned" ~ ('\y' || w || '\y') OR
                           d."Title_cleaned" ~ ('^' || w) OR
                           d."Title_cleaned" ~ (' ' || w) OR
                           d."Poem_line_cleaned" ~ ('\y' || w || '\y') OR
                           d."Poem_line_cleaned" ~ ('^' || w) OR
                           d."Poem_line_cleaned" ~ (' ' || w))
                ELSE word_count
            END as matched_word_count,
            
            CASE 
                WHEN word_count >= 3 AND (
                    d."Title_cleaned" ILIKE '%' || q || '%' OR
                    d."Poem_line_cleaned" ILIKE '%' || q || '%'
                ) THEN word_count
                WHEN word_count = 2 THEN
                    CASE 
                        WHEN d."Title_cleaned" ILIKE '%' || q || '%' OR
                             d."Poem_line_cleaned" ILIKE '%' || q || '%' 
                        THEN 2
                        ELSE 1
                    END
                ELSE 1
            END as longest_match_length,
            
            CASE 
                WHEN word_count = 1 AND (
                    d."Title_cleaned" ~ ('^' || q || '\y') OR
                    d."Poem_line_cleaned" ~ ('^' || q || '\y') OR
                    d."Title_cleaned" ~ (' ' || q || '\y') OR
                    d."Poem_line_cleaned" ~ (' ' || q || '\y')
                ) THEN TRUE
                ELSE FALSE
            END as has_prefix_match,
            
            -- Metadata matches (preserved for filtering)
            CASE 
                WHEN word_count >= 3 THEN d.entities::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.entities::text ILIKE '%' || w || '%')
            END as entities_match,
            
            CASE 
                WHEN word_count >= 3 THEN d.places::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.places::text ILIKE '%' || w || '%')
            END as places_match,
            
            CASE 
                WHEN word_count >= 3 THEN d.events::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.events::text ILIKE '%' || w || '%')
            END as events_match,
            
            CASE 
                WHEN word_count >= 3 THEN d.subjects::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.subjects::text ILIKE '%' || w || '%')
            END as subjects_match,
            
            CASE 
                WHEN word_count >= 3 THEN d.sentiments ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.sentiments ILIKE '%' || w || '%')
            END as sentiments_match,
            
            CASE 
                WHEN word_count >= 3 THEN d.religion::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.religion::text ILIKE '%' || w || '%')
            END as religion_match,
            
            CASE 
                WHEN word_count >= 3 THEN d.animals::text ILIKE '%' || q || '%'
                ELSE EXISTS(SELECT 1 FROM unnest(words) w WHERE d.animals::text ILIKE '%' || w || '%')
            END as animals_match,
            
            -- Store full data
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
            CASE
                WHEN word_count >= 3 THEN (
                    d."Title_cleaned" ILIKE '%' || q || '%' OR
                    d."Poem_line_cleaned" ILIKE '%' || q || '%' OR
                    d.entities::text ILIKE '%' || q || '%' OR
                    d.places::text ILIKE '%' || q || '%' OR
                    d.events::text ILIKE '%' || q || '%' OR
                    d.subjects::text ILIKE '%' || q || '%' OR
                    d.sentiments ILIKE '%' || q || '%' OR
                    d.religion::text ILIKE '%' || q || '%' OR
                    d.animals::text ILIKE '%' || q || '%'
                )
                WHEN word_count = 2 THEN
                    EXISTS(SELECT 1 FROM unnest(words) w WHERE
                        d."Title_cleaned" ~ ('\y' || w || '\y') OR
                        d."Title_cleaned" ~ ('^' || w) OR
                        d."Title_cleaned" ~ (' ' || w) OR
                        d."Poem_line_cleaned" ~ ('\y' || w || '\y') OR
                        d."Poem_line_cleaned" ~ ('^' || w) OR
                        d."Poem_line_cleaned" ~ (' ' || w) OR
                        d.entities::text ILIKE '%' || w || '%' OR
                        d.places::text ILIKE '%' || w || '%' OR
                        d.events::text ILIKE '%' || w || '%' OR
                        d.subjects::text ILIKE '%' || w || '%' OR
                        d.sentiments ILIKE '%' || w || '%' OR
                        d.religion::text ILIKE '%' || w || '%' OR
                        d.animals::text ILIKE '%' || w || '%'
                    )
                ELSE (
                    d."Title_cleaned" ~ ('\y' || q || '\y') OR
                    d."Title_cleaned" ~ ('^' || q) OR
                    d."Title_cleaned" ~ (' ' || q) OR
                    d."Poem_line_cleaned" ~ ('\y' || q || '\y') OR
                    d."Poem_line_cleaned" ~ ('^' || q) OR
                    d."Poem_line_cleaned" ~ (' ' || q) OR
                    d.entities::text ILIKE '%' || q || '%' OR
                    d.places::text ILIKE '%' || q || '%' OR
                    d.events::text ILIKE '%' || q || '%' OR
                    d.subjects::text ILIKE '%' || q || '%' OR
                    d.sentiments ILIKE '%' || q || '%' OR
                    d.religion::text ILIKE '%' || q || '%' OR
                    d.animals::text ILIKE '%' || q || '%'
                )
            END
    ),
    
    final_scored AS (
        SELECT 
            sr.*,
            
            -- Hierarchical scoring
            CASE WHEN sr.has_prefix_match THEN 30 ELSE 0 END as prefix_score,
            
            CASE 
                WHEN sr.title_match AND sr.line_match THEN 100
                WHEN sr.title_match THEN 80
                WHEN sr.line_match THEN 60
                ELSE 0
            END as primary_score,
            
            CASE 
                WHEN word_count >= 2 AND sr.matched_word_count = word_count THEN 40
                WHEN word_count >= 2 AND sr.matched_word_count >= (word_count - 1) THEN 25
                WHEN word_count >= 2 AND sr.matched_word_count >= 1 THEN 10
                ELSE 0
            END as word_completeness_score,
            
            CASE 
                WHEN sr.longest_match_length >= 3 THEN 30
                WHEN sr.longest_match_length = 2 THEN 20
                ELSE 0
            END as sequence_bonus,
            
            (CASE WHEN sr.entities_match THEN 5 ELSE 0 END +
             CASE WHEN sr.places_match THEN 5 ELSE 0 END +
             CASE WHEN sr.events_match THEN 5 ELSE 0 END +
             CASE WHEN sr.subjects_match THEN 5 ELSE 0 END +
             CASE WHEN sr.sentiments_match THEN 5 ELSE 0 END +
             CASE WHEN sr.religion_match THEN 3 ELSE 0 END +
             CASE WHEN sr.animals_match THEN 2 ELSE 0 END) as metadata_score,
            
            -- =====================================================
            -- SMART GROUPING LOGIC
            -- =====================================================
            -- Title-only: group by poem (is_grouped = true)
            -- Title+Line or Line-only: return all lines (is_grouped = false)
            
            CASE 
                WHEN sr.title_match AND sr.line_match THEN 'title+line'
                WHEN sr.title_match AND NOT sr.line_match THEN 'title-only'
                WHEN sr.line_match THEN 'line-only'
                ELSE 'metadata'
            END as computed_match_type,
            
            -- Mark if this should be grouped (title-only matches)
            CASE 
                WHEN sr.title_match AND NOT sr.line_match THEN TRUE
                ELSE FALSE
            END as is_title_only,
            
            -- Matched tabs (for filtering)
            ARRAY(
                SELECT tab FROM (
                    SELECT unnest(ARRAY[
                        CASE WHEN sr.has_prefix_match THEN 'prefix' END,
                        CASE WHEN sr.title_match THEN 'title' END,
                        CASE WHEN sr.line_match THEN 'line' END,
                        CASE WHEN sr.entities_match THEN 'entities' END,
                        CASE WHEN sr.places_match THEN 'places' END,
                        CASE WHEN sr.events_match THEN 'events' END,
                        CASE WHEN sr.subjects_match THEN 'subjects' END,
                        CASE WHEN sr.sentiments_match THEN 'sentiments' END,
                        CASE WHEN sr.religion_match THEN 'religion' END,
                        CASE WHEN sr.animals_match THEN 'animals' END
                    ]) as tab
                ) t WHERE tab IS NOT NULL
            ) as tabs_array
            
        FROM scored_results sr
    ),
    
    -- =====================================================
    -- GROUPING STEP: Deduplicate title-only matches
    -- =====================================================
    grouped_results AS (
        SELECT DISTINCT ON (
            CASE 
                WHEN fs.is_title_only THEN fs.poem_id 
                ELSE fs."Row_ID" 
            END
        )
            fs.poem_id,
            fs."Row_ID",
            fs."Title_cleaned",
            fs."Poem_line_cleaned",
            fs.is_title_only,
            (fs.prefix_score + fs.primary_score + fs.word_completeness_score + 
             fs.sequence_bonus + fs.metadata_score) as total_score,
            fs.computed_match_type,
            fs.tabs_array,
            fs.full_data
        FROM final_scored fs
        ORDER BY 
            CASE WHEN fs.is_title_only THEN fs.poem_id ELSE fs."Row_ID" END,
            (fs.prefix_score + fs.primary_score + fs.word_completeness_score + 
             fs.sequence_bonus + fs.metadata_score) DESC
    ),
    
    -- Calculate max score for relative scoring
    score_stats AS (
        SELECT MAX(total_score) as max_score
        FROM grouped_results
    ),
    
    -- Add relative scores
    ranked_results AS (
        SELECT 
            gr.*,
            -- Relative score: 0-100% based on max score
            CASE 
                WHEN ss.max_score > 0 THEN 
                    ROUND((gr.total_score::NUMERIC / ss.max_score::NUMERIC) * 100)::INT
                ELSE 0
            END as relative_score
        FROM grouped_results gr
        CROSS JOIN score_stats ss
    )
    
    SELECT 
        ROW_NUMBER() OVER (ORDER BY rr.total_score DESC, rr.poem_id DESC)::INT as rank,
        rr.total_score::INT as rank_score,
        rr.relative_score::INT as relative_score,
        rr.computed_match_type::TEXT as match_type,
        rr.tabs_array::TEXT[] as matched_tabs,
        rr.poem_id::INT,
        rr."Row_ID"::INT as row_id,
        rr.is_title_only::BOOLEAN as is_grouped,
        rr."Title_cleaned"::TEXT as display_title,
        rr."Poem_line_cleaned"::TEXT as display_line,
        rr.full_data::JSONB as data
    FROM ranked_results rr
    ORDER BY rr.total_score DESC, rr.poem_id DESC
    LIMIT result_limit;
END;
$$;

-- =====================================================
-- TESTING
-- =====================================================

-- Test title-only grouping
SELECT rank, rank_score, relative_score, match_type, is_grouped, poem_id, row_id,
       substring(display_title, 1, 40) as title_preview
FROM smart_word_search('الوطن', 20);
-- Expected: title-only matches show once per poem (is_grouped=true)
-- Expected: title+line matches show multiple times (is_grouped=false)

-- Test relative scoring
SELECT rank, rank_score, relative_score, match_type, poem_id
FROM smart_word_search('محمد بن زايد', 10);
-- Expected: highest score = 100%, others scaled proportionally

-- Test metadata preservation
SELECT rank, match_type, matched_tabs, 
       data->'entities' as entities,
       data->'places' as places
FROM smart_word_search('زايد', 10);
-- Expected: matched_tabs includes 'entities', 'places' for filtering