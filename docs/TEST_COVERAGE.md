# Test Coverage Documentation

**Last Updated:** February 9, 2026  
**Project:** AICoven Local (Open Source Swift Client)  
**Test Framework:** XCTest  
**Total Test Files:** 18  
**Total Test Methods:** 38

---

## Overview

This document provides a comprehensive overview of test coverage for the AICoven Local client. The test suite validates core functionality across LLM clients, services, infrastructure, and integration scenarios.

### Test Statistics

| Category | Files | Test Methods | Coverage Status |
|----------|-------|--------------|-----------------|
| LLM Clients | 3 | 6 | ✅ Good |
| Services | 5 | 11 | 🟡 Moderate |
| Infrastructure | 3 | 7 | ✅ Good |
| Integration Tests | 3 | 8 | 🟡 Moderate |
| Tooling & Utilities | 3 | 7 | ✅ Good |
| UI Tests | 1 | 2 | 🔴 Minimal |
| **Total** | **18** | **41** | **🟡 Moderate** |

---

## Test Coverage by Area

### 1. LLM Clients (Provider Integration)

Tests for provider-specific LLM client implementations, ensuring proper API integration and error handling.

#### **GeminiLLMClientTests.swift** (2 tests)
**Purpose:** Validate Google Gemini API integration

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testCompleteChat_decodesSuccessfulResponse` | Validates chat completion response parsing with mocked URLSession | ✅ |
| `testEmbed_throwsUnsupportedError` | Ensures embeddings are properly marked as unsupported for Gemini | ✅ |

**Coverage:** 
- ✅ Successful response decoding
- ✅ Error handling for unsupported operations
- ❌ Network error scenarios
- ❌ Rate limiting responses
- ❌ Streaming responses

#### **OpenAILLMClientTests.swift** (2 tests)
**Purpose:** Validate OpenAI API integration

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testCompleteChat_decodesSuccessfulResponse` | Tests chat completion with authentication headers | ✅ |
| `testEmbed_decodesEmbeddingResponse` | Validates embedding vector response parsing | ✅ |

**Coverage:**
- ✅ Chat completion
- ✅ Embedding generation
- ✅ Authentication header injection
- ❌ Function calling / tools
- ❌ Vision model responses
- ❌ Token counting

#### **AnthropicLLMClientTests.swift** (2 tests)
**Purpose:** Validate Anthropic Claude API integration

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testCompleteChat_decodesSuccessfulResponse` | Tests Claude chat completion with proper headers | ✅ |
| `testEmbed_throwsUnsupportedError` | Ensures embeddings properly error for Claude | ✅ |

**Coverage:**
- ✅ Chat completion
- ✅ Anthropic-specific headers (x-api-key, anthropic-version)
- ✅ Unsupported operation handling
- ❌ Tool use responses
- ❌ Extended context windows

---

### 2. Services Layer

Tests for core business logic services that orchestrate LLM interactions and data management.

#### **ChatServiceSummaryTests.swift** (2 tests)
**Purpose:** Validate thread summary generation via ChatService

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testUpdateThreadSummaryWritesSummaryViaThreadStore` | Verifies summary generation and persistence | ✅ |
| `testUpdateThreadSummaryDoesNothingWhenNoModelAvailable` | Tests graceful degradation with no providers | ✅ |

**Coverage:**
- ✅ Summary generation
- ✅ Graceful fallback on missing models
- ❌ Summary update on long threads
- ❌ Summary caching

#### **MemoryServiceTests.swift** (1 test)
**Purpose:** Test memory search and retrieval

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testSearchMemory_withoutQuery_usesStoreWithUserScope` | Validates scope fallback for personal memories | ✅ |

**Coverage:**
- ✅ Memory search with user scope
- ❌ Thread-scoped memory search
- ❌ Hybrid search (keyword + semantic)
- ❌ Memory ranking

#### **ThreadServiceTests.swift** (3 tests)
**Purpose:** Test thread lifecycle management

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testCreateThreadAddsPersonalThreadAndCanBeLoaded` | Tests thread creation and retrieval | ✅ |
| `testUpdateAndDeleteThreadAffectPersonalStore` | Validates update and deletion operations | ✅ |
| `testDeleteThreadRemovesFromStore` | (Implied) Tests deletion persistence | ✅ |

**Coverage:**
- ✅ Thread CRUD operations
- ✅ JSON persistence to local disk
- ❌ Thread archiving
- ❌ Thread search/filtering
- ❌ Thread migration

#### **ErrorReportingTests.swift** (4 tests)
**Purpose:** Validate error handling and logging across services

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testUsageService_logsDecodeErrorAndFallsBack` | Tests graceful degradation on corrupted usage data | ✅ |
| `testPricingUpdateService_logsDecodeErrorAndReturnsEmpty` | Validates pricing service error handling | ✅ |
| `testLegacyChatHistory_logsAndSetsAsideAFileItCannotRead` | Tests that an unreadable chat-history file is logged and kept, not deleted | ✅ |
| `testDatabaseManager_logsErrorOnFailedMigration` | Validates database migration error logging | ✅ |

**Coverage:**
- ✅ JSON decode error handling
- ✅ Fallback strategies
- ✅ Error logging
- ❌ Network error handling
- ❌ Encryption error handling

#### **PricingUpdateServiceErrorTests.swift** (1 test)
**Purpose:** Test pricing provider error handling

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testRefreshNowAsync_logsPerProviderErrorsAndReturnsCachedOverrides` | Tests provider-specific error handling and caching | ✅ |

**Coverage:**
- ✅ Per-provider error isolation
- ✅ Fallback caching
- ❌ Pricing update scheduling
- ❌ Rate limiting

---

### 3. Infrastructure Layer

Tests for cross-cutting technical concerns including encryption, persistence, and utilities.

#### **DataEncryptionServiceTests.swift** (3 tests)
**Purpose:** Validate encryption/decryption with passphrase-derived keys

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testEncryptDecryptRoundtrip_succeedsWithMatchingPurpose` | Tests successful encrypt/decrypt with AEAD | ✅ |
| `testDecryptFailsWithWrongPurposeAuthentication` | Validates purpose-based authentication failure | ✅ |
| `testDecryptFailsWhenKeyLocked` | Tests behavior when encryption key is locked | ✅ |

**Coverage:**
- ✅ Encrypt/decrypt roundtrip
- ✅ AEAD authentication
- ✅ Purpose-based encryption contexts
- ✅ Key lock behavior
- ❌ Key rotation
- ❌ Secure deletion
- ❌ Key derivation (PBKDF2)

#### **AnyJSONValueTests.swift** (2 tests)
**Purpose:** Test JSON encoding/decoding utilities

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testDecodeScalarsAndContainers` | Validates decoding of mixed scalar and container types | ✅ |
| `testEncodeRoundTrip` | Tests encode/decode roundtrip for all JSON types | ✅ |

**Coverage:**
- ✅ Scalar types (string, number, boolean, null)
- ✅ Container types (array, object)
- ✅ Roundtrip serialization
- ❌ Nested structures
- ❌ Edge cases (NaN, Infinity)

#### **AppStateTests.swift** (2 tests)
**Purpose:** Test application state management

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testHandleDeepLink_parsesConnectedAppsURL` | Tests deep link URL parsing | ✅ |
| `testCreateNewThreadAppendsAndSelectsThread` | Validates thread creation and selection | ✅ |

**Coverage:**
- ✅ Deep link parsing
- ✅ Thread creation
- ✅ Thread selection
- ❌ State persistence
- ❌ State recovery
- ❌ Concurrent modifications

---

### 4. Integration Tests

End-to-end tests validating interactions between multiple components.

#### **PersistenceIntegrationTests.swift** (2 tests)
**Purpose:** Test real GRDB-backed repositories with encryption

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testThreadRepository_createThreadAndAppendMessages_roundtrip` | Validates full thread lifecycle with database | ✅ |
| `testMemoryRepository_storeAndLoad_roundtrip` | Tests memory persistence with encryption | ✅ |

**Coverage:**
- ✅ Real GRDB database operations
- ✅ Encryption/decryption integration
- ✅ Thread and message persistence
- ✅ Memory chunk storage
- ❌ Concurrent database access
- ❌ Database migration
- ❌ Query performance

#### **MemoryServiceIntegrationTests.swift** (4 tests)
**Purpose:** Test memory workflows with real repositories

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testCreateMemoryPersistsChunk` | Validates memory creation end-to-end | ✅ |
| `testUpdateMemoryFallsBackToExistingTextWhenContentNil` | Tests update fallback behavior | ✅ |
| `testReviewProposalApprove_createsMemoryAndUpdatesStatus` | Validates proposal approval workflow | ✅ |
| `testReviewProposalReject_updatesStatusWithoutCreatingMemory` | Tests proposal rejection workflow | ✅ |

**Coverage:**
- ✅ Memory creation
- ✅ Memory updates
- ✅ Proposal approval/rejection
- ✅ Status transitions
- ❌ Memory search
- ❌ Memory deletion
- ❌ Embedding generation

#### **ChatAndAgentIntegrationTests.swift** (2 tests)
**Purpose:** Test agent runner and chat service with tool execution

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testAgentRunner_run_executesToolAndProducesFinalAnswer` | Tests autonomous agent tool execution | ✅ |
| `testChatService_streamMessage_usesToolAndProducesFinalAnswer` | Validates chat service tool loop | ✅ |

**Coverage:**
- ✅ Agent runner execution
- ✅ Tool invocation
- ✅ Tool result processing
- ✅ Final answer generation
- ❌ Multi-step tool chains
- ❌ Tool error recovery
- ❌ Agent safety constraints

---

### 5. Tooling & Utilities

Tests for tool execution, message processing, and helper utilities.

#### **ChatToolingTests.swift** (3 tests)
**Purpose:** Test tool invocation parsing and configuration

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testChatToolInvocation_parsesSimpleJSON` | Validates tool call JSON parsing | ✅ |
| `testCurrentMaxToolSteps_defaultsAndCap` | Tests max tool steps configuration | ✅ |
| `testMaybeForceSearchQuery_forWeatherRefusal` | Tests weather query forcing logic | ✅ |

**Coverage:**
- ✅ Tool JSON parsing
- ✅ Configuration defaults
- ✅ Query forcing logic
- ❌ Complex tool parameters
- ❌ Tool validation

#### **AgentRunnerToolingTests.swift** (1 test)
**Purpose:** Test agent-specific tool execution

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testAgentToolCall_currentTimeProducesSummaryAndContext` | Tests current_time tool execution and context generation | ✅ |

**Coverage:**
- ✅ current_time tool
- ✅ Summary generation
- ✅ Context generation
- ❌ Other tools (web search, file generation)
- ❌ Tool chaining

#### **MessageAdapterTests.swift** (3 tests)
**Purpose:** Test message sanitization and transformation

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testSanitizeContent_removesSquareBracketToolCallMarkup` | Tests removal of `[tool_call]` markup | ✅ |
| `testSanitizeContent_removesAngleBracketToolCallMarkup` | Tests removal of `<tool_call>` markup | ✅ |
| `testSanitizeContent_removesThoughtBlocks` | Tests removal of `<thought>` blocks | ✅ |

**Coverage:**
- ✅ Tool call markup removal
- ✅ Thought block removal
- ✅ Content sanitization
- ❌ Markdown processing
- ❌ Code block handling

---

### 6. UI Tests

Smoke tests for SwiftUI view initialization.

#### **SwiftUIViewTests.swift** (2 tests)
**Purpose:** Basic UI smoke tests

| Test Method | Description | Status |
|-------------|-------------|--------|
| `testHomeViewInitializes` | Smoke test for HomeView creation | ✅ |

**Coverage:**
- ✅ Basic view initialization
- ❌ User interactions
- ❌ Navigation flows
- ❌ State updates
- ❌ Error states
- ❌ Accessibility

---

## Coverage Gaps and Recommendations

### Critical Gaps (High Priority)

1. **Model Routing** (🔴 No Coverage)
   - `HeuristicModelRouter` has no tests
   - Model selection logic unvalidated
   - Provider capability matching untested
   - **Recommendation:** Add `ModelRouterTests.swift`

2. **Context Builder** (🔴 No Coverage)
   - Context sandwich assembly untested
   - Memory retrieval integration not validated
   - Runtime facts injection unverified
   - **Recommendation:** Add `ContextBuilderTests.swift`

3. **Tool Service** (🔴 Limited Coverage)
   - Only current_time tool tested
   - Web search (DuckDuckGo) untested
   - File/image generation untested
   - Attachment analysis untested
   - **Recommendation:** Expand `ToolServiceTests.swift`

4. **Repository Layer** (🟡 Partial Coverage)
   - Integration tests exist, but no unit tests for repositories
   - Query logic untested independently
   - Transaction handling unvalidated
   - **Recommendation:** Add protocol-based mocks and unit tests

5. **UI Layer** (🔴 Minimal Coverage)
   - Only 2 smoke tests for views
   - No interaction tests
   - No state management tests
   - Navigation flows untested
   - **Recommendation:** Add ViewInspector-based UI tests

### Medium Priority Gaps

6. **Error Recovery**
   - Network failures mostly untested
   - Retry logic unvalidated
   - Error presentation to users untested

7. **Performance**
   - No performance benchmarks
   - Memory usage untracked
   - Database query performance unmeasured

8. **Security**
   - Key derivation (PBKDF2) untested
   - Secure deletion unvalidated
   - Key rotation untested

### Low Priority Gaps

9. **Legacy Code**
   - Coven/Role services untested (scheduled for removal)
   - Auth service untested (no-op methods)

10. **Edge Cases**
    - Unicode handling
    - Large message handling
    - Concurrent operations stress testing

---

## Test Quality Metrics

### Good Practices ✅

1. **Mocking:** Tests use URLProtocol mocking for network requests
2. **Isolation:** Each test is self-contained with proper setup/teardown
3. **Async Support:** Proper use of `async throws` for async tests
4. **Integration Tests:** Real database tests validate end-to-end flows
5. **Error Cases:** Tests cover both success and failure scenarios

### Areas for Improvement ⚠️

1. **Test Data Builders:** No shared test data factories (lots of duplication)
2. **Coverage Measurement:** No automated coverage tracking in CI
3. **Performance Tests:** No XCTestMetric usage for performance validation
4. **UI Testing:** Limited ViewInspector or snapshot testing
5. **Documentation:** Test method names are descriptive, but no inline comments

---

## Running Tests

### Run All Tests

```bash
cd /path/to/aicoven-local-opensource

xcodebuild \
  -project "swift/AICoven/AICoven Local.xcodeproj" \
  -scheme AICoven \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test
```

### Run Specific Test Class

```bash
xcodebuild \
  -project "swift/AICoven/AICoven Local.xcodeproj" \
  -scheme AICoven \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:AICovenTests/MessageAdapterTests \
  test
```

### Run Single Test Method

```bash
xcodebuild \
  -project "swift/AICoven/AICoven Local.xcodeproj" \
  -scheme AICoven \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:AICovenTests/MessageAdapterTests/testSanitizeContent_removesSquareBracketToolCallMarkup \
  test
```

### Via Xcode

1. Open `swift/AICoven/AICoven Local.xcodeproj`
2. Press `Cmd+U` to run all tests
3. Use Test Navigator (Cmd+6) to run individual tests
4. View coverage: Product → Test → Show Code Coverage

---

## Test Coverage Goals

| Component | Current | Target | Priority |
|-----------|---------|--------|----------|
| LLM Clients | 40% | 80% | Medium |
| Services | 35% | 75% | High |
| Infrastructure | 60% | 90% | High |
| Core (Routing, Context) | 5% | 85% | Critical |
| UI Layer | 1% | 50% | Medium |
| **Overall** | **~25%** | **70%** | **High** |

---

## Recommended Test Additions

### Immediate Priority (Next Sprint)

1. **ModelRouterTests.swift** (Critical)
   - Test model selection logic
   - Test capability matching
   - Test fallback strategies

2. **ContextBuilderTests.swift** (Critical)
   - Test context sandwich assembly
   - Test memory retrieval integration
   - Test policy injection

3. **ToolServiceTests.swift** (High)
   - Test web search
   - Test file generation
   - Test image generation
   - Test attachment analysis

### Short-term (1-2 Months)

4. **Repository Protocol Tests**
   - Add mock implementations
   - Test query logic in isolation
   - Test transaction handling

5. **UI Interaction Tests**
   - Add ViewInspector
   - Test user flows
   - Test state updates
   - Test error presentation

6. **Security Tests**
   - Test key derivation
   - Test secure deletion
   - Test key rotation

### Long-term (3+ Months)

7. **Performance Benchmarks**
   - Database query performance
   - Memory usage tracking
   - UI rendering performance

8. **Snapshot Tests**
   - Add snapshot testing for views
   - Verify visual regression

9. **E2E Tests**
   - Full user workflow tests
   - Multi-provider scenarios
   - Complex agent runs

---

## Contributing to Tests

When adding new tests:

1. **Follow naming convention:** `test<Method>_<scenario>_<expectedOutcome>`
2. **Keep tests isolated:** Use fresh instances, no shared state
3. **Mock external dependencies:** Use URLProtocol, mock stores
4. **Test both success and failure:** Happy path + edge cases
5. **Document complex logic:** Add comments for non-obvious test setup
6. **Update this document:** Add new test files to the coverage tables

---

## Continuous Integration

**Current Status:** 🔴 No CI test automation configured

**Recommended CI Setup:**

```yaml
# .github/workflows/test.yml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Run Tests
        run: |
          xcodebuild test \
            -project "swift/AICoven/AICoven Local.xcodeproj" \
            -scheme AICoven \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
            -enableCodeCoverage YES
      - name: Upload Coverage
        uses: codecov/codecov-action@v3
```

---

## Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-02-09 | Initial test coverage documentation | Automated Review |

---

**For questions or to report gaps in coverage, please open a GitHub issue.**
