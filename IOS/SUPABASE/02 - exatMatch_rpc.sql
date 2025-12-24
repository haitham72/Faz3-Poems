DROP FUNCTION IF EXISTS hybrid_search_exact(JSONB, INT);

CREATE OR REPLACE FUNCTION hybrid_search_exact(
  search_payload JSONB,
  match_limit INT DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  exact_query TEXT;
  intent_type TEXT;
  intent_confidence FLOAT;
  search_term JSONB;
  all_results JSONB := '[]'::JSONB;
  result_counter INT := 0;
BEGIN
  exact_query := search_payload->>'exact_query';
  intent_type := search_payload->>'intent_type';
  intent_confidence := COALESCE((search_payload->>'intent_confidence')::FLOAT, 0.5);
  
  FOR search_term IN SELECT * FROM jsonb_array_elements(search_payload->'search_terms')
  LOOP
    DECLARE
      term_text TEXT;
      term_type TEXT;
      normalized_term TEXT;
      tsquery_term TEXT;
      word_count INT;
      result_row RECORD;
    BEGIN
      term_text := search_term->>'term';
      term_type := search_term->>'type';
      
      -- Normalize term
      normalized_term := regexp_replace(term_text, '[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED\u0640]', '', 'g');
      normalized_term := regexp_replace(normalized_term, '[إأآا]', 'ا', 'g');
      normalized_term := regexp_replace(normalized_term, 'ى', 'ي', 'g');
      normalized_term := regexp_replace(normalized_term, '[ؤئ]', 'ء', 'g');
      normalized_term := trim(normalized_term);
      
      -- Count words in term
      word_count := array_length(string_to_array(normalized_term, ' '), 1);
      
      -- Build tsquery for multi-word
      tsquery_term := replace(normalized_term, ' ', ' & ');
      
      FOR result_row IN
        WITH text_matches AS (
          SELECT 
            e.*,
            
            -- EXACT PHRASE MATCH (highest priority)
            CASE 
              WHEN e."Poem_line_cleaned" LIKE '%' || normalized_term || '%' THEN 1.0
              WHEN e."Title_cleaned" LIKE '%' || normalized_term || '%' THEN 1.0
              ELSE 0.0 
            END as exact_phrase_match,
            
            -- FTS MATCH (all words present, any order)
            CASE 
              WHEN word_count > 1 AND to_tsvector('arabic', e."Poem_line_cleaned") @@ to_tsquery('arabic', tsquery_term)
              THEN 0.7
              WHEN word_count = 1 AND to_tsvector('arabic', e."Poem_line_cleaned") @@ to_tsquery('arabic', normalized_term)
              THEN 1.0
              ELSE 0.0 
            END as fts_score,
            
            -- FUZZY SIMILARITY (scattered words)
            CASE 
              WHEN word_count > 1 THEN similarity(e."Poem_line_cleaned", normalized_term) * 0.4
              ELSE 0.0
            END as fuzzy_score,
            
            -- TITLE MATCH
            CASE 
              WHEN e."Title_cleaned" LIKE '%' || normalized_term || '%' THEN 1.0 
              ELSE 0.0 
            END as title_match,
            
            -- METADATA MATCHING
            CASE WHEN e."شخص"::text LIKE '%' || normalized_term || '%' THEN 1.0 ELSE 0.0 END as person_match,
            CASE WHEN e."أحداث"::text LIKE '%' || normalized_term || '%' THEN 1.0 ELSE 0.0 END as event_match,
            CASE WHEN e."أماكن"::text LIKE '%' || normalized_term || '%' THEN 1.0 ELSE 0.0 END as place_match,
            CASE WHEN e."مواضيع"::text LIKE '%' || normalized_term || '%' THEN 1.0 ELSE 0.0 END as topic_match,
            CASE WHEN e."دين"::text LIKE '%' || normalized_term || '%' THEN 1.0 ELSE 0.0 END as religion_match,
            
            -- PHRASE POSITION (only if exact phrase found)
            CASE 
              WHEN e."Poem_line_cleaned" LIKE '%' || normalized_term || '%' THEN
                (
                  -- Find start word index of phrase
                  WITH phrase_start AS (
                    SELECT strpos(e."Poem_line_cleaned", normalized_term) as char_pos
                  ),
                  words_before AS (
                    SELECT array_length(
                      string_to_array(
                        substring(e."Poem_line_cleaned", 1, (SELECT char_pos FROM phrase_start) - 1),
                        ' '
                      ),
                      1
                    ) as start_idx
                  )
                  SELECT ARRAY(
                    SELECT generate_series(
                      COALESCE((SELECT start_idx FROM words_before), 0),
                      COALESCE((SELECT start_idx FROM words_before), 0) + word_count - 1
                    )
                  )
                )
              ELSE ARRAY[]::INT[]
            END as phrase_positions,
            
            -- RESOLVED_FROM POSITIONS (for metadata-only matches)
            (
              SELECT jsonb_agg(elem)
              FROM jsonb_array_elements(e."شخص") elem
              WHERE elem->>'name' LIKE '%' || normalized_term || '%'
                 OR EXISTS (
                   SELECT 1 
                   FROM jsonb_array_elements_text(elem->'resolved_from') resolved
                   WHERE normalized_term LIKE '%' || resolved || '%'
                      OR resolved LIKE '%' || normalized_term || '%'
                 )
            ) as matched_persons
            
          FROM "Exact_search" e
          WHERE 
            e."Poem_line_cleaned" LIKE '%' || normalized_term || '%'
            OR e."Title_cleaned" LIKE '%' || normalized_term || '%'
            OR (word_count = 1 AND to_tsvector('arabic', e."Poem_line_cleaned") @@ to_tsquery('arabic', normalized_term))
            OR (word_count > 1 AND to_tsvector('arabic', e."Poem_line_cleaned") @@ to_tsquery('arabic', tsquery_term))
            OR (word_count > 1 AND similarity(e."Poem_line_cleaned", normalized_term) > 0.3)
            OR e."شخص"::text LIKE '%' || normalized_term || '%'
            OR e."أحداث"::text LIKE '%' || normalized_term || '%'
            OR e."أماكن"::text LIKE '%' || normalized_term || '%'
            OR e."مواضيع"::text LIKE '%' || normalized_term || '%'
            OR e."دين"::text LIKE '%' || normalized_term || '%'
        ),
        
        scored_results AS (
          SELECT 
            t.*,
            
            -- TEXT SCORE (combined)
            GREATEST(
              t.exact_phrase_match,
              t.fts_score,
              t.fuzzy_score
            ) as text_score,
            
            -- LOCATION WEIGHT
            CASE WHEN t.title_match = 1.0 THEN 1.5 ELSE 1.0 END as location_weight,
            
            -- TYPE-ALIGNED METADATA BOOST
            CASE term_type
              WHEN 'name' THEN t.person_match * 0.3
              WHEN 'title' THEN t.person_match * 0.3
              WHEN 'nickname' THEN t.person_match * 0.3
              WHEN 'place' THEN t.place_match * 0.3
              WHEN 'event' THEN t.event_match * 0.3
              WHEN 'religious' THEN t.religion_match * 0.3
              ELSE (t.person_match + t.place_match + t.topic_match) * 0.1
            END as metadata_boost,
            
            -- FINAL POSITIONS (phrase or resolved_from)
            CASE 
              WHEN array_length(t.phrase_positions, 1) > 0 THEN t.phrase_positions
              WHEN t.person_match = 1.0 THEN
                (
                  SELECT ARRAY_AGG(DISTINCT i-1 ORDER BY i-1)
                  FROM unnest(string_to_array(t."Poem_line_cleaned", ' ')) 
                  WITH ORDINALITY AS w(word, i)
                  WHERE EXISTS (
                    SELECT 1 
                    FROM jsonb_array_elements(t.matched_persons) person
                    CROSS JOIN jsonb_array_elements_text(person->'resolved_from') resolved
                    WHERE normalize_arabic(w.word) LIKE '%' || resolved || '%'
                  )
                )
              ELSE ARRAY[]::INT[]
            END as final_positions,
            
            -- HIGHLIGHT WORD (actual text from raw)
            CASE 
              WHEN array_length(t.phrase_positions, 1) > 0 THEN
                (
                  SELECT string_agg(word, ' ' ORDER BY idx)
                  FROM (
                    SELECT unnest(string_to_array(t."Poem_line_raw", ' ')) as word, 
                           generate_series(0, array_length(string_to_array(t."Poem_line_raw", ' '), 1) - 1) as idx
                  ) raw_words
                  WHERE idx = ANY(t.phrase_positions)
                )
              WHEN t.person_match = 1.0 THEN
                (
                  SELECT string_agg(w.word, ' ')
                  FROM unnest(string_to_array(t."Poem_line_raw", ' ')) 
                  WITH ORDINALITY AS w(word, i)
                  WHERE EXISTS (
                    SELECT 1 
                    FROM jsonb_array_elements(t.matched_persons) person
                    CROSS JOIN jsonb_array_elements_text(person->'resolved_from') resolved
                    WHERE normalize_arabic(w.word) LIKE '%' || resolved || '%'
                  )
                  LIMIT 1
                )
              ELSE term_text
            END as highlight_word
            
          FROM text_matches t
        ),
        
        final_ranked AS (
          SELECT 
            s.*,
            (s.text_score * s.location_weight) + s.metadata_boost as final_score,
            
            CASE 
              WHEN s.text_score > 0 AND s.metadata_boost > 0 THEN 'text+metadata'
              WHEN s.text_score > 0 THEN 'text_only'
              WHEN s.metadata_boost > 0 THEN 'metadata_only'
              ELSE 'weak'
            END as match_source,
            
            CASE 
              WHEN s.title_match = 1.0 THEN 'title'
              ELSE 'poem_line'
            END as match_location,
            
            -- MATCH TYPE DETAIL
            CASE 
              WHEN s.exact_phrase_match = 1.0 THEN 'exact_phrase'
              WHEN s.fts_score > 0 THEN 'fts_all_words'
              WHEN s.fuzzy_score > 0 THEN 'fuzzy_scattered'
              ELSE 'metadata_only'
            END as match_type
            
          FROM scored_results s
          WHERE 
            s.text_score > 0 OR 
            s.metadata_boost > 0
          ORDER BY final_score DESC
          LIMIT match_limit
        )
        
        SELECT * FROM final_ranked
      LOOP
        result_counter := result_counter + 1;
        
        all_results := all_results || jsonb_build_object(
          'rank', result_counter,
          'query', term_text,
          'poem_id', result_row.poem_id,
          'row_id', result_row."Row_ID",
          'title_raw', result_row."Title_raw",
          'poem_line_raw', result_row."Poem_line_raw",
          'summary', result_row.summary,
          'highlight_word', result_row.highlight_word,
          'highlight_positions', COALESCE(result_row.final_positions, ARRAY[]::INT[]),
          'match_source', result_row.match_source,
          'match_type', result_row.match_type,
          'match_location', result_row.match_location,
          'score', round(result_row.final_score::numeric, 3),
          'metadata', jsonb_build_object(
            'البحر', result_row."البحر",
            'قافية', result_row."قافية",
            'روي', result_row."روي",
            'شخص', result_row."شخص",
            'sentiments', result_row.sentiments,
            'أحداث', result_row."أحداث",
            'دين', result_row."دين",
            'مواضيع', result_row."مواضيع",
            'أماكن', result_row."أماكن",
            'تصنيف', result_row."تصنيف"
          )
        );
        
        EXIT WHEN result_counter >= match_limit;
      END LOOP;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'exact_query', exact_query,
    'total_results', result_counter,
    'results', all_results
  );
END;
$$;

GRANT EXECUTE ON FUNCTION hybrid_search_exact(JSONB, INT) TO anon, authenticated, service_role;