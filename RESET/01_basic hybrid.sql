-- =====================================================
-- HYBRID SEARCH V2: Entity-Aware Multi-Column Search
-- =====================================================

DROP FUNCTION IF EXISTS hybrid_search_v2_entity_aware(JSONB, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION hybrid_search_v2_entity_aware(
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
LANGUAGE plpgsql
AS $$
DECLARE
    exact_q JSONB;
    expanded_queries JSONB;
    individual_limit INT;
    
    current_query TEXT;
    current_column TEXT;
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
    -- Extract N8N payload components
    exact_q := n8n_payload->'N8N_query';
    expanded_queries := n8n_payload->'N8N_query'->'expanded_queries';
    individual_limit := COALESCE((n8n_payload->'N8N_query'->>'individual_Limit')::INT, 10);
    
    -- ==========================================
    -- PHASE 1: EXACT QUERY (100% confidence)
    -- ==========================================
    current_query := exact_q->>'Exact_query';
    current_column := exact_q->>'column';
    current_tag := exact_q->>'tag';
    current_confidence := COALESCE((exact_q->>'confidence_score')::NUMERIC, 100);
    
    IF current_query IS NOT NULL THEN
        -- Normalize query
        q_norm := TRIM(normalize_arabic(current_query));
        query_words := string_to_array(trim(current_query), ' ');
        
        meaningful_words := ARRAY[]::TEXT[];
        FOREACH current_word IN ARRAY query_words
        LOOP
            IF NOT is_common_particle(current_word) 
               AND normalize_arabic(current_word) NOT IN ('بن', 'ابن', 'بو', 'ابو', 'ال') 
            THEN
                meaningful_words := array_append(meaningful_words, current_word);
            END IF;
        END LOOP;
        
        IF array_length(meaningful_words, 1) IS NULL THEN
            meaningful_words := query_words;
        END IF;
        
        all_tags := array_append(all_tags, current_tag);
        
        -- Execute exact query search
        FOR result_row IN (
            SELECT * FROM process_single_query(
                current_query, q_norm, meaningful_words, current_column, 
                current_tag, current_confidence, individual_limit, min_score
            )
        ) LOOP
            temp_results := temp_results || jsonb_build_array(result_row.result_json);
            total_poems := total_poems + 1;
            total_lines := total_lines + 1;
            -- Estimate words (approximate)
            total_words := total_words + array_length(string_to_array(result_row.poem_line_raw, ' '), 1);
        END LOOP;
    END IF;
    
    -- ==========================================
    -- PHASE 2: EXPANDED QUERIES
    -- ==========================================
    IF expanded_queries IS NOT NULL THEN
        FOR i IN 0..jsonb_array_length(expanded_queries)-1 LOOP
            current_query := expanded_queries->i->>'query';
            current_column := expanded_queries->i->>'column';
            current_tag := expanded_queries->i->>'tag';
            current_confidence := COALESCE((expanded_queries->i->>'confidence_score')::NUMERIC, 50);
            
            IF current_query IS NULL THEN
                CONTINUE;
            END IF;
            
            -- Normalize query
            q_norm := TRIM(normalize_arabic(current_query));
            query_words := string_to_array(trim(current_query), ' ');
            
            meaningful_words := ARRAY[]::TEXT[];
            FOREACH current_word IN ARRAY query_words
            LOOP
                IF NOT is_common_particle(current_word) 
                   AND normalize_arabic(current_word) NOT IN ('بن', 'ابن', 'بو', 'ابو', 'ال') 
                THEN
                    meaningful_words := array_append(meaningful_words, current_word);
                END IF;
            END LOOP;
            
            IF array_length(meaningful_words, 1) IS NULL THEN
                meaningful_words := query_words;
            END IF;
            
            all_tags := array_append(all_tags, current_tag);
            
            -- Execute expanded query search
            FOR result_row IN (
                SELECT * FROM process_single_query(
                    current_query, q_norm, meaningful_words, current_column, 
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
    RAISE NOTICE 'temp_results: %', temp_results;
    RAISE NOTICE 'temp_results length: %', jsonb_array_length(temp_results);
    RETURN QUERY
    SELECT 
        CASE WHEN exact_q IS NOT NULL THEN 'exact' ELSE 'expanded' END::TEXT,
        COALESCE(exact_q->>'Exact_query', 'N/A')::TEXT,
        current_confidence,
        10, -- entity_boost constant
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
-- HELPER: Process Single Query (Text + Entity Search)
-- =====================================================

DROP FUNCTION IF EXISTS process_single_query(TEXT, TEXT, TEXT[], TEXT, TEXT, NUMERIC, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION process_single_query(
    original_query TEXT,
    q_norm TEXT,
    meaningful_words TEXT[],
    target_column TEXT,
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
    match_type TEXT,
    tag_out TEXT,
    result_json JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH 
    -- Text-based matches (title + poem_line)
    text_matches AS (
        SELECT * FROM get_text_matches(original_query, q_norm, meaningful_words, match_limit, min_score)
    ),
    
    -- Entity-based matches (JSONB columns)
    entity_matches AS (
        SELECT * FROM get_entity_matches(q_norm, meaningful_words, target_column, tag, confidence, match_limit, min_score)
    ),
    
    -- Combine all matches
    combined AS (
        SELECT * FROM text_matches
        UNION ALL
        SELECT * FROM entity_matches
    ),
    
    -- Group by poem_id and select best match
    best_per_poem AS (
        SELECT 
            c.poem_id,
            (array_agg(c.row_id ORDER BY c.score DESC))[1] as row_id,
            (array_agg(c.title_raw ORDER BY c.score DESC))[1] as title_raw,
            (array_agg(c.poem_line_raw ORDER BY c.score DESC))[1] as poem_line_raw,
            MAX(c.score) as final_score,
            array_agg(DISTINCT unnest_val) as match_locations,
            (array_agg(c.match_type ORDER BY c.score DESC))[1] as match_type,
            (array_agg(c.match_json ORDER BY c.score DESC))[1] as match_json
        FROM combined c
        CROSS JOIN LATERAL unnest(c.match_location) as unnest_val
        GROUP BY c.poem_id
    )
    
    SELECT 
        bpp.poem_id,
        bpp.row_id,
        bpp.title_raw,
        bpp.poem_line_raw,
        bpp.final_score,
        bpp.match_locations,
        bpp.match_type,
        tag,
        jsonb_build_object(
            'poem_id', bpp.poem_id,
            'row_id', bpp.row_id,
            'title_raw', bpp.title_raw,
            'poem_line_raw', bpp.poem_line_raw,
            'score', round(bpp.final_score, 1),
            'match_location', bpp.match_locations,
            'match_type', bpp.match_type,
            'tag', tag,
            'match', bpp.match_json
        ) as result_json
    FROM best_per_poem bpp
    ORDER BY bpp.final_score DESC
    LIMIT match_limit;
END;
$$;

-- =====================================================
-- HELPER: Get Text Matches (Title + Poem Line)
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
    match_type TEXT,
    match_json JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH 
    title_matches AS (
        SELECT DISTINCT ON (e.poem_id)
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            ARRAY['title']::TEXT[] as match_location,
            
            (CASE
                WHEN (' ' || normalize_arabic(e."Title_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 110.0
                WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 110.0
                WHEN array_length(meaningful_words, 1) > 1 AND EXISTS (
                    SELECT 1 FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(word, idx)
                    WHERE (SELECT bool_and(EXISTS (SELECT 1 FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2) WHERE normalize_arabic(u2.word2) = normalize_arabic(mw) AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2)) FROM unnest(meaningful_words) mw)
                ) THEN 90.0 + (array_length(meaningful_words, 1) * 2)
                WHEN array_length(meaningful_words, 1) > 1 AND (SELECT bool_and(position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0) FROM unnest(meaningful_words) w) THEN 60.0 + (array_length(meaningful_words, 1) * 2)
                WHEN EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0) THEN 85.0 + (SELECT COUNT(*)::numeric * 10 FROM unnest(meaningful_words) w WHERE position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0)
                ELSE 0
            END)::numeric as title_score,
            
            'exact_phrase'::text as match_type,
            
            jsonb_build_object(
                'title', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('text', match_info.pw, 'positions', (match_info.pos[1])::text, 'score', match_info.scr) ORDER BY match_info.scr DESC)
                    FROM (
                        SELECT pw, array_agg(idx-1) as pos, CASE WHEN position(q_norm IN normalize_arabic(e."Title_cleaned")) > 0 THEN 110 ELSE 50 END as scr
                        FROM unnest(string_to_array(e."Title_cleaned", ' ')) WITH ORDINALITY AS u(pw, idx)
                        WHERE pw <> '' AND (position(normalize_arabic(pw) IN q_norm) > 0 OR position(q_norm IN normalize_arabic(pw)) > 0 OR EXISTS (SELECT 1 FROM unnest(meaningful_words) mw WHERE normalize_arabic(pw) LIKE '%'||normalize_arabic(mw)||'%'))
                        GROUP BY pw
                    ) match_info
                ), '[]'::jsonb),
                'poem_line', '{}'::jsonb
            ) as match_json
            
        FROM "Exact_search" e
        WHERE position(normalize_arabic(original_query) IN normalize_arabic(e."Title_cleaned")) > 0 
           OR EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(normalize_arabic(w) IN normalize_arabic(e."Title_cleaned")) > 0)
        ORDER BY e.poem_id, title_score DESC
    ),
    
    poem_matches AS (
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            ARRAY['poem_line']::TEXT[] as match_location,
            
            (CASE
                WHEN (' ' || normalize_arabic(e."Poem_line_cleaned") || ' ') LIKE ('% ' || q_norm || ' %') THEN 100.0
                WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 10.0
                WHEN array_length(meaningful_words, 1) > 1 AND EXISTS (
                    SELECT 1 FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(word, idx)
                    WHERE (SELECT bool_and(EXISTS (SELECT 1 FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u2(word2, idx2) WHERE normalize_arabic(u2.word2) = normalize_arabic(mw) AND idx2 BETWEEN idx AND idx + array_length(meaningful_words, 1) + 2)) FROM unnest(meaningful_words) mw)
                ) THEN 85.0 + (array_length(meaningful_words, 1) * 2)
                WHEN array_length(meaningful_words, 1) > 1 AND (SELECT bool_and(position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0) FROM unnest(meaningful_words) w) THEN 55.0 + (array_length(meaningful_words, 1) * 2)
                WHEN EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0) THEN 35.0 + (SELECT COUNT(*)::numeric * 8 FROM unnest(meaningful_words) w WHERE position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0)
                ELSE 0
            END)::numeric as poem_score,
            
            'exact_phrase'::text as match_type,
            
            jsonb_build_object(
                'title', '[]'::jsonb,
                'poem_line', jsonb_build_object(
                    'row_id', e."Row_ID",
                    'matched_words', COALESCE((
                        SELECT jsonb_agg(jsonb_build_object('text', mi.pw, 'positions', CASE WHEN array_length(mi.pos, 1) > 1 THEN (mi.pos[1])::text || '-' || (mi.pos[array_length(mi.pos, 1)])::text ELSE (mi.pos[1])::text END, 'score', mi.scr) ORDER BY mi.scr DESC)
                        FROM (
                            SELECT pw, array_agg(idx-1) as pos, CASE WHEN position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 100 WHEN (' '||normalize_arabic(pw)||' ') LIKE ('% '||q_norm||' %') THEN 100 ELSE 50 END as scr
                            FROM unnest(string_to_array(e."Poem_line_cleaned", ' ')) WITH ORDINALITY AS u(pw, idx)
                            WHERE pw <> '' AND ((position(q_norm IN normalize_arabic(e."Poem_line_cleaned")) > 0 AND position(normalize_arabic(pw) IN q_norm) > 0) OR normalize_arabic(pw) LIKE '%' || q_norm || '%' OR EXISTS (SELECT 1 FROM unnest(meaningful_words) mw WHERE normalize_arabic(pw) LIKE '%'||normalize_arabic(mw)||'%')) AND (length(normalize_arabic(pw)) > 1)
                            GROUP BY pw
                        ) mi
                    ), '[]'::jsonb)
                )
            ) as match_json
            
        FROM "Exact_search" e
        WHERE position(normalize_arabic(original_query) IN normalize_arabic(e."Poem_line_cleaned")) > 0 
           OR EXISTS (SELECT 1 FROM unnest(meaningful_words) w WHERE position(normalize_arabic(w) IN normalize_arabic(e."Poem_line_cleaned")) > 0)
    )
    
    SELECT tm.poem_id, tm.row_id, tm.title_raw, tm.poem_line_raw, tm.title_score as score, tm.match_location, tm.match_type, tm.match_json 
    FROM title_matches tm WHERE tm.title_score >= min_score
    UNION ALL
    SELECT pm.poem_id, pm.row_id, pm.title_raw, pm.poem_line_raw, pm.poem_score as score, pm.match_location, pm.match_type, pm.match_json 
    FROM poem_matches pm WHERE pm.poem_score >= min_score;
END;
$$;

-- =====================================================
-- HELPER: Get Entity Matches (JSONB Columns)
-- =====================================================

DROP FUNCTION IF EXISTS get_entity_matches(TEXT, TEXT[], TEXT, TEXT, NUMERIC, INT, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION get_entity_matches(
    q_norm TEXT,
    meaningful_words TEXT[],
    target_column TEXT,
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
    score NUMERIC,
    match_location TEXT[],
    match_type TEXT,
    match_json JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Skip if no column specified
    IF target_column IS NULL OR target_column = '' THEN
        RETURN;
    END IF;
    
    RETURN QUERY EXECUTE format($q$
        SELECT 
            e.poem_id,
            e."Row_ID" as row_id,
            e."Title_raw" as title_raw,
            e."Poem_line_raw" as poem_line_raw,
            %s as score,
            ARRAY['%s']::TEXT[] as match_location,
            'entity_match'::text as match_type,
            jsonb_build_object(
                'title', '[]'::jsonb,
                'poem_line', jsonb_build_object(
                    'row_id', e."Row_ID",
                    'matched_words', jsonb_build_array(
                        jsonb_build_object(
                            'text', '%s',
                            'score', %s,
                            'positions', 'metadata'
                        )
                    )
                )
            ) as match_json
        FROM "Exact_search" e
        WHERE 
            CASE 
                WHEN '%s' = 'شخص' THEN 
                    EXISTS (
                        SELECT 1 FROM jsonb_array_elements(e."شخص") entity
                        WHERE position('%s' IN normalize_arabic(entity->>'name')) > 0
                           OR EXISTS (
                               SELECT 1 FROM jsonb_array_elements_text(entity->'resolved_from') rf
                               WHERE position('%s' IN normalize_arabic(rf)) > 0
                           )
                    )
                WHEN '%s' = 'أماكن' THEN 
                    EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(e."أماكن") place
                        WHERE position('%s' IN normalize_arabic(place)) > 0
                    )
                WHEN '%s' = 'أحداث' THEN 
                    EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(e."أحداث") event
                        WHERE position('%s' IN normalize_arabic(event)) > 0
                    )
                WHEN '%s' = 'دين' THEN 
                    EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(e."دين") religion
                        WHERE position('%s' IN normalize_arabic(religion)) > 0
                    )
                WHEN '%s' = 'مواضيع' THEN 
                    EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(e."مواضيع") topic
                        WHERE position('%s' IN normalize_arabic(topic)) > 0
                    )
                ELSE FALSE
            END
        LIMIT %s
    $q$, 
    (confidence * 0.6)::NUMERIC, 
    target_column, 
    tag, 
    (confidence * 0.6)::INT,
    target_column, q_norm, q_norm,
    target_column, q_norm,
    target_column, q_norm,
    target_column, q_norm,
    target_column, q_norm,
    match_limit);
END;
$$;