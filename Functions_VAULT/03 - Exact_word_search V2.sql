-- ═══════════════════════════════════════════════════════════════
-- INTELLIGENT EXACT WORD SEARCH WITH METADATA WEIGHTING
-- ═══════════════════════════════════════════════════════════════
-- Drop old function if exists
DROP FUNCTION IF EXISTS public.smart_exact_search(text, integer, numeric);

-- Create new smart search function
CREATE OR REPLACE FUNCTION public.smart_exact_search(
    query_text TEXT,
    match_count INTEGER DEFAULT 20,
    score_threshold NUMERIC DEFAULT 0.3
)
RETURNS TABLE (
    poem_id TEXT,
    row_id TEXT,
    title_raw TEXT,
    poem_line_raw TEXT,
    summary TEXT,
    qafiya TEXT,
    bahr TEXT,
    naw3 TEXT,
    shaks TEXT,
    sentiments TEXT,
    amakin TEXT,
    ahdath TEXT,
    mawadi3 TEXT,
    tasnif TEXT,
    final_score NUMERIC,
    match_details JSONB,
    source_fields TEXT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    query_words TEXT[];
    word_count INTEGER;
BEGIN
    -- Normalize and split query into words
    query_words := string_to_array(
        regexp_replace(
            lower(trim(query_text)),
            '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
        ),
        ' '
    );
    
    -- Remove empty strings
    query_words := array_remove(query_words, '');
    word_count := array_length(query_words, 1);
    
    IF word_count IS NULL OR word_count = 0 THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH normalized_data AS (
        SELECT 
            p.poem_id,
            p."Row_ID" as row_id,
            p."Title_raw" as title_raw,
            p."Poem_line_raw" as poem_line_raw,
            p.summary,
            p."قافية" as qafiya,
            p."البحر" as bahr,
            p."نوع" as naw3,
            p."شخص" as shaks,
            p.sentiments,
            p."أماكن" as amakin,
            p."أحداث" as ahdath,
            p."مواضيع" as mawadi3,
            p."تصنيف" as tasnif,
            -- Normalize text fields for matching
            regexp_replace(
                lower(coalesce(p."Title_raw", '')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as title_norm,
            regexp_replace(
                lower(coalesce(p."Poem_line_raw", '')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as poem_norm,
            regexp_replace(
                lower(coalesce(p.summary, '')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as summary_norm,
            regexp_replace(
                lower(coalesce(p."شخص", '[]')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as shaks_norm,
            regexp_replace(
                lower(coalesce(p.sentiments, '[]')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as sentiments_norm,
            regexp_replace(
                lower(coalesce(p."أماكن", '[]')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as amakin_norm,
            regexp_replace(
                lower(coalesce(p."أحداث", '[]')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as ahdath_norm,
            regexp_replace(
                lower(coalesce(p."مواضيع", '[]')),
                '[^\u0600-\u06FFa-zA-Z0-9\s]', ' ', 'g'
            ) as mawadi3_norm
        FROM public."Poems_search" p
    ),
    scored_results AS (
        SELECT 
            nd.*,
            -- Calculate base score for each word with decreasing weight
            (
                -- Title matches (highest weight)
                SUM(
                    CASE 
                        WHEN nd.title_norm LIKE '%' || w.word || '%' THEN
                            100.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.4)
                        ELSE 0
                    END
                ) +
                
                -- Poem line matches (high weight)
                SUM(
                    CASE 
                        WHEN nd.poem_norm LIKE '%' || w.word || '%' THEN
                            60.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.4)
                        ELSE 0
                    END
                ) +
                
                -- Summary matches (medium-high weight)
                SUM(
                    CASE 
                        WHEN nd.summary_norm LIKE '%' || w.word || '%' THEN
                            40.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.4)
                        ELSE 0
                    END
                ) +
                
                -- Metadata matches (medium weight with AI expansion consideration)
                SUM(
                    CASE 
                        WHEN nd.shaks_norm LIKE '%' || w.word || '%' THEN
                            25.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.5)
                        ELSE 0
                    END
                ) +
                SUM(
                    CASE 
                        WHEN nd.amakin_norm LIKE '%' || w.word || '%' THEN
                            20.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.5)
                        ELSE 0
                    END
                ) +
                SUM(
                    CASE 
                        WHEN nd.ahdath_norm LIKE '%' || w.word || '%' THEN
                            20.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.5)
                        ELSE 0
                    END
                ) +
                SUM(
                    CASE 
                        WHEN nd.mawadi3_norm LIKE '%' || w.word || '%' THEN
                            15.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.5)
                        ELSE 0
                    END
                ) +
                SUM(
                    CASE 
                        WHEN nd.sentiments_norm LIKE '%' || w.word || '%' THEN
                            10.0 * (1.0 - (w.word_position - 1.0) / GREATEST(word_count, 1) * 0.5)
                        ELSE 0
                    END
                )
            ) as base_score,
            
            -- CRITICAL: Check if ANY word matched in visible text (title/poem/summary)
            (
                SUM(
                    CASE 
                        WHEN nd.title_norm LIKE '%' || w.word || '%' OR
                             nd.poem_norm LIKE '%' || w.word || '%' OR
                             nd.summary_norm LIKE '%' || w.word || '%'
                        THEN 1 
                        ELSE 0 
                    END
                ) > 0
            ) as has_visible_match,
            
            -- Track which fields matched
            array_remove(ARRAY[
                CASE WHEN nd.title_norm LIKE '%' || query_words[1] || '%' THEN 'title' END,
                CASE WHEN nd.poem_norm LIKE '%' || query_words[1] || '%' THEN 'poem' END,
                CASE WHEN nd.summary_norm LIKE '%' || query_words[1] || '%' THEN 'summary' END,
                CASE WHEN nd.shaks_norm LIKE '%' || query_words[1] || '%' THEN 'شخص' END,
                CASE WHEN nd.amakin_norm LIKE '%' || query_words[1] || '%' THEN 'أماكن' END,
                CASE WHEN nd.ahdath_norm LIKE '%' || query_words[1] || '%' THEN 'أحداث' END,
                CASE WHEN nd.mawadi3_norm LIKE '%' || query_words[1] || '%' THEN 'مواضيع' END,
                CASE WHEN nd.sentiments_norm LIKE '%' || query_words[1] || '%' THEN 'sentiments' END
            ], NULL) as matched_fields,
            
            -- NEW: Extract actual matched keywords from metadata
            CASE 
                WHEN nd.shaks_norm LIKE '%' || query_words[1] || '%' THEN nd.shaks
                WHEN nd.amakin_norm LIKE '%' || query_words[1] || '%' THEN nd.amakin
                WHEN nd.ahdath_norm LIKE '%' || query_words[1] || '%' THEN nd.ahdath
                WHEN nd.mawadi3_norm LIKE '%' || query_words[1] || '%' THEN nd.mawadi3
                WHEN nd.sentiments_norm LIKE '%' || query_words[1] || '%' THEN nd.sentiments
                ELSE NULL
            END as matched_metadata_value
            
        FROM normalized_data nd
        CROSS JOIN LATERAL (
            SELECT 
                unnest(query_words) as word,
                generate_series(1, word_count) as word_position
        ) w
        GROUP BY 
            nd.poem_id, nd.row_id, nd.title_raw, nd.poem_line_raw,
            nd.summary, nd.qafiya, nd.bahr, nd.naw3, nd.shaks,
            nd.sentiments, nd.amakin, nd.ahdath, nd.mawadi3, nd.tasnif,
            nd.title_norm, nd.poem_norm, nd.summary_norm,
            nd.shaks_norm, nd.sentiments_norm, nd.amakin_norm,
            nd.ahdath_norm, nd.mawadi3_norm
        HAVING 
            -- At least one word must match somewhere
            SUM(
                CASE WHEN 
                    nd.title_norm LIKE '%' || w.word || '%' OR
                    nd.poem_norm LIKE '%' || w.word || '%' OR
                    nd.summary_norm LIKE '%' || w.word || '%' OR
                    nd.shaks_norm LIKE '%' || w.word || '%' OR
                    nd.amakin_norm LIKE '%' || w.word || '%' OR
                    nd.ahdath_norm LIKE '%' || w.word || '%' OR
                    nd.mawadi3_norm LIKE '%' || w.word || '%' OR
                    nd.sentiments_norm LIKE '%' || w.word || '%'
                THEN 1 ELSE 0 END
            ) > 0
    ),
    final_scored AS (
        SELECT 
            *,
            -- CRITICAL BOOST: If matched in visible text, add massive bonus
            -- This ensures even a 25% fuzzy match in text beats 100% metadata match
            CASE 
                WHEN has_visible_match THEN base_score + 500.0  -- Huge boost for visible matches
                ELSE base_score  -- No boost for metadata-only
            END as calculated_score
        FROM scored_results
    )
    SELECT 
        sr.poem_id,
        sr.row_id,
        sr.title_raw,
        sr.poem_line_raw,
        sr.summary,
        sr.qafiya,
        sr.bahr,
        sr.naw3,
        sr.shaks,
        sr.sentiments,
        sr.amakin,
        sr.ahdath,
        sr.mawadi3,
        sr.tasnif,
        ROUND(sr.calculated_score::numeric, 2) as final_score,
        jsonb_build_object(
            'base_score', sr.base_score,
            'has_visible_match', sr.has_visible_match,
            'word_count', word_count,
            'matched_fields', sr.matched_fields,
            'matched_metadata', sr.matched_metadata_value
        ) as match_details,
        sr.matched_fields as source_fields,
        sr.matched_metadata_value as metadata_keyword
    FROM final_scored sr
    WHERE sr.calculated_score >= score_threshold
    ORDER BY sr.calculated_score DESC
    LIMIT match_count;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.smart_exact_search(text, integer, numeric) TO anon, authenticated;

-- ═══════════════════════════════════════════════════════════════
-- USAGE EXAMPLES:
-- ═══════════════════════════════════════════════════════════════

-- Example 1: Simple search
-- SELECT * FROM smart_exact_search('رمضان', 20, 0.3);

-- Example 2: AI-expanded query (first word weighted highest)
-- SELECT * FROM smart_exact_search('بن زايد محمد رئيس الدولة أبوظبي', 30, 0.4);

-- Example 3: Strict matching (higher threshold)
-- SELECT * FROM smart_exact_search('حب', 50, 0.5);

-- Example 4: Loose matching (lower threshold)
-- SELECT * FROM smart_exact_search('الوطن', 20, 0.2);