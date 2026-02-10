-- =====================================================
-- HYBRID SEARCH - OPUS FIXED VERSION
-- 
-- KEY FIXES from Opus Analysis:
-- 1. ✅ Restored independent summary_semantic_results CTE
-- 2. ✅ Added WHERE filter to metadata_matches (no full table scan)
-- 3. ✅ Removed circular FTS self-verification from metadata
-- 4. ✅ Uses clean context_query embedding (from Edge Function)
-- 5. ✅ Adjusted default weights (semantic up, metadata down)
-- =====================================================

CREATE OR REPLACE FUNCTION public.hybrid_search_opus(
    query_text TEXT,
    context_query_text TEXT,
    query_embedding VECTOR(1536),
    focused_embedding VECTOR(1536),
    summary_embedding VECTOR(1536),
    extracted_entities TEXT[] DEFAULT ARRAY[]::TEXT[],
    extracted_places TEXT[] DEFAULT ARRAY[]::TEXT[],
    extracted_subjects TEXT[] DEFAULT ARRAY[]::TEXT[],
    extracted_events TEXT[] DEFAULT ARRAY[]::TEXT[],
    match_count INTEGER DEFAULT 20,
    
    -- SEMANTIC-FIRST default weights
    content_fts_weight FLOAT DEFAULT 0.08,
    content_trigram_weight FLOAT DEFAULT 0.05,
    content_semantic_weight FLOAT DEFAULT 0.35,  -- BOOSTED from 0.25
    summary_fts_weight FLOAT DEFAULT 0.03,
    summary_semantic_weight FLOAT DEFAULT 0.25,  -- BOOSTED from 0.15
    entity_weight FLOAT DEFAULT 0.06,
    subject_weight FLOAT DEFAULT 0.04,
    place_weight FLOAT DEFAULT 0.03,
    event_weight FLOAT DEFAULT 0.01,
    religion_weight FLOAT DEFAULT 0.01,
    exact_weight FLOAT DEFAULT 0.09,
    
    rrf_k INTEGER DEFAULT 50
)
RETURNS TABLE(
    id BIGINT,
    content TEXT,
    summary TEXT,
    metadata JSONB,
    final_score FLOAT,
    rrf_score FLOAT,
    
    content_fts_rank FLOAT,
    content_trigram_sim FLOAT,
    content_semantic_sim FLOAT,
    
    summary_fts_rank FLOAT,
    summary_semantic_sim FLOAT,
    
    entity_match FLOAT,
    subject_match FLOAT,
    place_match FLOAT,
    event_match FLOAT,
    religion_match FLOAT,
    
    exact_match BOOLEAN,
    matched_in TEXT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    q_norm TEXT;
    ctx_norm TEXT;
    query_words TEXT[];
    meaningful_words TEXT[];
    current_word TEXT;
BEGIN
    -- Normalize both queries
    q_norm := TRIM(normalize_arabic(query_text));
    ctx_norm := TRIM(normalize_arabic(context_query_text));
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
    -- SIGNAL 1: CONTENT FTS (MULTIVERSE SEARCH!)
    -- Searches with: query + context_query + all extracted entities
    -- =====================================================
    content_fts_results AS (
        SELECT
            ranked.id,
            ROW_NUMBER() OVER(ORDER BY ranked.max_rank DESC) AS rank_ix,
            ranked.max_rank AS score
        FROM (
            SELECT
                d.id,
                GREATEST(
                    -- Original queries
                    ts_rank_cd(d.fts, websearch_to_tsquery('arabic', query_text)),
                    ts_rank_cd(d.fts, websearch_to_tsquery('arabic', context_query_text)),
                    
                    -- Entity names (if provided)
                    COALESCE((
                        SELECT MAX(ts_rank_cd(d.fts, plainto_tsquery('arabic', entity)))
                        FROM unnest(extracted_entities) AS entity
                        WHERE entity IS NOT NULL AND entity != ''
                    ), 0),
                    
                    -- Subject names (if provided)
                    COALESCE((
                        SELECT MAX(ts_rank_cd(d.fts, plainto_tsquery('arabic', subject)))
                        FROM unnest(extracted_subjects) AS subject
                        WHERE subject IS NOT NULL AND subject != ''
                    ), 0),
                    
                    -- Place names (if provided)
                    COALESCE((
                        SELECT MAX(ts_rank_cd(d.fts, plainto_tsquery('arabic', place)))
                        FROM unnest(extracted_places) AS place
                        WHERE place IS NOT NULL AND place != ''
                    ), 0)
                ) AS max_rank
            FROM documents d
            WHERE 
                d.fts @@ websearch_to_tsquery('arabic', query_text)
                OR d.fts @@ websearch_to_tsquery('arabic', context_query_text)
                OR (
                    -- Match ANY extracted entity
                    array_length(extracted_entities, 1) > 0 AND
                    EXISTS (
                        SELECT 1 FROM unnest(extracted_entities) AS entity
                        WHERE d.fts @@ plainto_tsquery('arabic', entity)
                    )
                )
                OR (
                    -- Match ANY extracted subject
                    array_length(extracted_subjects, 1) > 0 AND
                    EXISTS (
                        SELECT 1 FROM unnest(extracted_subjects) AS subject
                        WHERE d.fts @@ plainto_tsquery('arabic', subject)
                    )
                )
                OR (
                    -- Match ANY extracted place
                    array_length(extracted_places, 1) > 0 AND
                    EXISTS (
                        SELECT 1 FROM unnest(extracted_places) AS place
                        WHERE d.fts @@ plainto_tsquery('arabic', place)
                    )
                )
        ) ranked
        ORDER BY rank_ix
        LIMIT LEAST(match_count * 4, 100)
    ),
    
    -- =====================================================
    -- SIGNAL 2: CONTENT TRIGRAM
    -- =====================================================
    content_trigram_results AS (
        SELECT
            d.id,
            ROW_NUMBER() OVER(ORDER BY 
                GREATEST(
                    similarity(normalize_arabic(d.content), q_norm),
                    similarity(normalize_arabic(d.content), ctx_norm)
                ) DESC
            ) AS rank_ix,
            GREATEST(
                similarity(normalize_arabic(d.content), q_norm),
                similarity(normalize_arabic(d.content), ctx_norm)
            )::FLOAT AS score
        FROM documents d
        WHERE 
            similarity(normalize_arabic(d.content), q_norm) > 0.1
            OR similarity(normalize_arabic(d.content), ctx_norm) > 0.1
        ORDER BY rank_ix
        LIMIT LEAST(match_count * 4, 100)
    ),
    
    -- =====================================================
    -- SIGNAL 3: CONTENT SEMANTIC (SIMPLE 1:1)
    -- Uses clean context_query embedding from Edge Function
    -- =====================================================
    content_semantic_results AS (
        SELECT
            d.id,
            GREATEST(
                (1 - (d.embedding <=> hybrid_search_opus.query_embedding))::FLOAT,
                (1 - (d.embedding <=> hybrid_search_opus.focused_embedding))::FLOAT
            ) AS score,
            ROW_NUMBER() OVER(ORDER BY score DESC) AS rank_ix
        FROM documents d
        WHERE d.embedding IS NOT NULL
          AND GREATEST(
                  (1 - (d.embedding <=> hybrid_search_opus.query_embedding))::FLOAT,
                  (1 - (d.embedding <=> hybrid_search_opus.focused_embedding))::FLOAT
              ) > 0.1
        ORDER BY score DESC
        LIMIT LEAST(match_count * 4, 100)
    ),
    
    -- =====================================================
    -- SIGNAL 4: SUMMARY FTS (MULTIVERSE SEARCH!)
    -- =====================================================
    summary_fts_results AS (
        SELECT
            ranked.id,
            ROW_NUMBER() OVER(ORDER BY ranked.max_rank DESC) AS rank_ix,
            ranked.max_rank AS score
        FROM (
            SELECT
                d.id,
                GREATEST(
                    ts_rank_cd(d.summary_fts, websearch_to_tsquery('arabic', query_text)),
                    ts_rank_cd(d.summary_fts, websearch_to_tsquery('arabic', context_query_text)),
                    
                    -- Entity names
                    COALESCE((
                        SELECT MAX(ts_rank_cd(d.summary_fts, plainto_tsquery('arabic', entity)))
                        FROM unnest(extracted_entities) AS entity
                        WHERE entity IS NOT NULL AND entity != ''
                    ), 0),
                    
                    -- Subject names
                    COALESCE((
                        SELECT MAX(ts_rank_cd(d.summary_fts, plainto_tsquery('arabic', subject)))
                        FROM unnest(extracted_subjects) AS subject
                        WHERE subject IS NOT NULL AND subject != ''
                    ), 0)
                ) AS max_rank
            FROM documents d
            WHERE 
                d.summary_fts @@ websearch_to_tsquery('arabic', query_text)
                OR d.summary_fts @@ websearch_to_tsquery('arabic', context_query_text)
                OR (
                    array_length(extracted_entities, 1) > 0 AND
                    EXISTS (
                        SELECT 1 FROM unnest(extracted_entities) AS entity
                        WHERE d.summary_fts @@ plainto_tsquery('arabic', entity)
                    )
                )
                OR (
                    array_length(extracted_subjects, 1) > 0 AND
                    EXISTS (
                        SELECT 1 FROM unnest(extracted_subjects) AS subject
                        WHERE d.summary_fts @@ plainto_tsquery('arabic', subject)
                    )
                )
        ) ranked
        ORDER BY rank_ix
        LIMIT LEAST(match_count * 4, 100)
    ),
    
    -- =====================================================
    -- OPUS FIX #2: RESTORE INDEPENDENT SUMMARY SEMANTIC SIGNAL
    -- This was KILLED in v3 - now restored as separate RRF signal
    -- =====================================================
    summary_semantic_results AS (
        SELECT
            d.id,
            GREATEST(
                (1 - (d.summary_embedding <=> hybrid_search_opus.summary_embedding))::FLOAT,
                (1 - (d.summary_embedding <=> hybrid_search_opus.focused_embedding))::FLOAT
            ) AS score,
            ROW_NUMBER() OVER(ORDER BY score DESC) AS rank_ix
        FROM documents d
        WHERE d.summary_embedding IS NOT NULL
          AND GREATEST(
                  (1 - (d.summary_embedding <=> hybrid_search_opus.summary_embedding))::FLOAT,
                  (1 - (d.summary_embedding <=> hybrid_search_opus.focused_embedding))::FLOAT
              ) > 0.1
        ORDER BY score DESC
        LIMIT LEAST(match_count * 4, 100)
    ),
    
    -- =====================================================
    -- SIGNAL 6: EXACT MATCHING
    -- =====================================================
    exact_results AS (
        SELECT
            d.id,
            ROW_NUMBER() OVER(ORDER BY 
                CASE 
                    WHEN EXISTS (
                        SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e 
                        WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                           OR normalize_arabic(e->>'name') LIKE '%' || ctx_norm || '%'
                    ) THEN 1
                    WHEN normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%' THEN 2
                    WHEN normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || ctx_norm || '%' THEN 2
                    WHEN normalize_arabic(d.content) LIKE '%' || q_norm || '%' THEN 3
                    WHEN normalize_arabic(d.content) LIKE '%' || ctx_norm || '%' THEN 3
                    ELSE 4
                END
            ) AS rank_ix,
            TRUE AS has_exact_match
        FROM documents d
        WHERE 
            EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e 
                WHERE normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                   OR normalize_arabic(e->>'name') LIKE '%' || ctx_norm || '%'
            )
            OR normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || q_norm || '%'
            OR normalize_arabic(d.metadata->>'Title_raw') LIKE '%' || ctx_norm || '%'
            OR normalize_arabic(d.content) LIKE '%' || q_norm || '%'
            OR normalize_arabic(d.content) LIKE '%' || ctx_norm || '%'
        ORDER BY rank_ix
        LIMIT LEAST(match_count * 4, 100)
    ),
    
    -- =====================================================
    -- OPUS FIX #3: ADD WHERE FILTER TO METADATA
    -- Only process documents that have relevant metadata matches
    -- Removes circular FTS self-verification
    -- =====================================================
    metadata_matches AS (
        SELECT
            d.id,
            
            -- Entity matches (VERIFIED in poem text!)
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') entity
                WHERE 
                    (
                        normalize_arabic(entity->>'name') = ANY(
                            SELECT normalize_arabic(unnest(extracted_entities))
                        )
                        OR normalize_arabic(entity->>'name') LIKE '%' || q_norm || '%'
                        OR normalize_arabic(entity->>'name') LIKE '%' || ctx_norm || '%'
                    )
                    AND (
                        -- VERIFY: Entity name actually appears in poem
                        d.fts @@ plainto_tsquery('arabic', entity->>'name')
                        OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(entity->>'name') || '%'
                    )
            ) THEN entity_weight ELSE 0.0 END AS entity_score,
            
            -- Subject matches (VERIFIED in poem text!)
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'subjects') subj
                WHERE 
                    (
                        normalize_arabic(subj->>'subject') = ANY(
                            SELECT normalize_arabic(unnest(extracted_subjects))
                        )
                        OR normalize_arabic(subj->>'subject') LIKE '%' || q_norm || '%'
                        OR normalize_arabic(subj->>'subject') LIKE '%' || ctx_norm || '%'
                    )
                    AND (
                        -- VERIFY: Subject actually appears in poem
                        d.fts @@ plainto_tsquery('arabic', subj->>'subject')
                        OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(subj->>'subject') || '%'
                    )
            ) THEN subject_weight ELSE 0.0 END AS subject_score,
            
            -- Place matches (VERIFIED in poem text!)
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'places') place
                WHERE 
                    (
                        normalize_arabic(place->>'name') = ANY(
                            SELECT normalize_arabic(unnest(extracted_places))
                        )
                        OR normalize_arabic(place->>'name') LIKE '%' || q_norm || '%'
                        OR normalize_arabic(place->>'name') LIKE '%' || ctx_norm || '%'
                    )
                    AND (
                        -- VERIFY: Place name actually appears in poem
                        d.fts @@ plainto_tsquery('arabic', place->>'name')
                        OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(place->>'name') || '%'
                    )
            ) THEN place_weight ELSE 0.0 END AS place_score,
            
            -- Event matches
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'events') evt
                WHERE 
                    normalize_arabic(evt->>'event') = ANY(
                        SELECT normalize_arabic(unnest(extracted_events))
                    )
                    OR normalize_arabic(evt->>'event') LIKE '%' || q_norm || '%'
                    OR normalize_arabic(evt->>'event') LIKE '%' || ctx_norm || '%'
            ) THEN event_weight ELSE 0.0 END AS event_score,
            
            -- Religion matches
            CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(d.metadata->'religion') rel
                WHERE 
                    normalize_arabic(rel->>'religion') LIKE '%' || q_norm || '%'
                    OR normalize_arabic(rel->>'religion') LIKE '%' || ctx_norm || '%'
            ) THEN religion_weight ELSE 0.0 END AS religion_score,
            
            -- Matched fields array (WITH verification!)
            ARRAY_REMOVE(ARRAY[
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') entity 
                    WHERE (
                        normalize_arabic(entity->>'name') = ANY(SELECT normalize_arabic(unnest(extracted_entities)))
                        OR normalize_arabic(entity->>'name') LIKE '%' || q_norm || '%'
                        OR normalize_arabic(entity->>'name') LIKE '%' || ctx_norm || '%'
                    ) AND (
                        d.fts @@ plainto_tsquery('arabic', entity->>'name')
                        OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(entity->>'name') || '%'
                    )
                ) THEN 'entities' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'subjects') subj 
                    WHERE (
                        normalize_arabic(subj->>'subject') = ANY(SELECT normalize_arabic(unnest(extracted_subjects)))
                        OR normalize_arabic(subj->>'subject') LIKE '%' || q_norm || '%'
                        OR normalize_arabic(subj->>'subject') LIKE '%' || ctx_norm || '%'
                    ) AND (
                        d.fts @@ plainto_tsquery('arabic', subj->>'subject')
                        OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(subj->>'subject') || '%'
                    )
                ) THEN 'subjects' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(d.metadata->'places') place 
                    WHERE (
                        normalize_arabic(place->>'name') = ANY(SELECT normalize_arabic(unnest(extracted_places)))
                        OR normalize_arabic(place->>'name') LIKE '%' || q_norm || '%'
                        OR normalize_arabic(place->>'name') LIKE '%' || ctx_norm || '%'
                    ) AND (
                        d.fts @@ plainto_tsquery('arabic', place->>'name')
                        OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(place->>'name') || '%'
                    )
                ) THEN 'places' END,
                CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(d.metadata->'events') evt 
                    WHERE normalize_arabic(evt->>'event') = ANY(SELECT normalize_arabic(unnest(extracted_events)))
                       OR normalize_arabic(evt->>'event') LIKE '%' || q_norm || '%'
                       OR normalize_arabic(evt->>'event') LIKE '%' || ctx_norm || '%') 
                THEN 'events' END,
                CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(d.metadata->'religion') rel 
                    WHERE normalize_arabic(rel->>'religion') LIKE '%' || q_norm || '%'
                       OR normalize_arabic(rel->>'religion') LIKE '%' || ctx_norm || '%') 
                THEN 'religion' END
            ], NULL) AS matched_fields
            
        FROM documents d
        -- ✅ WHERE FILTER: Only process docs with VERIFIED metadata matches
        WHERE EXISTS (
            SELECT 1 FROM jsonb_array_elements(d.metadata->'entities') e
            WHERE (
                normalize_arabic(e->>'name') = ANY(SELECT normalize_arabic(unnest(extracted_entities)))
                OR normalize_arabic(e->>'name') LIKE '%' || q_norm || '%'
                OR normalize_arabic(e->>'name') LIKE '%' || ctx_norm || '%'
            ) AND (
                d.fts @@ plainto_tsquery('arabic', e->>'name')
                OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(e->>'name') || '%'
            )
        )
        OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(d.metadata->'subjects') s
            WHERE (
                normalize_arabic(s->>'subject') = ANY(SELECT normalize_arabic(unnest(extracted_subjects)))
                OR normalize_arabic(s->>'subject') LIKE '%' || q_norm || '%'
                OR normalize_arabic(s->>'subject') LIKE '%' || ctx_norm || '%'
            ) AND (
                d.fts @@ plainto_tsquery('arabic', s->>'subject')
                OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(s->>'subject') || '%'
            )
        )
        OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(d.metadata->'places') p
            WHERE (
                normalize_arabic(p->>'name') = ANY(SELECT normalize_arabic(unnest(extracted_places)))
                OR normalize_arabic(p->>'name') LIKE '%' || q_norm || '%'
                OR normalize_arabic(p->>'name') LIKE '%' || ctx_norm || '%'
            ) AND (
                d.fts @@ plainto_tsquery('arabic', p->>'name')
                OR normalize_arabic(d.content) LIKE '%' || normalize_arabic(p->>'name') || '%'
            )
        )
        OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(d.metadata->'events') ev
            WHERE normalize_arabic(ev->>'event') = ANY(SELECT normalize_arabic(unnest(extracted_events)))
               OR normalize_arabic(ev->>'event') LIKE '%' || q_norm || '%'
               OR normalize_arabic(ev->>'event') LIKE '%' || ctx_norm || '%'
        )
        OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(d.metadata->'religion') r
            WHERE normalize_arabic(r->>'religion') LIKE '%' || q_norm || '%'
               OR normalize_arabic(r->>'religion') LIKE '%' || ctx_norm || '%'
        )
    ),
    
    -- =====================================================
    -- RRF COMBINATION WITH RESTORED SUMMARY SEMANTIC
    -- =====================================================
    combined AS (
        SELECT
            COALESCE(c_fts.id, c_trgm.id, c_sem.id, s_fts.id, s_sem.id, exact.id, meta.id) AS id,
            
            -- RRF scores (weighted)
            COALESCE(1.0 / (rrf_k + c_fts.rank_ix), 0.0) * content_fts_weight AS content_fts_rrf,
            COALESCE(1.0 / (rrf_k + c_trgm.rank_ix), 0.0) * content_trigram_weight AS content_trigram_rrf,
            COALESCE(1.0 / (rrf_k + c_sem.rank_ix), 0.0) * content_semantic_weight AS content_semantic_rrf,
            COALESCE(1.0 / (rrf_k + s_fts.rank_ix), 0.0) * summary_fts_weight AS summary_fts_rrf,
            COALESCE(1.0 / (rrf_k + s_sem.rank_ix), 0.0) * summary_semantic_weight AS summary_semantic_rrf,  -- ✅ RESTORED
            COALESCE(1.0 / (rrf_k + exact.rank_ix), 0.0) * exact_weight AS exact_rrf,
            
            -- Raw scores
            COALESCE(c_fts.score, 0.0) AS content_fts_raw,
            COALESCE(c_trgm.score, 0.0) AS content_trigram_raw,
            COALESCE(c_sem.score, 0.0) AS content_semantic_raw,
            COALESCE(s_fts.score, 0.0) AS summary_fts_raw,
            COALESCE(s_sem.score, 0.0) AS summary_semantic_raw,  -- ✅ RESTORED
            COALESCE(exact.has_exact_match, FALSE) AS exact_matched,
            
            -- Metadata scores
            COALESCE(meta.entity_score, 0.0) AS entity_contribution,
            COALESCE(meta.subject_score, 0.0) AS subject_contribution,
            COALESCE(meta.place_score, 0.0) AS place_contribution,
            COALESCE(meta.event_score, 0.0) AS event_contribution,
            COALESCE(meta.religion_score, 0.0) AS religion_contribution,
            
            COALESCE(meta.matched_fields, ARRAY[]::TEXT[]) AS metadata_fields
            
        FROM content_fts_results c_fts
        FULL OUTER JOIN content_trigram_results c_trgm ON c_fts.id = c_trgm.id
        FULL OUTER JOIN content_semantic_results c_sem ON COALESCE(c_fts.id, c_trgm.id) = c_sem.id
        FULL OUTER JOIN summary_fts_results s_fts ON COALESCE(c_fts.id, c_trgm.id, c_sem.id) = s_fts.id
        FULL OUTER JOIN summary_semantic_results s_sem ON COALESCE(c_fts.id, c_trgm.id, c_sem.id, s_fts.id) = s_sem.id  -- ✅ RESTORED
        FULL OUTER JOIN exact_results exact ON COALESCE(c_fts.id, c_trgm.id, c_sem.id, s_fts.id, s_sem.id) = exact.id
        FULL OUTER JOIN metadata_matches meta ON COALESCE(c_fts.id, c_trgm.id, c_sem.id, s_fts.id, s_sem.id, exact.id) = meta.id
    )
    
    -- =====================================================
    -- FINAL SCORING & RETURN
    -- =====================================================
    SELECT
        d.id,
        d.content,
        COALESCE(d.summary, d.metadata->>'summary') AS summary,
        d.metadata,
        
        -- Final score: Sum of ALL weighted contributions
        (
            c.content_fts_rrf + 
            c.content_trigram_rrf + 
            c.content_semantic_rrf + 
            c.summary_fts_rrf + 
            c.summary_semantic_rrf +  -- ✅ RESTORED
            c.exact_rrf +
            c.entity_contribution +
            c.subject_contribution +
            c.place_contribution +
            c.event_contribution +
            c.religion_contribution
        )::FLOAT AS final_score,
        
        -- RRF component (now includes summary_semantic!)
        (c.content_fts_rrf + c.content_trigram_rrf + c.content_semantic_rrf + 
         c.summary_fts_rrf + c.summary_semantic_rrf + c.exact_rrf)::FLOAT AS rrf_score,
        
        -- Content scores
        c.content_fts_raw::FLOAT AS content_fts_rank,
        c.content_trigram_raw::FLOAT AS content_trigram_sim,
        c.content_semantic_raw::FLOAT AS content_semantic_sim,
        
        -- Summary scores
        c.summary_fts_raw::FLOAT AS summary_fts_rank,
        c.summary_semantic_raw::FLOAT AS summary_semantic_sim,  -- ✅ RESTORED (not 0!)
        
        -- Metadata scores
        c.entity_contribution::FLOAT AS entity_match,
        c.subject_contribution::FLOAT AS subject_match,
        c.place_contribution::FLOAT AS place_match,
        c.event_contribution::FLOAT AS event_match,
        c.religion_contribution::FLOAT AS religion_match,
        
        -- Match details
        c.exact_matched AS exact_match,
        c.metadata_fields::TEXT[] AS matched_in
        
    FROM combined c
    JOIN documents d ON d.id = c.id
    ORDER BY final_score DESC
    LIMIT match_count;
END;
$$;