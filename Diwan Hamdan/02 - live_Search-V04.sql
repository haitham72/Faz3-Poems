-- =====================================================
-- LIVE SEARCH WITH INLINE SUGGESTIONS
-- First 3 rows = suggestions (only title populated)
-- Remaining rows = actual poem results
-- =====================================================

DROP FUNCTION IF EXISTS live_search(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION live_search(
    search_query TEXT,
    result_limit INT DEFAULT 10
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    score NUMERIC,
    tokens_matched BIGINT,
    total_tokens BIGINT,
    matched_tokens TEXT[],
    is_suggestion BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    cleaned_query TEXT;
    tokens TEXT[];
    token_count INT;
    result_count INT;
    avg_score NUMERIC;
    should_show_suggestions BOOLEAN;
BEGIN
    -- Preprocess query
    cleaned_query := preprocess_query(search_query);
    tokens := string_to_array(cleaned_query, ' ');
    token_count := array_length(tokens, 1);
    
    -- First, check result quality
    WITH preview AS (
        SELECT COUNT(*), AVG(
            CASE WHEN d."Title_cleaned" ILIKE '%' || cleaned_query || '%' THEN 100 ELSE 0 END +
            CASE WHEN d."Poem_line_cleaned" ILIKE '%' || cleaned_query || '%' THEN 90 ELSE 0 END
        ) as avg_score
        FROM "Diwan_Hamdan" d
        WHERE EXISTS (
            SELECT 1 FROM unnest(tokens) t
            WHERE d."Title_cleaned" ILIKE '%' || t || '%' 
               OR d."Poem_line_cleaned" ILIKE '%' || t || '%'
        )
        LIMIT 20
    )
    SELECT p.count, p.avg_score
    INTO result_count, avg_score
    FROM preview p;
    
    -- Decide if suggestions needed
    should_show_suggestions := (
        result_count < 5 OR 
        avg_score < 50 OR 
        search_query ILIKE '%هل%' OR 
        search_query ILIKE '%قصائد%' OR
        search_query ILIKE '%ابحث%'
    );
    
    RETURN QUERY
    -- PART 1: Suggestions (first 3 rows if needed)
    (
        SELECT 
            -1 as poem_id,
            -1 as row_id,
            qs.full_question as title_cleaned,
            NULL::TEXT as poem_line_cleaned,
            NULL::NUMERIC as score,
            NULL::BIGINT as tokens_matched,
            NULL::BIGINT as total_tokens,
            qs.search_terms as matched_tokens,
            true as is_suggestion
        FROM question_suggestions qs
        WHERE should_show_suggestions
          AND qs.question_normalized ILIKE normalize_arabic(search_query) || '%'
        ORDER BY qs.is_boosted DESC, qs.popularity DESC
        LIMIT 3
    )
    
    UNION ALL
    
    -- PART 2: Actual poem results
    (
        WITH 
        token_patterns AS (
            SELECT unnest(tokens) as token
        ),
        search_results AS (
            SELECT 
                d.poem_id,
                d."Row_ID",
                d."Title_cleaned",
                d."Poem_line_cleaned",
                
                (
                    SELECT COUNT(DISTINCT tp.token)
                    FROM token_patterns tp
                    WHERE 
                        d."Title_cleaned" ILIKE '%' || tp.token || '%' OR
                        d."Poem_line_cleaned" ILIKE '%' || tp.token || '%'
                ) AS tokens_matched_count,
                
                (
                    CASE WHEN d."Title_cleaned" ILIKE '%' || cleaned_query || '%' THEN 100 ELSE 0 END +
                    CASE WHEN d."Poem_line_cleaned" ILIKE '%' || cleaned_query || '%' THEN 90 ELSE 0 END +
                    (SELECT COUNT(DISTINCT tp.token)::NUMERIC * 20
                     FROM token_patterns tp
                     WHERE d."Title_cleaned" ILIKE '%' || tp.token || '%' 
                        OR d."Poem_line_cleaned" ILIKE '%' || tp.token || '%')
                ) AS calc_score,
                
                ARRAY(
                    SELECT DISTINCT tp.token
                    FROM token_patterns tp
                    WHERE 
                        d."Title_cleaned" ILIKE '%' || tp.token || '%' OR
                        d."Poem_line_cleaned" ILIKE '%' || tp.token || '%'
                ) AS matched_token_array
                
            FROM "Diwan_Hamdan" d
            WHERE 
                EXISTS (
                    SELECT 1 FROM token_patterns tp
                    WHERE 
                        d."Title_cleaned" ILIKE '%' || tp.token || '%' OR
                        d."Poem_line_cleaned" ILIKE '%' || tp.token || '%'
                )
        )
        SELECT 
            sr.poem_id,
            sr."Row_ID",
            sr."Title_cleaned",
            sr."Poem_line_cleaned",
            sr.calc_score,
            sr.tokens_matched_count::BIGINT,
            token_count::BIGINT,
            sr.matched_token_array,
            false as is_suggestion
        FROM search_results sr
        ORDER BY sr.calc_score DESC, sr.poem_id DESC
        LIMIT result_limit
    );
    
END;
$$;


-- =====================================================
-- USAGE & EXPECTED OUTPUT
-- =====================================================

/*
Query: "هل هناك قصائد عن محمد بن راشد"

Returns array:
[
  // Row 1: Suggestion
  {
    "poem_id": -1,
    "row_id": -1,
    "title": "هل هناك قصائد عن محمد بن راشد؟",
    "line": null,
    "score": null,
    "tokens_matched": null,
    "total_tokens": null,
    "matched_tokens": ["راشد", "محمد بن راشد"],
    "is_suggestion": true
  },
  // Row 2: Suggestion
  {
    "poem_id": -1,
    "row_id": -1,
    "title": "هل هناك قصائد عن الحب والغزل؟",
    "line": null,
    "score": null,
    "tokens_matched": null,
    "total_tokens": null,
    "matched_tokens": ["حب", "غزل"],
    "is_suggestion": true
  },
  // Row 3: Suggestion
  {
    "poem_id": -1,
    "row_id": -1,
    "title": "قصائد عن الوطن",
    "line": null,
    "score": null,
    "tokens_matched": null,
    "total_tokens": null,
    "matched_tokens": ["وطن", "الامارات"],
    "is_suggestion": true
  },
  // Row 4+: Actual results
  {
    "poem_id": 45,
    "row_id": 123,
    "title": "بن راشد الخير",
    "line": "محمد بن راشد يا فخر الديرة",
    "score": 180,
    "tokens_matched": 3,
    "total_tokens": 4,
    "matched_tokens": ["محمد", "بن", "راشد"],
    "is_suggestion": false
  },
  ...
]
*/


-- =====================================================
-- HTML/MOBILE INTEGRATION (SAME CODE!)
-- =====================================================

/*
const { data } = await supabase.rpc('live_search', {
  search_query: query,
  result_limit: 10
});

// Filter suggestions vs results
const suggestions = data.filter(item => item.is_suggestion);
const results = data.filter(item => !item.is_suggestion);

// Display
if (suggestions.length > 0) {
  suggestionsDiv.innerHTML = suggestions.map(s => `
    <div class="suggestion-item" data-terms="${s.matched_tokens.join(',')}">
      💡 ${s.title}
    </div>
  `).join('');
  
  // Click handler
  document.querySelectorAll('.suggestion-item').forEach(item => {
    item.addEventListener('click', async () => {
      const terms = item.dataset.terms.split(',');
      searchInput.value = terms.join(' ');
      // Re-search with the suggestion's terms
      const { data: newResults } = await supabase.rpc('live_search', {
        search_query: terms.join(' '),
        result_limit: 20
      });
      displayResults(newResults.filter(r => !r.is_suggestion));
    });
  });
}

// Display results (same as before!)
resultsDiv.innerHTML = results.map(result => `
  <div class="result-item">
    <div class="result-title">${result.title}</div>
    <div class="result-line">${highlightTokens(result.line, result.matched_tokens)}</div>
    <div class="result-meta">
      <span>${result.tokens_matched}/${result.total_tokens} tokens</span>
      <span>Score: ${Math.round(result.score)}</span>
    </div>
  </div>
`).join('');


// OR even simpler - treat them all the same:
resultsDiv.innerHTML = data.map(item => {
  if (item.is_suggestion) {
    return `
      <div class="suggestion-item" data-terms="${item.matched_tokens.join(',')}">
        💡 ${item.title}
      </div>
    `;
  } else {
    return `
      <div class="result-item">
        <div class="result-title">${item.title}</div>
        <div class="result-line">${item.line}</div>
      </div>
    `;
  }
}).join('');
*/