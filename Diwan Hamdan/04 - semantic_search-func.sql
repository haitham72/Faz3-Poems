-- =====================================================
-- STEP 1: Create safe JSON extraction helper function
-- =====================================================
CREATE OR REPLACE FUNCTION safe_extract_json_array(
    metadata_field JSONB,
    field_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    -- If it's already an array, return it
    IF jsonb_typeof(metadata_field) = 'array' THEN
        RETURN metadata_field;
    END IF;
    
    -- If it's null, return empty array
    IF metadata_field IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;
    
    -- If it's a string, try to parse it
    IF jsonb_typeof(metadata_field) = 'string' THEN
        BEGIN
            DECLARE
                parsed JSONB;
            BEGIN
                -- Parse the string to JSON
                parsed := (metadata_field #>> '{}')::jsonb;
                
                -- If the result has a field with the same name, extract it
                IF jsonb_typeof(parsed) = 'object' AND parsed ? field_name THEN
                    IF jsonb_typeof(parsed -> field_name) = 'array' THEN
                        RETURN parsed -> field_name;
                    END IF;
                END IF;
                
                -- If it's directly an array
                IF jsonb_typeof(parsed) = 'array' THEN
                    RETURN parsed;
                END IF;
                
                RETURN '[]'::jsonb;
            EXCEPTION WHEN OTHERS THEN
                -- Any parsing error, return empty array
                RETURN '[]'::jsonb;
            END;
        END;
    END IF;
    
    -- For any other type, return empty array
    RETURN '[]'::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN '[]'::jsonb;
END;
$$;

-- =====================================================
-- STEP 2: Update hybrid_search to use the safe function
-- =====================================================
DROP FUNCTION IF EXISTS hybrid_search CASCADE;

CREATE OR REPLACE FUNCTION hybrid_search(
    query_text TEXT,
    query_embedding vector(1536),
    match_count INT DEFAULT 20,
    fts_weight FLOAT DEFAULT 0.4,
    trigram_weight FLOAT DEFAULT 0.3,
    exact_weight FLOAT DEFAULT 0.6,
    semantic_weight FLOAT DEFAULT 1.0,
    rrf_k INT DEFAULT 50
)
RETURNS TABLE(
    id BIGINT,
    content TEXT,
    metadata JSONB,
    summary_text TEXT,
    
    -- Scoring breakdown
    final_score FLOAT,
    rrf_score FLOAT,
    fts_rank FLOAT,
    trigram_sim FLOAT,
    exact_match BOOLEAN,
    semantic_sim FLOAT,
    
    -- Match details
    matched_in TEXT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    q_norm TEXT;
    query_words TEXT[];
    meaningful_words TEXT[];
    current_word TEXT;
BEGIN
    -- Normalize query
    q_norm := TRIM(normalize_arabic(query_text));
    query_words := string_to_array(TRIM(query_text), ' ');
    
    -- Filter out common particles
    meaningful_words := ARRAY[]::TEXT[];
    FOREACH current_word IN ARRAY query_words
    LOOP
        IF NOT is_common_particle(current_word) THEN
            meaningful_words := array_append(meaningful_words, current_word);
        END IF;
    END LOOP;
    
    IF array_length(meaningful_words, 1) IS NULL THEN
        meaningful_words := query_words;
    END IF;
    
    RETURN QUERY
    WITH 
    -- =====================================================
    -- HELPER: Safely parse nested JSON metadata
    -- =====================================================
    parsed_metadata AS (
        SELECT
            d.id,
            d.content,
            d.metadata,
            d.embedding,
            d.fts,
            
            safe_extract_json_array(d.metadata->'entities', 'entities') AS entities_parsed,
            safe_extract_json_array(d.metadata->'places', 'places') AS places_parsed,
            safe_extract_json_array(d.metadata->'subjects', 'subjects') AS subjects_parsed,
            safe_extract_json_array(d.metadata->'events', 'events') AS events_parsed,
            safe_extract_json_array(d.metadata->'religion', 'religion') AS religion_parsed,
            safe_extract_json_array(d.metadata->'animals', 'animals') AS animals_parsed,
            safe_extract_json_array(d.metadata->'sentiments', 'sentiments') AS sentiments_parsed
            
        FROM documents d
    ),
    
    -- =====================================================
    -- SIGNAL 1: FULL-TEXT SEARCH (FTS)
    -- =====================================================
    fts_results AS (
        SELECT
            pm.id,
            ROW_NUMBER() OVER(ORDER BY ts_rank_cd(pm.fts, websearch_to_tsquery('arabic', query_text)) DESC) AS rank_ix,
            ts_rank_cd(pm.fts, websearch_to_tsquery('arabic', query_text))::FLOAT AS score
        FROM parsed_metadata pm
        WHERE pm.fts @@ websearch_to_tsquery('arabic', query_text)
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 2: TRIGRAM SIMILARITY
    -- =====================================================
    trigram_results AS (
        SELECT
            pm.id,
            ROW_NUMBER() OVER(ORDER BY 
                GREATEST(
                    similarity(normalize_arabic(split_part(pm.content, '---', 2)), q_norm),
                    similarity(normalize_arabic(pm.metadata->>'title_cleaned'), q_norm)
                ) DESC
            ) AS rank_ix,
            GREATEST(
                similarity(normalize_arabic(split_part(pm.content, '---', 2)), q_norm),
                similarity(normalize_arabic(pm.metadata->>'title_cleaned'), q_norm)
            )::FLOAT AS score
        FROM parsed_metadata pm
        WHERE 
            similarity(normalize_arabic(split_part(pm.content, '---', 2)), q_norm) > 0.1
            OR similarity(normalize_arabic(pm.metadata->>'title_cleaned'), q_norm) > 0.1
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 3: EXACT PHRASE MATCHING
    -- =====================================================
    exact_results AS (
        SELECT
            pm.id,
            ROW_NUMBER() OVER(ORDER BY 
                CASE 
                    WHEN EXISTS (
                        SELECT 1 FROM jsonb_array_elements(pm.entities_parsed) e 
                        WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                    ) THEN 1
                    WHEN normalize_arabic(pm.metadata->>'title_cleaned') LIKE '%' || q_norm || '%' THEN 2
                    WHEN normalize_arabic(split_part(pm.content, '---', 2)) LIKE '%' || q_norm || '%' THEN 3
                    WHEN (
                        SELECT COUNT(*) = array_length(meaningful_words, 1)
                        FROM unnest(meaningful_words) mw
                        WHERE position(normalize_arabic(mw) IN normalize_arabic(pm.metadata->>'title_cleaned')) > 0
                    ) THEN 4
                    WHEN (
                        SELECT COUNT(*) = array_length(meaningful_words, 1)
                        FROM unnest(meaningful_words) mw
                        WHERE position(normalize_arabic(mw) IN normalize_arabic(split_part(pm.content, '---', 2))) > 0
                    ) THEN 5
                    ELSE 6
                END
            ) AS rank_ix,
            CASE 
                WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.entities_parsed) e 
                    WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                ) THEN TRUE
                WHEN normalize_arabic(pm.metadata->>'title_cleaned') LIKE '%' || q_norm || '%' THEN TRUE
                WHEN normalize_arabic(split_part(pm.content, '---', 2)) LIKE '%' || q_norm || '%' THEN TRUE
                ELSE FALSE
            END AS has_exact_match
        FROM parsed_metadata pm
        WHERE 
            EXISTS (
                SELECT 1 FROM jsonb_array_elements(pm.entities_parsed) e 
                WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
            )
            OR normalize_arabic(pm.metadata->>'title_cleaned') LIKE '%' || q_norm || '%'
            OR normalize_arabic(split_part(pm.content, '---', 2)) LIKE '%' || q_norm || '%'
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) mw
                WHERE position(normalize_arabic(mw) IN normalize_arabic(split_part(pm.content, '---', 2))) > 0
            )
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 4: SEMANTIC/VECTOR SEARCH
    -- =====================================================
    semantic_results AS (
        SELECT
            pm.id,
            ROW_NUMBER() OVER(ORDER BY pm.embedding <#> query_embedding) AS rank_ix,
            (1 - (pm.embedding <=> query_embedding))::FLOAT AS score
        FROM parsed_metadata pm
        WHERE pm.embedding IS NOT NULL
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 5: METADATA MATCHING
    -- =====================================================
    metadata_matches AS (
        SELECT
            pm.id,
            ARRAY_AGG(DISTINCT match_type) AS matched_fields
        FROM parsed_metadata pm
        CROSS JOIN LATERAL (
            SELECT unnest(ARRAY[
                -- Entities
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.entities_parsed) entity
                    WHERE 
                        normalize_arabic(entity->>'name') LIKE '%' || q_norm || '%'
                        OR (
                            SELECT COUNT(*) = array_length(meaningful_words, 1)
                            FROM unnest(meaningful_words) mw
                            WHERE normalize_arabic(entity->>'name') LIKE '%' || normalize_arabic(mw) || '%'
                        )
                        OR EXISTS (
                            SELECT 1 FROM jsonb_array_elements_text(
                                COALESCE(entity->'resolved_from', '[]'::jsonb)
                            ) rf
                            WHERE normalize_arabic(rf) LIKE '%' || q_norm || '%'
                               OR EXISTS (
                                   SELECT 1 FROM unnest(meaningful_words) mw
                                   WHERE normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
                               )
                        )
                ) THEN 'entities' END,
                
                -- Places
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.places_parsed) place
                    WHERE position(q_norm IN normalize_arabic(place->>'name')) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(place->>'name')) > 0
                       )
                ) THEN 'places' END,
                
                -- Subjects
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.subjects_parsed) subject
                    WHERE position(q_norm IN normalize_arabic(subject->>'subject')) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(subject->>'subject')) > 0
                       )
                ) THEN 'subjects' END,
                
                -- Events
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.events_parsed) event
                    WHERE position(q_norm IN normalize_arabic(event->>'event')) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(event->>'event')) > 0
                       )
                ) THEN 'events' END,
                
                -- Religion
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.religion_parsed) rel
                    WHERE position(q_norm IN normalize_arabic(rel->>'religion')) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(rel->>'religion')) > 0
                       )
                ) THEN 'religion' END,
                
                -- Animals
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.animals_parsed) animal
                    WHERE position(q_norm IN normalize_arabic(animal->>'name')) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(animal->>'name')) > 0
                       )
                ) THEN 'animals' END,
                
                -- Sentiments
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(pm.sentiments_parsed) sent
                    WHERE position(q_norm IN normalize_arabic(sent->>'sentiment')) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(sent->>'sentiment')) > 0
                       )
                ) THEN 'sentiments' END
            ]) AS match_type
        ) metadata
        WHERE metadata.match_type IS NOT NULL
        GROUP BY pm.id
    ),
    
    -- =====================================================
    -- RRF COMBINATION
    -- =====================================================
    combined AS (
        SELECT
            COALESCE(fts.id, trgm.id, exact.id, sem.id, meta.id) AS id,
            
            COALESCE(1.0 / (rrf_k + fts.rank_ix), 0.0) * fts_weight AS fts_rrf,
            COALESCE(1.0 / (rrf_k + trgm.rank_ix), 0.0) * trigram_weight AS trigram_rrf,
            COALESCE(1.0 / (rrf_k + exact.rank_ix), 0.0) * exact_weight AS exact_rrf,
            COALESCE(1.0 / (rrf_k + sem.rank_ix), 0.0) * semantic_weight AS semantic_rrf,
            
            COALESCE(fts.score, 0.0) AS fts_raw,
            COALESCE(trgm.score, 0.0) AS trigram_raw,
            COALESCE(exact.has_exact_match, FALSE) AS exact_matched,
            COALESCE(sem.score, 0.0) AS semantic_raw,
            
            COALESCE(meta.matched_fields, ARRAY[]::TEXT[]) AS metadata_fields
            
        FROM fts_results fts
        FULL OUTER JOIN trigram_results trgm ON fts.id = trgm.id
        FULL OUTER JOIN exact_results exact ON COALESCE(fts.id, trgm.id) = exact.id
        FULL OUTER JOIN semantic_results sem ON COALESCE(fts.id, trgm.id, exact.id) = sem.id
        FULL OUTER JOIN metadata_matches meta ON COALESCE(fts.id, trgm.id, exact.id, sem.id) = meta.id
    )
    
    -- =====================================================
    -- FINAL SCORING & RETURN
    -- =====================================================
    SELECT
        pm.id,
        pm.content,
        pm.metadata,
        split_part(pm.content, '---', 2) AS summary_text,
        
        ((c.fts_rrf + c.trigram_rrf + c.exact_rrf + c.semantic_rrf) * 100)::FLOAT AS final_score,
        
        (c.fts_rrf + c.trigram_rrf + c.exact_rrf + c.semantic_rrf)::FLOAT AS rrf_score,
        c.fts_raw::FLOAT AS fts_rank,
        c.trigram_raw::FLOAT AS trigram_sim,
        c.exact_matched AS exact_match,
        c.semantic_raw::FLOAT AS semantic_sim,
        c.metadata_fields::TEXT[] AS matched_in
        
    FROM combined c
    JOIN parsed_metadata pm ON pm.id = c.id
    ORDER BY final_score DESC
    LIMIT LEAST(match_count, 30);
END;
$$;