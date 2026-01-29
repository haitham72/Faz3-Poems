-- =====================================================
-- FULL SEARCH - PRODUCTION READY
-- All processing server-side for mobile iOS app
-- Returns highlight positions ready to use
-- =====================================================

DROP FUNCTION IF EXISTS full_search(TEXT, JSONB, INT) CASCADE;

CREATE OR REPLACE FUNCTION full_search(
    search_query TEXT,
    enabled_columns JSONB DEFAULT '{"title": true, "line": true, "entities": true, "places": true, "events": true, "religion": true, "subjects": true, "animals": true, "sentiments": true}'::jsonb,
    result_limit INT DEFAULT 20
)
RETURNS TABLE(
    poem_id INT,
    row_id INT,
    title_cleaned TEXT,
    poem_line_cleaned TEXT,
    matched_columns TEXT[],
    entities JSONB,
    animals JSONB,
    places JSONB,
    events TEXT[],
    religion TEXT[],
    subjects TEXT[],
    sentiment TEXT,
    priority INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    q TEXT;
    search_title BOOLEAN;
    search_line BOOLEAN;
    search_entities BOOLEAN;
    search_places BOOLEAN;
    search_events BOOLEAN;
    search_religion BOOLEAN;
    search_subjects BOOLEAN;
    search_animals BOOLEAN;
    search_sentiments BOOLEAN;
BEGIN
    q := trim(normalize_arabic(search_query));
    
    IF char_length(q) < 2 THEN
        RETURN;
    END IF;
    
    -- Extract enabled columns
    search_title := COALESCE((enabled_columns->>'title')::boolean, true);
    search_line := COALESCE((enabled_columns->>'line')::boolean, true);
    search_entities := COALESCE((enabled_columns->>'entities')::boolean, false);
    search_places := COALESCE((enabled_columns->>'places')::boolean, false);
    search_events := COALESCE((enabled_columns->>'events')::boolean, false);
    search_religion := COALESCE((enabled_columns->>'religion')::boolean, false);
    search_subjects := COALESCE((enabled_columns->>'subjects')::boolean, false);
    search_animals := COALESCE((enabled_columns->>'animals')::boolean, false);
    search_sentiments := COALESCE((enabled_columns->>'sentiments')::boolean, false);
    
    RETURN QUERY
    WITH matches AS (
        SELECT 
            d.poem_id,
            d."Row_ID",
            d."Title_cleaned",
            d."Poem_line_cleaned",
            
            -- Build matched_columns array
            ARRAY(
                SELECT col FROM (
                    VALUES 
                        (CASE WHEN search_title AND d."Title_cleaned" ILIKE '%' || q || '%' THEN 'title' ELSE NULL END),
                        (CASE WHEN search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%' THEN 'line' ELSE NULL END),
                        (CASE WHEN search_entities AND d.entities IS NOT NULL AND jsonb_typeof(d.entities) = 'array' AND d.entities::text ILIKE '%' || q || '%' THEN 'entities' ELSE NULL END),
                        (CASE WHEN search_places AND d.places IS NOT NULL AND jsonb_typeof(d.places) = 'array' AND d.places::text ILIKE '%' || q || '%' THEN 'places' ELSE NULL END),
                        (CASE WHEN search_events AND d.events IS NOT NULL AND jsonb_typeof(d.events) = 'array' AND d.events::text ILIKE '%' || q || '%' THEN 'events' ELSE NULL END),
                        (CASE WHEN search_religion AND d.religion IS NOT NULL AND jsonb_typeof(d.religion) = 'array' AND d.religion::text ILIKE '%' || q || '%' THEN 'religion' ELSE NULL END),
                        (CASE WHEN search_subjects AND d.subjects IS NOT NULL AND jsonb_typeof(d.subjects) = 'array' AND d.subjects::text ILIKE '%' || q || '%' THEN 'subjects' ELSE NULL END),
                        (CASE WHEN search_animals AND d.animals IS NOT NULL AND jsonb_typeof(d.animals) = 'array' AND d.animals::text ILIKE '%' || q || '%' THEN 'animals' ELSE NULL END),
                        (CASE WHEN search_sentiments AND d.sentiments ILIKE '%' || q || '%' THEN 'sentiments' ELSE NULL END)
                ) AS t(col)
                WHERE col IS NOT NULL
            ) as matched_cols,
            
            -- Entities (highlight from resolved_from)
            CASE WHEN search_entities THEN (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'name', e->>'name',
                        'relation', e->>'relation',
                        'highlight_words', (
                            SELECT jsonb_agg(alias)
                            FROM jsonb_array_elements_text(e->'resolved_from') alias
                        )
                    )
                )
                FROM jsonb_array_elements(d.entities) e
                WHERE 
                    d.entities IS NOT NULL 
                    AND jsonb_typeof(d.entities) = 'array'
                    AND (
                        e->>'name' ILIKE '%' || q || '%' OR
                        (
                            jsonb_typeof(e->'resolved_from') = 'array'
                            AND EXISTS (
                                SELECT 1 FROM jsonb_array_elements_text(e->'resolved_from') alias
                                WHERE normalize_arabic(alias) ILIKE '%' || q || '%'
                            )
                        )
                    )
            ) ELSE NULL END as entities_data,
            
            -- Animals (highlight from resolved_from)
            CASE WHEN search_animals THEN (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'name', a->>'name',
                        'category', a->>'category',
                        'highlight_words', (
                            SELECT jsonb_agg(alias)
                            FROM jsonb_array_elements_text(a->'resolved_from') alias
                        )
                    )
                )
                FROM jsonb_array_elements(d.animals) a
                WHERE 
                    d.animals IS NOT NULL 
                    AND jsonb_typeof(d.animals) = 'array'
                    AND (
                        a->>'name' ILIKE '%' || q || '%' OR
                        (
                            jsonb_typeof(a->'resolved_from') = 'array'
                            AND EXISTS (
                                SELECT 1 FROM jsonb_array_elements_text(a->'resolved_from') alias
                                WHERE normalize_arabic(alias) ILIKE '%' || q || '%'
                            )
                        )
                    )
            ) ELSE NULL END as animals_data,
            
            -- Places (highlight from name)
            CASE WHEN search_places THEN (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'name', p->>'name',
                        'type', p->>'type',
                        'highlight_words', jsonb_build_array(p->>'name')
                    )
                )
                FROM jsonb_array_elements(d.places) p
                WHERE 
                    d.places IS NOT NULL 
                    AND jsonb_typeof(d.places) = 'array'
                    AND (p->>'name' ILIKE '%' || q || '%' OR p->>'type' ILIKE '%' || q || '%')
            ) ELSE NULL END as places_data,
            
            -- Events (simple array)
            CASE WHEN search_events THEN (
                SELECT array_agg(ev::text)
                FROM jsonb_array_elements_text(d.events) ev
                WHERE 
                    d.events IS NOT NULL 
                    AND jsonb_typeof(d.events) = 'array'
                    AND normalize_arabic(ev) ILIKE '%' || q || '%'
            ) ELSE NULL END as events_data,
            
            -- Religion (simple array)
            CASE WHEN search_religion THEN (
                SELECT array_agg(rel::text)
                FROM jsonb_array_elements_text(d.religion) rel
                WHERE 
                    d.religion IS NOT NULL 
                    AND jsonb_typeof(d.religion) = 'array'
                    AND normalize_arabic(rel) ILIKE '%' || q || '%'
            ) ELSE NULL END as religion_data,
            
            -- Subjects (simple array)
            CASE WHEN search_subjects THEN (
                SELECT array_agg(subj::text)
                FROM jsonb_array_elements_text(d.subjects) subj
                WHERE 
                    d.subjects IS NOT NULL 
                    AND jsonb_typeof(d.subjects) = 'array'
                    AND normalize_arabic(subj) ILIKE '%' || q || '%'
            ) ELSE NULL END as subjects_data,
            
            -- Sentiment (simple text)
            CASE 
                WHEN search_sentiments AND d.sentiments ILIKE '%' || q || '%' THEN d.sentiments
                ELSE NULL
            END as sentiment_data,
            
            -- Calculate priority
            CASE 
                WHEN d."Title_cleaned" ILIKE '%' || q || '%' AND d."Poem_line_cleaned" ILIKE '%' || q || '%' THEN 1
                WHEN d."Title_cleaned" ILIKE '%' || q || '%' THEN 2
                WHEN d."Poem_line_cleaned" ILIKE '%' || q || '%' THEN 3
                ELSE 4
            END as calc_priority
            
        FROM "Diwan_Hamdan" d
        WHERE 
            (search_title AND d."Title_cleaned" ILIKE '%' || q || '%') OR
            (search_line AND d."Poem_line_cleaned" ILIKE '%' || q || '%') OR
            (search_entities AND d.entities IS NOT NULL AND jsonb_typeof(d.entities) = 'array' AND d.entities::text ILIKE '%' || q || '%') OR
            (search_places AND d.places IS NOT NULL AND jsonb_typeof(d.places) = 'array' AND d.places::text ILIKE '%' || q || '%') OR
            (search_events AND d.events IS NOT NULL AND jsonb_typeof(d.events) = 'array' AND d.events::text ILIKE '%' || q || '%') OR
            (search_religion AND d.religion IS NOT NULL AND jsonb_typeof(d.religion) = 'array' AND d.religion::text ILIKE '%' || q || '%') OR
            (search_subjects AND d.subjects IS NOT NULL AND jsonb_typeof(d.subjects) = 'array' AND d.subjects::text ILIKE '%' || q || '%') OR
            (search_animals AND d.animals IS NOT NULL AND jsonb_typeof(d.animals) = 'array' AND d.animals::text ILIKE '%' || q || '%') OR
            (search_sentiments AND d.sentiments ILIKE '%' || q || '%')
    )
    SELECT 
        m.poem_id,
        m."Row_ID",
        m."Title_cleaned",
        m."Poem_line_cleaned",
        m.matched_cols,
        m.entities_data,
        m.animals_data,
        m.places_data,
        m.events_data,
        m.religion_data,
        m.subjects_data,
        m.sentiment_data,
        m.calc_priority
    FROM matches m
    ORDER BY m.calc_priority, m.poem_id DESC
    LIMIT result_limit;
END;
$$;

-- =====================================================
-- EXAMPLE OUTPUT:
-- =====================================================
/*
{
  "poem_id": 123,
  "row_id": 456,
  "title_cleaned": "ثلاث مرات",
  "poem_line_cleaned": "وقلوب عشاقك اللي كثر عشاقي عيونهم نحل",
  "matched_columns": ["line", "entities", "animals"],
  
  "entities": [
    {
      "name": "الحبيب",
      "relation": "المحبوب",
      "highlight_words": ["عشاقك", "شفاتك"]  // ← Mobile highlights these
    },
    {
      "name": "الشاعر",
      "relation": "الذات",
      "highlight_words": ["عشاقي"]  // ← Mobile highlights this
    }
  ],
  
  "animals": [
    {
      "name": "النحلة",
      "category": "حشرات",
      "highlight_words": ["نحل"]  // ← Mobile highlights this
    }
  ],
  
  "places": [
    {
      "name": "ارض الوفا",
      "type": "أراضي_إماراتية",
      "highlight_words": ["ارض الوفا"]  // ← Mobile highlights this
    }
  ],
  
  "events": ["اليوم الوطني"],
  "religion": null,
  "subjects": ["الحب والغزل"],
  "sentiment": null,
  "priority": 3
}
*/

-- =====================================================
-- MOBILE iOS USAGE:
-- =====================================================
/*
Swift code:

struct SearchResult: Codable {
    let poem_id: Int
    let row_id: Int
    let title_cleaned: String
    let poem_line_cleaned: String
    let matched_columns: [String]
    let entities: [Entity]?
    let animals: [Animal]?
    let places: [Place]?
    let priority: Int
}

struct Entity: Codable {
    let name: String
    let relation: String
    let highlight_words: [String]  // Highlight these in the poem
}

struct Animal: Codable {
    let name: String
    let category: String
    let highlight_words: [String]  // Highlight these in the poem
}

struct Place: Codable {
    let name: String
    let type: String
    let highlight_words: [String]  // Highlight these in the poem
}

// Highlight function:
func highlightText(_ text: String, entities: [Entity]?, animals: [Animal]?, places: [Place]?) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: text)
    
    // Highlight entity words
    entities?.forEach { entity in
        entity.highlight_words.forEach { word in
            highlightWord(word, in: attributed, color: .yellow, tooltip: entity.name)
        }
    }
    
    // Highlight animal words
    animals?.forEach { animal in
        animal.highlight_words.forEach { word in
            highlightWord(word, in: attributed, color: .orange, tooltip: animal.name)
        }
    }
    
    // Highlight place words
    places?.forEach { place in
        place.highlight_words.forEach { word in
            highlightWord(word, in: attributed, color: .green, tooltip: place.name)
        }
    }
    
    return attributed
}
*/