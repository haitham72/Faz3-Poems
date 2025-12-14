// main.js
import { loadCSV, highlight, wrapPoetryLine } from './utils.js';
import { buildIndex, liveSearch } from './live-search.js';
import { openPoemWidget } from './poem-widget.js';

const CSV_FILE = "02 - live_search.csv";
const SUPABASE_URL = "https://ezcbshyresjinfyscals.supabase.co";
const SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV6Y2JzaHlyZXNqaW5meXNjYWxzIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2MzE2MjY0NSwiZXhwIjoyMDc4NzM4NjQ1fQ.ozzNCzjvWOym1QqxkQXxgDH2_zf-Y7trpvaaUF7ZpFs";

const searchInput = document.getElementById('searchInput');
const dropdown = document.getElementById('dropdown');
const exactResults = document.getElementById('exactResults');
const statusDiv = document.getElementById('status');
const clearBtn = document.getElementById('clearBtn');

let dropdownData = [];
let dropdownPage = 0;
const PAGE_SIZE = 5;

// DROPDOWN
function showDropdown(results, query) {
  dropdownData = results;
  dropdownPage = 0;
  renderDropdown(query);
  dropdown.classList.add('visible');
}

function renderDropdown(query) {
  const end = (dropdownPage + 1) * PAGE_SIZE;
  const items = dropdownData.slice(0, end);
  
  let html = items.map(r => `
    <div class="dropdown-item" data-poem-id="${r.poem_id}">
      <div class="dropdown-title">${highlight(r.title_raw, query)}</div>
      <div class="dropdown-poem">${highlight(r.poem_line_raw, query)}</div>
    </div>
  `).join('');
  
  if (end < dropdownData.length) {
    html += `<div class="load-more">مرر لأسفل لعرض ${dropdownData.length - end} نتيجة أخرى...</div>`;
  }
  
  dropdown.innerHTML = html;
  
  dropdown.querySelectorAll('.dropdown-item').forEach(el => {
    el.addEventListener('click', () => {
      const poemId = el.getAttribute('data-poem-id');
      dropdown.classList.remove('visible');
      openPoemWidget(poemId, query);
    });
  });
}

dropdown.addEventListener('scroll', () => {
  if (dropdown.scrollTop + dropdown.clientHeight >= dropdown.scrollHeight - 10) {
    if ((dropdownPage + 1) * PAGE_SIZE < dropdownData.length) {
      dropdownPage++;
      renderDropdown(searchInput.value);
    }
  }
});

// EXACT SEARCH
async function exactSearch(query) {
  dropdown.classList.remove('visible');
  exactResults.innerHTML = '<div style="text-align:center;padding:40px;color:#666;">جاري البحث...</div>';
  
  try {
    const threshold = query.trim().split(/\s+/).length === 1 ? 0.4 : 0.3;
    
    const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/smart_exact_search`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_KEY,
        Authorization: `Bearer ${SUPABASE_KEY}`
      },
      body: JSON.stringify({
        query_text: query,
        match_count: 50,
        score_threshold: threshold
      })
    });

    const data = await response.json();
    displayExactResults(data, query);
  } catch (error) {
    exactResults.innerHTML = `<div style="color:red;">خطأ: ${error.message}</div>`;
  }
}

function displayExactResults(results, query) {
  if (!results || results.length === 0) {
    exactResults.innerHTML = '<div style="text-align:center;padding:40px;color:#666;">لا توجد نتائج</div>';
    return;
  }

  const uniquePoems = new Set(results.map(r => r.poem_id)).size;
  const visibleMatches = results.filter(r => {
    const fields = r.source_fields || [];
    return fields.some(f => ['title', 'poem', 'summary'].includes(f));
  }).length;

  let html = `
    <div class="analytics">
      <div><span style="color:#666;">النتائج:</span> <strong>${results.length}</strong></div>
      <div><span style="color:#666;">القصائد:</span> <strong style="color:#2196F3;">${uniquePoems}</strong></div>
      <div><span style="color:#666;">تطابق نصي:</span> <strong style="color:#4CAF50;">${visibleMatches}</strong></div>
    </div>
  `;

  html += results.map((r, idx) => {
    const hasVisibleMatch = (r.source_fields || []).some(f => ['title', 'poem', 'summary'].includes(f));
    const score = parseFloat(r.final_score || 0);
    const displayScore = hasVisibleMatch ? (score - 500).toFixed(1) : score.toFixed(1);
    const icon = hasVisibleMatch ? "🎯" : "📋";
    
    let metaKeywordHTML = '';
    if (!hasVisibleMatch && r.metadata_keyword) {
      try {
        const parsed = JSON.parse(r.metadata_keyword);
        let keywordText = '';
        
        if (Array.isArray(parsed)) {
          keywordText = parsed.map(item => {
            if (typeof item === 'object' && item.name) return item.name;
            return item;
          }).join('، ');
        } else {
          keywordText = r.metadata_keyword;
        }
        
        if (keywordText) {
          metaKeywordHTML = `
            <div style="margin-top:8px;padding:8px 12px;background:#fff3e0;border-radius:8px;border-left:3px solid #ff9800;">
              <span style="font-size:11px;color:#e65100;font-weight:600;">🔍 الكلمة المفتاحية:</span>
              <span style="font-size:13px;color:#f57c00;margin-right:6px;">${keywordText}</span>
            </div>
          `;
        }
      } catch (e) {
        if (r.metadata_keyword.trim()) {
          metaKeywordHTML = `
            <div style="margin-top:8px;padding:8px 12px;background:#fff3e0;border-radius:8px;border-left:3px solid #ff9800;">
              <span style="font-size:11px;color:#e65100;font-weight:600;">🔍 الكلمة المفتاحية:</span>
              <span style="font-size:13px;color:#f57c00;margin-right:6px;">${r.metadata_keyword}</span>
            </div>
          `;
        }
      }
    }
    
    return `
      <div class="result" data-poem-id="${r.poem_id}">
        <div style="font-weight:700;font-size:18px;margin-bottom:10px;">${highlight(r.title_raw, query)}</div>
        <div style="line-height:1.9;font-size:18px;">${wrapPoetryLine(highlight(r.poem_line_raw, query))}</div>
        ${metaKeywordHTML}
        <div style="margin-top:10px;font-size:12px;color:#666;">
          <span style="background:#e3f2fd;padding:4px 10px;border-radius:12px;margin-left:4px;">قصيدة #${r.poem_id}</span>
          <span style="padding:4px 10px;border-radius:12px;margin-left:4px;">${icon} ${displayScore}</span>
        </div>
      </div>
    `;
  }).join('');

  exactResults.innerHTML = html;
  
  exactResults.querySelectorAll('.result').forEach(el => {
    el.addEventListener('click', () => {
      const poemId = el.getAttribute('data-poem-id');
      openPoemWidget(poemId, query);
    });
  });
}

// EVENTS
searchInput.addEventListener('input', (e) => {
  const query = e.target.value;
  exactResults.innerHTML = '';
  
  if (!query.trim()) {
    dropdown.classList.remove('visible');
    return;
  }
  
  const results = liveSearch(query);
  showDropdown(results, query);
});

searchInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    exactSearch(e.target.value);
  }
});

clearBtn.addEventListener('click', () => {
  searchInput.value = '';
  dropdown.classList.remove('visible');
  exactResults.innerHTML = '';
});

document.addEventListener('click', (e) => {
  if (!searchInput.contains(e.target) && !dropdown.contains(e.target)) {
    dropdown.classList.remove('visible');
  }
});

// INIT
(async function init() {
  try {
    statusDiv.textContent = "جاري تحميل البيانات...";
    const rows = await loadCSV(CSV_FILE);
    buildIndex(rows);
    statusDiv.textContent = `✅ تم تحميل ${rows.length} سطر`;
    searchInput.disabled = false;
  } catch (error) {
    statusDiv.textContent = "❌ فشل التحميل: " + error.message;
  }
})();
