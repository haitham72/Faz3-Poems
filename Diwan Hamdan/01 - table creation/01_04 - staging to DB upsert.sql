INSERT INTO "Diwan_Hamdan" (
    id,
    poem_id,
    "Row_ID",
    "Title_raw",
    "Poem_line_raw",
    summary,
    "Title_cleaned",
    "Poem_line_cleaned",
    qafiya,
    rawy,
    meter,
    wasl,
    haraka,
    category,
    sentiments,
    entities,
    events,
    religion,
    subjects,
    places,
    animals,
    ai_image_thumb
)
SELECT
    id,
    poem_id,
    "Row_ID",
    "Title_raw",
    "Poem_line_raw",
    summary,
    "Title_cleaned",
    "Poem_line_cleaned",
    qafiya,
    rawy,
    meter,
    wasl,
    haraka,
    category,
    sentiments,
    entities::JSONB,
    events::JSONB,
    religion::JSONB,
    subjects::JSONB,
    places::JSONB,
    animals::JSONB,
    ai_image_thumb
FROM "Diwan_Hamdan_staging"
ON CONFLICT (id) DO UPDATE
SET
    poem_id = EXCLUDED.poem_id,
    "Row_ID" = EXCLUDED."Row_ID",
    "Title_raw" = EXCLUDED."Title_raw",
    "Poem_line_raw" = EXCLUDED."Poem_line_raw",
    summary = EXCLUDED.summary,
    "Title_cleaned" = EXCLUDED."Title_cleaned",
    "Poem_line_cleaned" = EXCLUDED."Poem_line_cleaned",
    qafiya = EXCLUDED.qafiya,
    rawy = EXCLUDED.rawy,
    meter = EXCLUDED.meter,
    wasl = EXCLUDED.wasl,
    haraka = EXCLUDED.haraka,
    category = EXCLUDED.category,
    sentiments = EXCLUDED.sentiments,
    entities = EXCLUDED.entities,
    events = EXCLUDED.events,
    religion = EXCLUDED.religion,
    subjects = EXCLUDED.subjects,
    places = EXCLUDED.places,
    animals = EXCLUDED.animals,
    ai_image_thumb = EXCLUDED.ai_image_thumb;

-- check column types
-- SELECT column_name, data_type
-- FROM information_schema.columns
-- WHERE table_name = 'Diwan_Hamdan'
-- ORDER BY ordinal_position;