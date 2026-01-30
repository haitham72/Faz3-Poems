-- =====================================================
-- COMPLETE TABLE CREATION - FINAL CORRECTED VERSION
-- =====================================================

DROP TABLE IF EXISTS "Diwan_Hamdan" CASCADE;

-- Enable pg_trgm extension
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Set trigram similarity threshold (use current_database() instead of hardcoded name)
-- Note: This must be run AFTER connecting to your database
-- For Supabase: Run this separately in the SQL editor
-- ALTER DATABASE current_database() SET pg_trgm.similarity_threshold = 0.2;
-- =====================================================
-- 1. NORMALIZE ARABIC FUNCTION (improved)
-- =====================================================
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
                                        '[ًٌٍَُِّْ]', '', 'g'),  -- diacritics
                                    '[أإآٱ]', 'ا', 'g'),          -- alef variants (added ٱ)
                                '[ى]', 'ي', 'g'),                  -- alef maksura
                            '[ة]', 'ه', 'g'),                      -- taa marbouta
                        '[ؤ]', 'و', 'g'),                          -- hamza on waw
                    '[ئ]', 'ي', 'g'),                              -- hamza on ya
                '[\u0640]', '', 'g'),                              -- tatweel
            '[\u200B\u200C\u200D\uFEFF]', '', 'g'),               -- zero-width chars
        '\s+', ' ', 'g'));                                         -- normalize spaces (fixed: added trim)
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =====================================================
-- 2. HELPER FUNCTION TO EXTRACT JSONB ARRAY VALUES
-- =====================================================
CREATE OR REPLACE FUNCTION jsonb_array_to_text(jsonb_input JSONB, key TEXT DEFAULT NULL)
RETURNS TEXT AS $$
BEGIN
    IF jsonb_input IS NULL THEN RETURN ''; END IF;
    
    -- Handle empty arrays
    IF jsonb_typeof(jsonb_input) != 'array' THEN RETURN ''; END IF;
    IF jsonb_array_length(jsonb_input) = 0 THEN RETURN ''; END IF;
    
    IF key IS NOT NULL THEN
        -- Extract specific key from array of objects (e.g., "name" from entities)
        RETURN COALESCE(
            (SELECT string_agg(elem->>key, ' ') 
             FROM jsonb_array_elements(jsonb_input) elem
             WHERE elem->>key IS NOT NULL),
            ''
        );
    ELSE
        -- Extract plain array values (e.g., subjects array)
        RETURN COALESCE(
            (SELECT string_agg(value::text, ' ') 
             FROM jsonb_array_elements_text(jsonb_input)),
            ''
        );
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =====================================================
-- 3. CREATE TABLE
-- =====================================================
CREATE TABLE "Diwan_Hamdan" (
    id BIGSERIAL PRIMARY KEY,
    poem_id INTEGER NOT NULL,
    "Row_ID" INTEGER NOT NULL,
    "Title_raw" TEXT,
    "Poem_line_raw" TEXT,
    summary TEXT,
    "Title_cleaned" TEXT,
    "Poem_line_cleaned" TEXT,
    
    qafiya TEXT,
    rawy TEXT,
    meter TEXT,
    wasl TEXT,
    haraka TEXT,
    category TEXT,
    
    entities JSONB,
    events JSONB,
    religion JSONB,
    subjects JSONB,
    places JSONB,
    animals JSONB,
    sentiments TEXT,
    
    -- GENERATED tsvectors for text fields
    title_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('simple', COALESCE("Title_cleaned", '')), 'A') ||
        setweight(to_tsvector('arabic', COALESCE("Title_cleaned", '')), 'A')
    ) STORED,
    
    poem_line_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('simple', COALESCE("Poem_line_cleaned", '')), 'B') ||
        setweight(to_tsvector('arabic', COALESCE("Poem_line_cleaned", '')), 'B')
    ) STORED,
    
    -- GENERATED tsvector for subjects JSONB array
    subjects_tsv tsvector GENERATED ALWAYS AS (
        CASE 
            WHEN subjects IS NOT NULL AND jsonb_typeof(subjects) = 'array' AND jsonb_array_length(subjects) > 0 THEN
                to_tsvector('arabic', jsonb_array_to_text(subjects))
            ELSE to_tsvector('arabic', '')
        END
    ) STORED,
    
    -- GENERATED tsvector for entities JSONB array (extracts "name" field)
    entities_tsv tsvector GENERATED ALWAYS AS (
        CASE 
            WHEN entities IS NOT NULL AND jsonb_typeof(entities) = 'array' AND jsonb_array_length(entities) > 0 THEN
                to_tsvector('arabic', jsonb_array_to_text(entities, 'name'))
            ELSE to_tsvector('arabic', '')
        END
    ) STORED,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 4. CREATE INDEXES
-- =====================================================

-- Basic ID indexes
CREATE INDEX idx_diwan_poem_id ON "Diwan_Hamdan" (poem_id);
CREATE INDEX idx_diwan_row_id ON "Diwan_Hamdan" ("Row_ID");

-- JSONB containment indexes (for @> queries)
CREATE INDEX idx_diwan_entities ON "Diwan_Hamdan" USING GIN (entities);
CREATE INDEX idx_diwan_places ON "Diwan_Hamdan" USING GIN (places);
CREATE INDEX idx_diwan_events ON "Diwan_Hamdan" USING GIN (events);
CREATE INDEX idx_diwan_religion ON "Diwan_Hamdan" USING GIN (religion);
CREATE INDEX idx_diwan_subjects ON "Diwan_Hamdan" USING GIN (subjects);
CREATE INDEX idx_diwan_animals ON "Diwan_Hamdan" USING GIN (animals);

-- FTS indexes (for @@ queries)
CREATE INDEX idx_diwan_title_fts ON "Diwan_Hamdan" USING GIN (title_tsv);
CREATE INDEX idx_diwan_poem_fts ON "Diwan_Hamdan" USING GIN (poem_line_tsv);
CREATE INDEX idx_diwan_subjects_fts ON "Diwan_Hamdan" USING GIN (subjects_tsv);
CREATE INDEX idx_diwan_entities_fts ON "Diwan_Hamdan" USING GIN (entities_tsv);

-- TRIGRAM indexes on TEXT columns (for % similarity queries)
CREATE INDEX idx_diwan_title_trgm ON "Diwan_Hamdan" 
USING GIN (normalize_arabic("Title_cleaned") gin_trgm_ops);

CREATE INDEX idx_diwan_content_trgm ON "Diwan_Hamdan" 
USING GIN (normalize_arabic("Poem_line_cleaned") gin_trgm_ops);

CREATE INDEX idx_diwan_sentiments_trgm ON "Diwan_Hamdan" 
USING GIN (normalize_arabic(COALESCE(sentiments, '')) gin_trgm_ops);

-- PREFIX indexes (for ILIKE 'word%' queries)
CREATE INDEX idx_diwan_title_prefix ON "Diwan_Hamdan" 
("Title_cleaned" text_pattern_ops);

CREATE INDEX idx_diwan_content_prefix ON "Diwan_Hamdan" 
("Poem_line_cleaned" text_pattern_ops);


ALTER DATABASE "postgres" SET pg_trgm.similarity_threshold = 0.2;
-- =====================================================
-- 5. ANALYZE TABLE FOR QUERY PLANNER
-- =====================================================
ANALYZE "Diwan_Hamdan";

ALTER TABLE "Diwan_Hamdan" ENABLE ROW LEVEL SECURITY;

-- Create a policy that allows anon to SELECT everything
CREATE POLICY "anon_select_all" ON "Diwan_Hamdan"
    FOR SELECT
    TO anon
    USING (true);

-- Reload schema
NOTIFY pgrst, 'reload schema';
ALTER DATABASE postgres SET pgrst.db_max_rows = '5000';

-- Reload configuration (requires superuser)
SELECT pg_reload_conf();

-- Option 2: Check current setting
SHOW pgrst.db_max_rows;