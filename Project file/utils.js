// utils.js
import { LATIN_TO_ARABIC } from "./entities.js";

export function normalize(text) {
  if (!text) return "";
  return String(text)
    .replace(/[\u0610-\u061A\u064B-\u065F\u06D6-\u06ED]/g, "")
    .replace(/\u0640/g, "")
    .replace(/[إأآا]/g, "ا")
    .replace(/ى/g, "ي")
    .replace(/[ؤئ]/g, "ء")
    .replace(/[.,\/#!$%\^&\*;:{}=\-_`~()؟،«»"""''\-——]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function mapLatinToArabic(query) {
  const tokens = query.toLowerCase().split(/\s+/);
  return tokens.map((t) => LATIN_TO_ARABIC[t] || t).join(" ");
}

export function highlight(text, query) {
  if (!text || !query) return text;
  const normTokens = normalize(query).split(/\s+/).filter(Boolean);
  let result = text;

  normTokens.forEach((token) => {
    const pattern = Array.from(token)
      .map(
        (ch) => ch + "[\\u0610-\\u061A\\u064B-\\u065F\\u06D6-\\u06ED\\u0640]*"
      )
      .join("");
    const regex = new RegExp(pattern, "gi");
    result = result.replace(regex, (match) => `<mark>${match}</mark>`);
  });

  return result;
}

export function wrapPoetryLine(highlightedText) {
  if (!highlightedText) return "";
  const parts = highlightedText.split(/\s{4,}/);

  if (parts.length === 2) {
    return `<div class="poetry-line">
      <div class="hemistich hemistich-right">${parts[0].trim()}</div>
      <div class="hemistich hemistich-left">${parts[1].trim()}</div>
    </div>`;
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
          current = "";
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

    if (parts.length >= 7) {
      rows.push({
        poem_id: parts[0]?.trim(),
        row_id: parts[1]?.trim(),
        title_raw: parts[2]?.trim(),
        poem_line_raw: parts[3]?.trim(),
        summary: parts[4]?.trim(),
        title_cleaned: parts[5]?.trim(),
        poem_line_cleaned: parts[6]?.trim(),
        qafiya: parts[7]?.trim(),
        bahr: parts[8]?.trim(),
        wasl: parts[9]?.trim(),
        haraka: parts[10]?.trim(),
        naw3: parts[11]?.trim(),
        shaks: parts[12]?.trim(),
        sentiments: parts[13]?.trim(),
        amakin: parts[14]?.trim(),
        ahdath: parts[15]?.trim(),
        mawadi3: parts[16]?.trim(),
        tasnif: parts[17]?.trim(),
        confidence: parts[18]?.trim(),
        status: parts[19]?.trim(),
      });
    }
    i++;
  }
  return rows;
}
