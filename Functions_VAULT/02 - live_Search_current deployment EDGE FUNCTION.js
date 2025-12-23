import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    // Parse request
    const { query_text, result_limit = 30 } = await req.json()
    
    // Validate input
    if (!query_text || typeof query_text !== 'string' || query_text.trim().length === 0) {
      return new Response(
        JSON.stringify({ error: 'query_text is required and must be a non-empty string' }),
        { 
          status: 422, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    
    if (!supabaseUrl || !supabaseKey) {
      throw new Error('Missing Supabase environment variables')
    }

    const supabase = createClient(supabaseUrl, supabaseKey)

    // Call RPC function
    const { data, error } = await supabase.rpc('word_stats_preview', {
      query_text: query_text.trim(),
      result_limit: Math.min(result_limit, 100) // Cap at 100 for performance
    })

    if (error) {
      console.error('RPC Error:', error)
      return new Response(
        JSON.stringify({ 
          error: 'Database query failed', 
          details: error.message 
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // Return response in exact API format
    return new Response(
      JSON.stringify(data || [{ word_count: 0, poem_count: 0, preview_results: [] }]),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    )

  } catch (error) {
    console.error('Function error:', error)
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error',
        message: error.message 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    )
  }
})