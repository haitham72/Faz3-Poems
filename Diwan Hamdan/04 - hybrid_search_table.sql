DROP TABLE IF EXISTS documents CASCADE;

-- Extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- NORMALIZE FUNCTION 
CREATE OR REPLACE FUNCTION normalize_arabic(text_input TEXT)
RETURNS TEXT AS $$
BEGIN
    IF text_input IS NULL THEN RETURN ''; END IF;
    RETURN trim(regexp_replace(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(text_input,
                                        '[ًٌٍَُِّْ]', '', 'g'),
                                    '[أإآٱ]', 'ا', 'g'),
                                '[ى]', 'ي', 'g'),
                            '[ة]', 'ه', 'g'),
                        '[ؤ]', 'و', 'g'),
                    '[ئ]', 'ي', 'g'),
                '[\u0640]', '', 'g'),
            '[\u200B\u200C\u200D\uFEFF]', '', 'g'),
        '\s+', ' ', 'g'));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- COMMON PARTICLES FILTER 
CREATE OR REPLACE FUNCTION is_common_particle(word TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN normalize_arabic(word) = ANY(ARRAY[
        'في', 'من', 'على', 'إلى', 'عن', 'مع', 'كل', 'هذا', 'ذلك',
        'التي', 'الذي', 'أن', 'أو', 'لا', 'ما', 'إذا', 'هل', 'قد',
        'لم', 'لن', 'كان', 'يكون', 'بن', 'ابن', 'ال'
    ]);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- DOCUMENTS TABLE 
CREATE TABLE documents (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    
    -- Main searchable content (combined text)
    content TEXT,
    
    -- Full-text search vector
    fts tsvector GENERATED ALWAYS AS (
        to_tsvector('arabic', content)
    ) STORED,
    
    -- Vector embedding (1536 for OpenAI text-embedding-3-small)
    embedding vector(1536),
    
    -- ALL other data in JSONB metadata
    metadata JSONB
);

-- INDEXES
-- FTS index (Supabase pattern)
CREATE INDEX ON documents USING GIN (fts);

-- Vector index (HNSW for fast ANN search)
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);

-- JSONB metadata GIN index (supports all JSONB queries)
CREATE INDEX ON documents USING GIN (metadata);

-- Specific JSONB path indexes for common queries
CREATE INDEX ON documents ((metadata->>'poem_id'));
CREATE INDEX ON documents ((metadata->>'chunk_id'));

-- Trigram on content for fuzzy matching
CREATE INDEX idx_docs_content_trgm ON documents 
USING GIN (normalize_arabic(content) gin_trgm_ops);

-- Trigram on metadata for fuzzy metadata search
CREATE INDEX idx_docs_metadata_trgm ON documents 
USING GIN (normalize_arabic(metadata::text) gin_trgm_ops);

-- ANALYZE documents;

-- Fix nested JSON strings in metadata
UPDATE documents
SET metadata = jsonb_set(
    jsonb_set(
        jsonb_set(
            jsonb_set(
                jsonb_set(
                    jsonb_set(
                        jsonb_set(
                            metadata,
                            '{entities}',
                            CASE 
                                WHEN jsonb_typeof(metadata->'entities') = 'string' 
                                THEN (metadata->>'entities')::jsonb
                                ELSE metadata->'entities'
                            END
                        ),
                        '{places}',
                        CASE 
                            WHEN jsonb_typeof(metadata->'places') = 'string' 
                            THEN (metadata->>'places')::jsonb
                            ELSE metadata->'places'
                        END
                    ),
                    '{animals}',
                    CASE 
                        WHEN jsonb_typeof(metadata->'animals') = 'string' 
                        THEN (metadata->>'animals')::jsonb
                        ELSE metadata->'animals'
                    END
                ),
                '{events}',
                CASE 
                    WHEN jsonb_typeof(metadata->'events') = 'string' 
                    THEN (metadata->>'events')::jsonb
                    ELSE metadata->'events'
                END
            ),
            '{religion}',
            CASE 
                WHEN jsonb_typeof(metadata->'religion') = 'string' 
                THEN (metadata->>'religion')::jsonb
                ELSE metadata->'religion'
            END
        ),
        '{subjects}',
        CASE 
            WHEN jsonb_typeof(metadata->'subjects') = 'string' 
            THEN (metadata->>'subjects')::jsonb
            ELSE metadata->'subjects'
        END
    ),
    '{sentiments}',
    CASE 
        WHEN jsonb_typeof(metadata->'sentiments') = 'string' 
        THEN (metadata->>'sentiments')::jsonb
        ELSE metadata->'sentiments'
    END
)
WHERE 
    jsonb_typeof(metadata->'entities') = 'string' OR
    jsonb_typeof(metadata->'places') = 'string' OR
    jsonb_typeof(metadata->'animals') = 'string' OR
    jsonb_typeof(metadata->'events') = 'string' OR
    jsonb_typeof(metadata->'religion') = 'string' OR
    jsonb_typeof(metadata->'subjects') = 'string' OR
    jsonb_typeof(metadata->'sentiments') = 'string';