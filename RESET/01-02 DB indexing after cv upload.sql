-- =====================================================
-- STEP 1: ADD TSVECTOR COLUMNS (One-time setup)
-- =====================================================

ALTER TABLE "Exact_search" 
ADD COLUMN IF NOT EXISTS title_tsv tsvector 
GENERATED ALWAYS AS (to_tsvector('arabic', "Title_cleaned")) STORED;

ALTER TABLE "Exact_search" 
ADD COLUMN IF NOT EXISTS poem_line_tsv tsvector 
GENERATED ALWAYS AS (to_tsvector('arabic', "Poem_line_cleaned")) STORED;

-- =====================================================
-- STEP 2: CREATE INDEXES
-- =====================================================

-- FTS indexes for text search (PRIMARY - super fast)
CREATE INDEX IF NOT EXISTS idx_title_fts ON "Exact_search" USING GIN (title_tsv);
CREATE INDEX IF NOT EXISTS idx_poem_fts ON "Exact_search" USING GIN (poem_line_tsv);

-- Trigram indexes for metadata columns (SECONDARY - for metadata search)
CREATE INDEX IF NOT EXISTS idx_shakhsh_normalized_trgm 
ON "Exact_search" USING GIN (normalize_arabic("شخص"::text) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_amakin_normalized_trgm 
ON "Exact_search" USING GIN (normalize_arabic("أماكن"::text) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_ahdath_normalized_trgm 
ON "Exact_search" USING GIN (normalize_arabic("أحداث"::text) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_deen_normalized_trgm 
ON "Exact_search" USING GIN (normalize_arabic("دين"::text) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_mawadee_normalized_trgm 
ON "Exact_search" USING GIN (normalize_arabic("مواضيع"::text) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_sentiments_normalized_trgm 
ON "Exact_search" USING GIN (normalize_arabic(sentiments) gin_trgm_ops);

-- Standard indexes
CREATE INDEX IF NOT EXISTS idx_exact_poem_id ON "Exact_search" (poem_id);
CREATE INDEX IF NOT EXISTS idx_exact_row_id ON "Exact_search" ("Row_ID");