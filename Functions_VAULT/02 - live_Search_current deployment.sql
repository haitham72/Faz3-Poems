DROP FUNCTION IF EXISTS word_stats_preview(TEXT, INT);

CREATE OR REPLACE FUNCTION word_stats_preview(
  query_text TEXT,
  result_limit INT DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  normalized_query TEXT;
  word_count_result BIGINT;
  poem_count_result BIGINT;
  preview_data JSONB;
BEGIN
  -- Normalize Arabic text
  normalized_query := regexp_replace(query_text, '[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED\u0640]', '', 'g');
  normalized_query := regexp_replace(normalized_query, '[إأآا]', 'ا', 'g');
  normalized_query := regexp_replace(normalized_query, 'ى', 'ي', 'g');
  normalized_query := regexp_replace(normalized_query, '[ؤئ]', 'ء', 'g');
  normalized_query := trim(normalized_query);
  
  -- Get total word occurrences
  SELECT COUNT(*)
  INTO word_count_result
  FROM poems_cleaned
  WHERE 
    "Text_cleaned" LIKE '%' || normalized_query || '%'
    OR "Title_cleaned" LIKE '%' || normalized_query || '%';
  
  -- Get unique poem count
  SELECT COUNT(DISTINCT poem_id)
  INTO poem_count_result
  FROM poems_cleaned
  WHERE 
    "Text_cleaned" LIKE '%' || normalized_query || '%'
    OR "Title_cleaned" LIKE '%' || normalized_query || '%';
  
  -- Get preview results
  SELECT jsonb_agg(
    jsonb_build_object(
      'poem_id', poem_id::INT,
      'title', "Title",
      'text', "Text_content",
      'match_in_title', ("Title_cleaned" LIKE '%' || normalized_query || '%'),
      'match_in_text', ("Text_cleaned" LIKE '%' || normalized_query || '%'),
      'matched_terms', ARRAY[query_text]
    )
  )
  INTO preview_data
  FROM (
    SELECT DISTINCT ON (poem_id)
      poem_id,
      "Title",
      "Text_content",
      "Title_cleaned",
      "Text_cleaned"
    FROM poems_cleaned
    WHERE 
      "Text_cleaned" LIKE '%' || normalized_query || '%'
      OR "Title_cleaned" LIKE '%' || normalized_query || '%'
    ORDER BY poem_id, "Row_number"
    LIMIT result_limit
  ) subquery;
  
  -- Return in exact API format
  RETURN jsonb_build_array(
    jsonb_build_object(
      'word_count', COALESCE(word_count_result, 0),
      'poem_count', COALESCE(poem_count_result, 0),
      'preview_results', COALESCE(preview_data, '[]'::jsonb)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION word_stats_preview(TEXT, INT) TO anon, authenticated, service_role;