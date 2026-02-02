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
// ARABIC LINGUISTIC IMPROVEMENTS
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
  "يوم", // ADDED: "day" is often noise
  "قصيدة", // ADDED: "poem" is implied in poetry search
  "قصائد",
]);

// Common Arabic synonyms/roots for query expansion
const ARABIC_SYNONYMS: Record<string, string[]> = {
  // Father
  الاب: ["الاب", "ابي", "والد", "والدي", "ابا", "اب", "الوالد"],
  اب: ["الاب", "ابي", "والد", "والدي", "ابا", "اب"],
  ابي: ["الاب", "ابي", "والد", "والدي", "ابا"],
  والد: ["الاب", "ابي", "والد", "والدي", "الوالد"],

  // Mother
  الام: ["الام", "امي", "والدة", "والدتي", "اما", "ام", "الوالدة"],
  ام: ["الام", "امي", "والدة", "والدتي", "اما"],
  امي: ["الام", "امي", "والدة", "والدتي"],

  // Martyr
  الشهيد: ["الشهيد", "شهيد", "شهداء", "الشهداء", "استشهاد"],
  شهيد: ["الشهيد", "شهيد", "شهداء", "الشهداء"],
  شهداء: ["الشهيد", "شهيد", "شهداء", "الشهداء"],

  // Love
  الحب: ["الحب", "حب", "حبيب", "محبة", "عشق", "غرام"],
  حب: ["الحب", "حب", "حبيب", "محبة"],
  عشق: ["عشق", "الحب", "حب", "غرام"],

  // War
  الحرب: ["الحرب", "حرب", "قتال", "معركة", "نزال"],
  حرب: ["الحرب", "حرب", "قتال", "معركة"],
};

/**
 * Normalize Arabic text for better matching
 */
const normalize = (text: any): string => {
  if (!text) return "";
  if (typeof text !== "string") text = String(text);
  return text
    .toLowerCase()
    .replace(/[ًٌٍَُِّْ]/g, "") // Remove diacritics
    .replace(/[أإآٱ]/g, "ا") // Normalize alef
    .replace(/[ى]/g, "ي") // Normalize ya
    .replace(/[ة]/g, "ه") // Ta marbuta -> ha
    .replace(/[ؤ]/g, "و") // Hamza on waw -> waw
    .replace(/[ئ]/g, "ي") // Hamza on ya -> ya
    .replace(/\s+/g, " ")
    .trim();
};

/**
 * Extract meaningful keywords from query (remove stop words)
 */
const extractKeywords = (query: string): string[] => {
  const normalized = normalize(query);
  const words = normalized.split(/\s+/);

  return words.filter((word) => {
    if (word.length <= 1) return false;
    return !ARABIC_STOP_WORDS.has(word);
  });
};

/**
 * Expand query with synonyms for better semantic matching
 */
const expandQuery = (query: string): string => {
  const keywords = extractKeywords(query);
  const expanded = new Set<string>();

  // Add original keywords
  keywords.forEach((kw) => expanded.add(kw));

  // Add synonyms
  keywords.forEach((kw) => {
    const synonyms = ARABIC_SYNONYMS[kw];
    if (synonyms) {
      synonyms.forEach((syn) => expanded.add(syn));
    }
  });

  // Return as space-separated string
  return Array.from(expanded).join(" ");
};

/**
 * Check if text matches query meaningfully (not just stop words)
 */
const matchesQuery = (text: string, query: string): boolean => {
  const normText = normalize(text);
  const normQuery = normalize(query);

  // Exact phrase match
  if (normText.includes(normQuery)) return true;

  // Extract meaningful words from query
  const queryWords = extractKeywords(query);

  if (queryWords.length === 0) {
    // Query is ONLY stop words - be lenient
    return normQuery.split(/\s+/).some((w) => normText.includes(w));
  }

  // For single keyword, check if it appears
  if (queryWords.length === 1) {
    return normText.includes(queryWords[0]);
  }

  // For multi-word queries, require 60% match (looser than before)
  const threshold = Math.ceil(queryWords.length * 0.6);
  const matchCount = queryWords.filter((w) => normText.includes(w)).length;

  return matchCount >= threshold;
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
      match_count = 10,
      weights = {
        fts: 0.05,
        trigram: 0.05,
        exact: 0.15,
        semantic: 3.0, // Keep high semantic weight
      },
    } = payload;

    if (!query || typeof query !== "string") {
      throw new Error('Missing or invalid "query" field');
    }

    const searchQuery = context_query || query;
    console.log("🔍 Original query:", query);

    // =====================================================
    // ARABIC PREPROCESSING: Extract keywords & expand
    // =====================================================
    const keywords = extractKeywords(searchQuery);
    console.log("🔑 Extracted keywords:", keywords);

    const expandedQuery = expandQuery(searchQuery);
    console.log("📝 Expanded query:", expandedQuery);

    // Use expanded query for embedding (better semantic matching)
    const embeddingInput = keywords.length > 0 ? expandedQuery : searchQuery;

    // Generate embedding
    const embeddingResponse = await fetch(
      "https://api.openai.com/v1/embeddings",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "text-embedding-3-small",
          input: embeddingInput.trim(),
          encoding_format: "float",
        }),
      },
    );

    if (!embeddingResponse.ok) {
      const error = await embeddingResponse.text();
      throw new Error(
        `OpenAI API error: ${embeddingResponse.status} - ${error}`,
      );
    }

    const embeddingData = await embeddingResponse.json();
    const embedding = embeddingData.data[0].embedding;

    // Call hybrid_search with adjusted parameters
    const supabase = createClient(supabaseUrl!, supabaseKey!);

    const { data: searchResults, error: searchError } = await supabase.rpc(
      "hybrid_search",
      {
        query_text: searchQuery, // Keep original for FTS/exact matching
        query_embedding: embedding,
        match_count: match_count * 4, // Get MORE candidates for filtering
        fts_weight: weights.fts,
        trigram_weight: weights.trigram,
        exact_weight: weights.exact,
        semantic_weight: weights.semantic,
        rrf_k: 50,
      },
    );

    if (searchError) throw searchError;
    console.log(`✅ Found ${searchResults?.length || 0} results from SQL`);

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
    // HELPERS
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

    // =====================================================
    // IMPROVED SCORING WITH METADATA PRIORITY
    // =====================================================
    const SEMANTIC_FLOOR = 0.35; // Raised from 0.30 - stricter filter
    const SEMANTIC_MULTIPLIER = 800; // Reduced from 1200 (less aggressive)
    const METADATA_BOOST_BASE = 150; // NEW: High boost for metadata matches

    let finalResults = searchResults.map((result: any) => {
      try {
        const meta = result.metadata || {};
        const summary = result.summary_text || "";
        const semanticSim = result.semantic_sim || 0;

        const entities = safeArray(meta.entities);
        const places = safeArray(meta.places);
        const events = safeArray(meta.events);
        const religion = safeArray(meta.religion);
        const subjects = safeArray(meta.subjects);
        const animals = safeArray(meta.animals);
        const sentiments = safeArray(meta.sentiments);

        let metadataBoost = 0;
        let rawMetadataMatches = 0;
        const matchedMetadata: string[] = [];

        // =====================================================
        // PRIORITY 1: METADATA MATCHING (HAPPENS FIRST)
        // If metadata matches keywords, boost heavily regardless of semantic score
        // =====================================================

        // Check if ANY keyword matches metadata (not just full query)
        keywords.forEach((keyword) => {
          // Entities - highest value
          entities.forEach((e: any) => {
            if (!e || typeof e !== "object") return;
            if (e.name && matchesQuery(e.name, keyword)) {
              rawMetadataMatches += 5; // High value
              matchedMetadata.push(`entity:${e.name}`);
            } else if (Array.isArray(e.resolved_from)) {
              const hasMatch = e.resolved_from.some(
                (rf: string) => rf && matchesQuery(rf, keyword),
              );
              if (hasMatch) {
                rawMetadataMatches += 3;
                matchedMetadata.push(`entity:${e.name}`);
              }
            }
          });

          // Subjects - very important for poetry
          subjects.forEach((s: any) => {
            if (!s || typeof s !== "object") return;
            if (s.subject && matchesQuery(s.subject, keyword)) {
              rawMetadataMatches += 4;
              matchedMetadata.push(`subject:${s.subject}`);
            } else if (Array.isArray(s.resolved_from)) {
              const hasMatch = s.resolved_from.some(
                (rf: string) => rf && matchesQuery(rf, keyword),
              );
              if (hasMatch) {
                rawMetadataMatches += 2;
                matchedMetadata.push(`subject:${s.subject}`);
              }
            }
          });

          // Places
          places.forEach((p: any) => {
            if (!p || typeof p !== "object") return;
            if (p.name && matchesQuery(p.name, keyword)) {
              rawMetadataMatches += 3;
              matchedMetadata.push(`place:${p.name}`);
            }
          });

          // Events
          events.forEach((e: any) => {
            if (!e || typeof e !== "object") return;
            if (e.event && matchesQuery(e.event, keyword)) {
              rawMetadataMatches += 3;
              matchedMetadata.push(`event:${e.event}`);
            }
          });

          // Religion
          religion.forEach((r: any) => {
            if (!r || typeof r !== "object") return;
            if (r.religion && matchesQuery(r.religion, keyword)) {
              rawMetadataMatches += 3;
              matchedMetadata.push(`religion:${r.religion}`);
            }
          });

          // Animals
          animals.forEach((a: any) => {
            if (!a || typeof a !== "object") return;
            if (a.name && matchesQuery(a.name, keyword)) {
              rawMetadataMatches += 3;
              matchedMetadata.push(`animal:${a.name}`);
            }
          });

          // Sentiments
          sentiments.forEach((s: any) => {
            if (!s || typeof s !== "object") return;
            if (s.sentiment && matchesQuery(s.sentiment, keyword)) {
              rawMetadataMatches += 2;
              matchedMetadata.push(`sentiment:${s.sentiment}`);
            }
          });
        });

        // Calculate metadata boost
        metadataBoost = rawMetadataMatches * METADATA_BOOST_BASE;

        // =====================================================
        // PRIORITY 2: SEMANTIC SCORING
        // =====================================================
        let semanticBoost = 0;
        let semanticPenalty = 0;

        if (semanticSim >= SEMANTIC_FLOOR) {
          // Good semantic match
          semanticBoost = semanticSim * SEMANTIC_MULTIPLIER;
        } else if (rawMetadataMatches === 0) {
          // Poor semantic AND no metadata match = penalize heavily
          semanticPenalty = -500;
        }
        // If semantic is poor BUT metadata matched, we still keep it (no penalty)

        // =====================================================
        // PRIORITY 3: EXACT MATCH BONUS
        // =====================================================
        const exactBonus = result.exact_match ? 20 : 0;

        const finalScore =
          (result.final_score || 0) +
          metadataBoost +
          semanticBoost +
          semanticPenalty +
          exactBonus;

        return {
          id: result.id,

          highlight_data: {
            query: query,
            summary: summary,
            title: meta.Title_raw || "",
            entities: entities,
            places: places,
            animals: animals,
            events: events,
            religion: religion,
            subjects: subjects,
          },

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

          final_score: finalScore,
          sql_base_score: result.final_score || 0,
          metadata_boost: metadataBoost,
          raw_metadata_matches: rawMetadataMatches,
          exact_bonus: exactBonus,
          semantic_boost: semanticBoost,
          semantic_penalty: semanticPenalty,
          matched_metadata: matchedMetadata,
          extracted_keywords: keywords,

          scores: {
            rrf: result.rrf_score ? (result.rrf_score * 20).toFixed(2) : "0",
            fts: result.fts_rank ? result.fts_rank.toFixed(2) : "0",
            trigram: result.trigram_sim ? result.trigram_sim.toFixed(2) : "0",
            semantic: result.semantic_sim
              ? result.semantic_sim.toFixed(5)
              : "0",
            exact: result.exact_match ? "YES" : "NO",
          },
        };
      } catch (mapError) {
        console.error("Error processing result:", mapError);
        return {
          id: result.id || 0,
          highlight_data: {
            query: query,
            summary: "",
            title: "",
            entities: [],
            places: [],
            animals: [],
            events: [],
            religion: [],
            subjects: [],
          },
          metadata: result.metadata || {},
          final_score: result.final_score || 0,
          sql_base_score: result.final_score || 0,
          metadata_boost: 0,
          raw_metadata_matches: 0,
          exact_bonus: 0,
          semantic_boost: 0,
          semantic_penalty: 0,
          matched_metadata: [],
          extracted_keywords: [],
          scores: {
            rrf: "0",
            fts: "0",
            trigram: "0",
            semantic: "0",
            exact: "NO",
          },
        };
      }
    });

    // Sort by final score
    finalResults.sort((a: any, b: any) => b.final_score - a.final_score);
    const topResults = finalResults.slice(0, match_count);

    console.log(`✅ Returning ${topResults.length} results`);
    console.log(
      `📊 Top 5 scoring breakdown:`,
      topResults.slice(0, 5).map((r) => ({
        poem: r.metadata.poem_id,
        semantic: r.scores.semantic,
        meta_matches: r.raw_metadata_matches,
        meta_boost: r.metadata_boost,
        sem_boost: r.semantic_boost.toFixed(0),
        penalty: r.semantic_penalty,
        final: r.final_score.toFixed(0),
        matched: r.matched_metadata.slice(0, 3),
      })),
    );

    return new Response(
      JSON.stringify({
        success: true,
        count: topResults.length,
        results: topResults,
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
