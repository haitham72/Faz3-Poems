-- =====================================================
-- CREATE EXACT_SEARCH_V2 TABLE FROM SCRATCH
-- =====================================================

DROP TABLE IF EXISTS "Exact_search_v2" CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE "Exact_search_v2" (
    id BIGSERIAL PRIMARY KEY,
    poem_id INTEGER NOT NULL,
    "Row_ID" INTEGER NOT NULL,
    "Title_raw" TEXT,
    "Poem_line_raw" TEXT,
    summary TEXT,
    "Title_cleaned" TEXT,
    "Poem_line_cleaned" TEXT,
    
    -- Poetry metadata
    qafiya TEXT,
    rawy TEXT,
    meter TEXT,
    wasl TEXT,
    haraka TEXT,
    category TEXT,
    
    -- JSONB columns
    entities JSONB,
    events JSONB,
    religion JSONB,
    subjects JSONB,
    places JSONB,
    animals JSONB,
    
    sentiments TEXT,
    
    -- Auto-generated tsvectors
    subjects_tsv tsvector,
    title_tsv tsvector GENERATED ALWAYS AS (to_tsvector('arabic', "Title_cleaned")) STORED,
    poem_line_tsv tsvector GENERATED ALWAYS AS (to_tsvector('arabic', "Poem_line_cleaned")) STORED,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- TRIGGER FOR subjects_tsv
-- =====================================================
CREATE OR REPLACE FUNCTION update_subjects_tsv()
RETURNS TRIGGER AS $$
BEGIN
    NEW.subjects_tsv := to_tsvector('arabic', 
        COALESCE(
            (SELECT string_agg(value::text, ' ') 
             FROM jsonb_array_elements_text(NEW.subjects)),
            ''
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE TRIGGER trigger_update_subjects_tsv
BEFORE INSERT OR UPDATE OF subjects
ON "Exact_search_v2"
FOR EACH ROW
EXECUTE FUNCTION update_subjects_tsv();

-- =====================================================
-- INDEXES
-- =====================================================

-- Basic indexes
CREATE INDEX idx_v2_poem_id ON "Exact_search_v2" (poem_id);
CREATE INDEX idx_v2_row_id ON "Exact_search_v2" ("Row_ID");

-- JSONB indexes
CREATE INDEX idx_v2_entities ON "Exact_search_v2" USING GIN (entities);
CREATE INDEX idx_v2_places ON "Exact_search_v2" USING GIN (places);
CREATE INDEX idx_v2_events ON "Exact_search_v2" USING GIN (events);
CREATE INDEX idx_v2_religion ON "Exact_search_v2" USING GIN (religion);
CREATE INDEX idx_v2_subjects ON "Exact_search_v2" USING GIN (subjects);
CREATE INDEX idx_v2_animals ON "Exact_search_v2" USING GIN (animals);

-- FTS indexes (CRITICAL for fast search)
CREATE INDEX idx_v2_subjects_fts ON "Exact_search_v2" USING GIN (subjects_tsv);
CREATE INDEX idx_v2_title_fts ON "Exact_search_v2" USING GIN (title_tsv);
CREATE INDEX idx_v2_poem_fts ON "Exact_search_v2" USING GIN (poem_line_tsv);

-- Trigram indexes for fuzzy metadata matching
CREATE INDEX idx_v2_entities_trgm 
ON "Exact_search_v2" USING GIN (normalize_arabic(entities::text) gin_trgm_ops);

CREATE INDEX idx_v2_places_trgm 
ON "Exact_search_v2" USING GIN (normalize_arabic(places::text) gin_trgm_ops);

CREATE INDEX idx_v2_events_trgm 
ON "Exact_search_v2" USING GIN (normalize_arabic(events::text) gin_trgm_ops);

CREATE INDEX idx_v2_religion_trgm 
ON "Exact_search_v2" USING GIN (normalize_arabic(religion::text) gin_trgm_ops);

CREATE INDEX idx_v2_subjects_trgm 
ON "Exact_search_v2" USING GIN (normalize_arabic(subjects::text) gin_trgm_ops);

CREATE INDEX idx_v2_animals_trgm 
ON "Exact_search_v2" USING GIN (normalize_arabic(animals::text) gin_trgm_ops);

CREATE INDEX idx_v2_sentiments_trgm 
ON "Exact_search_v2" USING GIN (normalize_arabic(sentiments) gin_trgm_ops);

-- =====================================================
-- DONE! 
-- =====================================================
-- Next: Upload your CSV data to this table