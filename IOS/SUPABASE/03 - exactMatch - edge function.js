// Supabase Edge Function: hybrid-search
// Receives N8N JSON payload and calls PostgreSQL hybrid_search_exact function

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface SearchTerm {
  term: string
  type: string
  weight: number
}

interface N8NPayload {
  exact_query: string
  search_terms: SearchTerm[]
  match_count?: number
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Parse incoming JSON from N8N
    const payload: N8NPayload = await req.json()
    
    // Validate payload
    if (!payload.exact_query || !payload.search_terms || !Array.isArray(payload.search_terms)) {
      return new Response(
        JSON.stringify({ 
          error: 'Invalid payload', 
          details: 'Expected: { exact_query: string, search_terms: SearchTerm[], match_count?: number }' 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // Validate search_terms structure
    const invalidTerms = payload.search_terms.filter(
      term => !term.term || !term.type || typeof term.weight !== 'number'
    )
    if (invalidTerms.length > 0) {
      return new Response(
        JSON.stringify({ 
          error: 'Invalid search_terms', 
          details: 'Each term must have: { term: string, type: string, weight: number }',
          invalid_terms: invalidTerms
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, supabaseKey)

    // Build search payload for PostgreSQL function
    const searchPayload = {
      exact_query: payload.exact_query,
      search_terms: payload.search_terms
    }

    const matchCount = payload.match_count || 20

    // Call PostgreSQL RPC function
    const { data, error } = await supabase.rpc('hybrid_search_exact', {
      search_payload: searchPayload,
      match_limit: matchCount
    })

    if (error) {
      console.error('PostgreSQL error:', error)
      return new Response(
        JSON.stringify({ 
          error: 'Database query failed', 
          details: error.message,
          hint: error.hint || null
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // Return successful response
    return new Response(
      JSON.stringify({
        success: true,
        query: payload.exact_query,
        results: data || [],
        metadata: {
          total_results: data?.length || 0,
          match_limit: matchCount,
          expansion_terms: payload.search_terms.length,
          timestamp: new Date().toISOString()
        }
      }),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    )

  } catch (error) {
    console.error('Edge function error:', error)
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error', 
        details: error.message 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    )
  }
})