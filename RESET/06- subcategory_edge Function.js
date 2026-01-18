// supabase/functions/subcategory/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const body = await req.json()
    console.log('Received body:', body)
    
    const { category } = body

    if (!category) {
      return new Response(
        JSON.stringify({ error: 'category parameter required' }),
        { 
          status: 400,
          headers: { 
            ...corsHeaders,
            'Content-Type': 'application/json'
          }
        }
      )
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    console.log('Querying for category:', category)

    const { data, error } = await supabase
      .from('ios_db')
      .select('ID, Category_EN, Category_AR, SubCategory_Text_EN, SubCategory_Text_AR, url_thumbnail_view, url_focus')
      .eq('Category_EN', category)
      .order('ID')

    if (error) {
      console.error('Database error:', error)
      throw error
    }

    console.log('Found rows:', data?.length || 0)

    return new Response(
      JSON.stringify(data || []),
      { 
        headers: { 
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      }
    )
  } catch (error) {
    console.error('Function error:', error)
    return new Response(
      JSON.stringify({ 
        error: error.message,
        details: error.toString()
      }),
      { 
        status: 500,
        headers: { 
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      }
    )
  }
})