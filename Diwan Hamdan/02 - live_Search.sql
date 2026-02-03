-- =====================================================
-- INDUSTRY STANDARD LIVE SEARCH
-- Priority: Title+Line > Title > Line
-- =====================================================

DROP FUNCTION IF EXISTS live_search(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION live_search(
    search_query TEXT,
    result_limit INT DEFAULT 5
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    ai_image_thumb TEXT,
    match_type TEXT
)
LANGUAGE plpgsql
AS $$

-- Search query
DECLARE
    q TEXT;
BEGIN
    q := trim(normalize_arabic(search_query));
    
    IF char_length(q) < 2 THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        d.poem_id,
        d."Row_ID",
        d."Title_cleaned",
        d."ai_image_thumb",
        d."Poem_line_cleaned",
        CASE 
            WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
             AND d."Poem_line_cleaned" ILIKE '%' || q || '%' 
            THEN 'both'
            WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
            THEN 'title'
            ELSE 'line'
        END as match_type
    FROM "Diwan_Hamdan" d
    WHERE 
        d."Poem_line_cleaned" ILIKE '%' || q || '%' OR
        d."Title_cleaned" ILIKE '%' || q || '%'
    ORDER BY
        -- Priority 1: Both title AND line match (highest)
        CASE 
            WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
             AND d."Poem_line_cleaned" ILIKE '%' || q || '%' 
            THEN 1
            -- Priority 2: Title only
            WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
            THEN 2
            -- Priority 3: Line only (lowest)
            ELSE 3
        END,
        -- Secondary sort: prefer prefix matches
        CASE 
            WHEN d."Poem_line_cleaned" ILIKE q || '%' THEN 1
            WHEN d."Title_cleaned" ILIKE q || '%' THEN 2
            ELSE 3
        END,
        d.poem_id DESC
    LIMIT result_limit;
END;
$$;


-- ## query examples

--  Basic live search (uses default limit = 5)
-- SELECT *
-- FROM live_search('حب');

-- --  Live search with a custom result limit
-- SELECT *
-- FROM live_search('وطن', 10);

-- -- Schema-qualified call (for our own system in production)
-- SELECT *
-- FROM public.live_search('سلام', 7);

-- -- Search and filter by match type (e.g., title-only matches)
-- SELECT *
-- FROM live_search('غزل', 5)
-- WHERE match_type = 'title';

-- --   Live search with ordering applied outside the function
-- SELECT *
-- FROM live_search('قلب', 8)
-- ORDER BY poem_id ASC;

-- -- Full Query Example:
-- SELECT poem_id, title_cleaned, poem_line_cleaned
-- FROM live_search('عشق', 5);
