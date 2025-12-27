-- =====================================================
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
        FROM get_all_metadata_matches(q_norm, meaningful_words, match_limit, min_score) mm
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
    
    aggregated_per_poem AS (
        SELECT 
            c.c_poem_id,
            (array_agg(c.c_row_id ORDER BY c.c_score DESC))[1] as row_id,
            (array_agg(c.c_title_raw ORDER BY c.c_score DESC))[1] as title_raw,
            (array_agg(c.c_poem_line_raw ORDER BY c.c_score DESC))[1] as poem_line_raw,
            
            -- Determine final score based on combination
            (CASE
                -- Title only (no metadata, no poem_line)
                WHEN bool_or('title' = ANY(c.c_match_location)) AND NOT bool_or(c.is_metadata) AND NOT bool_or('poem_line' = ANY(c.c_match_location))
                    THEN 100.0
                    
                -- Title + any metadata (NEW - should be high score)
                WHEN bool_or('title' = ANY(c.c_match_location)) AND bool_or(c.is_metadata) AND NOT bool_or('poem_line' = ANY(c.c_match_location))
                    THEN 95.0

                -- Title + Poem_line both matched
                WHEN bool_or('title' = ANY(c.c_match_location)) AND bool_or('poem_line' = ANY(c.c_match_location))
                    THEN 90.0
                    
                -- Poem_line + any metadata
                WHEN bool_or('poem_line' = ANY(c.c_match_location)) AND bool_or(c.is_metadata)
                    THEN 85.0
                    
                -- Poem_line only
                WHEN bool_or('poem_line' = ANY(c.c_match_location)) AND NOT bool_or(c.is_metadata)
                    THEN 80.0
                    
                -- شخص metadata only
                WHEN bool_or('شخص' = ANY(c.c_match_location)) AND NOT bool_or('poem_line' = ANY(c.c_match_location)) AND NOT bool_or('title' = ANY(c.c_match_location))
                    -- Preserve low scores for irrelevant entities (20-40 range)
                    THEN CASE 
                        WHEN MAX(c.c_score) < 50 THEN MAX(c.c_score)  -- Keep low entity-relevance scores
                        ELSE 70.0  -- Normal شخص score
                    END
                    
                -- Other metadata only
                WHEN bool_or(c.is_metadata) AND NOT bool_or('poem_line' = ANY(c.c_match_location)) AND NOT bool_or('title' = ANY(c.c_match_location))
                    -- Preserve low scores for irrelevant entities (20 range)
                    THEN CASE 
                        WHEN MAX(c.c_score) < 50 THEN MAX(c.c_score)  -- Keep low entity-relevance scores
                        ELSE 60.0  -- Normal metadata score
                    END
                    
                ELSE MAX(c.c_score)
            END) as final_score,
            
            array_agg(DISTINCT unnest_val) as match_locations,
            
            -- Merge all match_json objects
            jsonb_build_object(
                'title', COALESCE(
                    (SELECT c2.c_match_json->'title' FROM combined c2 
                     WHERE c2.c_poem_id = c.c_poem_id AND 'title' = ANY(c2.c_match_location) 
                     ORDER BY c2.c_score DESC LIMIT 1),
                    '[]'::jsonb
                ),
                'poem_line', COALESCE(
                    (SELECT c3.c_match_json->'poem_line' FROM combined c3
                     WHERE c3.c_poem_id = c.c_poem_id AND c3.c_row_id = (array_agg(c.c_row_id ORDER BY c.c_score DESC))[1]
                     ORDER BY c3.c_score DESC LIMIT 1),
                    '{}'::jsonb
                )
            ) as merged_match_json
            
        FROM combined c
        CROSS JOIN LATERAL unnest(c.c_match_location) as unnest_val
        GROUP BY c.c_poem_id
    )
    
    SELECT 
        app.c_poem_id as poem_id,
        app.row_id,
        app.title_raw,
        app.poem_line_raw,
        app.final_score,
        app.match_locations,
        tag as tag_out,
        jsonb_build_object(
            'poem_id', app.c_poem_id,
            'row_id', app.row_id,
            'title_raw', app.title_raw,
            'poem_line_raw', app.poem_line_raw,
            'score', round(app.final_score, 1),
            'match_location', app.match_locations,
            'tag', tag,
            'match', app.merged_match_json
        ) as result_json
    FROM aggregated_per_poem app
    WHERE app.final_score >= min_score
    ORDER BY app.final_score DESC
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
BEGIN
    -- Remove empty strings, whitespace, and 'OR' from meaningful_words
    SELECT array_agg(w) INTO clean_words
    FROM unnest(meaningful_words) w
    WHERE trim(w) <> '' AND trim(w) <> 'OR';
    
    -- Build tsquery
    IF position(' OR ' IN original_query) > 0 THEN
        -- Grouped query: use OR (|) operator
        ts_query := to_tsquery('arabic', array_to_string(clean_words, ' | '));
    ELSE
        -- Single query: use AND (&) operator
        ts_query := to_tsquery('arabic', array_to_string(clean_words, ' & '));
    END IF;
    
    RETURN QUERY
    WITH 
    title_matches AS (
        SELECT DISTINCT ON (e.poem_id)
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
        WHERE e.title_tsv @@ ts_query
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
        WHERE e.poem_line_tsv @@ ts_query
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
END;
$$;

-- =====================================================
-- HELPER: Get ALL Metadata Matches (unchanged)
-- =====================================================

DROP FUNCTION IF EXISTS get_all_metadata_matches(TEXT, TEXT[], INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION get_all_metadata_matches(
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
BEGIN
    RETURN QUERY
    
    -- شخص column (name + resolved_from highlighting)
    SELECT 
        e.poem_id,
        e."Row_ID" as row_id,
        e."Title_raw" as title_raw,
        e."Poem_line_raw" as poem_line_raw,
        
        -- SCORE WITH CRITICAL SAFETY CHECK
        CASE
            -- CRITICAL: Even if entity name matches query, check if the fuzzy matched word
            -- is actually in resolved_from! Otherwise "غضبي" could be associated with Sheikh!
            WHEN NOT EXISTS (
                SELECT 1 
                FROM jsonb_array_elements(e."شخص") person,
                LATERAL jsonb_array_elements_text(person->'resolved_from') rf
                WHERE EXISTS (
                    SELECT 1 FROM unnest(meaningful_words) mw
                    WHERE 
                        -- The matched word must actually be in resolved_from
                        (length(normalize_arabic(mw)) > 2 
                         AND normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%')
                        OR normalize_arabic(rf) = normalize_arabic(mw)
                )
                AND (
                    -- AND entity name must match query
                    (length(q_norm) > 2 AND position(q_norm IN normalize_arabic(person->>'name')) > 0)
                    OR normalize_arabic(person->>'name') = q_norm
                    OR EXISTS (
                        SELECT 1 FROM unnest(meaningful_words) mw2
                        WHERE length(normalize_arabic(mw2)) > 2 
                           AND position(normalize_arabic(mw2) IN normalize_arabic(person->>'name')) > 0
                    )
                )
            ) THEN 10.0  -- CRITICAL: Fuzzy match NOT verified in resolved_from - DANGEROUS!
            
            -- Penalize if ALL matched words are short (1-2 chars)
            WHEN (
                SELECT bool_and(length(normalize_arabic(mw)) <= 2)
                FROM unnest(meaningful_words) mw
                WHERE EXISTS (
                    SELECT 1 
                    FROM jsonb_array_elements(e."شخص") p,
                    LATERAL jsonb_array_elements_text(p->'resolved_from') rf
                    WHERE normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
                )
            ) THEN 40.0  -- Very low score for short words only
            
            ELSE 70.0  -- Safe - fuzzy match verified in resolved_from
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
                        WHERE EXISTS (
                            SELECT 1 FROM unnest(meaningful_words) mw
                            WHERE length(normalize_arabic(mw)) > 2  -- Require 3+ chars for fuzzy
                               AND normalize_arabic(resolved_text) LIKE '%' || normalize_arabic(mw) || '%'
                        )
                        OR EXISTS (
                            SELECT 1 FROM unnest(meaningful_words) mw
                            WHERE normalize_arabic(resolved_text) = normalize_arabic(mw)  -- Exact match any length
                        )
                    ) matches
                )
            )
        ) as match_json
    FROM "Exact_search" e
    WHERE EXISTS (
        SELECT 1 FROM jsonb_array_elements(e."شخص") person
        WHERE EXISTS (
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
        -- Entity relevance scoring (same logic as شخص)
        CASE
            -- Place name doesn't match query (like "روس النصابي" for "محمد بن راشد" search)
            -- This means the fuzzy match is probably garbage
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
            ) THEN 15.0  -- Irrelevant place - fuzzy match is garbage
            ELSE 60.0  -- Place name matches query - trust the fuzzy match
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
    WHERE EXISTS (
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
    WHERE EXISTS (
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
    WHERE EXISTS (
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
    WHERE EXISTS (
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