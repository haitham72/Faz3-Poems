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
    const payload = await req.json()
    
    const {
      query,
      context_query = payload.query,
      metadata = {},
      match_count = 20,
      weights = {
        fts: 0.4,
        trigram: 0.3,
        exact: 0.6,
        semantic: 1.0,
      },
    } = payload

    if (!query || typeof query !== 'string') {
      throw new Error('Missing or invalid "query" field')
    }

    const searchQuery = context_query || query
    console.log('🔍 Search:', { original: query, search: searchQuery })

    // =====================================================
    // STEP 1: Generate embedding
    // =====================================================
    if (!searchQuery || searchQuery.trim().length === 0) {
      throw new Error('Search query is empty')
    }
    
    const embeddingResponse = await fetch('https://api.openai.com/v1/embeddings', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${openaiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'text-embedding-3-small',
        input: searchQuery.trim(),
        encoding_format: 'float'
      }),
    })

    if (!embeddingResponse.ok) {
      const error = await embeddingResponse.text()
      throw new Error(`OpenAI API error: ${embeddingResponse.status} - ${error}`)
    }

    const embeddingData = await embeddingResponse.json()
    const embedding = embeddingData.data[0].embedding

    // =====================================================
    // STEP 2: Call hybrid_search
    // =====================================================
    const supabase = createClient(supabaseUrl!, supabaseKey!)
    
    const { data: searchResults, error: searchError } = await supabase.rpc('hybrid_search', {
      query_text: searchQuery,
      query_embedding: embedding,
      match_count: match_count * 2,
      fts_weight: weights.fts,
      trigram_weight: weights.trigram,
      exact_weight: weights.exact,
      semantic_weight: weights.semantic,
      rrf_k: 50,
    })

    if (searchError) throw searchError
    console.log(`✅ Found ${searchResults.length} results`)

    // =====================================================
    // STEP 3: CONSERVATIVE METADATA BOOSTING
    // Metadata is noisy - keep scores very low
    // =====================================================
    const normalize = (text: any): string => {
      if (!text) return ''
      if (typeof text !== 'string') text = String(text)
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
      const meta = result.metadata || {}

      // CONSERVATIVE SCORING (metadata is noisy)
      
      // Entities: 3 points per match
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
            metadataBoost += 3
            matchedMetadata.push(`entity:${entity}`)
          }
        })
      }

      // Subjects: 2 points per match
      if (metadata.subjects?.length && meta.subjects && Array.isArray(meta.subjects)) {
        const resultSubjects = meta.subjects.map((s: any) => normalize(s)).filter(Boolean)
        metadata.subjects.forEach(subject => {
          const normSubject = normalize(subject)
          if (!normSubject) return
          if (resultSubjects.some((rs: string) => rs.includes(normSubject) || normSubject.includes(rs))) {
            metadataBoost += 2
            matchedMetadata.push(`subject:${subject}`)
          }
        })
      }

      // Places: 2 points per match
      if (metadata.places?.length && meta.places) {
        const resultPlaces = meta.places.map((p: any) => normalize(p?.name || '')).filter(Boolean)
        const resolvedFrom = meta.places.map((p: any) => normalize(p?.resolved_from || '')).filter(Boolean)
        
        metadata.places.forEach(place => {
          const normPlace = normalize(place)
          if (!normPlace) return
          if (resultPlaces.some((rp: string) => rp.includes(normPlace) || normPlace.includes(rp)) ||
              resolvedFrom.some((rf: string) => rf.includes(normPlace) || normPlace.includes(rf))) {
            metadataBoost += 2
            matchedMetadata.push(`place:${place}`)
          }
        })
      }

      // Events: 1 point per match
      if (metadata.events?.length && meta.events && Array.isArray(meta.events)) {
        const resultEvents = meta.events.map((e: any) => normalize(e)).filter(Boolean)
        metadata.events.forEach(event => {
          const normEvent = normalize(event)
          if (!normEvent) return
          if (resultEvents.some((re: string) => re.includes(normEvent) || normEvent.includes(re))) {
            metadataBoost += 1
            matchedMetadata.push(`event:${event}`)
          }
        })
      }

      // Sentiments: 1 point per match
      if (metadata.sentiments?.length && meta.sentiments && Array.isArray(meta.sentiments)) {
        const resultSentiments = meta.sentiments.map((s: any) => normalize(s)).filter(Boolean)
        metadata.sentiments.forEach(sentiment => {
          const normSentiment = normalize(sentiment)
          if (!normSentiment) return
          if (resultSentiments.some((rs: string) => rs.includes(normSentiment))) {
            metadataBoost += 1
            matchedMetadata.push(`sentiment:${sentiment}`)
          }
        })
      }

      // Exact match: 10 points (significant but not overwhelming)
      const exactBonus = result.exact_match ? 10 : 0

      return {
        id: result.id,
        
        // For highlighting - include ALL metadata terms
        highlight_data: {
          query: query,
          entities: meta.entities || [],
          places: meta.places || [],
          animals: meta.animals || [],
          subjects: meta.subjects || [],
        },
        
        // Display metadata
        metadata: {
          Title_raw: meta.Title_raw,
          Poem_line_raw: meta.Poem_line_raw,
          قافية: meta.قافية,
          روي: meta.روي,
          البحر: meta.البحر,
          وصل: meta.وصل,
          حركة: meta.حركة,
          sentiments: meta.sentiments,
          entities: meta.entities,
          events: meta.events,
          religion: meta.religion,
          subjects: meta.subjects,
          places: meta.places,
          animals: meta.animals,
          Summary: meta.Summary,
          poem_id: meta.poem_id,
          chunk_id: meta.chunk_id,
          Row_IDs_in_chunk: meta.Row_IDs_in_chunk,
          chunk_type: meta.chunk_type,
        },
        
        // Scoring
        final_score: (result.final_score || 0) + metadataBoost + exactBonus,
        sql_base_score: result.final_score || 0,
        metadata_boost: metadataBoost,
        exact_bonus: exactBonus,
        matched_metadata: matchedMetadata,
        
        scores: {
          rrf: result.rrf_score ? (result.rrf_score * 100).toFixed(2) : '0',
          fts: result.fts_rank ? result.fts_rank.toFixed(3) : '0',
          trigram: result.trigram_sim ? result.trigram_sim.toFixed(3) : '0',
          semantic: result.semantic_sim ? result.semantic_sim.toFixed(3) : '0',
          exact: result.exact_match ? 'YES' : 'NO'
        }
      }
    })

    // Re-sort by adjusted score
    finalResults.sort((a: any, b: any) => b.final_score - a.final_score)
    const topResults = finalResults.slice(0, match_count)

    console.log(`✅ Returning ${topResults.length} results`)

    return new Response(
      JSON.stringify({
        success: true,
        count: topResults.length,
        results: topResults,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  } catch (error) {
    console.error('❌ Error:', error)
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || 'Unknown error',
        hint: 'Check query/context_query are strings'
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  }
})