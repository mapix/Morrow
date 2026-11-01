# Agent planning

Morrow currently uses native Swift orchestration, not an external agent SDK. Chat runs a bounded planning/tool/observation loop; responders use their own policy-bound loop and sandbox-runtime for isolated tools. OpenUI handles presentation only.

Planner responses use a JSON schema that separates `answer`, source IDs, operations and the optional OpenUI string. OpenUI Lang statements cannot serve as executable plans. Transport completion reasons are retained so truncated or empty outputs do not become successful plans; reasoning-only responses are never executed.

A malformed planner response receives one automatic retry using the same user instruction, a shorter-format reminder and a bounded increase in output tokens. Cancellation and HTTP errors do not trigger format retries. Unknown operation names or message targets still fail validation; retries do not alter scope or permissions. A failed second response identifies the model source. Raw model output is not persisted as diagnostics.

The UI reports format repair as ongoing work. Synthetic integration tests cover a malformed response followed by a global search outside the selected message, verified evidence and unchanged read flags. Local model checks are opt-in and use synthetic data only.
