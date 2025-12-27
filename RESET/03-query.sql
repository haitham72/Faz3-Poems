SELECT 
    (result.data->>'poem_id')::INT as poem_id,
    (result.data->>'row_id')::INT as row_id,
    result.data->>'title_raw' as title_raw,
    result.data->>'poem_line_raw' as poem_line_raw,
    (result.data->>'score')::NUMERIC as score,
    result.data->'match_location' as match_location,
    result.data->>'tag' as tag,
    result.data->'match' as match_details
FROM hybrid_search_v2_entity_aware(
    '{
        "N8N_query": {
            "Exact_query": "رمضان",
            "tag": "user_query",
            "confidence_score": 100,
            "expanded_queries": [
                {
                    "queries": ["محمد بن زايد", "بو خالد", "رئيس الدولة", "قائدنا"],
                    "tag": "محمد بن زايد آل نهيان",
                    "confidence_score": 95
                },
                {
                    "queries": ["رئيس", "قائد", "مدير", "زعيم"],
                    "tag": "القيادة",
                    "confidence_score": 85
                },
                {
                    "queries": ["زايد", "الوالد المؤسس"],
                    "tag": "زايد بن سلطان آل نهيان",
                    "confidence_score": 70
                }
            ],
            "individual_Limit": 5,
            "total_limit": 20
        }
    }'::jsonb,
    20,
    50
), 
LATERAL jsonb_array_elements(results) AS result(data)
ORDER BY (result.data->>'score')::NUMERIC DESC
LIMIT 20;

## N8N Query Format

{
  "n8n_payload": {
    "N8N_query": {
      "Exact_query": "بو خالد",
      "tag": "بو خالد",
      "confidence_score": 100,
      "expanded_queries": [
        {
          "query": "محمد بن زايد,الشامخ,رئيس الدولة",
          "tag": "محمد بن زايد آل نهيان",
          "confidence_score": 90
        }
      ],
      "individual_Limit": 10,
      "total_limit": 15
    }
  }
}


# exact query

SELECT 
    (result.data->>'poem_id')::INT as poem_id,
    (result.data->>'row_id')::INT as row_id,
    result.data->>'title_raw' as title_raw,
    result.data->>'poem_line_raw' as poem_line_raw,
    (result.data->>'score')::NUMERIC as score,
    result.data->'match_location' as match_location,
    result.data->>'tag' as tag,
    result.data->'match' as match_details
FROM hybrid_search_v2_entity_aware(
    '{
        "N8N_query": {
            "Exact_query": "بو خالد",
            "tag": "بو خالد",
            "confidence_score": 100,
            "expanded_queries": [],
            "individual_Limit": 10,
            "total_limit": 20
        }
    }'::jsonb,
    20,
    50
), 
LATERAL jsonb_array_elements(results) AS result(data)
ORDER BY (result.data->>'score')::NUMERIC DESC
LIMIT 20;


# expanded query

SELECT 
    (result.data->>'poem_id')::INT as poem_id,
    (result.data->>'row_id')::INT as row_id,
    result.data->>'title_raw' as title_raw,
    result.data->>'poem_line_raw' as poem_line_raw,
    (result.data->>'score')::NUMERIC as score,
    result.data->'match_location' as match_location,
    result.data->>'tag' as tag,
    result.data->'match' as match_details
FROM hybrid_search_v2_entity_aware(
    '{
        "N8N_query": {
            "Exact_query": "بو خالد",
            "tag": "بو خالد",
            "confidence_score": 100,
            "expanded_queries": [
                {
                    "query": "محمد بن زايد,الشامخ,رئيس الدولة",
                    "tag": "محمد بن زايد آل نهيان",
                    "confidence_score": 90
                }
            ],
            "individual_Limit": 10,
            "total_limit": 15
        }
    }'::jsonb,
    20,
    50
), 
LATERAL jsonb_array_elements(results) AS result(data)
ORDER BY (result.data->>'score')::NUMERIC DESC
LIMIT 20;