-- FINAL OPTIMIZED: hybrid_search_exact
-- Adjust weights to prioritize chunks that actually contain the query words

DROP FUNCTION IF EXISTS hybrid_search_exact(text, vector, integer, double precision, double precision, double precision, double precision, integer);

CREATE OR REPLACE FUNCTION hybrid_search_exact(
    query_text TEXT,
    query_embedding VECTOR(1536),
    match_count INT DEFAULT 10,
    -- ✅ FINAL WEIGHTS: Maximum precision for exact matching
    dense_weight FLOAT DEFAULT 0.10,    -- Reduced from 0.15 (minimal semantic influence)
    sparse_weight FLOAT DEFAULT 0.35,   -- Increased from 0.30 (keyword priority)
    pattern_weight FLOAT DEFAULT 0.40,  -- Increased from 0.35 (exact match priority)
    trigram_weight FLOAT DEFAULT 0.15,  -- Reduced from 0.20 (fuzzy as fallback only)
    rrf_k INT DEFAULT 60
)
RETURNS TABLE (
    id BIGINT,
    content TEXT,
    metadata JSONB,
    vector_score FLOAT,
    keyword_score FLOAT,
    pattern_score FLOAT,
    trigram_score FLOAT,
    vector_rank BIGINT,
    keyword_rank BIGINT,
    pattern_rank BIGINT,
    trigram_rank BIGINT,
    final_score FLOAT,
    match_type TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    query_tsquery tsquery;
    word_count INT;
BEGIN
    IF ABS((dense_weight + sparse_weight + pattern_weight + trigram_weight) - 1.0) > 0.001 THEN
        RAISE EXCEPTION 'Weights must sum to 1.0';
    END IF;

    word_count := array_length(string_to_array(trim(query_text), ' '), 1);

    BEGIN
        query_tsquery :=
            COALESCE(websearch_to_tsquery('simple', query_text), to_tsquery('simple', '')) ||
            COALESCE(websearch_to_tsquery('arabic', query_text), to_tsquery('simple', '')) ||
            COALESCE(websearch_to_tsquery('english', query_text), to_tsquery('simple', ''));
    EXCEPTION WHEN OTHERS THEN
        query_tsquery :=
            plainto_tsquery('simple', query_text) ||
            plainto_tsquery('arabic', query_text) ||
            plainto_tsquery('english', query_text);
    END;

    RETURN QUERY
    WITH semantic_search AS (
        SELECT
            d.id,
            (1 - (d.embedding <=> query_embedding))::float AS vector_score,
            row_number() OVER (ORDER BY d.embedding <=> query_embedding) AS rank_ix
        FROM documents d
        ORDER BY d.embedding <=> query_embedding
        LIMIT GREATEST(match_count * 5, 50)
    ),
    keyword_search AS (
        SELECT
            d.id,
            ts_rank_cd(d.fts, query_tsquery)::float AS keyword_score,
            row_number() OVER(ORDER BY ts_rank_cd(d.fts, query_tsquery) DESC) AS rank_ix
        FROM documents d
        WHERE d.fts @@ query_tsquery
        ORDER BY keyword_score DESC
        LIMIT GREATEST(match_count * 10, 100)
    ),
    pattern_search AS (
        SELECT
            d.id,
            CASE
                WHEN (d.metadata->>'people') ILIKE '%' || query_text || '%' THEN 10.0
                WHEN (d.metadata->>'places') ILIKE '%' || query_text || '%' THEN 9.0
                WHEN (d.metadata->>'poem_name') ILIKE '%' || query_text || '%' THEN 8.0
                WHEN split_part(d.content, '-----', 2) ILIKE '%' || query_text || '%' THEN 7.0
                WHEN word_count > 1 AND NOT EXISTS (
                    SELECT 1
                    FROM unnest(string_to_array(query_text, ' ')) AS token
                    WHERE split_part(d.content, '-----', 2) NOT ILIKE '%' || token || '%'
                ) THEN 5.0
                ELSE 0.0
            END::float AS pattern_score,
            
            CASE
                WHEN (d.metadata->>'people') ILIKE '%' || query_text || '%'
                     OR (d.metadata->>'places') ILIKE '%' || query_text || '%' 
                     OR (d.metadata->>'poem_name') ILIKE '%' || query_text || '%' THEN 'metadata_exact'
                WHEN split_part(d.content, '-----', 2) ILIKE '%' || query_text || '%' THEN 'chunk_exact'
                WHEN word_count > 1 AND NOT EXISTS (
                    SELECT 1
                    FROM unnest(string_to_array(query_text, ' ')) AS token
                    WHERE split_part(d.content, '-----', 2) NOT ILIKE '%' || token || '%'
                ) THEN 'multi_token_match'
                ELSE 'no_pattern_match'
            END AS match_type,
            
            row_number() OVER (
                ORDER BY
                CASE
                    WHEN (d.metadata->>'people') ILIKE '%' || query_text || '%' THEN 10
                    WHEN (d.metadata->>'places') ILIKE '%' || query_text || '%' THEN 9
                    WHEN (d.metadata->>'poem_name') ILIKE '%' || query_text || '%' THEN 8
                    WHEN split_part(d.content, '-----', 2) ILIKE '%' || query_text || '%' THEN 7
                    WHEN word_count > 1 AND NOT EXISTS (
                        SELECT 1
                        FROM unnest(string_to_array(query_text, ' ')) AS token
                        WHERE split_part(d.content, '-----', 2) NOT ILIKE '%' || token || '%'
                    ) THEN 5
                    ELSE 0
                END DESC
            ) AS rank_ix
        FROM documents d
        WHERE 
            (d.metadata->>'people') ILIKE '%' || query_text || '%'
            OR (d.metadata->>'places') ILIKE '%' || query_text || '%'
            OR (d.metadata->>'poem_name') ILIKE '%' || query_text || '%'
            OR split_part(d.content, '-----', 2) ILIKE '%' || query_text || '%'
            OR (
                word_count > 1 
                AND NOT EXISTS (
                    SELECT 1
                    FROM unnest(string_to_array(query_text, ' ')) AS token
                    WHERE split_part(d.content, '-----', 2) NOT ILIKE '%' || token || '%'
                )
            )
        LIMIT 50
    ),
    trigram_search AS (
        SELECT DISTINCT ON (d.id)
            d.id,
            GREATEST(
                word_similarity(query_text, split_part(d.content, '-----', 2)) * 3.0,
                word_similarity(query_text, d.metadata->>'poem_name') * 4.0,
                word_similarity(query_text, d.metadata->>'people') * 5.0,
                word_similarity(query_text, d.metadata->>'places') * 5.0,
                similarity(split_part(d.content, '-----', 2), query_text) * 1.0,
                similarity(d.metadata->>'poem_name', query_text) * 2.0,
                similarity(d.metadata->>'people', query_text) * 3.0,
                similarity(d.metadata->>'places', query_text) * 3.0
            )::float AS trigram_score,
            row_number() OVER (
                ORDER BY
                GREATEST(
                    word_similarity(query_text, split_part(d.content, '-----', 2)),
                    word_similarity(query_text, d.metadata->>'poem_name'),
                    word_similarity(query_text, d.metadata->>'people'),
                    word_similarity(query_text, d.metadata->>'places')
                ) DESC
            ) AS rank_ix
        FROM documents d
        WHERE
            EXISTS (
                SELECT 1
                FROM unnest(string_to_array(query_text, ' ')) AS token
                WHERE token != '' AND (
                    split_part(d.content, '-----', 2) LIKE '%' || token || '%'
                    OR d.metadata->>'poem_name' LIKE '%' || token || '%'
                    OR d.metadata->>'people' LIKE '%' || token || '%'
                    OR d.metadata->>'places' LIKE '%' || token || '%'
                )
            )
            OR word_similarity(query_text, split_part(d.content, '-----', 2)) > 0.3
            OR word_similarity(query_text, d.metadata->>'poem_name') > 0.3
            OR word_similarity(query_text, d.metadata->>'people') > 0.3
            OR word_similarity(query_text, d.metadata->>'places') > 0.3
        LIMIT GREATEST(match_count * 10, 100)
    )
    SELECT
        d.id,
        d.content,
        d.metadata,
        COALESCE(s.vector_score, 0.0)::float AS vector_score,
        COALESCE(k.keyword_score, 0.0)::float AS keyword_score,
        COALESCE(p.pattern_score, 0.0)::float AS pattern_score,
        COALESCE(t.trigram_score, 0.0)::float AS trigram_score,
        s.rank_ix AS vector_rank,
        k.rank_ix AS keyword_rank,
        p.rank_ix AS pattern_rank,
        t.rank_ix AS trigram_rank,
        (
            (dense_weight * COALESCE(1.0 / (rrf_k + s.rank_ix), 0.0)) +
            (sparse_weight * COALESCE(1.0 / (rrf_k + k.rank_ix), 0.0)) +
            (pattern_weight * COALESCE(1.0 / (rrf_k + p.rank_ix), 0.0)) +
            (trigram_weight * COALESCE(1.0 / (rrf_k + t.rank_ix), 0.0))
        )::float AS final_score,
        COALESCE(p.match_type, 
            CASE 
                WHEN t.trigram_score > 0.5 THEN 'trigram_fuzzy'
                WHEN k.keyword_score > 0 THEN 'keyword_match'
                ELSE 'semantic_only'
            END
        ) AS match_type
    FROM semantic_search s
    FULL OUTER JOIN keyword_search k ON s.id = k.id
    FULL OUTER JOIN pattern_search p ON COALESCE(s.id, k.id) = p.id
    FULL OUTER JOIN trigram_search t ON COALESCE(s.id, k.id, p.id) = t.id
    JOIN documents d ON d.id = COALESCE(s.id, k.id, p.id, t.id)
    ORDER BY final_score DESC
    LIMIT least(match_count, 30);
END;
$$;

-- ========================================
-- FINAL WEIGHTS SUMMARY:
-- ========================================
-- Pattern:  0.40 (exact matches dominate)
-- Keyword:  0.35 (FTS strong secondary)
-- Trigram:  0.15 (fuzzy fallback only)
-- Semantic: 0.10 (minimal influence)
--
-- This ensures chunks actually containing query words rank highest!