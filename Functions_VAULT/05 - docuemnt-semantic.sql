-- Standard Supabase documents table for semantic search
DROP TABLE IF EXISTS document_semantic CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE document_semantic (
  id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  content text NOT NULL,
  metadata jsonb DEFAULT '{}'::jsonb,
  embedding vector(1536),
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  
  -- FTS on content + metadata fields
  fts tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('simple', coalesce(content, '')), 'B') ||
    setweight(to_tsvector('arabic', coalesce(content, '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(metadata->>'Title_raw', '')), 'A') ||
    setweight(to_tsvector('arabic', coalesce(metadata->>'Title_raw', '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(metadata->>'Poem_line_raw', '')), 'B') ||
    setweight(to_tsvector('arabic', coalesce(metadata->>'Poem_line_raw', '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(metadata->>'summary', '')), 'C') ||
    setweight(to_tsvector('arabic', coalesce(metadata->>'summary', '')), 'C')
  ) STORED
);

-- Standard indexes
CREATE INDEX document_semantic_fts_idx ON document_semantic USING gin(fts);
CREATE INDEX document_semantic_embedding_idx ON document_semantic USING hnsw (embedding vector_ip_ops);
CREATE INDEX document_semantic_metadata_idx ON document_semantic USING gin(metadata);
CREATE INDEX document_semantic_content_trgm_idx ON document_semantic USING gin(content gin_trgm_ops);

-- Metadata field indexes for fast filtering
CREATE INDEX document_semantic_poem_id_idx ON document_semantic((metadata->>'poem_id'));
CREATE INDEX document_semantic_title_trgm_idx ON document_semantic USING gin((metadata->>'Title_raw') gin_trgm_ops);