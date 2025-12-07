# Edge-function-Semantic
import { createClient } from 'npm:@supabase/supabase-js@2'
import OpenAI from 'npm:openai'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const openaiApiKey = Deno.env.get('OPENAI_API_KEY')!

Deno.serve(async (req) => {
  try {
    const { 
      original_query,
      expanded_entities,  // Pre-expanded by your AI agent
      sentiments,         // Pre-expanded by your AI agent
      match_count = 20 
    } = await req.json()
   
    if (!original_query) {
      return new Response(
        JSON.stringify({ error: 'original_query is required' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const supabase = createClient(supabaseUrl, supabaseServiceRoleKey)
    const openai = new OpenAI({ apiKey: openaiApiKey })

    // Use provided expansions OR fall back to internal GPT expansion
    let finalEntities = expanded_entities || ''
    let finalSentiments = sentiments || ''

    // If no external expansions provided, do internal expansion
    if (!expanded_entities && !sentiments) {
      console.log('No external expansions, using internal GPT...')
      
      const expansionResponse = await openai.chat.completions.create({
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: `You are a semantic query expander for Arabic poetry search. Extract:
1. entities: key people, themes, occasions, poem subjects (space-separated, include Arabic and English)
2. sentiments: emotions, moods in ENGLISH (space-separated, match format: "Longing Sadness Love Joy")

Respond ONLY with JSON:
{"entities": "entity1 entity2 entity3", "sentiments": "Emotion1 Emotion2"}

Examples:
- Query: "عيد الأم" → {"entities": "mother الأم والدة أم", "sentiments": "Love Gratitude Joy"}
- Query: "الحزن والفراق" → {"entities": "separation فراق sadness", "sentiments": "Sadness Longing Grief"}`
          },
          {
            role: 'user',
            content: original_query
          }
        ],
        temperature: 0.3,
        max_tokens: 150
      })

      try {
        const expansion = JSON.parse(expansionResponse.choices[0].message.content || '{}')
        finalEntities = expansion.entities || ''
        finalSentiments = expansion.sentiments || ''
      } catch (parseError) {
        console.warn('Failed to parse GPT response, using empty expansions')
      }
    }

    // Generate embedding from original query
    const embeddingResponse = await openai.embeddings.create({
      model: 'text-embedding-3-small',
      input: original_query,
      dimensions: 1536,
    })
    const [{ embedding }] = embeddingResponse.data

    // Call semantic_hybrid_search function
    const { data: semanticResults, error: semanticError } = await supabase.rpc('semantic_hybrid_search', {
      original_query: original_query,
      expanded_entities: finalEntities,
      sentiments: finalSentiments,
      query_embedding: embedding,
      match_count: match_count
    })

    if (semanticError) throw semanticError

    // Format results
    const formattedResults = (semanticResults || []).map(doc => ({
      id: doc.id,
      poem_name: doc.metadata?.poem_name || 'Unknown',
      content: doc.content.split('-----')[1]?.trim() || doc.content,
      scores: {
        vector: doc.vector_score,
        entity: doc.entity_score,
        sentiment: doc.sentiment_score,
        trigram: doc.trigram_score,
        final: doc.final_score
      },
      metadata: doc.metadata
    }))

    return new Response(
      JSON.stringify({
        results: formattedResults,
        query_info: {
          original_query: original_query,
          expanded_entities: finalEntities,
          sentiments: finalSentiments,
          expansion_source: (expanded_entities || sentiments) ? 'external_agent' : 'internal_gpt',
          match_count: formattedResults.length,
          search_type: 'semantic_hybrid'
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