-- Fix nested JSON strings in metadata
UPDATE documents
SET metadata = jsonb_set(
    jsonb_set(
        jsonb_set(
            jsonb_set(
                jsonb_set(
                    jsonb_set(
                        jsonb_set(
                            metadata,
                            '{entities}',
                            CASE 
                                WHEN jsonb_typeof(metadata->'entities') = 'string' 
                                THEN (metadata->>'entities')::jsonb
                                ELSE metadata->'entities'
                            END
                        ),
                        '{places}',
                        CASE 
                            WHEN jsonb_typeof(metadata->'places') = 'string' 
                            THEN (metadata->>'places')::jsonb
                            ELSE metadata->'places'
                        END
                    ),
                    '{animals}',
                    CASE 
                        WHEN jsonb_typeof(metadata->'animals') = 'string' 
                        THEN (metadata->>'animals')::jsonb
                        ELSE metadata->'animals'
                    END
                ),
                '{events}',
                CASE 
                    WHEN jsonb_typeof(metadata->'events') = 'string' 
                    THEN (metadata->>'events')::jsonb
                    ELSE metadata->'events'
                END
            ),
            '{religion}',
            CASE 
                WHEN jsonb_typeof(metadata->'religion') = 'string' 
                THEN (metadata->>'religion')::jsonb
                ELSE metadata->'religion'
            END
        ),
        '{subjects}',
        CASE 
            WHEN jsonb_typeof(metadata->'subjects') = 'string' 
            THEN (metadata->>'subjects')::jsonb
            ELSE metadata->'subjects'
        END
    ),
    '{sentiments}',
    CASE 
        WHEN jsonb_typeof(metadata->'sentiments') = 'string' 
        THEN (metadata->>'sentiments')::jsonb
        ELSE metadata->'sentiments'
    END
)
WHERE 
    jsonb_typeof(metadata->'entities') = 'string' OR
    jsonb_typeof(metadata->'places') = 'string' OR
    jsonb_typeof(metadata->'animals') = 'string' OR
    jsonb_typeof(metadata->'events') = 'string' OR
    jsonb_typeof(metadata->'religion') = 'string' OR
    jsonb_typeof(metadata->'subjects') = 'string' OR
    jsonb_typeof(metadata->'sentiments') = 'string';



-- check rows for malformed json b

SELECT 
    COUNT(*) FILTER (WHERE jsonb_typeof(metadata->'subjects') = 'string') as "Subjects_Needs_Fix",
    COUNT(*) FILTER (WHERE jsonb_typeof(metadata->'places') = 'string') as "Places_Needs_Fix",
    COUNT(*) FILTER (WHERE jsonb_typeof(metadata->'sentiments') = 'string') as "Sentiments_Needs_Fix",
    COUNT(*) FILTER (WHERE jsonb_typeof(metadata->'events') = 'string') as "Events_Needs_Fix",
    COUNT(*) FILTER (WHERE jsonb_typeof(metadata->'religion') = 'string') as "Religion_Needs_Fix",
    COUNT(*) FILTER (WHERE jsonb_typeof(metadata->'animals') = 'string') as "Animals_Needs_Fix"
FROM documents;