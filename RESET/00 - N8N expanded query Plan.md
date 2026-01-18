## 1. User Input to N8N

{
"user_query": "find me poems about Bo khaled",
"user_language": "en",
"timestamp": "2025-12-26T10:00:00Z"
}

## 2. N8N Workflow System Prompt oneshot Entity relation lookup

{
"entity_lookup": {
"primary_match": {
"entity_id": "mbz_001",
"full_name": "محمد بن زايد آل نهيان",
"Expanded_query": ["نصير الدين", "محمد بن زايد", "قائدنا", "بو خالد", "رئيس الدولة"],
"relation_to": {
"الوالد المؤسس": "زايد بن سلطان",
"son": "خالد بن محمد بن زايد",
"role": "رئيس دولة الإمارات"
}
}
}
}

## 3. Query Expansion with Confidence Scoring

json{
"N8N_query": {
"Exact_query": "بو خالد",
"column": "شخص",
"tag": "بو خالد", //exact query or translation is its own tag
"confidence_score": 100
},
"expanded_queries": [
{
"query": "بن زايد","محمد بن زايد",
"column": "شخص",
"tag": "محمد بن زايد",
"confidence_score": 95 //expanded proposed query
},
{
"query": "رئيس الدولة", "قائدنا", "الرئيس"
"column": "شخص",
"tag": "رئيس الدولة",
"confidence_score": 85 //expanded relative query
},
{
"query": "زايد",
"column": "شخص",
"tag": "الوالد المؤسس",
"confidence_score": 60, // score is low as most likely user didn't mean this query, but its a proposed query
"reason": "related_entity"
},
{
"query": "نصير الدين",
"column": "دين", // column changes as it searches now in a different column
"tag": "نصير الدين",
"confidence_score": 60, // score is low as most likely user didn't mean this query, but its a proposed query
"reason": "related_entity"
},
{
"query": "خالد بن محمد بن زايد",
"column": "شخص",
"tag": "خالد بن محمد بن زايد",
"confidence_score": 40, // score is very low as most likely user didn't mean this query, but its a proposed query
"reason": "family_relation"
},
{
"query": "القيادة والزعماء", "المجد والعز",
"column": "مواضيع",
"tag": "القائد", //tag is proposed filter tag from N8N
"confidence_score": 50, // score is low as user didn't explicitly ask for these topics
"reason": "extracted_entities"
}
],
"indiviual_Limit": 10,
"total_limit": 50
}
}

## 4. SQL Function Call (Multiple Searches + Merging)

sql-- Call function for each expanded query
SELECT _ FROM hybrid_search_v1_core('بو خالد', 100);
SELECT _ FROM hybrid_search_v1_core('محمد بن زايد', 95);
SELECT _ FROM hybrid_search_v1_core('رئيس الدولة', 85);
SELECT _ FROM hybrid_search_v1_core('زايد', 60);
SELECT _ FROM hybrid_search_v1_core('نصير الدين', 60);
SELECT _ FROM hybrid_search_v1_core('خالد بن محمد بن زايد', 40);
SELECT _ FROM hybrid_search_v1_core('القيادة والزعماء', 50);
SELECT _ FROM hybrid_search_v1_core('المجد والعز', 50);
-- ... etc

## 5. Sample ROW from postgres table

[
{
"id": 642,
"poem_id": 42,
"Row_ID": 642,
"Title_raw": "أمجاد الجدود",
"Poem_line_raw": "يـنصاك ياشـبل الأسـود العـنيده يا ابن الكـريم ويا سلاله كريمه",
"summary": "نصيحة وتحفيز لشاب شجاع وكريم الأصل.",
"Title_cleaned": "امجاد الجدود",
"Poem_line_cleaned": "ينصاك ياشبل الاسود العنيده يا ابن الكريم ويا سلاله كريمه",
"قافية": "مه",
"روي": "ه",
"البحر": "الوافر",
"وصل": "لا يوجد",
"حركة": "كسرة",
"شخص": [
{
"name": "محمد بن زايد آل نهيان",
"relation": "رئيس دولة الإمارات",
"resolved_from": [
"ياشبل الاسود"
]
},
{
"name": "زايد بن سلطان آل نهيان",
"relation": "الوالد المؤسس",
"resolved_from": [
"ابن الكريم"
]
}
],
"sentiments": "فخر",
"أحداث": [],
"دين": [],
"مواضيع": [
"القيادة والزعماء",
"المجد والعز"
],
"أماكن": [],
"تصنيف": "معاصر",
"مواضيع_tsv": "'قياد':1 'مجد':3 'والزعماء':2 'والعز':4",
"created_at": "2025-12-25 07:19:22.514167+00"
}
]

## 6. Example of SQL return json Result

{
"Exact_query": "بو خالد",
"query_weight": 1.0,
"entity_boost": 10,
"poems": 43,
"lines": 120,
"words": 1240,
"tags": "بو خالد, محمد بن زايد, رئيس الدولة, زايد, نصير الدين, خالد بن محمد بن زايد, القائد",
"Exact_query_results": [
{
"poem_id": 44,
"row_id": 671,
"title_raw": "آمر يا بو خالد",
"poem_line_raw": "غصن الثنا لجلك تثـنـّا خذها يابو خالد عن يمين",
"score": 100.0,
"match_location": ["poem_line", "title", "شخص], //reason for 100 is because it matches both title and poem_line
"match_type": "exact_phrase", // reason for exact_phrase is because full text not partial
"tag": "بو خالد", //this was the actual query tag from N8N
"match": {
"title": [
{
"text": "بو خالد",
"score": 100, //reason for 100 is because it matches perfectly with no trigram/fuzzy triggered
"positions": "[2-3]"
}
],
"poem_line": {
"row_id": 671,
"matched_words": [
{
"text": "يابو خالد",
"score": 90, //reason for 90 is because the match was triggered via fuzzy match! notice the 'يابو' is a fuzzy match
"positions": "[5-6]"
}
]
}
}
}
],
"Expanded_query_results": [
{
"poem_id": 44,
"row_id": 671,
"title_raw": "ثقة زايد",
"poem_line_raw": "ولا يقوى على حمل التعـب ويحقــّق الآمال سـوى ( محمد إبن زايد إبن سلطان ) وامثاله",
"score": 100.0,
"match_location": ["poem_line", "title", "شخص"], //reason for 100 is because it matches both title and poem_line
"match_type": "exact_phrase", // reason for exact_phrase is because full text not partial
"tag": "محمد بن زايد", //this was the actual query tag from N8N
"match": {
"title": [
{
"text": "زايد",
"score": 80, //reason for 80 is because it partially match
"positions": 1 // second word in the tirle counting from 0
}
],
"poem_line": {
"row_id": 671,
"matched_words": [
{
"text": "محمد إبن زايد إبن سلطان",
"score": 95, //reason for 95 is because the match was extended to the full name triggered via fuzzy match! notice the 'إبن سلطان' is a fuzzy match
"positions": [9-13] // i tried my best to count the split spaces, but it's not perfect and i counted the 5 spaces splitting both poem lines as 1 space, and counted the (, ), as 1 space each, notice i made highlight as range [9-13] to cover the full name, instead of every word
}
]
}
}
},
{
"poem_id": 42,
"row_id": 642,
"title_raw": "أمجاد الجدود",
"poem_line_raw": "يـنصاك ياشـبل الأسـود العـنيده يا ابن الكـريم ويا سلاله كريمه",
"score": 60.0,
"match_location": ["poem_line", "شخص", "مواضيع"],
"match_type": "hybrid_match", // Combined entity_resolution and entity extraction
"tag": "محمد بن زايد, القائد", // Tags combined, notice how it's the same shared tag as the previous poem
"match": {
"title": [],
"poem_line": {
"row_id": 642,
"matched_words": [
{
"text": "ياشبل الاسود",
"score": 60,
"positions": "[1-2]"
},
{
"text": "ابن الكريم",
"score": 60,
"positions": "[5-6]"
},
{
"text": "القيادة والزعماء",
"score": 50,
"positions": "metadata"
},
{
"text": "المجد والعز",
"score": 50,
"positions": "metadata"
}
]
}
}
}
]
}

Animal Categories Found in Dataset (Proof):
From direct analysis of the 353 poems in the dataset:

طائر (Birds):
الطير/طيور (poems 71, 87, 155, 183, 243, 335)
الصقر (poems 87, 105, 183, 225, 332)
الحمامة/حمام (poems 55, 87, 142, 269, 324)
العقاب/نسر (poems 87, 183, 321)
اليمامة (poem 324)
الهدهد (poem 239)
حصان (Horses):
الخيل/حصان (poems 74, 174, 183, 219, 238)
الفرس/جواد (poem 238)
وحش (Wild Animals):
الأسد/سبع (poems 86, 105, 204, 247, 331)
الغزال/ظبي (poems 72, 154, 181, 208, 280)
الذئب (poems 134, 264)
الفهد/نمر (poem 331)
الثعلب (poem 105)
حشرات (Insects):
النحل/نحلة (poem 126, 332)
الفراشة (poem 62, 128)
العقرب (poem 105, 126)
الجرادة/صرصور (poem 126)
بحر (Sea Creatures):
السمك/أسماك (poems 87, 99, 232)
زاحف (Reptiles/Amphibians):
الثعبان/أفعى (poems 126, 129)
الضفدع (poem 126)
إبل (Camels):
الجمل/إبل (poems 68, 87, 134, 182, 220)

| column_name       |
| ----------------- |
| id                |
| poem_id           |
| Row_ID            |
| Title_raw         |
| Poem_line_raw     |
| summary           |
| Title_cleaned     |
| Poem_line_cleaned |
| qafiya            |
| rawy              |
| meter             |
| wasl              |
| haraka            |
| entities          |
| sentiments        |
| events            |
| religion          |
| subjects          |
| places            |
| category          |
| subjects_tsv      |
| created_at        |
| title_tsv         |
| poem_line_tsv     |

| Title_cleaned |
| Poem_line_cleaned |
| entities |
| sentiments |
| events |
| religion |
| subjects |
| places |
| category |
