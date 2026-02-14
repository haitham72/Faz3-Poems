CREATE OR REPLACE FUNCTION is_valid_json(text_val TEXT) RETURNS BOOLEAN AS $$
BEGIN
    PERFORM text_val::jsonb;
    RETURN TRUE;
EXCEPTION WHEN others THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

SELECT id,
       entities,
       events,
       religion,
       subjects,
       places,
       animals
FROM "Diwan_Hamdan_staging"
WHERE NOT is_valid_json(entities)
   OR NOT is_valid_json(events)
   OR NOT is_valid_json(religion)
   OR NOT is_valid_json(subjects)
   OR NOT is_valid_json(places)
   OR NOT is_valid_json(animals);
