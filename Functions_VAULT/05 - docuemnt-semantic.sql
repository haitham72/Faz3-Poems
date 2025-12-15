-- Documents table for semantic-hybrid search
DROP TABLE IF EXISTS document_semantic CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE document_semantic (
  id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  poem_id text NOT NULL,
  chunk_id text NOT NULL,
  "Title_raw" text NOT NULL,
  "Poem_line_raw" text NOT NULL,
  "Summary_chunked" text,
  "Title_cleaned" text NOT NULL,
  "Poem_line_cleaned" text NOT NULL,
  "Row_IDs_in_chunk" text,
  summary text,
  قافية text,
  البحر text,
  وصل text,
  حركة text,
  نوع text,
  شخص jsonb DEFAULT '[]'::jsonb,
  sentiments jsonb DEFAULT '[]'::jsonb,
  أماكن jsonb DEFAULT '[]'::jsonb,
  أحداث jsonb DEFAULT '[]'::jsonb,
  مواضيع jsonb DEFAULT '[]'::jsonb,
  تصنيف text,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  
  -- FTS configuration
  fts tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('simple', coalesce("Title_raw", '')), 'A') ||
    setweight(to_tsvector('arabic', coalesce("Title_raw", '')), 'A') ||
    setweight(to_tsvector('simple', coalesce("Poem_line_raw", '')), 'B') ||
    setweight(to_tsvector('arabic', coalesce("Poem_line_raw", '')), 'B') ||
    setweight(to_tsvector('simple', coalesce("Summary_chunked", '')), 'C') ||
    setweight(to_tsvector('arabic', coalesce("Summary_chunked", '')), 'C')
  ) STORED,
  
  embedding vector(1536)
);

-- Indexes
CREATE INDEX document_semantic_fts_idx ON document_semantic USING gin(fts);
CREATE INDEX document_semantic_embedding_idx ON document_semantic USING hnsw (embedding vector_ip_ops);
CREATE INDEX document_semantic_poem_id_idx ON document_semantic(poem_id);
CREATE INDEX document_semantic_title_trgm_idx ON document_semantic USING gin("Title_raw" gin_trgm_ops);
CREATE INDEX document_semantic_title_cleaned_trgm_idx ON document_semantic USING gin("Title_cleaned" gin_trgm_ops);
CREATE INDEX document_semantic_poem_line_trgm_idx ON document_semantic USING gin("Poem_line_raw" gin_trgm_ops);
CREATE INDEX document_semantic_poem_line_cleaned_trgm_idx ON document_semantic USING gin("Poem_line_cleaned" gin_trgm_ops);
CREATE INDEX document_semantic_shaks_idx ON document_semantic USING gin(شخص);
CREATE INDEX document_semantic_sentiments_idx ON document_semantic USING gin(sentiments);
CREATE INDEX document_semantic_amakin_idx ON document_semantic USING gin(أماكن);
CREATE INDEX document_semantic_ahdath_idx ON document_semantic USING gin(أحداث);
CREATE INDEX document_semantic_mawadi3_idx ON document_semantic USING gin(مواضيع);