-- =====================================================
-- AUTOCOMPLETE PREFIXES TABLE
-- Strips useless question words like "هل هناك قصائد عن"
-- =====================================================

CREATE TABLE IF NOT EXISTS autocomplete_prefixes (
    id SERIAL PRIMARY KEY,
    prefix TEXT NOT NULL,
    extract_after BOOLEAN DEFAULT true,
    boost_score INT DEFAULT 50
);

CREATE INDEX IF NOT EXISTS idx_prefix_length ON autocomplete_prefixes (length(prefix) DESC);

-- Insert common question prefixes to strip
INSERT INTO autocomplete_prefixes (prefix, extract_after, boost_score) VALUES
('هل هناك قصائد عن', true, 100),
('ابحث عن قصائد', true, 90),
('ابحث عن', true, 90),
('اريد قصائد عن', true, 80),
('قصائد عن', true, 90),
('ما هي القصائد التي تتحدث عن', true, 70),
('ما هي القصائد عن', true, 70),
('أبيات شعر عن', true, 60),
('شعر عن', true, 60)
ON CONFLICT DO NOTHING;


-- =====================================================
-- PREPROCESS QUERY FUNCTION
-- Removes prefixes before searching
-- =====================================================

CREATE OR REPLACE FUNCTION preprocess_query(user_query TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    q_normalized TEXT;
    prefix_record RECORD;
    cleaned_query TEXT;
BEGIN
    q_normalized := normalize_arabic(trim(user_query));
    cleaned_query := q_normalized;
    
    -- Check if query starts with known prefix
    FOR prefix_record IN 
        SELECT prefix, extract_after 
        FROM autocomplete_prefixes
        ORDER BY length(prefix) DESC  -- Match longest first
    LOOP
        IF q_normalized ILIKE normalize_arabic(prefix_record.prefix) || '%' AND prefix_record.extract_after THEN
            -- Remove prefix and return the actual search terms
            cleaned_query := trim(substring(q_normalized from length(normalize_arabic(prefix_record.prefix)) + 1));
            EXIT;  -- Found match, stop
        END IF;
    END LOOP;
    
    -- If cleaned query is empty, return original
    IF char_length(cleaned_query) < 2 THEN
        RETURN q_normalized;
    END IF;
    
    RETURN cleaned_query;
END;
$$;


-- =====================================================
-- AUTOCOMPLETE QUESTIONS FUNCTION
-- Returns matching question suggestions
-- =====================================================

DROP FUNCTION IF EXISTS autocomplete_questions(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION autocomplete_questions(
    prefix TEXT,
    limit_count INT DEFAULT 5
)
RETURNS TABLE(
    question TEXT,
    category TEXT,
    search_terms TEXT[],
    is_boosted BOOLEAN,
    popularity INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    q TEXT;
BEGIN
    q := normalize_arabic(trim(prefix));
    
    IF char_length(q) < 2 THEN
        -- Show top boosted questions when input is too short
        RETURN QUERY
        SELECT 
            qs.full_question,
            qs.category,
            qs.search_terms,
            qs.is_boosted,
            qs.popularity
        FROM question_suggestions qs
        WHERE qs.is_boosted = true
        ORDER BY qs.popularity DESC
        LIMIT limit_count;
    ELSE
        -- Return matching questions (boosted first)
        RETURN QUERY
        SELECT 
            qs.full_question,
            qs.category,
            qs.search_terms,
            qs.is_boosted,
            qs.popularity
        FROM question_suggestions qs
        WHERE normalize_arabic(qs.full_question) ILIKE q || '%'
        ORDER BY 
            qs.is_boosted DESC,
            qs.popularity DESC,
            length(qs.full_question) ASC  -- Shorter questions first
        LIMIT limit_count;
    END IF;
END;
$$;


-- =====================================================
-- TEST THE FUNCTIONS
-- =====================================================

/*
-- Test 1: Preprocess removes prefix
SELECT preprocess_query('هل هناك قصائد عن محمد بن زايد');
-- Should return: "محمد بن زايد"

-- Test 2: Autocomplete with prefix
SELECT * FROM autocomplete_questions('هل هناك', 5);
-- Should return 5 matching questions

-- Test 3: Autocomplete without prefix (shows top boosted)
SELECT * FROM autocomplete_questions('', 5);
-- Should return 5 top boosted questions
*/