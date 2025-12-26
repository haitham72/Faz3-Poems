SELECT * FROM hybrid_search_v2_entity_aware(
  '{
    "N8N_query": {
      "Exact_query": "بو خالد",
      "column": "شخص",
      "tag": "بو خالد",
      "confidence_score": 100,
      "expanded_queries": [
        {
          "query": "محمد بن زايد",
          "column": "شخص",
          "tag": "محمد بن زايد",
          "confidence_score": 95,
          "reason": "related_entity"
        }
      ],
      "indiviual_Limit": 10,
      "total_limit": 50
    }
  }'::jsonb,
  50,
  0.3
);