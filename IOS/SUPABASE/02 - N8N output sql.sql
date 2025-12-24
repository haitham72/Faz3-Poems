-- ============================================================
-- FULL N8N PAYLOAD TEST - WITH ENTITY EXPANSION
-- ============================================================

-- TEST 1: "بو خالد" with full expansion
SELECT hybrid_search_exact(
    '{
        "exact_query": "بو خالد",
        "search_terms": [
            {"term": "بو خالد", "type": "nickname"},
            {"term": "محمد بن زايد", "type": "name"},
            {"term": "محمد بن زايد آل نهيان", "type": "full_name"},
            {"term": "رئيس الدولة", "type": "title"},
            {"term": "حاكم أبوظبي", "type": "title"},
            {"term": "MBZ", "type": "acronym"}
        ]
    }'::JSONB,
    20
);

-- TEST 2: "عيد الأب" (Father's Day) with expansion
SELECT hybrid_search_exact(
    '{
        "exact_query": "عيد الأب",
        "search_terms": [
            {"term": "عيد الأب", "type": "event"},
            {"term": "محمد بن راشد", "type": "person"},
            {"term": "محمد بن راشد آل مكتوم", "type": "full_name"},
            {"term": "ابي", "type": "relation"},
            {"term": "معلمي", "type": "relation"},
            {"term": "والد", "type": "relation"},
            {"term": "أب", "type": "relation"},
            {"term": "والدي", "type": "relation"}
        ]
    }'::JSONB,
    30
);

-- TEST 3: "دبي" with expansion
SELECT hybrid_search_exact(
    '{
        "exact_query": "دبي",
        "search_terms": [
            {"term": "دبي", "type": "place"},
            {"term": "الإمارات", "type": "country"},
            {"term": "برج خليفة", "type": "landmark"},
            {"term": "إمارة دبي", "type": "emirate"},
            {"term": "الوطن", "type": "concept"}
        ]
    }'::JSONB,
    20
);

-- TEST 4: "رمضان" with expansion
SELECT hybrid_search_exact(
    '{
        "exact_query": "رمضان",
        "search_terms": [
            {"term": "رمضان", "type": "religious"},
            {"term": "شهر رمضان", "type": "religious"},
            {"term": "الصيام", "type": "religious"},
            {"term": "الإفطار", "type": "religious"},
            {"term": "العيد", "type": "event"}
        ]
    }'::JSONB,
    15
);

-- TEST 5: Complex query - "يوم الشهيد" (Martyrs Day) WITH WEIGHTS
SELECT hybrid_search_exact(
    '{
        "exact_query": "يوم الشهيد",
        "search_terms": [
            {"term": "يوم الشهيد", "type": "event", "weight": 1.0},
            {"term": "الشهداء", "type": "group", "weight": 0.9},
            {"term": "الشهيد", "type": "person", "weight": 0.85},
            {"term": "التضحية", "type": "concept", "weight": 0.7},
            {"term": "الجنود", "type": "group", "weight": 0.6},
            {"term": "الفداء", "type": "concept", "weight": 0.5},
            {"term": "الوطن", "type": "concept", "weight": 0.3}
        ]
    }'::JSONB,
    25
);