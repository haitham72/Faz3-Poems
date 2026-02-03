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