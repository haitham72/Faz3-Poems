-- Documents table for semantic-hybrid search
DROP TABLE IF EXISTS document_semantic CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE document_semantic (
  id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  poem_id text NOT NULL,
  chunk_id text NOT NULL,
  title_raw text NOT NULL,
  poem_line_raw text NOT NULL,
  summary_chunked text,
  title_cleaned text NOT NULL,
  poem_line_cleaned text NOT NULL,
  row_ids_in_chunk text,
  summary text,
  qafiya text,
  bahr text,
  wasl text,
  haraka text,
  naw3 text,
  shaks jsonb DEFAULT '[]'::jsonb,
  sentiments jsonb DEFAULT '[]'::jsonb,
  amakin jsonb DEFAULT '[]'::jsonb,
  ahdath jsonb DEFAULT '[]'::jsonb,
  mawadi3 jsonb DEFAULT '[]'::jsonb,
  tasnif text,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  
  -- FTS configuration
  fts tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('simple', coalesce(title_raw, '')), 'A') ||
    setweight(to_tsvector('arabic', coalesce(title_raw, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(poem_line_raw, '')), 'B') ||
    setweight(to_tsvector('arabic', coalesce(poem_line_raw, '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(summary_chunked, '')), 'C') ||
    setweight(to_tsvector('arabic', coalesce(summary_chunked, '')), 'C')
  ) STORED,
  
  embedding vector(1536)
);

-- Indexes
CREATE INDEX document_semantic_fts_idx ON document_semantic USING gin(fts);
CREATE INDEX document_semantic_embedding_idx ON document_semantic USING hnsw (embedding vector_ip_ops);
CREATE INDEX document_semantic_poem_id_idx ON document_semantic(poem_id);
CREATE INDEX document_semantic_title_trgm_idx ON document_semantic USING gin(title_raw gin_trgm_ops);
CREATE INDEX document_semantic_title_cleaned_trgm_idx ON document_semantic USING gin(title_cleaned gin_trgm_ops);
CREATE INDEX document_semantic_poem_line_trgm_idx ON document_semantic USING gin(poem_line_raw gin_trgm_ops);
CREATE INDEX document_semantic_poem_line_cleaned_trgm_idx ON document_semantic USING gin(poem_line_cleaned gin_trgm_ops);
CREATE INDEX document_semantic_shaks_idx ON document_semantic USING gin(shaks);
CREATE INDEX document_semantic_sentiments_idx ON document_semantic USING gin(sentiments);
CREATE INDEX document_semantic_amakin_idx ON document_semantic USING gin(amakin);
CREATE INDEX document_semantic_ahdath_idx ON document_semantic USING gin(ahdath);
CREATE INDEX document_semantic_mawadi3_idx ON document_semantic USING gin(mawadi3);