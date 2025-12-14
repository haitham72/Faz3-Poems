-- =====================================================================
-- SEMANTIC SEARCH: Vector similarity for meaning-based queries
-- =====================================================================
-- For queries like: "poems about unrequited love" or long questions
-- Searches in: summary (content before -----) using embeddings
-- =====================================================================

DROP FUNCTION IF EXISTS semantic_search(vector(1536), integer, double precision);

CREATE OR REPLACE FUNCTION semantic_search(
    query_embedding vector(1536),
    match_count INT DEFAULT 5,
    similarity_threshold FLOAT DEFAULT 0.7
)
RETURNS TABLE (
    id BIGINT,
    poem_raw TEXT,
    content TEXT,
    summary TEXT,
    chunk TEXT,
    metadata JSONB,
    similarity_score FLOAT,
    final_score FLOAT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        d.id,
        d.metadata->>'Poem_Raw' AS poem_raw,
        d.content,
        split_part(d.content, '-----', 1) AS summary,
        split_part(d.content, '-----', 2) AS chunk,
        d.metadata,
        (1 - (d.embedding <=> query_embedding))::float AS similarity_score,
        (1 - (d.embedding <=> query_embedding))::float AS final_score
    FROM documents d
    WHERE 1 - (d.embedding <=> query_embedding) > similarity_threshold
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- ========================================
-- USAGE:
-- ========================================
-- 1. Generate embedding in edge function (OpenAI)
-- 2. Call: SELECT * FROM semantic_search(embedding, 5, 0.7)
-- 3. Returns poems with semantic similarity > 0.7
-- ========================================