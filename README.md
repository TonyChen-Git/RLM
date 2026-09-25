# LumaChat

LumaChat 是一套 macOS、local-first 的 Coding Agent。它保留使用者對
workspace、模型後端、權限、檔案變更與遠端主機的控制，並在既有的 Chat、
Plan/Agent、MCP、Projects、Tasks、Goals、Undo 與 Checkpoint 基礎上，補齊
接近 Codex Desktop/CLI 的工作流程與編排能力。

模型推論走使用者自行選擇的服務（Ollama、remote Ollama、OpenAI-compatible、
Anthropic-compatible 等）；本專案不宣稱提供 OpenAI 託管模型、雲端 fallback
或 proprietary Codex 服務。

> **目前狀態（2026-09-25）**：原始 master prompt 的 Phase A–H 開發範圍已完成，
> 最終合併 development gate 通過 744 項 Swift 測試（1 項環境性 skip、
> 0 failures）、optimized arm64 build、ad-hoc hardened signing、canonical ZIP、
> SBOM/provenance 與安全稽核。VS Code 17/17、GitHub Action 14/14 Node 測試也通過。
> `1.4.1` build `8` 仍是 development snapshot；沒有 Developer ID/notarization/stapling、正式
> update feed、live backend/SSH/real-browser acceptance 或正式長時間 soak 證據，
> 因此不是可對外宣稱的 production release。

## 能力總覽

- **Chat 與 Agent**：獨立的 Classic Chat / Agent runtime、Plan mode、持久化
  Session、Resume、Context 管理、工具呼叫、Approval、Undo 與 Checkpoint。
- **Projects、Tasks、Goals**：專案目錄、工作資料夾綁定、背景任務、Goal 進度、
  Task Fork、並行寫入隔離與 managed Git worktree lease。
- **Terminal、Git、Review**：Task-owned Darwin `forkpty`、多 terminal pane、
  bounded scrollback、訊號/resize/reconnect、封閉式 Advanced Git API、五種
  Review source、hunk/file Stage/Unstage/Revert、inline comments、Review Task
  與 provider-neutral Pull Request 流程。
- **每模型參數 Profile**：以 `backend/provider + endpoint + exact model id`
  命名空間保存獨立 profile。Auto recommendation 依 exact model → family →
  backend → generic fallback 解析，Custom override 永久保存；主畫面與 Settings
  共用同一份 state，所有 Chat/Agent/retry/resume/tool continuation 都使用有效
  profile。Capability 不支援的欄位會在 UI 停用或隱藏，且不會送進 request。
- **Subagents**：持久化 parent/child identity、priority/FIFO scheduler、全域/
  provider/model/parent 限額、timeout、cancellation、結果聚合與 read-only/
  writable isolation。
- **Skills、Plugins、Hooks、OAuth**：bounded `SKILL.md` discovery、獨立 plugin
  manifest/lifecycle、permission-derived sandbox、host-only lifecycle hooks、
  PKCE OAuth 與 Keychain-only token；plugin-owned MCP 與手動 MCP 分離。
- **Browser 與 Computer Use 2.0**：Task-owned Chromium/CDP profile、tabs/
  navigation、DOM/Accessibility、screenshot、network/download metadata、
  Browser annotations，以及需 Screen Recording/Accessibility、capture-bound
  approval 的安全視窗操作。
- **Automation 與 Remote Runner**：持久化 one-time/interval/cron/event
  automation、Task history、macOS notifications、受 known_hosts 與 Keychain
  約束的 SSH runner、16 個 bounded remote tools、Local/Worktree ↔ SSH handoff。
- **CLI、App Server、SDK、整合**：共享同一個 headless runtime 的 `lumachat` CLI、
  loopback-only authenticated App Server v1、Swift SDK、VS Code adapter、GitHub
  Action 與內建 artifact workflow Skills（PDF、document、spreadsheet、
  presentation、image、visualization、site）。
- **Release hardening**：project-local staging、archive/manifest/SBOM/provenance
  scripts、update feed/Ed25519 verifier/rollback installer、SecureStorage seam、
  macOS entitlements/privacy manifest 與 production-release workflow。Production
  feed/signing keys 未配置時，更新功能 fail closed。

## Phase 進度

原始 parity master prompt 定義八個開發階段：

| Phase | 主題 | 目前紀錄 |
| --- | --- | --- |
| A | Managed worktrees、`.git` pointer、handoff、writable isolation | Release gate 已有證據 |
| B | 真 PTY、Task Terminal、Advanced Git、Review、PR | Release gate 已有證據（1.4.0 為歷史 Phase B artifact；1.4.1 為目前合併 artifact） |
| C | Subagents 與 scheduler | 實作完成；合併 Swift/release development gate 通過 |
| D | Skills、plugins、hooks、OAuth | 實作完成；合併 Swift/release development gate 通過 |
| E | Browser/CDP、annotations、Computer Use 2.0 | 實作與自動化 gate 通過；real-browser/native UI acceptance 仍屬外部 gate |
| F | Automations、notifications、SSH Remote Runner | 實作與自動化 gate 通過；live SSH host、native UI 與長時間 soak 待外部驗證 |
| G | CLI、App Server、SDK、VS Code、GitHub Action、artifact workflows | Swift、Node、schema 與 development package gate 通過 |
| H | Release、update/rollback、sandbox/storage seam、cross-platform readiness | Development hardening gate 通過；production signing/notarization 與正式長時間 soak 待外部環境 |

以原始八個開發 phase 計算，目前為 **8/8（100% implementation complete）**。
這個百分比不等於 production Definition of Done；外部憑證、服務與長時間運行的
驗收項目仍保留如下方限制。

詳細的 requirement trace、分數與限制請見
[`docs/CODEX_FULL_PARITY_AUDIT.md`](docs/CODEX_FULL_PARITY_AUDIT.md) 與
[`docs/CODEX_REPLACEMENT_ROADMAP.md`](docs/CODEX_REPLACEMENT_ROADMAP.md)。各功能的
設計細節在 `docs/*_ARCHITECTURE.md`；未發布變更摘要在
[`docs/RELEASE_NOTES_UNRELEASED.md`](docs/RELEASE_NOTES_UNRELEASED.md)。

## 建置與執行

需求：macOS 14 或更新版本、Swift 6 toolchain，以及至少一個可連線且由使用者
設定的模型 backend。`Package.swift` 提供桌面、CLI shim、updater 與 SDK 產品：

```sh
# 建立 debug products
swift build --product LumaChatDesktop
swift build --product lumachat
swift build --product lumachat-updater

# 啟動桌面 App
swift run LumaChatDesktop

# CLI（會轉入同一個 Agent runtime）
swift run lumachat chat "請檢查目前專案"
swift run lumachat agent --workspace-path /absolute/project "執行任務"
swift run lumachat exec --workspace-path /absolute/project "swift test"
swift run lumachat tasks list

# 啟動 loopback App Server（預設 127.0.0.1:32189）
swift run lumachat server --token "$LUMACHAT_SERVER_TOKEN"
```

CLI 的完整 command、exit code、JSON/JSONL 限制請見
[`docs/CLI_ARCHITECTURE.md`](docs/CLI_ARCHITECTURE.md)；App Server v1 的 route 與
schema 請見 [`docs/APP_SERVER_ARCHITECTURE.md`](docs/APP_SERVER_ARCHITECTURE.md) 及
`Integrations/Schemas/`。

### 測試與 lint/typecheck

一般開發可用：

```sh
swift test
node --test Integrations/VSCode/test/*.test.js
node --test Integrations/GitHubAction/test/*.test.js
PYTHONPYCACHEPREFIX="$PWD/tmp/pycache" python3 -m py_compile Scripts/*.py
git diff --check
```

Release/soak script 會把 SwiftPM scratch、cache、test Application Support、
logs、artifacts 與 generated output 放在專案 `tmp/`：

```sh
LUMACHAT_RELEASE_MODE=development Scripts/release.sh
python3 Scripts/soak.py 2h --project-root "$PWD" --dry-run
python3 Scripts/security_audit.py --help
```

2026-09-25 的 `1.4.1` development gate 結果：archive contract 6/6、soak contract 4/4、
security report contract 1/1、Swift 744 tests（1 skip、0 failures）、VS Code
17/17、GitHub Action 14/14；optimized arm64 build、bundle/extracted-bundle、
signature、plist、canonical ZIP、SBOM/provenance 與 security audit 均通過。生成的
development ZIP SHA-256 為
`d7bd60cc09888ebf7eacf541bf1d866588a348084520e441b414996f6ff1bfa7`。
Production release 仍需要 Developer ID、notary profile、Ed25519 update key、
team ID、update feed/archive URL 與 `SOURCE_DATE_EPOCH`，並只能由明確設定的
環境變數提供。

## Persistence、profile 與 secrets

一般執行的持久資料在：

```text
~/Library/Application Support/LumaChat/
├── settings.json                 # Chat/backend 與每模型 Custom profiles
├── Conversations/                # Classic Chat
├── AgentSessions/                # Agent sessions/attachments
├── AgentProjects/                # project catalog/settings
├── AgentWorktrees/               # registry 與 managed checkouts
├── Extensions/                   # Skills/plugins/OAuth public metadata
├── Updates/                      # update preferences/state/journal
└── Runtime/tmp/                  # packaged app runtime scratch
```

Debug/test 可用 `LUMACHAT_APP_SUPPORT_PATH` 與
`LUMACHAT_RUNTIME_TMP_PATH` 指向專案內的 `tmp/` 隔離目錄。不要把 credentials、
browser profiles、release staging 或 test output 寫到 repository 外的 Desktop、
Downloads、`/tmp` 或 `/var/tmp`。

Model Profile 的規則如下：

1. Profile key 至少包含 API provider、concrete backend、normalized endpoint 與
   trim 後的 exact model ID，因此同名模型不會互相覆蓋。
2. 沒有 Custom record 就是 Auto；每次使用會依 capabilities 重新計算 context、
   max output、temperature、top-p/top-k/min-p、penalties、Thinking、Reasoning
   Effort 與 Preserve Thinking。
3. 使用者改任何控制項會立即將完整有效設定寫回既有 `settings.json`，狀態變成
   Custom；切換模型、重啟 App、retry、resume、regenerate 與 Agent 多輪 tool-call
   都會恢復同一份設定。
4. Reset to Auto 只刪除該 key 的 override，重新套用目前 backend/model/capability
   推薦值。
5. backend/model 的最大 context 與 LumaChat effective context 分開處理；所有
   numeric values 在保存與 request encode 前都會 validation/clamp，effective
   context 不會超過後端上限。
6. OAuth、SSH、GitHub 與 App Server tokens 只走 Keychain/SecretStorage；不進
   `settings.json`、Session 或 model context。

完整規則與 request ownership 請見
[`docs/MODEL_PARAMETER_PROFILES.md`](docs/MODEL_PARAMETER_PROFILES.md)。

## Security boundary

所有檔案、process、network、browser、remote、plugin 與 external side effect
都必須經過 Task scope、permission/approval、bounded input/output、path/symlink
檢查與 redaction。Model 只能提供受限的資料/選項；backend、workspace、runner、
profile 與 browser authority 由 host 設定決定。Structured tools 優先於任意 shell
或 pixel automation；`.git`、credentials、AppleDouble `._*`、symlink/special
files 與不明確的第三方狀態 fail closed。

App Server 僅允許 loopback bind、Bearer token、bounded JSON/SSE 與 monotonic replay。
VS Code/GitHub adapters 不包含 provider client，也沒有 cloud fallback。Remote PTY
目前是 one-shot；persistent remote terminal、secure relay、SSH→SSH 與 hosted
runner 仍是明確的未實作 seam。

## Repository map

```text
Sources/LumaChat/              Desktop UI、Chat、Agent、providers、tools、persistence
Sources/LumaUpdateCore/        Update manifest verification/installer core
Sources/LumaChatSDK/           App Server v1 Swift client/protocol
Sources/LumaChatCLIShim/       Dependency-free lumachat launcher
Sources/LumaChatUpdater/       Standalone signed-update helper
Tests/LumaChatTests/            Swift regression and focused phase suites
Integrations/VSCode/            VS Code adapter + Node tests
Integrations/GitHubAction/      GitHub Action + Node/security tests
Integrations/Schemas/           Language-neutral App Server schemas/routes
Extensions/Builtin/             Artifact workflow plugin and seven Skills
Scripts/                        Build, release, feed, audit and soak tooling
AppBundle/                      Info.plist, entitlements, privacy manifest, icons
docs/                           Architecture, roadmap, audit and release notes
```

## Known limitations

- Phase C–H 合併 development gate 與十種 deterministic failure scenarios 已
  通過；2h/8h/24h/multi-day 正式 soak 尚未執行。Soak dry-run 只證明 profile、
  test inventory 與精確 selector 契約有效，不代表時間門檻已達成。
- live SSH host、真實 Ollama/OpenAI-compatible backend、真實 Chromium、native
  Computer Use/UI、VS Code 與 GitHub hosted runner 仍需要各自授權環境的 acceptance。
- Production Developer ID/notarization/update feed 未配置時只能做 development/
  ad-hoc build；不能把 development artifact 當成可自動更新的正式版本。
- Remote runner 需要使用者管理的 SSH host、strict `known_hosts` 與 Keychain
  credential；沒有安全 relay 或雲端 fallback。
- macOS native Computer Use 需要使用者主動授予 Screen Recording/Accessibility，
  並維持 capture-bound approval；它不是通用 GUI automation。
- App Server mutation idempotency cache 是 process-bounded；durable Task 會保留，
  但重啟後不承諾恢復舊的 response cache。

## Further reading

- [1.4.1 development release notes](docs/RELEASE_NOTES_1.4.1.md)
- [Full parity audit](docs/CODEX_FULL_PARITY_AUDIT.md)
- [Replacement roadmap](docs/CODEX_REPLACEMENT_ROADMAP.md)
- [Model parameter profiles](docs/MODEL_PARAMETER_PROFILES.md)
- [Terminal architecture](docs/TERMINAL_ARCHITECTURE.md)
- [Worktree architecture](docs/WORKTREE_ARCHITECTURE.md)
- [Plugin architecture](docs/PLUGIN_ARCHITECTURE.md)
- [Browser architecture](docs/BROWSER_ARCHITECTURE.md)
- [Automation/remote architecture](docs/AUTOMATION_REMOTE_ARCHITECTURE.md)
- [CLI architecture](docs/CLI_ARCHITECTURE.md)
- [App Server architecture](docs/APP_SERVER_ARCHITECTURE.md)
- [VS Code adapter](Integrations/VSCode/README.md)
- [GitHub Action](Integrations/GitHubAction/README.md)
