-- =====================================================
-- HYBRID SEARCH - NEW DATA STRUCTURE
-- Handles escaped JSON metadata + resolved_from logic
-- =====================================================

DROP FUNCTION IF EXISTS hybrid_search CASCADE;

-- Helper function to parse escaped JSON metadata
CREATE OR REPLACE FUNCTION parse_metadata_json(escaped_json TEXT)
RETURNS JSONB AS $$
BEGIN
    IF escaped_json IS NULL OR escaped_json = '' THEN
        RETURN '[]'::jsonb;
    END IF;
    
    -- Remove outer braces and extract inner JSON
    -- Format: {"key":"[{...}]"} -> [{...}]
    RETURN (escaped_json::jsonb -> (SELECT jsonb_object_keys(escaped_json::jsonb) LIMIT 1))::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Helper function to extract all resolved_from texts
CREATE OR REPLACE FUNCTION extract_resolved_from(metadata_array JSONB)
RETURNS TEXT[] AS $$
BEGIN
    IF metadata_array IS NULL OR jsonb_array_length(metadata_array) = 0 THEN
        RETURN ARRAY[]::TEXT[];
    END IF;
    
    RETURN ARRAY(
        SELECT DISTINCT unnest(
            ARRAY(
                SELECT jsonb_array_elements_text(elem->'resolved_from')
                FROM jsonb_array_elements(metadata_array) elem
                WHERE elem ? 'resolved_from'
            )
        )
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

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
    matched_in TEXT[],
    
    -- Highlighting data
    matched_resolved_from JSONB
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
                    similarity(normalize_arabic(d.metadata->>'Title_raw'), q_norm),
                    similarity(normalize_arabic(split_part(d.content, '---', 1)), q_norm)
                ) DESC
            ) AS rank_ix,
            GREATEST(
                similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm),
                similarity(normalize_arabic(d.metadata->>'Title_raw'), q_norm),
                similarity(normalize_arabic(split_part(d.content, '---', 1)), q_norm)
            )::FLOAT AS score
        FROM documents d
        WHERE 
            similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm) > 0.1
            OR similarity(normalize_arabic(d.metadata->>'Title_raw'), q_norm) > 0.1
            OR similarity(normalize_arabic(split_part(d.content, '---', 1)), q_norm) > 0.1
        ORDER BY rank_ix
        LIMIT LEAST(match_count, 30) * 3
    ),
    
    -- =====================================================
    -- SIGNAL 3: EXACT PHRASE MATCHING
    -- Now includes Summary and resolved_from matching
    -- =====================================================
    exact_results AS (
        SELECT
            d.id,
            ROW_NUMBER() OVER(ORDER BY 
                CASE 
                    -- Summary exact match = highest priority (50 pts later)
                    WHEN normalize_arabic(split_part(d.content, '---', 1)) LIKE '%' || q_norm || '%' THEN 1
                    -- Title exact phrase
                    WHEN normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%' THEN 2
                    -- Entity name or resolved_from exact match
                    WHEN EXISTS (
                        SELECT 1 FROM jsonb_array_elements(parse_metadata_json(d.metadata->>'entities')) e 
                        WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                           OR EXISTS (
                               SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf
                               WHERE normalize_arabic(rf) LIKE '%' || q_norm || '%'
                           )
                    ) THEN 3
                    -- Poem lines exact phrase
                    WHEN normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%' THEN 4
                    -- Other metadata resolved_from matches
                    WHEN EXISTS (
                        SELECT 1 FROM jsonb_array_elements(
                            parse_metadata_json(d.metadata->>'places') ||
                            parse_metadata_json(d.metadata->>'events') ||
                            parse_metadata_json(d.metadata->>'religion') ||
                            parse_metadata_json(d.metadata->>'subjects')
                        ) m
                        WHERE EXISTS (
                            SELECT 1 FROM jsonb_array_elements_text(m->'resolved_from') rf
                            WHERE normalize_arabic(rf) LIKE '%' || q_norm || '%'
                        )
                    ) THEN 5
                    ELSE 6
                END
            ) AS rank_ix,
            CASE 
                WHEN normalize_arabic(split_part(d.content, '---', 1)) LIKE '%' || q_norm || '%' THEN TRUE
                WHEN normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%' THEN TRUE
                WHEN normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%' THEN TRUE
                ELSE FALSE
            END AS has_exact_match
        FROM documents d
        WHERE 
            normalize_arabic(split_part(d.content, '---', 1)) LIKE '%' || q_norm || '%'
            OR normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%'
            OR normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%'
            OR EXISTS (
                SELECT 1 FROM unnest(meaningful_words) mw
                WHERE normalize_arabic(split_part(d.content, '---', 1)) LIKE '%' || normalize_arabic(mw) || '%'
                   OR normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || normalize_arabic(mw) || '%'
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
    -- SIGNAL 5: METADATA MATCHING
    -- Matches on both 'name/event/religion' and 'resolved_from'
    -- Returns matched resolved_from texts for highlighting
    -- =====================================================
    metadata_matches AS (
        SELECT
            d.id,
            ARRAY_AGG(DISTINCT match_type) FILTER (WHERE match_type IS NOT NULL) AS matched_fields,
            jsonb_object_agg(
                COALESCE(match_type, 'none'),
                matched_texts
            ) FILTER (WHERE match_type IS NOT NULL) AS resolved_from_matches
        FROM documents d
        CROSS JOIN LATERAL (
            -- Entities
            SELECT 
                'entities' as match_type,
                jsonb_agg(DISTINCT rf) as matched_texts
            FROM jsonb_array_elements(parse_metadata_json(d.metadata->>'entities')) entity
            CROSS JOIN LATERAL jsonb_array_elements_text(entity->'resolved_from') rf
            WHERE normalize_arabic(entity->>'name') LIKE '%' || q_norm || '%'
               OR normalize_arabic(rf) LIKE '%' || q_norm || '%'
               OR EXISTS (
                   SELECT 1 FROM unnest(meaningful_words) mw
                   WHERE normalize_arabic(entity->>'name') LIKE '%' || normalize_arabic(mw) || '%'
                      OR normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
               )
            HAVING COUNT(*) > 0
            
            UNION ALL
            
            -- Places
            SELECT 
                'places' as match_type,
                jsonb_agg(DISTINCT rf) as matched_texts
            FROM jsonb_array_elements(parse_metadata_json(d.metadata->>'places')) place
            CROSS JOIN LATERAL jsonb_array_elements_text(place->'resolved_from') rf
            WHERE normalize_arabic(place->>'name') LIKE '%' || q_norm || '%'
               OR normalize_arabic(rf) LIKE '%' || q_norm || '%'
               OR EXISTS (
                   SELECT 1 FROM unnest(meaningful_words) mw
                   WHERE normalize_arabic(place->>'name') LIKE '%' || normalize_arabic(mw) || '%'
                      OR normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
               )
            HAVING COUNT(*) > 0
            
            UNION ALL
            
            -- Events
            SELECT 
                'events' as match_type,
                jsonb_agg(DISTINCT rf) as matched_texts
            FROM jsonb_array_elements(parse_metadata_json(d.metadata->>'events')) event
            CROSS JOIN LATERAL jsonb_array_elements_text(event->'resolved_from') rf
            WHERE normalize_arabic(event->>'event') LIKE '%' || q_norm || '%'
               OR normalize_arabic(rf) LIKE '%' || q_norm || '%'
               OR EXISTS (
                   SELECT 1 FROM unnest(meaningful_words) mw
                   WHERE normalize_arabic(event->>'event') LIKE '%' || normalize_arabic(mw) || '%'
                      OR normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
               )
            HAVING COUNT(*) > 0
            
            UNION ALL
            
            -- Religion
            SELECT 
                'religion' as match_type,
                jsonb_agg(DISTINCT rf) as matched_texts
            FROM jsonb_array_elements(parse_metadata_json(d.metadata->>'religion')) rel
            CROSS JOIN LATERAL jsonb_array_elements_text(rel->'resolved_from') rf
            WHERE normalize_arabic(rel->>'religion') LIKE '%' || q_norm || '%'
               OR normalize_arabic(rf) LIKE '%' || q_norm || '%'
               OR EXISTS (
                   SELECT 1 FROM unnest(meaningful_words) mw
                   WHERE normalize_arabic(rel->>'religion') LIKE '%' || normalize_arabic(mw) || '%'
                      OR normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
               )
            HAVING COUNT(*) > 0
            
            UNION ALL
            
            -- Subjects
            SELECT 
                'subjects' as match_type,
                jsonb_agg(DISTINCT rf) as matched_texts
            FROM jsonb_array_elements(parse_metadata_json(d.metadata->>'subjects')) subj
            CROSS JOIN LATERAL jsonb_array_elements_text(subj->'resolved_from') rf
            WHERE normalize_arabic(subj->>'subject') LIKE '%' || q_norm || '%'
               OR normalize_arabic(rf) LIKE '%' || q_norm || '%'
               OR EXISTS (
                   SELECT 1 FROM unnest(meaningful_words) mw
                   WHERE normalize_arabic(subj->>'subject') LIKE '%' || normalize_arabic(mw) || '%'
                      OR normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
               )
            HAVING COUNT(*) > 0
            
            UNION ALL
            
            -- Animals
            SELECT 
                'animals' as match_type,
                jsonb_agg(DISTINCT rf) as matched_texts
            FROM jsonb_array_elements(parse_metadata_json(d.metadata->>'animals')) animal
            CROSS JOIN LATERAL jsonb_array_elements_text(animal->'resolved_from') rf
            WHERE normalize_arabic(animal->>'name') LIKE '%' || q_norm || '%'
               OR normalize_arabic(rf) LIKE '%' || q_norm || '%'
               OR EXISTS (
                   SELECT 1 FROM unnest(meaningful_words) mw
                   WHERE normalize_arabic(animal->>'name') LIKE '%' || normalize_arabic(mw) || '%'
                      OR normalize_arabic(rf) LIKE '%' || normalize_arabic(mw) || '%'
               )
            HAVING COUNT(*) > 0
        ) matches
        WHERE matches.match_type IS NOT NULL
        GROUP BY d.id
    ),
    
    -- =====================================================
    -- RRF COMBINATION
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
            COALESCE(meta.matched_fields, ARRAY[]::TEXT[]) AS metadata_fields,
            COALESCE(meta.resolved_from_matches, '{}'::jsonb) AS resolved_from_data
            
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
        split_part(d.content, '---', 1)::TEXT AS summary_text,
        
        -- Final score: RRF * 100 (metadata boost done in Edge function)
        ((c.fts_rrf + c.trigram_rrf + c.exact_rrf + c.semantic_rrf) * 100)::FLOAT AS final_score,
        
        -- Score breakdown
        (c.fts_rrf + c.trigram_rrf + c.exact_rrf + c.semantic_rrf)::FLOAT AS rrf_score,
        c.fts_raw::FLOAT AS fts_rank,
        c.trigram_raw::FLOAT AS trigram_sim,
        c.exact_matched AS exact_match,
        c.semantic_raw::FLOAT AS semantic_sim,
        c.metadata_fields::TEXT[] AS matched_in,
        c.resolved_from_data::JSONB AS matched_resolved_from
        
    FROM combined c
    JOIN documents d ON d.id = c.id
    ORDER BY final_score DESC
    LIMIT LEAST(match_count, 30);
END;
$$;
