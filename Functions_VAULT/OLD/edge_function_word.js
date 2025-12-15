// Edge-function-exact (SIMPLIFIED - NO EMBEDDINGS)
import { createClient } from 'npm:@supabase/supabase-js@2'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

Deno.serve(async (req) => {
  try {
    const { query, match_count = 3 } = await req.json()
   
    if (!query) {
      return new Response(
        JSON.stringify({ error: 'Query is required' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const cleanQuery = query.trim()
    const supabase = createClient(supabaseUrl, supabaseServiceRoleKey)

    // Call hybrid_search_exact function (NO EMBEDDING)
    const { data: exactResults, error: exactError } = await supabase.rpc('hybrid_search_exact', {
      query_text: cleanQuery,
      match_count: match_count
      // REMOVED: query_embedding
    })

    if (exactError) throw exactError

    const normalizeScore = (score) => {
      if (!score || score === 0) return 0
      return Math.max(0, Math.min(1, score))
    }

    const formattedResults = (exactResults || []).map(doc => ({
      id: doc.id,
      poem_name: doc.metadata?.poem_name || 'Unknown',
      poem_id: doc.metadata?.poem_id || null,
      people: doc.metadata?.people || '',
      places: doc.metadata?.places || '',
      qafya: doc.metadata?.qafya || '',
      bahr: doc.metadata?.bahr || '',
      sentiments: doc.metadata?.sentiments || '',
      Poem_Raw: doc.metadata?.Poem_Raw || doc.metadata?.poem || '',
      content: doc.content.split('-----')[1]?.trim() || doc.content,
      match_type: doc.match_type,
      
      scores: {
        // REMOVED: vector score (not in function)
        keyword: normalizeScore(doc.keyword_score),
        pattern: normalizeScore(doc.pattern_score),
        trigram: normalizeScore(doc.trigram_score),
        final: normalizeScore(doc.final_score)
      }
    }))

    return new Response(
      JSON.stringify({
        results: formattedResults,
        query_info: {
          original_query: cleanQuery,
          match_count: formattedResults.length,
          search_type: 'exact_hybrid'
        }
      }),
      {
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
        }
      }
    )
  } catch (error) {
    console.error('Error:', error)
    return new Response(
      JSON.stringify({
        error: error.message,
        details: error.details,
        stack: error.stack
      }),
      {
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      }
    )
  }
})