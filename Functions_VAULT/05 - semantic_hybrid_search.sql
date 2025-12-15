-- Drop all versions
DROP FUNCTION IF EXISTS hybrid_search_semantic_v2(TEXT, INT, FLOAT, FLOAT, FLOAT);
DROP FUNCTION IF EXISTS hybrid_search_semantic_v2(TEXT, VECTOR, INT, FLOAT, FLOAT, FLOAT);

-- Create the correct version
CREATE OR REPLACE FUNCTION hybrid_search_semantic_v2(
  query_text TEXT,
  query_embedding VECTOR(1536),
  match_count INT DEFAULT 10,
  fts_weight FLOAT DEFAULT 1.0,
  semantic_weight FLOAT DEFAULT 1.0,
  fuzzy_weight FLOAT DEFAULT 0.5
)
RETURNS TABLE (
  id BIGINT,
  title_raw TEXT,
  poem_line_raw TEXT,
  poem_id TEXT,
  chunk_id TEXT,
  summary TEXT,
  metadata JSONB,
  match_type TEXT,
  fts_score FLOAT,
  semantic_score FLOAT,
  fuzzy_score FLOAT,
  final_score FLOAT
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH fts_search AS (
    SELECT 
      ds.id,
      ds.metadata->>'Title_raw' as title_raw,
      ds.metadata->>'poem_RAW' as poem_line_raw,
      (ds.metadata->>'poem_id')::text as poem_id,
      'N/A' as chunk_id,
      ds.metadata->>'summary' as summary,
      ds.metadata,
      ts_rank_cd(ds.fts, websearch_to_tsquery('arabic', query_text)) as rank
    FROM document_semantic ds
    WHERE ds.fts @@ websearch_to_tsquery('arabic', query_text)
  ),
  semantic_search AS (
    SELECT 
      ds.id,
      ds.metadata->>'Title_raw' as title_raw,
      ds.metadata->>'poem_RAW' as poem_line_raw,
      (ds.metadata->>'poem_id')::text as poem_id,
      'N/A' as chunk_id,
      ds.metadata->>'summary' as summary,
      ds.metadata,
      (1 - (ds.embedding <=> query_embedding))::float as similarity
    FROM document_semantic ds
    ORDER BY ds.embedding <=> query_embedding
    LIMIT match_count * 3
  ),
  fuzzy_search AS (
    SELECT 
      ds.id,
      ds.metadata->>'Title_raw' as title_raw,
      ds.metadata->>'poem_RAW' as poem_line_raw,
      (ds.metadata->>'poem_id')::text as poem_id,
      'N/A' as chunk_id,
      ds.metadata->>'summary' as summary,
      ds.metadata,
      GREATEST(
        similarity(COALESCE(ds.metadata->>'Title_raw', ''), query_text) * 3.0,
        similarity(COALESCE(ds.metadata->>'Title_cleaned', ''), query_text) * 2.5,
        similarity(COALESCE(ds.metadata->>'Poem_line_cleaned', ''), query_text) * 1.5,
        similarity(ds.content, query_text) * 1.0
      ) as fuzzy_sim
    FROM document_semantic ds
    WHERE 
      (ds.metadata->>'Title_raw') IS NOT NULL AND (ds.metadata->>'Title_raw')::text % query_text OR
      (ds.metadata->>'Title_cleaned') IS NOT NULL AND (ds.metadata->>'Title_cleaned')::text % query_text OR
      (ds.metadata->>'Poem_line_cleaned') IS NOT NULL AND (ds.metadata->>'Poem_line_cleaned')::text % query_text OR
      ds.content % query_text
  ),
  combined AS (
    SELECT 
      COALESCE(f.id, s.id, fz.id) as id,
      COALESCE(f.title_raw, s.title_raw, fz.title_raw) as title_raw,
      COALESCE(f.poem_line_raw, s.poem_line_raw, fz.poem_line_raw) as poem_line_raw,
      COALESCE(f.poem_id, s.poem_id, fz.poem_id) as poem_id,
      COALESCE(f.chunk_id, s.chunk_id, fz.chunk_id) as chunk_id,
      COALESCE(f.summary, s.summary, fz.summary) as summary,
      COALESCE(f.metadata, s.metadata, fz.metadata) as metadata,
      CASE 
        WHEN f.id IS NOT NULL AND s.id IS NOT NULL AND fz.id IS NOT NULL THEN 'fts+semantic+fuzzy'
        WHEN f.id IS NOT NULL AND s.id IS NOT NULL THEN 'fts+semantic'
        WHEN f.id IS NOT NULL AND fz.id IS NOT NULL THEN 'fts+fuzzy'
        WHEN s.id IS NOT NULL AND fz.id IS NOT NULL THEN 'semantic+fuzzy'
        WHEN f.id IS NOT NULL THEN 'fts'
        WHEN s.id IS NOT NULL THEN 'semantic'
        ELSE 'fuzzy'
      END as match_type,
      COALESCE(f.rank, 0.0)::FLOAT as fts_score,
      COALESCE(s.similarity, 0.0)::FLOAT as semantic_score,
      COALESCE(fz.fuzzy_sim, 0.0)::FLOAT as fuzzy_score
    FROM fts_search f
    FULL OUTER JOIN semantic_search s ON f.id = s.id
    FULL OUTER JOIN fuzzy_search fz ON COALESCE(f.id, s.id) = fz.id
  )
  SELECT 
    c.id,
    c.title_raw,
    c.poem_line_raw,
    c.poem_id,
    c.chunk_id,
    c.summary,
    c.metadata,
    c.match_type,
    c.fts_score,
    c.semantic_score,
    c.fuzzy_score,
    (c.fts_score * fts_weight + c.semantic_score * semantic_weight + c.fuzzy_score * fuzzy_weight)::FLOAT as final_score
  FROM combined c
  ORDER BY final_score DESC
  LIMIT match_count;
END;
$$;