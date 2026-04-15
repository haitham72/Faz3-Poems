-- =====================================================
-- HYBRID WORD SEARCH - Best of Both Approaches
-- =====================================================
-- Combines: Clean structure + Full scoring + Proper JSONB handling
--
-- SCORING HIERARCHY:
-- ┌─────────────────────────────────────────────────────────┐
-- │ PRIMARY MATCHES (Content)                               │
-- ├─────────────────────────────────────────────────────────┤
-- │ • Title + Line match:        100 points                 │
-- │ • Title only:                 80 points                 │
-- │ • Line only:                  60 points                 │
-- │ • Prefix match:              +30 points                 │
-- ├─────────────────────────────────────────────────────────┤
-- │ MULTI-ENTITY BONUS (AND logic)                          │
-- ├─────────────────────────────────────────────────────────┤
-- │ • All entities matched:      +50 points (AND)           │
-- │ • Multiple matched:          +30 points (partial AND)   │
-- │ • Single matched:            +10 points (OR fallback)   │
-- ├─────────────────────────────────────────────────────────┤
-- │ WORD COMPLETENESS                                       │
-- ├─────────────────────────────────────────────────────────┤
-- │ • All words matched:         +40 points                 │
-- │ • All but one:               +25 points                 │
-- │ • At least one:              +10 points                 │
-- ├─────────────────────────────────────────────────────────┤
-- │ METADATA SIGNALS (All treated equally - match is match) │
-- ├─────────────────────────────────────────────────────────┤
-- │ • Entities:                  +5 points                  │
-- │ • Places:                    +5 points                  │
-- │ • Subjects:                  +5 points                  │
-- │ • Events:                    +5 points                  │
-- │ • Sentiments:                +5 points                  │
-- │ • Religion:                  +5 points                  │
-- │ • Animals:                   +5 points                  │
-- │ • Summary:                   +1 point (context only)    │
-- └─────────────────────────────────────────────────────────┘
--
-- JSONB FIELD EQUALITY:
-- Within each JSONB structure, ALL subfields are treated equally:
-- • entities: name = relation = resolved_from[]
-- • places:   name = resolved_from[]
-- • animals:  name = type = resolved_from[]
-- =====================================================

DROP FUNCTION IF EXISTS smart_word_search(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION smart_word_search(
    search_query TEXT,
    result_limit INT DEFAULT 100
)
RETURNS TABLE(
    rank INT,
    rank_score INT,
    relative_score INT,
    match_type TEXT,
    matched_tabs TEXT[],
    poem_id INT,
    row_id INT,
    is_grouped BOOLEAN,
    display_title TEXT,
    display_line TEXT,
    data JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    cleaned_q TEXT;
    q_parts TEXT[];
    words TEXT[];
    word_count INT;
BEGIN
    -- STEP 1: Preprocess (strip "هل هناك قصائد عن" etc)
    cleaned_q := preprocess_query(search_query);
    
    -- STEP 2: Handle multi-entity with "و" connector (LEARNED: simpler split)
    IF cleaned_q ILIKE '% و %' THEN
        q_parts := string_to_array(cleaned_q, ' و ');
        -- Clean each part
        q_parts := ARRAY(SELECT trim(p) FROM unnest(q_parts) p WHERE char_length(trim(p)) > 1);
    ELSE
        q_parts := ARRAY[cleaned_q];
    END IF;
    
    -- STEP 3: Tokenize & remove stopwords
    words := regexp_split_to_array(cleaned_q, '\s+');
    words := ARRAY(
        SELECT word FROM unnest(words) word 
        WHERE char_length(word) > 1 
        AND word NOT IN (
            'في', 'من', 'على', 'إلى', 'عن', 'مع', 'كل', 'هذا', 'ذلك', 
            'التي', 'الذي', 'أن', 'أو', 'لا', 'ما', 'إذا',
            'هل', 'هناك', 'قصائد', 'ابحث', 'اريد', 'شعر', 'أبيات'
        )
    );
    word_count := COALESCE(array_length(words, 1), 0);
    
    RETURN QUERY
    WITH scored_results AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            
            -- Core matches
            (d."Title_cleaned" ILIKE '%' || cleaned_q || '%') as title_match,
            (d."Poem_line_cleaned" ILIKE '%' || cleaned_q || '%') as line_match,
            
            -- Multi-entity count: how many distinct parts matched?
            -- Example: "محمد بن راشد و محمد بن زايد" splits into 2 parts
            -- matched_parts_count = 2 → poem mentions BOTH (AND)
            -- matched_parts_count = 1 → poem mentions only ONE (OR)
            (SELECT COUNT(DISTINCT p) FROM unnest(q_parts) p 
             WHERE d."Title_cleaned" ILIKE '%' || p || '%' OR 
                   d."Poem_line_cleaned" ILIKE '%' || p || '%') as matched_parts_count,
            
            -- Prefix detection
            (cleaned_q ~ '^' || ANY(words) OR 
             d."Title_cleaned" ~ ('^' || cleaned_q) OR
             d."Poem_line_cleaned" ~ ('^' || cleaned_q)) as has_prefix_match,
            
            -- Word completeness (how many words matched?)
            CASE 
                WHEN word_count >= 2 THEN
                    (SELECT COUNT(DISTINCT w) FROM unnest(words) w 
                     WHERE d."Title_cleaned" ILIKE '%' || w || '%' OR
                           d."Poem_line_cleaned" ILIKE '%' || w || '%')
                ELSE word_count
            END as matched_word_count,
            
            -- Metadata matches - PROPER JSONB SEARCHING
            -- Note: Within each JSONB structure, ALL fields are treated equally
            -- (e.g., entities.name = entities.relation = entities.resolved_from)
            -- This matches user intent since we don't know which field they're targeting
            
            -- Entities: search in 'name', 'relation', AND 'resolved_from' fields
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE EXISTS(
                       SELECT 1 FROM jsonb_array_elements(d.entities) e 
                       WHERE e->>'name' ILIKE '%' || w || '%' OR
                             e->>'relation' ILIKE '%' || w || '%' OR
                             EXISTS(SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf 
                                    WHERE rf ILIKE '%' || w || '%')
                   )) as entities_match,
            
            -- Places: search in 'name' and 'resolved_from' fields
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE EXISTS(
                       SELECT 1 FROM jsonb_array_elements(d.places) p 
                       WHERE p->>'name' ILIKE '%' || w || '%' OR
                             EXISTS(SELECT 1 FROM jsonb_array_elements_text(p->'resolved_from') rf 
                                    WHERE rf ILIKE '%' || w || '%')
                   )) as places_match,
            
            -- Events: array of strings
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE EXISTS(
                       SELECT 1 FROM jsonb_array_elements_text(d.events) ev 
                       WHERE ev ILIKE '%' || w || '%'
                   )) as events_match,
            
            -- Subjects: array of strings
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE EXISTS(
                       SELECT 1 FROM jsonb_array_elements_text(d.subjects) subj 
                       WHERE subj ILIKE '%' || w || '%'
                   )) as subjects_match,
            
            -- Sentiments: text column (already correct)
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE d.sentiments ILIKE '%' || w || '%') as sentiments_match,
            
            -- Religion: array of strings
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE EXISTS(
                       SELECT 1 FROM jsonb_array_elements_text(d.religion) rel 
                       WHERE rel ILIKE '%' || w || '%'
                   )) as religion_match,
            
            -- Animals: search in 'name', 'type', and 'resolved_from' fields
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE EXISTS(
                       SELECT 1 FROM jsonb_array_elements(d.animals) a 
                       WHERE a->>'name' ILIKE '%' || w || '%' OR
                             a->>'type' ILIKE '%' || w || '%' OR
                             EXISTS(SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') rf 
                                    WHERE rf ILIKE '%' || w || '%')
                   )) as animals_match,
            
            -- Summary: NEW - search the summary text
            EXISTS(SELECT 1 FROM unnest(words) w 
                   WHERE d.summary ILIKE '%' || w || '%') as summary_match,
            
            -- Full metadata
            jsonb_build_object(
                'entities', d.entities,
                'places', d.places,
                'events', d.events,
                'religion', d.religion,
                'subjects', d.subjects,
                'animals', d.animals,
                'sentiments', d.sentiments,
                'summary', d.summary,
                'meter', d.meter,
                'qafiya', d.qafiya,
                'rawy', d.rawy
            ) as full_data
            
        FROM "Diwan_Hamdan" d
        WHERE 
            -- Match ANY part for multi-entity queries
            EXISTS(SELECT 1 FROM unnest(q_parts) p WHERE
                d."Title_cleaned" ILIKE '%' || p || '%' OR
                d."Poem_line_cleaned" ILIKE '%' || p || '%' OR
                d.summary ILIKE '%' || p || '%' OR
                -- Entities: search in JSONB structure (name, relation, resolved_from)
                EXISTS(SELECT 1 FROM jsonb_array_elements(d.entities) e 
                       WHERE e->>'name' ILIKE '%' || p || '%' OR
                             e->>'relation' ILIKE '%' || p || '%' OR
                             EXISTS(SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') rf 
                                    WHERE rf ILIKE '%' || p || '%')) OR
                -- Places: search in JSONB structure
                EXISTS(SELECT 1 FROM jsonb_array_elements(d.places) pl 
                       WHERE pl->>'name' ILIKE '%' || p || '%' OR
                             EXISTS(SELECT 1 FROM jsonb_array_elements_text(pl->'resolved_from') rf 
                                    WHERE rf ILIKE '%' || p || '%')) OR
                -- Events: array of strings
                EXISTS(SELECT 1 FROM jsonb_array_elements_text(d.events) ev 
                       WHERE ev ILIKE '%' || p || '%') OR
                -- Subjects: array of strings
                EXISTS(SELECT 1 FROM jsonb_array_elements_text(d.subjects) subj 
                       WHERE subj ILIKE '%' || p || '%') OR
                -- Sentiments: text column
                d.sentiments ILIKE '%' || p || '%' OR
                -- Religion: array of strings
                EXISTS(SELECT 1 FROM jsonb_array_elements_text(d.religion) rel 
                       WHERE rel ILIKE '%' || p || '%') OR
                -- Animals: search in JSONB structure (name, type, resolved_from)
                EXISTS(SELECT 1 FROM jsonb_array_elements(d.animals) a 
                       WHERE a->>'name' ILIKE '%' || p || '%' OR
                             a->>'type' ILIKE '%' || p || '%' OR
                             EXISTS(SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') rf 
                                    WHERE rf ILIKE '%' || p || '%'))
            )
    ),
    
    final_scored AS (
        SELECT 
            sr.*,
            
            -- Hierarchical scoring (MISSING FROM OTHER LLM)
            (
                -- Prefix bonus
                (CASE WHEN sr.has_prefix_match THEN 30 ELSE 0 END) +
                
                -- Primary match
                (CASE 
                    WHEN sr.title_match AND sr.line_match THEN 100
                    WHEN sr.title_match THEN 80
                    WHEN sr.line_match THEN 60
                    ELSE 0
                END) +
                
                -- Multi-part AND bonus (rewards poems mentioning ALL entities)
                (CASE 
                    WHEN array_length(q_parts, 1) > 1 AND sr.matched_parts_count = array_length(q_parts, 1) THEN 50  -- All parts matched (AND)
                    WHEN sr.matched_parts_count > 1 THEN 30  -- Multiple parts matched (partial AND)
                    WHEN sr.matched_parts_count = 1 THEN 10  -- Single part matched (OR)
                    ELSE 0 
                END) +
                
                -- Word completeness
                (CASE 
                    WHEN word_count >= 2 AND sr.matched_word_count = word_count THEN 40
                    WHEN word_count >= 2 AND sr.matched_word_count >= (word_count - 1) THEN 25
                    WHEN word_count >= 2 AND sr.matched_word_count >= 1 THEN 10
                    ELSE 0
                END) +
                
                -- Metadata signals (all treated equally - a match is a match)
                (CASE WHEN sr.entities_match THEN 5 ELSE 0 END) +
                (CASE WHEN sr.places_match THEN 5 ELSE 0 END) +
                (CASE WHEN sr.events_match THEN 5 ELSE 0 END) +
                (CASE WHEN sr.subjects_match THEN 5 ELSE 0 END) +
                (CASE WHEN sr.sentiments_match THEN 5 ELSE 0 END) +
                (CASE WHEN sr.religion_match THEN 5 ELSE 0 END) +
                (CASE WHEN sr.animals_match THEN 5 ELSE 0 END) +
                (CASE WHEN sr.summary_match THEN 1 ELSE 0 END)  -- Summary: minimal boost, just extra context
            ) as total_score,
            
            -- Match type classification
            CASE 
                WHEN sr.title_match AND sr.line_match THEN 'title+line'
                WHEN sr.title_match AND NOT sr.line_match THEN 'title-only'
                WHEN sr.line_match THEN 'line-only'
                ELSE 'metadata'
            END as computed_match_type,
            
            -- Grouping flag
            CASE 
                WHEN sr.title_match AND NOT sr.line_match THEN TRUE
                ELSE FALSE
            END as is_title_only,
            
            -- Matched tabs array (MISSING FROM OTHER LLM)
            ARRAY(
                SELECT tab FROM (
                    SELECT unnest(ARRAY[
                        CASE WHEN sr.has_prefix_match THEN 'prefix' END,
                        CASE WHEN sr.title_match THEN 'title' END,
                        CASE WHEN sr.line_match THEN 'line' END,
                        CASE WHEN sr.entities_match THEN 'entities' END,
                        CASE WHEN sr.places_match THEN 'places' END,
                        CASE WHEN sr.events_match THEN 'events' END,
                        CASE WHEN sr.subjects_match THEN 'subjects' END,
                        CASE WHEN sr.sentiments_match THEN 'sentiments' END,
                        CASE WHEN sr.religion_match THEN 'religion' END,
                        CASE WHEN sr.animals_match THEN 'animals' END,
                        CASE WHEN sr.summary_match THEN 'summary' END
                    ]) as tab
                ) t WHERE tab IS NOT NULL
            ) as tabs_array
            
        FROM scored_results sr
    ),
    
    -- Deduplicate title-only matches
    grouped_results AS (
        SELECT DISTINCT ON (
            CASE WHEN fs.is_title_only THEN fs.poem_id ELSE fs."Row_ID" END
        )
            fs.*
        FROM final_scored fs
        ORDER BY 
            CASE WHEN fs.is_title_only THEN fs.poem_id ELSE fs."Row_ID" END,
            fs.total_score DESC
    )
    
    -- LEARNED: Window function for relative_score (cleaner than CTE)
    SELECT 
        ROW_NUMBER() OVER (ORDER BY gr.total_score DESC, gr.poem_id DESC)::INT as rank,
        gr.total_score::INT as rank_score,
        -- LEARNED: NULLIF prevents division-by-zero
        ROUND((gr.total_score::NUMERIC / NULLIF(MAX(gr.total_score) OVER (), 0)) * 100)::INT as relative_score,
        gr.computed_match_type::TEXT as match_type,
        gr.tabs_array::TEXT[] as matched_tabs,
        gr.poem_id::INT,
        gr."Row_ID"::INT as row_id,
        gr.is_title_only::BOOLEAN as is_grouped,
        gr."Title_cleaned"::TEXT as display_title,
        gr."Poem_line_cleaned"::TEXT as display_line,
        gr.full_data::JSONB as data
    FROM grouped_results gr
    ORDER BY gr.total_score DESC, gr.poem_id DESC
    LIMIT result_limit;
END;
$$;

-- =====================================================
-- TEST CASES
-- =====================================================

-- Test 1: Prefix stripping
SELECT '=== TEST 1: Prefix Stripping ===' as test;
SELECT rank, rank_score, relative_score, match_type, matched_tabs,
       substring(display_title, 1, 40) as title
FROM smart_word_search('هل هناك قصائد عن محمد بن زايد', 5);

-- Test 2: Multi-entity (should prioritize poems with BOTH)
SELECT '=== TEST 2: Multi-Entity (AND vs OR) ===' as test;
SELECT 
    rank, 
    rank_score, 
    relative_score, 
    match_type, 
    matched_tabs,
    CASE 
        WHEN display_line ILIKE '%محمد بن راشد%' AND display_line ILIKE '%محمد بن زايد%' THEN '✓ BOTH'
        WHEN display_line ILIKE '%محمد بن راشد%' THEN '→ Only MBR'
        WHEN display_line ILIKE '%محمد بن زايد%' THEN '→ Only MBZ'
        ELSE '? Neither in line'
    END as entity_check,
    substring(display_title, 1, 40) as title
FROM smart_word_search('محمد بن راشد و محمد بن زايد', 10);

-- Test 3: Entity name search
SELECT '=== TEST 3a: Entity Name Search ===' as test;
SELECT rank, matched_tabs, data->'entities' as entities, substring(display_title, 1, 40) as title
FROM smart_word_search('الشاعر', 5);

-- Test 3b: Entity relation search  
SELECT '=== TEST 3b: Entity Relation Search ===' as test;
SELECT rank, matched_tabs, data->'entities' as entities, substring(display_title, 1, 40) as title
FROM smart_word_search('الذات', 5);

-- Test 3c: Entity resolved_from search
SELECT '=== TEST 3c: Entity Resolved_From Search ===' as test;
SELECT rank, matched_tabs, data->'entities' as entities, substring(display_title, 1, 40) as title
FROM smart_word_search('حمدان بن محمد', 5);

-- Test 4: Animals type search
SELECT '=== TEST 4: Animal Type Search ===' as test;
SELECT rank, matched_tabs, data->'animals' as animals, substring(display_title, 1, 40) as title
FROM smart_word_search('وحوش برية', 5);

-- Test 5: Summary as context-only signal (minimal boost)
SELECT '=== TEST 5: Summary Context Signal ===' as test;
SELECT 
    rank,
    rank_score,
    matched_tabs,
    CASE 
        WHEN 'line' = ANY(matched_tabs) THEN '✓ Line match (primary)'
        WHEN 'summary' = ANY(matched_tabs) AND NOT ('line' = ANY(matched_tabs)) THEN '→ Summary only (+1)'
        ELSE '? Metadata'
    END as match_source,
    substring(data->>'summary', 1, 60) as summary_preview,
    substring(display_title, 1, 40) as title
FROM smart_word_search('الشوق', 8)
ORDER BY rank;