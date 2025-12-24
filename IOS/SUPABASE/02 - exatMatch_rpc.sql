CREATE OR REPLACE FUNCTION hybrid_search_exact(
    search_payload JSONB,
    match_limit INT DEFAULT 50
)
RETURNS JSONB AS $$
DECLARE
    query_text TEXT;
    word_count INT;
    result_json JSONB;
    current_result RECORD;
    results_array JSONB := '[]'::JSONB;
    total_count INT := 0;
    search_terms JSONB;
    has_expansion BOOLEAN := false;
    all_queries TEXT[] := ARRAY[]::TEXT[];
    single_term TEXT;
    -- Highlighting variables
    highlight_word TEXT;
    positions INT[];
    match_pos INT;
    words_array TEXT[];
    i INT;
    search_text TEXT;
    before_text TEXT;
    word_idx INT;
    phrase_word_count INT;
    matched_term TEXT;
    match_weight NUMERIC;
BEGIN
    -- Extract query
    query_text := search_payload->>'exact_query';
    IF query_text IS NULL OR trim(query_text) = '' THEN
        RETURN jsonb_build_object(
            'exact_query', query_text,
            'total_results', 0,
            'results', '[]'::JSONB
        );
    END IF;

    -- Check for expansion terms
    search_terms := search_payload->'search_terms';
    IF search_terms IS NOT NULL AND jsonb_array_length(search_terms) > 0 THEN
        has_expansion := true;
        -- Extract all term strings into array
        SELECT array_agg(value->>'term')
        INTO all_queries
        FROM jsonb_array_elements(search_terms);
    ELSE
        -- No expansion, just search original query
        all_queries := ARRAY[query_text];
    END IF;

    -- Count words to detect phrases
    word_count := array_length(string_to_array(trim(query_text), ' '), 1);

    -- STRATEGY: Exact phrase (2-10 words) OR single word
    IF word_count BETWEEN 2 AND 10 THEN
        -- ==================== PHRASE SEARCH ====================
        FOR current_result IN
            WITH ranked_results AS (
                SELECT DISTINCT ON (poem_id, "Row_ID")
                    poem_id,
                    "Row_ID" as row_id,
                    "Title_raw" as title_raw,
                    "Poem_line_raw" as poem_line_raw,
                    "Poem_line_cleaned" as poem_line_cleaned,
                    summary,
                    "البحر" as bahr,
                    "قافية" as qafiya,
                    jsonb_build_object(
                        'شخص', "شخص",
                        'أماكن', "أماكن",
                        'أحداث', "أحداث",
                        'دين', "دين",
                        'مواضيع', "مواضيع",
                        'sentiments', sentiments,
                        'تصنيف', "تصنيف",
                        'البحر', "البحر",
                        'قافية', "قافية",
                        'روي', "روي"
                    ) as metadata,
                    
                    -- SCORING - Check against ALL search terms WITH WEIGHTS
                    CASE
                        -- Check each expanded term for exact phrase matches
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE position(lower(term->>'term') IN lower("Title_cleaned")) > 0
                        ) THEN (
                            SELECT COALESCE((term->>'weight')::NUMERIC, 1.0) * 1.5
                            FROM jsonb_array_elements(search_terms) AS term
                            WHERE position(lower(term->>'term') IN lower("Title_cleaned")) > 0
                            ORDER BY COALESCE((term->>'weight')::NUMERIC, 1.0) DESC
                            LIMIT 1
                        )
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE position(lower(term->>'term') IN lower("Poem_line_cleaned")) > 0
                        ) THEN (
                            SELECT COALESCE((term->>'weight')::NUMERIC, 1.0) * 1.0
                            FROM jsonb_array_elements(search_terms) AS term
                            WHERE position(lower(term->>'term') IN lower("Poem_line_cleaned")) > 0
                            ORDER BY COALESCE((term->>'weight')::NUMERIC, 1.0) DESC
                            LIMIT 1
                        )
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE to_tsvector('arabic', "Poem_line_cleaned") @@ plainto_tsquery('arabic', term->>'term')
                        ) THEN (
                            SELECT COALESCE((term->>'weight')::NUMERIC, 1.0) * 0.7
                            FROM jsonb_array_elements(search_terms) AS term
                            WHERE to_tsvector('arabic', "Poem_line_cleaned") @@ plainto_tsquery('arabic', term->>'term')
                            ORDER BY COALESCE((term->>'weight')::NUMERIC, 1.0) DESC
                            LIMIT 1
                        )
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE similarity("Poem_line_cleaned", term->>'term') > 0.15
                        ) THEN (
                            SELECT COALESCE((term->>'weight')::NUMERIC, 1.0) * similarity("Poem_line_cleaned", term->>'term') * 0.6
                            FROM jsonb_array_elements(search_terms) AS term
                            WHERE similarity("Poem_line_cleaned", term->>'term') > 0.15
                            ORDER BY (COALESCE((term->>'weight')::NUMERIC, 1.0) * similarity("Poem_line_cleaned", term->>'term')) DESC
                            LIMIT 1
                        )
                        ELSE 0.1
                    END as score,
                    
                    -- MATCH TYPE - Based on which term matched
                    CASE
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE position(lower(term->>'term') IN lower("Title_cleaned")) > 0 
                               OR position(lower(term->>'term') IN lower("Poem_line_cleaned")) > 0
                        ) THEN 'exact_phrase'
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE to_tsvector('arabic', "Poem_line_cleaned") @@ plainto_tsquery('arabic', term->>'term')
                        ) THEN 'fts'
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE similarity("Poem_line_cleaned", term->>'term') > 0.15
                        ) THEN 'fuzzy'
                        ELSE 'metadata_only'
                    END as match_type,
                    
                    -- MATCH LOCATION
                    CASE
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE position(lower(term->>'term') IN lower("Title_cleaned")) > 0
                        ) THEN 'title'
                        WHEN EXISTS (
                            SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                            WHERE position(lower(term->>'term') IN lower("Poem_line_cleaned")) > 0
                        ) THEN 'poem_line'
                        ELSE 'metadata'
                    END as match_location,
                    
                    -- Store which term actually matched (highest weighted match)
                    (
                        SELECT term->>'term' 
                        FROM jsonb_array_elements(search_terms) AS term
                        WHERE position(lower(term->>'term') IN lower("Title_cleaned")) > 0
                           OR position(lower(term->>'term') IN lower("Poem_line_cleaned")) > 0
                        ORDER BY COALESCE((term->>'weight')::NUMERIC, 1.0) DESC
                        LIMIT 1
                    ) as matched_term,
                    
                    -- Store the weight of matched term
                    (
                        SELECT COALESCE((term->>'weight')::NUMERIC, 1.0)
                        FROM jsonb_array_elements(search_terms) AS term
                        WHERE position(lower(term->>'term') IN lower("Title_cleaned")) > 0
                           OR position(lower(term->>'term') IN lower("Poem_line_cleaned")) > 0
                        ORDER BY COALESCE((term->>'weight')::NUMERIC, 1.0) DESC
                        LIMIT 1
                    ) as match_weight
                    
                FROM "Exact_search"
                WHERE 
                    -- Text matches ANY of the search terms
                    EXISTS (
                        SELECT 1 FROM jsonb_array_elements(search_terms) AS term
                        WHERE position(lower(term->>'term') IN lower("Poem_line_cleaned")) > 0
                           OR position(lower(term->>'term') IN lower("Title_cleaned")) > 0
                           OR to_tsvector('arabic', "Poem_line_cleaned") @@ plainto_tsquery('arabic', term->>'term')
                           OR similarity("Poem_line_cleaned", term->>'term') > 0.15
                    )
            )
            SELECT * FROM ranked_results
            WHERE score > 0.1
            ORDER BY score DESC, poem_id, row_id
            LIMIT match_limit
        LOOP
            -- ==================== HIGHLIGHTING EXTRACTION ====================
            -- Reset variables
            highlight_word := '';
            positions := ARRAY[]::INT[];
            
            -- Use the actual matched term, not the original query
            matched_term := COALESCE(current_result.matched_term, query_text);
            
            -- CRITICAL FIX: Search in the field that ACTUALLY contains the match
            IF current_result.match_location = 'title' THEN
                search_text := current_result.title_raw;
            ELSE
                search_text := current_result.poem_line_raw;
            END IF;
            
            -- Split into words (space-separated)
            words_array := string_to_array(search_text, ' ');
            
            -- Find phrase position in RAW text (case-insensitive)
            match_pos := position(lower(matched_term) IN lower(search_text));
            
            IF match_pos > 0 THEN
                -- Extract actual matched text from raw (preserves diacritics)
                highlight_word := substring(
                    search_text 
                    FROM match_pos 
                    FOR length(matched_term)
                );
                
                -- Calculate word positions
                -- Count words before match position
                before_text := substring(search_text FROM 1 FOR match_pos - 1);
                word_idx := array_length(string_to_array(trim(before_text), ' '), 1);
                IF word_idx IS NULL THEN word_idx := 0; END IF;
                
                phrase_word_count := array_length(string_to_array(trim(matched_term), ' '), 1);
                
                -- Build positions array
                FOR i IN 0..(phrase_word_count - 1) LOOP
                    positions := array_append(positions, word_idx + i);
                END LOOP;
            ELSE
                -- Fallback: if not found in expected location, try the other field
                IF current_result.match_location = 'title' THEN
                    search_text := current_result.poem_line_raw;
                ELSE
                    search_text := current_result.title_raw;
                END IF;
                
                match_pos := position(lower(matched_term) IN lower(search_text));
                IF match_pos > 0 THEN
                    words_array := string_to_array(search_text, ' ');
                    highlight_word := substring(search_text FROM match_pos FOR length(matched_term));
                    
                    before_text := substring(search_text FROM 1 FOR match_pos - 1);
                    word_idx := array_length(string_to_array(trim(before_text), ' '), 1);
                    IF word_idx IS NULL THEN word_idx := 0; END IF;
                    
                    phrase_word_count := array_length(string_to_array(trim(matched_term), ' '), 1);
                    FOR i IN 0..(phrase_word_count - 1) LOOP
                        positions := array_append(positions, word_idx + i);
                    END LOOP;
                END IF;
            END IF;
            
            -- Build result object
            results_array := results_array || jsonb_build_object(
                'rank', total_count + 1,
                'query', query_text,
                'matched_term', COALESCE(current_result.matched_term, query_text),
                'match_weight', COALESCE(current_result.match_weight, 1.0),
                'poem_id', current_result.poem_id,
                'row_id', current_result.row_id,
                'title_raw', current_result.title_raw,
                'poem_line_raw', current_result.poem_line_raw,
                'summary', current_result.summary,
                'metadata', current_result.metadata,
                'score', current_result.score,
                'match_type', current_result.match_type,
                'match_location', current_result.match_location,
                'match_source', 'text_only',
                'highlight_word', highlight_word,
                'highlight_positions', positions
            );
            
            total_count := total_count + 1;
        END LOOP;
        
    ELSE
        -- ==================== SINGLE WORD SEARCH ====================
        FOR current_result IN
            WITH ranked_results AS (
                SELECT DISTINCT ON (poem_id, "Row_ID")
                    poem_id,
                    "Row_ID" as row_id,
                    "Title_raw" as title_raw,
                    "Poem_line_raw" as poem_line_raw,
                    "Poem_line_cleaned" as poem_line_cleaned,
                    summary,
                    "البحر" as bahr,
                    "قافية" as qafiya,
                    jsonb_build_object(
                        'شخص', "شخص",
                        'أماكن', "أماكن",
                        'أحداث', "أحداث",
                        'دين', "دين",
                        'مواضيع', "مواضيع",
                        'sentiments', sentiments,
                        'تصنيف', "تصنيف",
                        'البحر', "البحر",
                        'قافية', "قافية",
                        'روي', "روي"
                    ) as metadata,
                    
                    -- Single word scoring - check ALL terms
                    CASE
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE lower("Title_cleaned") ~ ('\y' || lower(q) || '\y')
                        ) THEN 1.5
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE lower("Poem_line_cleaned") ~ ('\y' || lower(q) || '\y')
                        ) THEN 1.0
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE to_tsvector('arabic', "Poem_line_cleaned") @@ plainto_tsquery('arabic', q)
                        ) THEN 0.7
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE similarity("Poem_line_cleaned", q) > 0.2
                        ) THEN (
                            SELECT MAX(similarity("Poem_line_cleaned", q)) * 0.5
                            FROM unnest(all_queries) AS q
                        )
                        ELSE 0.1
                    END as score,
                    
                    CASE
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE lower("Title_cleaned") ~ ('\y' || lower(q) || '\y')
                               OR lower("Poem_line_cleaned") ~ ('\y' || lower(q) || '\y')
                        ) THEN 'exact_word'
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE to_tsvector('arabic', "Poem_line_cleaned") @@ plainto_tsquery('arabic', q)
                        ) THEN 'fts'
                        ELSE 'fuzzy'
                    END as match_type,
                    
                    CASE
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE lower("Title_cleaned") ~ ('\y' || lower(q) || '\y')
                        ) THEN 'title'
                        WHEN EXISTS (
                            SELECT 1 FROM unnest(all_queries) AS q
                            WHERE lower("Poem_line_cleaned") ~ ('\y' || lower(q) || '\y')
                        ) THEN 'poem_line'
                        ELSE 'metadata'
                    END as match_location,
                    
                    (
                        SELECT q FROM unnest(all_queries) AS q
                        WHERE lower("Title_cleaned") ~ ('\y' || lower(q) || '\y')
                           OR lower("Poem_line_cleaned") ~ ('\y' || lower(q) || '\y')
                        LIMIT 1
                    ) as matched_term
                    
                FROM "Exact_search"
                WHERE 
                    EXISTS (
                        SELECT 1 FROM unnest(all_queries) AS q
                        WHERE lower("Poem_line_cleaned") ~ ('\y' || lower(q) || '\y')
                           OR lower("Title_cleaned") ~ ('\y' || lower(q) || '\y')
                           OR to_tsvector('arabic', "Poem_line_cleaned") @@ plainto_tsquery('arabic', q)
                           OR similarity("Poem_line_cleaned", q) > 0.2
                    )
            )
            SELECT * FROM ranked_results
            WHERE score > 0.1
            ORDER BY score DESC, poem_id, row_id
            LIMIT match_limit
        LOOP
            -- Single word highlighting
            -- Reset variables
            highlight_word := '';
            positions := ARRAY[]::INT[];
            
            matched_term := COALESCE(current_result.matched_term, query_text);
            
            -- Search in correct field
            IF current_result.match_location = 'title' THEN
                search_text := current_result.title_raw;
            ELSE
                search_text := current_result.poem_line_raw;
            END IF;
            
            words_array := string_to_array(search_text, ' ');
            
            -- Find all occurrences of matched term
            FOR i IN 1..array_length(words_array, 1) LOOP
                IF position(lower(matched_term) IN lower(words_array[i])) > 0 THEN
                    positions := array_append(positions, i - 1); -- 0-indexed
                    IF highlight_word = '' THEN
                        highlight_word := words_array[i];
                    END IF;
                END IF;
            END LOOP;
            
            -- Fallback: try other field if nothing found
            IF array_length(positions, 1) IS NULL THEN
                IF current_result.match_location = 'title' THEN
                    search_text := current_result.poem_line_raw;
                ELSE
                    search_text := current_result.title_raw;
                END IF;
                
                words_array := string_to_array(search_text, ' ');
                FOR i IN 1..array_length(words_array, 1) LOOP
                    IF position(lower(matched_term) IN lower(words_array[i])) > 0 THEN
                        positions := array_append(positions, i - 1);
                        IF highlight_word = '' THEN
                            highlight_word := words_array[i];
                        END IF;
                    END IF;
                END LOOP;
            END IF;
            
            results_array := results_array || jsonb_build_object(
                'rank', total_count + 1,
                'query', query_text,
                'matched_term', COALESCE(current_result.matched_term, query_text),
                'poem_id', current_result.poem_id,
                'row_id', current_result.row_id,
                'title_raw', current_result.title_raw,
                'poem_line_raw', current_result.poem_line_raw,
                'summary', current_result.summary,
                'metadata', current_result.metadata,
                'score', current_result.score,
                'match_type', current_result.match_type,
                'match_location', current_result.match_location,
                'match_source', 'text_only',
                'highlight_word', highlight_word,
                'highlight_positions', positions
            );
            
            total_count := total_count + 1;
        END LOOP;
    END IF;

    -- Return final JSON
    RETURN jsonb_build_object(
        'exact_query', query_text,
        'total_results', total_count,
        'results', results_array
    );
END;
$$ LANGUAGE plpgsql;