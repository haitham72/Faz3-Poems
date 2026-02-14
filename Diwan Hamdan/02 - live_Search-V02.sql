-- =====================================================
-- INDUSTRY STANDARD LIVE SEARCH
-- Priority: Title+Line > Title (1 result only) > Line
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
    WITH ranked_results AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            CASE 
                WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
                 AND d."Poem_line_cleaned" ILIKE '%' || q || '%' 
                THEN 'both'
                WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
                THEN 'title'
                ELSE 'line'
            END as match_type,
            -- Add row number for each poem_id when match is title-only
            ROW_NUMBER() OVER (
                PARTITION BY 
                    d.poem_id,
                    CASE 
                        WHEN d."Title_cleaned" ILIKE '%' || q || '%' 
                         AND d."Poem_line_cleaned" NOT ILIKE '%' || q || '%' 
                        THEN 1  -- Title only matches get grouped
                        ELSE 0  -- Other matches don't get deduplicated
                    END
                ORDER BY d."Row_ID"
            ) as rn
        FROM "Diwan_Hamdan" d
        WHERE 
            d."Poem_line_cleaned" ILIKE '%' || q || '%' OR
            d."Title_cleaned" ILIKE '%' || q || '%'
    )
    SELECT 
        r.poem_id,
        r."Row_ID",
        r."Title_cleaned",
        r."Poem_line_cleaned",
        r.match_type
    FROM ranked_results r
    WHERE 
        -- Keep all 'both' and 'line' matches
        r.match_type IN ('both', 'line')
        -- For 'title' only matches, keep only the first row per poem
        OR (r.match_type = 'title' AND r.rn = 1)
    ORDER BY
        -- Priority 1: Both title AND line match (highest)
        CASE 
            WHEN r.match_type = 'both' THEN 1
            -- Priority 2: Title only (1 per poem)
            WHEN r.match_type = 'title' THEN 2
            -- Priority 3: Line only (lowest)
            ELSE 3
        END,
        -- Secondary sort: prefer prefix matches
        CASE 
            WHEN r."Poem_line_cleaned" ILIKE q || '%' THEN 1
            WHEN r."Title_cleaned" ILIKE q || '%' THEN 2
            ELSE 3
        END,
        r.poem_id DESC
    LIMIT result_limit;
END;
$$;


-- ## Query Examples

-- Basic live search (uses default limit = 5)
-- SELECT *
-- FROM live_search('حب');

-- Live search with a custom result limit
-- SELECT *
-- FROM live_search('وطن', 10);

-- Schema-qualified call (for production)
-- SELECT *
-- FROM public.live_search('سلام', 7);

-- Search and filter by match type (e.g., title-only matches)
-- SELECT *
-- FROM live_search('غزل', 50)
-- WHERE match_type = 'title';

-- Live search with ordering applied outside the function
-- SELECT *
-- FROM live_search('قلب', 8)
-- ORDER BY poem_id ASC;

-- Full Query Example:
-- SELECT poem_id, title_cleaned, poem_line_cleaned, match_type
-- FROM live_search('محمد', 20);

-- ## Behavior:
-- If a poem has title "محمد الدولة" and 10 lines, and the search is "محمد":
-- - If NONE of the 10 lines contain "محمد": Returns 1 result (title match only)
-- - If ANY line contains "محمد": Returns that line as 'both' match (not 'title')
-- - If searching for something in lines only: Returns all matching lines as 'line' type