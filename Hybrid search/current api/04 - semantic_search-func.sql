-- =====================================================
-- ENHANCED HYBRID SEARCH WITH SUMMARY EMBEDDINGS
-- Signals: Content FTS + Content Trigram + Content Semantic +
--          Summary FTS + Summary Semantic + Exact Match + Metadata
-- =====================================================
DROP FUNCTION IF EXISTS hybrid_search CASCADE;
CREATE OR REPLACE FUNCTION hybrid_search(
query_text TEXT,
query_embedding vector(1536),
summary_embedding vector(1536) DEFAULT NULL,
match_count INT DEFAULT 20,
-- Content weights (45% total)
content_fts_weight FLOAT DEFAULT 0.15,
content_trigram_weight FLOAT DEFAULT 0.10,
content_semantic_weight FLOAT DEFAULT 0.20,

-- Summary weights (15% total)
summary_fts_weight FLOAT DEFAULT 0.05,
summary_semantic_weight FLOAT DEFAULT 0.10,

-- Metadata weights (30% total)
entity_weight FLOAT DEFAULT 0.10,
subject_weight FLOAT DEFAULT 0.08,
place_weight FLOAT DEFAULT 0.05,
event_weight FLOAT DEFAULT 0.04,
religion_weight FLOAT DEFAULT 0.03,

-- Exact match bonus (10% total)
exact_weight FLOAT DEFAULT 0.10,

rrf_k INT DEFAULT 50
)
RETURNS TABLE(
id BIGINT,
content TEXT,
summary TEXT,
metadata JSONB,
-- Scoring breakdown
final_score FLOAT,
rrf_score FLOAT,

-- Content scores
content_fts_rank FLOAT,
content_trigram_sim FLOAT,
content_semantic_sim FLOAT,

-- Summary scores
summary_fts_rank FLOAT,
summary_semantic_sim FLOAT,

-- Metadata scores
entity_match FLOAT,
subject_match FLOAT,
place_match FLOAT,
event_match FLOAT,
religion_match FLOAT,

-- Other
exact_match BOOLEAN,
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
-- SIGNAL 1: CONTENT FTS
-- =====================================================
content_fts_results AS (
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
-- SIGNAL 2: CONTENT TRIGRAM
-- =====================================================
content_trigram_results AS  (
    SELECT
        d.id,
        ROW_NUMBER() OVER(ORDER BY 
            GREATEST(
                similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm),
                 similarity(normalize_arabic(d.metadata->>'Title_raw'), q_norm)
            ) DESC
        ) AS rank_ix,
        GREATEST(
            similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm),
            similarity(normalize_arabic(d.metadata->>'Title_raw'), q_norm)
        )::FLOAT AS score
    FROM documents d
    WHERE 
        similarity(normalize_arabic(split_part(d.content, '---', 2)), q_norm) > 0.1
        OR similarity(normalize_arabic(d.metadata->>'Title_raw'), q_norm) > 0.1
    ORDER BY rank_ix
    LIMIT LEAST(match_count, 30) * 3
),

-- =====================================================
-- SIGNAL 3: CONTENT SEMANTIC
-- =====================================================
content_semantic_results AS (
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
-- SIGNAL 4: SUMMARY FTS
-- =====================================================
summary_fts_results AS (
    SELECT
        d.id,
        ROW_NUMBER() OVER(ORDER BY ts_rank_cd(d.summary_fts, websearch_to_tsquery('arabic', query_text)) DESC) AS rank_ix,
        ts_rank_cd(d.summary_fts, websearch_to_tsquery('arabic', query_text))::FLOAT AS score
    FROM documents d
    WHERE d.summary_fts @@ websearch_to_tsquery('arabic', query_text)
      AND d.summary_fts IS NOT NULL
    ORDER BY rank_ix
    LIMIT LEAST(match_count, 30) * 3
),

-- =====================================================
-- SIGNAL 5: SUMMARY SEMANTIC
-- =====================================================
summary_semantic_results AS (
    SELECT
        d.id,
        ROW_NUMBER() OVER(ORDER BY d.summary_embedding <#> $3) AS rank_ix,
        (1 - (d.summary_embedding <=> $3))::FLOAT AS score
    FROM documents d
    WHERE d.summary_embedding IS NOT NULL
      AND $3 IS NOT NULL
    ORDER BY rank_ix
    LIMIT LEAST(match_count, 30) * 3
),

-- =====================================================
-- SIGNAL 6: EXACT PHRASE MATCHING
-- =====================================================
exact_results AS (
    SELECT
        d.id,
        ROW_NUMBER() OVER(ORDER BY 
            CASE 
                -- Entity name exact match = highest priority
                WHEN EXISTS  (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e 
                    WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                ) THEN 1
                -- Title exact phrase
                WHEN normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%' THEN 2
                -- Summary exact phrase
                WHEN normalize_arabic(d.summary) LIKE '%' || q_norm || '%' THEN 3
                 -- Poem lines exact phrase
                WHEN normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%' THEN 4
                -- Title contains all meaningful words
                WHEN (
                    SELECT COUNT(*) = array_length(meaningful_words, 1)
                    FROM unnest(meaningful_words) mw
                    WHERE position(normalize_arabic(mw) IN normalize_arabic(d.metadata->>'Title_raw')) > 0
                ) THEN 5
                ELSE 6
            END
        ) AS rank_ix,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements (d.metadata->'entities') e 
                WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
            ) THEN TRUE
            WHEN normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%' THEN TRUE
            WHEN normalize_arabic(d.summary) LIKE '%' || q_norm || '%' THEN TRUE
            WHEN normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%' THEN TRUE
            ELSE FALSE
        END AS has_exact_match
    FROM documents d
    WHERE 
        EXISTS (
            SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e 
            WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
        )
        OR normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%'
        OR normalize_arabic(d.summary) LIKE '%' || q_norm || '%'
        OR normalize_arabic(split_part(d.content, '---', 2)) LIKE '%' || q_norm || '%'
        OR EXISTS (
            SELECT 1 FROM unnest(meaningful_words) mw
            WHERE position(normalize_arabic(mw) IN normalize_arabic(d.metadata->>'Title_raw')) > 0
               OR position(normalize_arabic(mw) IN normalize_arabic(d.summary)) > 0
        )
    ORDER BY rank_ix
    LIMIT LEAST(match_count, 30) * 3
),

-- =====================================================
-- SIGNAL 7: METADATA MATCHING
-- =====================================================
metadata_matches AS (
    SELECT
        d.id,
        ARRAY_AGG(DISTINCT match_type) AS matched_fields
    FROM documents d
    CROSS JOIN  LATERAL (
        SELECT unnest(ARRAY[
            -- Entities
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') entity
                WHERE 
                    normalize_arabic(entity->>'name') LIKE '%' || q_norm || '%'
                    OR (
                        SELECT COUNT(*) = array_length(meaningful_words, 1)
                        FROM unnest(meaningful_words) mw
                        WHERE normalize_arabic(entity->>'name') LIKE '%' || normalize_arabic(mw) || '%'
                    )
            ) THEN 'entities' END,
            
            -- Places
            CASE WHEN EXISTS (
                 SELECT 1 FROM jsonb_array_elements(d.metadata->'places') place
                WHERE position(q_norm IN normalize_arabic(place->>'name')) > 0
                   OR EXISTS (
                       SELECT 1 FROM unnest(meaningful_words) mw
                       WHERE position(normalize_arabic(mw) IN normalize_arabic(place->>'name')) > 0
                   )
            ) THEN 'places' END,
            
            -- Subjects
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'subjects') subj
                WHERE position(q_norm IN normalize_arabic(subj->>'subject')) > 0
                   OR EXISTS (
                       SELECT 1 FROM unnest(meaningful_words) mw
                       WHERE position(normalize_arabic(mw) IN normalize_arabic(subj->>'subject')) > 0
                   )
            ) THEN 'subjects' END,
            
            -- Events
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'events') evt
                WHERE position(q_norm IN normalize_arabic(evt->>'event')) > 0
                   OR EXISTS (
                       SELECT 1 FROM unnest(meaningful_words) mw
                       WHERE position(normalize_arabic(mw) IN normalize_arabic(evt->>'event')) > 0
                   )
            ) THEN 'events' END,
            
            -- Religion
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'religion') rel
                WHERE position(q_norm IN normalize_arabic(rel->>'religion')) > 0
                   OR EXISTS (
                       SELECT 1 FROM unnest(meaningful_words) mw
                       WHERE position(normalize_arabic(mw) IN normalize_arabic(rel->>'religion')) > 0
                   )
            ) THEN 'religion' END,
            
            -- Animals
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'animals') animal
                WHERE position(q_norm IN normalize_arabic(animal->>'name')) > 0
            ) THEN 'animals' END,
            
            -- Sentiments
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'sentiments') sent
                WHERE position(q_norm IN normalize_arabic(sent->>'sentiment')) > 0
            ) THEN 'sentiments' END
        ]) AS match_type
    ) metadata
    WHERE metadata.match_type IS NOT NULL
    GROUP BY d.id
),

-- =====================================================
-- RRF COMBINATION
-- =====================================================
combined AS (
    SELECT
        COALESCE(
            content_fts.id, 
            content_trgm.id, 
            content_sem.id,
            summary_fts.id,
            summary_sem.id,
            exact.id, 
            meta.id
        ) AS id,
        
         -- Content RRF signals (45%)
        COALESCE(1.0 / (rrf_k + content_fts.rank_ix), 0.0) * content_fts_weight AS content_fts_rrf,
        COALESCE(1.0 / (rrf_k + content_trgm.rank_ix), 0.0) * content_trigram_weight AS content_trigram_rrf,
        COALESCE(1.0 / (rrf_k + content_sem.rank_ix), 0.0) * content_semantic_weight AS content_semantic_rrf,
        
         -- Summary RRF signals (15%)
        COALESCE(1.0 / (rrf_k + summary_fts.rank_ix), 0.0) * summary_fts_weight AS summary_fts_rrf,
        COALESCE(1.0 / (rrf_k + summary_sem.rank_ix), 0.0) * summary_semantic_weight AS summary_semantic_rrf,
        
        -- Exact match RRF (10%)
        COALESCE(1.0 / (rrf_k + exact.rank_ix), 0.0) * exact_weight AS exact_rrf,
        
        -- Metadata signals (30%)
        CASE WHEN 'entities' = ANY(meta.matched_fields) THEN entity_weight ELSE 0 END AS entity_match,
        CASE WHEN 'subjects' = ANY(meta.matched_fields) THEN subject_weight ELSE 0 END AS subject_match,
        CASE WHEN 'places' = ANY(meta.matched_fields) THEN place_weight ELSE 0 END AS place_match,
         CASE WHEN 'events' = ANY(meta.matched_fields) THEN event_weight ELSE 0 END AS event_match,
        CASE WHEN 'religion' = ANY(meta.matched_fields) THEN religion_weight ELSE 0 END AS religion_match,
        
        -- Raw scores for debugging
        COALESCE(content_fts.score, 0.0) AS content_fts_raw,
        COALESCE(content_trgm.score, 0.0) AS content_trigram_raw,
        COALESCE(content_sem.score, 0.0) AS content_semantic_raw,
        COALESCE(summary_fts.score, 0.0) AS summary_fts_raw,
        COALESCE(summary_sem.score, 0.0) AS summary_semantic_raw,
        COALESCE(exact.has_exact_match, FALSE) AS exact_matched,
        
        COALESCE(meta.matched_fields, ARRAY[]::TEXT[]) AS metadata_fields
         
    FROM content_fts_results content_fts
    FULL OUTER JOIN content_trigram_results content_trgm 
        ON content_fts.id = content_trgm.id
    FULL OUTER JOIN content_semantic_results content_sem 
        ON COALESCE(content_fts.id, content_trgm.id) = content_sem.id
    FULL OUTER JOIN summary_fts_results summary_fts 
        ON COALESCE(content_fts.id, content_trgm.id, content_sem.id) = summary_fts.id
    FULL OUTER JOIN summary_semantic_results summary_sem 
        ON COALESCE(content_fts.id, content_trgm.id, content_sem.id, summary_fts.id) = summary_sem.id
    FULL OUTER JOIN exact_results exact 
        ON COALESCE(content_fts.id, content_trgm.id, content_sem.id, summary_fts.id, summary_sem.id) = exact.id
    FULL OUTER JOIN metadata_matches meta 
        ON COALESCE(content_fts.id, content_trgm.id, content_sem.id, summary_fts.id, summary_sem.id, exact.id) = meta.id
)

-- =====================================================
-- FINAL SCORING  & RETURN
-- =====================================================
SELECT
    d.id,
    d.content,
    d.summary,
    d.metadata,
    
    -- Final score = sum of all weighted RRF signals + metadata matches
    ((c.content_fts_rrf + c.content_trigram_rrf + c.content_semantic_rrf +
      c.summary_fts_rrf + c.summary_semantic_rrf + c.exact_rrf +
      c.entity_match + c.subject_match + c.place_match + c.event_match + c.religion_match
    ) * 100)::FLOAT AS final_score,
    
    -- Total RRF score (for debugging)
    (c.content_fts_rrf + c.content_trigram_rrf + c.content_semantic_rrf +
     c.summary_fts_rrf + c.summary_semantic_rrf + c.exact_rrf)::FLOAT AS rrf_score,
    
    -- Content scores
    c.content_fts_raw::FLOAT AS content_fts_rank,
    c.content_trigram_raw::FLOAT AS content_trigram_sim,
    c.content_semantic_raw::FLOAT AS content_semantic_sim,
    
    -- Summary scores
    c.summary_fts_raw::FLOAT AS summary_fts_rank,
    c.summary_semantic_raw::FLOAT AS summary_semantic_sim,
    
    -- Metadata scores
    c.entity_match::FLOAT AS entity_match,
    c.subject_match::FLOAT AS subject_match,
    c.place_match::FLOAT AS place_match,
    c.event_match::FLOAT AS event_match,
    c.religion_match::FLOAT AS religion_match,
    
    -- Other
    c.exact_matched AS exact_match,
    c.metadata_fields::TEXT[] AS matched_in
    
FROM combined c
JOIN documents d ON d.id = c.id
ORDER BY final_score DESC
LIMIT match_count;
END;
$$;
-- =====================================================
-- USAGE EXAMPLE
-- =====================================================
-- SELECT * FROM hybrid_search(
--     'محمد بن زايد',
--     '[0.1, 0.2, ..., 0.3]'::vector(1536),  -- query_embedding
--     '[0.1, 0.2, ..., 0.3]'::vector(1536),  -- summary_embedding
--     20,                                      -- match_count
--     0.15,                                    -- content_fts_weight
--     0.10,                                    -- content_trigram_weight
--     0.20,                                    -- content_semantic_weight
--     0.05,                                    -- summary_fts_weight
--     0.10,                                    -- summary_semantic_weight
--     0.10,                                    -- entity_weight
--     0.08,                                    -- subject_weight
--     0.05,                                    -- place_weight
--     0.04,                                    -- event_weight
--     0.03,                                    -- religion_weight
--     0.10,                                    -- exact_weight
--     50                                       -- rrf_k
-- );