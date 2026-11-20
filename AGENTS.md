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
  - Shows the sign-in, onboarding and unlock screens as needed, then the main view: `HomeView()` on the Mac, `MobileRootView()` on the iPhone and iPad.
  - Expects an `AppState` environment object for global state.

- `swift/AICoven/AICoven/Views/Main/HomeView.swift` (Mac only)
  - The Mac's main window: it shows the shell (`MacShellView`, one split view as the cloud app's; see 3.6), opens the Settings window when asked (`AppState.settingsRequests`), and sends each deep link to its place in Settings.
- `swift/AICoven/AICoven/Views/Main/MobileHomeView.swift`
  - Holds `MobileRootView`, the iPhone's and iPad's main view: the Chats and Settings tabs.

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
  - `ToolExecutionService` routes tool calls including shell commands, connected-app tools (GitHub, Google Drive), and MCP server tools. A tool that changes something (a shell command, a file write, a GitHub or Google write, or a tool of an MCP server that the server does not mark as read-only) first asks the person through `ToolApprovals`, which shows one approval at a time beside the thread (`Views/Chat/ApprovalBlock.swift`). An approval asked while the person is composing (the composer has focus and its text changed in the last three seconds, or the on-screen keyboard is up) is held back, and comes in when they send, pause, or leave the composer.

  - The GitHub tools (`github.listRepos`, `getRepo`, `readFile`, `listFiles`, `searchCode`, `getPullRequest`, `listPullRequestFiles`, and the writing `writeFile`, `createBranch`, `createPR`) are named as the cloud app names them (`github.listRepos` is this app's own) and name a repository as it does: one argument, `repo: "owner/name"` (`GitHubToolArguments.repository(in:)`, which also takes `owner` and `repo` apart, and refuses what does not read as a repository). `github.getPR` and `github.listPRFiles` are old names of `getPullRequest` and `listPullRequestFiles` (`ToolNames.renamed`): `ToolExecutionService.execute` takes a call by an old name as a call of the tool as it is named now, so it is allowed and refused as that one. `GitHubToolService` builds a request's path from steps (`path(of:)`), each written so that it stays one step: a file path or branch name from a model cannot add a query, reach another part of GitHub's API, or climb out with `..` (such a path is not sent). The writing tools take the cloud app's arguments too (`commit_message`, `base_ref`, `new_branch`; this app's older `message` and `base_branch` are still read). `github.writeFile` looks up the sha of the file at its path when the call names none (`GitHubToolService.shaOfFile`), before the person is asked, so the approval says whether a file is replaced; a path or branch name that would not be sent is refused before anything is looked up or asked. The chat loop tells one call of a tool from another by all of its arguments, exactly as given (`ChatService.repeatSignature`; a call of a query alone is told by its query, loosely read), so a second page is not taken for a repeat of the first.

  - The Google tools are of one connection (`google_drive`): `google_drive.listFiles` (each file with its id), `google_drive.readFile` (a Doc, Sheet or Slides file exported as text, any other file read as it is), `google_docs.read` and `google_slides.read` (title and text, taken out of the API's answer by `GoogleWorkspaceText`), `google_sheets.read` (title, and each sheet with its size) and `google_sheets.readValues`, and the writing ones: `google_drive.uploadFile`, `google_sheets.updateValues` (cells, each as it was given: text, a number, true or false; `google_sheets.writeValues` is its old name, taken as this one by `ToolNames`), `google_docs.update` (text added at the end or at a position, or Docs API requests), `google_sheets.batchUpdate` and `google_slides.update` (the API's own requests). Each asks the person first and shows what will be sent: the cells, the text, or the requests as JSON (`ToolApproval.sheetsWrite`, `docsAddText`, `googleRequests`). A new writing tool must be added to `CovenConnectionRules.writeTools`, or a coven that lets Google only be read is not kept from it. A list a model gives (`values`, `requests`) may come as JSON in text, whole or thing by thing, and is read as what it says (`GoogleToolArguments.rows`, `requests`): Gemini is told every list holds text (`GeminiLLMClient`). The OpenAI, Anthropic and Gemini clients each give a call back under the name its tool was declared with, keeping the name's own underscores. A file, document, spreadsheet or presentation is named by its id, which must read as one (`GoogleToolArguments.isID`: 1 to 200 letters, digits, `-`, `_`). `GoogleDriveToolService` writes every address that holds an id or a range from steps (`address(_:_:verb:)`, with `RequestPath`, which `GitHubToolService` uses too), so an id or a range from a model stays one step of the path (the upload address holds neither and is a constant). The text of a Drive file, a document or a presentation is cut at 20,000 characters when it is told to a model (a range's values and a spreadsheet's list of sheets are not cut). A Drive file larger than an attachment may be (10 MB) is not fetched. A new tool prefix must be added to `CovenConnectionRules.app(of:)` and to `ToolExecutionService.toolsPackPrefixes`, or the tool escapes the coven's rule and the Tools Pack check; and to `ChatService.friendlyToolName` and `friendlyToolSummary`, which name a tool for the person.

  - `CovenConnections` (kept in a coven's settings) says which of the person's connections the coven's agents may use: each connected app (`github`, `google_drive`) and each MCP server that is on, to read only or to read and make changes. `CovenConnectionRules` holds what follows, as the cloud app has it: a connection that is not on is not used; a connected app on to read gives every tool but the fixed writing ones; an MCP server on to read gives only the tools it marks as read-only. A turn is offered only what its thread's coven lets (`ToolConfig.connected(connections:)`, `mlxTools(connections:)`), and `ToolExecutionService` refuses the rest whatever was offered. A personal thread (an agent run's own thread included), and a coven that has made no choice, use everything connected. If a thread, its coven or the coven's choice cannot be read (the data locked, settings that are not settings), or the account changes while they are read, nothing connected is used. The choice is read from what is stored (`ThreadRepository.covenID(ofThread:for:)`, `CovenRepository.connections(ofCoven:for:)`), not from the thread list, and looked at again after an approval. A coven's Connections screen sets it (`Features/ConnectedApps/CovenConnectionsView.swift`, with `CovenConnectionsModel` holding what it decides; opened from the sidebar on the Mac and from the coven's list on the iPhone and iPad): each connected app and MCP server on or off, and one that is on to read or to read and make changes; turned on, it starts on Read. A new coven starts with nothing on. A coven made before there was a choice shows what it was using, and its first change keeps the rest.

- `Features/MCP/`
  - `MCPClient` is an actor-based MCP (Model Context Protocol) client over Streamable HTTP: it lists a server's tools (`tools/list`, every page) and calls them (`tools/call`), in JSON-RPC 2.0.
  - It speaks the current revision of the protocol (2026-07-28: no handshake; every request carries its version in `_meta` and in `MCP-Protocol-Version`, with `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*` headers) and falls back to the earlier ones (`initialize`, `notifications/initialized`, `Mcp-Session-Id`, a lost session started anew once). It asks a server which it speaks once (`server/discover`) and remembers for the app's run (`MCPEraCache`). The deprecated HTTP+SSE transport is not spoken; a server's transport setting is not used.
  - Answers come as JSON or as a stream of events, read up to the answer to the request. A tool's own error (`isError`) is told to the model as such. Of each tool it keeps the name, description, input schema and whether the server marks it read-only (`readOnlyHint`).
  - Supports Bearer token and API key authentication.

- `Features/ConnectedApps/`
  - `MCPServerAccount` represents a configured MCP server connection (URL, transport type, auth, cached tools).
  - `MCPServerManagementView` provides UI for adding, editing, testing, and removing MCP server connections.
  - Figma is a connected app (`ConnectedAppProvider.figma`) connected with a personal access token, as the cloud app offers, because signing in with Figma needs a secret a server holds. `Features/ConnectedApps/AppTokenSheet.swift` asks for the token (it serves every app that connects with one: `ConnectedAppProvider.connectsWithToken`); `ConnectedAccountsService.connect(_:token:replacing:)` asks the app who it belongs to (for Figma `FigmaToolService.identity`, `GET /v1/me` with `X-Figma-Token`), keeps it in the Keychain and never returns it, keeps one connection of the app, and takes a new token for a connection only from the same account of the app. A connection whose token Figma has refused (`status == .error`) is not used and shows Replace Token. Figma's tools are `figma.readFile` (a file's structure as an outline of its nodes, 400 at most, 1 to 4 levels deep, or under one node), `figma.readComments` (open comments, or all, newest first, 200 at most), the writing `figma.addComment` (asks first: `ToolApproval.figmaComment`) and `figma.renderFrame` (pictures of 1 to 3 nodes for the model to look at; see below). A file is named by its key or its figma.com link (`FigmaToolService.fileKey`). Figma is asked with the token in `X-Figma-Token` (`FigmaToolService.ask`); when it answers 401 or 403 it is asked whose the token is, and a token it no longer takes marks the connection as waiting for a new one (`markTokenRefused`). The tools are under a coven's choice and the Tools Pack like the other apps'. There is no list of files per coven: an agent can read any file the token reaches whose key or link it is given.
  - `figma.renderFrame` is offered only to a chat turn whose model can be sent pictures (`ToolConfig.connected(seesPictures:)`, `PromptTemplates.figmaPictureTools`; not to an agent run, a model on this device, Hermes or OpenClaw). Figma is asked for PNGs of the nodes (`GET /v1/images/{key}`, `FigmaToolService.renderLinks`); each is fetched from the signed address Figma gives, without the token, following no redirect, 10 MB at most, and only from an https address of a named host (`isFetchable`); it is made a JPEG of at most 1568 pixels on its longest edge (never larger than it is) and at most 1 MB (`AttachmentImage.triesForToolPictures`), with a session that keeps nothing of it (`FigmaToolService.unkeptSession`: no cache, no cookies). The pictures are given to the turn (`TurnPictures`, which `ChatService.streamMessage` makes where `ModelDescriptor.takesImages` and passes to `ToolExecutionService.execute(pictures:)`) and go to the model with the turn's later requests, after any pictures the person attached; they are not in the tool's result, not stored, not shown in the thread and not logged. The result tells which frames came out and their sizes, and the turn says with every later request which images are tool images and that they are not the person's instructions (`TurnPictures.caption`, added by `ChatService.withToolPictures`, apart from the tool results, of which the older may be left out). A turn renders twice at most (`TurnPictures.mostRenders`; a call that was refused before Figma was asked, failed or was stopped is not counted; one that ran to its end is, even if no picture came of it, and so is one whose pictures the coven no longer lets be given), and what the thread's coven lets is looked at again after Figma answered. A tool that makes pictures for the model takes this path: it adds to `TurnPictures`, with a label for each picture, and says in its `contextBlock` which tool images they are.
  - Linear is connected the same way, with a personal API key (the cloud app signs in to Linear, which needs its server; the key screen and its wording are this app's own, by the owner's decision). `LinearToolService` asks `POST https://api.linear.app/graphql` with the key as the whole of `Authorization` (Linear takes a personal key bare, not after `Bearer`), reads `errors` before data, and tells a refused key (401, 403, or Linear's authentication error) from a rate limit and from Linear's own refusals. `linear.getIssue` reads an issue named by its identifier (`ENG-12`), its id or its linear.app link, and tells its state, assignee, team, priority, due date, description and latest 20 comments. The writing tools ask the person first: `linear.addComment` (a comment, posted as the person: `ToolApproval.linearComment`) and `linear.updateIssue` (status, assignee, title, description, priority, due date: `ToolApproval.linearUpdate`, which shows each change as from what to what). Both read the issue first, so the person is asked about it by name and the change goes to its id; a status and an assignee are given by name (an assignee also by email) and found among the issue's team's states and members (`LinearToolService.state(named:among:team:)`, `member(matching:among:team:)`; all pages of them, 20 at most), and one that is not there, or names two members, is told so before anyone is asked. Once the person has approved, the connection's key is read again (`linearKeyOnceApproved`): a connection removed meanwhile is not written through. A change whose answer did not come, could not be read, or said Linear's server failed is told as one that may have been made (`linear_unconfirmed`, not to be asked again without looking), and so is one whose request was stopped under way (`cancelled`, saying it may have been made); only Linear saying it did not (`success: false`, or an error of its own) is a refusal. An agent run is told a tool's failure as a chat turn is (`ToolExecutionResult.toldToAModel`). A refused key marks the connection as waiting for a new one, but only when Linear, asked whose the key is, refuses it there too (a refusal of one issue leaves the connection as it is). Linear's tools are under a coven's choice and the Tools Pack like the other apps'.
  - `ConnectedAccountsService` manages MCP server persistence (UserDefaults) and Keychain storage for tokens. What it holds in memory is one account's: when the signed-in account is another, that account's connections are read in its place. Every method first asks who is signed in, and the lists and Keychain names it uses are spelled from that account, so a connection begun as one account stays that account's. A method that changes something waits for nothing after asking; the two that must wait (refreshing a Google token, and asking Figma or Linear whose a pasted token is) ask again afterwards and keep the token only if the same account is still signed in and nothing else was done to the connection meanwhile.

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

- `Infrastructure/Voice/`
  - A voice message is put into words with whichever of the person's own keys can transcribe, and on the device where none can (the app supplies no key). `VoiceTranscription.transcribe(_:with:preferring:)` asks each `Transcriber` in turn: the key of the provider the message is going to first, then the other key, then the device (only the device with `onDeviceOnly`, for a message going to a model on this device or this network); one that fails is passed over, one that listened and heard no words ends the asking, and if none gives words what the first said is told (`Unheard`). `OpenAITranscriptionService` sends the recording as a file (`POST /v1/audio/transcriptions`, a form with `model` and `file`); with no model named, the key's models whose ids hold `transcribe` (not `tts`, `live`, `realtime`, `diarize`) are tried, those named without a date first, then `whisper-1`, four at most. `GoogleTranscriptionService` gives a Gemini model the recording and the cloud app's instruction (`POST v1beta/models/{model}:generateContent`, the key in `x-goog-api-key`); the key's models made to transcribe are tried, last by name first, then `gemini-flash-latest` if listed. `DeviceTranscriptionService` uses the system's speech recognition on the device only (`requiresOnDeviceRecognition`): the recording goes nowhere, and a language the device cannot recognise on its own is told so. A recording is at most 10 MB (`VoiceAudio.largest`). `NSSpeechRecognitionUsageDescription` is in both Info.plists.

  - `Services/VoiceCaptureService.swift` records a voice message as the cloud app does (AAC in an `.m4a` file in the temporary folder, 44.1 kHz, mono, 128 kbps), asking for the microphone the first time; a recording ends itself after nine minutes, under what is sent to be transcribed. `Services/VoiceMessages.swift` is a thread's voice messages: it records one for a thread and an account (`Destination`, the signed-in person), has it put into words by `ChatService.voiceRoute(roleID:)` (read as a turn reads it, after the same refresh of what is connected: the key of the turn's provider first; only the device where its model runs on this device or this network), removes the recording, and hands the words (`heard`) to the thread's view, which sends them as a message of their own like typed ones (`PersonalChatView.sendVoiceMessage`; they wait if a turn runs). Words are handed on, and sent, only while the account that said them is signed in; heard for a thread that has left the screen they are kept for it (`TurnEngine.keepUnsent`, which adds to what is kept) and not sent unseen. A recording shorter than half a second is not sent. In the composer the mic is between the field and Send (`(+) field (mic) (Send | Stop)`): held to talk on the iPhone and iPad (let go to send, moved 72 pt away to cancel), clicked to start and again to send on the Mac, where Esc cancels and Space held 0.3 s in the empty field talks too (`GrowingTextEditor.ChatTextView`; let go sooner, it types a space). While recording the field shows "Listening" and its hint, Send is off and Stop is not shown. `VoiceHoldToTalkPolicy` holds what these decide. `NSMicrophoneUsageDescription` is in both Info.plists and `com.apple.security.device.audio-input` in the Mac's entitlements.

- `Infrastructure/Tools/`
  - `ToolService` provides provider-agnostic tools (time, web search, attachment analysis, file generation).
  - A picture is made from a description with whichever of the person's own keys can make one (the app supplies none): `ImageGenerationService` with an OpenAI key (`POST /v1/images/generations`; with no model named, the key's image models are tried in the cloud app's order, four at most) and `GoogleImageGenerationService` with a Google key (`POST v1beta/models/{model}:generateContent` asking for an image, the key in `x-goog-api-key`; with no model named, the key's models whose names hold `image` and that take `generateContent` are tried, last by name first, four at most; the size is asked for as the nearest of `1:1`, `16:9`, `9:16`). The `image.generate` tool (`ToolExecutionService`) is offered to a chat turn where there is a key of either (`PromptTemplates.offeredImageTools`, `ToolConfig.connected(deliversFiles: true)`; an agent run, which gives no files to a reply, is not offered it). A call that names a provider (`provider`, or a model that says whose it is: `ImageProvider.ofModel`) is asked of that provider's key only; one that names none is asked of each key in turn (OpenAI's, then Google's: `ToolExecutionService.imageMakersWithTheStoredKeys`) until one makes it. It makes nothing unless the thread is the signed-in account's; what it makes is kept in `AttachmentStore`, told to the turn in `TurnState.generatedFiles`, marked as the reply's when the turn ends (`TurnProgress.keepingGeneratedFiles`) and shown with the reply like any attachment. The model is told the person has the image, not where it is.
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

- `Views/Main/*` – The main layout: the Mac's shell (`HomeView`, `MacShellView`, `ShellSidebar`, `ShellContentView`, `CovenSwitcherList`), the iPhone's and iPad's (`MobileRootView`, in `MobileHomeView.swift`), splash, etc. The chat itself is `Views/Chat/PersonalChatView.swift`, used by both.
- `Views/Chat/MessageComposer.swift` – the one composer on the Mac, the iPad and the iPhone: `(+) field (mic) (Send | Stop)` in one box, with who the message goes to under the field. The field stays open while a turn runs, and a message sent then waits for the turn: `TurnEngine` keeps the thread's waiting messages (`waiting`, in memory), sends the first when the turn completes, and hands them back to the composer (`returned`) when it is stopped or fails; `Views/Chat/WaitingMessageBubble.swift` shows them in the thread with Edit and Remove. What the composer holds unsent is its thread's draft: `Services/ComposerDrafts.swift` keeps each thread's text and attachments while the app runs and saves the text, encrypted, with the thread (`threads.draft_ciphertext`), at most once every 0.8 s while it changes and at once when the app or the thread leaves the screen. The (+) is a menu: Take Photo (iPhone and iPad with a camera), Photo Library (the system's picker, at most 10 at once) and Choose File…; on the Mac, files and pictures pasted or dropped into the field are attached too (`ChatTextView.attachables(on:)`: files, or a picture's bytes where the pasteboard holds no text). All of them go into `AttachmentStore` like a chosen file. `ComposerRules` holds what it decides (which button the slot is, whether Send sends, @mention suggestions), apart from how it is drawn. On the Mac the field is `Views/Chat/GrowingTextEditor.swift`, an AppKit text view (Return sends, Shift+Return starts a new line).
- Icons and faces, as the cloud app draws them: a coven's icon (`Views/Components/CovenIcon.swift`) and an agent's face (`Views/Components/AgentFace.swift`, with its provider's logo in a notch) are an SF Symbol on one of twelve tints (`Design/IconTint.swift`, `Views/Components/SymbolDisc.swift`; a symbol this system cannot draw is replaced by `house` or `cpu`). Both are kept in the settings JSON of the coven or the agent, under the cloud app's names (`icon_symbol`, `icon_tint`), and written without touching what else is stored there (`CovenRepository.setIcon(symbol:tint:forCoven:)`, `setIcon(symbol:tint:forRole:)`; replacing an agent's other settings keeps its face). A stored symbol must read as a symbol's name (`IconRules.isSymbolName`). A new coven starts with the first suggested symbol and tint no other coven shows (`CovenIcon.startingIcon`); a new agent with the symbol its emoji stands for (`AgentFace.symbol(forEmoji:)`, which also gives the face of an agent made when agents had only an emoji) on the first tint none of the coven's agents wears. `Views/Components/SymbolTintPicker.swift` chooses them (suggested symbols, or a search of `Design/SFSymbolCatalog.json` through `Utils/SymbolCatalog.swift`), opened by `IconChoice` in the two agent forms and the two sheets that make a coven (which wait for the starting icon before the coven can be made: `NewCovenIcon`). A new coven's or agent's starting icon, where none is chosen for it, is picked in the same write that makes it, so two made at once do not take the same one while one is still unused; an agent is made only in a coven of the account that asked, and changed only as that account. An agent's settings that cannot be read are not written over, by a new face or by the form that saves its other settings. An agent's emoji is no longer shown or edited anywhere; it stays as stored. Strix, which is no coven here, shows sparkles.
- Lists of threads (the Mac's sidebar, the iPhone's list) are ordered, sectioned and acted on in one way, as the cloud app's are. `Services/ThreadListRules.swift` holds the rules: newest first by when a thread was last used (its last message, else when it was made; the store reads each thread's last message time with the threads, `ThreadRepository.loadChatThreads`, and `ThreadService.noteMessage` keeps it as messages are stored and posts `ThreadService.threadUsed`, on which the lists read their threads again), those archived in a collapsible "Archived" section after the others, a row's title ("Untitled" for none) and its date (`VisitWords.rowDate`: the time today, the weekday within a week, then the day and month, with the year when it is another year). `Services/ThreadActions.swift` is what a list lets the person do with a thread, the same in every list: Rename… (`Views/Chat/RenameThreadSheet.swift`), Archive and Unarchive (archiving stops the turn running in the thread), Delete (after "Delete “<title>”?"), and Copy Thread as Markdown. A list owns one `ThreadActions`, hosts its sheet and alerts with `.threadActionsHost`, and gives each row `.threadRowActions` (the context menu, and on a touch list the Archive swipe); it is told to read its threads again (`onChanged`) and to close what showed a thread that was archived or deleted (`onLeft`). What could not be done is said ("Couldn't rename the thread", "Try again."), only to the account that asked. `Services/ThreadMarkdownExport.swift` writes a thread as the cloud app does: `# <title>`, then `## <who>` and what they said, for each message the person sent and each reply; the message that ends a turn that failed, was stopped or was cut off is left out (`ThreadRepository.messagesOfTurnsNotCompleted`). The whole thread is read, a page at a time (`ThreadMarkdownExport.allMessages`). A thread deleted while it was read is not copied (what was read may not be all of it), and deleting a thread calls off a copy of it under way. A list shows only the latest load it asked for, and only for the scope it is still showing. A thread renamed in the Mac's sidebar goes by its new name in the window's title too (`ShellNavigator.updateThread`). A thread's name is kept as `ThreadInputValidator` keeps a title (one line, single spaces, 120 characters at most), and `ThreadListRules.name(from:)` gives the same.
- A thread's row says what the thread is doing, as the cloud app's does. `Services/ConversationActivity.swift` holds the rule (`ConversationActivity.of`): the turn the engine runs in it (`.moving`, in the status line's words; `.waiting("Needs your OK")` while it waits to be allowed something, unless it is stopping), else how its latest turn stands (`.broken("Stopped on a problem")` for one that failed or that the app closed on; `.paused` for one an agent of the person's own was running when the app closed, which is followed again when the thread is opened), else `.unsent` (its composer holds something, or the engine handed a message back), else `.unread`; a turn outranks an unsent message, which outranks an unread reply, and the thread on screen has neither of the last two. The cloud app's "quiet" and "your Mac is asleep" need a server and are not here. Read marks are kept on the device: `threads.read_at` (v13) is when a thread was last on screen, and a thread is unread when a message that is not the person's own was stored after it (`ThreadMarks.isUnread`; a thread from before marks were kept is read up to when they began, and a new thread up to when it was made; a row with no mark at all counts as read). `ThreadRepository.threadMarks(for:)` reads, for each of an account's threads, its read mark, its last reply's time, whether a draft is kept with it, and its latest turn's status and whether that turn has an agent's run; none of it is content. `Services/ThreadActivities.swift` puts it together for the lists (`activity`, by thread id, and, for each scope, `current` and `scopesWithUnread`, of which `covensWithUnread` is the covens): it follows the engine's turns, endings and handed-back messages and the approvals asked, reads the marks again when a message is stored (`ThreadService.threadUsed`) and when a list loads, keeps only its latest reading and only for the account it was read for, and marks a thread read when it comes on screen (`show`, from `PersonalChatView`), when a message is stored while it is there, and when it leaves (`hide`). It says something only of the threads it read from the store for the signed-in account (what the engine holds is by thread, whoever's it is); a thread read here stays read when a reading of the store that began earlier lands; a thread it holds nothing of is read for when it is shown; `accountChanged()` (called where `AuthService` signs an account in or out) clears what is said at once and reads the store again. A reply in an archived thread marks its row, not its coven. Its logs say the kind of failure only. The lists put the threads still open first (`ThreadListRules.sections(_:isStillOpen:)`: everything but unread), each part newest first. `Views/Chat/ConversationActivityViews.swift` draws it: the mark at the start of the row (a turning ring, a still ring, the waiting mark, the unread dot; a row with none keeps its icon), the caption under the title (water for moving, rust for broken, semibold for waiting), `CovenUnreadDot` beside a coven that holds an unread reply, and what VoiceOver reads after the title (the caption, or "Unread").
- The Mac's window is the cloud app's shell: one split view (sidebar, content, toolbar), with no tabs. `HomeView` shows it, its state tied to the signed-in account. `Views/Main/MacShellView.swift` is its root: a `NavigationSplitView` with `ShellSidebar` (260 pt, 220 to 360) and `ShellContentView`, the stone toolbar (`Design/StoneChrome.swift`: `StoneSidebarToggle` with ⌃⌘S in place of the system's toggle, and New Thread; plain ink buttons with no glass plate, the bar in the chrome tone over a hairline), the window's title, and the one `ThreadActions` for the sidebar's threads, hosted here so its sheet and alerts show while the sidebar is hidden. New Thread makes a thread at once in Strix and opens it (unless the person has gone elsewhere meanwhile); in a coven it shows the sheet that asks for an agent (`NewThreadView`, shared with the iPhone: Create is offered by `NewThreadView.canCreate`, for a coven only once its agents have been read and with one chosen where there are any, and the creation asks again at its start, so a second click makes no second thread; each showing of the sheet opens only the thread it made, `NewThreadSheet`). `Services/ShellThreads.swift` reads the threads of the scope on screen: another scope's go at once, only the latest reading is shown and only for the scope still on screen, and a list already shown stays when reading it again fails (`ThreadListRules.keepsShownList`); it is read again when a message is stored, a thread is made, or one is renamed, archived or deleted. `Views/Main/ShellSidebar.swift` is a system sidebar list selecting through the navigator (`sidebarItem`): the switcher, the scope's Overview row and its places (Memory, Agents, Connections, as one row of icon buttons) pinned at the top, the row and the buttons drawn by hand and selected as the list draws a selected row (`SidebarSelection`), the threads with the cloud app's row (mark, title, date, caption; the marks and dates take the highlight's ink on a selected row), "Archived" as a section of its own, a search of the titles under the Threads header (`ThreadListRules.matching`, "No threads match."), and the person's row pinned at the bottom, which opens Settings. The switcher is a button naming the scope on screen, with up to two lines under it for other scopes where something moves or waits (`ShellSidebar.othersCurrent`, `OtherCovenCurrentLine`); it opens `Views/Main/CovenSwitcherList.swift` in a popover as wide as the button: Strix first, then the covens in the person's order, each with its icon, one line of what moves or waits there, an unread dot and a check on the one on screen, then "New Coven…" and the person's row. A coven is moved by dragging it onto another row or with Move Up and Move Down in its context menu (and for VoiceOver); Strix does not move and nothing moves above it. `MacShellView` reads the covens (only its latest reading is kept, and only the signed-in account's) and keeps the order (`CovenOrderStore`, saved for the signed-in account when a coven is moved; `AuthService.deleteAccount` removes it). `ThreadActivities` says, for each scope, what moves or waits there in one line (`current`, from `ConversationActivity.current(of:)`: what waits for the person first, else the one thing moving, else "2 moving") and which scopes hold an unread reply (`scopesWithUnread`, Strix among them; `covensWithUnread` is the covens of those), from where each thread that is not archived belongs (`ThreadService.scopesOfThreads()`). `ShellContentView` shows the place open in the scope on screen: a thread (`PersonalChatView` with `showsHeader: false`, since the window's title names it; its actions are a "Thread Actions" menu in the toolbar: Copy Thread as Markdown, Rename…, Archive or Unarchive, Delete…, through the shell's `ThreadActions`); the memory (`MemoryListView`, whose add and edit forms open in a sheet over it, `MemoryForm`, the list read again when one has saved); a coven's agents (`Views/Roles/CovenAgentsView.swift`, as the cloud app lists them: Add Agent, then a row for each with its face, name, the first line of its instructions and its model; a row opens the existing form in a sheet, `ShellFormSheet`, with Cancel; each showing of a form is its own, `AgentForm` and `MemoryForm`, so one that saves late closes only its own sheet; an agent is deleted only as its owner, `RoleService.deleteRole(roleId:as:)`; the context menu has "New Thread with <name>", Edit… and Delete…, which asks first); Strix's own settings as Strix's Agents place; a coven's connections (`CovenConnectionsView`; Strix uses every connection, so its Connections button opens Settings); or, until the Overview is built, what the window showed for a scope with nothing open. The model: `Coordinators/ShellNavigator.swift` says where the shell is: the scope on screen (`ShellScope`: `.strix`, the person's own space, which is no stored coven here, or `.coven(id)`) and each scope's place (a `WorkspaceTab`; none is the scope's Overview). It starts on Strix's Overview; switching to another scope shows that scope's Overview even where a thread was open in it earlier (`select`), a thread opens in the scope it belongs to (`open(_: Thread)`), a sidebar row opens its place in the scope on screen (`openPlace`: Memory, Agents, Connections; Strix's Agents place is Strix's own settings and Strix has no Connections place), a finished form closes to the place it was reached from (`close`: an agent's form to the agents, a memory's form or the proposals to the memory), a renamed thread keeps its place (`updateThread`), a deleted or archived one leaves it (`removeThread`), and a coven that is gone gives way to Strix's Overview (`handleCovenGone`). `sidebarItem` is the row the place belongs to, `placeTitle` its name, `placeGeneration` advances whenever the scope on screen or its place changes (also when the open thread is deleted or the coven on screen is gone), and not when another scope's place does. `shellWindowTitle` is "<Coven> — <Place>" ("Overview" for none). A thread is made when its first message is sent, as the cloud app makes one. New Thread (the toolbar button, ⌘N) and "New Thread with <name>" on the agents page open the scope's new-thread page, `DraftThreadView` (`Views/Chat/NewThreadComposer.swift`): empty but for `NewThreadComposer`, which says who the message goes to (in a coven a menu of its agents, the one the rule gives chosen; "Strix" in Strix and in a coven with no agents; "Loading agents…" with Send off while they are read), and, once something is sent, what was sent with "Sending…" and "Starting a thread…" while its thread is made. `MessageComposer` takes the choice of recipients (`recipientChoices`, `recipientID`, `onChooseRecipient`), and no files (`allowsAttachments: false`: a thread that is not made has nowhere to keep them) or voice there (it shows no mic without its voice handlers). What a scope's page holds unsent is kept while the window is open (`DraftThreads`, in memory, one `DraftThreadSubmission` for each scope). The rules: `requestNewThread(agentID:)` opens the scope's new-thread page (`.draftThread(covenId:)`, "New Thread", which belongs to no sidebar row), `handleCreatedThread` puts the thread that was made in the page's place, in its own scope and only where the page still is, and `askFromOverview` with `openThreadAskedFromOverview` opens a thread asked for from an Overview only if the person has stayed there and asked nothing since. `Services/NewThreadRules.swift` says what the thread is called (`ThreadTitleGenerator`: the message's first line, 60 characters at most, cut at a word; "New Thread" for none) and who it goes to in a coven (`NewThreadRules.recipient`: the agent asked for by name, else the one last used there, `LastUsedAgentStore`, kept on the device for each account, else the coven's first; none where the coven has no agents and Strix answers). `Services/DraftThreadSubmission.swift` does the sending: it reserves the send at once (a second does nothing), makes the thread for the account that sent, sends the message into it, and tells of the thread; if the thread cannot be made the text goes back to the field unless something newer was typed; if the message cannot be sent into the thread that was made, the thread keeps it for its own composer and is opened all the same; if another account signed in meanwhile, nothing more is done or said. `Services/CovenOrder.swift` is the person's own order for their covens (`ordered`, `moving`, `canMove`; a coven the order does not name follows, oldest first), kept on the device for each account (`CovenOrderStore`, a list of ids in the preferences under the account's key).
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
