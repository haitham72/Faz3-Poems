import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const body = await req.json()
    console.log('ðŸ“¥ Incoming request:', JSON.stringify(body, null, 2))

    // Extract parameters - handle multiple N8N wrapper formats
    let n8n_payload = body.n8n_payload 
      || body.query 
      || body.N8N_query 
      || body.name  // N8N sometimes wraps in "name"
      || body
    
    const total_limit = body.total_limit || n8n_payload?.total_limit || 20
    const min_score = body.min_score || n8n_payload?.min_score || 50

    // Validate structure
    if (!n8n_payload) {
      return new Response(
        JSON.stringify({ 
          error: 'Empty payload',
          received: body 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // If n8n_payload doesn't have N8N_query, check if it IS the N8N_query
    if (!n8n_payload.N8N_query && !n8n_payload.Exact_query) {
      return new Response(
        JSON.stringify({ 
          error: 'Invalid payload structure. Expected N8N_query object',
          received: body,
          extracted: n8n_payload
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // ============================================
    // SMART FORMAT CONVERSION
    // ============================================
    
    const query = n8n_payload.N8N_query

    // Remove unused "column" field
    delete query.column
    if (query.expanded_queries) {
      query.expanded_queries.forEach(eq => delete eq.column)
    }

    // Convert expanded_queries format
    // TEMPORARY FIX: Keep everything as comma-separated strings (not arrays)
    // This uses the working SQL code path with whole-word matching
    if (query.expanded_queries && Array.isArray(query.expanded_queries)) {
      query.expanded_queries = query.expanded_queries.map(eq => {
        
        // Case 1: Old format with single "query" field
        if (eq.query && !eq.queries) {
          const queryStr = eq.query.toString().trim()
          
          // Just clean and return - keep as comma string
          console.log(`âœ… Keeping as comma string: "${queryStr}"`)
          return {
            query: queryStr,
            tag: eq.tag,
            confidence_score: eq.confidence_score || 50,
            reason: eq.reason
          }
        }
        
        // Case 2: Array format - convert BACK to comma string
        if (eq.queries && Array.isArray(eq.queries)) {
          const queryStr = eq.queries.join(',')
          console.log(`âœ… Converting array back to comma string: [${eq.queries.join(', ')}] â†’ "${queryStr}"`)
          return {
            query: queryStr,
            tag: eq.tag,
            confidence_score: eq.confidence_score || 50,
            reason: eq.reason
          }
        }
        
        // Case 3: Malformed - return as-is and let SQL handle error
        console.warn('âš ï¸ Unexpected query format:', eq)
        return eq
      })
    }

    console.log('ðŸ“¤ Converted payload:', JSON.stringify({ N8N_query: query }, null, 2))

    // ============================================
    // CALL POSTGRESQL FUNCTION - UPDATED TO V2
    // ============================================

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    )

    // CHANGED: hybrid_search_v3_entity_aware â†’ hybrid_search_v2_entity_aware
    const { data, error } = await supabaseClient.rpc('hybrid_search_v2_entity_aware', {
      n8n_payload: { N8N_query: query },
      total_limit: total_limit,
      min_score: min_score
    })

    if (error) {
      console.error('âŒ Database error:', error)
      return new Response(
        JSON.stringify({ 
          error: error.message,
          details: error.details,
          hint: error.hint 
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // ============================================
    // UNWRAP NESTED RESPONSE
    // ============================================
    // The RPC returns: [{results: {summary: {}, results: []}}]
    // We want: {summary: {}, results: []}
    
    const response = data[0]?.results?.results ? {
      summary: data[0].results.summary,
      results: data[0].results.results
    } : (data[0]?.results || {});

    console.log('âœ… Success! Returned', response.results?.length || 0, 'results')

    return new Response(
      JSON.stringify(response),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    )

  } catch (error) {
    console.error('âŒ Edge function error:', error)
    return new Response(
      JSON.stringify({ 
        error: error.message,
        stack: error.stack 
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})