import React, { useState, useEffect } from "react";
import "./App.css";

function App() {
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(false);
  const [stats, setStats] = useState(null);
  
  // Separate state for each response type
  const [aiSummary, setAiSummary] = useState(null);
  const [exactResults, setExactResults] = useState([]);
  const [semanticResults, setSemanticResults] = useState([]);

  const SUPABASE_URL = "https://ezcbshyresjinfyscals.supabase.co";
  const SUPABASE_KEY = "sb_publishable_FjlIO4TFYGQZJpQm-PosDw_hk2AFmeN";
  
  // 3 SEPARATE N8N WEBHOOKS
  const N8N_WEBHOOKS = {
    aiSummary: "http://localhost:5678/webhook-test/ai-summary",
    exactSearch: "http://localhost:5678/webhook-test/exact-search",
    semanticSearch: "http://localhost:5678/webhook-test/semantic-search"
  };

  // Fetch instant stats while typing
  useEffect(() => {
    if (query.length < 2) {
      setStats(null);
      return;
    }

    const timer = setTimeout(() => {
      fetchInstantStats(query);
    }, 300);

    return () => clearTimeout(timer);
  }, [query]);

  const fetchInstantStats = async (searchQuery) => {
    try {
      const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/word_stats`, {
        method: "POST",
        headers: {
          apikey: SUPABASE_KEY,
          Authorization: `Bearer ${SUPABASE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query_text: searchQuery }),
      });

      const result = await response.json();
      if (result && result.length > 0) {
        setStats(result[0]);
      }
    } catch (error) {
      console.error("Stats error:", error);
    }
  };

  // Call all 3 N8N webhooks in PARALLEL - Show results AS THEY ARRIVE
  const performFullSearch = async (searchQuery) => {
    setLoading(true);
    
    // Clear previous results
    setAiSummary(null);
    setExactResults([]);
    setSemanticResults([]);
    
    console.log("🚀 Calling 3 N8N webhooks in parallel...");
    
    let completedCount = 0;
    const totalWebhooks = 3;
    
    // Helper to check if all webhooks are done
    const checkCompletion = () => {
      completedCount++;
      if (completedCount === totalWebhooks) {
        console.log("✅ All 3 webhooks completed!");
        setLoading(false);
      }
    };
    
    // Webhook 1: AI Summary - Process immediately when done
    fetch(N8N_WEBHOOKS.aiSummary, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: searchQuery })
    })
    .then(r => r.json())
    .then(aiResponse => {
      console.log("📊 AI Response arrived:", aiResponse);
      
      if (aiResponse) {
        if (aiResponse.choices?.[0]?.message?.content) {
          console.log("✓ Found AI Summary");
          setAiSummary(aiResponse.choices[0].message.content);
        }
        else if (Array.isArray(aiResponse) && aiResponse[0]?.message?.content) {
          console.log("✓ Found AI Summary (alt format)");
          setAiSummary(aiResponse[0].message.content);
        }
      }
      checkCompletion();
    })
    .catch(err => {
      console.error("❌ AI Summary webhook error:", err);
      checkCompletion();
    });
    
    // Webhook 2: Exact Search - Process immediately when done
    fetch(N8N_WEBHOOKS.exactSearch, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: searchQuery })
    })
    .then(r => r.json())
    .then(exactResponse => {
      console.log("📊 Exact Response arrived:", exactResponse);
      
      if (exactResponse) {
        if (exactResponse.results && Array.isArray(exactResponse.results)) {
          console.log(`✓ Found ${exactResponse.results.length} Exact Results`);
          setExactResults(exactResponse.results);
        }
        else if (Array.isArray(exactResponse)) {
          console.log(`✓ Found ${exactResponse.length} Exact Results (alt format)`);
          setExactResults(exactResponse);
        }
      }
      checkCompletion();
    })
    .catch(err => {
      console.error("❌ Exact Search webhook error:", err);
      checkCompletion();
    });
    
    // Webhook 3: Semantic Search - Process immediately when done
    fetch(N8N_WEBHOOKS.semanticSearch, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: searchQuery })
    })
    .then(r => r.json())
    .then(semanticResponse => {
      console.log("📊 Semantic Response arrived:", semanticResponse);
      
      if (semanticResponse) {
        if (semanticResponse.results && Array.isArray(semanticResponse.results)) {
          console.log(`✓ Found ${semanticResponse.results.length} Semantic Results`);
          setSemanticResults(semanticResponse.results);
        }
        else if (semanticResponse.semantic && Array.isArray(semanticResponse.semantic)) {
          console.log(`✓ Found ${semanticResponse.semantic.length} Semantic Results (semantic key)`);
          setSemanticResults(semanticResponse.semantic);
        }
        else if (Array.isArray(semanticResponse) && semanticResponse[0]?.semantic) {
          console.log(`✓ Found ${semanticResponse[0].semantic.length} Semantic Results (array format)`);
          setSemanticResults(semanticResponse[0].semantic);
        }
        else if (Array.isArray(semanticResponse)) {
          console.log(`✓ Found ${semanticResponse.length} Semantic Results (direct array)`);
          setSemanticResults(semanticResponse);
        }
      }
      checkCompletion();
    })
    .catch(err => {
      console.error("❌ Semantic Search webhook error:", err);
      checkCompletion();
    });
  };

  const handleKeyPress = (e) => {
    if (e.key === "Enter" && query.length >= 2) {
      performFullSearch(query);
    }
  };

  const highlightText = (text, searchTerm) => {
    if (!searchTerm.trim()) return text;
    const escapedTerm = searchTerm.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const regex = new RegExp(`(${escapedTerm})`, "gi");
    const parts = text.split(regex);
    return parts.map((part, i) =>
      regex.test(part) ? <mark key={i}>{part}</mark> : part
    );
  };

  // Deduplicate results by poem_id
  const deduplicateResults = (results) => {
    const seen = new Set();
    return results.filter(poem => {
      const key = `${poem.id}-${poem.poem_name}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  };

  const uniqueExactResults = deduplicateResults(exactResults);
  const uniqueSemanticResults = deduplicateResults(semanticResults);

  return (
    <div className="app">
      <div className="container">
        {/* Header */}
        <header className="header">
          <h1 className="title">قصائد الشيخ حمدان</h1>
          <p className="subtitle">بحث ذكي في مكتبة الشعر الإماراتي</p>
        </header>

        {/* Search Bar */}
        <div className="search-box">
          <svg
            className="search-icon"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
            />
          </svg>
          <input
            type="text"
            className="search-input"
            placeholder="ابحث عن قصيدة، موضوع، أو كلمة... (اضغط Enter للبحث الكامل)"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyPress={handleKeyPress}
          />
          {query && (
            <button className="clear-btn" onClick={() => {
              setQuery("");
              setAiSummary(null);
              setExactResults([]);
              setSemanticResults([]);
            }}>
              <svg fill="currentColor" viewBox="0 0 20 20">
                <path
                  fillRule="evenodd"
                  d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
                  clipRule="evenodd"
                />
              </svg>
            </button>
          )}
        </div>

        {/* Loading State */}
        {loading && (
          <div className="loading-overlay">
            <div className="spinner"></div>
            <p>جاري البحث... (3 مصادر متوازية)</p>
          </div>
        )}

        {/* Results Grid */}
        {(stats || aiSummary || uniqueExactResults.length > 0 || uniqueSemanticResults.length > 0) && !loading && (
          <div className="results-grid">
            {/* Stats Card - Live while typing */}
            {stats && (
              <div className="card stats-card">
                <div className="card-header">
                  <svg className="card-icon" fill="currentColor" viewBox="0 0 20 20">
                    <path d="M2 11a1 1 0 011-1h2a1 1 0 011 1v5a1 1 0 01-1 1H3a1 1 0 01-1-1v-5zM8 7a1 1 0 011-1h2a1 1 0 011 1v9a1 1 0 01-1 1H9a1 1 0 01-1-1V7zM14 4a1 1 0 011-1h2a1 1 0 011 1v12a1 1 0 01-1 1h-2a1 1 0 01-1-1V4z" />
                  </svg>
                  <h3>إحصائيات فورية</h3>
                </div>
                <div className="stats-grid">
                  <div className="stat-item">
                    <div className="stat-value">{stats.word_count}</div>
                    <div className="stat-label">مرة ذُكرت</div>
                  </div>
                  <div className="stat-item">
                    <div className="stat-value">{stats.poem_count}</div>
                    <div className="stat-label">قصيدة</div>
                  </div>
                </div>
              </div>
            )}

            {/* AI Summary Card */}
            {aiSummary && (
              <div className="card summary-card">
                <div className="card-header">
                  <svg className="card-icon" fill="currentColor" viewBox="0 0 20 20">
                    <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z" />
                  </svg>
                  <h3>ملخص ذكي بالذكاء الاصطناعي</h3>
                </div>
                <p className="summary-text">{aiSummary}</p>
              </div>
            )}

            {/* Exact Word Match Results */}
            {uniqueExactResults.length > 0 && (
              <div className="card poems-card full-width">
                <div className="card-header">
                  <svg className="card-icon" fill="currentColor" viewBox="0 0 20 20">
                    <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clipRule="evenodd" />
                  </svg>
                  <h3>نتائج الكلمة المباشرة ({uniqueExactResults.length})</h3>
                </div>
                <div className="poems-list">
                  {uniqueExactResults.map((poem, index) => (
                    <div key={`exact-${poem.id}-${index}`} className="poem-item exact-match">
                      <div className="poem-header">
                        <div>
                          <h4 className="poem-title">{poem.poem_name}</h4>
                          <span className="match-badge exact">مطابقة مباشرة</span>
                        </div>
                        {poem.scores && (
                          <div className="poem-score">
                            {(poem.scores.final * 100).toFixed(0)}%
                          </div>
                        )}
                      </div>
                      <div className="poem-content">
                        {highlightText(poem.content, query)}
                      </div>
                      {poem.scores && (
                        <div className="score-breakdown">
                          <span>دلالي: {(poem.scores.vector * 100).toFixed(0)}%</span>
                          <span>كلمات: {(poem.scores.keyword * 100).toFixed(0)}%</span>
                          <span>نمط: {(poem.scores.pattern * 100).toFixed(0)}%</span>
                          <span>تشابه: {(poem.scores.trigram * 100).toFixed(0)}%</span>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Semantic/Thematic Results */}
            {uniqueSemanticResults.length > 0 && (
              <div className="card poems-card full-width">
                <div className="card-header">
                  <svg className="card-icon" fill="currentColor" viewBox="0 0 20 20">
                    <path d="M10.394 2.08a1 1 0 00-.788 0l-7 3a1 1 0 000 1.84L5.25 8.051a.999.999 0 01.356-.257l4-1.714a1 1 0 11.788 1.838L7.667 9.088l1.94.831a1 1 0 00.787 0l7-3a1 1 0 000-1.838l-7-3zM3.31 9.397L5 10.12v4.102a8.969 8.969 0 00-1.05-.174 1 1 0 01-.89-.89 11.115 11.115 0 01.25-3.762zM9.3 16.573A9.026 9.026 0 007 14.935v-3.957l1.818.78a3 3 0 002.364 0l5.508-2.361a11.026 11.026 0 01.25 3.762 1 1 0 01-.89.89 8.968 8.968 0 00-5.35 2.524 1 1 0 01-1.4 0zM6 18a1 1 0 001-1v-2.065a8.935 8.935 0 00-2-.712V17a1 1 0 001 1z" />
                  </svg>
                  <h3>نتائج المعنى والموضوع ({uniqueSemanticResults.length})</h3>
                </div>
                <div className="poems-list">
                  {uniqueSemanticResults.map((poem, index) => (
                    <div key={`semantic-${poem.id}-${index}`} className="poem-item semantic-match">
                      <div className="poem-header">
                        <div>
                          <h4 className="poem-title">{poem.poem_name}</h4>
                          <span className="match-badge semantic">مطابقة معنوية</span>
                        </div>
                        {poem.scores && (
                          <div className="poem-score semantic-score">
                            {(poem.scores.final).toFixed(1)}
                          </div>
                        )}
                      </div>
                      <div className="poem-content">
                        {highlightText(poem.content, query)}
                      </div>
                      {poem.scores && (
                        <div className="score-breakdown">
                          <span>دلالي: {(poem.scores.vector * 100).toFixed(0)}%</span>
                          <span>كيانات: {poem.scores.entity?.toFixed(1) || 0}</span>
                          <span>مشاعر: {poem.scores.sentiment?.toFixed(1) || 0}</span>
                          <span>تشابه: {(poem.scores.trigram * 100).toFixed(0)}%</span>
                        </div>
                      )}
                      {poem.rerank_score && (
                        <div className="rerank-score">
                          تصنيف إعادة: {poem.rerank_score.toFixed(1)}
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {/* Empty State */}
        {!aiSummary && !loading && query.length >= 2 && uniqueExactResults.length === 0 && uniqueSemanticResults.length === 0 && (
          <div className="empty-state">
            <svg
              className="empty-icon"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M9.172 16.172a4 4 0 015.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
            <p>اضغط Enter للبحث الكامل</p>
          </div>
        )}
      </div>
    </div>
  );
}

export default App;
