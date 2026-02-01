import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const openaiKey = Deno.env.get('OPENAI_API_KEY')
const supabaseUrl = Deno.env.get('SUPABASE_URL')
const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface N8NPayload {
  query: string
  context_query: string
  metadata?: {
    entities?: string[]
    places?: string[]
    subjects?: string[]
    events?: string[]
    sentiments?: string[]
  }
  match_count?: number
  weights?: {
    fts?: number
    trigram?: number
    exact?: number
    semantic?: number
  }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const {
      query,
      context_query,
      metadata = {},
      match_count = 20,
      weights = {
        fts: 0.4,
        trigram: 0.3,
        exact: 0.6,
        semantic: 1.0,
      },
    }: N8NPayload = await req.json()

    console.log('🔍 Search request:', { query, context_query, metadata })

    // =====================================================
    // STEP 1: Generate embedding from context_query
    // =====================================================
    console.log('📝 Generating embedding for:', context_query)
    
    const embeddingResponse = await fetch('https://api.openai.com/v1/embeddings', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${openaiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'text-embedding-3-small',
        input: context_query,
        encoding_format: 'float'
      }),
    })

    if (!embeddingResponse.ok) {
      const error = await embeddingResponse.text()
      throw new Error(`OpenAI API error: ${embeddingResponse.status} - ${error}`)
    }

    const embeddingData = await embeddingResponse.json()
    const embedding = embeddingData.data[0].embedding

    console.log('✅ Embedding generated')

    // =====================================================
    // STEP 2: Call hybrid_search function
    // =====================================================
    const supabase = createClient(supabaseUrl!, supabaseKey!)
    
    const { data: searchResults, error: searchError } = await supabase.rpc('hybrid_search', {
      query_text: context_query,
      query_embedding: embedding,
      match_count: match_count * 2, // Get extra for metadata filtering
      fts_weight: weights.fts,
      trigram_weight: weights.trigram,
      exact_weight: weights.exact,
      semantic_weight: weights.semantic,
      rrf_k: 50,
    })

    if (searchError) {
      throw searchError
    }

    console.log(`✅ Found ${searchResults.length} results from hybrid_search`)

    // =====================================================
    // STEP 3: Apply metadata boosting
    // Based on your proven scoring: 60 points per metadata match
    // =====================================================
    const normalize = (text: any): string => {
      if (!text) return ''
      if (typeof text !== 'string') {
        text = String(text)
      }
      return text
        .toLowerCase()
        .replace(/[ًٌٍَُِّْ]/g, '')
        .replace(/[أإآٱ]/g, 'ا')
        .replace(/[ى]/g, 'ي')
        .replace(/[ة]/g, 'ه')
        .replace(/[ؤ]/g, 'و')
        .replace(/[ئ]/g, 'ي')
        .trim()
    }

    let finalResults = searchResults.map((result: any) => {
      let metadataBoost = 0
      const matchedMetadata: string[] = []

      // Extract metadata from JSONB
      const meta = result.metadata || {}

      // Entity matching (15 points per match - highest priority)
      if (metadata.entities?.length && meta.entities) {
        const resultEntities = meta.entities
          .map((e: any) => normalize(e?.name || ''))
          .filter(Boolean)
        const resolvedFrom = meta.entities
          .flatMap((e: any) => (e?.resolved_from || []).map((rf: any) => normalize(rf)))
          .filter(Boolean)
        
        metadata.entities.forEach(entity => {
          const normEntity = normalize(entity)
          if (!normEntity) return
          
          if (resultEntities.some((re: string) => re.includes(normEntity) || normEntity.includes(re)) ||
              resolvedFrom.some((rf: string) => rf.includes(normEntity) || normEntity.includes(rf))) {
            metadataBoost += 15
            matchedMetadata.push(`entity:${entity}`)
          }
        })
      }

      // Subject matching (12 points per match)
      if (metadata.subjects?.length && meta.subjects && Array.isArray(meta.subjects)) {
        const resultSubjects = meta.subjects
          .map((s: any) => normalize(s))
          .filter(Boolean)
        
        metadata.subjects.forEach(subject => {
          const normSubject = normalize(subject)
          if (!normSubject) return
          
          if (resultSubjects.some((rs: string) => rs.includes(normSubject) || normSubject.includes(rs))) {
            metadataBoost += 12
            matchedMetadata.push(`subject:${subject}`)
          }
        })
      }

      // Place matching (10 points per match)
      if (metadata.places?.length && meta.places) {
        const resultPlaces = meta.places
          .map((p: any) => normalize(p?.name || ''))
          .filter(Boolean)
        const resolvedFrom = meta.places
          .map((p: any) => normalize(p?.resolved_from || ''))
          .filter(Boolean)
        
        metadata.places.forEach(place => {
          const normPlace = normalize(place)
          if (!normPlace) return
          
          if (resultPlaces.some((rp: string) => rp.includes(normPlace) || normPlace.includes(rp)) ||
              resolvedFrom.some((rf: string) => rf.includes(normPlace) || normPlace.includes(rf))) {
            metadataBoost += 10
            matchedMetadata.push(`place:${place}`)
          }
        })
      }

      // Event matching (8 points per match)
      if (metadata.events?.length && meta.events && Array.isArray(meta.events)) {
        const resultEvents = meta.events
          .map((e: any) => normalize(e))
          .filter(Boolean)
        
        metadata.events.forEach(event => {
          const normEvent = normalize(event)
          if (!normEvent) return
          
          if (resultEvents.some((re: string) => re.includes(normEvent) || normEvent.includes(re))) {
            metadataBoost += 8
            matchedMetadata.push(`event:${event}`)
          }
        })
      }

      // Sentiment matching (5 points per match)
      if (metadata.sentiments?.length && meta.sentiments && Array.isArray(meta.sentiments)) {
        const resultSentiments = meta.sentiments
          .map((s: any) => normalize(s))
          .filter(Boolean)
        
        metadata.sentiments.forEach(sentiment => {
          const normSentiment = normalize(sentiment)
          if (!normSentiment) return
          
          if (resultSentiments.some((rs: string) => rs.includes(normSentiment))) {
            metadataBoost += 5
            matchedMetadata.push(`sentiment:${sentiment}`)
          }
        })
      }

      // Exact match bonus (20 points - from your implementation)
      const exactBonus = result.exact_match ? 20 : 0

      return {
        id: result.id,
        content: result.content,
        metadata: result.metadata,
        metadata_boost: metadataBoost,
        exact_bonus: exactBonus,
        matched_metadata: matchedMetadata,
        final_score: result.final_score + metadataBoost + exactBonus,
        score_breakdown: {
          base_rrf: result.rrf_score * 100,
          fts: result.fts_rank,
          trigram: result.trigram_sim,
          semantic: result.semantic_sim,
          exact_bonus: exactBonus,
          metadata_boost: metadataBoost,
          sql_final: result.final_score,
          adjusted_final: result.final_score + metadataBoost + exactBonus,
        }
      }
    })

    // Re-sort by adjusted final score
    finalResults.sort((a: any, b: any) => b.final_score - a.final_score)

    // Take top results
    const topResults = finalResults.slice(0, match_count)

    console.log(`✅ Returning ${topResults.length} results after metadata boosting`)

    // =====================================================
    // STEP 4: Return results
    // =====================================================
    return new Response(
      JSON.stringify({
        success: true,
        query: {
          original: query,
          context: context_query,
          metadata,
        },
        count: topResults.length,
        weights,
        results: topResults,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  } catch (error) {
    console.error('❌ Search error:', error)
    
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || 'Unknown error',
        stack: error.stack,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  }
})