## 🎯 Recommended RAG Test Suite Additions

### P0: Critical RAG Tests (Add Immediately)


| #   | Test Scenario                          | Expected Behavior                                                         |
| --- | -------------------------------------- | ------------------------------------------------------------------------- |
| 1   | **Retrieval Precision@K**              | Top 5 results should be 80%+ relevant to query                            |
| 2   | **Semantic vs Keyword Match Accuracy** | Semantic should find conceptually similar poems, not just keyword matches |
| 3   | **Arabic Query Understanding**         | Diacritics, synonyms, and morphological variants should match             |
| 4   | **Empty State Handling**               | Clear "No results" with suggestions when RAG returns nothing              |
| 5   | **Source Attribution**                 | Each result should show which collection/source it came from              |
| 6   | **Response Latency**                   | AI search should complete in <2 seconds                                   |
| 7   | **Hallucination Check**                | AI suggestions must reference actual poems in database                    |
| 8   | **Query Expansion**                    | Related terms should expand search scope appropriately                    |


### P1: Advanced RAG Tests


| #   | Test Scenario                    | Expected Behavior                                            |
| --- | -------------------------------- | ------------------------------------------------------------ |
| 9   | **Multi-turn Context Retention** | Follow-up queries should understand previous context         |
| 10  | **Embedding Drift Detection**    | Model updates shouldn't break existing search relevance      |
| 11  | **Cold Start Behavior**          | New poems should be searchable within X minutes of ingestion |
| 12  | **Fallback to Keyword Search**   | When semantic fails, degrade gracefully to text match        |
| 13  | **Confidence Score Display**     | Low-confidence results should be flagged or ranked lower     |
| 14  | **Poem Metadata Enrichment**     | RAG should leverage poet, era, theme metadata for ranking    |


---

## 💡 Recommendations


| Priority | Action                                                   | Owner       | Timeline  |
| -------- | -------------------------------------------------------- | ----------- | --------- |
| **P0**   | Pause UI testing, focus on RAG core functionality        | QA Lead     | Immediate |
| **P0**   | Add retrieval accuracy tests with gold standard dataset  | ML Engineer | 1 week    |
| **P0**   | Fix semantic/text match tabs (currently not displayed)   | iOS Dev     | 3 days    |
| **P1**   | Implement Arabic NLP test suite (morphology, diacritics) | ML Engineer | 2 weeks   |
| **P1**   | Add latency & performance benchmarks                     | DevOps      | 1 week    |
| **P2**   | Create hallucination detection test framework            | ML Engineer | 2 weeks   |
| **P2**   | Add multi-turn conversation context tests                | QA + ML     | 2 weeks   |


---

## 🎯 Bottom Line


| Aspect               | Current State   | Required State       |
| -------------------- | --------------- | -------------------- |
| **Test Focus**       | 85% Figma/UI    | 60% RAG Core, 40% UI |
| **RAG Tests**        | 6 (all failing) | 50+ (85%+ passing)   |
| **Production Ready** | ❌ No            | ✅ Target             |


