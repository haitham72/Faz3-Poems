import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const openaiKey = Deno.env.get('OPENAI_API_KEY')
const supabaseUrl = Deno.env.get('SUPABASE_URL')
const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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
    // HELPER: Parse escaped JSON metadata
    // =====================================================
    const parseMetadataJSON = (escapedJSON: string | null): any[] => {
      if (!escapedJSON) return []
      try {
        // Format: {"key":"[{...}]"} or {"key":[{...}]}
        const parsed = typeof escapedJSON === 'string' ? JSON.parse(escapedJSON) : escapedJSON
        const key = Object.keys(parsed)[0]
        const value = parsed[key]
        return typeof value === 'string' ? JSON.parse(value) : value
      } catch {
        return []
      }
    }

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

    // =====================================================
    // STEP 3: SCORING & HIGHLIGHT DATA PREPARATION
    // =====================================================
    let finalResults = searchResults.map((result: any) => {
      const meta = result.metadata || {}
      const summary = result.summary_text || ''
      
      // Parse all metadata
      const entities = parseMetadataJSON(meta.entities)
      const places = parseMetadataJSON(meta.places)
      const animals = parseMetadataJSON(meta.animals)
      const events = parseMetadataJSON(meta.events)
      const religion = parseMetadataJSON(meta.religion)
      const subjects = parseMetadataJSON(meta.subjects)
      const sentiments = parseMetadataJSON(meta.sentiments)
      
      // CONSERVATIVE METADATA SCORING
      let metadataBoost = 0
      const matchedMetadata: string[] = []
      
      // Summary match: 50 points (HIGHEST)
      if (normalize(summary).includes(normalize(query))) {
        metadataBoost += 50
        matchedMetadata.push('summary')
      }
      
      // Title match: 30 points
      if (normalize(meta.Title_raw || '').includes(normalize(query))) {
        metadataBoost += 30
        matchedMetadata.push('title')
      }
      
      // Entities: name match +5, resolved_from match +3
      entities.forEach((e: any) => {
        if (normalize(e.name || '').includes(normalize(query))) {
          metadataBoost += 5
          matchedMetadata.push(`entity:${e.name}`)
        } else if (e.resolved_from && Array.isArray(e.resolved_from)) {
          const hasMatch = e.resolved_from.some((rf: string) => 
            normalize(rf).includes(normalize(query))
          )
          if (hasMatch) {
            metadataBoost += 3
            matchedMetadata.push(`entity:${e.name}`)
          }
        }
      })
      
      // Places: name +4, resolved_from +2
      places.forEach((p: any) => {
        if (normalize(p.name || '').includes(normalize(query))) {
          metadataBoost += 4
          matchedMetadata.push(`place:${p.name}`)
        } else if (p.resolved_from && normalize(p.resolved_from).includes(normalize(query))) {
          metadataBoost += 2
          matchedMetadata.push(`place:${p.name}`)
        }
      })
      
      // Events: event +3, resolved_from +2
      events.forEach((e: any) => {
        if (normalize(e.event || '').includes(normalize(query))) {
          metadataBoost += 3
          matchedMetadata.push(`event:${e.event}`)
        } else if (e.resolved_from && Array.isArray(e.resolved_from)) {
          const hasMatch = e.resolved_from.some((rf: string) => 
            normalize(rf).includes(normalize(query))
          )
          if (hasMatch) {
            metadataBoost += 2
            matchedMetadata.push(`event:${e.event}`)
          }
        }
      })
      
      // Religion: religion +3, resolved_from +2
      religion.forEach((r: any) => {
        if (normalize(r.religion || '').includes(normalize(query))) {
          metadataBoost += 3
          matchedMetadata.push(`religion:${r.religion}`)
        } else if (r.resolved_from && Array.isArray(r.resolved_from)) {
          const hasMatch = r.resolved_from.some((rf: string) => 
            normalize(rf).includes(normalize(query))
          )
          if (hasMatch) {
            metadataBoost += 2
            matchedMetadata.push(`religion:${r.religion}`)
          }
        }
      })
      
      // Subjects: subject +3, resolved_from +2
      subjects.forEach((s: any) => {
        if (normalize(s.subject || '').includes(normalize(query))) {
          metadataBoost += 3
          matchedMetadata.push(`subject:${s.subject}`)
        } else if (s.resolved_from && Array.isArray(s.resolved_from)) {
          const hasMatch = s.resolved_from.some((rf: string) => 
            normalize(rf).includes(normalize(query))
          )
          if (hasMatch) {
            metadataBoost += 2
            matchedMetadata.push(`subject:${s.subject}`)
          }
        }
      })
      
      // Animals: name +3, resolved_from +2
      animals.forEach((a: any) => {
        if (normalize(a.name || '').includes(normalize(query))) {
          metadataBoost += 3
          matchedMetadata.push(`animal:${a.name}`)
        } else if (a.resolved_from && Array.isArray(a.resolved_from)) {
          const hasMatch = a.resolved_from.some((rf: string) => 
            normalize(rf).includes(normalize(query))
          )
          if (hasMatch) {
            metadataBoost += 2
            matchedMetadata.push(`animal:${a.name}`)
          }
        }
      })
      
      // Sentiments: sentiment +2
      sentiments.forEach((s: any) => {
        if (normalize(s.sentiment || '').includes(normalize(query))) {
          metadataBoost += 2
          matchedMetadata.push(`sentiment:${s.sentiment}`)
        }
      })
      
      // Exact match bonus: 10 points
      const exactBonus = result.exact_match ? 10 : 0

      return {
        id: result.id,
        
        // For multi-layer highlighting
        highlight_data: {
          query: query,
          summary: summary,
          title: meta.Title_raw || '',
          entities: entities,
          places: places,
          animals: animals,
          events: events,
          religion: religion,
          subjects: subjects,
        },
        
        // Display metadata (parsed)
        metadata: {
          Summary: summary,
          Title_raw: meta.Title_raw,
          Poem_line_raw: meta.Poem_line_raw,
          قافية: meta.قافية,
          روي: meta.روي,
          البحر: meta.البحر,
          وصل: meta.وصل,
          حركة: meta.حركة,
          category: meta.category,
          sentiments: sentiments,
          entities: entities,
          events: events,
          religion: religion,
          subjects: subjects,
          places: places,
          animals: animals,
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
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  }
})
