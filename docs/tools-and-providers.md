# Providers, API Keys, and Tools

This document explains how the AICoven local client uses your provider keys, how to configure them, and what built-in tools are available in the app.

The client is **local-first** and has no required custom backend. All state (threads, messages, memories, settings, agent runs) is stored on-device. The only outbound network calls are:

- HTTPS requests directly to LLM / embedding providers you configure (e.g. OpenAI, Anthropic, Gemini).
- HTTPS requests to DuckDuckGo's JSON API for web search (no API key required).

## Supported provider types

The `LLMClient` layer is designed to work with multiple providers. The exact list will evolve, but the core categories are:

- **OpenAI-compatible APIs** – chat completions and embeddings.
- **Anthropic** – Claude models via the Messages API.
- **Google / Gemini** – Gemini models via the Generative Language API.
- **OpenRouter** – any model in OpenRouter's catalog that is served at its chat completions endpoint and supports tool calling, with an OpenRouter API key. Requests go to `https://openrouter.ai/api/v1` in the OpenAI chat completions format. The model picker lists those models with a default first (a Claude Sonnet, else a GPT, else a Gemini model). Summaries, agent steps and fallback routing use only the OpenRouter model chosen in Strix settings, or that default when none is chosen. The account's Test action asks OpenRouter whether it accepts the key. OpenRouter usage is recorded with a cost of $0, because the app has no OpenRouter prices.
- **Ollama** – local model server running on `http://localhost:11434`. Models are discovered automatically via `/api/tags`. No API key required.
- **MLX (on-device)** – runs models directly on Apple Silicon (Mac, iPad 8 GB+, iPhone 6 GB+) using Apple's MLX framework. Models are downloaded from HuggingFace and cached locally. The curated catalog includes 11 models organized by category (General, Coding, Mobile) and tier (Core, Specialized), with device-aware filtering for iPhones.
- **OpenClaw** – An OpenAI-compatible self-hosted proxy. Can point at a local endpoint (`http://localhost:3000`) or a remote cloud API. The client exposes `isLocalEndpoint` so `ChatService` applies the correct timeout profile (300s/600s for local vs. 60s/120s for cloud) and skips cloud-only behavior like background thread summarization.
- **OpenAI-compatible server** – any server that speaks the OpenAI chat API, on this machine (LM Studio, llama.cpp, vLLM) or hosted: an address, a key if the server asks for one, and a model. A connection made for Nous Research's Hermes models in an earlier version becomes one of these the first time the app reads its connections: at Together AI's address when it named none, with its key and its model (`ProviderAccountService.convertHermesModelConnectionsIfNeeded`).
- **Hermes agent** – Nous Research's Hermes Agent, through its API server (usually `http://127.0.0.1:8642`, with the key it was started with as `API_SERVER_KEY`). Hermes is an agent, not a model: it runs the turn itself, with its own tools, memory and model, through its `/v1/runs` API. The app starts a run for each message, shows its progress, answers what it asks to be allowed through the approval card, and stops it when the turn is stopped.
- **MCP servers** – external tool servers connected via the Model Context Protocol. See the [MCP server integration](#mcp-server-integration) section below.

`ModelRouter` selects a `(providerID, modelID)` pair for each task (chat, summarization, embeddings, MCP tool calling, etc.) based on the set of providers that have keys configured on your device. The `.mcpToolCalling` task type prefers models flagged as tool-capable, falling back to the cheapest available model.

## Where keys are stored

Provider keys are never sent to any AICoven backend; they stay on your device:

- The app uses a `SecretsStore` abstraction backed by the system Keychain to store API credentials securely.
- References to provider accounts and preferences are stored in the encrypted SQLite database.
- When an LLM call is made, the appropriate client pulls the key from `SecretsStore` and adds it to the HTTPS request.

For more on encryption and local storage, see `docs/local-context-architecture.md`.

## Configuring provider keys in the app

> UI labels and exact flows may change slightly over time, but this is the intended user experience.

1. **Open the app** (iOS or macOS) and go to **Settings → AI connections** (⌘, opens Settings on the Mac).
2. For each provider you want to use (e.g. OpenAI, Anthropic, Gemini):
   - Paste your API key into the corresponding field.
   - Optionally choose a default model if the UI exposes model selection.
3. Save your changes.

Once a key is configured and validated, the `LLMConfiguration` environment and `ModelRouter` will include that provider in routing decisions. If no keys are configured, the app will surface a clear error message when you try to chat.

## How routing works

When you send a message or an agent step runs, the app:

1. Builds a **context sandwich** via `ContextBuilder` (system contract, time, policies, memories, history, current message). On iPhone, the builder uses tighter limits (6 recent messages, 4 memories) to leave headroom for MLX model weights.
2. Constructs a `RoutingContext` (task type, quality vs. cost preferences, long-context requirements, etc.).
3. Asks `ModelRouter` to choose the best available `ModelDescriptor` for that context, limited to providers with valid keys. The active MLX model is registered as a `ModelDescriptor` by `LLMConfiguration.makeEnvironment()` so it participates in routing.
4. Invokes the chosen `LLMClient` with your message(s) and the selected `modelID`.

For local models (MLX, Ollama), `ChatService` supports **pre-execution**: before sending the user's message to the model, it checks for keyword matches against native tools (time, web search) and MCP tools (via fuzzy scoring). If a match is found, the tool is executed eagerly and the result injected into the prompt. This significantly improves tool-calling reliability for simple single-tool queries.

If no matching provider/model is available (e.g. no keys set, or only incompatible models), the router returns `nil` and the caller shows a human-readable error instead of failing silently.

## Tools overview

On top of raw LLM calls, the app exposes a set of **provider-agnostic tools** implemented by `ToolService`. These tools are designed to:

- Work with whichever providers you have keys for.
- Avoid any additional developer or user keys.
- Produce artifacts (files/images) that the UI can display and the user can download or reuse.

### Time

- `currentTime(timezone:)` returns both UTC and local ISO8601 timestamps plus the timezone identifier.
- `ContextBuilder` injects this into the system messages so the model can reason about "now" without device APIs.

### Web search

- Implemented as `webSearch(query:maxResults:)` on `ToolService`.
- Uses DuckDuckGo's JSON API (`https://api.duckduckgo.com/?q=...&format=json&no_html=1&skip_disambig=1`).
- Does **not** require any key; it is purely HTTP to a public endpoint.
- Returns a small list of `(title, url, snippet)` results.
- Results can be surfaced to the model as extra system context or appended into the user message by the enhanced composer.

### Attachment and file analysis

- `analyzeAttachment(_ attachment:hints:)` branches based on the attachment's MIME type:
  - For images (`image/*`), loads bytes from disk and calls a vision-capable model (if any) via `LLMClient`.
  - For text-like files, reads UTF‑8 content and sends it to the best available chat model.
  - If only a filename is available, synthesizes a description and asks the model for high-level guidance.
- `analyzeFile(text:hints:)` lets callers pass arbitrary text blobs for summarization or Q&A.

These are used in two main places:

- **Interactive chat** – the enhanced message composer can run "Summarize attachments" to generate summaries before you send.
- **Agents** – autonomous runs can call into the same APIs when they need to understand files or images.

### Image generation

- Image generation is a tool a model calls, `image.generate` (`prompt`, and optionally `model`, `size`, `quality`), not a `ToolService` function.
- It is offered to a chat turn only where an OpenAI key is stored, whichever model answers the turn. Agent runs are not offered it.
- `ImageGenerationService` (`Infrastructure/Tools/ImageGenerationService.swift`) makes the image with that key at OpenAI's image endpoint (`POST /v1/images/generations`). With no model named, the key's image models are tried in order, four at most.
- `ToolExecutionService` keeps the image in the app's encrypted attachment store (`AttachmentStore`) for the thread, only if the thread is the signed-in account's.
- The turn gives it to its reply, which shows it like any attachment (`FileAttachmentDetail`): a thumbnail that opens in Quick Look. The model is told the person has the image, not where it is.
- Only OpenAI makes images for now.

### File generation

- `generateFile(name:mimeType:contents:)` writes a file to disk (typically under a `GeneratedFiles` directory) and returns a `GeneratedFile` with `id`, `url`, and MIME type.
- Used for things like saving summaries, reports, or other text artifacts produced during a chat or agent run.
- Files are exposed to the UI as attachments so users can open or export them via the host OS.

## Tools in the chat UI

The enhanced message composer in the personal chat view wires several of these tools directly into the user experience:

- **Web search** – Takes the current draft message as a query and appends a `[Web search results]` section with top results.
- **Summarize attachments** – Runs `analyzeAttachment` for each attached file/image and appends an `[Attachment analysis]` section.
- **Generate file from message** – Calls `generateFile` to save the draft text as a `.txt` file and attaches it.

When you hit send:

- Only your **human-authored question** is persisted as the user message in the thread.
- Tool-produced sections (e.g. `[Web search results]`, `[Attachment analysis]`) are treated as **extra system context** in the context sandwich rather than as literal user text.

This keeps the conversation history readable while still giving the model access to richer, tool-generated information.

## Tools in autonomous agents

The same `ToolService` instance is available to the autonomous `AgentRunner`.

- Agents can call web search, attachment analysis, and file/image generation helpers as part of their planning/execution loop.
- Each use of a tool is recorded in the `agent_steps` table along with any intermediate reasoning the model exposes.
- The step limit (`max_steps`) is enforced regardless of tool usage, so tools cannot cause unbounded execution.

Agents and the streaming chat path share a simple JSON protocol for tool calls. When a model wants to call a tool, it must respond with a single JSON object (no extra text) of the form:

```json
{"tool": "web_search" | "current_time", "input": "...", "reason": "..."}
```

`AgentRunner` parses this via an internal `AgentToolCall` helper, executes the mapped `ToolService` method, and feeds a summarized context block back into the context sandwich. The chat streaming path uses a similar `ChatToolInvocation` helper and enforces a configurable `chat_max_tool_steps` budget to avoid unbounded tool loops.

Agent UI and tooling are still evolving, but the intent is to expose:

- A run history showing which tools were invoked and why.
- Links to any generated files/images.
- A clear way to stop or limit tool usage.

## MCP server integration

The app supports the [Model Context Protocol (MCP)](https://modelcontextprotocol.io), allowing users to connect external tool servers and use their tools from chat.

### Architecture

- `MCPClient` (actor, `Features/MCP/MCPClient.swift`) handles the JSON-RPC 2.0 transport. Connects via HTTP POST and supports both plain JSON and SSE (`text/event-stream`) response formats.
- `MCPServerAccount` (`Features/ConnectedApps/MCPServerAccount.swift`) stores per-server configuration: URL, transport type (`sse` or `streamable_http`), auth type (`none`, `bearer`, `api_key`), and cached tool definitions.
- `ConnectedAccountsService` persists server configs in `UserDefaults` and stores auth tokens in Keychain.
- `MCPServerManagementView` provides the settings UI for managing servers.

### Tool discovery and caching

When an MCP server is connected, the app calls `tools/list` to discover available tools. The response is cached in `MCPServerAccount.cachedTools` and refreshed on reconnect or when the cache is stale. Tools are surfaced to `ChatService` via `PromptTemplates.mcpToolDefinitions`, which converts them into the internal `ToolDefinition` format.

### Semantic tool selection

When many MCP tools are available, the app uses `MCPToolEmbeddingCache` to compute and cache embedding vectors for tool descriptions. During a chat turn, `ChatService` ranks tools by cosine similarity to the user's query and includes only the top candidates in the prompt. This reduces prompt size and improves accuracy, especially for local models with limited context windows.

### MCP tool-calling benchmark

`MCPToolCallingBenchmark` (`Core/LLM/MCPToolCallingBenchmark.swift`) provides a lightweight evaluation suite for testing a local model's ability to select the correct tool from a JSON prompt. The default suite includes 10 test cases covering web search, time, file operations, GitHub, shell, and Google Drive tools. Results (accuracy, refusal rate, hallucination rate, average latency) are persisted in `UserDefaults` and displayed in the MLX model settings UI.

### Tool execution flow

1. `ChatService` checks connected MCP servers for tools matching the user's message (keyword/fuzzy matching for local models, native function declarations for cloud providers).
2. For local models, the best-matching MCP tool is pre-executed before the model generates a response.
3. Tool execution goes through `MCPClient.callTool(name:arguments:)`, which sends a `tools/call` JSON-RPC request.
4. Results are injected into the context sandwich as a `[Tool Result]` block, truncated to device-appropriate limits (4 KB on iPhone, 8 KB on Mac/iPad).

## Privacy considerations

- Provider keys never leave the device except in HTTPS requests directly to the chosen provider.
- Tool calls that talk to the network (web search, provider APIs, and MCP server calls) are explicit and auditable.
- MCP server authentication tokens are stored in the system Keychain, not in plaintext.
- All long-term state (including agent runs and tool outputs that are persisted) is stored in the encrypted SQLite database.

If you intend to extend the tools layer (for example, to add Git or local shell access), please follow the same design constraints:

- Prefer local operations over new remote services.
- Make any outbound network calls explicit and minimal.
- Ensure new tools integrate cleanly with the context sandwich and do not leak sensitive data by default.

---

## Servers that can be local or remote: OpenClaw and OpenAI-compatible servers

An OpenClaw connection and an OpenAI-compatible server can each point at a server on this machine or at a remote one. The client detects which via the `isLocalEndpoint` computed property.

### `isLocalEndpoint` detection
`OpenClawLLMClient` provides a static `isLocalAddress(_ url: URL) -> Bool` helper that checks whether the base URL resolves to a loopback address, `localhost`, or a private network range.

When `isLocalEndpoint` is `true`:
- Timeouts are extended: **300s connect / 600s response** (local inference is slow).
- `ChatService.isLocalDeployment(providerID:)` returns `true`, suppressing cloud-only behaviors such as background thread summarization on iOS.
- `hasCloudProvider` (used for background summary gating) returns `false`.

When `isLocalEndpoint` is `false` (a remote address, e.g. Together AI):
- Standard cloud timeouts apply: **60s connect / 120s response**.
- Background summarization is enabled.

---

## Background actors: memory and summarization

To prevent heavy post-turn work from blocking the chat stream, memory persistence and thread summarization run in independent Swift actors that subscribe to a shared event bus.

### `ChatEventBus`

A lightweight `actor` using `AsyncStream` continuations:

```swift
enum ChatEvent {
    case memoryProposalsReady(proposals: [ParsedMemoryProposal], threadId: String)
    case threadNeedsSummary(threadId: String)
}

actor ChatEventBus {
    static let shared = ChatEventBus()
    func subscribe() -> AsyncStream<ChatEvent>  // one stream per subscriber
    func emit(_ event: ChatEvent)               // broadcasts to all subscribers
}
```

Using `AsyncStream` (vs. `NotificationCenter`) gives type-safe, back-pressure-aware delivery without `userInfo` casting.

### `BackgroundMemoryService`

`actor BackgroundMemoryService` subscribes to `.memoryProposalsReady` events and writes proposals to the local SQLite database via `MemoryService`. Runs entirely outside the chat stream — memory writes never block the next user message.

Started once at app launch:
```swift
// AICovenApp.swift
Task { await BackgroundMemoryService.shared.start() }
```

### `BackgroundSummarizationService`

`actor BackgroundSummarizationService` subscribes to `.threadNeedsSummary` events. It builds its **own independent LLM environment** (via `LLMConfiguration.makeEnvironment()`) so summarization LLM calls never compete with the user's interactive chat.

Started at app launch:
```swift
Task { await BackgroundSummarizationService.shared.start() }
```

**iOS-only behavior:** When only local (MLX/Ollama) models are available, `BackgroundSummarizationService` skips summarization to avoid resource contention on constrained devices. This is checked via `hasCloudProvider` from `ChatService`.

### Why separate actors?

Memory proposal writes are cheap I/O (local DB insert). Summarization is an expensive LLM call that may take 10–30 seconds. Keeping them in separate actors prevents a slow summarization from ever blocking memory writes.
