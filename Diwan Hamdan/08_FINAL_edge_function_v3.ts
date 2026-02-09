import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const openaiKey = Deno.env.get("OPENAI_API_KEY");
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const payload = await req.json();

    const {
      query,
      context_query,
      metadata = {},
      match_count = 5,
      weights = {},
    } = payload;

    if (!query || typeof query !== "string") {
      throw new Error('Missing or invalid "query" field');
    }

    if (!context_query || typeof context_query !== "string") {
      throw new Error('Missing or invalid "context_query" field');
    }

    console.log("🔍 Query:", query);
    console.log("📝 Context query:", context_query);
    console.log("📊 Match count:", match_count);

    // =====================================================
    // EXTRACT METADATA ARRAYS
    // =====================================================
    const extractedEntities = metadata.entities || [];
    const extractedPlaces = metadata.places || [];
    const extractedSubjects = metadata.subjects || [];
    const extractedEvents = metadata.events || [];

    console.log("🏷️ Extracted entities:", extractedEntities);
    console.log("📍 Extracted places:", extractedPlaces);
    console.log("🎯 Extracted subjects:", extractedSubjects);

    // =====================================================
    // OPUS FIX: ADJUSTED WEIGHTS
    // Prioritize semantic signals, reduce metadata noise
    // =====================================================
    const DEFAULT_WEIGHTS = {
      // Content (primary - 45%)
      content_fts_weight: 0.12,
      content_trigram_weight: 0.08,
      content_semantic_weight: 0.25, // Highest single weight

      // Summary (secondary - 20%)
      summary_fts_weight: 0.05,
      summary_semantic_weight: 0.15, // INCREASED - independent signal

      // Metadata (context - 21%)
      entity_weight: 0.08, // REDUCED - too common in corpus
      subject_weight: 0.06, // REDUCED
      place_weight: 0.04,
      event_weight: 0.02,
      religion_weight: 0.01, // REDUCED

      // Exact (precision - 14%)
      exact_weight: 0.14, // INCREASED - strong signal
    };

    const finalWeights = { ...DEFAULT_WEIGHTS, ...weights };

    console.log("⚖️ Weights (Opus-optimized):", finalWeights);

    // =====================================================
    // OPUS FIX #1: USE CLEAN CONTEXT_QUERY FOR BOTH EMBEDDINGS
    // The AI-cleaned query embeds much better than noisy user input
    // =====================================================
    const embeddingPromises = [
      // Query embedding - USE CONTEXT_QUERY (clean AI-processed text)
      fetch("https://api.openai.com/v1/embeddings", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "text-embedding-3-small",
          input: context_query.trim(), // ✅ CLEAN QUERY
          encoding_format: "float",
        }),
      }),
      // Summary embedding - ALSO USE CONTEXT_QUERY (same as OLD version)
      fetch("https://api.openai.com/v1/embeddings", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "text-embedding-3-small",
          input: context_query.trim(), // ✅ CLEAN QUERY
          encoding_format: "float",
        }),
      }),
    ];

    const [queryEmbeddingRes, summaryEmbeddingRes] =
      await Promise.all(embeddingPromises);

    if (!queryEmbeddingRes.ok || !summaryEmbeddingRes.ok) {
      throw new Error("OpenAI API error");
    }

    const [queryEmbeddingData, summaryEmbeddingData] = await Promise.all([
      queryEmbeddingRes.json(),
      summaryEmbeddingRes.json(),
    ]);

    const queryEmbedding = queryEmbeddingData.data[0].embedding;
    const summaryEmbedding = summaryEmbeddingData.data[0].embedding;

    console.log("✅ Generated 2 embeddings from CLEAN context_query");

    // =====================================================
    // CALL HYBRID SEARCH (OPUS-FIXED VERSION)
    // =====================================================
    const supabase = createClient(supabaseUrl!, supabaseKey!);

    const { data: searchResults, error: searchError } = await supabase.rpc(
      "hybrid_search_opus", // New function name
      {
        query_text: query,
        context_query_text: context_query,
        query_embedding: queryEmbedding, // Clean AI query embedding
        summary_embedding: summaryEmbedding, // Same clean embedding

        // Pass extracted metadata for filtering
        extracted_entities: extractedEntities,
        extracted_places: extractedPlaces,
        extracted_subjects: extractedSubjects,
        extracted_events: extractedEvents,

        match_count: match_count * 4, // Fetch 4x for reranker

        // Opus-optimized weights
        content_fts_weight: finalWeights.content_fts_weight,
        content_trigram_weight: finalWeights.content_trigram_weight,
        content_semantic_weight: finalWeights.content_semantic_weight,
        summary_fts_weight: finalWeights.summary_fts_weight,
        summary_semantic_weight: finalWeights.summary_semantic_weight,
        entity_weight: finalWeights.entity_weight,
        subject_weight: finalWeights.subject_weight,
        place_weight: finalWeights.place_weight,
        event_weight: finalWeights.event_weight,
        religion_weight: finalWeights.religion_weight,
        exact_weight: finalWeights.exact_weight,

        rrf_k: 50,
      },
    );

    if (searchError) throw searchError;
    console.log(`✅ SQL returned ${searchResults?.length || 0} candidates`);

    if (!searchResults || searchResults.length === 0) {
      return new Response(
        JSON.stringify({
          success: true,
          count: 0,
          results: [],
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // =====================================================
    // PROCESS RESULTS
    // =====================================================
    const safeArray = (value: any): any[] => {
      if (!value) return [];
      if (Array.isArray(value)) return value;
      try {
        if (typeof value === "string") {
          const parsed = JSON.parse(value);
          if (Array.isArray(parsed)) return parsed;
        }
      } catch {}
      return [];
    };

    const processedResults = searchResults.map((result: any) => {
      const meta = result.metadata || {};

      return {
        id: result.id,
        content: result.content,
        summary: result.summary,

        metadata: {
          Summary: result.summary,
          Title_raw: meta.Title_raw,
          Poem_line_raw: meta.Poem_line_raw,
          قافية: meta.قافية,
          روي: meta.روي,
          البحر: meta.البحر,
          category: meta.category,
          poem_id: meta.poem_id,
          chunk_id: meta.chunk_id,
          Row_IDs_in_chunk: meta.Row_IDs_in_chunk,
          chunk_type: meta.chunk_type,

          sentiments: safeArray(meta.sentiments),
          entities: safeArray(meta.entities),
          events: safeArray(meta.events),
          religion: safeArray(meta.religion),
          subjects: safeArray(meta.subjects),
          places: safeArray(meta.places),
          animals: safeArray(meta.animals),
        },

        // Scores
        final_score: result.final_score || 0,
        rrf_score: result.rrf_score || 0,

        content_fts_rank: result.content_fts_rank || 0,
        content_trigram_sim: result.content_trigram_sim || 0,
        content_semantic_sim: result.content_semantic_sim || 0,

        summary_fts_rank: result.summary_fts_rank || 0,
        summary_semantic_sim: result.summary_semantic_sim || 0, // ✅ RESTORED

        entity_match: result.entity_match || 0,
        subject_match: result.subject_match || 0,
        place_match: result.place_match || 0,
        event_match: result.event_match || 0,
        religion_match: result.religion_match || 0,

        exact_match: result.exact_match || false,
        matched_in: result.matched_in || [],
      };
    });

    // Sort by final score
    processedResults.sort((a: any, b: any) => b.final_score - a.final_score);

    // Calculate absolute scores (×100 for readability like OLD version)
    const resultsWithScores = processedResults.map((r: any) => {
      const absoluteScore = Math.round(r.final_score * 100);

      return {
        ...r,
        absolute_score: absoluteScore,
      };
    });

    console.log(`✅ Returning ${resultsWithScores.length} results`);
    console.log(
      `📊 Top result: ${resultsWithScores[0]?.absolute_score}% | Content: ${(resultsWithScores[0]?.content_semantic_sim * 100).toFixed(1)}% | Summary: ${(resultsWithScores[0]?.summary_semantic_sim * 100).toFixed(1)}%`,
    );

    return new Response(
      JSON.stringify({
        success: true,
        count: resultsWithScores.length,
        results: resultsWithScores,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (error) {
    console.error("❌ Error:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || "Unknown error",
        stack: error.stack || "",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
