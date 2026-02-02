-- =====================================================
-- HYBRID SEARCH - COMPLETE IMPLEMENTATION
-- Combines: FTS + Trigram + Exact + Semantic + Metadata
-- Based on: Your proven architecture + Supabase RRF pattern
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
    
    -- Filter out common particles (your approach)
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
    -- SIGNAL 1: FULL-TEXT SEARCH (FTS)
    -- =====================================================
    fts_results AS (
        SELECT
            d.id,
            ROW_NUMBER() OVER(ORDER BY ts_rank_cd(d.fts, websearch_to_tsquery('arabic', query_text)) DESC) AS rank_ix,
            ts_rank_cd(d.fts, websearch_to_tsquery('arabic', query_text))::FLOAT AS score
        FROM documents d
        WHERE d.fts @@ websearch_to_tsquery('arabic', query_text)
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 2: TRIGRAM SIMILARITY (Fuzzy)
    -- =====================================================
    trigram_results AS (
        SELECT
            d.id,
            ROW_NUMBER() OVER(ORDER BY 
                GREATEST(
                    similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm),
                    similarity(normalize_arabic(d.metadata->>'title_cleaned'), q_norm)
                ) DESC
            ) AS rank_ix,
            GREATEST(
                similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm),
                similarity(normalize_arabic(d.metadata->>'title_cleaned'), q_norm)
            )::FLOAT AS score
        FROM documents d
        WHERE 
            similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm) > 0.1
            OR similarity(normalize_arabic(d.metadata->>'title_cleaned'), q_norm) > 0.1
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 3: EXACT PHRASE MATCHING (Your approach)
    -- =====================================================
    exact_results AS (
        SELECT
            d.id,
            ROW_NUMBER() OVER(ORDER BY 
                CASE 
                    -- Entity name exact match = highest priority
                    WHEN EXISTS (
                        SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e 
                        WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                    ) THEN 1
                    -- Title exact phrase
                    WHEN normalize_arabic(d.metadata->>'title_cleaned') LIKE '%' || q_norm || '%' THEN 2
                    -- Poem lines exact phrase (after '---')
                    WHEN normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%' THEN 3
                    -- Title contains all meaningful words
                    WHEN (
                        SELECT COUNT(*) = array_length(meaningful_words, 1)
                        FROM unnest(meaningful_words) mw
                        WHERE position(normalize_arabic(mw) IN normalize_arabic(d.metadata->>'title_cleaned')) > 0
                    ) THEN 4
                    -- Poem lines contain all meaningful words
                    WHEN (
                        SELECT COUNT(*) = array_length(meaningful_words, 1)
                        FROM unnest(meaningful_words) mw
                        WHERE position(normalize_arabic(mw) IN normalize_arabic(split_part(d.content, '---', 2))) > 0
                    ) THEN 5
                    ELSE 6
                END
            ) AS rank_ix,
            CASE 
                WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e 
                    WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                ) THEN TRUE
                WHEN normalize_arabic(d.metadata->>'title_cleaned') LIKE '%' || q_norm || '%' THEN TRUE
                WHEN normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%' THEN TRUE
                ELSE FALSE
            END AS has_exact_match
        FROM documents d
        WHERE 
            EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e 
                WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
            )
            OR normalize_arabic(d.metadata->>'title_cleaned') LIKE '%' || q_norm || '%'
            OR normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%'
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) mw
                WHERE position(normalize_arabic(mw) IN normalize_arabic(split_part(d.content, '---', 2))) > 0
            )
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 4: SEMANTIC/VECTOR SEARCH
    -- =====================================================
    semantic_results AS (
        SELECT
            d.id,
            ROW_NUMBER() OVER(ORDER BY d.embedding <#> query_embedding) AS rank_ix,
            (1 - (d.embedding <=> query_embedding))::FLOAT AS score
        FROM documents d
        WHERE d.embedding IS NOT NULL
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 5: METADATA MATCHING (Your proven approach)
    -- Score: 60 per metadata field match
    -- =====================================================
    metadata_matches AS (
        SELECT
            d.id,
            ARRAY_AGG(DISTINCT match_type) AS matched_fields
        FROM documents d
        CROSS JOIN LATERAL (
            SELECT unnest(ARRAY[
                -- Entities (highest priority)
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') entity
                    WHERE 
                        -- Exact name match
                        normalize_arabic(entity->>'name') LIKE '%' || q_norm || '%'
                        -- OR all meaningful words from query appear in entity name
                        OR (
                            SELECT COUNT(*) = array_length(meaningful_words, 1)
                            FROM unnest(meaningful_words) mw
                            WHERE normalize_arabic(entity->>'name') LIKE '%' || normalize_arabic(mw) || '%'
                        )
                        -- OR resolved_from contains any query word
                        OR EXISTS (
                            SELECT 1 FROM jsonb_array_elements_text(entity->'resolved_from') rf
                            WHERE normalize_arabic(rf) LIKE '%' || q_norm || '%'
                               OR EXISTS (
                                   SELECT 1 FROM unnest(meaningful_words) mw
                                   WHERE normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
                               )
                        )
                ) THEN 'entities' END,
                
                -- Places
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'places') place
                    WHERE position(q_norm IN normalize_arabic(place->>'name')) > 0
                       OR position(q_norm IN normalize_arabic(place->>'resolved_from')) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(place->>'name')) > 0
                              OR position(normalize_arabic(mw) IN normalize_arabic(place->>'resolved_from')) > 0
                       )
                ) THEN 'places' END,
                
                -- Subjects
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(d.metadata->'subjects') subject
                    WHERE position(q_norm IN normalize_arabic(subject)) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(subject)) > 0
                       )
                ) THEN 'subjects' END,
                
                -- Events
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(d.metadata->'events') event
                    WHERE position(q_norm IN normalize_arabic(event)) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(event)) > 0
                       )
                ) THEN 'events' END,
                
                -- Religion
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(d.metadata->'religion') rel
                    WHERE position(q_norm IN normalize_arabic(rel)) > 0
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(rel)) > 0
                       )
                ) THEN 'religion' END,
                
                -- Animals
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'animals') animal
                    WHERE position(q_norm IN normalize_arabic(animal->>'name')) > 0
                       OR EXISTS (
                           SELECT 1 FROM jsonb_array_elements_text(animal->'resolved_from') rf
                           WHERE position(q_norm IN normalize_arabic(rf)) > 0
                       )
                       OR EXISTS (
                           SELECT 1 FROM unnest(meaningful_words) mw
                           WHERE position(normalize_arabic(mw) IN normalize_arabic(animal->>'name')) > 0
                              OR EXISTS (
                                  SELECT 1 FROM jsonb_array_elements_text(animal->'resolved_from') rf
                                  WHERE position(normalize_arabic(mw) IN normalize_arabic(rf)) > 0
                              )
                       )
                ) THEN 'animals' END,
                
                -- Sentiments
                CASE WHEN position(q_norm IN normalize_arabic(COALESCE(d.metadata->>'sentiments', ''))) > 0
                    OR EXISTS (
                        SELECT 1 FROM unnest(meaningful_words) mw
                        WHERE position(normalize_arabic(mw) IN normalize_arabic(COALESCE(d.metadata->>'sentiments', ''))) > 0
                    )
                THEN 'sentiments' END
            ]) AS match_type
        ) metadata
        WHERE metadata.match_type IS NOT NULL
        GROUP BY d.id
    ),
    
    -- =====================================================
    -- RRF COMBINATION (Supabase pattern)
    -- =====================================================
    combined AS (
        SELECT
            COALESCE(fts.id, trgm.id, exact.id, sem.id, meta.id) AS id,
            
            -- RRF scores
            COALESCE(1.0 / (rrf_k + fts.rank_ix), 0.0) * fts_weight AS fts_rrf,
            COALESCE(1.0 / (rrf_k + trgm.rank_ix), 0.0) * trigram_weight AS trigram_rrf,
            COALESCE(1.0 / (rrf_k + exact.rank_ix), 0.0) * exact_weight AS exact_rrf,
            COALESCE(1.0 / (rrf_k + sem.rank_ix), 0.0) * semantic_weight AS semantic_rrf,
            
            -- Raw scores
            COALESCE(fts.score, 0.0) AS fts_raw,
            COALESCE(trgm.score, 0.0) AS trigram_raw,
            COALESCE(exact.has_exact_match, FALSE) AS exact_matched,
            COALESCE(sem.score, 0.0) AS semantic_raw,
            
            -- Metadata
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
        d.id,
        d.content,
        d.metadata,
        
        -- Final score: RRF * 100 + metadata boost (60 per field)
        -- ((c.fts_rrf + c.trigram_rrf + c.exact_rrf + c.semantic_rrf) * 100 + 
        --  COALESCE(array_length(c.metadata_fields, 1), 0) * 60)::FLOAT AS final_score,
        ((c.fts_rrf + c.trigram_rrf + c.exact_rrf + c.semantic_rrf) * 100)::FLOAT AS final_score,
        
        -- Score breakdown
        (c.fts_rrf + c.trigram_rrf + c.exact_rrf + c.semantic_rrf)::FLOAT AS rrf_score,
        c.fts_raw::FLOAT AS fts_rank,
        c.trigram_raw::FLOAT AS trigram_sim,
        c.exact_matched AS exact_match,
        c.semantic_raw::FLOAT AS semantic_sim,
        c.metadata_fields::TEXT[] AS matched_in
        
    FROM combined c
    JOIN documents d ON d.id = c.id
    ORDER BY final_score DESC
    LIMIT LEAST(match_count, 30);
END;
$$;

-- =====================================================
-- USAGE EXAMPLE
-- =====================================================
-- SELECT * FROM hybrid_search(
--     'محمد بن زايد',                          -- query text
--     '[0.1, 0.2, ..., 0.3]'::vector(1536),  -- query embedding
--     20,                                      -- match_count
--     0.4,                                     -- fts_weight
--     0.3,                                     -- trigram_weight
--     0.6,                                     -- exact_weight
--     1.0,                                     -- semantic_weight
--     50                                       -- rrf_k
-- );