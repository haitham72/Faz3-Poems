// poem-widget.js
import { getPoemsData } from './live-search.js';
import { highlight, wrapPoetryLine } from './utils.js';

const SUPABASE_URL = "https://ezcbshyresjinfyscals.supabase.co";
const SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV6Y2JzaHlyZXNqaW5meXNjYWxzIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2MzE2MjY0NSwiZXhwIjoyMDc4NzM4NjQ1fQ.ozzNCzjvWOym1QqxkQXxgDH2_zf-Y7trpvaaUF7ZpFs";
const SUPABASE_TABLE = "Poems_search";

export async function openPoemWidget(poemId, query) {
  console.log("Opening poem #" + poemId);
  
  let poemLines = getPoemsData().filter(line => String(line.poem_id).trim() === String(poemId).trim());
  
  if (!poemLines || poemLines.length === 0) {
    try {
      const response = await fetch(
        `${SUPABASE_URL}/rest/v1/${SUPABASE_TABLE}?poem_id=eq.${poemId}&select=*&order=Row_ID.asc`,
        {
          headers: {
            apikey: SUPABASE_KEY,
            Authorization: `Bearer ${SUPABASE_KEY}`
          }
        }
      );

      poemLines = await response.json();
      
      if (!poemLines || poemLines.length === 0) {
        alert("لم يتم العثور على القصيدة");
        return;
      }

      poemLines = poemLines.map(line => ({
        poem_id: line.poem_id,
        row_id: line.Row_ID,
        title_raw: line.Title_raw,
        poem_line_raw: line.Poem_line_raw,
        summary: line.summary,
        qafiya: line["قافية"],
        bahr: line["البحر"],
        wasl: line["وصل"],
        haraka: line["حركة"],
        naw3: line["نوع"],
        shaks: line["شخص"],
        sentiments: line.sentiments,
        amakin: line["أماكن"],
        ahdath: line["أحداث"],
        mawadi3: line["مواضيع"],
        tasnif: line["تصنيف"]
      }));
    } catch (error) {
      alert("خطأ في تحميل القصيدة");
      return;
    }
  }

  showPoemModal(poemLines, query);
}

function showPoemModal(poemLines, query) {
  const overlay = document.createElement("div");
  overlay.style.cssText = `position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.7); z-index: 1000; display: flex; align-items: center; justify-content: center; padding: 20px;`;

  const title = poemLines[0]?.title_raw || "بدون عنوان";
  const poemId = poemLines[0]?.poem_id || "";

  const formattedLines = poemLines.map((line, idx) => {
    const lineHTML = wrapPoetryLine(highlight(line.poem_line_raw, query));
    const hasMetadataMatch = checkMetadataMatch(line, query);
    const metadataClass = hasMetadataMatch ? 'metadata-triggered' : '';
    
    return `<div class="clickable-line ${metadataClass}" data-line-idx="${idx}">${lineHTML}</div>`;
  }).join("");

  overlay.innerHTML = `
    <div style="background: white; border-radius: 16px; padding: 32px; max-width: 900px; width: 90%; max-height: 80vh; overflow-y: auto; box-shadow: 0 20px 60px rgba(0,0,0,0.3); position: relative;">
      <h2 style="margin-bottom: 20px; font-size: 24px; color: #2c3e50; text-align: center;">${highlight(title, query)}</h2>
      <div style="line-height: 2; font-size: 18px; padding-bottom: 20px;">${formattedLines}</div>
      <div style="margin-top: 20px; padding-top: 20px; border-top: 1px solid #eee; font-size: 13px; color: #666; text-align: center;">قصيدة #${poemId} • ${poemLines.length} بيت</div>
      <button id="closeWidget" style="margin-top: 20px; padding: 12px 24px; border-radius: 12px; background: #3498db; color: white; border: none; cursor: pointer; font-size: 16px; display: block; margin: 20px auto 0; font-weight: 500;">إغلاق</button>
      
      <div id="metadataPanel" class="metadata-panel">
        <div class="metadata-header">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <h3 style="margin: 0; font-size: 17px; font-weight: 600; color: #2c3e50;">تفاصيل البيت</h3>
            <button id="closeMetadata" class="close-metadata-btn">×</button>
          </div>
        </div>
        <div class="metadata-body" id="metadataContent"></div>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  const clickableLines = overlay.querySelectorAll(".clickable-line");
  const metadataPanel = overlay.querySelector("#metadataPanel");
  const metadataContent = overlay.querySelector("#metadataContent");
  const closeMetadataBtn = overlay.querySelector("#closeMetadata");

  clickableLines.forEach((lineEl, idx) => {
    lineEl.addEventListener("click", () => {
      clickableLines.forEach(l => l.classList.remove("active"));
      lineEl.classList.add("active");
      showMetadata(poemLines[idx], metadataContent, metadataPanel);
    });
  });

  closeMetadataBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    metadataPanel.classList.remove("visible");
    clickableLines.forEach(l => l.classList.remove("active"));
  });

  overlay.querySelector("#closeWidget").addEventListener("click", () => overlay.remove());
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) overlay.remove();
  });

  setTimeout(() => {
    const firstMark = overlay.querySelector("mark");
    const firstMetadata = overlay.querySelector(".metadata-triggered");
    if (firstMark) firstMark.scrollIntoView({ behavior: "smooth", block: "center" });
    else if (firstMetadata) firstMetadata.scrollIntoView({ behavior: "smooth", block: "center" });
  }, 100);
}

function checkMetadataMatch(line, query) {
  const queryLower = query.toLowerCase();
  const fields = [line.shaks, line.amakin, line.ahdath, line.mawadi3, line.sentiments];
  
  for (const field of fields) {
    if (field && typeof field === 'string' && field.toLowerCase().includes(queryLower)) {
      return true;
    }
  }
  return false;
}

function showMetadata(lineData, contentEl, panelEl) {
  let html = "";

  if (lineData.summary?.trim()) {
    html += `<div class="summary-box"><span class="summary-label">ملخص البيت</span><div>${lineData.summary}</div></div>`;
  }

  const prosodyItems = [];
  if (lineData.bahr) prosodyItems.push(`<div class="metadata-chip"><span class="label">البحر:</span> ${lineData.bahr}</div>`);
  if (lineData.qafiya) prosodyItems.push(`<div class="metadata-chip"><span class="label">القافية:</span> ${lineData.qafiya}</div>`);
  if (lineData.wasl) prosodyItems.push(`<div class="metadata-chip"><span class="label">الوصل:</span> ${lineData.wasl}</div>`);
  if (lineData.haraka) prosodyItems.push(`<div class="metadata-chip"><span class="label">الحركة:</span> ${lineData.haraka}</div>`);

  if (prosodyItems.length > 0) {
    html += `<div class="metadata-section"><div class="metadata-section-title">العروض والقافية</div><div class="metadata-chips">${prosodyItems.join("")}</div></div>`;
  }

  const contentItems = [];
  
  try {
    if (lineData.shaks && lineData.shaks !== "[]") {
      const shaksArray = JSON.parse(lineData.shaks);
      if (shaksArray.length > 0) {
        const names = shaksArray.map(s => s.name || s).join("، ");
        contentItems.push(`<div class="metadata-chip"><span class="label">👤</span> ${names}</div>`);
      }
    }
  } catch (e) {}

  try {
    if (lineData.sentiments && lineData.sentiments !== "[]") {
      const sentArray = JSON.parse(lineData.sentiments);
      if (sentArray.length > 0) {
        contentItems.push(`<div class="metadata-chip"><span class="label">💭</span> ${sentArray.join("، ")}</div>`);
      }
    }
  } catch (e) {}

  try {
    if (lineData.amakin && lineData.amakin !== "[]") {
      const amakinArray = JSON.parse(lineData.amakin);
      if (amakinArray.length > 0) {
        contentItems.push(`<div class="metadata-chip"><span class="label">📍</span> ${amakinArray.join("، ")}</div>`);
      }
    }
  } catch (e) {}

  try {
    if (lineData.ahdath && lineData.ahdath !== "[]") {
      const ahdathArray = JSON.parse(lineData.ahdath);
      if (ahdathArray.length > 0) {
        contentItems.push(`<div class="metadata-chip"><span class="label">📅</span> ${ahdathArray.join("، ")}</div>`);
      }
    }
  } catch (e) {}

  try {
    if (lineData.mawadi3 && lineData.mawadi3 !== "[]") {
      const mawArray = JSON.parse(lineData.mawadi3);
      if (mawArray.length > 0) {
        contentItems.push(`<div class="metadata-chip"><span class="label">🏷️</span> ${mawArray.join("، ")}</div>`);
      }
    }
  } catch (e) {}

  if (contentItems.length > 0) {
    html += `<div class="metadata-section"><div class="metadata-section-title">المحتوى</div><div class="metadata-chips">${contentItems.join("")}</div></div>`;
  }

  const classItems = [];
  if (lineData.naw3) classItems.push(`<div class="metadata-chip"><span class="label">النوع:</span> ${lineData.naw3}</div>`);
  if (lineData.tasnif && lineData.tasnif !== "معاصر") {
    classItems.push(`<div class="metadata-chip"><span class="label">التصنيف:</span> ${lineData.tasnif}</div>`);
  }

  if (classItems.length > 0) {
    html += `<div class="metadata-section"><div class="metadata-section-title">التصنيف</div><div class="metadata-chips">${classItems.join("")}</div></div>`;
  }

  if (html) {
    contentEl.innerHTML = html;
    panelEl.classList.add("visible");
  } else {
    contentEl.innerHTML = `<div style="text-align: center; color: #999; padding: 40px 20px;"><div style="font-size: 48px; margin-bottom: 12px; opacity: 0.3;">📖</div><div>لا توجد تفاصيل إضافية لهذا البيت</div></div>`;
    panelEl.classList.add("visible");
  }
}
