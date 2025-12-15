// Edge-function-exact (UPDATED)
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

    // Normalize score helper - converts to 0-1 range
    const normalizeScore = (score) => {
      if (!score || score === 0) return 0
      // Clamp between 0 and 1
      return Math.max(0, Math.min(1, score))
    }

    // Format results with Poem_Raw and normalized scores
    const formattedResults = (exactResults || []).map(doc => ({
      id: doc.id,
      
      // Essential metadata fields
      poem_name: doc.metadata?.poem_name || 'Unknown',
      poem_id: doc.metadata?.poem_id || null,
      people: doc.metadata?.people || '',
      places: doc.metadata?.places || '',
      qafya: doc.metadata?.qafya || '',
      bahr: doc.metadata?.bahr || '',
      sentiments: doc.metadata?.sentiments || '',
      
      // ✅ Raw poem with tashkeel/tatweel
      Poem_Raw: doc.metadata?.Poem_Raw || doc.metadata?.poem || '',
      
      // Chunk content for display
      content: doc.content.split('-----')[1]?.trim() || doc.content,
      
      match_type: doc.match_type,
      
      // ✅ Normalized scores (0-1 range)
      scores: {
        vector: normalizeScore(doc.vector_score),
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
