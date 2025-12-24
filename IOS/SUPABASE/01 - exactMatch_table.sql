DROP TABLE IF EXISTS "Exact_search" CASCADE;

-- Extensions FIRST
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE "Exact_search" (
    id BIGSERIAL PRIMARY KEY,
    poem_id INTEGER NOT NULL,
    "Row_ID" INTEGER NOT NULL,
    "Title_raw" TEXT,
    "Poem_line_raw" TEXT,
    summary TEXT,
    "Title_cleaned" TEXT,
    "Poem_line_cleaned" TEXT,
    "قافية" TEXT,
    "روي" TEXT,
    "البحر" TEXT,
    "وصل" TEXT,
    "حركة" TEXT,
    "شخص" JSONB,
    sentiments TEXT,
    "أحداث" JSONB,
    "دين" JSONB,
    "مواضيع" TEXT[],
    "أماكن" JSONB,
    "تصنيف" TEXT,
    
    -- Regular column, not GENERATED
    مواضيع_tsv tsvector,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Trigger to auto-update the tsvector column
CREATE OR REPLACE FUNCTION update_مواضيع_tsv()
RETURNS TRIGGER AS $$
BEGIN
    NEW.مواضيع_tsv := to_tsvector('arabic', COALESCE(array_to_string(NEW."مواضيع", ' '), ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE TRIGGER trigger_update_مواضيع_tsv
BEFORE INSERT OR UPDATE OF "مواضيع"
ON "Exact_search"
FOR EACH ROW
EXECUTE FUNCTION update_مواضيع_tsv();

-- Indexes
CREATE INDEX idx_exact_poem_id ON "Exact_search" (poem_id);
CREATE INDEX idx_exact_entities ON "Exact_search" USING GIN ("شخص");
CREATE INDEX idx_exact_places ON "Exact_search" USING GIN ("أماكن");
CREATE INDEX idx_exact_topics_fts ON "Exact_search" USING GIN (مواضيع_tsv);
CREATE INDEX idx_exact_fts_line ON "Exact_search" USING GIN (to_tsvector('arabic', "Poem_line_cleaned"));
CREATE INDEX idx_exact_trigram_line ON "Exact_search" USING GIN ("Poem_line_cleaned" gin_trgm_ops);
CREATE INDEX idx_exact_trigram_title ON "Exact_search" USING GIN ("Title_cleaned" gin_trgm_ops);