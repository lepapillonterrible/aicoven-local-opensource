# AGENTS.md

This file provides guidance to AI coding agents working with code in this repository.

## 1. Overview

This repo contains an open-source, local-first Swift client for AICoven. The goal is:

- No dependency on a custom backend (no login, covens, or user accounts for end users).
- All persistent state (chats, documents, settings) is stored locally on-device.
- The app talks directly to LLM/embedding providers using user-supplied API keys.

The main app code lives under `swift/AICoven/AICoven`. There are also empty top-level `core/`, `features/`, and `infrastructure/` folders that are not currently wired into the build; focus on the `swift/` tree.

## 2. Common commands

### 2.1 Open the project in Xcode

```bash
open swift/AICoven/AICoven\ Local.xcodeproj
```

Most day-to-day development and running is done via Xcode (Cmd+R, Test navigator, etc.).

### 2.2 Build the app from the command line

The primary Xcode project is `swift/AICoven/AICoven Local.xcodeproj` with scheme `AICoven` and configurations `Debug`, `Release`, and `Staging`.

```bash
# Debug build for macOS
xcodebuild \
  -project "swift/AICoven/AICoven Local.xcodeproj" \
  -scheme AICoven \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

If you need to target a specific destination, add a `-destination` flag (e.g. an iOS simulator or Mac).

### 2.3 Run tests (XCTest)

The `AICovenTests` directory under `swift/AICoven` contains 18 test files with 41+ test methods covering LLM clients, services, infrastructure, integration scenarios, tooling, and UI smoke tests.

Example CLI test run:

```bash
xcodebuild \
  -project "swift/AICoven/AICoven Local.xcodeproj" \
  -scheme AICoven \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

### 2.4 Run a single test (example)

```bash
xcodebuild \
  -project "swift/AICoven/AICoven Local.xcodeproj" \
  -scheme AICoven \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:AICovenTests/MessageAdapterTests/testSanitizeContent_removesSquareBracketToolCallMarkup \
  test
```

### 2.5 Linting / formatting

A `.swiftlint.yml` configuration exists at the repo root. CI runs SwiftLint and SwiftFormat via `scripts/lint.sh`. Locally:

```bash
# Install tools (if not present)
brew install swiftlint swiftformat

# Run the lint script (format, lint, build, tests)
./scripts/lint.sh
```

## 3. High-level architecture

The Swift client is structured into a few main layers inside `swift/AICoven/AICoven`:

- `App/` – Application entry point and top-level composition.
- `Core/` – Domain models and local-only abstractions (LLM, storage, documents, tools, agents).
- `Features/` – User-facing features grouped by area (Chat, Settings, Documents).
- `Infrastructure/` – Cross-cutting concerns like design system, persistence, and keychain.
- `Services/` – Service layer including ChatService, StoreService, MemoryService, and some legacy services being refactored out.
- `Networking/` – Environment configuration (no backend URLs in the local-first client).
- `Views/`, `ViewModels/`, `Utils/`, `Extensions/` – Older layout still present for some screens and helpers; some of these are being moved into `Features/` and `Core/`.

### 3.1 App entry and navigation

**Key files:**

- `swift/AICoven/AICoven/App/AICovenApp.swift`
  - `@main` entry point for the multiplatform app (iOS + macOS).
  - Creates the root `WindowGroup` and shows `ContentView`.
  - Configures some global appearance (e.g., navigation bar title style).

- `swift/AICoven/AICoven/App/ContentView.swift`
  - Root SwiftUI view for the local-first client.
  - No login/auth routing; it always shows `HomeView()`.
  - Expects an `AppState` environment object for global state.

- `swift/AICoven/AICoven/Views/Main/HomeView.swift` and `Views/Main/MainTabView.swift`
  - `HomeView` encapsulates the main layout and likely embeds `MainTabView`.
  - `MainTabView` defines the primary tabs for the local client:
    - **Chat** (threads/conversations)
    - **Documents** (currently a placeholder view)
    - **Settings** (reusing `ProfileView` as a settings/profile area)

Agents making navigation changes should do so via these entry views rather than wiring new roots elsewhere.

### 3.2 Core layer (local-first abstractions)

**Location:** `swift/AICoven/AICoven/Core`

This is the local-first backbone intended to replace many backend-oriented services:

- `Core/LLM/`
  - Defines `LLMClient`, a provider-agnostic protocol for chat completions and embeddings.
  - `ToolEnvironment` inspects configured providers and derives per-provider capabilities.
  - Provider implementations for OpenAI, Anthropic, Gemini, OpenRouter (through the OpenAI client at OpenRouter's address), Ollama, and MLX (on-device via Apple Silicon).
  - **`OpenClawLLMClient`** – OpenAI-compatible self-hosted proxy client. Exposes `isLocalEndpoint` (checks `baseURL` against loopback/RFC1918 ranges) and adjusts timeouts (300s/600s for local, 60s/120s for cloud). `baseURL` is `internal` so `ChatService` can inspect it for `isLocalDeployment()` decisions.
  - **`HermesAgentClient`** – the Hermes agent's own API (`/v1/runs`): start a run, follow its events, answer what it asks to be allowed, stop it, read where it stands. Hermes is an agent, not a model: `ChatService.streamMessage` hands a turn whose provider is `hermes` to `Services/HermesTurn.swift`, which follows the run and reports it as the reply loop reports its own turns, so the status line, work trace, approvals and Stop are the same.
  - **`OpenClawGatewayConnection`** (`Core/LLM/Providers/OpenClawGateway.swift`) – one connection to an OpenClaw native Gateway over a web socket, protocol 4: the Gateway's challenge is answered with this device's identity (`OpenClawDeviceIdentity`, an Ed25519 key in the Keychain) and a signature over it; then requests get their answers by id and events arrive in the Gateway's order. An OpenClaw connection has a Gateway address only if the person gives one; without it the connection speaks the OpenAI chat API through `OpenClawLLMClient`. With one, OpenClaw is an agent like Hermes: `ChatService.streamMessage` hands a turn whose provider is `openclaw` to `Services/OpenClawTurn.swift`, which starts the run in the thread's session (`chat.send`), follows its `chat` events, asks the person about each `session.approval` through `ToolApprovals` (this once, or no) and stops the run (`chat.abort`) when the turn is stopped. A run the app was closed on is kept with its turn (`AgentRun`, with the Gateway it was started through) and picked up when its thread is opened: `OpenClawTurn.resume` reads where it stands (`agent.wait`, `chat.history`) and follows it from there.
  - `MLXLLMClient` runs models locally via Apple's MLX framework. Handles iOS memory pressure (model eviction after inference, GPU cache limits, `autoreleasepool` for generation). System messages are folded into the first user message for compatibility with strict chat templates (Gemma 2, Phi, etc.).
  - `MLXModelManager` manages a curated model catalog with category (`general`, `coding`, `mobile`), tier (`core`, `specialized`), recommended-for tags, and device-aware filtering (iPhones only see models ≤ 3 GB RAM or `.mobile` category).
  - `MCPToolCallingBenchmark` evaluates a local model's MCP tool-calling accuracy across 10 test cases (web, file, GitHub, shell, Google Drive). Results are persisted in `UserDefaults` and displayed in the MLX settings UI.
  - `MCPToolEmbeddingCache` caches embedding vectors for MCP tool descriptions, enabling semantic tool selection via cosine similarity when many tools are available.
  - `LLMConfiguration.makeEnvironment()` now registers the active MLX model as a `ModelDescriptor` so it participates in routing.

- `Core/Context/`
  - `ContextBuilder` assembles the layered context sandwich for each chat turn.
  - Composes system contract, runtime facts, policies, retrieved memories, thread history, and current message.
  - Supports device-aware `Limits`: `.mobile` (6 recent messages, 4 memories) for iPhones running local models where RAM is shared with MLX model weights.

- `Core/Routing/`
  - `HeuristicModelRouter` selects the best model per task based on capabilities, user preferences, and context requirements.
  - `findExact(providerID:modelID:)` prioritizes user-selected models from Strix settings before falling back to heuristic routing.
  - `ModelDescriptor` types define model capabilities (context length, tools support, quality tier).
  - Task types include `.chat`, `.summarize`, `.embed`, `.judge`, `.agentStep`, and `.mcpToolCalling` (prefers tool-capable models, falls back to cheapest).

- `Core/Agents/`
  - `AgentRunner` executes bounded multi-step autonomous runs.
  - `AgentProfile` describes agent types, allowed tools, memory scopes, and safety constraints.

- `Core/Tools/`
  - `ToolExecutionService` routes tool calls including shell commands, connected-app tools (GitHub, Google Drive), and MCP server tools. A tool that changes something (a shell command, a file write, a GitHub or Google write) first asks the person through `ToolApprovals`, which shows one approval at a time beside the thread (`Views/Chat/ApprovalBlock.swift`). An approval asked while the person is composing (the composer has focus and its text changed in the last three seconds, or the on-screen keyboard is up) is held back, and comes in when they send, pause, or leave the composer.

- `Features/MCP/`
  - `MCPClient` is an actor-based MCP (Model Context Protocol) client that connects to remote servers over HTTP/SSE, discovers tools via `tools/list`, and executes them via `tools/call` using JSON-RPC 2.0.
  - Supports Bearer token and API key authentication.
  - Handles both plain JSON and SSE (`text/event-stream`) response formats.

- `Features/ConnectedApps/`
  - `MCPServerAccount` represents a configured MCP server connection (URL, transport type, auth, cached tools).
  - `MCPServerManagementView` provides UI for adding, editing, testing, and removing MCP server connections.
  - `ConnectedAccountsService` manages MCP server persistence (UserDefaults) and Keychain storage for tokens.

**Note:** Model types are in `swift/AICoven/AICoven/Models/` (not in Core). Some legacy types (`User`, `Coven`, `WorkspaceTab`) from the original multi-tenant design remain but are not used in the local client.

**Note:** Persistence is handled by repository actors in `Infrastructure/Persistence/` (not via Core/Storage protocols). Current implementation uses concrete GRDB-backed repositories: `ThreadRepository`, `MemoryRepository`, `ProviderAccountRepository`, `SettingsRepository`, `AgentRunRepository`.

### 3.3 Features layer

**Location:** `swift/AICoven/AICoven/Features`

Feature modules are being extracted from the older `Views/` structure into this directory:

- `Features/Chat/Chat` and `Features/Chat/Threads`
  - Chat and thread list UI, migrated from `Views/Chat` and `Views/Threads`.
  - Still rely on existing services (`ChatService`, `ThreadService`, etc.) rather than directly on `LLMClient`/`ThreadStore`; this is a good place to focus refactors when moving fully to the local abstractions.

- `Features/Settings/Settings` and `Features/Settings/Profile`
  - Settings/profile screens, including provider keys and usage/budget UI from the original app.
  - These should be gradually updated to use `SettingsStore` for non-secret prefs and `SecretsStore` (see below) for API keys, instead of backend-driven provider account services.

- `Features/Documents`
  - Currently empty. Use this for new document-related views (list, detail, import flows) when implementing true local document support.

### 3.4 Infrastructure layer

**Location:** `swift/AICoven/AICoven/Infrastructure`

This layer holds cross-cutting technical concerns:

- `Infrastructure/Persistence/`
  - `DatabaseManager` manages the SQLite database via GRDB (DatabasePool).
  - Repository actors (`ThreadRepository`, `MemoryRepository`, `ProviderAccountRepository`, `SettingsRepository`, `AgentRunRepository`) provide typed access to encrypted data.
  - All sensitive data is encrypted at rest using `DataEncryptionService`.

- `Infrastructure/Security/`
  - `DataEncryptionService` implements passphrase-based encryption using a key hierarchy (user passphrase → `K_wrap` → `K_data`).
  - Handles AES-GCM encryption/decryption of database fields.

- `Infrastructure/Keychain/`
  - `SecretsStore` protocol with `KeychainSecretsStore` implementation.
  - Securely stores API keys and encryption metadata using the system Keychain.

- `Infrastructure/Attachments/`
  - `AttachmentStore` keeps the files attached to messages on the device: a file is copied in when it is attached (at most 10 MB), encrypted with the account's data key in the app's own folder, with a row in `attachments` saying whose it is, its thread, and, once sent, its message. It goes when taken out of the composer unsent, with its thread, and with its account. `AttachmentImage` writes a still picture out afresh as it comes in: upright, without location or camera data, at most 4096 pixels on its longest edge (a picture that moves is kept as it is). A message keeps what shows its attachments in its metadata (`file_attachments`); `Views/Chat/MessageAttachmentsView.swift` shows them in the thread, pictures as thumbnails, and `Services/AttachmentPreviewPresenter.swift` opens one in Quick Look from a file that exists only while it is looked at. `Services/AttachmentContext.swift` reads what a turn is told of its message's attachments, put after the message as the cloud app puts it (`[Attachment: <name>]` and then the text): text between fences, a PDF's text (PDFKit), at most 20,000 characters of each (8,000 for a model on this device or this network), and a note for a picture, a PDF without text, and any other file. A model's turn, a Hermes run and an OpenClaw run are all given it. A model that can see pictures (`ModelDescriptor.takesImages`: Anthropic's and Google's chat models, OpenAI's but for its text-only ones (ids starting `gpt-3.5`, `o1-mini`, `o1-preview` or `o3-mini`), and an OpenRouter model whose catalog entry lists `image` among its `input_modalities`; no model on Ollama, MLX, OpenClaw or an OpenAI-compatible server) is sent a message's pictures with it instead of the note: `AttachmentImage.forModel` writes each as an upright JPEG with nothing written into it, on white where it could be seen through, at most 4096 pixels on its longest edge and 3.5 MB; `LLMMessage.images` carries them, and the OpenAI (also OpenRouter), Anthropic and Gemini clients send them after the text. Other models, and Hermes and OpenClaw runs, are told of a picture by name.

- `Infrastructure/Tools/`
  - `ToolService` provides provider-agnostic tools (time, web search, attachment analysis, file/image generation).
  - All tools work with user-configured provider keys only; no custom backend required.

- `Infrastructure/Design/`
  - `DesignSystem` defines centralized colors, typography, and reusable styling primitives.

- `Infrastructure/Networking/`
  - Environment/networking configuration inherited from the original app.
  - In the local-only client, networking is limited to calls to external LLM/embedding providers and DuckDuckGo web search. No custom backend URLs are configured.

### 3.5 Services layer (mixed; partially legacy)

**Location:** `swift/AICoven/AICoven/Services`

This directory contains a mix of active and legacy services:

**Active services:**
- `AppState.swift` – Shared application state (threads, selection, global actions), injected into the view hierarchy.
- `ChatService.swift` – Encapsulates chat/thread operations using `LLMClient` and repositories. User-preference-first model selection via `resolveProviderAndModel()` + `findExact`. For local models, supports pre-execution of native and MCP tools based on keyword/fuzzy matching before sending to the model. Applies device-aware memory limits on iPhone (tighter context, tool context truncation, skips background summaries when only local models are available). `isLocalDeployment(providerID:)` inspects the active client's `baseURL` to determine if OpenClaw or an OpenAI-compatible server is pointing at a local server vs. cloud.
- `ChatEventBus.swift` – Lightweight `AsyncStream`-based event bus for broadcasting post-turn events (`.memoryProposalsReady`, `.threadNeedsSummary`) to background actors without blocking the chat path.
- `BackgroundMemoryService.swift` – Background `actor` that subscribes to `.memoryProposalsReady` events and persists memory proposals via `MemoryService`. Started at app launch; never blocks interactive chat.
- `BackgroundSummarizationService.swift` – Background `actor` that subscribes to `.threadNeedsSummary` events and runs thread summarization using its own independent LLM environment. Skips on iOS when only local models are available.
- `ThreadService.swift` – Thread CRUD and listing.
- `MessageAdapter.swift` – Transforms between internal message models and LLM request/response formats.
- `MemoryService.swift` – Manages context memory storage and retrieval.
- `ProviderAccountService.swift` – Manages provider configurations and API keys.
- `StoreService.swift` – StoreKit 2 in-app purchase management.
- `StrixSettingsService.swift` – Reads/writes user preferences for model and provider selection.
- `LLMClients.swift` – Concrete `LLMClient` implementations (OpenAI, Anthropic, Gemini, Ollama).
- `AnalyticsService.swift` – Privacy-preserving, opt-in-only analytics.

**Legacy cloud services (being refactored):**
- `CovenService.swift`, `RoleService.swift`, `RoleTemplateService.swift` – Multi-user covens and roles from the original backend system. These make API calls that will fail in the local-only client.
- `AuthService.swift` – Authentication stub with no-op methods.
- `FileUploadService.swift` – An unimplemented file upload service referencing non-existent backend endpoints. Attached files are kept by `Infrastructure/Attachments/AttachmentStore`.
- `EncryptionService.swift` – Legacy encryption service; being replaced by `Infrastructure/Security/DataEncryptionService.swift`.

**Note:** When adding new functionality, prefer working against `Core/LLM`, `Core/Context`, `Core/Routing`, and `Infrastructure/*` instead of extending legacy services. The services listed under "Legacy cloud services" should not be used in new code.

### 3.6 Views, ViewModels, and older structure

**Location:** `swift/AICoven/AICoven/Views`, `swift/AICoven/AICoven/ViewModels`

These directories contain the original view hierarchy and (minimal) view-model representation:

- `Views/Main/*` – Shell around the main layout (home, workspace, splash, etc.).
- `Views/Chat/MessageComposer.swift` – the one composer on the Mac, the iPad and the iPhone: `(+) field (Send | Stop)` in one box, with who the message goes to under the field. The field stays open while a turn runs, and a message sent then waits for the turn: `TurnEngine` keeps the thread's waiting messages (`waiting`, in memory), sends the first when the turn completes, and hands them back to the composer (`returned`) when it is stopped or fails; `Views/Chat/WaitingMessageBubble.swift` shows them in the thread with Edit and Remove. What the composer holds unsent is its thread's draft: `Services/ComposerDrafts.swift` keeps each thread's text and attachments while the app runs and saves the text, encrypted, with the thread (`threads.draft_ciphertext`), at most once every 0.8 s while it changes and at once when the app or the thread leaves the screen. The (+) is a menu: Take Photo (iPhone and iPad with a camera), Photo Library (the system's picker, at most 10 at once) and Choose File…; on the Mac, files and pictures pasted or dropped into the field are attached too (`ChatTextView.attachables(on:)`: files, or a picture's bytes where the pasteboard holds no text). All of them go into `AttachmentStore` like a chosen file. `ComposerRules` holds what it decides (which button the slot is, whether Send sends, @mention suggestions), apart from how it is drawn. On the Mac the field is `Views/Chat/GrowingTextEditor.swift`, an AppKit text view (Return sends, Shift+Return starts a new line).
- `Views/Auth/*` – Login/signup/password reset UI. These are no longer used by `ContentView` in the local-first client but remain in the tree for compatibility; safe to remove or repurpose once no code references them.
- `Views/Covens/*`, `Views/Roles/*`, `Views/Memory/*`, `Views/Components/*`, `Views/Common/*` – UI for covens, roles, memory browsing, shared components, etc.
- `Views/Store/*` – StoreKit purchase UI (`StoreView`).
- `Views/Settings/*` – Settings, tutorials, and provider key configuration views.
- `ViewModels/UsageViewModel.swift` – A view model for usage/budget views, tied to legacy usage services.

New UI should typically live under `Features/*` and use `Core` + `Infrastructure` rather than adding to these older folders.

### 3.7 Tests

**Location:** `swift/AICoven/AICovenTests/`

The test suite includes 18 test files with 41+ test methods covering:

- **LLM Client Integration** – Tests for OpenAI, Anthropic, and Gemini API clients (`OpenAILLMClientTests`, `AnthropicLLMClientTests`, `GeminiLLMClientTests`)
- **Services Layer** – Tests for ChatService, ThreadService, MemoryService, and error handling (`ChatServiceSummaryTests`, `ThreadServiceTests`, `MemoryServiceTests`, `ErrorReportingTests`, `PricingUpdateServiceErrorTests`)
- **Infrastructure** – Tests for encryption, persistence, and utilities (`DataEncryptionServiceTests`, `AnyJSONValueTests`, `AppStateTests`)
- **Integration Tests** – End-to-end tests with real database and encryption (`PersistenceIntegrationTests`, `MemoryServiceIntegrationTests`, `ChatAndAgentIntegrationTests`)
- **Tooling** – Tests for tool execution and message processing (`ChatToolingTests`, `AgentRunnerToolingTests`, `MessageAdapterTests`)
- **UI** – Basic smoke tests for view initialization (`SwiftUIViewTests`)

**Test Coverage:** ~25% overall. See `docs/TEST_COVERAGE.md` for comprehensive coverage analysis.

**Running Tests:**
- Xcode Test Navigator (Cmd+6) for individual tests
- Cmd+U to run all tests
- Command-line via xcodebuild (see section 2.3 for CLI examples)

## 4. Notes for future agents

- The README at repo root describes the overall goal of this repo as a local-only, open-source Swift client. Trust the `swift/AICoven/AICoven` tree and this file for the up-to-date architecture.
- Covens and roles are being reintegrated into the local client. Some backend-related types (remote memory, provider accounts) remain in the tree from the original cloud app. Prefer the newer `Core/LLM`, `Core/Context`, and `Infrastructure/*` abstractions for new features.
- Premium features (shell, GitHub, Google Drive tools) require in-app purchases via StoreKit 2. The Store UI is shown for all builds.
- When in doubt about where a new feature belongs:
  - Domain logic and persistence interfaces → `Core/`.
  - User-facing screens → `Features/`.
  - Cross-cutting technical concerns (keychain, design system, provider-specific networking) → `Infrastructure/`.
