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

// =====================================================
// ARABIC PROCESSING
// =====================================================

const ARABIC_STOP_WORDS = new Set([
  "في",
  "من",
  "إلى",
  "على",
  "عن",
  "مع",
  "أو",
  "و",
  "ل",
  "ب",
  "ك",
  "أن",
  "إن",
  "لا",
  "ما",
  "هذا",
  "هذه",
  "ذلك",
  "التي",
  "الذي",
  "هو",
  "هي",
  "كان",
  "يكون",
  "له",
  "لها",
  "هل",
  "قد",
  "لم",
  "لن",
  "إذا",
  "كل",
  "بعض",
  "غير",
  "حتى",
  "عند",
  "منذ",
  "خلال",
  "بين",
  "فوق",
  "تحت",
  "أمام",
  "وراء",
  "يوم",
  "قصيدة",
  "قصائد",
]);

const normalize = (text: any): string => {
  if (!text) return "";
  if (typeof text !== "string") text = String(text);
  return text
    .toLowerCase()
    .replace(/[ًٌٍَُِّْ]/g, "")
    .replace(/[أإآٱ]/g, "ا")
    .replace(/[ى]/g, "ي")
    .replace(/[ة]/g, "ه")
    .replace(/[ؤ]/g, "و")
    .replace(/[ئ]/g, "ي")
    .replace(/\s+/g, " ")
    .trim();
};

const extractKeywords = (query: string): string[] => {
  const normalized = normalize(query);
  const words = normalized.split(/\s+/);
  return words.filter((word) => {
    if (word.length <= 1) return false;
    return !ARABIC_STOP_WORDS.has(word);
  });
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const payload = await req.json();

    const {
      query,
      context_query = payload.query,
      metadata = {},
      match_count = 20,
      weights = {}, // Dynamic weights from N8N
    } = payload;

    if (!query || typeof query !== "string") {
      throw new Error('Missing or invalid "query" field');
    }

    const searchQuery = context_query || query;
    console.log("🔍 Original query:", query);
    console.log("📊 Requested match_count:", match_count);

    const keywords = extractKeywords(searchQuery);
    console.log("🔑 Extracted keywords:", keywords);

    // =====================================================
    // DYNAMIC WEIGHT CALCULATION
    // Default weights (100% total)
    // =====================================================
    const DEFAULT_WEIGHTS = {
      // Content (45%)
      content_fts_weight: 0.15,
      content_trigram_weight: 0.1,
      content_semantic_weight: 0.2,

      // Summary (15%)
      summary_fts_weight: 0.05,
      summary_semantic_weight: 0.1,

      // Metadata (30%)
      entity_weight: 0.1,
      subject_weight: 0.08,
      place_weight: 0.05,
      event_weight: 0.04,
      religion_weight: 0.03,

      // Exact (10%)
      exact_weight: 0.1,
    };

    // Merge with N8N weights (N8N can override any weight)
    const finalWeights = { ...DEFAULT_WEIGHTS, ...weights };

    console.log("⚖️ Final weights:", finalWeights);

    // =====================================================
    // GENERATE EMBEDDINGS
    // Two embeddings: one for content, one for summary
    // =====================================================
    const embeddingPromises = [
      // Content embedding - use expanded query with keywords
      fetch("https://api.openai.com/v1/embeddings", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "text-embedding-3-small",
          input: searchQuery.trim(),
          encoding_format: "float",
        }),
      }),
      // Summary embedding - use cleaned context_query
      fetch("https://api.openai.com/v1/embeddings", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "text-embedding-3-small",
          input: (context_query || searchQuery).trim(),
          encoding_format: "float",
        }),
      }),
    ];

    const [contentEmbeddingRes, summaryEmbeddingRes] =
      await Promise.all(embeddingPromises);

    if (!contentEmbeddingRes.ok || !summaryEmbeddingRes.ok) {
      throw new Error("OpenAI API error");
    }

    const [contentEmbeddingData, summaryEmbeddingData] = await Promise.all([
      contentEmbeddingRes.json(),
      summaryEmbeddingRes.json(),
    ]);

    const contentEmbedding = contentEmbeddingData.data[0].embedding;
    const summaryEmbedding = summaryEmbeddingData.data[0].embedding;

    console.log("✅ Generated 2 embeddings (content + summary)");

    // =====================================================
    // CALL HYBRID SEARCH WITH DYNAMIC WEIGHTS
    // =====================================================
    const supabase = createClient(supabaseUrl!, supabaseKey!);

    const { data: searchResults, error: searchError } = await supabase.rpc(
      "hybrid_search",
      {
        query_text: searchQuery,
        query_embedding: contentEmbedding,
        summary_embedding: summaryEmbedding,
        match_count: match_count * 4, // Fetch 4x for reranker

        // Content weights
        content_fts_weight: finalWeights.content_fts_weight,
        content_trigram_weight: finalWeights.content_trigram_weight,
        content_semantic_weight: finalWeights.content_semantic_weight,

        // Summary weights
        summary_fts_weight: finalWeights.summary_fts_weight,
        summary_semantic_weight: finalWeights.summary_semantic_weight,

        // Metadata weights
        entity_weight: finalWeights.entity_weight,
        subject_weight: finalWeights.subject_weight,
        place_weight: finalWeights.place_weight,
        event_weight: finalWeights.event_weight,
        religion_weight: finalWeights.religion_weight,

        // Exact match
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
          match_count_requested: match_count,
          match_count_returned: 0,
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
      try {
        if (!value) return [];
        if (Array.isArray(value)) return value;
        if (typeof value === "string") {
          try {
            const parsed = JSON.parse(value);
            if (Array.isArray(parsed)) return parsed;
          } catch {
            return [];
          }
        }
        return [];
      } catch {
        return [];
      }
    };

    const processedResults = searchResults.map((result: any) => {
      const meta = result.metadata || {};

      return {
        id: result.id,
        content: result.content,
        summary: result.summary,

        metadata: {
          Summary: result.summary, // For backward compatibility
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

          // Arrays
          sentiments: safeArray(meta.sentiments),
          entities: safeArray(meta.entities),
          events: safeArray(meta.events),
          religion: safeArray(meta.religion),
          subjects: safeArray(meta.subjects),
          places: safeArray(meta.places),
          animals: safeArray(meta.animals),
        },

        // Scores from SQL
        final_score: result.final_score || 0,
        rrf_score: result.rrf_score || 0,

        // Content scores
        content_fts_rank: result.content_fts_rank || 0,
        content_trigram_sim: result.content_trigram_sim || 0,
        content_semantic_sim: result.content_semantic_sim || 0,

        // Summary scores
        summary_fts_rank: result.summary_fts_rank || 0,
        summary_semantic_sim: result.summary_semantic_sim || 0,

        // Metadata scores
        entity_match: result.entity_match || 0,
        subject_match: result.subject_match || 0,
        place_match: result.place_match || 0,
        event_match: result.event_match || 0,
        religion_match: result.religion_match || 0,

        // Other
        exact_match: result.exact_match || false,
        matched_in: result.matched_in || [],

        // Metadata for reranker
        extracted_keywords: keywords,
      };
    });

    // Sort by final score
    processedResults.sort((a: any, b: any) => b.final_score - a.final_score);

    // Calculate absolute and relative scores
    if (processedResults.length === 0) {
      return new Response(
        JSON.stringify({
          success: true,
          count: 0,
          results: [],
          match_count_requested: match_count,
          match_count_returned: 0,
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const maxAbsoluteScore = Math.max(
      ...processedResults.map((r: any) => r.final_score),
    );
    const minAbsoluteScore = Math.min(
      ...processedResults.map((r: any) => r.final_score),
    );

    console.log(
      `📊 Score range: ${minAbsoluteScore.toFixed(2)} - ${maxAbsoluteScore.toFixed(2)}`,
    );

    const resultsWithScores = processedResults.map((r: any) => {
      const absoluteScore =
        maxAbsoluteScore > 0
          ? Math.round((r.final_score / maxAbsoluteScore) * 100)
          : 0;

      const relativeScore =
        maxAbsoluteScore > minAbsoluteScore
          ? Math.round(
              ((r.final_score - minAbsoluteScore) /
                (maxAbsoluteScore - minAbsoluteScore)) *
                100,
            )
          : 100;

      return {
        ...r,
        absolute_score: absoluteScore,
        relative_score: relativeScore,
      };
    });

    console.log(
      `✅ Returning ${resultsWithScores.length} candidates for reranker`,
    );
    console.log(
      `📊 Top 5 breakdown:`,
      resultsWithScores.slice(0, 5).map((r: any) => ({
        poem: r.metadata.poem_id,
        absolute: r.absolute_score,
        final: r.final_score.toFixed(0),
        content_sem: r.content_semantic_sim.toFixed(3),
        summary_sem: r.summary_semantic_sim.toFixed(3),
      })),
    );

    return new Response(
      JSON.stringify({
        success: true,
        count: resultsWithScores.length,
        results: resultsWithScores,
        match_count_requested: match_count,
        match_count_returned: resultsWithScores.length,
        max_absolute_score: maxAbsoluteScore.toFixed(2),
        query_metadata: metadata, // Pass to reranker
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
