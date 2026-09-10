# QuietDraft

A floating macOS overlay that transcribes **system audio** (the other person’s voice in a call, not your mic), OCRs **what is visible on screen**, and drafts spoken answers with OpenAI.

The overlay stays on top of other apps and is **hidden from screen sharing** (Zoom, Meet, OBS, etc.). Speech-to-text and Scan run on-device. Only **Submit** sends text to OpenAI.

Requires **macOS 13+** and an **Apple Silicon** Mac (Homebrew paths assume `/opt/homebrew`). Needs a working internet connection for Submit.

---

## What you need

| Tool | Why |
|------|-----|
| Xcode Command Line Tools | Swift 5.9+ compiler (`swift --version`) |
| [Homebrew](https://brew.sh) | Installs whisper.cpp |
| whisper.cpp | Local speech-to-text |
| A Whisper GGML model | The weights Whisper loads (~466 MB) |
| An OpenAI API key | Answers after you hit Submit |

---

## 1. Clone and install build tools

```bash
git clone <this-repo-url>
cd hidden-answer-machine   # or whatever you named the folder
```

```bash
xcode-select --install
```

Install Homebrew if you do not have it, then:

```bash
brew install whisper-cpp
```

Confirm the versions Homebrew installed — `Package.swift` currently links these Cellar paths:

- `/opt/homebrew/Cellar/whisper-cpp/1.9.1`
- `/opt/homebrew/Cellar/ggml/0.16.0`

If `ls` shows a different version, update those strings in `Package.swift` to match:

```bash
ls /opt/homebrew/Cellar/whisper-cpp
ls /opt/homebrew/Cellar/ggml
```

---

## 2. Download the Whisper model

QuietDraft looks for this file by default:

`~/.cache/hyperframes/whisper/models/ggml-small.en.bin`

```bash
mkdir -p ~/.cache/hyperframes/whisper/models
curl -L -o ~/.cache/hyperframes/whisper/models/ggml-small.en.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
```

The file is about **466 MB**. To use a different model, set `WHISPER_MODEL_PATH` in `.env`.

---

## 3. Configure secrets

```bash
cp .env.example .env
```

Edit `.env`:

```bash
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-5
OPENAI_REASONING_EFFORT=minimal
# Optional: path override
# WHISPER_MODEL_PATH=/path/to/ggml-small.en.bin
# Optional fallback only — prefer pasting resume / JD in the chat box (see Use it)
# RESUME_OR_JD_CONTEXT=
```

`OPENAI_REASONING_EFFORT` must be `minimal`, `low`, `medium`, or `high`. `none` is rejected by gpt-5. `minimal` is fastest; raise it if answers feel too shallow.

**Preferred:** put resume and job description in the overlay chat box, not in `.env` (full steps in [Use it](#6-use-it)). `RESUME_OR_JD_CONTEXT` is a fallback and is parsed as a **single line**, so a real resume does not fit well there.

The copy in **`/Applications` does not see the project folder**, so also install the same file here:

```bash
mkdir -p ~/.config/quietdraft
cp .env ~/.config/quietdraft/.env
```

Never commit `.env`. After you change it, quit and reopen QuietDraft.

---

## 4. Build and install

From the repo root:

```bash
chmod +x build_app.sh
killall QuietDraft 2>/dev/null || true
./build_app.sh
```

That compiles, signs with a local identity (`QuietDraftLocalSign`), and copies the app to:

- `./QuietDraft.app`
- `/Applications/QuietDraft.app`

**Always run the Applications copy:**

```bash
open /Applications/QuietDraft.app
```

Confirm it is signed (not ad-hoc):

```bash
codesign -dv /Applications/QuietDraft.app 2>&1 | grep Authority
```

You want `Authority=QuietDraftLocalSign`. If you see `Signature=adhoc`, rebuild with `./build_app.sh` and do not launch the unsigned binary.

macOS may block the first open (“unidentified developer”). Right-click `/Applications/QuietDraft.app` → **Open**, or allow it under **System Settings → Privacy & Security**.

Do not launch only the project-folder `.app` in day-to-day use. Screen Recording and Accessibility are tied to the signed binary you actually opened.

Quit QuietDraft before you build again (`killall QuietDraft`). Signing can hang if the app is still running.

Release build (optional): `./build_app.sh release`

### Local signing keychain

macOS will not reliably grant Screen Recording to an ad-hoc (unsigned) binary. `build_app.sh` therefore signs with a **self-signed identity** named `QuietDraftLocalSign`.

On the first successful build it creates, inside the repo (gitignored):

| File | Role |
|------|------|
| `.certs/cert.p12` / `key.pem` | The code-signing certificate |
| `.certs/quietdraft.keychain-db` | A **project-local keychain** that holds that cert |

You do not create this by hand. The script:

1. Unlocks `.certs/quietdraft.keychain-db`
2. Puts it **first** on the user keychain search list (so `codesign` can see `QuietDraftLocalSign`)
3. Signs a copy under `/tmp`, then copies it to the project folder and `/Applications`
4. Restores your **login** keychain as the default when it finishes

The keychain path in the script is **absolute**. A relative name like `quietdraft.keychain-db` would be created under `~/Library/Keychains/` instead, and signing/TCC would break in confusing ways. Do not “simplify” that path.

**Keep `.certs/` forever** on this machine. If you delete the keychain or regenerate `cert.p12`, you get a new identity. macOS then treats QuietDraft as a different app: Screen Recording, System Audio, and Accessibility all look empty and you have to Allow everything again.

If macOS asks whether `codesign` may use the keychain, choose **Always Allow**.

---

## 5. Grant permissions

On first launch, macOS will ask for access. Click **Allow** on **every** dialog, then **quit and reopen** QuietDraft. Permissions often do not apply until the second launch.

Check **System Settings → Privacy & Security**:

1. **Screen Recording** — QuietDraft must be on. Needed for system audio and Scan screen.
2. **System Audio** (or **System Audio Recording**, macOS 14.2+) — allow QuietDraft if you see a separate toggle. This is how it hears the call. It does **not** use the microphone.
3. **Accessibility** — QuietDraft must be on. Needed to read on-screen text from other apps (including browser pages that a screenshot cannot see). QuietDraft only shows up in this list **after** you have clicked Allow on its prompt — opening the Settings pane first will look empty.

If a dialog says to open System Settings, enable the matching toggle, then quit and reopen.

If QuietDraft **never appears** in Screen Recording or Accessibility, click **+** and add `/Applications/QuietDraft.app` yourself, turn it on, then quit and reopen.

If it still never appears, the build was likely ad-hoc unsigned. Rebuild with `./build_app.sh` and open `/Applications/QuietDraft.app` again.

To reset permissions after a signing mix-up:

```bash
tccutil reset ScreenCapture com.local.quietdraft
tccutil reset AudioCapture com.local.quietdraft
tccutil reset Accessibility com.local.quietdraft
```

Then launch from `/Applications` and click Allow once more.

---

## 6. Use it

Listening starts automatically when the overlay appears.

| Control | What it does |
|---------|----------------|
| **Grab** | Drops live transcription of **system audio** (what the Mac is playing) into the text box |
| **Scan screen** | Hides the overlay, screenshots the display, OCRs visible pixels (Apple Vision, on-device) |
| **Clear** | Empties the draft box |
| **Submit** | Sends the box to OpenAI and streams the answer. **Return** also submits. |

Edit the text before Submit if Scan or Grab picked up extra UI.

**Resume and job description (preferred):** paste them into the chat box at the bottom and hit **Submit** once before the interview (you can do resume, then JD, or both in one paste). They stay in the conversation, so later Grab/Scan answers can use that background. This is better than `RESUME_OR_JD_CONTEXT` in `.env`, which only supports a single line.

**Audio:** QuietDraft hears speaker/headphone output, not your mic. In a call, that is the other person’s voice (and anything else the call app plays). Your own voice is not captured unless it is playing back through the speakers.

**Scan:** only text that is actually on screen. Scrolled-off content and other tabs are not included.

**Sharing:** the overlay uses `sharingType = .none`, so it should not show up in Zoom/Meet/OBS. Other people on the call should not see it.

---

## Troubleshooting

**“Failed to load Whisper model”**  
The GGML file is missing or `WHISPER_MODEL_PATH` is wrong. Re-run the download in step 2.

**“Missing OPENAI_API_KEY”**  
The running app did not find `.env`. Copy it to `~/.config/quietdraft/.env`, then quit and reopen.

**Status stuck on “Starting capture…” / “Allow QuietDraft…”**  
A permission dialog is waiting, or Screen Recording / System Audio is off. Allow it, then quit and reopen.

**No transcription / “user declined” (`-3801`)**  
Screen Recording or System Audio was denied. Reset with `tccutil` (step 5), allow, quit, reopen.

**Scan misses Chrome page content**  
Chrome often composites the page on the GPU, so a screenshot may show tabs/chrome but a blank page. OCR can only read pixels that are actually in the screenshot.

**Answers feel slow**  
gpt-5 reasoning can take a while. Keep `OPENAI_REASONING_EFFORT=minimal` unless you need more depth.

**Build linker errors for `libwhisper` / `libggml`**  
Homebrew versions drifted from `Package.swift`. Update the Cellar paths (step 1).

**`codesign` hangs**  
QuietDraft is still running. `killall QuietDraft` and build again.

**`codesign` cannot find `QuietDraftLocalSign`**  
The local keychain is missing, locked, or not on the search list. Run `./build_app.sh` from the repo root (it unlocks `.certs/quietdraft.keychain-db` and prepends it). Do not delete `.certs/`. If you already deleted it, the script will mint a new cert — then reset permissions (step 5) and Allow everything again.

**A keychain named `quietdraft` appeared under `~/Library/Keychains/`**  
Someone ran `security` with a relative keychain name. Ignore or delete that one; the real file is `hidden-answer-machine/.certs/quietdraft.keychain-db`. Always use `./build_app.sh`.

Debug log (not in the repo):

```bash
tail -f ~/quietdraft_debug.log
```

Last Scan screenshot (for checking what OCR saw):

```bash
open ~/quietdraft_last_scan.png
```

The log also records which `.env` was loaded (`[config] loaded env from …`).
