-- =====================================================
-- DIWAN HAMDAN - PRODUCTION READY SCHEMA
-- =====================================================

DROP TABLE IF EXISTS "Diwan_Hamdan" CASCADE;

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
                                            '[ًٌٍَُِّْ]', '', 'g'),   -- remove tashkeel
                                        '[أإآٱ]', 'ا', 'g'),        -- normalize alif
                                    '[ى]', 'ي', 'g'),               -- alif maqsura
                                '[ة]', 'ه', 'g'),                   -- taa marbuta
                            '[ؤ]', 'و', 'g'),
                        '[ئ]', 'ي', 'g'),
                    '[\u0640]', '', 'g'),                            -- tatweel
                '[\u200B\u200C\u200D\uFEFF]', '', 'g'),               -- zero width
            '\s+', ' ', 'g')                                          -- normalize spaces
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =====================================================
-- Main Table
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
    sentiments TEXT,

    -- JSON fields (direct JSONB storage)
    entities JSONB,
    events JSONB,
    religion JSONB,
    subjects JSONB,
    places JSONB,
    animals JSONB,


    ai_image_thumb TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- Basic Indexes
-- =====================================================
CREATE INDEX idx_diwan_poem_id 
ON "Diwan_Hamdan" (poem_id);

CREATE INDEX idx_diwan_row_id 
ON "Diwan_Hamdan" ("Row_ID");

-- =====================================================
-- JSONB GIN Indexes
-- =====================================================
CREATE INDEX idx_diwan_entities 
ON "Diwan_Hamdan" USING GIN (entities);

CREATE INDEX idx_diwan_places 
ON "Diwan_Hamdan" USING GIN (places);

CREATE INDEX idx_diwan_animals 
ON "Diwan_Hamdan" USING GIN (animals);

CREATE INDEX idx_diwan_events 
ON "Diwan_Hamdan" USING GIN (events);

CREATE INDEX idx_diwan_subjects 
ON "Diwan_Hamdan" USING GIN (subjects);

-- =====================================================
-- Trigram Search Indexes (Arabic fuzzy search)
-- =====================================================
CREATE INDEX idx_diwan_title_trgm 
ON "Diwan_Hamdan" 
USING GIN (normalize_arabic("Title_cleaned") gin_trgm_ops);

CREATE INDEX idx_diwan_content_trgm 
ON "Diwan_Hamdan" 
USING GIN (normalize_arabic("Poem_line_cleaned") gin_trgm_ops);

-- =====================================================
-- Row Level Security (Supabase / PostgREST)
-- =====================================================
ALTER TABLE "Diwan_Hamdan" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_select_all" 
ON "Diwan_Hamdan"
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
