# Tintap

Native macOS selection assistant. Select text in any accessibility-enabled app to show a nearby Tooltip with translation and AI-search actions.

## Features

- Select text to show **Translate** and **AI Search** actions in the nearby tooltip.
- Translate through OpenAI Chat Completions-compatible services or Anthropic Messages API. Configure the API format, base URL, model, target language, and API key from the persistent menu bar icon. The key is stored in macOS Keychain.
- AI Search opens the local ChatGPT macOS app, pastes a search prompt, and sends it. The previous clipboard contents are restored immediately afterwards.
- The menu-bar item can enable or disable global selection tracking. Tooltip X/Y offsets are configurable from Settings.
- The action-only tooltip is draggable, closes when clicking elsewhere, and automatically flips above or below the selection to stay inside the visible screen area.

## Run

1. From this folder, run `swift run`.
2. When macOS asks, grant **Accessibility** permission to the launched `Tintap` process in **System Settings → Privacy & Security → Accessibility**.
3. Configure the model from the Tintap menu-bar icon before using **Translate**.
4. Select text in TextEdit, Safari, or another supported app, then choose **Translate** or **AI Search** from the tooltip.

## Current debugging scope

- Global mouse-up is used to detect the end of a drag selection.
- The Accessibility API supplies the selected text and its on-screen bounds.
- The tooltip is a non-activating panel so it does not steal focus from the source app.

Some apps intentionally do not expose selected text through the Accessibility API. Test first in TextEdit.

VS Code and Chromium-based browsers use a different accessibility tree from native AppKit editors. First set `"editor.accessibilitySupport": "on"` in VS Code's user `settings.json` and restart VS Code. If an app provides no focused accessibility element, no selected text, or no selected-range bounds, Tintap temporarily sends Command-C after a drag or double-click selection, reads the selected text, restores the previous clipboard contents, and anchors the tooltip at the mouse-up location. Set `TINTAP_CLIPBOARD_FALLBACK=0` to disable this fallback.

For diagnostics, run `TINTAP_DEBUG=1 swift run`. The terminal will state whether it could obtain selected text and bounds, plus the tooltip position.

`swift build -c release` only updates the executable under `.build`; it does not refresh `dist/Tintap.app`. After source changes, run `zsh scripts/package.sh --replace` before launching `dist/Tintap.app`.

Model-service URLs should point to the API base rather than a web console. For New API gateways, this is usually `https://your-host/v1`; Tintap then appends `/chat/completions` or `/messages` according to the selected API format.

DeepSeek's Anthropic-compatible API uses the base URL `https://api.deepseek.com/anthropic`; Tintap expands it to `/anthropic/v1/messages`. Use `deepseek-v4-flash` or `deepseek-v4-pro` as the model name.

## Package a local app

Run `zsh scripts/package.sh` to build a release executable and create an ad-hoc-signed `dist/Tintap.app`. To replace an existing generated bundle, run `zsh scripts/package.sh --replace`. Launch it with `open dist/Tintap.app`, then grant **Accessibility** permission to **Tintap** itself.
