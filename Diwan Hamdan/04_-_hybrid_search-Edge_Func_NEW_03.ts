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
      context_query = payload.query,
      metadata = {},
      match_count = 20,
      weights = {
        fts: 0.4,
        trigram: 0.3,
        exact: 0.6,
        semantic: 1.0,
      },
    } = payload;

    if (!query || typeof query !== "string") {
      throw new Error('Missing or invalid "query" field');
    }

    const searchQuery = context_query || query;
    console.log("🔍 Search:", { original: query, search: searchQuery });

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
          input: searchQuery.trim(),
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

    // Call hybrid_search
    const supabase = createClient(supabaseUrl!, supabaseKey!);

    const { data: searchResults, error: searchError } = await supabase.rpc(
      "hybrid_search",
      {
        query_text: searchQuery,
        query_embedding: embedding,
        match_count: match_count * 2,
        fts_weight: weights.fts,
        trigram_weight: weights.trigram,
        exact_weight: weights.exact,
        semantic_weight: weights.semantic,
        rrf_k: 50,
      },
    );

    if (searchError) throw searchError;
    console.log(`✅ Found ${searchResults?.length || 0} results`);

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

    // SMART MATCHING: Check if query words appear in text
    const matchesQuery = (text: string, query: string): boolean => {
      const normText = normalize(text);
      const normQuery = normalize(query);

      // Exact phrase match
      if (normText.includes(normQuery)) return true;

      // Word-based matching
      const queryWords = normQuery.split(/\s+/).filter((w) => w.length > 1);
      if (queryWords.length === 0) return false;

      // For single word queries, just check if it appears
      if (queryWords.length === 1) {
        return normText.includes(queryWords[0]);
      }

      // For multi-word queries, at least 60% of words must match
      const threshold = Math.ceil(queryWords.length * 0.6);
      const matchCount = queryWords.filter((w) => normText.includes(w)).length;

      return matchCount >= threshold;
    };

    // =====================================================
    // METADATA SCORING
    // =====================================================
    let finalResults = searchResults.map((result: any) => {
      try {
        const meta = result.metadata || {};
        const summary = result.summary_text || "";

        const entities = safeArray(meta.entities);
        const places = safeArray(meta.places);
        const animals = safeArray(meta.animals);
        const events = safeArray(meta.events);
        const religion = safeArray(meta.religion);
        const subjects = safeArray(meta.subjects);
        const sentiments = safeArray(meta.sentiments);

        let metadataBoost = 0;
        const matchedMetadata: string[] = [];

        // Summary: 50 points
        if (matchesQuery(summary, query)) {
          metadataBoost += 50;
          matchedMetadata.push("summary");
        }

        // Title: 30 points
        if (matchesQuery(meta.Title_raw || "", query)) {
          metadataBoost += 30;
          matchedMetadata.push("title");
        }

        // Entities: name +5, resolved_from +3
        entities.forEach((e: any) => {
          if (!e || typeof e !== "object") return;
          try {
            if (e.name && matchesQuery(e.name, query)) {
              metadataBoost += 5;
              matchedMetadata.push(`entity:${e.name}`);
            } else if (Array.isArray(e.resolved_from)) {
              const hasMatch = e.resolved_from.some(
                (rf: string) => rf && matchesQuery(rf, query),
              );
              if (hasMatch) {
                metadataBoost += 3;
                matchedMetadata.push(`entity:${e.name}`);
              }
            }
          } catch (err) {
            console.warn("Entity error:", err);
          }
        });

        // Places: name +4, resolved_from +2
        places.forEach((p: any) => {
          if (!p || typeof p !== "object") return;
          try {
            if (p.name && matchesQuery(p.name, query)) {
              metadataBoost += 4;
              matchedMetadata.push(`place:${p.name}`);
            } else {
              const rf = p.resolved_from;
              if (rf) {
                const rfText = Array.isArray(rf) ? rf.join(" ") : String(rf);
                if (matchesQuery(rfText, query)) {
                  metadataBoost += 2;
                  matchedMetadata.push(`place:${p.name}`);
                }
              }
            }
          } catch (err) {
            console.warn("Place error:", err);
          }
        });

        // Events: event +3, resolved_from +2
        events.forEach((e: any) => {
          if (!e || typeof e !== "object") return;
          try {
            if (e.event && matchesQuery(e.event, query)) {
              metadataBoost += 3;
              matchedMetadata.push(`event:${e.event}`);
            } else if (Array.isArray(e.resolved_from)) {
              const hasMatch = e.resolved_from.some(
                (rf: string) => rf && matchesQuery(rf, query),
              );
              if (hasMatch) {
                metadataBoost += 2;
                matchedMetadata.push(`event:${e.event}`);
              }
            }
          } catch (err) {
            console.warn("Event error:", err);
          }
        });

        // Religion: religion +3, resolved_from +2
        religion.forEach((r: any) => {
          if (!r || typeof r !== "object") return;
          try {
            if (r.religion && matchesQuery(r.religion, query)) {
              metadataBoost += 3;
              matchedMetadata.push(`religion:${r.religion}`);
            } else if (Array.isArray(r.resolved_from)) {
              const hasMatch = r.resolved_from.some(
                (rf: string) => rf && matchesQuery(rf, query),
              );
              if (hasMatch) {
                metadataBoost += 2;
                matchedMetadata.push(`religion:${r.religion}`);
              }
            }
          } catch (err) {
            console.warn("Religion error:", err);
          }
        });

        // Subjects: subject +3, resolved_from +2
        subjects.forEach((s: any) => {
          if (!s || typeof s !== "object") return;
          try {
            if (s.subject && matchesQuery(s.subject, query)) {
              metadataBoost += 3;
              matchedMetadata.push(`subject:${s.subject}`);
            } else if (Array.isArray(s.resolved_from)) {
              const hasMatch = s.resolved_from.some(
                (rf: string) => rf && matchesQuery(rf, query),
              );
              if (hasMatch) {
                metadataBoost += 2;
                matchedMetadata.push(`subject:${s.subject}`);
              }
            }
          } catch (err) {
            console.warn("Subject error:", err);
          }
        });

        // Animals: name +3, resolved_from +2
        animals.forEach((a: any) => {
          if (!a || typeof a !== "object") return;
          try {
            if (a.name && matchesQuery(a.name, query)) {
              metadataBoost += 3;
              matchedMetadata.push(`animal:${a.name}`);
            } else if (Array.isArray(a.resolved_from)) {
              const hasMatch = a.resolved_from.some(
                (rf: string) => rf && matchesQuery(rf, query),
              );
              if (hasMatch) {
                metadataBoost += 2;
                matchedMetadata.push(`animal:${a.name}`);
              }
            }
          } catch (err) {
            console.warn("Animal error:", err);
          }
        });

        // Sentiments: sentiment +2
        sentiments.forEach((s: any) => {
          if (!s || typeof s !== "object") return;
          try {
            if (s.sentiment && matchesQuery(s.sentiment, query)) {
              metadataBoost += 2;
              matchedMetadata.push(`sentiment:${s.sentiment}`);
            }
          } catch (err) {
            console.warn("Sentiment error:", err);
          }
        });

        // Exact match bonus: 10 points
        const exactBonus = result.exact_match ? 10 : 0;

        // Semantic boost: Multiply by 250 for 5x impact (0.4 semantic = 100 points!)
        // Raw semantic is 0-1, so 250x makes it comparable to other scores
        const semanticBoost = (result.semantic_sim || 0) * 250;

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

          final_score:
            (result.final_score || 0) +
            metadataBoost +
            exactBonus +
            semanticBoost,
          sql_base_score: result.final_score || 0,
          metadata_boost: metadataBoost,
          exact_bonus: exactBonus,
          semantic_boost: semanticBoost,
          matched_metadata: matchedMetadata,

          scores: {
            rrf: result.rrf_score ? (result.rrf_score * 100).toFixed(2) : "0",
            fts: result.fts_rank ? result.fts_rank.toFixed(3) : "0",
            trigram: result.trigram_sim ? result.trigram_sim.toFixed(3) : "0",
            semantic: result.semantic_sim
              ? result.semantic_sim.toFixed(3)
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
          exact_bonus: 0,
          matched_metadata: [],
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

    finalResults.sort((a: any, b: any) => b.final_score - a.final_score);
    const topResults = finalResults.slice(0, match_count);

    console.log(`✅ Returning ${topResults.length} results`);
    console.log(
      `📊 Sample boosts:`,
      topResults.slice(0, 3).map((r) => ({
        poem: r.metadata.poem_id,
        boost: r.metadata_boost,
        matched: r.matched_metadata,
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
