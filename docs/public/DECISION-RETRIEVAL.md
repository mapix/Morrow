# Decision retrieval

Chat search first retrieves a bounded shortlist with EmbeddingGemma 2. A separate decision model compares each query and retrieved passage, then the chat receives the retained results in the new order. The default is local Ollama `nimble` at `http://127.0.0.1:11434`.

The client calls Ollama's `/v1/systemone` protocol with a `Noul` relevance question. It follows the [TypeSafe reranking pattern](https://docs.typesafe.ai/cookbooks/rerank_typesafe): the returned number is P(the passage supplies useful evidence for the query). It is not fact-check confidence or permission to act. Candidates below 0.1 are filtered by default; uncertain 0.5 candidates are retained. Turning off filtering keeps every candidate and changes only their order.

The planner can also request the read-only `rerank` tool with a specific relevance purpose. It operates on the current turn's candidates and cannot expand the mailbox scope or modify mail. Structured-only filters retain their exact lookup order.

## Setup

Use a current Ollama release with System One support and a current Nimble model:

```sh
ollama pull nimble
```

Older Clef GGUFs with the `qwen35` architecture are rejected by current Ollama; the current model needs the `clef` architecture and converted decision head. Reimporting the old weights does not convert that head.

In Morrow settings, configure **Retrieval decision model** separately from the thinking model. A remote service receives the selected passages. The service address must be reachable from your Mac; the Nimble model is provided by the serving runtime rather than the app bundle.

## Limits and failures

- At most 40 retrieved candidates; at most 1,600 passage characters per candidate and 2,000 query characters.
- Single decision request at a time, bounded queue, 8,192 context configuration, capped HTTP response and cancellation.
- One minute of residency is requested from Ollama. Model residency is controlled by the serving runtime.
- A bounded decision pass and a 512-entry, five-minute in-memory score cache. Cache keys include query, candidate evidence, read state, model and service.
- A failure preserves every original candidate and its embedding order, with an explicit failure receipt. No partial filtering is presented as successful.

Mail content is evidence, not authorization. Ranking does not mark messages read, send replies or edit files. These safeguards and service failures are covered by fixtures; actual model quality is checked with a separate live EmbeddingGemma 2 → Nimble test.
