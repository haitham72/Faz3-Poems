// utils.js
import { LATIN_TO_ARABIC } from "./entities.js";
import { BOOSTED_WORDS } from "./entities.js";

export function normalize(text) {
  if (!text) return " ";
  return String(text)
    .replace(/[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED]/g, " ")
    .replace(/\u0640/g, " ")
    .replace(/[إأآا]/g, "ا")
    .replace(/ى/g, "ي")
    .replace(/[ؤئ]/g, "ء")
    .replace(/[.,/#!$%^&*;:{}=-_`~()؟،«»""''-——]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function mapLatinToArabic(query) {
  const lowerQuery = query.toLowerCase().trim();
  // Check exact match first (for multi-word phrases like "mohamed bin rashed")
  if (LATIN_TO_ARABIC[lowerQuery]) {
    return LATIN_TO_ARABIC[lowerQuery];
  }
  // Check for partial phrase matches (sorted by length, longest first)
  const phraseKeys = Object.keys(LATIN_TO_ARABIC)
    .filter((k) => k.includes(" "))
    .sort((a, b) => b.length - a.length);
  for (const phrase of phraseKeys) {
    if (lowerQuery.includes(phrase)) {
      const converted = lowerQuery.replace(phrase, LATIN_TO_ARABIC[phrase]);
      // Recursively convert remaining parts
      return mapLatinToArabic(converted);
    }
  }
  // Fall back to word-by-word conversion
  const tokens = lowerQuery.split(/\s+/);
  return tokens.map((t) => LATIN_TO_ARABIC[t] || t).join(" ");
}

export function wrapPoetryLine(highlightedText) {
  if (!highlightedText) return "";
  const parts = highlightedText.split(/\s{4,}/);
  if (parts.length === 2) {
    return `<div class="poetry-line"> <div class="hemistich hemistich-right">${parts[0].trim()}</div> <div class="hemistich hemistich-left">${parts[1].trim()}</div> </div>`;
  }
  return highlightedText;
}

export async function loadCSV(path) {
  const response = await fetch(path);
  const text = await response.text().then((t) => t.replace(/^\uFEFF/, ""));
  const lines = text.trim().split(/\r?\n/);
  const rows = [];
  let i = 1;
  while (i < lines.length) {
    let currentLine = lines[i];
    let parts = [];
    let current = "";
    let inQuotes = false;
    while (i < lines.length) {
      for (let j = 0; j < currentLine.length; j++) {
        const char = currentLine[j];
        if (char === '"') {
          if (inQuotes && currentLine[j + 1] === '"') {
            current += '"';
            j++;
          } else {
            inQuotes = !inQuotes;
          }
        } else if (char === "," && !inQuotes) {
          parts.push(current);
          current = " ";
        } else {
          current += char;
        }
      }

      if (inQuotes) {
        current += "\n";
        i++;
        if (i < lines.length) currentLine = lines[i];
        else break;
      } else {
        parts.push(current);
        break;
      }
    }

    if (parts.length >= 21) {
      // Updated to match your required field count
      rows.push({
        poem_id: parts[0]?.trim(),
        row_id: parts[1]?.trim(),
        title_raw: parts[2]?.trim(),
        poem_line_raw: parts[3]?.trim(),
        summary: parts[4]?.trim(), // Position 5
        title_cleaned: parts[5]?.trim(), // Position 6
        poem_line_cleaned: parts[6]?.trim(), // Position 7
        category: parts[12]?.trim(), // Position 13
        entities: parts[13]?.trim(), // Position 14
        events: parts[14]?.trim(), // Position 15
        religion: parts[15]?.trim(), // Position 16
        subjects: parts[16]?.trim(), // Position 17
        places: parts[17]?.trim(), // Position 18
        animals: parts[18]?.trim(), // Position 19
        sentiments: parts[19]?.trim(), // Position 20
      });
    }
    i++;
  }
  return rows;
}

// Add preprocessing function for entity boosting
export function preprocessQuery(query) {
  let processed = query.trim();

  // Step 1: Latin to Arabic conversion
  processed = mapLatinToArabic(processed);

  // Step 2: Fuzzy matching against boosted words
  const words = processed.split(/\s+/);
  const correctedWords = words.map((word) => {
    // If exact match exists, return as-is
    if (BOOSTED_WORDS.includes(word)) return word;

    // Otherwise, find closest match within edit distance
    const closest = findClosestBoostedWord(word);
    return closest || word; // Return original if no good match
  });

  return correctedWords.join(" ");
}

// Helper for fuzzy matching
function findClosestBoostedWord(input) {
  const threshold = 1; // Max allowed edit distance
  let bestMatch = null;
  let bestDistance = Infinity;

  for (const word of BOOSTED_WORDS) {
    const distance = levenshtein(input, word);
    if (distance <= threshold && distance < bestDistance) {
      bestDistance = distance;
      bestMatch = word;
    }
  }

  return bestMatch;
}

// Basic Arabic-aware Levenshtein
function levenshtein(a, b) {
  const confusables = { غ: "ش", ش: "غ", ت: "ث", ث: "ت", ح: "ه", ه: "ح" };

  // Normalize common Arabic character swaps before comparison
  const normA = a.replace(/./g, (c) => confusables[c] || c);
  const normB = b.replace(/./g, (c) => confusables[c] || c);

  const [str1, str2] = [normA, normB];
  const [len1, len2] = [str1.length, str2.length];
  const matrix = Array(len2 + 1)
    .fill()
    .map(() => Array(len1 + 1).fill(0));

  for (let i = 0; i <= len1; i++) matrix[0][i] = i;
  for (let j = 0; j <= len2; j++) matrix[j][0] = j;

  for (let j = 1; j <= len2; j++) {
    for (let i = 1; i <= len1; i++) {
      const cost = str1[i - 1] === str2[j - 1] ? 0 : 1;
      matrix[j][i] = Math.min(
        matrix[j][i - 1] + 1, // deletion
        matrix[j - 1][i] + 1, // insertion
        matrix[j - 1][i - 1] + cost, // substitution
      );
    }
  }

  return matrix[len2][len1];
}

export function highlight(text, query) {
  if (!text || !query) return text || "";
  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const regex = new RegExp(`(${escaped})`, "gi");
  return text.replace(regex, '<span class="highlight">$1</span>');
}
