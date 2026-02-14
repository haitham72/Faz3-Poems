-- =====================================================
-- COMPLETE LIVE SEARCH SYSTEM - CLEAN DEPLOYMENT
-- Run this entire file to reset everything
-- =====================================================

-- =====================================================
-- STEP 1: DROP EVERYTHING (clean slate)
-- =====================================================

DROP FUNCTION IF EXISTS live_search(TEXT, INT) CASCADE;
DROP FUNCTION IF EXISTS autocomplete_questions(TEXT, INT) CASCADE;
DROP FUNCTION IF EXISTS preprocess_query(TEXT) CASCADE;
DROP FUNCTION IF EXISTS track_suggestion_click(TEXT) CASCADE;
DROP TABLE IF EXISTS question_suggestions CASCADE;
DROP TABLE IF EXISTS autocomplete_prefixes CASCADE;


-- =====================================================
-- STEP 2: AUTOCOMPLETE PREFIXES TABLE
-- =====================================================

CREATE TABLE autocomplete_prefixes (
    id SERIAL PRIMARY KEY,
    prefix TEXT NOT NULL,
    extract_after BOOLEAN DEFAULT true,
    boost_score INT DEFAULT 50
);

CREATE INDEX idx_prefix_length ON autocomplete_prefixes (length(prefix) DESC);

INSERT INTO autocomplete_prefixes (prefix, extract_after, boost_score) VALUES
('هل هناك قصائد عن', true, 100),
('ابحث عن قصائد', true, 90),
('ابحث عن', true, 90),
('اريد قصائد عن', true, 80),
('قصائد عن', true, 90),
('ما هي القصائد التي تتحدث عن', true, 70),
('ما هي القصائد عن', true, 70),
('أبيات شعر عن', true, 60),
('شعر عن', true, 60);


-- =====================================================
-- STEP 3: QUESTION SUGGESTIONS TABLE (NO NORMALIZED COLUMN)
-- =====================================================

CREATE TABLE question_suggestions (
    id SERIAL PRIMARY KEY,
    full_question TEXT NOT NULL UNIQUE,
    category TEXT,
    search_terms TEXT[] NOT NULL,
    popularity INT DEFAULT 0,
    is_boosted BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_question_search ON question_suggestions 
USING btree (normalize_arabic(full_question) text_pattern_ops);

CREATE INDEX idx_question_popularity ON question_suggestions (popularity DESC);
CREATE INDEX idx_question_boosted ON question_suggestions (is_boosted, popularity DESC);


-- =====================================================
-- STEP 4: PREPROCESS QUERY FUNCTION
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
    
    FOR prefix_record IN 
        SELECT prefix, extract_after 
        FROM autocomplete_prefixes
        ORDER BY length(prefix) DESC
    LOOP
        IF q_normalized ILIKE normalize_arabic(prefix_record.prefix) || '%' AND prefix_record.extract_after THEN
            cleaned_query := trim(substring(q_normalized from length(normalize_arabic(prefix_record.prefix)) + 1));
            EXIT;
        END IF;
    END LOOP;
    
    IF char_length(cleaned_query) < 2 THEN
        RETURN q_normalized;
    END IF;
    
    RETURN cleaned_query;
END;
$$;


-- =====================================================
-- STEP 5: AUTOCOMPLETE QUESTIONS FUNCTION
-- =====================================================

CREATE OR REPLACE FUNCTION autocomplete_questions(prefix TEXT, limit_count INT DEFAULT 5)
RETURNS TABLE(question TEXT, category TEXT, search_terms TEXT[], is_boosted BOOLEAN, popularity INT)
LANGUAGE plpgsql
AS $$
DECLARE q TEXT;
BEGIN
    q := normalize_arabic(trim(prefix));
    
    IF char_length(q) < 2 THEN
        RETURN QUERY
        SELECT qs.full_question, qs.category, qs.search_terms, qs.is_boosted, qs.popularity
        FROM question_suggestions qs
        WHERE qs.is_boosted = true
        ORDER BY qs.popularity DESC
        LIMIT limit_count;
    ELSE
        RETURN QUERY
        SELECT qs.full_question, qs.category, qs.search_terms, qs.is_boosted, qs.popularity
        FROM question_suggestions qs
        WHERE normalize_arabic(qs.full_question) ILIKE q || '%'
        ORDER BY qs.is_boosted DESC, qs.popularity DESC, length(qs.full_question) ASC
        LIMIT limit_count;
    END IF;
END;
$$;


-- =====================================================
-- STEP 6: TRACK SUGGESTION CLICK FUNCTION
-- =====================================================

CREATE OR REPLACE FUNCTION track_suggestion_click(question_text TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE question_suggestions
    SET popularity = popularity + 1
    WHERE full_question = question_text;
    
    IF NOT FOUND THEN
        INSERT INTO question_suggestions (full_question, search_terms, popularity)
        VALUES (question_text, ARRAY[question_text], 1)
        ON CONFLICT (full_question) DO NOTHING;
    END IF;
END;
$$;


-- =====================================================
-- STEP 7: MAIN LIVE SEARCH FUNCTION
-- =====================================================

CREATE OR REPLACE FUNCTION live_search(search_query TEXT, result_limit INT DEFAULT 10)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    score NUMERIC,
    tokens_matched BIGINT,
    total_tokens BIGINT,
    matched_tokens TEXT[],
    is_suggestion BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    cleaned_query TEXT;
    tokens TEXT[];
    token_count INT;
    result_count INT;
    avg_score NUMERIC;
    should_show_suggestions BOOLEAN;
BEGIN
    cleaned_query := preprocess_query(search_query);
    tokens := string_to_array(cleaned_query, ' ');
    token_count := array_length(tokens, 1);
    
    WITH preview AS (
        SELECT COUNT(*), AVG(
            CASE WHEN d."Title_cleaned" ILIKE '%' || cleaned_query || '%' THEN 100 ELSE 0 END +
            CASE WHEN d."Poem_line_cleaned" ILIKE '%' || cleaned_query || '%' THEN 90 ELSE 0 END
        ) as avg_score
        FROM "Diwan_Hamdan" d
        WHERE EXISTS (
            SELECT 1 FROM unnest(tokens) t
            WHERE d."Title_cleaned" ILIKE '%' || t || '%' 
               OR d."Poem_line_cleaned" ILIKE '%' || t || '%'
        )
        LIMIT 20
    )
    SELECT p.count, p.avg_score
    INTO result_count, avg_score
    FROM preview p;
    
    should_show_suggestions := (
        result_count < 5 OR 
        avg_score < 50 OR 
        search_query ILIKE '%هل%' OR 
        search_query ILIKE '%قصائد%' OR
        search_query ILIKE '%ابحث%'
    );
    
    RETURN QUERY
    (
        SELECT 
            -1 as poem_id,
            -1 as row_id,
            qs.full_question as title_cleaned,
            NULL::TEXT as poem_line_cleaned,
            NULL::NUMERIC as score,
            NULL::BIGINT as tokens_matched,
            NULL::BIGINT as total_tokens,
            qs.search_terms as matched_tokens,
            true as is_suggestion
        FROM question_suggestions qs
        WHERE should_show_suggestions
          AND normalize_arabic(qs.full_question) ILIKE normalize_arabic(search_query) || '%'
        ORDER BY qs.is_boosted DESC, qs.popularity DESC
        LIMIT 3
    )
    
    UNION ALL
    
    (
        WITH 
        token_patterns AS (
            SELECT unnest(tokens) as token
        ),
        search_results AS (
            SELECT 
                d.poem_id,
                d."Row_ID",
                d."Title_cleaned",
                d."Poem_line_cleaned",
                
                (
                    SELECT COUNT(DISTINCT tp.token)
                    FROM token_patterns tp
                    WHERE 
                        d."Title_cleaned" ILIKE '%' || tp.token || '%' OR
                        d."Poem_line_cleaned" ILIKE '%' || tp.token || '%'
                ) AS tokens_matched_count,
                
                (
                    CASE WHEN d."Title_cleaned" ILIKE '%' || cleaned_query || '%' THEN 100 ELSE 0 END +
                    CASE WHEN d."Poem_line_cleaned" ILIKE '%' || cleaned_query || '%' THEN 90 ELSE 0 END +
                    (SELECT COUNT(DISTINCT tp.token)::NUMERIC * 20
                     FROM token_patterns tp
                     WHERE d."Title_cleaned" ILIKE '%' || tp.token || '%' 
                        OR d."Poem_line_cleaned" ILIKE '%' || tp.token || '%')
                ) AS calc_score,
                
                ARRAY(
                    SELECT DISTINCT tp.token
                    FROM token_patterns tp
                    WHERE 
                        d."Title_cleaned" ILIKE '%' || tp.token || '%' OR
                        d."Poem_line_cleaned" ILIKE '%' || tp.token || '%'
                ) AS matched_token_array
                
            FROM "Diwan_Hamdan" d
            WHERE 
                EXISTS (
                    SELECT 1 FROM token_patterns tp
                    WHERE 
                        d."Title_cleaned" ILIKE '%' || tp.token || '%' OR
                        d."Poem_line_cleaned" ILIKE '%' || tp.token || '%'
                )
        )
        SELECT 
            sr.poem_id,
            sr."Row_ID",
            sr."Title_cleaned",
            sr."Poem_line_cleaned",
            sr.calc_score,
            sr.tokens_matched_count::BIGINT,
            token_count::BIGINT,
            sr.matched_token_array,
            false as is_suggestion
        FROM search_results sr
        ORDER BY sr.calc_score DESC, sr.poem_id DESC
        LIMIT result_limit
    );
    
END;
$$;


-- =====================================================
-- DONE - System ready for question upserts
-- =====================================================

SELECT 'Live search system deployed successfully!' as status;