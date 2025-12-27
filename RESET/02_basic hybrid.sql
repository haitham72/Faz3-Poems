-- =====================================================
-- HYBRID SEARCH V3: COMPLETE FTS OPTIMIZED + GROUPED QUERIES
-- =====================================================

DROP FUNCTION IF EXISTS hybrid_search_v3_entity_aware CASCADE;
DROP FUNCTION IF EXISTS get_all_metadata_matches CASCADE;
DROP FUNCTION IF EXISTS process_single_query CASCADE;
DROP FUNCTION IF EXISTS get_text_matches CASCADE;
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

-- =====================================================
-- STEP 3: MAIN ORCHESTRATOR FUNCTION
-- =====================================================-- =====================================================
-- HYBRID SEARCH V3: COMPLETE FTS OPTIMIZED + GROUPED QUERIES
-- Performance: ~100-500ms (vs 2000ms before)
-- Supports: Single queries + Grouped queries (multiple per tag)
-- =====================================================

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

-- =====================================================
-- STEP 3: MAIN ORCHESTRATOR FUNCTION
-- =====================================================

DROP FUNCTION IF EXISTS hybrid_search_v3_entity_aware(JSONB, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION hybrid_search_v3_entity_aware(
    n8n_payload JSONB,
    total_limit INT DEFAULT 50,
    min_score NUMERIC DEFAULT 0.3
)
RETURNS TABLE(
    query_type TEXT,
    query_text TEXT,
    query_weight NUMERIC,
    entity_boost INT,
    tag TEXT,
    poems INT,
    lines INT,
    words INT,
    tags TEXT,
    results JSONB
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    exact_q JSONB;
    expanded_queries JSONB;
    individual_limit INT;
    
    current_query TEXT;
    current_queries TEXT[];  -- NEW: Support array of queries
    current_tag TEXT;
    current_confidence NUMERIC;
    
    q_norm TEXT;
    query_words TEXT[];
    meaningful_words TEXT[];
    current_word TEXT;
    
    result_row RECORD;
    temp_results JSONB := '[]'::JSONB;
    all_tags TEXT[] := ARRAY[]::TEXT[];
    total_poems INT := 0;
    total_lines INT := 0;
    total_words INT := 0;
BEGIN
    exact_q := n8n_payload->'N8N_query';
    expanded_queries := n8n_payload->'N8N_query'->'expanded_queries';
    individual_limit := COALESCE((n8n_payload->'N8N_query'->>'individual_Limit')::INT, 10);
    
    -- ==========================================
    -- PHASE 1: EXACT QUERY (user input verbatim)
    -- ==========================================
    current_query := exact_q->>'Exact_query';
    current_tag := exact_q->>'tag';
    current_confidence := COALESCE((exact_q->>'confidence_score')::NUMERIC, 100);
    
    IF current_query IS NOT NULL THEN
        q_norm := TRIM(normalize_arabic(current_query));
        query_words := string_to_array(trim(current_query), ' ');
        
        meaningful_words := ARRAY[]::TEXT[];
        FOREACH current_word IN ARRAY query_words
        LOOP
            IF NOT is_common_particle(current_word) 
               AND normalize_arabic(current_word) NOT IN ('بن', 'ابن', 'ال') 
            THEN
                meaningful_words := array_append(meaningful_words, current_word);
            END IF;
        END LOOP;
        
        IF array_length(meaningful_words, 1) IS NULL THEN
            meaningful_words := query_words;
        END IF;
        
        all_tags := array_append(all_tags, current_tag);
        
        FOR result_row IN (
            SELECT * FROM process_single_query(
                current_query, q_norm, meaningful_words,
                current_tag, current_confidence, individual_limit, min_score
            )
        ) LOOP
            temp_results := temp_results || jsonb_build_array(result_row.result_json);
            total_poems := total_poems + 1;
            total_lines := total_lines + 1;
            total_words := total_words + array_length(string_to_array(result_row.poem_line_raw, ' '), 1);
        END LOOP;
    END IF;
    
    -- ==========================================
    -- PHASE 2: EXPANDED QUERIES (with grouped support)
    -- ==========================================
    IF expanded_queries IS NOT NULL THEN
        FOR i IN 0..jsonb_array_length(expanded_queries)-1 LOOP
            current_tag := expanded_queries->i->>'tag';
            current_confidence := COALESCE((expanded_queries->i->>'confidence_score')::NUMERIC, 50);
            
            -- Check if using old format (single "query") or new format (array "queries")
            IF expanded_queries->i ? 'queries' THEN
                -- NEW FORMAT: Multiple queries grouped by tag
                current_queries := ARRAY(
                    SELECT jsonb_array_elements_text(expanded_queries->i->'queries')
                );
                
                IF array_length(current_queries, 1) IS NULL OR array_length(current_queries, 1) = 0 THEN
                    CONTINUE;
                END IF;
                
                -- Combine all queries with OR logic
                current_query := array_to_string(current_queries, ' OR ');
                
            ELSE
                -- OLD FORMAT: Single query per object (backwards compatible)
                current_query := expanded_queries->i->>'query';
                
                IF current_query IS NULL THEN
                    CONTINUE;
                END IF;
            END IF;
            
            q_norm := TRIM(normalize_arabic(current_query));
            query_words := string_to_array(trim(current_query), ' ');
            
            meaningful_words := ARRAY[]::TEXT[];
            FOREACH current_word IN ARRAY query_words
            LOOP
                IF NOT is_common_particle(current_word) 
                   AND normalize_arabic(current_word) NOT IN ('بن', 'ابن', 'ال', 'OR') 
                THEN
                    meaningful_words := array_append(meaningful_words, current_word);
                END IF;
            END LOOP;
            
            IF array_length(meaningful_words, 1) IS NULL THEN
                meaningful_words := query_words;
            END IF;
            
            all_tags := array_append(all_tags, current_tag);
            
            FOR result_row IN (
                SELECT * FROM process_single_query(
                    current_query, q_norm, meaningful_words,
                    current_tag, current_confidence, individual_limit, min_score
                )
            ) LOOP
                temp_results := temp_results || jsonb_build_array(result_row.result_json);
                total_poems := total_poems + 1;
                total_lines := total_lines + 1;
                total_words := total_words + array_length(string_to_array(result_row.poem_line_raw, ' '), 1);
            END LOOP;
        END LOOP;
    END IF;
    
    -- ==========================================
    -- PHASE 3: DEDUPLICATE & RETURN
    -- ==========================================
    RETURN QUERY
    SELECT 
        CASE WHEN exact_q IS NOT NULL THEN 'exact' ELSE 'expanded' END::TEXT,
        COALESCE(exact_q->>'Exact_query', 'N/A')::TEXT,
        current_confidence,
        10,
        array_to_string(all_tags, ', ')::TEXT,
        total_poems,
        total_lines,
        total_words,
        array_to_string(all_tags, ', ')::TEXT,
        (
            SELECT jsonb_agg(result ORDER BY (result->>'score')::NUMERIC DESC)
            FROM (
                SELECT DISTINCT ON ((result->>'poem_id')::INT) result
                FROM jsonb_array_elements(temp_results) result
                ORDER BY (result->>'poem_id')::INT, (result->>'score')::NUMERIC DESC
            ) deduped
            LIMIT total_limit
        );
END;
$$;

-- =====================================================
-- HELPER: Process Single Query
-- =====================================================

DROP FUNCTION IF EXISTS process_single_query(TEXT, TEXT, TEXT[], TEXT, NUMERIC, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION process_single_query(
    original_query TEXT,
    q_norm TEXT,
    meaningful_words TEXT[],
    tag TEXT,
    confidence NUMERIC,
    match_limit INT,
    min_score NUMERIC
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_raw TEXT,
    poem_line_raw TEXT,
    final_score NUMERIC,
    match_locations TEXT[],
    tag_out TEXT,
    result_json JSONB
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    WITH 
    text_matches AS (
        SELECT 
            tm.poem_id as tm_poem_id,
            tm.row_id as tm_row_id,
            tm.title_raw as tm_title_raw,
            tm.poem_line_raw as tm_poem_line_raw,
            tm.score as tm_score,
            tm.match_location as tm_match_location,
            tm.match_json as tm_match_json
        FROM get_text_matches(original_query, q_norm, meaningful_words, match_limit, min_score) tm
    ),
    
    all_metadata_matches AS (
        SELECT 
            mm.poem_id as mm_poem_id,
            mm.row_id as mm_row_id,
            mm.title_raw as mm_title_raw,
            mm.poem_line_raw as mm_poem_line_raw,
            mm.score as mm_score,
            mm.match_location as mm_match_location,
            mm.match_json as mm_match_json
        FROM get_all_metadata_matches(q_norm, meaningful_words, tag, match_limit, min_score) mm
    ),
    
    combined AS (
        SELECT 
            tm_poem_id as c_poem_id, 
            tm_row_id as c_row_id, 
            tm_title_raw as c_title_raw, 
            tm_poem_line_raw as c_poem_line_raw,
            tm_score as c_score, 
            tm_match_location as c_match_location, 
            tm_match_json as c_match_json,
            FALSE as is_metadata
        FROM text_matches
        
        UNION ALL
        
        SELECT 
            mm_poem_id as c_poem_id, 
            mm_row_id as c_row_id, 
            mm_title_raw as c_title_raw, 
            mm_poem_line_raw as c_poem_line_raw,
            mm_score as c_score, 
            mm_match_location as c_match_location, 
            mm_match_json as c_match_json,
            TRUE as is_metadata
        FROM all_metadata_matches
    ),
    
    -- NO AGGREGATION - Return ALL matching rows!
    final_results AS (
        SELECT 
            c.c_poem_id as poem_id,
            c.c_row_id as row_id,
            c.c_title_raw as title_raw,
            c.c_poem_line_raw as poem_line_raw,
            
            -- Keep original scores from each match type
            c.c_score as final_score,
            
            -- Collect all match locations for this specific row
            array_agg(DISTINCT unnest_val) as match_locations,
            
            -- Use the match_json from this specific row
            c.c_match_json as merged_match_json
        FROM combined c
        CROSS JOIN LATERAL unnest(c.c_match_location) as unnest_val
        GROUP BY c.c_poem_id, c.c_row_id, c.c_title_raw, c.c_poem_line_raw, c.c_score, c.c_match_json
    )
    
    SELECT 
        fr.poem_id,
        fr.row_id,
        fr.title_raw,
        fr.poem_line_raw,
        fr.final_score,
        fr.match_locations,
        tag as tag_out,
        jsonb_build_object(
            'poem_id', fr.poem_id,
            'row_id', fr.row_id,
            'title_raw', fr.title_raw,
            'poem_line_raw', fr.poem_line_raw,
            'score', round(fr.final_score, 1),
            'match_location', fr.match_locations,
            'tag', tag,
            'match', fr.merged_match_json
        ) as result_json
    FROM final_results fr
    WHERE fr.final_score >= min_score
    ORDER BY fr.final_score DESC
    LIMIT match_limit;
END;
$$;

-- =====================================================
-- HELPER: Get Text Matches - FTS OPTIMIZED with OR support
-- =====================================================

DROP FUNCTION IF EXISTS get_text_matches(TEXT, TEXT, TEXT[], INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION get_text_matches(
    original_query TEXT,
    q_norm TEXT,
    meaningful_words TEXT[],
    match_limit INT,
    min_score NUMERIC
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_raw TEXT,
    poem_line_raw TEXT,
    score NUMERIC,
    match_location TEXT[],
    match_json JSONB
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    word_count INT := array_length(meaningful_words, 1);
    ts_query tsquery;
    clean_words TEXT[];
    has_short_words BOOLEAN := FALSE;
    use_trigram BOOLEAN := FALSE;
BEGIN
    -- Remove empty strings, whitespace, and 'OR' from meaningful_words
    SELECT array_agg(w) INTO clean_words
    FROM unnest(meaningful_words) w
    WHERE trim(w) <> '' AND trim(w) <> 'OR';
    
    -- PHRASE DETECTION: Check if query contains short words (≤2 chars)
    -- Short words like "بو", "ام" are filtered by FTS, so we need trigram search
    SELECT EXISTS (
        SELECT 1 FROM unnest(string_to_array(q_norm, ' ')) word
        WHERE length(word) > 0 AND length(word) <= 2
    ) INTO has_short_words;
    
    -- Use trigram if: has short words OR clean_words is empty (all words filtered)
    use_trigram := has_short_words OR clean_words IS NULL OR array_length(clean_words, 1) IS NULL;
    
    -- Build tsquery (only if using FTS)
    IF NOT use_trigram THEN
        IF position(' OR ' IN original_query) > 0 THEN
            -- Grouped query: use OR (|) operator
            ts_query := to_tsquery('arabic', array_to_string(clean_words, ' | '));
        ELSE
            -- Single query: use AND (&) operator  
            ts_query := to_tsquery('arabic', array_to_string(clean_words, ' & '));
        END IF;
    END IF;
    
    -- STRATEGY: Use completely separate code paths for trigram vs FTS
    IF use_trigram THEN
        -- TRIGRAM PATH: For phrases with short words like "بو خالد", "ابي"
        RETURN QUERY
        WITH 
        -- Title matches: Return one row per poem with title match
        title_only_matches AS (
            SELECT DISTINCT ON (e.poem_id)
                e.poem_id,
                NULL::INT as row_id,  -- No specific line
                e."Title_raw" as title_raw,
                NULL::TEXT as poem_line_raw,  -- Title-only, no line
                100.0 as score,
                ARRAY['title']::TEXT[] as match_location,
                jsonb_build_object(
                    'title', jsonb_build_array(
                        jsonb_build_object(
                            'text', q_norm,
                            'score', 100,
                            'positions', 'phrase',
                            'match_type', 'title_only'
                        )
                    ),
                    'poem_line', '{}'::jsonb
                ) as match_json
            FROM "Exact_search" e
            WHERE normalize_arabic(e."Title_cleaned") LIKE '%' || normalize_arabic(q_norm) || '%'
              -- Only return if NO poem lines match in this poem
              AND NOT EXISTS (
                  SELECT 1 FROM "Exact_search" e2
                  WHERE e2.poem_id = e.poem_id
                    AND normalize_arabic(e2."Poem_line_cleaned") ILIKE '%' || normalize_arabic(q_norm) || '%'
                    AND word_similarity(normalize_arabic(q_norm), normalize_arabic(e2."Poem_line_cleaned")) > 0.6
              )
            ORDER BY e.poem_id
        ),
        
        poem_matches AS (
            -- STAGE 1: Fast ILIKE filter (uses GIN index)
            WITH stage1_candidates AS (
                SELECT * 
                FROM "Exact_search" e
                WHERE normalize_arabic(e."Poem_line_cleaned") ILIKE '%' || normalize_arabic(q_norm) || '%'
                LIMIT 200  -- Safety cap
            )
            -- STAGE 2: Precision word_similarity scoring
            SELECT 
                e.poem_id,
                e."Row_ID" as row_id,
                e."Title_raw" as title_raw,
                e."Poem_line_raw" as poem_line_raw,
                -- Score from word_similarity (0-100 scale)
                (word_similarity(normalize_arabic(q_norm), normalize_arabic(e."Poem_line_cleaned")) * 100)::NUMERIC as score,
                ARRAY['poem_line']::TEXT[] as match_location,
                jsonb_build_object(
                    'title', '[]'::jsonb,
                    'poem_line', jsonb_build_object(
                        'row_id', e."Row_ID",
                        'matched_words', jsonb_build_array(
                            jsonb_build_object(
                                'text', q_norm,
                                'score', ROUND(word_similarity(normalize_arabic(q_norm), normalize_arabic(e."Poem_line_cleaned")) * 100),
                                'positions', 'phrase'  -- Simple marker - frontend will highlight the query text
                            )
                        )
                    )
                ) as match_json
            FROM stage1_candidates e
            WHERE word_similarity(normalize_arabic(q_norm), normalize_arabic(e."Poem_line_cleaned")) > 
                CASE 
                    -- Short queries (≤3 chars): strict threshold
                    WHEN length(replace(q_norm, ' ', '')) <= 3 THEN 0.7
                    -- Multi-word queries: looser threshold for variations
                    WHEN position(' ' IN q_norm) > 0 THEN 0.6
                    -- Default: strict
                    ELSE 0.7
                END
        )
        
        SELECT * FROM title_only_matches
        UNION ALL
        SELECT * FROM poem_matches
        ORDER BY score DESC
        LIMIT match_limit;
        
    ELSE
        -- FTS PATH: For normal queries
        RETURN QUERY
    WITH 
    title_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            ARRAY['title']::TEXT[] as match_location,
            
            -- FTS-BASED SCORING (boosted 1000x to reach 100+ range)
            (
                ts_rank(e.title_tsv, ts_query) * 1000
                
                + CASE WHEN ' ' || normalize_arabic(e."Title_cleaned") || ' ' LIKE '% ' || q_norm || ' %'
                    THEN 50.0 ELSE 0 END
                
                + CASE 
                    WHEN word_count >= 3 THEN 15.0 + (word_count - 3) * 3
                    WHEN word_count = 2 THEN 10.0
                    ELSE 5.0 
                  END
                
                - CASE WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) = 0 
                    THEN 5.0 ELSE 0 END
            )::numeric as title_score,
            
            -- Highlighting: Word positions in Title_raw with consecutive word merging
            jsonb_build_object(
                'title', COALESCE((
                    WITH word_array AS (
                        SELECT word, idx-1 as position
                        FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(word, idx)
                        WHERE word <> ''
                    ),
                    matched_positions AS (
                        SELECT 
                            wa.word,
                            wa.position,
                            ROW_NUMBER() OVER (ORDER BY wa.position) as rn
                        FROM word_array wa
                        WHERE EXISTS (
                            SELECT 1 FROM unnest(clean_words) mw
                            WHERE normalize_arabic(wa.word) = normalize_arabic(mw)
                        )
                        ORDER BY wa.position
                    ),
                    -- Group consecutive positions into ranges
                    ranges AS (
                        SELECT 
                            min(position) as start_pos,
                            max(position) as end_pos,
                            count(*) as word_count,
                            string_agg(word, ' ' ORDER BY position) as matched_text
                        FROM (
                            SELECT 
                                word,
                                position,
                                position - rn as grp
                            FROM matched_positions
                        ) grouped
                        GROUP BY grp
                    )
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'text', matched_text,
                            'positions', CASE 
                                WHEN start_pos = end_pos THEN start_pos::text
                                ELSE start_pos::text || '-' || end_pos::text
                            END,
                            'score', 85
                        )
                    )
                    FROM ranges
                ), '[]'::jsonb),
                'poem_line', '{}'::jsonb
            ) as match_json
            
        FROM "Exact_search" e
        WHERE 
            CASE 
                -- Use trigram for phrases with short words (FTS filters them out)
                WHEN use_trigram THEN
                    ' ' || normalize_arabic(e."Title_cleaned") || ' ' LIKE '% ' || q_norm || ' %'
                -- Use FTS for normal queries
                ELSE
                    e.title_tsv @@ ts_query
            END
        ORDER BY e.poem_id, title_score DESC
    ),
    
    poem_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            ARRAY['poem_line']::TEXT[] as match_location,
            
            -- FTS-BASED SCORING
            (
                ts_rank(e.poem_line_tsv, ts_query) * 1000
                
                + CASE WHEN ' ' || normalize_arabic(e."Poem_line_cleaned") || ' ' LIKE '% ' || q_norm || ' %'
                    THEN 40.0 ELSE 0 END
                
                + CASE 
                    WHEN word_count >= 3 THEN 10.0 + (word_count - 3) * 3
                    WHEN word_count = 2 THEN 7.0
                    ELSE 3.0 
                  END
                
                - CASE WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) = 0 
                    THEN 5.0 ELSE 0 END
            )::numeric as poem_score,
            
            -- Highlighting: Word positions with RANGE support for consecutive words
            jsonb_build_object(
                'title', '[]'::jsonb,
                'poem_line', jsonb_build_object(
                    'row_id', e."Row_ID",
                    'matched_words', COALESCE((
                        WITH word_array AS (
                            SELECT word, idx-1 as position
                            FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(word, idx)
                            WHERE word <> ''
                        ),
                        matched_positions AS (
                            SELECT 
                                wa.word,
                                wa.position,
                                ROW_NUMBER() OVER (ORDER BY wa.position) as rn
                            FROM word_array wa
                            WHERE EXISTS (
                                SELECT 1 FROM unnest(clean_words) mw
                                WHERE normalize_arabic(wa.word) = normalize_arabic(mw)
                            )
                            ORDER BY wa.position
                        ),
                        -- Group consecutive positions into ranges
                        ranges AS (
                            SELECT 
                                min(position) as start_pos,
                                max(position) as end_pos,
                                count(*) as word_count,
                                string_agg(word, ' ' ORDER BY position) as matched_text
                            FROM (
                                SELECT 
                                    word,
                                    position,
                                    position - rn as grp
                                FROM matched_positions
                            ) grouped
                            GROUP BY grp
                        )
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'text', matched_text,
                                'positions', CASE 
                                    WHEN start_pos = end_pos THEN start_pos::text
                                    ELSE start_pos::text || '-' || end_pos::text
                                END,
                                'score', 85
                            )
                        )
                        FROM ranges
                    ), '[]'::jsonb)
                )
            ) as match_json
            
        FROM "Exact_search" e
        WHERE 
            CASE 
                -- Use trigram for phrases with short words
                WHEN use_trigram THEN
                    ' ' || normalize_arabic(e."Poem_line_cleaned") || ' ' LIKE '% ' || q_norm || ' %'
                -- Use FTS for normal queries
                ELSE
                    e.poem_line_tsv @@ ts_query
            END
    )
    
    SELECT 
        tm.poem_id, tm.row_id, tm.title_raw, tm.poem_line_raw, 
        tm.title_score as score, tm.match_location, tm.match_json 
    FROM title_matches tm 
    WHERE tm.title_score >= min_score
    
    UNION ALL
    
    SELECT 
        pm.poem_id, pm.row_id, pm.title_raw, pm.poem_line_raw, 
        pm.poem_score as score, pm.match_location, pm.match_json 
    FROM poem_matches pm 
    WHERE pm.poem_score >= min_score;
    END IF;  -- Close the IF use_trigram ELSE block
END;
$$;

-- =====================================================
-- HELPER: Get ALL Metadata Matches (unchanged)
-- =====================================================

DROP FUNCTION IF EXISTS get_all_metadata_matches(TEXT, TEXT[], INT, NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS get_all_metadata_matches(TEXT, TEXT[], TEXT, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION get_all_metadata_matches(
    q_norm TEXT,
    meaningful_words TEXT[],
    current_tag TEXT,
    match_limit INT,
    min_score NUMERIC
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_raw TEXT,
    poem_line_raw TEXT,
    score NUMERIC,
    match_location TEXT[],
    match_json JSONB
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    tag_words TEXT[];
    tag_norm TEXT;
BEGIN
    -- Extract significant words from tag for entity matching
    -- Skip ONLY structural particles: بن, ابن, ال, آل, بنت
    -- Keep ALL other words including short ones (important for nicknames like "بو خالد")
    IF current_tag IS NOT NULL AND current_tag != '' THEN
        tag_norm := normalize_arabic(current_tag);
        SELECT array_agg(word) INTO tag_words
        FROM unnest(string_to_array(tag_norm, ' ')) word
        WHERE word NOT IN ('بن', 'ابن', 'ال', 'آل', 'بنت', '')
          AND length(word) > 0;  -- Keep "بو", "ام", etc for nicknames!
        
        -- NICKNAME DETECTION: If tag has ≤2 significant words, it's likely a nickname (e.g., "بو خالد")
        -- Nicknames won't match entity names like "محمد بن زايد آل نهيان"
        -- Disable tag-based entity name matching - rely on resolved_from matching only
        IF array_length(tag_words, 1) IS NOT NULL AND array_length(tag_words, 1) <= 2 THEN
            tag_words := ARRAY[]::TEXT[];  -- Disable tag scoring for nicknames
        END IF;
    ELSE
        tag_words := ARRAY[]::TEXT[];
    END IF;
    
    RETURN QUERY
    
    -- شخص column (name + resolved_from highlighting)
    SELECT 
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        
        -- SCORE WITH TAG-BASED ENTITY VERIFICATION
        CASE
            -- CRITICAL SAFETY: Check if fuzzy matched word is in resolved_from
            -- AND check if entity name matches the TAG (not just query)
            WHEN NOT EXISTS (
                SELECT 1 
                FROM jsonb_array_elements(e."شخص") person,
                LATERAL jsonb_array_elements_text(person->'resolved_from') rf
                WHERE jsonb_typeof(person->'resolved_from') = 'array'  -- Safety check!
                  AND EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) mw
                    WHERE 
                        (length(normalize_arabic(mw)) > 2 
                         AND normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%')
                        OR normalize_arabic(rf) = normalize_arabic(mw)
                )
                AND (
                    -- NEW: Match entity name against TAG, not query!
                    -- Count significant words that match between entity name and tag
                    array_length(tag_words, 1) IS NULL  -- No tag provided (fallback to old logic)
                    OR normalize_arabic(person->>'name') = tag_norm  -- Exact match
                    OR (
                        SELECT COUNT(*) >= 2  -- At least 2 significant words match
                        FROM unnest(COALESCE(tag_words, ARRAY[]::TEXT[])) tw
                        WHERE position(tw IN normalize_arabic(person->>'name')) > 0
                    )
                )
            ) THEN 10.0  -- DANGEROUS: fuzzy match not verified OR entity doesn't match tag
            
            -- Penalize if ALL matched words are short (1-2 chars)
            WHEN (
                SELECT bool_and(length(normalize_arabic(mw)) <= 2)
                FROM unnest(meaningful_words) mw
                WHERE EXISTS (
                    SELECT 1 
                    FROM jsonb_array_elements(e."شخص") p,
                    LATERAL jsonb_array_elements_text(p->'resolved_from') rf
                    WHERE jsonb_typeof(p->'resolved_from') = 'array'
                      AND normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
                )
            ) THEN 40.0  -- Very low score for short words only
            
            -- TAG-BASED SCORING: Score based on how well entity name matches tag
            -- This is the DEFAULT now - always check entity relevance!
            ELSE (
                SELECT 
                    CASE
                        -- If tag provided and entity name matches well
                        WHEN array_length(tag_words, 1) > 0 AND EXISTS (
                            SELECT 1 FROM jsonb_array_elements(e."شخص") person
                            WHERE normalize_arabic(person->>'name') = tag_norm
                        ) THEN 70.0
                        
                        -- RELATED ENTITY: Has 'relation' field (father, brother, etc)
                        -- Give medium score (60) - relevant but not primary target
                        WHEN array_length(tag_words, 1) > 0 AND EXISTS (
                            SELECT 1 FROM jsonb_array_elements(e."شخص") person
                            WHERE person->>'relation' IS NOT NULL 
                              AND person->>'relation' != ''
                              AND (
                                  SELECT COUNT(*) >= 1
                                  FROM unnest(COALESCE(tag_words, ARRAY[]::TEXT[])) tw
                                  WHERE position(tw IN normalize_arabic(person->>'name')) > 0
                              )
                        ) THEN 60.0
                        
                        -- 3+ significant words match
                        WHEN array_length(tag_words, 1) > 0 AND EXISTS (
                            SELECT 1 FROM jsonb_array_elements(e."شخص") person
                            WHERE (
                                SELECT COUNT(*) >= 3
                                FROM unnest(COALESCE(tag_words, ARRAY[]::TEXT[])) tw
                                WHERE position(tw IN normalize_arabic(person->>'name')) > 0
                            )
                        ) THEN 65.0
                        
                        -- 2 significant words match
                        WHEN array_length(tag_words, 1) > 0 AND EXISTS (
                            SELECT 1 FROM jsonb_array_elements(e."شخص") person
                            WHERE (
                                SELECT COUNT(*) = 2
                                FROM unnest(COALESCE(tag_words, ARRAY[]::TEXT[])) tw
                                WHERE position(tw IN normalize_arabic(person->>'name')) > 0
                            )
                        ) THEN 50.0
                        
                        -- Only 1 word matches OR no tag provided
                        WHEN array_length(tag_words, 1) > 0 THEN 15.0  -- Tag provided but weak match
                        
                        ELSE 70.0  -- No tag provided - trust the match
                    END
            )
        END as score,
        
        ARRAY['شخص']::TEXT[] as match_location,
        jsonb_build_object(
            'title', '[]'::jsonb,
            'poem_line', jsonb_build_object(
                'row_id', e."Row_ID",
                'matched_words', (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'text', resolved_text,
                            'score', CASE 
                                WHEN length(normalize_arabic(resolved_text)) <= 2 THEN 40
                                ELSE 70 
                            END,
                            'positions', 'metadata',
                            'source', 'شخص_resolved'
                        )
                    )
                    FROM (
                        SELECT DISTINCT resolved_text
                        FROM jsonb_array_elements(e."شخص") person,
                        LATERAL jsonb_array_elements_text(person->'resolved_from') resolved_text
                        WHERE jsonb_typeof(person->'resolved_from') = 'array'
                          AND (EXISTS (
                            SELECT 1 FROM unnest(meaningful_words) mw
                            WHERE length(normalize_arabic(mw)) > 2  -- Require 3+ chars for fuzzy
                               AND normalize_arabic(resolved_text) LIKE '%' || normalize_arabic(mw) || '%'
                        )
                        OR EXISTS (
                            SELECT 1 FROM unnest(meaningful_words) mw
                            WHERE normalize_arabic(resolved_text) = normalize_arabic(mw)  -- Exact match any length
                        ))
                    ) matches
                )
            )
        ) as match_json
    FROM "Exact_search" e
    WHERE jsonb_array_length(e."شخص") > 0  -- Ensure array is not empty
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(e."شخص") person
        WHERE jsonb_typeof(person->'resolved_from') = 'array'
          AND EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(person->'resolved_from') rf
            WHERE EXISTS (
                SELECT 1 FROM unnest(meaningful_words) mw
                WHERE 
                    -- Stricter fuzzy: require 3+ chars
                    (length(normalize_arabic(mw)) > 2 
                     AND normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%')
                    -- OR exact word match (any length)
                    OR normalize_arabic(rf) = normalize_arabic(mw)
            )
        )
    )
    
    UNION ALL
    
    -- أماكن column
    SELECT 
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        -- TAG-BASED SCORING for places (similar to شخص logic)
        CASE
            -- If tag provided, check if place name matches tag
            -- This prevents "محمد ابن راشد ابن مكتوم" (place) from matching "محمد بن زايد" tag
            WHEN array_length(tag_words, 1) > 0 THEN (
                SELECT 
                    CASE
                        -- Place name exactly matches tag
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(e."أماكن") place
                            WHERE normalize_arabic(place->>'name') = tag_norm
                        ) THEN 60.0
                        
                        -- 3+ significant words match
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(e."أماكن") place
                            WHERE (
                                SELECT COUNT(*) >= 3
                                FROM unnest(COALESCE(tag_words, ARRAY[]::TEXT[])) tw
                                WHERE position(tw IN normalize_arabic(place->>'name')) > 0
                            )
                        ) THEN 50.0
                        
                        -- 2 significant words match
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(e."أماكن") place
                            WHERE (
                                SELECT COUNT(*) = 2
                                FROM unnest(COALESCE(tag_words, ARRAY[]::TEXT[])) tw
                                WHERE position(tw IN normalize_arabic(place->>'name')) > 0
                            )
                        ) THEN 35.0
                        
                        -- Only 1 word matches (probably wrong place!)
                        ELSE 15.0
                    END
            )
            -- No tag provided - fallback to old logic
            WHEN NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(e."أماكن") place
                WHERE 
                    (length(q_norm) > 2 AND position(q_norm IN normalize_arabic(place->>'name')) > 0)
                    OR normalize_arabic(place->>'name') = q_norm
                    OR EXISTS (
                        SELECT 1 FROM unnest(meaningful_words) mw
                        WHERE length(normalize_arabic(mw)) > 2 
                           AND normalize_arabic(place->>'name') LIKE '%' || normalize_arabic(mw) || '%'
                    )
            ) THEN 15.0  -- Irrelevant place
            ELSE 60.0  -- Place matches query
        END as score,
        ARRAY['أماكن']::TEXT[] as match_location,
        jsonb_build_object(
            'title', '[]'::jsonb,
            'poem_line', jsonb_build_object(
                'row_id', e."Row_ID",
                'matched_words', jsonb_build_array(
                    jsonb_build_object(
                        'text', (
                            SELECT place->>'name' 
                            FROM jsonb_array_elements(e."أماكن") place 
                            WHERE 
                                (length(q_norm) > 2 AND position(q_norm IN normalize_arabic(place->>'name')) > 0)
                                OR normalize_arabic(place->>'name') = q_norm
                                OR EXISTS (
                                    SELECT 1 FROM unnest(meaningful_words) mw
                                    WHERE 
                                        -- For 3+ char words: allow substring
                                        (length(normalize_arabic(mw)) > 2 
                                         AND position(normalize_arabic(mw) IN normalize_arabic(place->>'name')) > 0)
                                        -- For ANY length: require whole-word match
                                        OR ' ' || normalize_arabic(place->>'name') || ' ' LIKE '% ' || normalize_arabic(mw) || ' %'
                                )
                            LIMIT 1
                        ),
                        'score', 60,
                        'positions', 'metadata',
                        'source', 'أماكن'
                    )
                )
            )
        ) as match_json
    FROM "Exact_search" e
    WHERE jsonb_array_length(e."أماكن") > 0
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(e."أماكن") place
        WHERE 
            -- Stricter: require 3+ chars OR exact match
            (length(q_norm) > 2 AND position(q_norm IN normalize_arabic(place->>'name')) > 0)
            OR normalize_arabic(place->>'name') = q_norm
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) mw
                WHERE 
                    -- For 3+ char words: allow substring
                    (length(normalize_arabic(mw)) > 2 
                     AND position(normalize_arabic(mw) IN normalize_arabic(place->>'name')) > 0)
                    -- For ANY length: require whole-word match (space boundaries)
                    OR ' ' || normalize_arabic(place->>'name') || ' ' LIKE '% ' || normalize_arabic(mw) || ' %'
            )
    )
    
    UNION ALL
    
    -- أحداث column
    SELECT 
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        60.0 as score,
        ARRAY['أحداث']::TEXT[] as match_location,
        jsonb_build_object(
            'title', '[]'::jsonb,
            'poem_line', jsonb_build_object(
                'row_id', e."Row_ID",
                'matched_words', jsonb_build_array(
                    jsonb_build_object(
                        'text', (
                            SELECT event 
                            FROM jsonb_array_elements_text(e."أحداث") event 
                            WHERE position(q_norm IN normalize_arabic(event)) > 0
                               OR EXISTS (
                                   SELECT 1 FROM unnest(meaningful_words) mw
                                   WHERE position(normalize_arabic(mw) IN normalize_arabic(event)) > 0
                               )
                            LIMIT 1
                        ),
                        'score', 60,
                        'positions', 'metadata',
                        'source', 'أحداث'
                    )
                )
            )
        ) as match_json
    FROM "Exact_search" e
    WHERE jsonb_array_length(e."أحداث") > 0
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(e."أحداث") event
        WHERE position(q_norm IN normalize_arabic(event)) > 0
           OR EXISTS (
               SELECT 1 FROM unnest(meaningful_words) mw
               WHERE position(normalize_arabic(mw) IN normalize_arabic(event)) > 0
           )
    )
    
    UNION ALL
    
    -- دين column
    SELECT 
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        60.0 as score,
        ARRAY['دين']::TEXT[] as match_location,
        jsonb_build_object(
            'title', '[]'::jsonb,
            'poem_line', jsonb_build_object(
                'row_id', e."Row_ID",
                'matched_words', jsonb_build_array(
                    jsonb_build_object(
                        'text', (
                            SELECT religion 
                            FROM jsonb_array_elements_text(e."دين") religion 
                            WHERE position(q_norm IN normalize_arabic(religion)) > 0
                               OR EXISTS (
                                   SELECT 1 FROM unnest(meaningful_words) mw
                                   WHERE position(normalize_arabic(mw) IN normalize_arabic(religion)) > 0
                               )
                            LIMIT 1
                        ),
                        'score', 60,
                        'positions', 'metadata',
                        'source', 'دين'
                    )
                )
            )
        ) as match_json
    FROM "Exact_search" e
    WHERE jsonb_array_length(e."دين") > 0
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(e."دين") religion
        WHERE position(q_norm IN normalize_arabic(religion)) > 0
           OR EXISTS (
               SELECT 1 FROM unnest(meaningful_words) mw
               WHERE position(normalize_arabic(mw) IN normalize_arabic(religion)) > 0
           )
    )
    
    UNION ALL
    
    -- مواضيع column
    SELECT 
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        60.0 as score,
        ARRAY['مواضيع']::TEXT[] as match_location,
        jsonb_build_object(
            'title', '[]'::jsonb,
            'poem_line', jsonb_build_object(
                'row_id', e."Row_ID",
                'matched_words', jsonb_build_array(
                    jsonb_build_object(
                        'text', (
                            SELECT topic 
                            FROM jsonb_array_elements_text(e."مواضيع") topic 
                            WHERE position(q_norm IN normalize_arabic(topic)) > 0
                               OR EXISTS (
                                   SELECT 1 FROM unnest(meaningful_words) mw
                                   WHERE position(normalize_arabic(mw) IN normalize_arabic(topic)) > 0
                               )
                            LIMIT 1
                        ),
                        'score', 60,
                        'positions', 'metadata',
                        'source', 'مواضيع'
                    )
                )
            )
        ) as match_json
    FROM "Exact_search" e
    WHERE jsonb_array_length(e."مواضيع") > 0
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(e."مواضيع") topic
        WHERE position(q_norm IN normalize_arabic(topic)) > 0
           OR EXISTS (
               SELECT 1 FROM unnest(meaningful_words) mw
               WHERE position(normalize_arabic(mw) IN normalize_arabic(topic)) > 0
           )
    )
    
    UNION ALL
    
    -- sentiments column
    SELECT 
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        60.0 as score,
        ARRAY['sentiments']::TEXT[] as match_location,
        jsonb_build_object(
            'title', '[]'::jsonb,
            'poem_line', jsonb_build_object(
                'row_id', e."Row_ID",
                'matched_words', jsonb_build_array(
                    jsonb_build_object(
                        'text', e.sentiments,
                        'score', 60,
                        'positions', 'metadata',
                        'source', 'sentiments'
                    )
                )
            )
        ) as match_json
    FROM "Exact_search" e
    WHERE e.sentiments IS NOT NULL
      AND (position(q_norm IN normalize_arabic(e.sentiments)) > 0
           OR EXISTS (
               SELECT 1 FROM unnest(meaningful_words) mw
               WHERE position(normalize_arabic(mw) IN normalize_arabic(e.sentiments)) > 0
           ));
END;
$$;