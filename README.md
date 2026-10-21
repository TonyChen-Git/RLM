# LumaChat

LumaChat 是一套 macOS、local-first 的 Coding Agent。它保留使用者對
workspace、模型後端、權限、檔案變更與遠端主機的控制，並在既有的 Chat、
Plan/Agent、MCP、Projects、Tasks、Goals、Undo 與 Checkpoint 基礎上，補齊
接近 Codex Desktop/CLI 的工作流程與編排能力。

模型推論走使用者自行選擇的服務（Ollama、remote Ollama、OpenAI-compatible、
Anthropic-compatible 等）；本專案不宣稱提供 OpenAI 託管模型、雲端 fallback
或 proprietary Codex 服務。

> **目前版本（2026-10-19）**：[LumaChat 1.4.7 build 14](https://github.com/TonyChen-Git/RLM/releases/tag/v1.4.7)
> 已從 `main` 發佈為一般正式 GitHub Release（非 prerelease），整合 Phase I–Q 與後續修復。
> 完整本機 gate 通過 896 項 Swift、48 項 Python（各 1 skip、0 failures）；
> macOS CI 896 項（2 skips）及 Linux worker CI 10 項皆零失敗。
> 發佈後也核對 exact `v1.4.7` tag CI：macOS 896 項（2 skips、0 failures）及 Linux worker 10/10 通過。
> arm64 封裝、安全檢查與有限原生 UI smoke 通過，五個上傳產物的大小與雜湊已核對。
> 詳見 [1.4.7 版本說明](docs/RELEASE_NOTES_1.4.7.md)。

> **10 月 20 日驗收更新**：同一封裝通過真實 Chrome 五項操作與 Task／截圖重啟保留，
> 語音播放／停止控制及 Computer Use 安全提示已檢查；模型與網頁使用本機 fixture。
> 本版 2h 長測通過；8h 尚未合格，第三次嘗試發現 pip 互動測試逾時。
> 10 月 21 日測試流程修正通過 22 項 PTY 測試（1 skip、0 failures）及兩次 pip 重跑；
> 產品程式碼與已發佈版相同。外部測試目標依使用者決定暫不提供。

> **私用驗收範圍（2026-10-20 更新）**：依使用者「不用簽，我私用」的決定，
> 沿用已驗證的 ad-hoc 封裝。Apple Developer ID／公證／stapling、正式更新 feed
> 與 signed-update／rollback 外部驗收列為 `not_required_for_private_use`，未執行也未標為通過。
> 未執行的功能外部驗收與本版長測資格仍須各自取得證據；更新信任與權限檢查維持原有行為。
> 使用者目前「先不提供」外部模型、SSH、MCP 與測試 repository 目標；相關 live acceptance
> 記為 `deferred_by_user`，未執行也未標為通過。
> 各版本證據分別保留於 [1.4.6 版本說明](docs/RELEASE_NOTES_1.4.6.md)、
> [開發整合紀錄](docs/RELEASE_NOTES_UNRELEASED.md) 與 [差異稽核](docs/CODEX_FULL_PARITY_AUDIT.md)。

## 能力總覽

- **Chat 與 Agent**：獨立的 Classic Chat / Agent runtime、Plan mode、持久化
  Session、Resume、Context 管理、工具呼叫、Approval、Undo 與 Checkpoint。
  執行中可送入下一模型回合的文字 Steer，或將後續文字／圖片訊息放入可編輯的持久 Queue；
  Settings 決定預設動作，`⌘↩` 與 `⌘⇧↩` 分別使用預設及替代動作。
- **Projects、Tasks、Goals**：專案目錄、工作資料夾綁定、背景任務、Goal 進度、
  Task Fork、並行寫入隔離與 managed Git worktree lease。Fork 只帶入最多 80 則、
  64 KiB、經敏感資訊遮蔽的文字脈絡；Side chat 是無工具、暫時性的 Task 摘要問答，可使用明確選取的唯讀檔案／圖片快照。
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
  PKCE OAuth 與 Keychain-only token；plugin-owned MCP 與手動 MCP 分離。MCP 設定可
  查看連線診斷、Reconnect 與 Refresh Discovery。
- **Browser 與 Computer Use 2.0**：Task-owned Chromium/CDP profile、tabs/
  navigation、DOM/Accessibility、screenshot、network/download metadata、
  Browser annotations，以及需 Screen Recording/Accessibility、capture-bound
  approval 的安全視窗操作。
- **Automation 與 Remote Runner**：持久化 one-time/interval/cron/event
  automation、Task history、macOS notifications、受 known_hosts 與 Keychain
  約束的 SSH runner、16 個 bounded remote tools、Local/Worktree ↔ SSH handoff。
- **CLI、App Server、SDK、整合**：共享同一個 headless runtime 的 `lumachat` CLI、
  loopback-only authenticated App Server v1、磁碟 mutation journal、有限的 SSE
  live buffer、Swift SDK、VS Code adapter、GitHub
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
| B | 真 PTY、Task Terminal、Advanced Git、Review、PR | Release gate 已有證據（1.4.0 為歷史 Phase B artifact；1.4.1 為歷史合併 artifact） |
| C | Subagents 與 scheduler | 實作完成；合併 Swift/release development gate 通過 |
| D | Skills、plugins、hooks、OAuth | 實作完成；合併 Swift/release development gate 通過 |
| E | Browser/CDP、annotations、Computer Use 2.0 | 實作與自動化 gate 通過；10 月 14 日封裝版通過真實 Chrome 本機 fixture 5/5 與 annotation UI；外部模型／Computer Use 待驗收 |
| F | Automations、notifications、SSH Remote Runner | 實作與自動化 gate 通過；live SSH host、native UI 與長時間 soak 待外部驗證 |
| G | CLI、App Server、SDK、VS Code、GitHub Action、artifact workflows | Swift、Node、schema 與 development package gate 通過 |
| H | Release、update/rollback、sandbox/storage seam、cross-platform readiness | Development hardening gate 通過；版本綁定長時間 soak 待完成；production signing/notarization 不列私用完成條件 |

以原始八個開發 phase 計算，目前為 **8/8（100% implementation complete）**。
這個百分比不等於 production Definition of Done；外部憑證、服務與長時間運行的
驗收項目仍保留如下方限制。

詳細的 requirement trace、分數與限制請見
[`docs/CODEX_FULL_PARITY_AUDIT.md`](docs/CODEX_FULL_PARITY_AUDIT.md) 與
[`docs/CODEX_REPLACEMENT_ROADMAP.md`](docs/CODEX_REPLACEMENT_ROADMAP.md)。各功能的
設計細節在 `docs/*_ARCHITECTURE.md`；未發布變更摘要在
[`docs/RELEASE_NOTES_UNRELEASED.md`](docs/RELEASE_NOTES_UNRELEASED.md)。

## 建置與執行

需求：macOS 14 或更新版本，以及至少一個可連線且由使用者設定的模型 backend。
原始碼建置的工具鏈以發行與 CI 記錄為準：本機發行 gate 使用 Apple Swift 6.4，
目前 CI 固定 Xcode 26.3（build 17C529）／Apple Swift 6.2.4；1.4.7 最終候選
hosted gate 已通過 896 項 Swift 測試（2 skips、0 failures）與最佳化編譯。
其他 Swift 6 小版本未一律驗證；版本相容性與
失敗紀錄見 [1.4.6 版本說明](docs/RELEASE_NOTES_1.4.6.md) 與
[1.4.7 修正版進度](docs/RELEASE_NOTES_1.4.7.md)。
`Package.swift` 提供桌面、CLI shim、updater 與 SDK 產品：

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

發行前須同步更新 [AppBundle/Info.plist](AppBundle/Info.plist) 的
`CFBundleShortVersionString`／`CFBundleVersion`，以及
[LumaCLIRunner.swift](Sources/LumaChat/Headless/CLI/LumaCLIRunner.swift) 的
`currentVersion`。Release gate 會執行解壓封裝內的 CLI 版本檢查，拒絕 App 與
CLI 版本不一致的封裝。

Release/soak script 會把 SwiftPM scratch、cache、test Application Support、
logs、artifacts 與 generated output 放在專案 `tmp/`：

```sh
LUMACHAT_RELEASE_MODE=development Scripts/release.sh
python3 Scripts/soak.py 2h --project-root "$PWD" --dry-run
python3 Scripts/security_audit.py --help
```

2026-10-15 的 `1.4.6` build `13` 完整 release gate 通過 Swift 886 tests
（1 skip、0 failures，273.489 秒）、Python 48 tests（1 Linux-only skip、
0 failures）、VS Code 17/17 與 GitHub Action 14/14。最佳化 arm64 編譯、
ad-hoc 簽章、ZIP／解壓驗證、CLI 版本檢查與安全稽核通過。新封裝的隔離
Task 畫面、About 1.4.6 (13) 與正常退出已驗證；本次 smoke 未執行 Browser、
模型或麥克風操作。ZIP SHA-256：
`0d5112022bee7d3c266a32cd0ef25692d1a34cc112411387805da39a5cdb026a`。
發佈與後續驗收狀態見 [1.4.6 版本說明](docs/RELEASE_NOTES_1.4.6.md)。

以下為版本提升前的歷史證據。2026-10-14 `1.4.5` development gate
通過 Swift 886 tests（1 environment skip、
0 failures，258.252 秒）及 Python archive/soak/security/worker 48 tests
（1 Linux-only skip、0 failures）。完成 arm64 最佳化建置（197.62 秒）、
ad-hoc 簽章、ZIP／解壓驗證及安全稽核；340 個 source/test/script/config 檔案
記錄於凍結 receipt。新 development ZIP SHA-256：
`7c5c0716e30becfbb600f06db6f37516cc5560cca88783701aa5019b7a4de3b0`。

Browser 診斷確認持續使用的 CDP WebSocket 被誤設的 30 秒 URLSession resource
期限關閉；已移除該覆寫，保留每項命令的 30 秒上限，並補齊已關閉 socket 與
接收取消的失敗清理。5 項真實 loopback lifecycle 測試納入上述 gate 與 Browser
soak filter；暫時 DEBUG trace 已移除。debug App 的真實 Chrome 5/5 操作通過後，
新最佳化封裝也完成 open、snapshot、find、screenshot、close；授權前觀察到至少
68.38 秒等待，持久紀錄的命令間隔為 79.31 秒，snapshot 耗時 0.059 秒。
1280×657 PNG 已檢視，原生 Browser annotation pane 通過 accessibility 與實際
UI 截圖檢視；App 正常退出、Chrome 與 fixture server 已清理。模型與網頁均為
本機 fixture，不構成外部供應商驗收。證據見 `tmp/phase-iq-oct14-release.log`、
`tmp/phase-iq-oct14-browser-fixed/acceptance.json` 與
`tmp/phase-iq-oct14-browser-package/acceptance.json`。

2026-10-12 的 Phase I–Q 復原與防重播修正通過 Swift 881 tests（1 environment
skip、0 failures，209.124 秒）、Python archive/soak/security/worker 48 tests
（1 Linux-only skip、0 failures）、VS Code 17/17 與 GitHub Action 14/14。
完成 arm64 最佳化建置、ad-hoc 簽章、ZIP/解壓驗證與安全稽核；339 個凍結的
source/test/script/config 檔案對應該次封裝。開發 ZIP SHA-256：
`c332aa0d10afae62054a38fc21d60f3d8c4f0d7a2f06314e75a3c12997e3c68d`。
封裝版 Steer 逐筆檢視／複製／移除／重啟保留，以及匯入儲存／重啟／預覽還原／
重複還原拒絕均通過原生 accessibility 驗收。這些隔離的合成 Task 未送出模型
訊息，也未驗證像素版面。第一次 App 退出為 0；第二次退出未取得可證明結果。
完整證據、歷史 Browser 截圖逾時與兩次未合格的 2h soak 紀錄見
[差異稽核](docs/CODEX_FULL_PARITY_AUDIT.md)。以下保留歷史封裝紀錄。

2026-10-04 的 Phase I–Q 整合修正封裝通過 Swift 852 tests（1 skip、
0 failures）與 Python archive/soak/security/worker 24 tests（1 Linux-only skip）。
後續修正 soak 測試後，完整 Swift 回歸再次通過；擴充後的 Python 26 tests
（1 Linux-only skip）亦通過。
VS Code 17/17 與 GitHub Action 14/14 通過。完成 arm64 最佳化建置、ad-hoc 簽章、
ZIP/解壓驗證與安全稽核。封裝版 Queue 編輯、失敗保留草稿、重試清除錯誤及
重啟復原通過；測試採隔離的合成 Task，未呼叫外部模型。該次開發 ZIP SHA-256：
`e8696c66291824adaa6a0840bf37e9cf78da240095c6dfdae690bef48e7f6d76`。
上述封裝與 852 項 Swift 結果不涵蓋後續 Steer、匯入還原及 webhook ledger 修正。

2026-09-30 的 `1.4.5` development package 通過 archive contract 7/7、
soak contract 4/4、security-audit contract 3/3、Swift 794 tests（1 skip、
0 failures）、VS Code 17/17 與 GitHub Action 14/14；完成 arm64 最佳化建置、
ad-hoc 簽章、ZIP/解壓驗證、SBOM/provenance 與安全稽核。Chat、Plan、Agent
空白畫面的封裝版 UI smoke 已通過；真實 Qwen/vLLM 連線與長對話、Approval、Queue
狀態仍待驗收。ZIP SHA-256 為
`e0db363db1ab4ef17b49430562739eb306a4f164b34991998309d6bee19c4541`。

2026-09-29 的 `1.4.4` development package 通過 archive contract 7/7、
soak contract 4/4、security-audit contract 3/3、Swift 792 tests（1 skip、
0 failures）、VS Code 17/17 與 GitHub Action 14/14；完成 arm64 最佳化建置、
ad-hoc 簽章、ZIP/解壓驗證、SBOM/provenance 與安全稽核。ZIP SHA-256 為
`90a5658270adb9b032c8a0e87991a4499756460e643ca72e4bd562d8f7c0e859`。
封裝版原生 UI smoke 與使用者 vLLM 主機連線仍待驗收。

2026-09-27 的 `1.4.2` development package 驗證結果：archive contract 7/7、
soak contract 4/4、security-audit contract 3/3、Swift 745 tests（1 skip、
0 failures）；optimized arm64 build、ad-hoc signed app、ZIP/archive 驗證及
SBOM/provenance 均完成。Release script 的最後來源稽核初次遇到 SwiftPM 產生的
`.build/debug` symlink；排除根目錄的生成 `.build` 並通過定向測試後，直接安全稽核
通過。完整 release script 未重跑。ZIP SHA-256 為
`8dcbea2a992a3aac7c8d28b55c52c779b47c9990136dded5277d6cd74e6f6ad7`。
封裝版原生 UI smoke 尚待完成。

以下是 **歷史的** 2026-09-25 `1.4.1` development gate 結果：
archive contract 6/6、soak contract 4/4、
security report contract 1/1、Swift 744 tests（1 skip、0 failures）、VS Code
17/17、GitHub Action 14/14；optimized arm64 build、bundle/extracted-bundle、
signature、plist、canonical ZIP、SBOM/provenance 與 security audit 均通過。生成的
development ZIP SHA-256 為
`d7bd60cc09888ebf7eacf541bf1d866588a348084520e441b414996f6ff1bfa7`。
未來若啟用 production distribution，仍需要 Developer ID、notary profile、Ed25519 update key、
team ID、update feed/archive URL 與 `SOURCE_DATE_EPOCH`，並只能由明確設定的
環境變數提供。

## Persistence、profile 與 secrets

一般執行的持久資料在：

```text
~/Library/Application Support/LumaChat/
├── settings.json                 # Chat/backend 與每模型 Custom profiles
├── Conversations/                # Classic Chat
├── AgentSessions/                # Agent sessions/attachments/queued follow-ups
├── AgentProjects/                # project catalog/settings
├── AgentMemories/                # opt-in、Project-scoped reviewed memories
├── AgentWorktrees/               # registry 與 managed checkouts
├── AppServer/mutations.json       # App Server mutation request journal
├── Extensions/                   # Skills/plugins/OAuth public metadata
├── Updates/                      # update preferences/state/journal
└── Runtime/tmp/                  # packaged app runtime scratch
```

Debug/test 可用 `LUMACHAT_APP_SUPPORT_PATH` 與
`LUMACHAT_RUNTIME_TMP_PATH` 指向專案內的 `tmp/` 隔離目錄。不要把 credentials、
browser profiles、release staging 或 test output 寫到 repository 外的 Desktop、
Downloads、`/tmp` 或 `/var/tmp`。

封裝版的手動 UI smoke 請從 repository 執行
`Scripts/ui_smoke.sh [path/to/LumaChat.app]`。腳本會在 `tmp/` 建立帶標記的
暫時 profile，以 `LUMACHAT_UI_SMOKE_PROFILE` 啟動封裝版，並在 App 結束後只
清理該次建立的 profile。封裝版不採用 debug/test 的
`LUMACHAT_APP_SUPPORT_PATH`；直接開啟封裝版測試會使用正式的 Project catalog。
目前封裝版已包含隔離能力標記；舊的 `1.4.1` 封裝版缺少該標記，
腳本會在啟動前拒絕它。

依腳本列出的 checklist 手動檢查 Chat、Plan、Agent 的底部 Composer，
包含空白 Task、視窗縮放、側邊欄，以及可用時的長對話、Approval 與 Queue。
Plan 的唯讀 footer 應緊接 Composer 下方；腳本只提供隔離 profile。

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

## 本機記憶與專案指令匯入（開發原始碼）

Agent 設定中的本機記憶及背景建議各自預設關閉；啟用後仍須對 Project 和
Task 分別開啟。使用者可在 Task 記憶面板輸入提案，或讓本機背景掃描只從已
完成、閒置且允許貢獻記憶的 Task 擷取明確的「記住／偏好／工作流程」語句。
建議附來源、分類並可跨 Project 搜尋；使用者審閱及核准後，相關的已核准
內容才會在下一次執行時作為有界暫時上下文傳給當前模型供應商。記憶依
Project ID 存於本機，不寫進 Task 對話歷史；可以編輯、刪除或清空。
背景掃描不呼叫模型，也不保存音訊。詳見
[`docs/LOCAL_MEMORY_ARCHITECTURE.md`](docs/LOCAL_MEMORY_ARCHITECTURE.md)。
刪除 Project 時會一併清理其本機記憶檔。

Project Settings 可預覽 `CLAUDE.md` 的 Project 內參照、舊版 `.cursorrules`、
Cursor `.mdc` 規則和外部 Project 設定摘要；`.mdc` 啟用範圍獨立持久化。
使用者也能選取 Claude Code JSONL 或 Cursor Markdown 聊天匯出，審閱後匯入
為唯文字 Task。匯入不執行 hooks 或 commands，也不帶入憑證與原有工具權限。
詳見 [`docs/PROJECT_IMPORT_ARCHITECTURE.md`](docs/PROJECT_IMPORT_ARCHITECTURE.md)。

## Security boundary

所有檔案、process、network、browser、remote、plugin 與 external side effect
都必須經過 Task scope、permission/approval、bounded input/output、path/symlink
檢查與 redaction。Model 只能提供受限的資料/選項；backend、workspace、runner、
profile 與 browser authority 由 host 設定決定。Structured tools 優先於任意 shell
或 pixel automation；`.git`、credentials、AppleDouble `._*`、symlink/special
files 與不明確的第三方狀態 fail closed。

App Server 僅允許 loopback bind、Bearer token、bounded JSON/SSE 與 monotonic replay。
目前開發原始碼以磁碟 journal 保留 mutation request ID 與完成回應，支援重啟後在
保留範圍內重播；未確定是否完成的操作會拒絕重試。Approval 決策接受後沒有
durable 完成 receipt，同一 request ID 重送會得到 409 uncertain。SSE live queue
以單筆事件上限推導保守的累計位元組上限，過慢的 subscriber 會收到明確失效結果。
VS Code/GitHub adapters 不包含 provider client，也沒有 cloud fallback。Remote PTY
的 `remote_pty_run` 工具仍是 one-shot；SSH Task Terminal UI 已有持續互動連線。
它在 App 重啟後只恢復 disconnected metadata，按 Reconnect 會建立新 shell，
不會重新附著舊程序或還原舊 scrollback。secure relay、SSH→SSH 與 hosted
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

- Phase I–Q 的 10 月 14 日 886-test development gate 與新封裝已通過；
  10 月 12 日封裝的 Steer／匯入還原 accessibility 驗收另有保留證據。
  2026-10-04 首次 2h 本機 soak 揭露的測試同步問題
  已修復；第二次 run 在 60 個完整 cycles、481 個 shards 後中斷，沒有完成結算，
  兩次紀錄均不合格且原樣保留。後續 10 月 14 日的 1.4.5 整合來源，以及
  10 月 15 日精確的 1.4.6 發行來源，分別取得合格的 2h 結果；兩個序列的
  8h 均中斷，24h／72h 未開始。目前沒有仍在執行的序列，1.4.7 尚無
  自己的 qualifying soak。新 run 不沿用舊 run 時數或 cycles；完成與
  qualification 檢查通過前不算驗收。證據見
  [1.4.6 驗證紀錄](docs/validation/1.4.6.json)。本機整合／fixture soak
  不替代外部服務驗收；dry-run 只證明 profile、inventory 與 selector 契約有效。
- live SSH host、真實 Ollama/OpenAI-compatible backend、native Computer Use、
  VS Code 與 GitHub hosted runner 仍需要各自授權環境的 acceptance。
  Browser 的 30 秒 WebSocket resource 期限問題已修正，新最佳化封裝以真實
  Chrome 完成本機 fixture 的 5/5 操作，並檢視 PNG 與原生 annotation UI。
  這不構成真實模型／外部供應商驗收。
- Production Developer ID/notarization/update feed 未配置時只能做 development/
  ad-hoc build；不能把 development artifact 當成可自動更新的正式版本。
- Remote runner 需要使用者管理的 SSH host、strict `known_hosts` 與 Keychain
  credential；沒有安全 relay 或雲端 fallback。
- 執行中 Queue 可接受文字與圖片，Steer 的接受 receipt 會先持久化；崩潰後無法
  證實已送出的訊息會明確標記為 uncertain，不自動重送。Side chat 可使用明確選取
  的有界唯讀檔案／圖片快照，仍不具工具、寫入或 Approval 權限。最新 Steer 復原
  可逐筆檢視遮蔽後文字，手動複製至原 Task 草稿或移除；新封裝 accessibility
  驗收已通過，外部模型送出與完整像素版面驗收仍待執行。
- 本機記憶的背景建議目前採有限的本機明確語句規則；封裝版 UI smoke 已通過，
  真實模型與長時間驗收仍待執行。
  Claude Code/Cursor 匯入支援有界指令參照、`.mdc` 範圍與使用者選取的文字聊天；
  外部權限、hooks、MCP 憑證和其他聊天匯出格式不會映射到 LumaChat；
  最新單次匯入還原已通過新封裝 accessibility 驗收，真實供應商匯出驗收仍待執行。
  自管 Linux worker、系統離線語音、GitLab PR、GitHub webhook 與 plugin/OAuth
  強化已有歷史開發版封裝；後續修正與外部驗收另列於差異稽核。
  最小 worker 支援命令工作與文字 patch 接手；完整遠端 Agent runtime、二進位
  patch 接手及託管 Cloud 不在此版本範圍。互動式 SSH Terminal 仍待真實主機、封裝版 UI、
  主機重啟／網路故障及長時間 soak 驗收。
- 自管 Linux worker 需先由主機管理者檢視並安裝為
  `/usr/local/bin/lumachat-worker`；Task 以既有 SSH runner 的主機身分與憑證
  呼叫這個固定路徑。安裝與網路隔離需求見
  [Phase L–Q 架構與驗收邊界](docs/PHASE_L_Q_ARCHITECTURE.md)。
- macOS native Computer Use 需要使用者主動授予 Screen Recording/Accessibility，
  並維持 capture-bound approval；它不是通用 GUI automation。
- App Server 的 durable mutation journal 與 SSE live-buffer 位元組上限已在
  開發原始碼補上；journal 只重播保留中的已完成回應，
  舊的完成項目可能被逐出，未確定結果會 fail closed；這不是全面的 exactly-once
  保證。SSE event replay 仍限目前 server process。
  正式環境、長時間與外部 client 的驗收尚未完成。

## Further reading

- [1.4.7 patch release preparation](docs/RELEASE_NOTES_1.4.7.md)
- [1.4.6 release notes](docs/RELEASE_NOTES_1.4.6.md)
- [1.4.5 development prerelease notes](docs/RELEASE_NOTES_1.4.5.md)
- [1.4.4 development prerelease notes](docs/RELEASE_NOTES_1.4.4.md)
- [1.4.3 historical development prerelease notes](docs/RELEASE_NOTES_1.4.3.md)
- [1.4.2 historical development candidate notes](docs/RELEASE_NOTES_1.4.2.md)
- [1.4.1 historical development release notes](docs/RELEASE_NOTES_1.4.1.md)
- [Full parity audit](docs/CODEX_FULL_PARITY_AUDIT.md)
- [Replacement roadmap](docs/CODEX_REPLACEMENT_ROADMAP.md)
- [Model parameter profiles](docs/MODEL_PARAMETER_PROFILES.md)
- [Terminal architecture](docs/TERMINAL_ARCHITECTURE.md)
- [Worktree architecture](docs/WORKTREE_ARCHITECTURE.md)
- [Plugin architecture](docs/PLUGIN_ARCHITECTURE.md)
- [Browser architecture](docs/BROWSER_ARCHITECTURE.md)
- [Automation/remote architecture](docs/AUTOMATION_REMOTE_ARCHITECTURE.md)
- [Phase L–Q implementation and acceptance](docs/PHASE_L_Q_ARCHITECTURE.md)
- [CLI architecture](docs/CLI_ARCHITECTURE.md)
- [App Server architecture](docs/APP_SERVER_ARCHITECTURE.md)
- [VS Code adapter](Integrations/VSCode/README.md)
- [GitHub Action](Integrations/GitHubAction/README.md)
