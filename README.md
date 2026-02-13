# AICoven Local (Open Source Swift Client)

AICoven Local is a Swift client that lets you run an AI assistant with **no dependency on a custom backend**. All app state (chats, documents, settings) is stored locally on your device. The only network calls are directly to the model providers you configure (e.g. OpenAI, Anthropic, Gemini) using your own API keys — or to a **local LLM server** like [Ollama](https://ollama.com) running on your machine.

For the cloud version of the app go to https://aicoven.ai/

## Goals

- **No backend required**: everything happens on device. The only API calls are made to AI model providers.
- **Local-first data**: chats, documents, and settings live on-device.
- **User-provided API keys**: you bring your own keys for LLM/embedding providers.
- **Local LLM support**: run models directly on your Mac via [MLX](https://github.com/ml-explore/mlx-swift) (on-device, no server needed) or via [Ollama](https://ollama.com) — no API key needed for either.
- **Simple default assistant**: a single configurable assistant that "just works" out of the box.

## Current status

This repo started as an extraction of the original multi-tenant AICoven app and is being reshaped into a **standalone, local-first client**. The current codebase already includes:

- A provider-agnostic `LLMClient` + `ModelRouter` used for all LLM calls, supporting OpenAI, Anthropic, Google Gemini, Ollama, and on-device MLX models.
- Encrypted local context storage (threads, memories, settings) backed by SQLite/GRDB.
- A "context sandwich" builder that composes system contract, policies, time, memories, history, and the current turn.
- A tools layer (`ToolEnvironment` + `ToolService`) that exposes web search, file/image analysis, and local file/image generation using only your provider keys.
- Shell command tools with an approval flow, and connected-app integrations (GitHub, Google Drive).
- StoreKit 2 in-app purchase support with a community edition compile flag.

Some files from the original cloud app remain in the codebase (e.g. covens, roles, remote memory services). Covens and roles are actively being reintegrated into the local client. These features are **not** required to use the basic local assistant.

### Community Edition

When the `COMMUNITY_EDITION` Swift active compilation condition is set (it is enabled by default in the current build settings), all billing gates are bypassed and every feature is fully unlocked. This makes the open-source build a self-contained, feature-complete client.

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
- Native tool calling for API providers (OpenAI, Anthropic, Gemini) with text-based fallback for local models
- StoreKit 2 in-app purchases with community edition bypass
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

These tools are available both to the autonomous `AgentRunner` and to the interactive chat UI via the enhanced message composer.

### Tool calling by provider

| Provider | Tool calling method | Status |
|----------|-------------------|--------|
| **OpenAI** | Native function calling API | ✅ Fully supported |
| **Anthropic** | Native tool use API | ✅ Fully supported |
| **Google Gemini** | Native function declarations API | ✅ Fully supported |
| **Ollama** (local) | Text-based (JSON in system prompt) | ⚠️ Needs improvement |
| **MLX** (on-device) | Text-based (JSON in system prompt) | ⚠️ Needs improvement |

API providers (OpenAI, Anthropic, Gemini) use **native tool calling** — tool schemas are sent as structured function declarations and the model returns structured tool calls. This is reliable and well-supported.

Local models (Ollama, MLX) use **text-based tool calling** — tool definitions are embedded in the system prompt and the model is instructed to output raw JSON. A parser with several fallback strategies (code fence stripping, think-tag removal, brace matching) extracts tool calls from the response. A remapping layer corrects commonly hallucinated tool names (e.g. `python` → `shell.execute`). **This approach works but is less reliable than native tool calling**, especially with smaller models (4B-7B). Contributions to improve local model tool use are very welcome.

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
- `docs/tools-and-providers.md` – Provider keys, `LLMClient`/`ModelRouter` routing, and the tools layer (web search, attachment analysis, file/image generation).
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

AICoven can run models **directly on your Mac's GPU** using Apple's [MLX framework](https://github.com/ml-explore/mlx-swift) — no server, no API key, completely offline.

1. In the app, open a chat with a role configured to use an MLX model.
2. On first use, the model weights are automatically downloaded from HuggingFace.
3. Subsequent loads are instant from the local cache.

Tested models include:
- `mlx-community/Mistral-7B-Instruct-v0.3-4bit`
- `mlx-community/Qwen3-4B-4bit`
- Any [mlx-community](https://huggingface.co/mlx-community) 4-bit quantized model

> **Note:** MLX models run on Apple Silicon only. Performance depends on your Mac's unified memory — 7B models need ~4 GB, larger models need more. Tool use with MLX models is functional but less reliable than with API providers; see the [tool calling table](#tool-calling-by-provider) above.

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
3. In the app, go to **Settings → Provider Keys → Add Provider Key**.
4. Select **Ollama (Local)**, enter the server URL (default `http://localhost:11434`), and tap **Connect**.
5. The app will discover available models automatically — select one and tap **Add Ollama**.
6. Start chatting! Requests go directly to Ollama on your machine; nothing leaves your network.

### Using MLX (On-Device, Apple Silicon)

AICoven Local also supports running models directly on-device using [MLX](https://github.com/ml-explore/mlx) on Apple Silicon.

**Hardware requirements**

- macOS on Apple Silicon (M1 or newer) is required.
- For a smooth experience, at least **16 GB RAM** is recommended for medium/large models.

**Expected model sizes & memory usage**

- Small models (e.g. 3–4B parameters): typically **2–4 GB** downloads; expect **4–8 GB** of free RAM.
- Medium models (e.g. 7–8B parameters): typically **4–8 GB** downloads; expect **8–16 GB** of free RAM.
- Larger models may require more disk space and RAM; choose a size appropriate for your machine.

**Adding an MLX provider in the app**

1. Ensure you have an Apple Silicon Mac (M1 or newer) and that MLX models/tools are installed according to the MLX project’s instructions.
2. Open the app and go to **Settings → Provider Keys → Add Provider Key**.
3. Select **MLX (On-Device)** from the provider list.
4. Configure the model or path options as prompted, then tap **Connect**.
5. Once connected, select your preferred MLX model in the app and start chatting.

**MLX vs. Ollama**

- **MLX**: runs inference directly on your Apple Silicon GPU/CPU with no local HTTP server. Everything stays entirely on-device inside the app.
- **Ollama**: runs a local HTTP server that manages models and serves requests at `http://localhost:11434`. AICoven Local connects to that server over localhost.

Use MLX if you want a fully in-process, Apple Silicon–optimized workflow, and Ollama if you prefer a local model server that can be shared across multiple tools.
> **Note:** Tool use with Ollama models works but is less reliable than with API providers, especially for smaller models. See the [tool calling table](#tool-calling-by-provider) above.

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
