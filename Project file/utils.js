function normalize(text) {
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
function liveSearch(query) {
  if (!query.trim()) return [];

  const arabicQuery = mapLatinToArabic(query);
  const normQuery = normalize(arabicQuery);

  const rawResults = flexIndex.search(normQuery, {
    enrich: true,
    limit: 100,
  });
}

function mapLatinToArabic(query) {
  const tokens = query.toLowerCase().split(/\s+/);
  return tokens.map((t) => LATIN_TO_ARABIC[t] || t).join(" ");
}

// ============================================
// HIGHLIGHT
// ============================================
function highlight(text, query) {
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

// ============================================
// CSV LOADING (from V6)
// ============================================
async function loadCSV(path) {
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
      });
    }
    i++;
  }
  return rows;
}
