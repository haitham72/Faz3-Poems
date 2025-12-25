DROP FUNCTION IF EXISTS hybrid_search_exact(JSONB, INT, NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS normalize_arabic(TEXT) CASCADE;
DROP FUNCTION IF EXISTS is_common_particle(TEXT) CASCADE;

CREATE OR REPLACE FUNCTION normalize_arabic(text_input TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT lower(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(text_input, '[ًٌٍَُِّْ]', '', 'g'),
                        'ة', 'ه', 'g'
                    ),
                    '[أإآٱ]', 'ا', 'g'
                ),
                '[ىي]', 'ي', 'g'
            ),
            '[()،]', '', 'g'
        )
    );
$$;

CREATE OR REPLACE FUNCTION is_common_particle(word TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT lower(word) IN ('بن', 'ابن', 'ال', 'آل', 'من', 'في', 'على', 'الى', 'او', 'و', 'يا');
$$;

CREATE OR REPLACE FUNCTION hybrid_search_exact(
    search_payload JSONB,
    match_limit INT DEFAULT 5,
    min_score NUMERIC DEFAULT 0.5
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    query_text TEXT;
    search_terms JSONB;
    current_result RECORD;
    results_array JSONB := '[]'::JSONB;
    per_term_results JSONB := '{}'::JSONB;
    current_term RECORD;
    term_results JSONB;
    term_count INT;
    seen_poems INT[] := ARRAY[]::INT[];
    highlight_terms TEXT[];
    title_highlights JSONB;
    poem_highlights JSONB;
    summary_highlights JSONB;
    mawadi3_highlights JSONB;
    normalized_score NUMERIC;
    rf_record RECORD;
BEGIN
    query_text := search_payload->>'exact_query';
    search_terms := COALESCE(search_payload->'search_terms', '[]'::JSONB);
    
    IF jsonb_array_length(search_terms) = 0 THEN
        search_terms := jsonb_build_array(
            jsonb_build_object(
                'query', jsonb_build_array(query_text),
                'confidence', 1.0,
                'type', 'text',
                'filter', null
            )
        );
    END IF;

    FOR current_term IN 
        SELECT 
            COALESCE(value->'main_query', value->'expanded_query', value->'query') as query_variants,
            value->>'type' as term_type,
            COALESCE((value->>'confidence')::NUMERIC, 1.0) as confidence,
            value->>'filter' as entity_filter
        FROM jsonb_array_elements(search_terms)
    LOOP
        term_results := '[]'::JSONB;
        term_count := 0;
        
        FOR current_result IN
            WITH 
            compound_ngrams AS (
                SELECT DISTINCT
                    fragment,
                    fragment_type,
                    CASE fragment_type
                        WHEN 'full_name' THEN 100
                        WHEN 'last_word_distinctive' THEN 50
                        ELSE 30
                    END as priority,
                    CASE fragment_type
                        WHEN 'full_name' THEN 100
                        WHEN 'last_word_distinctive' THEN 50
                        ELSE 30
                    END as distinctiveness_score
                FROM (
                    SELECT 
                        value::text as fragment,
                        'full_name' as fragment_type
                    FROM jsonb_array_elements_text(current_term.query_variants)
                    
                    UNION ALL
                    
                    SELECT 
                        words[array_length(words, 1)] as fragment,
                        'last_word_distinctive' as fragment_type
                    FROM (
                        SELECT string_to_array(value::text, ' ') as words
                        FROM jsonb_array_elements_text(current_term.query_variants)
                    ) q
                    WHERE array_length(words, 1) >= 2
                    AND NOT is_common_particle(words[array_length(words, 1)])
                ) all_ngrams
            ),
            match_analysis AS (
                SELECT 
                    e.*,
                    ng.fragment,
                    ng.fragment_type,
                    ng.distinctiveness_score,
                    ng.priority,
                    CASE
                        WHEN position(lower(ng.fragment) IN lower(e."Title_cleaned")) > 0 THEN 'title_exact'
                        WHEN position(normalize_arabic(ng.fragment) IN normalize_arabic(e."Title_cleaned")) > 0 THEN 'title_normalized'
                        WHEN similarity(ng.fragment, e."Title_cleaned") > 0.4 THEN 'title_fuzzy'
                        
                        WHEN position(lower(ng.fragment) IN lower(e."Poem_line_cleaned")) > 0 THEN 'poem_exact'
                        WHEN position(normalize_arabic(ng.fragment) IN normalize_arabic(e."Poem_line_cleaned")) > 0 THEN 'poem_normalized'
                        WHEN similarity(ng.fragment, e."Poem_line_cleaned") > 0.4 THEN 'poem_fuzzy'
                        
                        WHEN current_term.term_type = 'شخص' AND jsonb_array_length(e."شخص") > 0 AND
                             EXISTS (
                                 SELECT 1 FROM jsonb_array_elements(e."شخص") entity,
                                               jsonb_array_elements_text(entity->'resolved_from') rf
                                 WHERE normalize_arabic(rf) = normalize_arabic(ng.fragment)
                                    OR similarity(ng.fragment, rf) > 0.4
                             ) THEN 'entity_resolved'
                        
                        WHEN position(lower(ng.fragment) IN lower(e.summary)) > 0 THEN 'summary_exact'
                        WHEN position(normalize_arabic(ng.fragment) IN normalize_arabic(e.summary)) > 0 THEN 'summary_normalized'
                        WHEN similarity(ng.fragment, e.summary) > 0.4 THEN 'summary_fuzzy'
                        
                        WHEN e."مواضيع" IS NOT NULL AND
                             EXISTS (
                                 SELECT 1 FROM jsonb_array_elements_text(e."مواضيع") topic
                                 WHERE position(lower(ng.fragment) IN lower(topic)) > 0
                                    OR position(normalize_arabic(ng.fragment) IN normalize_arabic(topic)) > 0
                                    OR similarity(ng.fragment, topic) > 0.4
                             ) THEN 'مواضيع_exact'
                        
                        ELSE NULL
                    END as match_location,
                    CASE
                        WHEN position(lower(ng.fragment) IN lower(e."Title_cleaned")) > 0 
                            THEN current_term.confidence * 8.0 * (ng.distinctiveness_score / 100.0)
                        WHEN position(normalize_arabic(ng.fragment) IN normalize_arabic(e."Title_cleaned")) > 0 
                            THEN current_term.confidence * 7.5 * (ng.distinctiveness_score / 100.0)
                        WHEN similarity(ng.fragment, e."Title_cleaned") > 0.4
                            THEN current_term.confidence * 7.0 * similarity(ng.fragment, e."Title_cleaned")
                        WHEN position(lower(ng.fragment) IN lower(e."Poem_line_cleaned")) > 0 
                            THEN current_term.confidence * 7.0 * (ng.distinctiveness_score / 100.0)
                        WHEN position(normalize_arabic(ng.fragment) IN normalize_arabic(e."Poem_line_cleaned")) > 0 
                            THEN current_term.confidence * 6.5 * (ng.distinctiveness_score / 100.0)
                        WHEN similarity(ng.fragment, e."Poem_line_cleaned") > 0.4
                            THEN current_term.confidence * 6.0 * similarity(ng.fragment, e."Poem_line_cleaned")
                        WHEN current_term.term_type = 'شخص' AND jsonb_array_length(e."شخص") > 0 AND
                             EXISTS (
                                 SELECT 1 FROM jsonb_array_elements(e."شخص") entity,
                                               jsonb_array_elements_text(entity->'resolved_from') rf
                                 WHERE normalize_arabic(rf) = normalize_arabic(ng.fragment)
                                    OR similarity(ng.fragment, rf) > 0.4
                             ) 
                            THEN current_term.confidence * 6.0 * (ng.distinctiveness_score / 100.0)
                        WHEN position(lower(ng.fragment) IN lower(e.summary)) > 0 
                            THEN current_term.confidence * 3.0 * (ng.distinctiveness_score / 100.0)
                        WHEN position(normalize_arabic(ng.fragment) IN normalize_arabic(e.summary)) > 0 
                            THEN current_term.confidence * 2.8 * (ng.distinctiveness_score / 100.0)
                        WHEN similarity(ng.fragment, e.summary) > 0.4
                            THEN current_term.confidence * 2.5 * similarity(ng.fragment, e.summary)
                        WHEN e."مواضيع" IS NOT NULL AND
                             EXISTS (
                                 SELECT 1 FROM jsonb_array_elements_text(e."مواضيع") topic
                                 WHERE position(lower(ng.fragment) IN lower(topic)) > 0
                                    OR position(normalize_arabic(ng.fragment) IN normalize_arabic(topic)) > 0
                                    OR similarity(ng.fragment, topic) > 0.4
                             )
                            THEN current_term.confidence * 2.0 * (ng.distinctiveness_score / 100.0)
                        ELSE 0
                    END as fragment_score
                FROM "Exact_search" e
                CROSS JOIN compound_ngrams ng
                WHERE 
                    position(lower(ng.fragment) IN lower(e."Poem_line_cleaned")) > 0
                    OR position(lower(ng.fragment) IN lower(e."Title_cleaned")) > 0
                    OR position(lower(ng.fragment) IN lower(e.summary)) > 0
                    OR position(normalize_arabic(ng.fragment) IN normalize_arabic(e."Poem_line_cleaned")) > 0
                    OR position(normalize_arabic(ng.fragment) IN normalize_arabic(e."Title_cleaned")) > 0
                    OR position(normalize_arabic(ng.fragment) IN normalize_arabic(e.summary)) > 0
                    OR similarity(ng.fragment, e."Poem_line_cleaned") > 0.4
                    OR similarity(ng.fragment, e."Title_cleaned") > 0.4
                    OR similarity(ng.fragment, e.summary) > 0.4
                    OR (e."مواضيع" IS NOT NULL AND EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(e."مواضيع") topic
                        WHERE position(lower(ng.fragment) IN lower(topic)) > 0
                           OR position(normalize_arabic(ng.fragment) IN normalize_arabic(topic)) > 0
                           OR similarity(ng.fragment, topic) > 0.4
                    ))
            ),
            ranked_results AS (
                SELECT DISTINCT ON (poem_id)
                    poem_id,
                    "Row_ID" as row_id,
                    "Title_raw" as title_raw,
                    "Poem_line_raw" as poem_line_raw,
                    summary,
                    "مواضيع" as mawadi3,
                    "شخص",
                    MAX(fragment_score) as score,
                    (array_agg(fragment ORDER BY priority DESC, fragment_score DESC))[1] as matched_fragment,
                    (array_agg(fragment_type ORDER BY priority DESC, fragment_score DESC))[1] as fragment_type,
                    (array_agg(match_location ORDER BY priority DESC, fragment_score DESC))[1] as match_location,
                    CASE
                        WHEN (array_agg(match_location ORDER BY priority DESC, fragment_score DESC))[1] LIKE 'title%' THEN 'title'
                        WHEN (array_agg(match_location ORDER BY priority DESC, fragment_score DESC))[1] LIKE 'poem%' THEN 'poem_line'
                        WHEN (array_agg(match_location ORDER BY priority DESC, fragment_score DESC))[1] LIKE 'entity%' THEN 'شخص'
                        WHEN (array_agg(match_location ORDER BY priority DESC, fragment_score DESC))[1] LIKE 'summary%' THEN 'summary'
                        WHEN (array_agg(match_location ORDER BY priority DESC, fragment_score DESC))[1] LIKE 'مواضيع%' THEN 'مواضيع'
                        ELSE 'text'
                    END as match_tag
                FROM match_analysis
                WHERE fragment_score >= min_score
                GROUP BY poem_id, "Row_ID", "Title_raw", "Poem_line_raw", summary, "مواضيع", "شخص"
                ORDER BY poem_id, MAX(fragment_score) DESC
            )
            SELECT * FROM ranked_results
            WHERE poem_id <> ALL(seen_poems)
            ORDER BY score DESC
            LIMIT match_limit
        LOOP
            seen_poems := array_append(seen_poems, current_result.poem_id);
            
            normalized_score := LEAST(current_result.score / 8.0, 1.0);
            
            title_highlights := '[]'::JSONB;
            poem_highlights := '[]'::JSONB;
            summary_highlights := '[]'::JSONB;
            mawadi3_highlights := '[]'::JSONB;
            
            SELECT array_agg(DISTINCT value::text) INTO highlight_terms
            FROM jsonb_array_elements_text(current_term.query_variants);
            
            IF highlight_terms IS NOT NULL THEN
                FOR i IN 1..array_length(highlight_terms, 1) LOOP
                    IF position(lower(highlight_terms[i]) IN lower(current_result.title_raw)) > 0 
                       OR position(normalize_arabic(highlight_terms[i]) IN normalize_arabic(current_result.title_raw)) > 0 
                       OR similarity(highlight_terms[i], current_result.title_raw) > 0.4 THEN
                        title_highlights := title_highlights || jsonb_build_array(highlight_terms[i]);
                    END IF;
                END LOOP;
            END IF;
            
            IF current_result.match_location NOT LIKE 'title%' AND highlight_terms IS NOT NULL THEN
                FOR i IN 1..array_length(highlight_terms, 1) LOOP
                    IF position(lower(highlight_terms[i]) IN lower(current_result.poem_line_raw)) > 0 
                       OR position(normalize_arabic(highlight_terms[i]) IN normalize_arabic(current_result.poem_line_raw)) > 0 
                       OR similarity(highlight_terms[i], current_result.poem_line_raw) > 0.4 THEN
                        poem_highlights := poem_highlights || jsonb_build_array(highlight_terms[i]);
                    END IF;
                END LOOP;
                
                IF current_result."شخص" IS NOT NULL AND jsonb_array_length(current_result."شخص") > 0 THEN
                    FOR rf_record IN 
                        SELECT DISTINCT value::text as resolved_term
                        FROM jsonb_array_elements(current_result."شخص") entity,
                             jsonb_array_elements_text(entity->'resolved_from')
                    LOOP
                        IF position(lower(rf_record.resolved_term) IN lower(current_result.poem_line_raw)) > 0 
                           OR position(normalize_arabic(rf_record.resolved_term) IN normalize_arabic(current_result.poem_line_raw)) > 0 THEN
                            poem_highlights := poem_highlights || jsonb_build_array(rf_record.resolved_term);
                        END IF;
                    END LOOP;
                END IF;
            END IF;
            
            IF current_result.match_location LIKE 'summary%' AND highlight_terms IS NOT NULL THEN
                FOR i IN 1..array_length(highlight_terms, 1) LOOP
                    IF position(lower(highlight_terms[i]) IN lower(current_result.summary)) > 0 
                       OR position(normalize_arabic(highlight_terms[i]) IN normalize_arabic(current_result.summary)) > 0 
                       OR similarity(highlight_terms[i], current_result.summary) > 0.4 THEN
                        summary_highlights := summary_highlights || jsonb_build_array(highlight_terms[i]);
                    END IF;
                END LOOP;
            END IF;
            
            IF current_result.match_location LIKE 'مواضيع%' AND highlight_terms IS NOT NULL AND current_result.mawadi3 IS NOT NULL THEN
                FOR i IN 1..array_length(highlight_terms, 1) LOOP
                    FOR rf_record IN 
                        SELECT value::text as topic_text
                        FROM jsonb_array_elements_text(current_result.mawadi3)
                    LOOP
                        IF position(lower(highlight_terms[i]) IN lower(rf_record.topic_text)) > 0 
                           OR position(normalize_arabic(highlight_terms[i]) IN normalize_arabic(rf_record.topic_text)) > 0 
                           OR similarity(highlight_terms[i], rf_record.topic_text) > 0.4 THEN
                            mawadi3_highlights := mawadi3_highlights || jsonb_build_array(rf_record.topic_text);
                        END IF;
                    END LOOP;
                END LOOP;
            END IF;
            
            term_results := term_results || jsonb_build_object(
                'rank', term_count + 1,
                'poem_id', current_result.poem_id,
                'row_id', current_result.row_id,
                'title_raw', current_result.title_raw,
                'poem_line_raw', CASE WHEN current_result.match_location LIKE 'title%' THEN null ELSE current_result.poem_line_raw END,
                'score', round(normalized_score::numeric, 2),
                'raw_score', round(current_result.score::numeric, 2),
                'tag', current_result.match_tag,
                'matched_via', current_result.matched_fragment,
                'fragment_type', current_result.fragment_type,
                'match_location', current_result.match_location,
                'summary', CASE WHEN current_result.match_location LIKE 'summary%' THEN current_result.summary ELSE null END,
                'مواضيع', CASE WHEN current_result.match_location LIKE 'مواضيع%' THEN current_result.mawadi3 ELSE null END,
                'highlights', jsonb_build_object(
                    'title', title_highlights,
                    'poem_line', poem_highlights,
                    'summary', summary_highlights,
                    'مواضيع', mawadi3_highlights
                )
            );
            
            term_count := term_count + 1;
        END LOOP;
        
        per_term_results := per_term_results || jsonb_build_object(
            COALESCE(jsonb_array_element_text(current_term.query_variants, 0), 'unknown'),
            jsonb_build_object(
                'query', current_term.query_variants,
                'type', current_term.term_type,
                'confidence', current_term.confidence,
                'filter', current_term.entity_filter,
                'analytics', jsonb_build_object(
                    'total_matches', term_count
                ),
                'results', term_results
            )
        );
    END LOOP;
    
    WITH all_terms_results AS (
        SELECT (value->'results')::jsonb as term_results_data
        FROM jsonb_each(per_term_results)
    ),
    flattened AS (
        SELECT (jsonb_array_elements(term_results_data))::jsonb as result
        FROM all_terms_results
    ),
    deduplicated AS (
        SELECT DISTINCT ON ((result->>'poem_id')::int)
            result,
            (result->>'score')::numeric as score
        FROM flattened
        ORDER BY (result->>'poem_id')::int, (result->>'score')::numeric DESC
    ),
    ranked AS (
        SELECT 
            result,
            score,
            row_number() OVER (ORDER BY score DESC) as rank
        FROM deduplicated
    )
    SELECT jsonb_agg(result || jsonb_build_object('rank', rank) ORDER BY score DESC)
    INTO results_array
    FROM ranked
    LIMIT match_limit;
    
    RETURN jsonb_build_object(
        'merged_results', COALESCE(results_array, '[]'::JSONB),
        'per_term_breakdown', per_term_results,
        'metadata', jsonb_build_object(
            'original_query', query_text,
            'total_expansion_terms', jsonb_array_length(search_terms),
            'merged_total', COALESCE(jsonb_array_length(results_array), 0)
        )
    );
END;
$$;