-- =====================================================
-- DIWAN HAMDAN - PRODUCTION READY SCHEMA
-- =====================================================

DROP TABLE IF EXISTS "Diwan_Hamdan_staging" CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- =====================================================
-- Arabic Normalization Function
-- =====================================================
CREATE OR REPLACE FUNCTION normalize_arabic(text_input TEXT)
RETURNS TEXT AS $$
BEGIN
    IF text_input IS NULL THEN 
        RETURN ''; 
    END IF;

    RETURN trim(
        regexp_replace(
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
            '\s+', ' ', 'g')
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =====================================================
-- Main Table
-- =====================================================
CREATE TABLE "Diwan_Hamdan_staging" (
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
    sentiments TEXT,

    -- JSON fields as TEXT for staging
    entities TEXT,
    events TEXT,
    religion TEXT,
    subjects TEXT,
    places TEXT,
    animals TEXT,

    ai_image_thumb TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW()
);


-- Basic B-tree indexes
CREATE INDEX idx_diwan_staging_poem_id 
ON "Diwan_Hamdan_staging" (poem_id);

CREATE INDEX idx_diwan_staging_row_id 
ON "Diwan_Hamdan_staging" ("Row_ID");

-- Trigram indexes for text search
CREATE INDEX idx_diwan_staging_title_trgm 
ON "Diwan_Hamdan_staging" 
USING GIN (normalize_arabic("Title_cleaned") gin_trgm_ops);

CREATE INDEX idx_diwan_staging_content_trgm 
ON "Diwan_Hamdan_staging" 
USING GIN (normalize_arabic("Poem_line_cleaned") gin_trgm_ops);



-- =====================================================
-- Row Level Security (Supabase / PostgREST)
-- =====================================================
ALTER TABLE "Diwan_Hamdan_staging" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_select_all" 
ON "Diwan_Hamdan_staging"
FOR SELECT 
TO anon
USING (true);

-- =====================================================
-- PostgREST Performance Setting
-- =====================================================
ALTER ROLE authenticator 
SET pgrst.db_max_rows = 5000;

SELECT pg_reload_conf();
NOTIFY pgrst, 'reload schema';

-- Confirm setting
SELECT rolconfig 
FROM pg_roles 
WHERE rolname = 'authenticator';
