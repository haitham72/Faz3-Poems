-- =====================================================
-- COMPLETE TABLE CREATION - Run once from scratch
-- =====================================================

DROP TABLE IF EXISTS "Diwan_Hamdan" CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 1. Create normalize function
CREATE OR REPLACE FUNCTION normalize_arabic(text_input TEXT)
RETURNS TEXT AS $$
BEGIN
    IF text_input IS NULL THEN RETURN ''; END IF;
    RETURN regexp_replace(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(text_input,
                                '[ًٌٍَُِّْ]', '', 'g'),
                            '[أإآ]', 'ا', 'g'),
                        '[ى]', 'ي', 'g'),
                    '[ة]', 'ه', 'g'),
                '[ؤ]', 'و', 'g'),
            '[ئ]', 'ي', 'g'),
        '[\u0640]', '', 'g');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 2. Create table
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
    
    -- GENERATED for simple fields
    title_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('simple', COALESCE("Title_cleaned", '')), 'A') ||
        setweight(to_tsvector('arabic', COALESCE("Title_cleaned", '')), 'A')
    ) STORED,
    
    poem_line_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('simple', COALESCE("Poem_line_cleaned", '')), 'B') ||
        setweight(to_tsvector('arabic', COALESCE("Poem_line_cleaned", '')), 'B')
    ) STORED,
    
    -- TRIGGER for JSONB
    subjects_tsv tsvector,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Create trigger function
CREATE OR REPLACE FUNCTION update_subjects_tsv()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.subjects IS NOT NULL AND jsonb_typeof(NEW.subjects) = 'array' THEN
        NEW.subjects_tsv := to_tsvector('arabic', 
            (SELECT string_agg(value::text, ' ') 
             FROM jsonb_array_elements_text(NEW.subjects))
        );
    ELSE
        NEW.subjects_tsv := to_tsvector('arabic', '');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. Attach trigger
CREATE TRIGGER trigger_update_subjects_tsv
BEFORE INSERT OR UPDATE OF subjects
ON "Diwan_Hamdan"
FOR EACH ROW
EXECUTE FUNCTION update_subjects_tsv();

-- 5. Create indexes
CREATE INDEX idx_diwan_poem_id ON "Diwan_Hamdan" (poem_id);
CREATE INDEX idx_diwan_row_id ON "Diwan_Hamdan" ("Row_ID");
CREATE INDEX idx_diwan_entities ON "Diwan_Hamdan" USING GIN (entities);
CREATE INDEX idx_diwan_places ON "Diwan_Hamdan" USING GIN (places);
CREATE INDEX idx_diwan_events ON "Diwan_Hamdan" USING GIN (events);
CREATE INDEX idx_diwan_religion ON "Diwan_Hamdan" USING GIN (religion);
CREATE INDEX idx_diwan_subjects ON "Diwan_Hamdan" USING GIN (subjects);
CREATE INDEX idx_diwan_animals ON "Diwan_Hamdan" USING GIN (animals);
CREATE INDEX idx_diwan_subjects_fts ON "Diwan_Hamdan" USING GIN (subjects_tsv);
CREATE INDEX idx_diwan_title_fts ON "Diwan_Hamdan" USING GIN (title_tsv);
CREATE INDEX idx_diwan_poem_fts ON "Diwan_Hamdan" USING GIN (poem_line_tsv);
CREATE INDEX idx_diwan_entities_trgm ON "Diwan_Hamdan" USING GIN (normalize_arabic(entities::text) gin_trgm_ops);
CREATE INDEX idx_diwan_places_trgm ON "Diwan_Hamdan" USING GIN (normalize_arabic(places::text) gin_trgm_ops);
CREATE INDEX idx_diwan_events_trgm ON "Diwan_Hamdan" USING GIN (normalize_arabic(events::text) gin_trgm_ops);
CREATE INDEX idx_diwan_religion_trgm ON "Diwan_Hamdan" USING GIN (normalize_arabic(religion::text) gin_trgm_ops);
CREATE INDEX idx_diwan_subjects_trgm ON "Diwan_Hamdan" USING GIN (normalize_arabic(subjects::text) gin_trgm_ops);
CREATE INDEX idx_diwan_animals_trgm ON "Diwan_Hamdan" USING GIN (normalize_arabic(animals::text) gin_trgm_ops);
CREATE INDEX idx_diwan_sentiments_trgm ON "Diwan_Hamdan" USING GIN (normalize_arabic(sentiments) gin_trgm_ops);