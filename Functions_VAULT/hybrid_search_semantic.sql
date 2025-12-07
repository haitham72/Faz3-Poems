-- OPTIONAL: Improved semantic_hybrid_search with token-based trigram
-- This is less critical than the hybrid_search_exact fix, but adds consistency

CREATE OR REPLACE FUNCTION semantic_hybrid_search(
    original_query TEXT,
    expanded_entities TEXT,
    sentiments TEXT,
    query_embedding VECTOR(1536),
    match_count INT DEFAULT 20
)
RETURNS TABLE (
    id BIGINT,
    content TEXT,
    metadata JSONB,
    vector_score FLOAT,
    entity_score FLOAT,
    sentiment_score FLOAT,
    trigram_score FLOAT,
    final_score FLOAT
)
LANGUAGE plpgsql
AS $$
DECLARE
    entity_array TEXT[];
    sentiment_array TEXT[];
    first_entity TEXT;
BEGIN
    entity_array := string_to_array(expanded_entities, ' ');
    sentiment_array := string_to_array(sentiments, ' ');
    first_entity := entity_array[1];

    RETURN QUERY
    WITH semantic_search AS (
        SELECT
            d.id,
            (1 - (d.embedding <=> query_embedding))::float AS vector_score
        FROM documents d
        ORDER BY d.embedding <=> query_embedding
        LIMIT 80
    ),

    entity_pattern AS (
        SELECT
            d.id,
            MAX(
                CASE
                    WHEN EXISTS (
                        SELECT 1 FROM unnest(entity_array) e
                        WHERE (d.metadata->>'people') ILIKE '%' || e || '%'
                    ) THEN 10.0

                    WHEN EXISTS (
                        SELECT 1 FROM unnest(entity_array) e
                        WHERE (d.metadata->>'poem_name') ILIKE '%' || e || '%'
                    ) THEN 8.0

                    WHEN split_part(d.content, '-----', 2) ILIKE '%' || first_entity || '%'
                    THEN 6.0

                    ELSE 0.0
                END
            )::float AS entity_score
        FROM documents d
        GROUP BY d.id
    ),

    sentiment_pattern AS (
        SELECT
            d.id,
            MAX(
                CASE
                    WHEN EXISTS (
                        SELECT 1 FROM unnest(sentiment_array) s
                        WHERE (d.metadata->>'sentiments') ILIKE '%' || s || '%'
                    ) THEN 7.0
                    ELSE 0.0
                END
            )::float AS sentiment_score
        FROM documents d
        GROUP BY d.id
    ),

    trigram_search AS (
        SELECT DISTINCT ON (d.id)
            d.id,
            GREATEST(
                word_similarity(original_query, split_part(d.content, '-----', 2)),
                word_similarity(original_query, d.metadata->>'poem_name')
            )::float AS trigram_score
        FROM documents d
        WHERE
            -- ✅ IMPROVED: Token-based OR high similarity
            EXISTS (
                SELECT 1
                FROM unnest(string_to_array(original_query, ' ')) AS token
                WHERE token != '' AND (
                    split_part(d.content, '-----', 2) LIKE '%' || token || '%'
                    OR d.metadata->>'poem_name' LIKE '%' || token || '%'
                )
            )
            OR word_similarity(original_query, split_part(d.content, '-----', 2)) > 0.2
            OR word_similarity(original_query, d.metadata->>'poem_name') > 0.2
        LIMIT 50
    )

    SELECT
        d.id,
        d.content,
        d.metadata,
        COALESCE(s.vector_score, 0.0)      AS vector_score,
        COALESCE(e.entity_score, 0.0)      AS entity_score,
        COALESCE(m.sentiment_score, 0.0)   AS sentiment_score,
        COALESCE(t.trigram_score, 0.0)     AS trigram_score,

        (
            (0.55 * COALESCE(s.vector_score, 0.0))   +
            (0.20 * COALESCE(e.entity_score, 0.0))   +
            (0.15 * COALESCE(m.sentiment_score, 0.0)) +
            (0.10 * COALESCE(t.trigram_score, 0.0))
        )::float AS final_score

    FROM semantic_search s
    FULL OUTER JOIN entity_pattern   e ON s.id = e.id
    FULL OUTER JOIN sentiment_pattern m ON COALESCE(s.id, e.id) = m.id
    FULL OUTER JOIN trigram_search   t ON COALESCE(s.id, e.id, m.id) = t.id
    JOIN documents d ON d.id = COALESCE(s.id, e.id, m.id, t.id)
    ORDER BY final_score DESC
    LIMIT match_count;

END;
$$;