-- FIXED: Direct character replacement (no unicode escapes)
CREATE OR REPLACE FUNCTION normalize_arabic_text(text_input text)
RETURNS text AS $$
DECLARE
    result text;
BEGIN
    result := text_input;
    
    -- Remove diacritics (direct characters)
    result := translate(result, 
        'ًٌٍَُِّْـ۝ۚۖۗۘ',  -- diacritics to remove
        ''                    -- replace with nothing
    );
    
    -- Normalize alef variants
    result := replace(result, 'آ', 'ا');
    result := replace(result, 'أ', 'ا');
    result := replace(result, 'إ', 'ا');
    result := replace(result, 'ٱ', 'ا');
    
    -- Normalize yaa variants
    result := replace(result, 'ى', 'ي');
    
    -- Normalize taa marbouta
    result := replace(result, 'ة', 'ه');
    
    -- Normalize hamza variants
    result := replace(result, 'ئ', 'ء');
    result := replace(result, 'ؤ', 'ء');
    
    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- UPDATE DATA
UPDATE "Diwan_Hamdan"
SET 
    "Title_cleaned" = normalize_arabic_text("Title_raw"),
    "Poem_line_cleaned" = normalize_arabic_text("Poem_line_raw");

CREATE OR REPLACE FUNCTION trigger_normalize_arabic()
RETURNS TRIGGER AS $$
BEGIN
    NEW."Title_cleaned" := normalize_arabic_text(NEW."Title_raw");
    NEW."Poem_line_cleaned" := normalize_arabic_text(NEW."Poem_line_raw");
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS normalize_on_insert ON "Diwan_Hamdan";

CREATE TRIGGER normalize_on_insert
BEFORE INSERT OR UPDATE OF "Title_raw", "Poem_line_raw"
ON "Diwan_Hamdan"
FOR EACH ROW
EXECUTE FUNCTION trigger_normalize_arabic();

-- TEST
SELECT "Poem_line_raw", "Poem_line_cleaned" 
FROM "Diwan_Hamdan" 
WHERE "Poem_line_raw" LIKE '%حبيبتي%'
LIMIT 1;