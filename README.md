# ⚡ SparkBar

**SparkBar** is an ultra-lightweight, 100% native macOS AI launcher and autonomous tool agent built with **Swift, SwiftUI, and AppKit** (`NSPanel`).

Press **`⌥ + Space`** (`Option + Space`) from anywhere on your Mac to summon a sleek, translucent Spotlight-style floating prompt bar. Unlike Electron-wrapped desktop AI apps that consume **800 MB – 1.5 GB of RAM**, SparkBar idles at **~25–35 MB of RAM** and opens in under **20ms**.

---

## ✨ Features

* **Featherweight Native Architecture:** Pure Swift & AppKit `NSPanel` with `.nonactivatingPanel` and `NSVisualEffectView` HUD blur—zero Chromium/Electron bloat.
* **Instant Global Hotkey (`⌥ + Space`):** Registered via native macOS Carbon Event Manager (`RegisterEventHotKey`). Press `Option + Space` to summon or dismiss, or `Esc` to hide.
* **Hermes Agent & OpenCode-Inspired Tool Engine:**
  * **Server-Side Web Search:** Supports OpenRouter `:online` grounding, DeepSeek, and Perplexity out of the box with zero local harness overhead.
  * **Native Autonomous Function Calling Loop:** Multi-turn tool execution built directly in Swift:
    * `web_search` — Live web search via DuckDuckGo HTML & Instant Answer API.
    * `fetch_url` — Clean text extraction from any web page.
    * `run_command` — Execute local shell commands (`zsh`) with timeout protection.
    * `read_file` / `write_file` / `list_directory` — Fast local file system inspection and editing.
    * `clipboard` — Read from or write directly to the macOS clipboard (`NSPasteboard`).
* **Multi-Provider Streaming (`URLSession` Async SSE):**
  * **DeepSeek** (`deepseek-chat`, `deepseek-reasoner` with collapsible Thought Process view)
  * **OpenAI** (`gpt-4o-mini`, `gpt-4o`, `gpt-4.1`, `o3-mini`)
  * **OpenRouter** (`deepseek/deepseek-chat:online`, `anthropic/claude-3.5-sonnet:online`, etc.)
  * **Anthropic Claude** (Native `/v1/messages` streaming & tool use)
  * **Groq**, **Google Gemini**, and **Local Ollama / LM Studio** (`http://127.0.0.1:11434/v1`)
* **Rich Markdown & Code Blocks:** Syntax-styled code blocks with one-click copy buttons.

---

## 🚀 Quick Start

### 1. Build & Run via Swift Package Manager

```bash
git clone https://github.com/r0bledas/SparkBar.git
cd SparkBar
swift run
```

### 2. Package as a Standalone macOS `.app` Bundle

```bash
chmod +x Scripts/package_app.sh
./Scripts/package_app.sh
open dist/SparkBar.app
```

You can also copy `dist/SparkBar.app` directly into `/Applications`:

```bash
cp -R dist/SparkBar.app /Applications/
```

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **`⌥ + Space`** (`Option + Space`) | Summon or hide SparkBar from any app or full-screen space |
| **`Return`** | Send prompt |
| **`Esc`** | Dismiss floating panel |
| **`⌘ + K`** | Clear conversation & start fresh |
| **`⌘ + ,`** | Open Settings & API Keys |
| **`⌘ + Q`** | Quit SparkBar |

---

## 🔑 Configuring API Keys

You can configure your API keys in two ways:
1. **In-App Settings (`⌘ + ,`):** Select your provider (DeepSeek, OpenAI, OpenRouter, Anthropic, Groq, Gemini, or Ollama) and paste your key. Keys are stored in the macOS Keychain.
2. **Environment Variables:** SparkBar automatically detects `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `GROQ_API_KEY`, and `GEMINI_API_KEY`.

---

## 📄 License

Released under the [MIT License](LICENSE).
