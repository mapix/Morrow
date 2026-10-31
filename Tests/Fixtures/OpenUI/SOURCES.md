# OpenUI 1.0 public fixtures

- Upstream: https://github.com/thesysdev/openui
- Pinned commit: `7df27bc8eeb6fd15ac318ca7745d225a8e16e9b9`
- Retrieved: 2026-10-30
- Source directory: https://github.com/thesysdev/openui/tree/7df27bc8eeb6fd15ac318ca7745d225a8e16e9b9/spec/fixtures/1.0
- License: MIT, Copyright (c) 2011-2024 Thesys Inc. The upstream notice is retained in `LICENSE`.

The 59 upstream data/documentation files are unchanged copies: full `library.json`, all seven grammar cases, all five state cases, all ten action cases, and their README files. `RETRIEVAL-MANIFEST.json` lists byte sizes and verified Git blob SHA-1 values. JSON files were checked for syntax only. No upstream code or test runner was executed.

Use this directory's `library.json` for these cases. It is a fixture library with `Text`, `Card(title, children)`, `Form(name, children)`, and `Input(name, placeholder, value, rules)`. These signatures differ from the default React UI library and may differ from the Morrow native profile. Preserve JSON property order when mapping positional arguments.

An interactive case has `input.oui`, `expected.json`, and `interactions.json`; the validation case uses `validation.json`. `actions/006-query-rerun-on-state`, `007-mutation-run`, and `008-tool-not-found-stops-plan` are retained as official parsing/runtime references. Do not treat their presence as authorization to execute tools or as evidence that the native profile supports that runtime.

Passing selected fixtures does not establish complete OpenUI 1.0 conformance. Record which grammar, streaming, state, action, and recovery rules the Morrow profile supports.

Normative sources:

- Language: https://github.com/thesysdev/openui/blob/7df27bc8eeb6fd15ac318ca7745d225a8e16e9b9/spec/language.md
- LibrarySpec and message protocol: https://github.com/thesysdev/openui/blob/7df27bc8eeb6fd15ac318ca7745d225a8e16e9b9/spec/prompt.md
- License: https://github.com/thesysdev/openui/blob/7df27bc8eeb6fd15ac318ca7745d225a8e16e9b9/LICENSE
