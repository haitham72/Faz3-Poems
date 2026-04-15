import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const openaiKey = Deno.env.get("OPENAI_API_KEY")!;
const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  // 1. Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // 2. Parse Input
    const { query, match_count = 5 } = await req.json();

    if (!query) throw new Error("Missing query");

    // 3. Generate Embedding (Single Query)
    const embeddingRes = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "text-embedding-3-small",
        input: query.replace(/\n/g, " "),
        encoding_format: "float",
      }),
    });

    const embeddingData = await embeddingRes.json();
    const queryEmbedding = embeddingData.data[0].embedding;

    // 4. Call Supabase RPC (Standard Vector Search)
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Note: This matches the signature of the SQL function you provided earlier
    const { data: results, error } = await supabase.rpc("match_documents", {
      filter: {}, // Empty filter to search everything
      match_count: match_count,
      query_embedding: queryEmbedding,
    });

    if (error) throw error;

    // 5. Return Simplified Response
    return new Response(
      JSON.stringify({
        success: true,
        count: results?.length || 0,
        results: results || [],
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ success: false, error: err.message }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
