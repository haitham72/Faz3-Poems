--live search trigram
drop function if exists word_stats(text);

create or replace function word_stats(query_text text)
returns table (word_count bigint, poem_count bigint)
language plpgsql
as $$
begin
    return query
    select
        count(*)::bigint                                      as word_count,
        count(distinct metadata->>'poem_id')::bigint          as poem_count
    from documents
    where
        -- Exact substring (main signal)
        (
            (metadata->>'poem')        ilike '%' || query_text || '%'
         or (metadata->>'poem_name')  ilike '%' || query_text || '%'
         or (metadata->>'people')     ilike '%' || query_text || '%'
         or (metadata->>'places')     ilike '%' || query_text || '%'
        )
        
        -- Only add fuzzy when query is short AND really similar
        or (
            length(query_text) <= 6
            and (
                   word_similarity(query_text, metadata->>'poem')       > 0.55
                or word_similarity(query_text, metadata->>'poem_name') > 0.65
                or word_similarity(query_text, metadata->>'people')    > 0.60
                or word_similarity(query_text, metadata->>'places')    > 0.55
            )
        );
end;
$$;