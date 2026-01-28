// live-search.js
import { normalize, mapLatinToArabic } from "./utils.js";

let flexIndex = null;
let poemsData = [];

export function buildIndex(rows) {
  poemsData = rows.map((r, idx) => ({
    idx,
    poem_id: r.poem_id,
    row_id: r.row_id,
    title_raw: r.title_raw,
    poem_line_raw: r.poem_line_raw,
    summary: r.summary,
    title_clean: normalize(r.title_cleaned || r.title_raw || ""),
    line_clean: normalize(r.poem_line_cleaned || r.poem_line_raw || ""),
    entities: r.entities || "[]",
    places: r.places || "[]",
    events: r.events || "[]",
    subjects: r.subjects || "[]",
    sentiments: r.sentiments || "[]",
    category: r.category || "",
  }));

  flexIndex = new FlexSearch.Document({
    document: {
      id: "idx",
      store: [
        "poem_id",
        "row_id",
        "title_raw",
        "poem_line_raw",
        "summary",
        "entities",
        "places",
        "events",
        "subjects",
        "sentiments",
        "category",
      ],
      index: [
        { field: "title_clean", tokenize: "forward", weight: 3 },
        { field: "line_clean", tokenize: "forward", weight: 1 },
      ],
    },
    tokenize: "forward",
    cache: true,
  });

  poemsData.forEach((doc) => flexIndex.add(doc));
}

export function liveSearch(query) {
  if (!query.trim()) return [];

  const arabicQuery = mapLatinToArabic(query);
  const normQuery = normalize(arabicQuery);

  const rawResults = flexIndex.search(normQuery, {
    enrich: true,
    limit: 100,
  });

  const candidateMap = new Map();
  rawResults.forEach((bucket) => {
    if (bucket.result) {
      bucket.result.forEach((r) => {
        if (!candidateMap.has(r.id)) {
          candidateMap.set(r.id, r.doc);
        }
      });
    }
  });

  const candidates = Array.from(candidateMap.values());

  const scored = candidates.map((doc) => {
    let score = 0;
    const title = doc.title_clean || "";
    const line = doc.line_clean || "";
    const titleTokens = title.split(" ").filter(Boolean);
    const lineTokens = line.split(" ").filter(Boolean);

    if (titleTokens.includes(normQuery)) score += 120;
    if (lineTokens.includes(normQuery)) score += 80;
    if (title.indexOf(normQuery) !== -1) score += 60;
    if (line.indexOf(normQuery) !== -1) score += 30;

    return { doc, score };
  });

  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, 50).map((s) => s.doc);
}

export function getPoemsData() {
  return poemsData;
}
