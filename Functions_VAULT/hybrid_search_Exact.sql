-- =====================================================================
-- HYBRID SEARCH FINAL: With Arabic normalization for highlights
-- =====================================================================
-- Fixes:
-- 1. Strips diacritics/tatweel before matching
-- 2. Removes special chars (parentheses, etc)
-- 3. Normalizes both query and poem words for comparison
-- =====================================================================

DROP FUNCTION IF EXISTS hybrid_search_exact(text, integer, double precision, double precision, double precision, integer);

CREATE OR REPLACE FUNCTION hybrid_search_exact(
    query_text TEXT,
    match_count INT DEFAULT 10,
    sparse_weight FLOAT DEFAULT 0.35,
    pattern_weight FLOAT DEFAULT 0.55,
    trigram_weight FLOAT DEFAULT 0.10,
    rrf_k INT DEFAULT 60
)
RETURNS TABLE (
    id BIGINT,
    poem_raw TEXT,
    content TEXT,
    metadata JSONB,
    keyword_score FLOAT,
    pattern_score FLOAT,
    trigram_score FLOAT,
    keyword_rank BIGINT,
    pattern_rank BIGINT,
    trigram_rank BIGINT,
    final_score FLOAT,
    match_type TEXT,
    highlight_positions JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    query_tsquery tsquery;
    word_count INT;
    query_tokens TEXT[];
    cleaned_query TEXT;
BEGIN
    IF ABS((sparse_weight + pattern_weight + trigram_weight) - 1.0) > 0.001 THEN
        RAISE EXCEPTION 'Weights must sum to 1.0';
    END IF;

    -- Deduplicate query words
    WITH split_words AS (
        SELECT DISTINCT unnest(string_to_array(trim(query_text), ' ')) as word
    )
    SELECT string_agg(word, ' ')
    INTO cleaned_query
    FROM split_words
    WHERE word IS NOT NULL AND word != '';
    
    query_tokens := string_to_array(trim(cleaned_query), ' ');
    word_count := array_length(query_tokens, 1);

    BEGIN
        query_tsquery :=
            COALESCE(websearch_to_tsquery('simple', cleaned_query), to_tsquery('simple', '')) ||
            COALESCE(websearch_to_tsquery('arabic', cleaned_query), to_tsquery('simple', '')) ||
            COALESCE(websearch_to_tsquery('english', cleaned_query), to_tsquery('simple', ''));
    EXCEPTION WHEN OTHERS THEN
        query_tsquery :=
            plainto_tsquery('simple', cleaned_query) ||
            plainto_tsquery('arabic', cleaned_query) ||
            plainto_tsquery('english', cleaned_query);
    END;

    RETURN QUERY
    WITH keyword_search AS (
        SELECT
            d.id,
            ts_rank_cd(d.fts, query_tsquery)::float AS keyword_score,
            row_number() OVER(ORDER BY ts_rank_cd(d.fts, query_tsquery) DESC) AS rank_ix
        FROM documents d
        WHERE d.fts @@ query_tsquery
        ORDER BY keyword_score DESC
        LIMIT GREATEST(match_count * 5, 50)
    ),
    pattern_search AS (
        SELECT
            d.id,
            d.content,
            d.metadata,
            d.metadata->>'Poem_Raw' as poem_raw_text,
            split_part(d.content, '-----', 2) as chunk_text,
            COALESCE(d.metadata->>'poem', '') as poem_metadata,
            
            CASE
                WHEN word_count = 1 THEN
                    CASE
                        WHEN (d.metadata->>'people') ILIKE '%' || cleaned_query || '%' THEN 100.0
                        WHEN (d.metadata->>'places') ILIKE '%' || cleaned_query || '%' THEN 95.0
                        WHEN (d.metadata->>'poem_name') ILIKE '%' || cleaned_query || '%' THEN 90.0
                        WHEN split_part(d.content, '-----', 2) ILIKE '%' || cleaned_query || '%' THEN 85.0
                        WHEN (d.metadata->>'poem') ILIKE '%' || cleaned_query || '%' THEN 85.0
                        ELSE 0.0
                    END
                WHEN word_count > 1 THEN
                    CASE
                        WHEN NOT EXISTS (
                            SELECT 1 FROM unnest(query_tokens) AS token
                            WHERE (d.metadata->>'people') NOT ILIKE '%' || token || '%'
                        ) THEN 98.0
                        WHEN NOT EXISTS (
                            SELECT 1 FROM unnest(query_tokens) AS token
                            WHERE (d.metadata->>'places') NOT ILIKE '%' || token || '%'
                        ) THEN 92.0
                        WHEN NOT EXISTS (
                            SELECT 1 FROM unnest(query_tokens) AS token
                            WHERE (d.metadata->>'poem_name') NOT ILIKE '%' || token || '%'
                        ) THEN 87.0
                        WHEN NOT EXISTS (
                            SELECT 1 FROM unnest(query_tokens) AS token
                            WHERE split_part(d.content, '-----', 2) NOT ILIKE '%' || token || '%'
                        ) THEN 82.0
                        WHEN NOT EXISTS (
                            SELECT 1 FROM unnest(query_tokens) AS token
                            WHERE (d.metadata->>'poem') NOT ILIKE '%' || token || '%'
                        ) THEN 82.0
                        ELSE 0.0
                    END
                ELSE 0.0
            END::float AS pattern_score,
            
            CASE
                WHEN word_count = 1 AND (d.metadata->>'people') ILIKE '%' || cleaned_query || '%' THEN 'exact_person'
                WHEN word_count = 1 AND (d.metadata->>'places') ILIKE '%' || cleaned_query || '%' THEN 'exact_place'
                WHEN word_count = 1 AND (d.metadata->>'poem_name') ILIKE '%' || cleaned_query || '%' THEN 'exact_title'
                WHEN word_count = 1 AND split_part(d.content, '-----', 2) ILIKE '%' || cleaned_query || '%' THEN 'exact_chunk'
                WHEN word_count = 1 AND (d.metadata->>'poem') ILIKE '%' || cleaned_query || '%' THEN 'exact_poem'
                WHEN word_count > 1 THEN 'multi_match'
                ELSE 'no_exact_match'
            END AS match_type,
            
            -- ========================================
            -- IMPROVED HIGHLIGHT CALCULATION
            -- Search in poem_raw first, then title as fallback
            -- ========================================
            (
                WITH poem_matches AS (
                    SELECT 
                        word_idx - 1 as word_idx,
                        word as original_word
                    FROM (
                        SELECT 
                            unnest(string_to_array(d.metadata->>'Poem_Raw', ' ')) as word,
                            generate_series(1, array_length(string_to_array(d.metadata->>'Poem_Raw', ' '), 1)) as word_idx
                    ) words
                    WHERE EXISTS (
                        SELECT 1 FROM unnest(query_tokens) AS token
                        WHERE 
                            regexp_replace(
                                regexp_replace(lower(word), '[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED\u0640]', '', 'g'),
                                '[()،؛.!?«»"""''\-]', '', 'g'
                            ) 
                            ILIKE 
                            '%' || regexp_replace(
                                regexp_replace(lower(token), '[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED\u0640]', '', 'g'),
                                '[()،؛.!?«»"""''\-]', '', 'g'
                            ) || '%'
                    )
                ),
                title_matches AS (
                    SELECT DISTINCT
                        unnest(query_tokens) as original_word
                    WHERE EXISTS (
                        SELECT 1 FROM unnest(query_tokens) AS token
                        WHERE 
                            regexp_replace(
                                regexp_replace(lower(d.metadata->>'poem_name'), '[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED\u0640]', '', 'g'),
                                '[()،؛.!?«»"""''\-]', '', 'g'
                            ) 
                            ILIKE 
                            '%' || regexp_replace(
                                regexp_replace(lower(token), '[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED\u0640]', '', 'g'),
                                '[()،؛.!?«»"""''\-]', '', 'g'
                            ) || '%'
                    )
                ),
                all_matches AS (
                    SELECT word_idx, original_word FROM poem_matches
                    UNION ALL
                    SELECT -1 as word_idx, original_word FROM title_matches
                )
                SELECT jsonb_build_object(
                    'positions', (SELECT jsonb_agg(DISTINCT word_idx ORDER BY word_idx) FROM all_matches WHERE word_idx >= 0),
                    'tokens', (SELECT jsonb_agg(DISTINCT original_word ORDER BY original_word) FROM all_matches)
                )
            ) as highlight_positions,
            
            row_number() OVER (
                ORDER BY
                CASE
                    WHEN word_count = 1 AND (d.metadata->>'people') ILIKE '%' || cleaned_query || '%' THEN 100
                    WHEN word_count = 1 AND (d.metadata->>'places') ILIKE '%' || cleaned_query || '%' THEN 95
                    WHEN word_count = 1 AND (d.metadata->>'poem_name') ILIKE '%' || cleaned_query || '%' THEN 90
                    WHEN word_count = 1 AND split_part(d.content, '-----', 2) ILIKE '%' || cleaned_query || '%' THEN 85
                    WHEN word_count = 1 AND (d.metadata->>'poem') ILIKE '%' || cleaned_query || '%' THEN 85
                    WHEN word_count > 1 THEN 80
                    ELSE 0
                END DESC
            ) AS rank_ix
        FROM documents d
        WHERE 
            (
                (word_count = 1 AND (
                    (d.metadata->>'people') ILIKE '%' || cleaned_query || '%'
                    OR (d.metadata->>'places') ILIKE '%' || cleaned_query || '%'
                    OR (d.metadata->>'poem_name') ILIKE '%' || cleaned_query || '%'
                    OR split_part(d.content, '-----', 2) ILIKE '%' || cleaned_query || '%'
                    OR (d.metadata->>'poem') ILIKE '%' || cleaned_query || '%'
                ))
                OR
                (word_count > 1 AND NOT EXISTS (
                    SELECT 1 FROM unnest(query_tokens) AS token
                    WHERE split_part(d.content, '-----', 2) NOT ILIKE '%' || token || '%'
                       AND (d.metadata->>'people') NOT ILIKE '%' || token || '%'
                       AND (d.metadata->>'places') NOT ILIKE '%' || token || '%'
                       AND (d.metadata->>'poem_name') NOT ILIKE '%' || token || '%'
                       AND (d.metadata->>'poem') NOT ILIKE '%' || token || '%'
                ))
            )
        LIMIT 50
    ),
    trigram_search AS (
        SELECT DISTINCT ON (d.id)
            d.id,
            GREATEST(
                word_similarity(cleaned_query, split_part(d.content, '-----', 2)) * 2.0,
                word_similarity(cleaned_query, d.metadata->>'poem') * 2.0,
                word_similarity(cleaned_query, d.metadata->>'poem_name') * 3.0,
                word_similarity(cleaned_query, d.metadata->>'people') * 4.0,
                word_similarity(cleaned_query, d.metadata->>'places') * 4.0
            )::float AS trigram_score,
            row_number() OVER (
                ORDER BY 
                GREATEST(
                    word_similarity(cleaned_query, split_part(d.content, '-----', 2)),
                    word_similarity(cleaned_query, d.metadata->>'poem'),
                    word_similarity(cleaned_query, d.metadata->>'poem_name'),
                    word_similarity(cleaned_query, d.metadata->>'people')
                ) DESC
            ) AS rank_ix
        FROM documents d
        WHERE
            word_similarity(cleaned_query, split_part(d.content, '-----', 2)) > 0.4
            OR word_similarity(cleaned_query, d.metadata->>'poem') > 0.4
            OR word_similarity(cleaned_query, d.metadata->>'poem_name') > 0.4
            OR word_similarity(cleaned_query, d.metadata->>'people') > 0.4
            OR word_similarity(cleaned_query, d.metadata->>'places') > 0.4
        LIMIT 30
    )
    SELECT
        d.id,
        d.metadata->>'Poem_Raw' AS poem_raw,
        d.content,
        d.metadata,
        COALESCE(k.keyword_score, 0.0)::float AS keyword_score,
        COALESCE(p.pattern_score, 0.0)::float AS pattern_score,
        COALESCE(t.trigram_score, 0.0)::float AS trigram_score,
        k.rank_ix AS keyword_rank,
        p.rank_ix AS pattern_rank,
        t.rank_ix AS trigram_rank,
        (
            (sparse_weight * COALESCE(1.0 / (rrf_k + k.rank_ix), 0.0)) +
            (pattern_weight * COALESCE(1.0 / (rrf_k + p.rank_ix), 0.0)) +
            (trigram_weight * COALESCE(1.0 / (rrf_k + t.rank_ix), 0.0))
        )::float AS final_score,
        COALESCE(p.match_type, 
            CASE 
                WHEN t.trigram_score > 0.6 THEN 'fuzzy_typo'
                WHEN k.keyword_score > 0 THEN 'keyword_only'
                ELSE 'no_match'
            END
        ) AS match_type,
        COALESCE(p.highlight_positions, '{}'::jsonb) AS highlight_positions
    FROM pattern_search p
    LEFT JOIN keyword_search k ON k.id = p.id
    LEFT JOIN trigram_search t ON t.id = p.id
    JOIN documents d ON d.id = p.id
    WHERE p.pattern_score > 0
    ORDER BY final_score DESC
    LIMIT match_count;
END;
$$;

-- ========================================
-- NORMALIZATION APPLIED:
-- ========================================
-- Strips from both query and poem words:
-- 1. Diacritics: \u0610-\u061A\u064B-\u065F\u06D6-\u06ED
-- 2. Tatweel: \u0640
-- 3. Special chars: ()،؛.!?«»"""''-
--
-- Now "راشـــد" matches "راشد"
-- Now "(راشد" matches "راشد"
-- ========================================