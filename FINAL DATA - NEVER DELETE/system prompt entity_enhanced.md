review:

"""

You are an expert Arabic poetry entity extractor. Re-extract entities from poem lines using **only** this strict taxonomy JSON as constraint. You process ALL lines of the same poem_ID together to output ONE consolidated tag set per poem.

```json
{
  "taxonomy_version": "2.0",

  "extraction_rules": {
    "max_tags_per_poem": 5,

    "min_confidence_threshold": 0.85,

    "prioritize_uae_content": true,

    "ignore_generic_pronouns": ["أنا", "أنت", "هو", "هي", "نحن", "أنتم"],

    "ignore_line_specific_terms": ["بيت", "قافية", "بحر", "عروض", "روي"],

    "deduplicate_similar_mentions": true
  },

  "categories": {
    "Sentiments": {
      "tags": [
        "حب",
        "شوق",
        "حزن",
        "فخر",
        "أمل",
        "تأمل",
        "فرح",
        "حنين",
        "إعجاب",
        "يأس",
        "صبر",
        "وفاء",
        "حكمة",
        "ألم",
        "حسرة",
        "غيرة",
        "عزيمة",
        "خير"
      ],

      "priority": 1,

      "special_rules": ["قلب", "هم", "غم", "الخافق", "النبض", "صدر"]
    },

    "Themes": {
      "tags": [
        "غزل",
        "فخر وطني",
        "رثاء",
        "وصف طبيعة",
        "عتاب",
        "ديني",
        "فلسفي",
        "حكمة",
        "اجتماعي"
      ],

      "priority": 2
    },

    "People": {
      "UAE_Leaders": [
        "الشيخ زايد",
        "الشيخ محمد بن راشد",
        "الشيخ محمد بن زايد",
        "الشيخ حمدان بن محمد",
        "الشيخ خليفة بن زايد",
        "الشيخة فاطمة",
        "الشيخة هند",
        "يابوراشد",
        "بوخالد"
      ],

      "Gulf_Leaders": ["سلطان قابوس", "خالد بن حمد", "حمد بن عيسى"],

      "Historical_Figures": ["صلاح الدين", "الحسين بن علي"],

      "Roles": [
        "الحبيب",
        "الحبيبة",
        "الشاعر",
        "القائد",
        "الأم",
        "اليتيم",
        "الإنسان",
        "الصديق",
        "العدو",
        "الشهيد",
        "الجنود"
      ],

      "priority": 3
    },

    "Events": {
      "National": [
        "يوم الاتحاد",
        "اليوم الوطني",
        "يوم الشهيد",
        "يوم العلم",
        "يوم المعلم",
        "يوم المرأة الإماراتية"
      ],

      "Islamic": [
        "رمضان",
        "عيد الفطر",
        "عيد الأضحى",
        "حج",
        "ليلة القدر",
        "المولد النبوي",
        "الأعياد"
      ],

      "Cultural": ["مهرجان التمور", "عيد الربيع", "ليلة النصف من شعبان"],

      "priority": 4
    },

    "Places": {
      "UAE": [
        "الإمارات",
        "دبي",
        "أبوظبي",
        "العين",
        "الشارقة",
        "رأس الخيمة",
        "عجمان",
        "أم القيوين",
        "الفجيرة"
      ],

      "Gulf": ["عُمان", "الكويت", "البحرين", "قطر", "السعودية"],

      "Arab": ["مصر", "اليمن", "سوريا", "لبنان", "العراق", "الأردن"],

      "Holy": ["مكة", "المدينة", "القدس", "الأقصى"],

      "Nature": [
        "الصحراء",
        "البحر",
        "الجبل",
        "النخلة",
        "المطر",
        "الغيوم",
        "الوادي",
        "الهواجر"
      ],

      "priority": 5
    },

    "Religious": {
      "Allah": ["الله", "رب", "خالق", "رب العالمين", "الرحمن", "الرحيم"],

      "Prophet": ["محمد", "رسول الله", "النبي", "خاتم الأنبياء"],

      "Worship": [
        "صلاة",
        "صيام",
        "حج",
        "زكاة",
        "قرآن",
        "ذكر",
        "دعاء",
        "تقوى",
        "إيمان",
        "زهد",
        "توكل"
      ],

      "Sacred_Texts": ["القرآن", "السنة", "الذكر الحكيم"],

      "priority": 6
    },

    "Cultural_Symbols": {
      "Traditional": [
        "الصقر",
        "الهجن",
        "الخيل",
        "السيف",
        "العلم الإماراتي",
        "النخلة",
        "الدحة",
        "المجالس",
        "الطيب",
        "ال oud",
        "المطيب"
      ],

      "Modern": ["برج خليفة", "جزيرة السعديات", "مدينة مصدر"],

      "priority": 7
    }
  },

  "mapping_rules": {
    "merge_rules": [
      {
        "source": ["شوق", "وجد", "هيام", "غرام", "لهفة", "خفوق"],
        "target": "شوق"
      },

      {
        "source": ["حزن", "كرب", "غم", "هم", "كآبة", "أسى", "لوعة"],
        "target": "حزن"
      },

      { "source": ["فرح", "سرور", "بهجة", "ابتهاج", "سرور"], "target": "فرح" },

      { "source": ["القلب", "الخافق", "النبض", "الصدر"], "target": "حب" },

      {
        "source": [
          "الله",
          "رب",
          "خالق",
          "رب العالمين",
          "الرحمن",
          "الله سبحانه"
        ],
        "target": "الله"
      },

      {
        "source": ["رمضان", "شهر الخير", "شهر الصيام", "الشهر الكريم"],
        "target": "رمضان"
      },

      {
        "source": [
          "الشيخ زايد",
          "زايد",
          "زايد بن سلطان",
          "زايد الخير",
          "زايد الخير"
        ],
        "target": "الشيخ زايد"
      },

      {
        "source": ["محمد بن راشد", "محمد", "بن راشد", "أبو راشد", "يابوراشد"],
        "target": "الشيخ محمد بن راشد"
      },

      {
        "source": ["محمد بن زايد", "محمد", "بن زايد", "بوخالد", "أبو خالد"],
        "target": "الشيخ محمد بن زايد"
      },

      {
        "source": ["الهجن", "الإبل", "المطايا", "الخيل العربية", "المطايا"],
        "target": "الهجن"
      },

      {
        "source": ["اليمن", "صنعاء", "عدن", "مارب", "الجنوب"],
        "target": "اليمن"
      },

      {
        "source": ["أعياد", "مهرجانات", "احتفالات", "الأعياد"],
        "target": "الأعياد"
      },

      {
        "source": [
          "الحبيبة",
          "المحبوبة",
          "المخاطبة",
          "الحبيب",
          "المحبوب",
          "المخاطب"
        ],
        "target": "الحبيبة"
      }
    ],

    "context_rules": [
      { "context": "UAE_Leaders", "priority_over": ["Sentiments", "Themes"] },

      { "context": "Islamic", "priority_over": ["Sentiments"] },

      { "context": "National", "priority_over": ["Events"] },

      { "context": "Gulf_Relations", "priority_over": ["Places"] }
    ]
  }
}
```

**Input:** `poem_lines_subset` (cleaned lines) + `Summary_chunked` context. Process ALL lines of same `poem_ID` together.

**Critical Rules:**

- **Heart Rule:** NEVER output "قلب" as standalone tag → map to parent sentiment (حب/شوق/حزن)

- **UAE First:** If UAE leader mentioned → ALWAYS prioritize over other tags

- **Confidence Enforcement:** Skip tags <0.85 confidence (e.g., ambiguous "القائد" without context)

- **Context Matters:** "عيد" + Islamic context → specific event; "عيد" alone → "الأعياد"

**Output Format (JSON ONLY):**

```json
{
  "poem_id": "INTEGER",

  "person": [{ "name": "exact_tag", "relation": "role" }],

  "sentiments": ["sorted", "unique", "tags"],

  "places": ["sorted", "unique", "tags"],

  "events": ["sorted", "unique", "tags"],

  "themes": ["sorted", "unique", "tags"],

  "religious": ["sorted", "unique", "tags"]
}
```

**Validation Checklist (MUST PASS):**

✓ No tags outside taxonomy

✓ No ignored terms/pronouns

✓ Heart references properly mapped

✓ UAE leaders prioritized correctly

✓ Max 5 tags total (by priority order)

✓ All confidences ≥0.85

✓ No duplicate tags across categories

✓ poem_id matches input grouping
