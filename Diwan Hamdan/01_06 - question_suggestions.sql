-- =====================================================
-- QUESTION SUGGESTIONS TABLE
-- 50 questions about UAE, Sheikhs, and Hamdan's poetry themes
-- No normalized column (uses expression index)
-- =====================================================

DROP TABLE IF EXISTS question_suggestions CASCADE;

CREATE TABLE question_suggestions (
    id SERIAL PRIMARY KEY,
    full_question TEXT NOT NULL,
    category TEXT,
    search_terms TEXT[] NOT NULL,
    popularity INT DEFAULT 0,
    is_boosted BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Expression-based index (no extra column needed)
CREATE INDEX idx_question_search ON question_suggestions 
USING btree (normalize_arabic(full_question) text_pattern_ops);

CREATE INDEX idx_question_popularity ON question_suggestions (popularity DESC);
CREATE INDEX idx_question_boosted ON question_suggestions (is_boosted, popularity DESC);


-- =====================================================
-- 50 CURATED QUESTIONS
-- =====================================================

INSERT INTO question_suggestions (full_question, category, search_terms, popularity, is_boosted) VALUES

-- UAE Sheikhs (Top Priority - 15 questions)
('هل هناك قصائد عن محمد بن زايد؟', 'شخصيات', ARRAY['زايد', 'محمد بن زايد', 'بن زايد'], 500, true),
('هل هناك قصائد عن محمد بن راشد؟', 'شخصيات', ARRAY['راشد', 'محمد بن راشد', 'بو راشد'], 490, true),
('هل هناك قصائد عن الشيخ زايد؟', 'شخصيات', ARRAY['زايد', 'الشيخ زايد'], 480, true),
('هل هناك قصائد عن خليفة بن زايد؟', 'شخصيات', ARRAY['خليفة', 'خليفة بن زايد'], 470, true),
('هل هناك قصائد عن حمدان بن محمد؟', 'شخصيات', ARRAY['حمدان', 'فزاع'], 460, true),
('هل هناك قصائد عن راشد بن سعيد؟', 'شخصيات', ARRAY['راشد بن سعيد'], 450, true),
('هل هناك قصائد عن سلطان بن زايد؟', 'شخصيات', ARRAY['سلطان', 'سلطان بن زايد'], 440, true),
('قصائد عن آل نهيان', 'شخصيات', ARRAY['نهيان', 'ال نهيان'], 430, true),
('قصائد عن آل مكتوم', 'شخصيات', ARRAY['مكتوم', 'ال مكتوم'], 420, true),
('هل هناك قصائد عن منصور بن زايد؟', 'شخصيات', ARRAY['منصور', 'منصور بن زايد'], 410, true),
('هل هناك قصائد عن عبدالله بن زايد؟', 'شخصيات', ARRAY['عبدالله', 'عبدالله بن زايد'], 400, true),
('هل هناك قصائد عن أحمد بن محمد؟', 'شخصيات', ARRAY['احمد', 'احمد بن محمد'], 390, true),
('هل هناك قصائد عن مكتوم بن محمد؟', 'شخصيات', ARRAY['مكتوم', 'مكتوم بن محمد'], 380, true),
('هل هناك قصائد عن ذياب بن محمد؟', 'شخصيات', ARRAY['ذياب', 'ذياب بن محمد'], 370, true),
('قصائد عن حكام الإمارات', 'شخصيات', ARRAY['حكام', 'امارات', 'شيوخ'], 360, true),

-- UAE & Patriotism (10 questions)
('هل هناك قصائد عن الوطن؟', 'مواضيع', ARRAY['وطن', 'الامارات', 'الديرة'], 450, true),
('هل هناك قصائد عن الإمارات؟', 'مواضيع', ARRAY['امارات', 'الامارات'], 440, true),
('هل هناك قصائد عن الديرة؟', 'مواضيع', ARRAY['ديرة', 'الديرة'], 430, true),
('هل هناك قصائد عن اليوم الوطني؟', 'مناسبات', ARRAY['اليوم الوطني', 'وطني', 'اتحاد'], 420, true),
('قصائد عن الفخر والعزة', 'مواضيع', ARRAY['فخر', 'عزة', 'كرامة'], 410, true),
('قصائد عن حب الوطن', 'مواضيع', ARRAY['وطن', 'حب'], 400, true),
('هل هناك قصائد عن الاتحاد؟', 'مناسبات', ARRAY['اتحاد', 'الاتحاد'], 390, true),
('هل هناك قصائد عن علم الإمارات؟', 'مواضيع', ARRAY['علم', 'راية'], 380, true),
('قصائد عن المجد والشموخ', 'مواضيع', ARRAY['مجد', 'شموخ'], 370, true),
('هل هناك قصائد عن الانتماء؟', 'مواضيع', ARRAY['انتماء', 'ولاء'], 360, true),

-- UAE Cities (7 questions)
('هل هناك قصائد عن دبي؟', 'أماكن', ARRAY['دبي'], 400, true),
('هل هناك قصائد عن أبوظبي؟', 'أماكن', ARRAY['ابوظبي', 'ابو ظبي'], 390, true),
('هل هناك قصائد عن الشارقة؟', 'أماكن', ARRAY['شارقة', 'الشارقة'], 380, true),
('هل هناك قصائد عن رأس الخيمة؟', 'أماكن', ARRAY['راس الخيمة'], 370, true),
('هل هناك قصائد عن عجمان؟', 'أماكن', ARRAY['عجمان'], 360, true),
('هل هناك قصائد عن الفجيرة؟', 'أماكن', ARRAY['فجيرة', 'الفجيرة'], 350, true),
('هل هناك قصائد عن أم القيوين؟', 'أماكن', ARRAY['ام القيوين'], 340, true),

-- Emotional Themes (10 questions)
('هل هناك قصائد عن الحب؟', 'مواضيع', ARRAY['حب', 'عشق', 'غزل'], 430, true),
('هل هناك قصائد عن الشوق؟', 'مواضيع', ARRAY['شوق', 'حنين'], 420, true),
('هل هناك قصائد عن الفراق؟', 'مواضيع', ARRAY['فراق', 'بعد', 'غياب'], 410, true),
('هل هناك قصائد عن الأم؟', 'مواضيع', ARRAY['أم', 'والدة', 'الوالدة'], 400, true),
('هل هناك قصائد عن الصداقة؟', 'مواضيع', ARRAY['صديق', 'رفيق', 'صحبة'], 390, true),
('هل هناك قصائد عن الحزن؟', 'مواضيع', ARRAY['حزن', 'ألم'], 380, true),
('هل هناك قصائد عن الأمل؟', 'مواضيع', ARRAY['أمل', 'رجاء'], 370, true),
('قصائد عن الحب والغزل', 'مواضيع', ARRAY['حب', 'غزل'], 360, true),
('هل هناك قصائد عن الوفاء؟', 'مواضيع', ARRAY['وفاء', 'اخلاص'], 350, true),
('هل هناك قصائد عن الصبر؟', 'مواضيع', ARRAY['صبر'], 340, true),

-- Nature & Desert (5 questions)
('هل هناك قصائد عن الصحراء؟', 'أماكن', ARRAY['صحراء', 'بادية', 'رمل'], 370, true),
('هل هناك قصائد عن البحر؟', 'مواضيع', ARRAY['بحر', 'موج'], 360, true),
('هل هناك قصائد عن الليل؟', 'مواضيع', ARRAY['ليل', 'قمر', 'نجوم'], 350, true),
('هل هناك قصائد عن المطر؟', 'مواضيع', ARRAY['مطر', 'غيث'], 340, true),
('هل هناك قصائد عن الربيع؟', 'مواضيع', ARRAY['ربيع'], 330, true),

-- Religious/Cultural (3 questions)
('هل هناك قصائد عن رمضان؟', 'مناسبات', ARRAY['رمضان', 'شهر رمضان'], 390, true),
('هل هناك قصائد عن العيد؟', 'مناسبات', ARRAY['عيد'], 380, true),
('هل هناك قصائد عن الحج؟', 'مناسبات', ARRAY['حج', 'مكة'], 370, true);

ALTER TABLE question_suggestions ADD CONSTRAINT unique_question UNIQUE (full_question);
-- =====================================================
-- VERIFY INSERT
-- =====================================================

-- Count total
SELECT COUNT(*) as total_questions FROM question_suggestions;

-- Count by category
SELECT category, COUNT(*) as count 
FROM question_suggestions 
GROUP BY category 
ORDER BY count DESC;

-- Show top 10 by popularity
SELECT full_question, category, popularity 
FROM question_suggestions 
ORDER BY popularity DESC 
LIMIT 10;