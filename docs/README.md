# Documentation Index

**AICoven Local (Open Source Swift Client)**  
Last Updated: March 9, 2026

---

## Core Documentation

### [README.md](../README.md) 📘
**Main project overview and getting started guide**
- Project goals and vision (local-first, no backend)
- High-level architecture overview
- Implementation status (✅ implemented, 🚧 in progress, ⚠️ limitations)
- Community edition details
- Running the app (requirements, setup, build)
- Contributing guidelines

**Key Sections:**
- Current status and features
- Project layout and structure
- Tools and capabilities (including shell commands, connected apps)
- Privacy and security model

---

### [AGENTS.md](../AGENTS.md) 🤖
**Guidance for AI coding assistants working with this codebase**
- Common development commands (build, test, run, lint)
- Detailed architecture walkthrough
- Layer-by-layer code organization
- Active vs legacy services classification
- Best practices for making changes
- Test infrastructure overview (18 test files, 41+ methods)

**Intended Audience:** AI agents, automated tools, and developers new to the codebase

---

## Architecture Documentation

### [local-context-architecture.md](local-context-architecture.md) 🏗️
**Deep dive into the local-first architecture**
- Context sandwich composition with device-aware limits (mobile vs. desktop)
- GRDB persistence layer
- Encryption and key hierarchy (passphrase-based)
- Model routing and selection (including `.mcpToolCalling` task type)
- MLX on-device inference with iOS memory management
- Autonomous agent execution
- Memory storage and retrieval
- MCP server integration overview

**Topics Covered:**
- Data flow and lifecycle
- Repository pattern implementation
- Security model and encryption
- Agent safety constraints
- iOS memory pressure handling for MLX models

---

### [tools-and-providers.md](tools-and-providers.md) 🔧
**Provider integration and tools layer**
- LLMClient abstraction
- ModelRouter capabilities (including user-preference routing via `findExact` and `.mcpToolCalling`)
- Provider-specific implementations (OpenAI, Anthropic, Gemini, Ollama, MLX)
- Tools layer (web search, file/image generation, attachment analysis)
- MCP server integration (MCPClient, tool discovery, semantic tool selection, benchmark suite)
- Provider key management
- Pre-execution of tools for local models

**Topics Covered:**
- Adding new providers
- Tool registration and execution
- MCP server configuration and tool caching
- Model capability mapping
- API key security

---

## Quality & Testing Documentation

### [TEST_COVERAGE.md](TEST_COVERAGE.md) ✅
**Comprehensive test coverage analysis**
- 18 test files, 41+ test methods
- Coverage by area (LLM clients, services, infrastructure, integration)
- Detailed test descriptions and purposes
- Coverage gaps and recommendations
- Running tests (CLI and Xcode)
- CI/CD recommendations

**Coverage Areas:**
- **LLM Clients:** 3 files, 6 tests (Good ✅)
- **Services:** 5 files, 11 tests (Moderate 🟡)
- **Infrastructure:** 3 files, 7 tests (Good ✅)
- **Integration Tests:** 3 files, 8 tests (Moderate 🟡)
- **Tooling:** 3 files, 7 tests (Good ✅)
- **UI Tests:** 1 file, 2 tests (Minimal 🔴)

**Overall Coverage:** ~25% (Target: 70%)

---

### [CODE_REVIEW.md](CODE_REVIEW.md) 🔍
**Code review findings**
- Critical issues (encryption duplication, backend dependencies)
- High-priority issues (error handling, architecture violations)
- Medium-priority issues (type safety, security concerns)
- Low-priority issues (code style, performance)
- Recommended action plan
- Files requiring attention

**Note:** Some items flagged in this review have since been addressed (SwiftLint added, test suite expanded, model routing improved).

---

### [REVIEW_SUMMARY.md](REVIEW_SUMMARY.md) 📊
**High-level code review summary**
- Key findings and strengths
- Critical/high/medium priority issues
- Implementation status breakdown
- Security considerations
- Readiness assessment

---

## Privacy & Analytics Documentation

### [ANALYTICS_PRIVACY.md](ANALYTICS_PRIVACY.md) 🔒
**Privacy policy and analytics documentation**
- Opt-in only analytics with user consent
- SHA-256 hashing of all identifiers
- Local-only data storage guarantees
- Provider API key handling

---

### [ANALYTICS_PRIVACY_AUDIT.md](ANALYTICS_PRIVACY_AUDIT.md) 🔐
**Privacy audit and compliance**
- Detailed privacy audit findings
- Confirmation that no identifiable information is sent
- GDPR compliance notes
- Recommendations for further improvements

---

## Feature Documentation

### [Real-time Task Progress UI for Agent Scratchpad.md](Real-time%20Task%20Progress%20UI%20for%20Agent%20Scratchpad.md) 🎨
**Feature design document**
- Agent scratchpad UI design
- Real-time progress tracking
- User experience considerations

---

## Documentation Quality Checklist

### Current Status

| Document | Accuracy | Completeness | Last Updated |
|----------|----------|--------------|--------------|
| README.md | ✅ High | ✅ Complete | 2026-03-09 |
| AGENTS.md | ✅ High | ✅ Complete | 2026-03-09 |
| local-context-architecture.md | ✅ High | ✅ Complete | 2026-03-09 |
| tools-and-providers.md | ✅ High | ✅ Complete | 2026-03-09 |
| TEST_COVERAGE.md | ✅ High | ✅ Complete | 2026-02-09 |
| CODE_REVIEW.md | 🟡 Medium | ✅ Complete | 2026-02-03 |
| REVIEW_SUMMARY.md | 🟡 Medium | ✅ Complete | 2026-02-09 |
| ANALYTICS_PRIVACY.md | ✅ High | 🟡 Good | 2026-02-09 |
| ANALYTICS_PRIVACY_AUDIT.md | ✅ High | 🟡 Good | 2026-02-09 |

---

## Quick Reference

### For New Contributors

1. Start with [README.md](../README.md) for project overview
2. Read [AGENTS.md](../AGENTS.md) for development workflow
3. Review [CODE_REVIEW.md](CODE_REVIEW.md) for current issues
4. Check [TEST_COVERAGE.md](TEST_COVERAGE.md) before adding features

### For Code Reviewers

1. [CODE_REVIEW.md](CODE_REVIEW.md) for detailed findings
2. [REVIEW_SUMMARY.md](REVIEW_SUMMARY.md) for quick assessment
3. [TEST_COVERAGE.md](TEST_COVERAGE.md) for coverage gaps

### For Architects

1. [local-context-architecture.md](local-context-architecture.md) for system design
2. [tools-and-providers.md](tools-and-providers.md) for provider integration
3. [CODE_REVIEW.md](CODE_REVIEW.md) for architectural violations

### For QA/Testing

1. [TEST_COVERAGE.md](TEST_COVERAGE.md) for test suite overview
2. [README.md](../README.md) for running tests
3. [AGENTS.md](../AGENTS.md) for test commands

---

## Documentation Maintenance

### When to Update

- **After major features:** Update architecture docs and test coverage
- **After code reviews:** Update CODE_REVIEW.md and REVIEW_SUMMARY.md
- **After adding tests:** Update TEST_COVERAGE.md with new test files
- **After architectural changes:** Update local-context-architecture.md and tools-and-providers.md
- **Before releases:** Verify all documentation is accurate and complete

### Documentation Standards

1. **Accuracy:** All code examples and paths must be correct
2. **Timeliness:** Update dates when making changes
3. **Clarity:** Use clear headings, tables, and examples
4. **Cross-references:** Link related documents
5. **Status indicators:** Use ✅, 🚧, ⚠️, 🔴 for visual clarity

---

## Missing Documentation (Future Work)

### High Priority
- [ ] **CONTRIBUTING.md** – Contribution guidelines and code standards
- [ ] **SECURITY.md** – Security policy and vulnerability reporting

### Medium Priority
- [ ] **CHANGELOG.md** – Version history and changes
- [ ] **TROUBLESHOOTING.md** – Common issues and solutions

### Low Priority
- [ ] **PERFORMANCE.md** – Performance benchmarks and optimization
- [ ] **EXAMPLES/** – Example code and tutorials

---

## Getting Help

- **Issues:** Open a GitHub issue for questions or problems
- **Discussions:** Use GitHub Discussions for general questions
- **Code Review:** Request review in pull requests
- **Documentation:** Suggest improvements via issues or PRs

---

**This documentation index is maintained as part of the AICoven Local project.**  
**For questions or updates, please open a GitHub issue or PR.**
