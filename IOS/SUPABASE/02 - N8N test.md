# Edge Function Test Payloads

## Test 1: Simple Query - "بو خالد"
```bash
curl -X POST \
  https://ezcbshyresjinfyscals.supabase.co/functions/v1/hybrid-search \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "exact_query": "بو خالد",
    "search_terms": [
      {"term": "بو خالد", "type": "nickname", "weight": 1.0},
      {"term": "محمد بن زايد", "type": "full_name", "weight": 0.95},
      {"term": "أبو خالد", "type": "alternate_spelling", "weight": 0.9},
      {"term": "MBZ", "type": "acronym", "weight": 0.8}
    ],
    "match_count": 15
  }'
```

## Test 2: Event Query - "يوم الشهيد"
```bash
curl -X POST \
  https://ezcbshyresjinfyscals.supabase.co/functions/v1/hybrid-search \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "exact_query": "يوم الشهيد",
    "search_terms": [
      {"term": "يوم الشهيد", "type": "event", "weight": 1.0},
      {"term": "الشهداء", "type": "group", "weight": 0.9},
      {"term": "الشهيد", "type": "person", "weight": 0.85},
      {"term": "التضحية", "type": "concept", "weight": 0.7},
      {"term": "الفداء", "type": "concept", "weight": 0.65},
      {"term": "الجنود", "type": "group", "weight": 0.6},
      {"term": "الوطن", "type": "concept", "weight": 0.3}
    ],
    "match_count": 25
  }'
```

## Test 3: Place Query - "دبي"
```bash
curl -X POST \
  https://ezcbshyresjinfyscals.supabase.co/functions/v1/hybrid-search \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "exact_query": "دبي",
    "search_terms": [
      {"term": "دبي", "type": "place", "weight": 1.0},
      {"term": "الإمارات", "type": "country", "weight": 0.6},
      {"term": "برج خليفة", "type": "landmark", "weight": 0.5},
      {"term": "Dubai", "type": "latin", "weight": 0.9}
    ],
    "match_count": 10
  }'
```

## Test 4: Religious Event - "رمضان"
```bash
curl -X POST \
  https://ezcbshyresjinfyscals.supabase.co/functions/v1/hybrid-search \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "exact_query": "رمضان",
    "search_terms": [
      {"term": "رمضان", "type": "religious_event", "weight": 1.0},
      {"term": "العيد", "type": "celebration", "weight": 0.8},
      {"term": "الصيام", "type": "practice", "weight": 0.7},
      {"term": "الإفطار", "type": "practice", "weight": 0.6},
      {"term": "البركة", "type": "concept", "weight": 0.5}
    ],
    "match_count": 15
  }'
```

## Test 5: Father's Day - "عيد الأب"
```bash
curl -X POST \
  https://ezcbshyresjinfyscals.supabase.co/functions/v1/hybrid-search \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "exact_query": "عيد الأب",
    "search_terms": [
      {"term": "عيد الأب", "type": "event", "weight": 1.0},
      {"term": "الأب", "type": "relation", "weight": 0.9},
      {"term": "أبي", "type": "relation", "weight": 0.85},
      {"term": "محمد بن راشد", "type": "person", "weight": 0.8},
      {"term": "الوالد", "type": "relation", "weight": 0.75},
      {"term": "معلمي", "type": "role", "weight": 0.7},
      {"term": "ملهمي", "type": "role", "weight": 0.65},
      {"term": "الحب", "type": "emotion", "weight": 0.4}
    ],
    "match_count": 20
  }'
```

## Expected Response Format
```json
{
  "success": true,
  "query": "بو خالد",
  "results": [
    {
      "rank": 1,
      "query": "بو خالد",
      "matched_term": "بو خالد",
      "match_weight": 1.0,
      "poem_id": 44,
      "row_id": 666,
      "title_raw": "آمر يا بو خالد",
      "poem_line_raw": "...",
      "summary": "...",
      "score": 1.5,
      "match_type": "exact_phrase",
      "match_location": "title",
      "highlight_word": "بو خالد",
      "highlight_positions": [2, 3],
      "metadata": {...}
    }
  ],
  "metadata": {
    "total_results": 15,
    "match_limit": 15,
    "expansion_terms": 4,
    "timestamp": "2025-12-24T..."
  }
}
```

## Error Response Examples

### Missing required fields
```json
{
  "error": "Invalid payload",
  "details": "Expected: { exact_query: string, search_terms: SearchTerm[], match_count?: number }"
}
```

### Invalid search_terms
```json
{
  "error": "Invalid search_terms",
  "details": "Each term must have: { term: string, type: string, weight: number }",
  "invalid_terms": [
    {"term": "test", "type": "concept"}  // missing weight
  ]
}
```

### Database error
```json
{
  "error": "Database query failed",
  "details": "function hybrid_search_exact does not exist",
  "hint": null
}
```