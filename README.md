<p align="center">
  <img src="docs/assets/logo-rounded.png" alt="Episteme logo" width="132">
</p>

<h1 align="center">Episteme</h1>

<p align="center">
  A local-first macOS paper library with native PDF reading and Codex-backed research sessions.
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://swift.org"><img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-orange"></a>
  <img alt="Platform" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Status" src="https://img.shields.io/badge/status-active%20development-2ea44f">
  <img alt="License" src="https://img.shields.io/badge/license-not%20specified-lightgrey">
</p>

<p align="center">
  <a href="#intro-video">🎬 Intro Video</a> ·
  <a href="#screenshots">🖼️ Screenshots</a> ·
  <a href="#features">✨ Features</a> ·
  <a href="#installation">🚀 Installation</a> ·
  <a href="#quick-start">⚡ Quick Start</a> ·
  <a href="#development">🛠️ Development</a> ·
  <a href="#architecture">🧱 Architecture</a>
</p>

Episteme is a native macOS workspace for reading, organizing, and discussing academic papers. It keeps PDFs, folders, tags, notes, arXiv caches, thumbnails, reading sessions, and generated outputs on your machine, while using the Codex CLI when you want an AI research assistant inside a paper-specific workspace.

It is built for researchers who want the speed and feel of a local paper manager, plus grounded chat over the actual PDF, clickable citations back to source regions, and local arXiv discovery without a hosted product backend.

## Intro Video

Watch the detailed Remotion product walkthrough with animated UI focus moves: [docs/assets/videos/episteme-intro.mp4](docs/assets/videos/episteme-intro.mp4).

## Screenshots

<p align="center">
  <img src="docs/assets/screenshots/reader-chat.png" alt="Reader view with a PDF and Codex chat side by side">
  <br>
  <sub>Read a PDF, keep paper tabs open, and ask Codex questions with source-grounded context.</sub>
</p>

<table>
  <tr>
    <td width="50%">
      <img src="docs/assets/screenshots/library.png" alt="Paper library with folder tree, search, tags, and details">
    </td>
    <td width="50%">
      <img src="docs/assets/screenshots/discover.png" alt="arXiv Discover view with paper cards, thumbnails, tags, and local similarity scores">
    </td>
  </tr>
  <tr>
    <td><sub>Organize a local paper library with nested folders, tags, thumbnails, and paper details.</sub></td>
    <td><sub>Browse arXiv results with local caching, thumbnails, Chinese summaries, and save/open actions.</sub></td>
  </tr>
</table>

See the full visual tour in [docs/showcase.md](docs/showcase.md).

## Features

- 📚 **Local paper library** - import PDFs, organize them into nested folders, add tags, and keep durable metadata in SQLite.
- 📖 **Native PDF reader** - read with PDFKit, switch paper tabs, zoom smoothly, and preserve reader context.
- 🔎 **Source-grounded chat** - select text in the PDF, ask a local agent runtime, and keep citations tied to original page regions.
- 🧰 **Agent session workspaces** - each chat session writes a local workspace with PDFs, metadata, anchors, extracted text, and turn logs.
- 🎨 **Generated image support** - image-generation requests can surface directly in the chat, with in-app zoomable previews.
- 🔭 **Local arXiv Explore** - browse arXiv metadata directly, cache feeds/PDFs/thumbnails, and save papers into the local library.
- ✨ **Agent enrichment** - process Explore results for Chinese titles, summaries, contribution notes, tags, and useful links.
- 🧭 **Similarity ranking** - optionally rank arXiv results against local folders or tags using an OpenAI-compatible embedding provider.
- 🔒 **Local-first storage** - no Episteme account, cloud sync, or product API is required for the current version.

## Installation

### Requirements

- macOS 14 or newer
- Swift 6.2 toolchain
- Xcode command line tools
- [Codex CLI](https://github.com/openai/codex) for Codex chat, enrichment, and image-generation workflows
- Local agent CLIs for optional runtime routes, including Kimi ACP (`kimi acp`) and Gemini ACP (`gemini --experimental-acp`)

Check the basic toolchain:

```bash
swift --version
codex --version
```

### Build the app bundle

```bash
git clone https://github.com/caopulan/Episteme.git
cd Episteme
scripts/build-app-bundle.sh
open "$HOME/Applications/Episteme.app"
```

By default, the build script installs the signed local app bundle at:

```text
~/Applications/Episteme.app
```

You can override the output path:

```bash
EPISTEME_APP_PATH="$PWD/build/Episteme.app" scripts/build-app-bundle.sh
open "$PWD/build/Episteme.app"
```

## Quick Start

1. Open **Episteme**.
2. Import a PDF from the Library page, or open Discover and fetch recent arXiv papers.
3. Open a paper in the reader.
4. Select a sentence or paragraph in the PDF.
5. Ask Codex about the selected source in the right-hand chat panel.

Example prompts that work well:

```text
What is the central contribution of this paper? Please cite the source location.
```

```text
Compare this paper with the other papers in the current session. Which assumptions differ?
```

```text
Use imagegen to create a figure that explains this paper's training pipeline.
```

When image generation succeeds, Episteme copies the generated asset into the session workspace and renders it in the chat. Click the thumbnail to open an in-app zoomable preview instead of leaving the reader.

## Daily Workflow

### Organize a Local Library

Episteme stores saved PDFs and metadata locally. Use the Library sidebar as a folder tree, then narrow the paper list with search, folder scope, and reading actions.

```text
Library
├── All Papers
├── Diffusion Models
├── Multimodal Evaluation
└── Visual RL
```

### Read With Anchored Context

The reader keeps PDF reading and chat side by side. A source selection becomes part of the next message, so Codex can answer with context from the actual paper workspace rather than a loose paste.

### Discover From arXiv

Discover fetches arXiv metadata directly, caches results locally, and lets you process the current result set only when you need slower enrichment.

Useful Discover actions:

- Search by date range, keyword, category, and local similarity source.
- Download and cache PDF thumbnails.
- Translate titles.
- Generate Chinese summaries, contribution notes, tags, and links.
- Save papers into chosen folders.

### Keep AI Runs Inspectable

Codex runs are not hidden behind a remote service. Session files live on disk, and each turn keeps generated prompt context, output logs, and local workspace artifacts.

## Data Location

The default support directory is:

```text
~/Library/Application Support/Episteme
```

Typical contents:

```text
Episteme/
├── store.sqlite
├── agent-runtimes.json
├── papers/
├── sessions/
├── arxiv-cache/
├── thumbnails/
└── migrations/
```

For development or experiments, isolate app data with:

```bash
EPISTEME_SUPPORT_ROOT="$PWD/.episteme-dev" swift run PaperCodexApp
```

## Development

Build the debug app:

```bash
swift build
```

Run the app from SwiftPM:

```bash
swift run PaperCodexApp
```

Run the full verification suite:

```bash
swift run PaperCodexCoreChecks
```

Run focused checks:

```bash
swift run PaperCodexCoreChecks ui-layout-source
swift run PaperCodexCoreChecks codex
swift run PaperCodexCoreChecks arxiv-feed
```

Run local agent runtime smoke checks against a safe fixture workspace:

```bash
scripts/agent-runtime-smoke.sh --codex --claude --kimi-cli --kimi-acp --gemini-acp --kimi-openclaw
```

The smoke script verifies that Codex, Claude Code, native Kimi CLI, Kimi ACP, Gemini ACP, and the OpenClaw Kimi route can see `workspace_manifest.json`, the Episteme citation contract, and the live MCP endpoint when the app is running. It is read-only by default and does not mutate library papers, folders, tags, or notes.

If OpenClaw Kimi is blocked by local account or membership state, use the native Kimi CLI route, an ACP route, or the configured Hermes Kimi route:

```bash
scripts/agent-runtime-smoke.sh --kimi-cli
scripts/agent-runtime-smoke.sh --kimi-acp --gemini-acp
scripts/agent-runtime-smoke.sh --hermes-kimi
```

To expose Episteme to local Codex outside the in-app session, open Settings -> Episteme MCP and click **Install / Update**. The app writes a local Codex marketplace, plugin cache entry, MCP endpoint config, and Episteme skills. If the app moves ports or ships newer plugin/skill content, the same button refreshes the installed plugin; an already-installed plugin is also refreshed on Episteme startup.

Build the distributable local app bundle:

```bash
scripts/build-app-bundle.sh
```

## Architecture

Episteme is split into a SwiftUI macOS shell and a local core library.

```text
Sources/
├── PaperCodexApp/          # SwiftUI, PDFKit, app state, reader, library, Discover
├── PaperCodexCore/         # SQLite, indexing, arXiv, Codex runtime, parsing
├── PaperCodexCoreChecks/   # executable verification suite
└── CodeArxivFavoritesMigrator/
```

Core runtime pieces:

- `PaperRepository` manages the local SQLite store.
- `PDFIndexExtractor` extracts page text, spans, and anchors from text-layer PDFs.
- `SessionWorkspaceManager` writes per-session paper workspaces.
- `CodexAgentRuntime` invokes `codex exec` and `codex exec resume`.
- Agent runtime adapters launch Codex, Claude Code, ACP agents such as Kimi ACP and Gemini ACP, Hermes, OpenClaw Kimi, and pi against the same session workspace contract.
- `LocalArxivClient` and `ArxivFeedCache` power local arXiv discovery.
- `SimilarityRanker` computes optional local similarity ordering.

## Configuration

Most user-facing configuration is available in the Settings page:

- app language and default Codex prompt language
- arXiv feed/cache preferences
- Codex enrichment model, thinking effort, and concurrency
- optional embedding provider base URL, API key, and model
- quick prompts for reader chat
- disposable cache cleanup

The app also respects:

```bash
EPISTEME_SUPPORT_ROOT=/custom/support/root
EPISTEME_AGENT_RUNTIMES_PATH=/custom/agent-runtimes.json
EPISTEME_APP_PATH=/custom/Episteme.app
EPISTEME_BUILD_CONFIGURATION=release
EPISTEME_BUNDLE_IDENTIFIER=local.episteme.app
EPISTEME_CODESIGN_IDENTITY=-
```

Additional ACP runtimes can be added without rebuilding by writing `agent-runtimes.json` in the support directory, or by pointing `EPISTEME_AGENT_RUNTIMES_PATH` at another JSON file:

```json
{
  "profiles": [
    {
      "id": "local-acp-agent",
      "displayName": "Local ACP Agent",
      "backend": "acp",
      "executableName": "local-agent",
      "knownExecutablePaths": ["/opt/homebrew/bin/local-agent"],
      "supportsNonInteractiveRuns": true,
      "supportsPTY": false,
      "supportsResume": false,
      "supportsStructuredOutput": true,
      "supportsMCPConfig": true,
      "mcpMode": "acp-session",
      "promptInjectionModes": ["argument-prompt", "workspace-instructions"],
      "acpServerArguments": ["acp"]
    }
  ]
}
```

The legacy `PAPER_CODEX_*` environment variables are still accepted for existing development scripts and local setups.

## Current Limitations

- macOS only; the UI currently depends on SwiftUI and PDFKit.
- OCR/scanned PDFs are not the primary target yet; PDFs need a usable text layer for strong anchors.
- Cloud sync, accounts, and multi-device state are intentionally out of scope for the current version.
- Codex-backed chat and enrichment require a working local Codex CLI setup.
- arXiv requests can be rate-limited; cached metadata is used when available.

## Troubleshooting

### Codex is unavailable

Confirm the CLI is installed and visible:

```bash
which codex
codex --version
codex exec --help
```

Episteme checks for `codex` in `PATH` and common install locations, including the ChatGPT and Codex app bundles, `~/.local/bin`, and Homebrew paths.

### Reset local development data

Use an isolated support root while testing:

```bash
rm -rf "$PWD/.episteme-dev"
EPISTEME_SUPPORT_ROOT="$PWD/.episteme-dev" swift run PaperCodexApp
```

### Rebuild the installed app

```bash
scripts/build-app-bundle.sh
open "$HOME/Applications/Episteme.app"
```

## Contributing

Contributions are welcome. Before sending a change, run:

```bash
swift run PaperCodexCoreChecks
swift build
```

For UI or bundle-level changes, also run:

```bash
scripts/build-app-bundle.sh
```

Keep changes grounded in the local-first product boundary: local library, local arXiv/cache state, inspectable Codex workspaces, and native macOS reading.

## License

No open source license file is currently included in this repository. Add a `LICENSE` file before relying on Episteme as open source software.
