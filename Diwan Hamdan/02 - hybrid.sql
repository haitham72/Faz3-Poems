-- =====================================================
-- CLEAN SEARCH FOR DIWAN_HAMDAN
-- FTS + Trigram hybrid, returns highlighting data
-- =====================================================

DROP FUNCTION IF EXISTS search_poems(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION search_poems(
    search_query TEXT,
    result_limit INT DEFAULT 20
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title TEXT,
    line TEXT,
    score NUMERIC,
    match_positions JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    q_norm TEXT;
    has_short_words BOOLEAN;
BEGIN
    q_norm := normalize_arabic(search_query);
    
    -- Check if query has short words (<= 2 chars)
    SELECT EXISTS (
        SELECT 1 FROM unnest(string_to_array(q_norm, ' ')) word
        WHERE length(word) > 0 AND length(word) <= 2
    ) INTO has_short_words;
    
    IF has_short_words THEN
        -- TRIGRAM (for "بو", "ام")
        RETURN QUERY
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_raw",
            d."Poem_line_raw",
            (word_similarity(q_norm, normalize_arabic(d."Poem_line_cleaned")) * 100)::NUMERIC,
            jsonb_build_object(
                'query', search_query,
                'method', 'trigram'
            ) as match_positions
        FROM "Diwan_Hamdan" d
        WHERE normalize_arabic(d."Poem_line_cleaned") ILIKE '%' || q_norm || '%'
        ORDER BY word_similarity(q_norm, normalize_arabic(d."Poem_line_cleaned")) DESC
        LIMIT result_limit;
    ELSE
        -- FTS (normal queries)
        RETURN QUERY
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_raw",
            d."Poem_line_raw",
            (ts_rank(d.poem_line_tsv, to_tsquery('arabic', search_query)) * 100)::NUMERIC,
            jsonb_build_object(
                'query', search_query,
                'method', 'fts'
            ) as match_positions
        FROM "Diwan_Hamdan" d
        WHERE d.poem_line_tsv @@ to_tsquery('arabic', search_query)
        ORDER BY ts_rank(d.poem_line_tsv, to_tsquery('arabic', search_query)) DESC
        LIMIT result_limit;
    END IF;
END;
$$;