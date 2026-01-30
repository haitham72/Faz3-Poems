{
  "n8n_payload": {
    "N8N_query": {
      "Exact_query": "بو راشد",
      "tag": "بو راشد",
      "confidence_score": 100,
      "expanded_queries": [
        {
          "query": "محمد بن راشد,أبي,معلم",
          "tag": "محمد بن راشد",
          "confidence_score": 90
        }
      ],
      "individual_Limit": 20,
      "total_limit": 55
    }
  }
}


{
  "n8n_payload": {
    "N8N_query": {
      "Exact_query": "بو خالد",
      "tag": "بو خالد",
      "confidence_score": 100,
      "expanded_queries": [
        {
          "query": "محمد بن زايد",
          "tag": "محمد بن زايد آل نهيان",
          "confidence_score": 90
        },
        {
          "query": "الرئيس ,القائد ,الشامخ ,رئيس الدولة",
          "tag": "رئيس دولة الامارات",
          "confidence_score": 90
        }
      ],
      "individual_Limit": 110,
      "total_limit": 150
    }
  }
}

{
  "n8n_payload": {
    "N8N_query": {
      "Exact_query": "هل هناك قصائد عن اليوم الوطني العماني مع بو خالد؟",
      "columns": ["entities", "places", "events"],
      "expanded_queries": [
        {
          "query": "محمد بن زايد، قابوس", //this checks the columns  'entities' and finds alot of results matching specificcaly in ["name"]--  and [{"name":"قابوس بن سعيد آل سعيد","relation":"former Sultan of Oman","resolved_from":["السلطان (قابوس)"]}],[{"name": "محمد بن زايد آل نهيان", "relation": "رئيس دولة الإمارات", "resolved_from": ["(ابو خالد )"]}]
          "column": "entities",
          "trigger": "بو خالد، عمان", // this is for backend log only and doesnt affect query
          "confidence_score": 90 // reason is it is not a direct match it was entity related
        },
        {
          "query": "عمان", //[{"name": "عمان", "type": "مدن_وأماكن_عربية"}] this was found in 'places' coloumns it could be extracted as symantic not as direct match aswell for example "كلنا نحبها" was previously annotated as "عمان"
          "column": "places",
          "trigger": "اليوم الوطني العماني",
          "confidence_score": 100 // reason is it is a direct match crystal clear as the ai didnot have to search or relate,   
        }
      ],
      "individual_Limit": 110,
      "total_limit": 150
    }
  }
}