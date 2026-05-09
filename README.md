# AICoven Local (Open Source Swift Client)

AICoven Local is a Swift client that lets you run an AI assistant with **no dependency on a custom backend**. All app state (chats, documents, settings) is stored locally on your device. The only network calls are directly to the model providers you configure (e.g. OpenAI, Anthropic, Gemini) using your own API keys — or to a **local LLM server** like [Ollama](https://ollama.com) running on your machine.

For the cloud version of the app go to https://aicoven.ai/

## Goals

- **No backend required**: everything happens on device. The only API calls are made to AI model providers.
- **Local-first data**: chats, documents, and settings live on-device.
- **User-provided API keys**: you bring your own keys for LLM/embedding providers.
- **Local LLM support**: run models directly on your Mac or iPhone via [MLX](https://github.com/ml-explore/mlx-swift) (on-device, no server needed) or via [Ollama](https://ollama.com) — no API key needed for either.
- **MCP server integration**: connect to any [Model Context Protocol](https://modelcontextprotocol.io) server (e.g. Zapier, custom tools) to extend the assistant's capabilities with external actions.
- **Simple default assistant**: a single configurable assistant that "just works" out of the box.

## Current status

This repo started as an extraction of the original multi-tenant AICoven app and is being reshaped into a **standalone, local-first client**. The current codebase already includes:

- A provider-agnostic `LLMClient` + `ModelRouter` used for all LLM calls, supporting OpenAI, Anthropic, Google Gemini, Ollama, and on-device MLX models.
- Encrypted local context storage (threads, memories, settings) backed by SQLite/GRDB.
- A "context sandwich" builder that composes system contract, policies, time, memories, history, and the current turn — with device-aware context limits for iPhones.
- A tools layer (`ToolEnvironment` + `ToolService`) that exposes web search, file/image analysis, and local file/image generation using only your provider keys.
- An MCP client (`MCPClient`) that connects to remote MCP servers over HTTP/SSE, discovers tools, and executes them — with semantic tool selection via embedding-based matching and a benchmark suite for evaluating local model tool-calling accuracy.
- Shell command tools with an approval flow, and connected-app integrations (GitHub, Google Drive).
- StoreKit 2 in-app purchase support with a community edition compile flag.

Some files from the original cloud app remain in the codebase (e.g. covens, roles, remote memory services). Covens and roles are actively being reintegrated into the local client. These features are **not** required to use the basic local assistant.

### In-App Purchases

Some premium features (shell tools, GitHub integration, Google Drive integration) require an in-app purchase. The StoreKit 2 purchase flow is enabled for all builds — users see the Store UI and can unlock features by making a purchase.

## High-level architecture

- **SwiftUI app** (iOS + macOS, Mac Catalyst): single codebase under `swift/AICoven/AICoven`.
- **Persistence**: SQLite via GRDB for threads, messages, memories, provider accounts, settings, and agent runs/steps.
- **Encryption**: chats, memories, and provider configs encrypted at rest using a key derived from a user passphrase.
- **Secrets**: API keys stored via a `SecretsStore` abstraction backed by the system Keychain.
- **LLM abstraction**: `LLMClient` protocol and `HeuristicModelRouter` to pick the right `(providerID, modelID)` for each task, with user-preference-first routing via `findExact`.
- **Tools layer**: `ToolEnvironment` + `ToolService` offering time, web search, attachment analysis, file/image generation, shell commands (with approval), and connected apps.
- **Memory model**: encrypted `memory_chunks` and `memory_proposals` tables accessed via repositories and `MemoryService`, with user- and thread-scoped snippets stored alongside optional embeddings and tags.
- **Autonomous agents**: an `AgentRunner` that executes bounded multi-step runs fully locally, backed by encrypted `agent_runs`/`agent_steps` tables and sharing the same context sandwich, tools, and routing as interactive chat.

For a deeper dive into the context sandwich, encrypted storage, and routing, see `docs/local-context-architecture.md`.

## Project layout

The Swift sources live under `swift/` and are organized as:

- `swift/AICoven/AICoven/App` – App entry point and top-level navigation (`AICovenApp`, `ContentView`).
- `swift/AICoven/AICoven/Core` – Local-first domain layer:
  - `Core/LLM` – `LLMClient`, `ModelRouter`, `ToolEnvironment`, model descriptors.
  - `Core/Context` – Context sandwich builder used by chat and agents.
  - `Core/Routing` – Model routing and selection logic (including `findExact` for user preferences).
  - `Core/Agents` – Autonomous agent runner and profiles.
  - `Core/Tools` – `ToolExecutionService` with shell command approval and connected-app integrations.
- `swift/AICoven/AICoven/Infrastructure` – Cross-cutting concerns:
  - `Infrastructure/Persistence` – GRDB database manager and repository actors for threads, messages, memories, settings.
  - `Infrastructure/Keychain` – `SecretsStore` and Keychain-backed implementation.
  - `Infrastructure/Design` – Design system and shared styles.
  - `Infrastructure/Security` – `DataEncryptionService` for encrypted storage.
  - `Infrastructure/Tools` – `ToolService` (time, web search, attachment analysis, file/image generation).
- `swift/AICoven/AICoven/Models` – Domain model types (threads, messages, memories, provider configs, agent runs/steps).
- `swift/AICoven/AICoven/Networking` – Environment configuration.
- `swift/AICoven/AICoven/Features` – Feature-oriented SwiftUI modules (chat, settings, etc.).
- `swift/AICoven/AICoven/Views`, `ViewModels` – Older view hierarchy from the original app; being gradually migrated to Features.
- `swift/AICoven/AICoven/Services` – Service layer including `ChatService`, `StoreService` (StoreKit 2), `StrixSettingsService`, and legacy services being refactored.
- `swift/AICoven/AICovenTests` – XCTest suite with 18 test files covering LLM clients, services, infrastructure, and integration scenarios.

**Note:** Some legacy types (covens, roles, cloud authentication) remain in the codebase but are not used in the local-first client. New code should use `Core/LLM`, `Core/Context`, and `Infrastructure/*` rather than extending legacy services.

## Implementation status

The local-first client is functional for core workflows but some features are still in development:

### ✅ Fully Implemented
- Local SQLite storage via GRDB for threads, messages, memories, settings, agent runs
- Encrypted storage using passphrase-derived keys (`DataEncryptionService`)
- Provider-agnostic `LLMClient` abstraction with model routing (`HeuristicModelRouter`)
- User-preference-first model selection via `findExact` routing
- Context sandwich builder with runtime time, policies, memory retrieval
- Autonomous agent runner with bounded multi-step execution
- Web search via DuckDuckGo (no API key required)
- Attachment analysis for files and images
- Enhanced chat UI with thread management
- Shell command tools with approval flow
- Connected apps: GitHub and Google Drive integrations
- Local LLM support via Ollama and on-device MLX with automatic model discovery
- MLX model catalog with category/tier classification (General, Coding, Mobile), device-aware filtering, and AICoven fine-tuned MCP models
- MLX on iPhone support (6 GB+ RAM) with automatic memory management (model eviction, GPU cache limits, tool context truncation)
- Native tool calling for API providers (OpenAI, Anthropic, Gemini) with text-based fallback for local models
- MCP server integration with tool discovery, execution, caching, SSE transport, and semantic tool selection
- MCP tool-calling benchmark suite for evaluating local model accuracy (`MCPToolCallingBenchmark`)
- StoreKit 2 in-app purchases for premium features
- SwiftLint configuration (`.swiftlint.yml`) and CI workflow

### 🚧 Partially Implemented
- Image and file generation tools (basic implementation, can be extended)
- Memory retrieval and hybrid search (functional but can be improved)
- Settings UI (works but has TODOs for cache clearing, advanced options)
- Provider key management (functional but UI could be enhanced)
- Thread rename/pin functionality (UI affordances present but not wired up)

### ⚠️ Known Limitations
- Some legacy cloud services are present but non-functional; they are being removed as they are found
- Test coverage is moderate (~25% overall) — see [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) for details

For detailed code review findings and recommendations, see [`docs/CODE_REVIEW.md`](docs/CODE_REVIEW.md).

## Tools and capabilities

The tools layer is provider-agnostic and designed to work with whatever keys you configure:

- **Time** (`current_time`) – Timezone-aware current time, injected into the context sandwich.
- **Web search** (`web_search`) – Powered by DuckDuckGo's public JSON API (no extra keys).
- **Web visit** (`web_visit`) – Fetch and summarize the content of a URL.
- **File read/write/list** (`file.read`, `file.write`, `file.list`) – Read, write, and list local files and directories.
- **Shell commands** (`shell.execute`) – Execute local shell commands with a user-approval flow before execution.
- **Attachment analysis** – Summarization/QA over attached files and images using the best available vision/chat model.
- **Image generation** – Simple image generation using a chat model and local decoding; images are stored as local files and appear as attachments.
- **Connected apps** – GitHub repository tools (read/write files, create branches/PRs, search code) and Google Drive file tools (list, read, upload, Sheets read/write), authenticated via user-provided tokens.
- **MCP server tools** – Any tools exposed by connected [MCP](https://modelcontextprotocol.io) servers (e.g. email via Zapier, calendar, Slack). Tools are discovered automatically via `tools/list`, cached locally, and executed via JSON-RPC over HTTP or SSE. Semantic tool selection uses embedding-based matching when many tools are available.

These tools are available both to the autonomous `AgentRunner` and to the interactive chat UI via the enhanced message composer.

### Tool calling by provider

| Provider | Tool calling method | Status |
|----------|-------------------|--------|
| **OpenAI** | Native function calling API | ✅ Fully supported |
| **Anthropic** | Native tool use API | ✅ Fully supported |
| **Google Gemini** | Native function declarations API | ✅ Fully supported |
| **Ollama** (local) | Text-based (JSON in system prompt) | ⚠️ Works, less reliable |
| **MLX** (on-device) | Text-based (JSON in system prompt) + pre-execution | ⚠️ Works, less reliable |
| **MCP servers** | JSON-RPC tool calls (HTTP/SSE) | ✅ Fully supported |

API providers (OpenAI, Anthropic, Gemini) use **native tool calling** — tool schemas are sent as structured function declarations and the model returns structured tool calls. This is reliable and well-supported.

Local models (Ollama, MLX) use **text-based tool calling** — tool definitions are embedded in the system prompt and the model is instructed to output raw JSON. A parser with several fallback strategies (code fence stripping, think-tag removal, brace matching) extracts tool calls from the response. A remapping layer corrects commonly hallucinated tool names (e.g. `python` → `shell.execute`). For local models, `ChatService` also supports **pre-execution**: before sending to the model, it checks the user's message for keyword matches against native tools (time, web search) and MCP tools (via fuzzy scoring), executes the matching tool eagerly, and injects the result into the prompt. This improves reliability significantly for simple single-tool queries.

**MCP tools** are discovered from connected MCP servers and made available to all providers. When many MCP tools are available, **semantic tool selection** via `MCPToolEmbeddingCache` ranks tools by cosine similarity to the user's query, reducing prompt size and improving accuracy. A built-in **benchmark suite** (`MCPToolCallingBenchmark`) lets you evaluate any local model's tool-calling accuracy across 10 test cases covering web, file, GitHub, shell, and Google Drive tool categories.

## Privacy and security

- All user data (chats, memories, settings, agent runs/steps) is stored **locally**.
- Provider keys are supplied by the user and never leave the device except in requests directly to the provider APIs.
- Sensitive fields are encrypted at rest using a key derived from a user passphrase; the passphrase itself is not stored.
- There is **no required custom backend**; you can run the client entirely against your own provider accounts.
- Analytics are opt-in only, anonymized via SHA-256 hashing, and contain no identifiable information.

See `docs/local-context-architecture.md` for more details on the encryption and key hierarchy.

## Docs

For a complete documentation index, see [`docs/README.md`](docs/README.md).

- `docs/local-context-architecture.md` – Local context sandwich, GRDB persistence, encryption, routing, and autonomous agents.
- `docs/tools-and-providers.md` – Provider keys, `LLMClient`/`ModelRouter` routing, the tools layer (web search, attachment analysis, file/image generation), and MCP server integration.
- `docs/TEST_COVERAGE.md` – Comprehensive test coverage documentation with 18 test files and 41 test methods across all layers.
- `docs/CODE_REVIEW.md` – Detailed code review findings and architectural recommendations.
- `docs/REVIEW_SUMMARY.md` – High-level summary of code quality, implementation status, and readiness assessment.
- `docs/ANALYTICS_PRIVACY.md` – Analytics privacy implementation and consent model.
- `docs/ANALYTICS_PRIVACY_AUDIT.md` – Detailed privacy audit confirming no identifiable information is sent.

## Running the app

### Requirements

- Xcode 16 or newer.
- iOS 17+ simulator or device, macOS 14+ for the Mac build.

### Steps

1. Clone the repo:
   ```bash
   git clone https://github.com/lepapillonterrible/aicoven-local-opensource.git
   cd aicoven-local-opensource
   ```
2. Open the Xcode project:
   ```bash
   open swift/AICoven/AICoven\ Local.xcodeproj
   ```
3. Select the `AICoven` scheme and your desired destination (iOS simulator or My Mac).
4. Set a unique bundle identifier and configure signing for your account if needed.
5. Build & run.
6. In the app, open Settings → Provider Keys and add your own API keys (e.g. OpenAI, Anthropic, Gemini). The app will then route LLM and embedding calls through those providers.

### Using MLX (On-Device Models)

AICoven can run models **directly on your device's GPU** using Apple's [MLX framework](https://github.com/ml-explore/mlx-swift) — no server, no API key, completely offline. Supported on Macs, iPads (M-series, 8 GB+ RAM), and iPhones (6 GB+ RAM, e.g. iPhone 15 Pro and newer).

1. In the app, go to **Settings → MLX Models** to browse the curated catalog.
2. Models are organized by category (General, Coding, Mobile) and tier (Core, Specialized).
3. Download a model — weights are fetched from HuggingFace and cached locally.
4. Select a model to make it active, or go to **Settings → Strix AI → MLX (On-Device)** to set it as your default provider.
5. On iPhone, only models suitable for constrained memory are shown (≤ 3 GB RAM or Mobile category).

**Curated model catalog:**

| Model | Size | Category | Recommended For |
|-------|------|----------|----------------|
| AICoven MCP 3B ⚡ | 3B, 4-bit | General (Core) | MCP Tools, Tool Calling, Agents |
| AICoven MCP 2B iOS 📱 | 2B, 4-bit | General (Core) | MCP Tools, iOS, On-Device |
| AICoven MCP 1.7B 🆕 | 1.7B, 4-bit | Mobile (Core) | MCP Tools, iOS, Tool Calling |
| Qwen 2.5 1.5B | 1.5B, 4-bit | Mobile (Core) | iOS, Low RAM |
| Qwen 3 4B | 4B, 4-bit | General (Core) | MCP Tools, Chat, Reasoning |
| Llama 3.2 3B | 3B, 4-bit | General (Core) | MCP Tools, Chat |
| Phi 4 Mini | 3.8B, 4-bit | General (Core) | Fast Inference, Reasoning |
| Gemma 3 4B | 4B, 4-bit | General (Core) | Multilingual, Chat |
| Qwen 2.5 Coder 7B | 7B, 4-bit | Coding (Specialized) | GitHub, Code, Debugging |
| DeepSeek R1 8B | 8B, 4-bit | Coding (Specialized) | Reasoning, Debugging |
| Mistral 7B v0.3 | 7B, 4-bit | General (Specialized) | Reasoning, Code |
| Gemma 2 2B | 2B, 4-bit | Mobile (Specialized) | iOS, Low RAM |

You can test any downloaded model's MCP tool-calling accuracy using the built-in benchmark (tap **Test** on a downloaded model card).

> **Note:** MLX models run on Apple Silicon only. On iPhone, local inference is highly resource-intensive. To prevent jetsam (out-of-memory crashes), models are automatically unloaded after each inference, GPU cache is hard-capped at 512MB, and context/tool output is capped more aggressively. Additionally, due to background MLX streaming, developers must ensure all UI streaming and state mutations are strictly isolated to the `@MainActor` to prevent complete UI freezing during response generation. Tool use with MLX models is functional but less reliable than with API providers; see the [tool calling table](#tool-calling-by-provider) above.

### Using Ollama (Local LLMs)

You can run models on your machine with [Ollama](https://ollama.com) — no API key or cloud account needed.

1. Install Ollama:
   ```bash
   brew install ollama
   ```
2. Start the server and pull a model:
   ```bash
   ollama serve          # leave running in a terminal
   ollama pull llama3.2  # or any model you prefer
   ```
3. In the app, go to **Settings → Strix AI** and select **Ollama (Local)** from the provider list.
4. Available models are discovered automatically from your running Ollama instance.
5. Start chatting! Requests go directly to Ollama on your machine; nothing leaves your network.

### Using MCP Servers

AICoven supports the [Model Context Protocol (MCP)](https://modelcontextprotocol.io), allowing you to connect external tool servers (e.g. Zapier, custom services) and use their tools directly from chat.

1. In the app, go to **Settings → Connected Apps → MCP Servers**.
2. Tap **Add Server** and enter the server URL and authentication details (Bearer token or API key).
3. The app will connect and discover available tools via `tools/list`.
4. Discovered tools are cached locally and automatically included in chat prompts.
5. When you ask the assistant to perform an action covered by an MCP tool, it will be executed via JSON-RPC.

**How MCP tool selection works:**

- For **cloud providers** (OpenAI, Anthropic, Gemini): MCP tools are injected as native function declarations alongside built-in tools. The model chooses which tool to call.
- For **local models** (MLX, Ollama): `ChatService` uses keyword matching and fuzzy scoring to pre-select the most relevant MCP tool before sending to the model. When many MCP tools are available, **semantic tool selection** via embedding-based cosine similarity narrows the candidate set.
- MCP tool results are injected into the context sandwich and truncated to fit device memory constraints (4 KB on iPhone, 8 KB on Mac/iPad).

**Supported transports:** SSE (`text/event-stream`) and Streamable HTTP.
**Authentication:** None, Bearer token, or API key.

### MLX vs. Ollama

- **MLX**: runs inference directly on your Apple Silicon GPU/CPU with no local HTTP server. Everything stays entirely on-device inside the app. Supports Mac, iPad (M-series), and iPhone (6 GB+ RAM).
- **Ollama**: runs a local HTTP server that manages models and serves requests at `http://localhost:11434`. AICoven connects to that server over localhost.

Use MLX if you want a fully in-process, Apple Silicon–optimized workflow, and Ollama if you prefer a local model server that can be shared across multiple tools.

> **Note:** Tool use with local models works but is less reliable than with API providers, especially for smaller models. See the [tool calling table](#tool-calling-by-provider) above.

## Development Workflow

### CI (GitHub Actions)

CI runs automatically on:
- **Pull requests** to `main` or `dev` branches
- **Pushes** to `main` or `dev` branches

The CI pipeline:
1. Runs SwiftFormat (check mode)
2. Runs SwiftLint (strict mode)
3. Builds the project (Debug, macOS)
4. Runs tests (if configured in the test plan)

### Pre-commit Hook (Local Testing)

To run linting checks automatically before each commit, set up the git hook:

```bash
./scripts/setup-hooks.sh
```

This installs a pre-commit hook that runs SwiftFormat and SwiftLint on staged Swift files. To skip the hook temporarily:

```bash
git commit --no-verify
```

### Full Lint/Build/Test

For a complete local check (matching CI):

```bash
./scripts/lint.sh
```

## Contributing

This project is licensed under the **PolyForm Noncommercial License 1.0.0** (see `LICENSE`). This means you may copy, modify, and distribute the software for **noncommercial purposes only**. Issues and PRs are welcome.

Good areas to contribute:

- Simplifying or removing remaining legacy cloud/covens/roles code.
- Improving the local context sandwich and memory retrieval.
- Adding new providers behind the `LLMClient` abstraction.
- Extending the tools layer (e.g. richer web browsing, local document indexing, additional file/image workflows).
- Enhancing the SwiftUI chat UI, especially around attachments and agent telemetry.

If you plan a larger contribution, please open an issue first to discuss direction and avoid duplicated work.
