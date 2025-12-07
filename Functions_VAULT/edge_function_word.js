# Edge-function-exact
import { createClient } from 'npm:@supabase/supabase-js@2'
import OpenAI from 'npm:openai'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const openaiApiKey = Deno.env.get('OPENAI_API_KEY')!

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
    const openai = new OpenAI({ apiKey: openaiApiKey })

    // Generate embedding
    const embeddingResponse = await openai.embeddings.create({
      model: 'text-embedding-3-small',
      input: cleanQuery,
      dimensions: 1536,
    })
    const [{ embedding }] = embeddingResponse.data

    // Call hybrid_search_exact function
    const { data: exactResults, error: exactError } = await supabase.rpc('hybrid_search_exact', {
      query_text: cleanQuery,
      query_embedding: embedding,
      match_count: match_count
    })

    if (exactError) throw exactError

    // Format results
    const formattedResults = (exactResults || []).map(doc => ({
      id: doc.id,
      poem_name: doc.metadata?.poem_name || 'Unknown',
      content: doc.content.split('-----')[1]?.trim() || doc.content,
      match_type: doc.match_type,
      scores: {
        vector: doc.vector_score,
        keyword: doc.keyword_score,
        pattern: doc.pattern_score,
        trigram: doc.trigram_score,
        final: doc.final_score
      },
      metadata: doc.metadata
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