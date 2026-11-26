<p align="center">
  <img src="Assets/AppIcon-1024.png" width="136" height="136" alt="SparkBar Icon" />
</p>

<h1 align="center">SparkBar</h1>

<p align="center">
  <strong>Ultra-lightweight, 100% native macOS AI Spotlight Launcher (<code>⌥ + Space</code>) & Autonomous Tool Agent</strong><br/>
  Built with pure Swift, SwiftUI, and AppKit (<code>NSPanel</code>) — zero Electron bloat.
</p>

<p align="center">
  <a href="https://github.com/r0bledas/SparkBar/releases/latest">
    <img src="https://img.shields.io/github/v/release/r0bledas/SparkBar?style=flat-square&color=00b4d8" alt="Latest Release" />
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?style=flat-square" alt="Swift 6.0" />
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License" />
  </a>
</p>

---

**SparkBar** is an ultra-lightweight, 100% native macOS AI launcher and autonomous tool agent built with **Swift, SwiftUI, and AppKit** (`NSPanel`).

Press **`⌥ + Space`** (`Option + Space`) from anywhere on your Mac to summon a sleek, translucent Spotlight-style floating prompt bar. Unlike Electron-wrapped desktop AI apps that consume **800 MB – 1.5 GB of RAM**, SparkBar idles at **~25–35 MB of RAM** and opens in under **20ms**.

---

## 💬 Why This Exists (A Small Rant)

OpenAI had a good thing going with the original native macOS ChatGPT app and its instant `Option + Space` companion bar—and then they decided to migrate everything into the unified **Codex** app (`com.openai.codex`), relegating the old app to *"ChatGPT Classic"* and replacing a lightweight launcher with a full-blown **Electron super-app** that bundles Chat, Work, and an entire IDE workspace into a 1 GB+ RAM hog.

And the **Gemini** macOS app isn't the answer either. Sure, it exists as an alternative, but it hits you with a splash icon and a splash window when all you wanted was a prompt box.

When I press `⌥ + Space`, **I need it to be immediate.**
- I don't need splash icons or splash windows.
- I don't need an Electron wrapper burning a whole gigabyte of RAM in the background just to render a text box.
- I just want to press `⌥ + Space`, ask a question, search the live web, or have an autonomous agent run a local task—**instantly**—and get out of my way.

So I built **SparkBar**: pure native Swift, SwiftUI, and AppKit `NSPanel`. Zero splash screens, zero Electron, zero bloat.

---

## ✨ Features

* **Standalone Full-Screen / Resizable Chat Window (`⌘ + ⇧ + F`):**
  * Expand any conversation into a dedicated, resizable native macOS window with an integrated **History** sidebar and standard macOS titlebar double-click zoom (`performZoom`).
  * The floating Spotlight bar stays minimal and fixed-size (`520×105` collapsed, `520×520` expanded) with subtle circular corner **Maximize** and **Hide** controls that appear only when hovering over the top quarter.
* **Google Antigravity (AGY CLI) Zero-API-Key Provider:**
  * Use your **Google One / Antigravity** plan directly inside SparkBar with **zero metered API keys**.
  * Spawns `agy -p ... --output-format stream-json` on-demand per turn and exits cleanly when finished — keeping **0 MB idle RAM** overhead while streaming live responses, tools, and persistent multi-turn conversations (`--conversation <id>`).
  * Includes 1-click official `agy` binary download & update checks, multi-account Google email switching, automatic variant/effort grouping from `agy models`, and optional [`AGY-Portable`](https://github.com/r0bledas/AGY-Portable) USB folder isolation.
* **Grouped Multi-Provider Support (Zero Hardcoded Models):**
  * **Google Antigravity:** `Google Antigravity (AGY)`
  * **Cloud APIs:** `DeepSeek`, `OpenAI`, `OpenRouter`, `Anthropic Claude`, `Groq`, `Google Gemini`
  * **Local Runners (No API Key Required):** `Ollama`, `llama.cpp`, `LM Studio`, `MLX Server`, and `Custom OpenAI-Compatible` (optional API key)
  * Dynamically discovers models and Thinking Effort / variant levels (`Low`, `Medium`, `High`, `XHigh`, `Max`) directly from each provider.
* **Local API Endpoint (`Beta`):**
  * Optional built-in loopback HTTP/1.1 server (`127.0.0.1:11435` by default, zero external dependencies via `Network.framework`) exposing **OpenAI**, **OpenAI Responses**, **Anthropic**, **Ollama**, **Google Gemini REST**, and **llama.cpp** endpoints backed by SparkBar's active provider.
* **Standalone Native macOS Settings Window (`⌘ + ,`) & 1-Click GitHub Self-Update:**
  * Opens as an independent macOS `NSWindow` decoupled from the floating prompt bar.
  * Sync directly from `r0bledas/SparkBar` with a single click (`Update from GitHub…`) to pull `main`, build a Release `.app`, install to `/Applications/SparkBar.app`, and relaunch.
* **Smooth Window Dragging & Magnetic Snapping:**
  * Drag the floating panel freely with magnetic bottom-anchor snapping, `⌘`-locked axis alignment, and native trackpad haptic alignment ticks.
* **Image Attachments & Instant Speech-Bubble Previews:**
  * Drag & drop images, screenshots, or paste from clipboard (`⌘ + V`). Hovering any thumbnail displays a top-layer speech-bubble filename popover without layout shift.
* **Autonomous Tool Engine & Live Status Badges:**
  * Clean live indicators (`Searching…` → `Searched: <query>`, `Viewed: <url>`, `Running command…`) with native icons.
  * `web_search` & `fetch_url` — Live web search and readable page extraction.
  * `run_command`, `job_status`, `job_cancel` — Stateful login-shell execution (`cd` persists across turns) with background job tracking.
  * `render_pdf` & `pdf_info` — 1-call HTML/Markdown to PDF generation (`WKWebView.createPDF`) and `PDFKit` verification.
  * `read_file` / `write_file` / `list_directory` & `clipboard` — Fast local file and macOS pasteboard access.
  * **Zero-Discovery Host Environment Manifest:** Captures login shell `PATH` (`/bin/zsh -lc`, Homebrew, Node, Rust, Python) once at startup.
* **Persistent History & Markdown Logs (`⌘ + Y`):**
  * Automatically saves every thread in `~/Library/Application Support/SparkBar/conversations/` and exports clean `.md` logs in `~/Library/Application Support/SparkBar/logs/`.
* **Smooth Memoized Markdown, Clickable Links, Tables & LaTeX:**
  * Cached block rendering for stutter-free scrolling, underlined clickable hyperlinks (pointing-hand cursor + auto-hide floating panel on click), GitHub/ASCII tables, code blocks, and KaTeX math (`$$...$$` and `$...$`).

---

## 🔌 Local API Endpoint (Beta)

Enable **Settings (`⌘ + ,`) → Local API Endpoint `BETA`** to expose SparkBar's active LLM backend on `http://127.0.0.1:11435` (loopback-only, configurable port, streaming & non-streaming):

| Protocol | Base URL / Path | Supported Endpoints |
| :--- | :--- | :--- |
| **OpenAI** | `http://127.0.0.1:11435/v1` | `GET /v1/models`, `POST /v1/chat/completions`, `POST /v1/responses`, `POST /v1/completions` |
| **Anthropic** | `http://127.0.0.1:11435` | `POST /v1/messages` |
| **Ollama** | `http://127.0.0.1:11435` | `GET /api/tags`, `GET /api/version`, `POST /api/show`, `POST /api/chat`, `POST /api/generate` |
| **Google Gemini** | `http://127.0.0.1:11435/v1beta` | `GET /v1beta/models`, `POST /v1beta/models/{model}:generateContent`, `:streamGenerateContent` |
| **llama.cpp** | `http://127.0.0.1:11435/completion` | `POST /completion` |
| **Health** | `http://127.0.0.1:11435/health` | `GET /`, `GET /health` |

Quick check with `curl`:

```bash
# OpenAI Chat Completions
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"default","messages":[{"role":"user","content":"Hello from SparkBar!"}]}'

# Ollama Chat
curl http://127.0.0.1:11435/api/chat \
  -d '{"model":"default","stream":false,"messages":[{"role":"user","content":"Hello!"}]}'
```

---

## 🚀 Quick Start

### 1. Download Prebuilt macOS App
Grab the latest `SparkBar-vX.Y.Z.zip` from [**GitHub Releases**](https://github.com/r0bledas/SparkBar/releases/latest), unzip it, and move `SparkBar.app` into `/Applications`.

### 2. Build & Run from Source (Swift Package Manager)

```bash
git clone https://github.com/r0bledas/SparkBar.git
cd SparkBar
./Scripts/package_app.sh
cp -R dist/SparkBar.app /Applications/
open /Applications/SparkBar.app
```

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **`⌥ + Space`** (`Option + Space`) | Summon or hide SparkBar from any app or full-screen space |
| **`Return`** | Send prompt |
| **`⌘ + ⇧ + F`** | Open standalone Full Window with integrated History sidebar |
| **`Esc` / `⌘ + W`** | Dismiss floating panel (or close History view) |
| **`⌘ + N` / `⌘ + K`** | Save current thread to log & start a New Chat |
| **`⌘ + Y`** | Toggle History browser |
| **`⌘ + ,`** | Open Settings & API Keys |
| **`⌘ + Q`** | Quit SparkBar |

---

## 🔑 Configuring Providers & API Keys

1. **Zero-API-Key (Google Antigravity):** Select **Google Antigravity (AGY)** in Settings (`⌘ + ,`) and click **Download & Sign In**.
2. **Local Runners (No API Key):** Select **Ollama**, **llama.cpp**, **LM Studio**, **MLX Server**, or **Custom OpenAI-Compatible** in Settings.
3. **Cloud APIs:** Paste your API key in Settings (stored securely in macOS Keychain), or export `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `GROQ_API_KEY`, or `GEMINI_API_KEY`.

---

## 📄 License

Released under the [MIT License](LICENSE).
