# OpenAI-Compatible Proxy Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the native PromptMeet app save and use an OpenAI-compatible Base URL and model while preserving official OpenAI, DeepSeek, Keychain secrecy, and truthful screenshot degradation.

**Architecture:** A typed Swift configuration owns defaults, UserDefaults migration, URL policy, request URL construction, and validation request creation. The companion exports the normalized preferences to a typed Python provider configuration, which becomes the single routing source for every desktop AI request. OpenAI-compatible image requests are attempted against that same endpoint and model, with a one-time text-only retry only when the configured service explicitly rejects image input.

**Tech Stack:** Swift 6, SwiftUI, Foundation URLSession and UserDefaults, macOS Keychain, Python 3.13, dataclasses, urllib, httpx, XCTest, pytest.

## Global Constraints

- Never use the em dash character.
- API keys remain only in macOS Keychain and process memory/environment. They must never enter UserDefaults, logs, serialized records, WebSocket payloads, public status, response messages, or error text.
- Plain HTTP is valid only for `localhost`, `127.0.0.1`, and `::1`; all other hosts require HTTPS.
- Existing users retain the official OpenAI defaults `https://api.openai.com/v1` and `gpt-4o`, and existing Keychain accounts are unchanged.
- DeepSeek routing, meeting history, context construction, screenshot storage, and request concurrency remain unchanged.
- Every behavior follows red, green, refactor with captured command output.
- Delivery includes complete tests, lint, release build, app packaging, signing, real settings walkthrough, commit, no-mistakes, push, PR, and CI. Never use `--yes` and never merge.

---

### Task 1: Typed native OpenAI-compatible preferences

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Services/AIProviderConfiguration.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/AIProviderConfigurationTests.swift`

**Interfaces:**
- Produces: `OpenAICompatibleConfiguration(baseURL:modelID:)`, `chatCompletionsURL`, `AIProviderPreferences.loadOpenAICompatible()`, and `saveOpenAICompatible(_:)`.
- Consumes: existing `AIProviderCatalog`, Keychain account names, and legacy `openAIAnswerModel` preference.

- [ ] **Step 1: Write failing boundary tests**

```swift
func testOpenAICompatibleBoundaryNormalizesOfficialAndLoopbackURLs() throws {
    XCTAssertEqual(
        try OpenAICompatibleConfiguration(baseURL: "https://api.openai.com/v1/", modelID: " gpt-4o ").chatCompletionsURL.absoluteString,
        "https://api.openai.com/v1/chat/completions"
    )
    XCTAssertEqual(
        try OpenAICompatibleConfiguration(baseURL: "http://localhost:52251/v1/", modelID: "local-model").chatCompletionsURL.absoluteString,
        "http://localhost:52251/v1/chat/completions"
    )
}

func testOpenAICompatibleBoundaryRejectsNonLoopbackHTTP() {
    XCTAssertThrowsError(try OpenAICompatibleConfiguration(baseURL: "http://proxy.example/v1", modelID: "model"))
}

func testOpenAIPreferencesMigrateMissingBaseWithoutReplacingSavedModel() throws {
    defaults.set("saved-model", forKey: AIProviderPreferenceKey.openAIModel)
    let value = try AIProviderPreferences(defaults: defaults).loadOpenAICompatible()
    XCTAssertEqual(value.baseURL.absoluteString, "https://api.openai.com/v1")
    XCTAssertEqual(value.modelID, "saved-model")
}
```

- [ ] **Step 2: Run the focused Swift test and verify RED**

Run: `cd desktop-macos && swift test --filter AIProviderConfigurationTests`
Expected: compile failure because the typed configuration and preference store do not exist.

- [ ] **Step 3: Implement the typed boundary and preference migration**

Implement exact host/scheme checks with `URLComponents`, strip only trailing path slashes, reject credentials/query/fragment, trim and require the model identifier, and keep the existing `openAIAnswerModel` key. Store only the canonical Base URL string and model identifier.

- [ ] **Step 4: Re-run the focused Swift test and verify GREEN**

Run: `cd desktop-macos && swift test --filter AIProviderConfigurationTests`
Expected: all configuration, migration, and Keychain tests pass.

### Task 2: Configured validation and settings UI

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Services/AIProviderConfiguration.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/PromptMeetSettingsView.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/AIProviderConfigurationTests.swift`

**Interfaces:**
- Consumes: `OpenAICompatibleConfiguration` and `AIProviderPreferences` from Task 1.
- Produces: a validator that POSTs to the configured `chat/completions` URL with the configured model and sanitizes provider response messages.

- [ ] **Step 1: Write failing URLProtocol-backed validator tests**

```swift
func testValidationPostsConfiguredEndpointAndModel() async throws {
    let result = await validator.validate(
        providerID: "openai",
        modelID: "proxy-model",
        baseURL: "http://127.0.0.1:52251/v1/",
        secret: "test-placeholder"
    )
    XCTAssertEqual(capturedURL?.absoluteString, "http://127.0.0.1:52251/v1/chat/completions")
    XCTAssertEqual(capturedJSON?["model"] as? String, "proxy-model")
    XCTAssertTrue(result.isValid)
}

func testValidationReturnsUsefulProviderMessageWithCredentialRedacted() async {
    responseBody = #"{"error":{"message":"bad test-placeholder model"}}"#
    let result = await validator.validate(...)
    XCTAssertTrue(result.message.contains("bad"))
    XCTAssertFalse(result.message.contains("test-placeholder"))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `cd desktop-macos && swift test --filter AIProviderConfigurationTests`
Expected: validator signature and behavior assertions fail.

- [ ] **Step 3: Implement validation and edit the native settings pane**

For OpenAI, render `OpenAI 兼容`, editable `Base URL`, editable `模型标识`, the existing masked Keychain state, and secure key draft. Validate with the draft key or an existing Keychain value, save normalized non-secret preferences independently of whether the key changed, and never put the key into feedback. DeepSeek retains its existing picker and behavior.

- [ ] **Step 4: Re-run the focused test and verify GREEN**

Run: `cd desktop-macos && swift test --filter AIProviderConfigurationTests`
Expected: all validator, redaction, preference, and secret tests pass.

### Task 3: Companion environment and centralized backend routing

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Services/CompanionLauncher.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/CompanionRuntimeLocatorTests.swift`
- Modify: `backend/services/model_provider.py`
- Modify: `backend/services/desktop_agent_service.py`
- Modify: `backend/tests/test_model_provider.py`
- Modify: `backend/tests/test_desktop_agent_service.py`

**Interfaces:**
- Consumes: persisted canonical Base URL/model and unchanged Keychain account.
- Produces: `OPENAI_API_BASE`, `OPENAI_ANSWER_MODEL`, and `OPENAI_QUESTION_MODEL`; every desktop request consumes `ProviderConfiguration.from_environment()`.

- [ ] **Step 1: Write failing companion export tests**

```swift
func testOpenAICompatibleRuntimeEnvironmentUsesPersistedBaseAndModelForAllRequests() throws {
    let environment = try preferences.runtimeEnvironment(providerID: "openai")
    XCTAssertEqual(environment["OPENAI_API_BASE"], "http://localhost:52251/v1")
    XCTAssertEqual(environment["OPENAI_ANSWER_MODEL"], "proxy-model")
    XCTAssertEqual(environment["OPENAI_QUESTION_MODEL"], "proxy-model")
}
```

- [ ] **Step 2: Verify the companion test is RED**

Run: `cd desktop-macos && swift test --filter CompanionRuntimeLocatorTests`
Expected: missing runtime environment API.

- [ ] **Step 3: Implement and verify companion export GREEN**

Run: `cd desktop-macos && swift test --filter CompanionRuntimeLocatorTests`
Expected: persisted normalized values are exported and no secret is returned by the preference store.

- [ ] **Step 4: Write failing Python routing tests**

```python
def test_openai_compatible_endpoint_and_model_are_routed_exactly() -> None:
    configuration = ProviderConfiguration.from_environment({
        "PROMPTMEET_AI_PROVIDER": "openai",
        "OPENAI_API_KEY": "placeholder",
        "OPENAI_API_BASE": "http://[::1]:52251/v1/",
        "OPENAI_ANSWER_MODEL": "proxy-model",
    })
    assert configuration.endpoint == "http://[::1]:52251/v1/chat/completions"
    assert configuration.model == "proxy-model"

def test_selected_openai_never_falls_back_to_deepseek_or_official_openai() -> None:
    service = DesktopAgentService(environment={
        "PROMPTMEET_AI_PROVIDER": "openai",
        "DEEPSEEK_API_KEY": "deepseek-placeholder",
        "OPENAI_API_BASE": "http://localhost:52251/v1",
    })
    with pytest.raises(RuntimeError):
        service.provider_status()
```

- [ ] **Step 5: Run focused Python tests and verify RED**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_model_provider.py tests/test_desktop_agent_service.py`
Expected: local endpoint/model routing and no-fallback assertions fail.

- [ ] **Step 6: Centralize all desktop requests on ProviderConfiguration**

Normalize the OpenAI-compatible base with Python's URL parser using the same scheme/host policy as Swift. Accept an arbitrary non-empty compatible model identifier. Replace endpoint-string provider inference and `_provider` branching with typed configurations for answers, questions, summaries, translations, meeting answers, and screenshot analysis. Preserve DeepSeek defaults.

- [ ] **Step 7: Re-run focused Python tests and verify GREEN**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_model_provider.py tests/test_desktop_agent_service.py`
Expected: all focused routing tests pass with no credential in repr/status/errors.

### Task 4: Truthful image-input rejection degradation

**Files:**
- Modify: `backend/services/desktop_agent_service.py`
- Modify: `backend/tests/test_desktop_agent_service.py`

**Interfaces:**
- Consumes: the exact configured endpoint/model from `ProviderConfiguration`.
- Produces: a one-time same-provider text-only retry for explicit image-input rejection, plus accurate `degraded_vision` and screenshot `vision_used` metadata.

- [ ] **Step 1: Write a failing multimodal rejection test**

```python
def test_proxy_image_rejection_retries_text_only_on_same_endpoint_and_model(monkeypatch, tmp_path) -> None:
    result = asyncio.run(service.answer_meeting(record_with_screenshot, "图上是什么？", collect))
    assert captured_urls == [
        "http://localhost:52251/v1/chat/completions",
        "http://localhost:52251/v1/chat/completions",
    ]
    assert [payload["model"] for payload in payloads] == ["proxy-model", "proxy-model"]
    assert first_payload_contains_image()
    assert not second_payload_contains_image()
    assert result.degraded_vision is True
```

- [ ] **Step 2: Run the exact test and verify RED**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_desktop_agent_service.py -k image_rejection`
Expected: first 400 image rejection aborts instead of retrying truthfully.

- [ ] **Step 3: Implement a narrow, one-time fallback**

Fallback only for 400, 415, or 422 responses whose provider message identifies image, vision, multimodal, or `image_url` input. Rebuild the prompt as text-only, retain endpoint/model, and mark degradation. Other failures propagate unchanged. Screenshot analysis records `vision_used=false` and an explicit unsupported message when this happens.

- [ ] **Step 4: Re-run exact and focused tests for GREEN**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_desktop_agent_service.py tests/test_context_builder.py tests/test_desktop_screenshot_processing.py`
Expected: all tests pass and the fallback does not affect DeepSeek or ordinary OpenAI-compatible text requests.

### Task 5: Documentation, full validation, and delivery

**Files:**
- Modify: `README.md`
- Modify: `docs/macos-meeting-agent.md`
- Modify only if an invariant changes: `AGENTS.md`
- Append: `/Users/zilong/coding/firstmate/state/promptmeet-openai-proxy-settings.status`

**Interfaces:**
- Documents: exact local proxy example, URL security policy, persistence split, validation behavior, and image rejection degradation.

- [ ] **Step 1: Update owner documentation without touching generated files**

Document `http://localhost:52251/v1`, official defaults, HTTPS policy, Keychain isolation, and same-endpoint image fallback. Keep AGENTS.md as short pointers unless a core invariant materially changes.

- [ ] **Step 2: Run full automated verification**

```bash
cd backend && ../build/desktop-python/bin/python3 -m pytest -q
cd desktop-macos && swift test
cd backend && ../build/desktop-python/bin/python3 -m black --check .
cd desktop-macos && swift build -c release
```

Expected: all test, lint, and release commands pass.

- [ ] **Step 3: Package and verify signing**

```bash
./scripts/build-whisper-runtime.sh
./scripts/build-macos-app.sh
codesign --verify --deep --strict dist/PromptMeet.app
```

Expected: runtime, bundle, and signing checks pass.

- [ ] **Step 4: Perform the closest real settings walkthrough**

Open the actual native settings window with a lane-local UserDefaults/Keychain context. Confirm OpenAI-compatible label, editable Base URL/model, official migration defaults, loopback HTTP acceptance, non-loopback HTTP rejection, exact local `/v1/chat/completions` validation routing against a fake local server, useful sanitized error text, masked credential state, durable relaunch, and no official endpoint request. Use only a placeholder credential.

- [ ] **Step 5: Commit and run no-mistakes**

Commit only task files, then run `no-mistakes axi run --intent "<complete launch brief and decisions>"`. Drive every auto-fix/no-op gate, stop on any ask-user gate, never use `--yes`, and never merge.

- [ ] **Step 6: Record final evidence**

Append red-green commands, suite counts, lint/build/package/sign results, walkthrough evidence, commit, pushed branch, PR URL, and CI outcome to the Firstmate status file.
