SELECT hybrid_search_exact(
    '{
        "exact_query": "بو خالد",
        "search_terms": [
            {
                "query": ["بو خالد"],
                "confidence": 1.0,
                "type": "person",
                "filter": "محمد بن زايد آل نهيان"
            },
            {
                "query": ["محمد بن زايد"],
                "confidence": 0.95,
                "type": "person",
                "filter": "محمد بن زايد آل نهيان"
            },
            {
                "query": ["رئيس الدولة"],
                "confidence": 0.7,
                "type": "person",
                "filter": "رئيس دولة الإمارات"
            }
        ]
    }'::JSONB,
    20,     -- match_limit
    1.5     -- min_score (to filter garbage)
);