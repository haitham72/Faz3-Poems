-- =====================================================
-- QUESTION AUTOCOMPLETE SYSTEM
-- Shows "هل هناك قصائد عن {suggestion}" as user types
-- =====================================================

-- Table for storing popular question templates
CREATE TABLE IF NOT EXISTS question_suggestions (
    id SERIAL PRIMARY KEY,
    full_question TEXT NOT NULL,           -- "هل هناك قصائد عن محمد بن زايد؟"
    question_normalized TEXT NOT NULL,     -- Normalized for matching
    category TEXT,                         -- "شخصيات", "مواضيع", "أماكن"
    search_terms TEXT[] NOT NULL,          -- ["زايد", "محمد بن زايد"]
    popularity INT DEFAULT 0,              -- Click tracking
    is_boosted BOOLEAN DEFAULT false,      -- Pre-curated high-quality
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for fast prefix matching
DROP INDEX IF EXISTS idx_question_normalized;
CREATE INDEX idx_question_normalized ON question_suggestions (question_normalized text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_question_popularity ON question_suggestions (popularity DESC);
CREATE INDEX IF NOT EXISTS idx_question_boosted ON question_suggestions (is_boosted, popularity DESC);

-- =====================================================
-- SEED DATA: Popular Questions
-- =====================================================

INSERT INTO question_suggestions (full_question, question_normalized, category, search_terms, popularity, is_boosted) VALUES
-- Questions starting with "هل هناك قصائد عن"
('هل هناك قصائد عن محمد بن زايد؟', normalize_arabic('هل هناك قصائد عن محمد بن زايد؟'), 'شخصيات', ARRAY['زايد', 'محمد بن زايد'], 500, true),
('هل هناك قصائد عن محمد بن راشد؟', normalize_arabic('هل هناك قصائد عن محمد بن راشد؟'), 'شخصيات', ARRAY['راشد', 'محمد بن راشد', 'بو راشد'], 450, true),
('هل هناك قصائد عن الوطن؟', normalize_arabic('هل هناك قصائد عن الوطن؟'), 'مواضيع', ARRAY['وطن', 'الامارات', 'الديرة'], 400, true),
('هل هناك قصائد عن الحب؟', normalize_arabic('هل هناك قصائد عن الحب؟'), 'مواضيع', ARRAY['حب', 'عشق', 'غزل'], 380, true),
('هل هناك قصائد عن رمضان؟', normalize_arabic('هل هناك قصائد عن رمضان؟'), 'مناسبات', ARRAY['رمضان', 'شهر رمضان'], 350, true),
('هل هناك قصائد عن دبي؟', normalize_arabic('هل هناك قصائد عن دبي؟'), 'أماكن', ARRAY['دبي'], 320, true),
('هل هناك قصائد عن الأم؟', normalize_arabic('هل هناك قصائد عن الأم؟'), 'مواضيع', ARRAY['أم', 'والدة', 'الوالدة'], 300, true),
('هل هناك قصائد عن الصداقة؟', normalize_arabic('هل هناك قصائد عن الصداقة؟'), 'مواضيع', ARRAY['صديق', 'رفيق', 'صحبة'], 280, true),

-- Other question formats
('قصائد عن الفخر والعزة', normalize_arabic('قصائد عن الفخر والعزة'), 'مواضيع', ARRAY['فخر', 'عزة', 'كرامة'], 260, true),
('أبيات شعر عن الشجاعة', normalize_arabic('أبيات شعر عن الشجاعة'), 'مواضيع', ARRAY['شجاعة', 'بطولة'], 240, true),
('ما هي القصائد التي تذكر الصحراء؟', normalize_arabic('ما هي القصائد التي تذكر الصحراء؟'), 'أماكن', ARRAY['صحراء', 'بادية'], 220, true),
('ابحث عن قصائد الفراق', normalize_arabic('ابحث عن قصائد الفراق'), 'مواضيع', ARRAY['فراق', 'بعد', 'غياب'], 200, true)
ON CONFLICT DO NOTHING;


-- =====================================================
-- AUTOCOMPLETE FUNCTION
-- Returns suggestions that match what user is typing
-- =====================================================

DROP FUNCTION IF EXISTS autocomplete_questions(TEXT, INT) CASCADE;

CREATE OR REPLACE FUNCTION autocomplete_questions(
    prefix TEXT,
    limit_count INT DEFAULT 5
)
RETURNS TABLE(
    question TEXT,
    category TEXT,
    search_terms TEXT[],
    is_boosted BOOLEAN,
    popularity INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    q TEXT;
BEGIN
    q := normalize_arabic(trim(prefix));
    
    IF char_length(q) < 2 THEN
        -- Show top boosted questions when input is too short
        RETURN QUERY
        SELECT 
            qs.full_question,
            qs.category,
            qs.search_terms,
            qs.is_boosted,
            qs.popularity
        FROM question_suggestions qs
        WHERE qs.is_boosted = true
        ORDER BY qs.popularity DESC
        LIMIT limit_count;
    ELSE
        -- Return matching questions (boosted first)
        RETURN QUERY
        SELECT 
            qs.full_question,
            qs.category,
            qs.search_terms,
            qs.is_boosted,
            qs.popularity
        FROM question_suggestions qs
        WHERE qs.question_normalized ILIKE q || '%'
        ORDER BY 
            qs.is_boosted DESC,
            qs.popularity DESC,
            length(qs.full_question) ASC  -- Shorter questions first
        LIMIT limit_count;
    END IF;
END;
$$;


-- =====================================================
-- TRACK SUGGESTION CLICKS
-- =====================================================

CREATE OR REPLACE FUNCTION track_suggestion_click(question_text TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE question_suggestions
    SET popularity = popularity + 1
    WHERE full_question = question_text;
    
    -- If question doesn't exist, add it with low popularity
    IF NOT FOUND THEN
        INSERT INTO question_suggestions (full_question, question_normalized, search_terms, popularity)
        VALUES (
            question_text,
            normalize_arabic(question_text),
            ARRAY[question_text],  -- Temporary search term
            1
        )
        ON CONFLICT DO NOTHING;
    END IF;
END;
$$;


-- =====================================================
-- USAGE EXAMPLES
-- =====================================================

/*
-- Example 1: User types "هل"
SELECT * FROM autocomplete_questions('هل', 5);

Returns:
┌──────────────────────────────────────────┬──────────┬─────────────────────┐
│ question                                 │ category │ is_boosted          │
├──────────────────────────────────────────┼──────────┼─────────────────────┤
│ هل هناك قصائد عن محمد بن زايد؟          │ شخصيات   │ true (pop: 500)     │
│ هل هناك قصائد عن محمد بن راشد؟          │ شخصيات   │ true (pop: 450)     │
│ هل هناك قصائد عن الوطن؟                 │ مواضيع   │ true (pop: 400)     │
│ هل هناك قصائد عن الحب؟                  │ مواضيع   │ true (pop: 380)     │
│ هل هناك قصائد عن رمضان؟                 │ مناسبات  │ true (pop: 350)     │
└──────────────────────────────────────────┴──────────┴─────────────────────┘

-- Example 2: User types "هل هناك قصا"
SELECT * FROM autocomplete_questions('هل هناك قصا', 5);

Returns only questions matching "هل هناك قصا*"

-- Example 3: User types "قصائد"
SELECT * FROM autocomplete_questions('قصائد', 5);

Returns:
- "قصائد عن الفخر والعزة"
- etc.

-- Example 4: Track when user clicks suggestion
SELECT track_suggestion_click('هل هناك قصائد عن محمد بن زايد؟');
-- Increments popularity counter
*/


-- =====================================================
-- FRONTEND INTEGRATION NOTES
-- =====================================================

/*
JavaScript Example:

let debounceTimer;
searchInput.addEventListener('input', async (e) => {
  clearTimeout(debounceTimer);
  
  debounceTimer = setTimeout(async () => {
    const query = e.target.value;
    
    // Step 1: Get question suggestions
    const { data: suggestions } = await supabase.rpc('autocomplete_questions', {
      prefix: query,
      limit_count: 5
    });
    
    if (suggestions && suggestions.length > 0) {
      // Show suggestions dropdown
      suggestionsDiv.innerHTML = suggestions.map(s => `
        <div class="suggestion-item ${s.is_boosted ? 'boosted' : ''}" 
             data-question="${s.question}"
             data-search-terms="${s.search_terms.join(',')}">
          <span class="suggestion-icon">💡</span>
          <span class="suggestion-text">${s.question}</span>
          <span class="suggestion-category">${s.category}</span>
        </div>
      `).join('');
      
      // Click handler
      document.querySelectorAll('.suggestion-item').forEach(item => {
        item.addEventListener('click', async () => {
          const question = item.dataset.question;
          const searchTerms = item.dataset.searchTerms.split(',');
          
          // Track click
          await supabase.rpc('track_suggestion_click', {
            question_text: question
          });
          
          // Execute search with the question's search_terms
          searchInput.value = question;
          suggestionsDiv.innerHTML = '';
          
          // Use the predefined search_terms instead of the full question
          const { data: results } = await supabase.rpc('live_search', {
            search_query: searchTerms.join(' '),  // Or use question directly
            result_limit: 20
          });
          
          displayResults(results);
        });
      });
    } else {
      // No suggestions - show live search results instead
      const { data: results } = await supabase.rpc('live_search', {
        search_query: query,
        result_limit: 10
      });
      
      displaySearchResults(results);
    }
    
  }, 150);
});


CSS Example:

.suggestion-item {
  padding: 12px 16px;
  border-bottom: 1px solid #f0f0f0;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 12px;
  transition: background 0.2s;
}

.suggestion-item:hover {
  background: #f5f5f5;
}

.suggestion-item.boosted {
  background: #fffbf0;
  border-left: 3px solid #ffc107;
}

.suggestion-icon {
  font-size: 18px;
}

.suggestion-text {
  flex: 1;
  font-size: 15px;
  color: #333;
}

.suggestion-category {
  font-size: 12px;
  color: #666;
  background: #e3f2fd;
  padding: 4px 8px;
  border-radius: 4px;
}
*/