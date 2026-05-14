-- ============================================
-- Whisper Dictation — Option+Cmd+L toggle
-- Floating macOS pill via hs.webview
-- ============================================

local dictateScript        = os.getenv("HOME") .. "/scripts/dictate.sh"
local recordChunksScript   = os.getenv("HOME") .. "/scripts/record-chunks.sh"

-- ============================================
-- Configuração
-- ============================================
local AUTO_ENTER = true
local isRecording = false
local pillView = nil
local escHotkey = nil
local enterHotkey = nil
local shiftHotkey = nil
local targetWindow = nil
local targetApp = nil
local dismissTimer = nil
local beatTimer = nil
local beatIndex = 0
local BEAT_INTERVAL = 0.4   -- lub-dub: 2 beats close, 2 beats silence (~38 BPM cycle)
local BEAT_PATTERN  = {true, true, false, false}
local waveTimer = nil
local waveValues = {8, 12, 16, 12, 8}
local waveEnergy = 0.3
local recordingStartTime = nil       -- timestamp when recording started
local isTranscribing = false          -- true while whisper is running
local MIN_RECORD_SECS = 1.5          -- ignore Enter/Shift before this

-- ============================================
-- Chunked recording / transcription
-- ============================================
-- Strategy: ffmpeg's segment muxer rotates files every CHUNK_SECS seconds
-- without dropping samples. As soon as a chunk finalises, we kick off whisper
-- on it (sequentially, one at a time, to avoid CPU contention). Each chunk is
-- enriched with the trailing OVERLAP_SECS of the previous chunk so a word
-- split across a boundary appears intact in the next transcription. The
-- downstream consumer (an LLM) handles the resulting word duplications.
local CHUNK_DIR     = "/tmp/voxt-chunks"
local CHUNK_SECS    = 18
local OVERLAP_SECS  = 3
local RAW_TAP       = CHUNK_DIR .. "/_raw.pcm"   -- live raw-PCM tap for mic monitor

-- ============================================
-- Health: pre-flight + live mic-energy monitor
-- ============================================
-- Pre-flight: a fast SSH probe to the Mac Mini (whisper-cli + VAD model must
-- exist). Runs on every hotkey press BEFORE rec starts, so a dead transcriber
-- is caught instantly instead of after a 2-minute monologue.
local REMOTE_HOST            = "macmini"
local REMOTE_WHISPER         = "/opt/homebrew/bin/whisper-cli"
local REMOTE_MODEL           = "/Users/zion/whisper.cpp/models/ggml-large-v3.bin"
local REMOTE_VAD_MODEL       = "/Users/zion/whisper.cpp/models/ggml-silero-v5.1.2.bin"
local PREFLIGHT_TIMEOUT_SECS = 3

-- Mic monitor: while recording, sample the tail of /tmp/voxt-chunks/_raw.pcm
-- every MIC_CHECK_INTERVAL seconds (after a short grace period). If RMS stays
-- below MIC_SILENCE_THRESHOLD for MIC_SILENCE_STREAK consecutive samples, flip
-- the pill into a "no audio" warning state — without stopping the recording,
-- so the user can fix the mic mid-dictation.
local MIC_CHECK_GRACE        = 2.5    -- secs before first check (lets buffers fill)
local MIC_CHECK_INTERVAL     = 1.5    -- secs between checks
local MIC_TAIL_BYTES         = 32000  -- ~1s of 16-bit mono 16kHz audio
local MIC_SILENCE_THRESHOLD  = 0.005  -- sox RMS amplitude considered silence
local MIC_SILENCE_STREAK     = 3      -- ~4.5s of silence before warning fires

local micCheckTimer          = nil
local micSilenceCount        = 0
local micWarningShown        = false
local preflightTask          = nil

local recPipelineTask    = nil   -- hs.task for record-chunks.sh
local recPipelineDone    = false -- true once recording bash script has exited
local chunkWatcher       = nil   -- hs.pathwatcher on CHUNK_DIR
local seenChunks         = {}    -- map: idx → true (chunk file has appeared)
local finalisedChunks    = {}    -- map: idx → true (file fully written + closed)
local transcribedChunks  = {}    -- map: idx → text
local chunkQueue         = {}    -- ordered list of indices waiting for whisper
local activeChunkTask    = nil   -- hs.task running whisper on a chunk
local pendingEnrichTask  = nil   -- hs.task running sox to build enriched chunk
local pendingFinalize    = nil   -- nil | { autoEnter = bool }
local cancelRequested    = false

-- Smart paste: pending state when user switched windows
local pendingResult = nil             -- transcribed text waiting to be pasted
local pendingAutoEnter = nil          -- whether to auto-enter when accepted
local highlightCanvas = nil           -- hs.canvas border around original window
local highlightPulseTimer = nil       -- timer for pulsing animation
local pendingTimer = nil              -- timeout to dismiss pending state
local pendingWindowWatcher = nil      -- hs.timer to watch for window refocus
local PENDING_TIMEOUT = 60            -- seconds before pending state auto-dismisses

-- ============================================
-- Sound feedback
-- ============================================
local soundsDir = os.getenv("HOME") .. "/.hammerspoon/sounds/"

local function playSound(name, vol)
    local s = hs.sound.getByName(name)
    if s then s:volume(vol or 0.5); s:play() end
end

local function playSoundFile(filename, vol)
    local s = hs.sound.getByFile(soundsDir .. filename)
    if s then s:volume(vol or 0.5); s:play() end
end

local function stopLoadingSound()
    if beatTimer then beatTimer:stop(); beatTimer = nil end
    beatIndex = 0
end

local function startLoadingSound()
    stopLoadingSound()
    -- beat 1 fires immediately, then timer handles beats 2–8 and loop
    playSoundFile("bong-001.mp3", 0.35)
    beatIndex = 1
    beatTimer = hs.timer.doEvery(BEAT_INTERVAL, function()
        beatIndex = (beatIndex % 8) + 1
        if BEAT_PATTERN[beatIndex] then
            playSoundFile("bong-001.mp3", 0.35)
        end
    end)
end

-- ============================================
-- Wave animation (JS-driven smooth random walk)
-- ============================================
local function stopWaveAnimation()
    if waveTimer then waveTimer:stop(); waveTimer = nil end
end

local function startWaveAnimation()
    stopWaveAnimation()
    waveValues = {4, 6, 8, 6, 4}
    waveEnergy = 0.3
    waveTimer = hs.timer.doEvery(0.08, function()
        if not pillView or not isRecording then return end
        -- energy drifts slowly (simulates speech vs silence)
        waveEnergy = math.max(0.05, math.min(1.0, waveEnergy + (math.random() - 0.44) * 0.18))
        for i = 1, 5 do
            -- centre bars (voice frequencies) react more
            local boost = (i == 3) and 1.5 or (i == 2 or i == 4) and 1.2 or 0.8
            local target = math.floor(2 + waveEnergy * boost * math.random(6, 18))
            waveValues[i] = math.floor(waveValues[i] * 0.35 + target * 0.65)
        end
        -- soft symmetry: mirror outer and inner pairs
        local avg15 = math.floor((waveValues[1] + waveValues[5]) / 2)
        waveValues[1] = avg15; waveValues[5] = avg15
        local avg24 = math.floor((waveValues[2] + waveValues[4]) / 2)
        waveValues[2] = avg24; waveValues[4] = avg24
        pillView:evaluateJavaScript(string.format(
            "(function(){var b=document.querySelectorAll('.wave b'),h=[%d,%d,%d,%d,%d];for(var i=0;i<5;i++){if(b[i])b[i].style.height=h[i]+'px';}})();",
            waveValues[1], waveValues[2], waveValues[3], waveValues[4], waveValues[5]
        ))
    end)
end

-- ============================================
-- Pill dimensions (webview is larger to hide window edges)
-- ============================================
local PILL_W = 320
local PILL_H = 48
local PAD = 4   -- minimal padding (shadow clipping acceptable — avoids blocking clicks)
local VIEW_W = PILL_W + PAD * 2
local VIEW_H = PILL_H + PAD * 2
local PILL_Y = 8

local function getViewFrame()
    local scr = hs.screen.mainScreen():frame()
    return hs.geometry.rect(
        scr.x + math.floor((scr.w - VIEW_W) / 2),
        scr.y + PILL_Y,
        VIEW_W,
        VIEW_H
    )
end

-- Hidden frame for pre-warm (off-screen as defence-in-depth; :hide() is the real protection)
local OFF_SCREEN_FRAME = hs.geometry.rect(-9999, -9999, VIEW_W, VIEW_H)

-- Properly hide the NSWindow so it leaves the window list and stops intercepting clicks.
-- Setting alpha(0) + moving off-screen is NOT enough on macOS: the window stays in the
-- window server's hit-test stack and silently swallows clicks at its last on-screen frame.
local function movePillOffScreen()
    if pillView then
        pillView:hide()
        pillView:alpha(0)
        pillView:frame(OFF_SCREEN_FRAME)
    end
end

-- ============================================
-- HTML shell (pill centred inside padded webview)
-- ============================================
local function shellHTML()
    return string.format([[
        <html>
        <head><style>
            * { margin:0; padding:0; box-sizing:border-box; pointer-events:none !important; }
            html, body {
                background: transparent !important;
                overflow: hidden;
                width: 100%%;
                height: 100%%;
                -webkit-user-select: none;
            }
            .wrapper {
                width: 100%%;
                height: 100%%;
                display: flex;
                align-items: center;
                justify-content: center;
                padding: %dpx;
            }
            @keyframes pillIn {
                from { opacity:0; transform: translateY(-6px) scale(0.97); }
                to   { opacity:1; transform: translateY(0)    scale(1);    }
            }
            .pill {
                display: flex;
                align-items: center;
                gap: 10px;
                width: %dpx;
                height: %dpx;
                padding: 0 16px;
                border-radius: 14px;
                border: 0.5px solid rgba(255,255,255,0.10);
                box-shadow:
                    0 2px 8px rgba(0,0,0,0.4),
                    0 1px 3px rgba(0,0,0,0.25);
                backdrop-filter: blur(50px) saturate(1.6);
                -webkit-backdrop-filter: blur(50px) saturate(1.6);
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 13px;
                -webkit-font-smoothing: antialiased;
                background: rgba(28,28,32,0.82);
                color: rgba(255,255,255,0.9);
                transition: background 0.3s ease, color 0.3s ease;
                animation: pillIn 0.22s ease-out;
            }
            /* === Wave bars (recording state) === */
            .wave {
                display: flex;
                align-items: center;
                gap: 2.5px;
                flex-shrink: 0;
                height: 20px;
            }
            .wave.hidden { display: none; }
            .wave b {
                display: block;
                width: 3px;
                border-radius: 2px;
                background: #ff5252;
                box-shadow: 0 0 5px rgba(255,82,82,0.55);
                height: 4px;
                transition: height 0.09s ease-out;
            }
            /* === Spinner (transcribing state) === */
            .spinner {
                width: 14px;
                height: 14px;
                border: 2px solid rgba(140,170,255,0.25);
                border-top-color: rgba(140,170,255,0.9);
                border-radius: 50%%;
                flex-shrink: 0;
                animation: spin 0.75s linear infinite;
            }
            .spinner.hidden { display: none; }
            @keyframes spin { to { transform: rotate(360deg); } }
            /* === Text === */
            .text {
                flex: 1;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
                font-weight: 500;
                letter-spacing: -0.1px;
            }
            @keyframes textIn {
                from { opacity: 0; transform: translateY(2px); }
                to   { opacity: 1; transform: translateY(0);   }
            }
            .text.anim { animation: textIn 0.22s ease-out; }
            /* === Badge === */
            .badge {
                background: rgba(255,255,255,0.1);
                border-radius: 6px;
                padding: 4px 12px;
                font-size: 11px;
                color: rgba(255,255,255,0.45);
                white-space: nowrap;
                flex-shrink: 0;
                letter-spacing: 0.3px;
            }
            .badge.hidden { display: none; }
        </style></head>
        <body>
            <div class="wrapper">
                <div class="pill" id="pill">
                    <div class="wave hidden" id="wave"><b></b><b></b><b></b><b></b><b></b></div>
                    <div class="spinner hidden" id="spinner"></div>
                    <div class="text" id="text"></div>
                    <div class="badge hidden" id="badge"></div>
                </div>
            </div>
        </body>
        </html>
    ]], PAD, PILL_W, PILL_H)
end

local function ensurePill(onReady)
    if pillView then
        pillView:frame(getViewFrame())  -- reposicionar para o ecrã atual
        pillView:alpha(1.0)
        pillView:show()                  -- bring window back into the window list
        -- re-trigger entrance animation
        pillView:evaluateJavaScript("(function(){var p=document.getElementById('pill');p.style.animation='none';void p.offsetWidth;p.style.animation='';})();")
        if onReady then onReady() end
        return
    end
    -- fallback: pill not yet pre-warmed
    local frame = getViewFrame()
    pillView = hs.webview.new(frame, { developerExtrasEnabled = false })
    pillView:windowStyle({"borderless", "nonactivating"})
    pillView:level(hs.canvas.windowLevels.overlay)
    pillView:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    pillView:allowTextEntry(false)
    pillView:transparent(true)
    pillView:alpha(1.0)
    pillView:html(shellHTML())
    pillView:show()
    hs.timer.doAfter(0.5, function()
        if onReady then onReady() end
    end)
end

local function updatePill(opts)
    ensurePill()
    local safeText  = (opts.text  or ""):gsub("\\", "\\\\"):gsub("'", "\\'")
    local safeBadge = (opts.badge or ""):gsub("\\", "\\\\"):gsub("'", "\\'")
    local js = string.format([[
        (function() {
            var pill    = document.getElementById('pill');
            var wave    = document.getElementById('wave');
            var spinner = document.getElementById('spinner');
            var text    = document.getElementById('text');
            var badge   = document.getElementById('badge');

            pill.style.background = '%s';
            pill.style.color      = '%s';

            wave.className    = %s ? 'wave'    : 'wave hidden';
            spinner.className = %s ? 'spinner' : 'spinner hidden';

            text.className = 'text';
            void text.offsetWidth;
            text.className = 'text anim';
            text.textContent = '%s';

            badge.className   = %s ? 'badge' : 'badge hidden';
            badge.textContent = '%s';
        })();
    ]],
        opts.bg    or "rgba(28,28,32,0.82)",
        opts.color or "rgba(255,255,255,0.9)",
        opts.showWave    and "true" or "false",
        opts.showSpinner and "true" or "false",
        safeText,
        opts.badge and "true" or "false",
        safeBadge
    )
    pillView:evaluateJavaScript(js)
end

-- ============================================
-- Window highlight (glowing border around original window)
-- ============================================
local HIGHLIGHT_COLOR   = {red = 1, green = 0.72, blue = 0.2, alpha = 0.9}   -- amber/gold
local HIGHLIGHT_DIM     = {red = 1, green = 0.72, blue = 0.2, alpha = 0.35}
local HIGHLIGHT_BORDER  = 3
local HIGHLIGHT_RADIUS  = 10

local function removeWindowHighlight()
    if highlightPulseTimer then highlightPulseTimer:stop(); highlightPulseTimer = nil end
    if highlightCanvas then highlightCanvas:delete(); highlightCanvas = nil end
end

local function drawWindowHighlight(win)
    removeWindowHighlight()
    if not win then return end
    local f = win:frame()
    if not f then return end

    local pad = HIGHLIGHT_BORDER + 2
    highlightCanvas = hs.canvas.new(hs.geometry.rect(
        f.x - pad, f.y - pad,
        f.w + pad * 2, f.h + pad * 2
    ))
    highlightCanvas:level(hs.canvas.windowLevels.overlay)
    highlightCanvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    highlightCanvas:clickActivating(false)
    highlightCanvas:canvasMouseEvents(false)

    highlightCanvas[1] = {
        type             = "rectangle",
        action           = "stroke",
        strokeColor      = HIGHLIGHT_COLOR,
        strokeWidth      = HIGHLIGHT_BORDER,
        roundedRectRadii = {xRadius = HIGHLIGHT_RADIUS, yRadius = HIGHLIGHT_RADIUS},
        frame            = {x = pad - HIGHLIGHT_BORDER/2, y = pad - HIGHLIGHT_BORDER/2,
                            w = f.w + HIGHLIGHT_BORDER, h = f.h + HIGHLIGHT_BORDER},
    }
    highlightCanvas:show()

    -- Pulse animation: alternate bright/dim
    local bright = true
    highlightPulseTimer = hs.timer.doEvery(0.8, function()
        if not highlightCanvas then return end
        bright = not bright
        highlightCanvas[1].strokeColor = bright and HIGHLIGHT_COLOR or HIGHLIGHT_DIM
    end)
end

-- ============================================
-- Pending state management (text ready but wrong window)
-- ============================================
local function dismissPending()
    pendingResult = nil
    pendingAutoEnter = nil
    removeWindowHighlight()
    escHotkey:stop()
    if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
    if pendingWindowWatcher then pendingWindowWatcher:stop(); pendingWindowWatcher = nil end
    targetWindow = nil
    targetApp = nil
    movePillOffScreen()
end

local function acceptPending()
    if not pendingResult then return end
    local text = pendingResult
    local autoEnter = pendingAutoEnter

    -- Clean up pending state first
    pendingResult = nil
    pendingAutoEnter = nil
    removeWindowHighlight()
    escHotkey:stop()
    if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
    if pendingWindowWatcher then pendingWindowWatcher:stop(); pendingWindowWatcher = nil end
    targetWindow = nil
    targetApp = nil

    -- Text is already in clipboard from transcription
    hs.eventtap.keyStroke({"cmd"}, "v")
    if autoEnter then
        hs.timer.doAfter(0.05, function()
            hs.eventtap.keyStroke({}, "return")
        end)
    end

    -- Show green confirmation
    showResult(text)
end

local function startPendingState(text, autoEnter)
    pendingResult = text
    pendingAutoEnter = autoEnter

    -- Draw highlight around original window
    drawWindowHighlight(targetWindow)

    -- Watch for user returning to original window → auto-paste
    if pendingWindowWatcher then pendingWindowWatcher:stop() end
    pendingWindowWatcher = hs.timer.doEvery(0.5, function()
        local fw = hs.window.focusedWindow()
        if fw and targetWindow and fw:id() == targetWindow:id() then
            acceptPending()
        end
    end)

    -- Timeout: dismiss after PENDING_TIMEOUT seconds
    if pendingTimer then pendingTimer:stop() end
    pendingTimer = hs.timer.doAfter(PENDING_TIMEOUT, function()
        dismissPending()
    end)
end

-- ============================================
-- States
-- ============================================
local function showRecording()
    updatePill({
        text     = "Recording\xe2\x80\xa6",
        bg       = "rgba(28, 28, 32, 0.82)",
        color    = "rgba(255,255,255,0.92)",
        showWave = true,
        badge    = "\xe2\x87\xa7 Paste  \xe2\x86\xb5 Send",
    })
end

local function showTranscribing()
    updatePill({
        text        = "Transcribing\xe2\x80\xa6",
        bg          = "rgba(24, 26, 40, 0.82)",
        color       = "rgba(140, 170, 255, 0.92)",
        showSpinner = true,
        badge       = "ESC Cancel",
    })
end

local function showResult(text)
    stopLoadingSound()
    playSoundFile("confirmation-001.mp3", 0.8)
    if not text or text == "" then text = "(no text detected)" end
    if #text > 42 then text = text:sub(1, 39) .. "..." end
    updatePill({
        text  = "\xe2\x9c\x93 " .. text,
        bg    = "rgba(22, 34, 26, 0.82)",
        color = "rgba(120, 240, 160, 0.92)",
    })
    if dismissTimer then dismissTimer:stop() end
    dismissTimer = hs.timer.doAfter(3.5, function()
        movePillOffScreen()
        dismissTimer = nil
    end)
end

local function showPending(text)
    stopLoadingSound()
    playSoundFile("question-004.mp3", 0.5)
    if not text or text == "" then text = "(no text detected)" end
    local preview = text
    if #preview > 30 then preview = preview:sub(1, 27) .. "..." end
    updatePill({
        text  = "\xe2\x8f\xb3 " .. preview,
        bg    = "rgba(40, 32, 16, 0.88)",
        color = "rgba(255, 200, 80, 0.95)",
        badge = "\xe2\x8c\xa5\xe2\x8c\x98L Paste",
    })
end

local function hidePill()
    stopLoadingSound()
    movePillOffScreen()
end

local function showError(msg)
    stopLoadingSound()
    stopWaveAnimation()
    playSoundFile("question-004.mp3", 0.7)
    updatePill({
        text  = "\xe2\x9a\xa0 " .. msg,
        bg    = "rgba(60, 18, 18, 0.92)",
        color = "rgba(255, 140, 140, 0.95)",
    })
    if dismissTimer then dismissTimer:stop() end
    dismissTimer = hs.timer.doAfter(4.5, function()
        movePillOffScreen()
        dismissTimer = nil
    end)
end

-- Soft warning shown DURING recording when the mic is dead silent.
-- Keeps recording active so the user can recover (e.g., unmute, fix device)
-- and reverts to normal "Recording…" state once audio energy returns.
local function showMicWarning()
    updatePill({
        text     = "\xe2\x9a\xa0 Sem \xc3\xa1udio \xe2\x80\x94 verifica o microfone",
        bg       = "rgba(60, 36, 12, 0.92)",
        color    = "rgba(255, 200, 100, 0.95)",
        showWave = true,
        badge    = "ESC Cancel",
    })
end

-- ============================================
-- Health checks: pre-flight + live mic-energy monitor
-- ============================================
local function runPreflight(onOK, onFail)
    -- Single SSH call: verify whisper-cli + model files exist on the Mac Mini.
    -- ControlMaster keeps the connection warm so this is ~50ms in steady state.
    -- ConnectTimeout caps cold-cache cases at 3s.
    local cmd = string.format(
        [[/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=%d %s ]] ..
        [['test -x %s && test -f %s && test -f %s && echo ok' 2>/dev/null]],
        PREFLIGHT_TIMEOUT_SECS, REMOTE_HOST,
        REMOTE_WHISPER, REMOTE_MODEL, REMOTE_VAD_MODEL
    )
    preflightTask = hs.task.new("/bin/bash", function(code, out, _err)
        preflightTask = nil
        local ok = (code == 0) and (out and out:find("ok"))
        if ok then onOK() else onFail() end
    end, { "-c", cmd })
    preflightTask:start()
end

-- Reads tail of the raw PCM tap and computes RMS via sox.
-- Calls done(rms) with rms as a number (0.0–1.0 range); rms is nil if the tap
-- is missing or sox failed.
local function sampleMicRMS(done)
    if not hs.fs.attributes(RAW_TAP) then done(nil); return end
    local cmd = string.format(
        [[/usr/bin/tail -c %d %q 2>/dev/null | ]] ..
        [[/opt/homebrew/bin/sox -t raw -r 16000 -c 1 -b 16 -e signed - -n stat 2>&1 | ]] ..
        [[/usr/bin/awk '/RMS .*amplitude/ {print $NF; exit}']],
        MIC_TAIL_BYTES, RAW_TAP
    )
    hs.task.new("/bin/bash", function(_code, out, _err)
        local rms = tonumber((out or ""):gsub("%s+", ""))
        done(rms)
    end, { "-c", cmd }):start()
end

local function stopMicMonitor()
    if micCheckTimer then micCheckTimer:stop(); micCheckTimer = nil end
    micSilenceCount = 0
    micWarningShown = false
end

local function startMicMonitor()
    stopMicMonitor()
    hs.timer.doAfter(MIC_CHECK_GRACE, function()
        if not isRecording then return end
        micCheckTimer = hs.timer.doEvery(MIC_CHECK_INTERVAL, function()
            if not isRecording then stopMicMonitor(); return end
            sampleMicRMS(function(rms)
                if not isRecording then return end
                if rms == nil then return end  -- tap not ready yet
                if rms < MIC_SILENCE_THRESHOLD then
                    micSilenceCount = micSilenceCount + 1
                    if micSilenceCount >= MIC_SILENCE_STREAK and not micWarningShown then
                        micWarningShown = true
                        showMicWarning()
                    end
                else
                    -- Audio came back: clear warning and resume normal recording UI.
                    if micWarningShown then
                        micWarningShown = false
                        showRecording()
                    end
                    micSilenceCount = 0
                end
            end)
        end)
    end)
end

-- ============================================
-- Dictation control (chunked pipeline)
-- ============================================

local function chunkPath(idx)
    return string.format("%s/chunk_%03d.wav", CHUNK_DIR, idx)
end

local function enrichedPath(idx)
    return string.format("%s/_enriched_%03d.wav", CHUNK_DIR, idx)
end

local function chunkOutBase(idx)
    return string.format("%s/chunk_%03d", CHUNK_DIR, idx)
end

local function listChunkIndices()
    local idxs = {}
    if not hs.fs.attributes(CHUNK_DIR, "mode") then return idxs end
    for f in hs.fs.dir(CHUNK_DIR) do
        local n = f:match("^chunk_(%d+)%.wav$")
        if n then table.insert(idxs, tonumber(n)) end
    end
    table.sort(idxs)
    return idxs
end

local function resetChunkState()
    chunkQueue        = {}
    seenChunks        = {}
    finalisedChunks   = {}
    transcribedChunks = {}
    pendingFinalize   = nil
    cancelRequested   = false
    recPipelineDone   = false
end

-- Forward-declared because of mutual recursion via callbacks.
local processNextChunk
local maybeFinalize

local function transcribeChunkAt(idx, done)
    local current = chunkPath(idx)
    if not hs.fs.attributes(current) then
        transcribedChunks[idx] = ""
        done()
        return
    end

    local function runWhisper(input)
        local outBase = chunkOutBase(idx)
        os.remove(outBase .. ".txt")
        activeChunkTask = hs.task.new("/bin/bash", function(_code, _out, _err)
            activeChunkTask = nil
            local txt = ""
            local rf = io.open(outBase .. ".txt", "r")
            if rf then
                txt = rf:read("*a"):gsub("^%s+", ""):gsub("%s+$", "")
                rf:close()
            end
            if txt == "[BLANK_AUDIO]" then txt = "" end
            transcribedChunks[idx] = txt
            os.remove(enrichedPath(idx))
            done()
        end, { dictateScript, "transcribe-chunk", input, outBase })
        activeChunkTask:start()
    end

    -- For idx 0 there is no previous chunk → no overlap.
    if idx == 0 then
        runWhisper(current)
        return
    end

    local prev = chunkPath(idx - 1)
    if not hs.fs.attributes(prev) then
        runWhisper(current)
        return
    end

    -- Build enriched chunk = last OVERLAP_SECS of prev + all of current.
    -- Run via /bin/bash so we can pipe sox commands.
    local enriched = enrichedPath(idx)
    local tailFile = string.format("%s/_tail_%03d.wav", CHUNK_DIR, idx)
    local cmd = string.format(
        "/opt/homebrew/bin/sox %q %q trim -%d 2>/dev/null && " ..
        "/opt/homebrew/bin/sox %q %q %q 2>/dev/null; " ..
        "rm -f %q",
        prev, tailFile, OVERLAP_SECS,
        tailFile, current, enriched,
        tailFile
    )
    pendingEnrichTask = hs.task.new("/bin/bash", function(_code, _out, _err)
        pendingEnrichTask = nil
        if hs.fs.attributes(enriched) then
            runWhisper(enriched)
        else
            -- Enrichment failed: transcribe plain chunk so we never lose audio.
            runWhisper(current)
        end
    end, { "-c", cmd })
    pendingEnrichTask:start()
end

processNextChunk = function()
    if cancelRequested then return end
    if activeChunkTask or pendingEnrichTask then return end
    if #chunkQueue == 0 then
        maybeFinalize()
        return
    end
    local idx = table.remove(chunkQueue, 1)
    transcribeChunkAt(idx, function() processNextChunk() end)
end

local function enqueueChunk(idx)
    if finalisedChunks[idx] then return end
    finalisedChunks[idx] = true
    table.insert(chunkQueue, idx)
    table.sort(chunkQueue)
    processNextChunk()
end

maybeFinalize = function()
    if cancelRequested then return end
    if not recPipelineDone then return end
    if not pendingFinalize then return end
    if activeChunkTask or pendingEnrichTask then return end
    if #chunkQueue > 0 then return end

    -- Assemble full transcription in chunk order (with intentional overlap
    -- duplications — downstream LLM dedupes naturally).
    local indices = listChunkIndices()
    local parts = {}
    for _, idx in ipairs(indices) do
        local txt = transcribedChunks[idx]
        if txt and txt ~= "" then
            table.insert(parts, txt)
        end
    end
    local result = table.concat(parts, " ")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")

    local autoEnter = pendingFinalize.autoEnter
    pendingFinalize = nil

    if chunkWatcher then chunkWatcher:stop(); chunkWatcher = nil end

    if result ~= "" then
        hs.pasteboard.setContents(result)
        local currentWindow = hs.window.focusedWindow()
        local sameWindow = (currentWindow and targetWindow
                            and currentWindow:id() == targetWindow:id())
        if sameWindow then
            hs.timer.doAfter(0.15, function()
                hs.eventtap.keyStroke({"cmd"}, "v")
                if autoEnter then
                    hs.timer.doAfter(0.05, function()
                        hs.eventtap.keyStroke({}, "return")
                    end)
                end
                targetWindow = nil
                targetApp    = nil
            end)
            isTranscribing = false
            escHotkey:stop()
            showResult(result)
        else
            isTranscribing = false
            showPending(result)
            startPendingState(result, autoEnter)
        end
    else
        isTranscribing = false
        escHotkey:stop()
        showResult(nil)
    end
end

local function onChunkDirChange(_paths, _flags)
    -- ffmpeg's segment muxer only opens chunk_(N+1).wav after closing chunk_N.
    -- So the appearance of chunk_(N+1) is the signal that chunk_N is final.
    local idxs = listChunkIndices()
    for _, idx in ipairs(idxs) do
        if not seenChunks[idx] then
            seenChunks[idx] = true
            if idx > 0 then
                enqueueChunk(idx - 1)
            end
        end
    end
end

local function onRecPipelineExit(_code, _out, _err)
    recPipelineTask = nil
    -- The bash script's cleanup trap waits for ffmpeg to flush the last chunk
    -- before exiting. So when we get here, the highest-indexed chunk file is
    -- final too. Mark it for transcription.
    local idxs = listChunkIndices()
    if #idxs > 0 then
        enqueueChunk(idxs[#idxs])
    end
    recPipelineDone = true
    processNextChunk()
end

local function beginRecording()
    -- Guardar janela ativa AGORA (antes de qualquer mudança de foco)
    targetWindow = hs.window.focusedWindow()
    targetApp    = hs.application.frontmostApplication()

    escHotkey:start()
    enterHotkey:enable()
    shiftHotkey:start()

    if dismissTimer then dismissTimer:stop(); dismissTimer = nil end
    recordingStartTime = hs.timer.secondsSinceEpoch()
    resetChunkState()
    playSoundFile("confirmation-001.mp3", 0.8)
    ensurePill(function()
        showRecording()
        startWaveAnimation()
    end)

    hs.execute(string.format("mkdir -p %q", CHUNK_DIR))
    -- pathwatcher must attach AFTER the dir exists.
    chunkWatcher = hs.pathwatcher.new(CHUNK_DIR, onChunkDirChange):start()

    recPipelineTask = hs.task.new(
        "/bin/bash",
        onRecPipelineExit,
        { recordChunksScript, CHUNK_DIR, tostring(CHUNK_SECS) }
    )
    recPipelineTask:start()
    startMicMonitor()
end

local function startDictation()
    if isRecording then return end
    isRecording = true

    -- Show an instant "checking" state so the user gets visual feedback while
    -- the pre-flight SSH probe runs. Pill stays up regardless of outcome.
    ensurePill(function()
        updatePill({
            text  = "Checking\xe2\x80\xa6",
            bg    = "rgba(24, 26, 40, 0.82)",
            color = "rgba(180, 200, 255, 0.92)",
        })
    end)

    runPreflight(
        function()  -- onOK
            if not isRecording then return end  -- user already cancelled
            beginRecording()
        end,
        function()  -- onFail
            isRecording = false
            showError("Mac Mini offline \xe2\x80\x94 transcri\xc3\xa7\xc3\xa3o indispon\xc3\xadvel")
        end
    )
end

local function hasMinRecordingTime()
    if not recordingStartTime then return false end
    return (hs.timer.secondsSinceEpoch() - recordingStartTime) >= MIN_RECORD_SECS
end

-- Forward-declared above ensurePill so policyCallback can reference it
function stopDictation(autoEnter, stopSound)
    if not isRecording then return end
    if autoEnter == nil then autoEnter = AUTO_ENTER end
    isRecording = false
    -- Keep escHotkey running so ESC can cancel transcription
    enterHotkey:disable()
    shiftHotkey:stop()

    stopWaveAnimation()
    stopMicMonitor()
    recordingStartTime = nil
    if stopSound then
        playSoundFile(stopSound, 0.8)
    else
        playSound("Pop", 0.35)
    end
    showTranscribing()
    startLoadingSound()
    isTranscribing = true

    pendingFinalize = { autoEnter = autoEnter }
    if recPipelineTask and recPipelineTask:isRunning() then
        recPipelineTask:terminate()  -- bash script's trap flushes ffmpeg's last chunk
    else
        -- Defensive: pipeline already exited. Trigger finalisation directly.
        recPipelineDone = true
        processNextChunk()
    end
end

local function cleanupChunks()
    if chunkWatcher then chunkWatcher:stop(); chunkWatcher = nil end
    -- Wipe the whole chunk dir; never leave audio fragments around.
    hs.execute(string.format("rm -rf %q", CHUNK_DIR))
end

local function cancelDictation()
    if not isRecording then return end
    isRecording = false
    recordingStartTime = nil
    escHotkey:stop()
    enterHotkey:disable()
    shiftHotkey:stop()
    cancelRequested = true
    pendingFinalize = nil
    if recPipelineTask and recPipelineTask:isRunning() then recPipelineTask:terminate() end
    if pendingEnrichTask and pendingEnrichTask:isRunning() then pendingEnrichTask:terminate() end
    if activeChunkTask and activeChunkTask:isRunning() then activeChunkTask:terminate() end
    activeChunkTask    = nil
    pendingEnrichTask  = nil
    stopWaveAnimation()
    stopMicMonitor()
    playSoundFile("question-004.mp3", 0.7)
    hidePill()
    cleanupChunks()
end

local function cancelTranscription()
    if not isTranscribing then return end
    isTranscribing = false
    cancelRequested = true
    pendingFinalize = nil
    if recPipelineTask and recPipelineTask:isRunning() then recPipelineTask:terminate() end
    if pendingEnrichTask and pendingEnrichTask:isRunning() then pendingEnrichTask:terminate() end
    if activeChunkTask and activeChunkTask:isRunning() then activeChunkTask:terminate() end
    activeChunkTask    = nil
    pendingEnrichTask  = nil
    stopLoadingSound()
    playSoundFile("question-004.mp3", 0.7)
    hidePill()
    cleanupChunks()
    targetWindow = nil
    targetApp = nil
end

-- ============================================
-- Hotkeys
-- ============================================
hs.hotkey.bind({"cmd", "alt"}, "L", function()
    if pendingResult then
        -- Accept pending transcription → paste in current window
        acceptPending()
    elseif isRecording then
        stopDictation()
    else
        startDictation()
    end
end)

-- Escape eventtap — captura o Esc a nível baixo (antes do webview interceptar)
-- Cancels recording OR transcription
escHotkey = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    if event:getKeyCode() ~= 53 then return false end  -- 53 = Escape
    if pendingResult then
        dismissPending()
        return true
    end
    if isRecording then
        cancelDictation()
        return true
    end
    if isTranscribing then
        cancelTranscription()
        return true
    end
    return false
end)

-- Enter hotkey — para a gravação e faz auto-enter (tem prioridade sobre qualquer app)
-- Ignores press if recording is shorter than MIN_RECORD_SECS (prevents accidental stops)
enterHotkey = hs.hotkey.new({}, "return", function()
    if isRecording and hasMinRecordingTime() then
        stopDictation(true, "confirmation-002.mp3")
    end
end)

-- Shift key tap — para a gravação e cola o texto SEM fazer Enter
-- Uses eventtap to detect shift key press (since shift alone isn't a regular hotkey)
-- Ignores press if recording is shorter than MIN_RECORD_SECS (prevents accidental stops)
shiftHotkey = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    if not isRecording then return false end
    local flags = event:getFlags()
    -- Detect shift key press (not release), and no other modifiers
    if flags.shift and not flags.cmd and not flags.alt and not flags.ctrl then
        if hasMinRecordingTime() then
            stopDictation(false)
            return true  -- consume the event
        end
        return true  -- consume but ignore (too early)
    end
    return false
end)

require("hs.ipc")

-- Pré-aquecer o webview no startup para evitar atraso na primeira gravação.
-- Cria-se directamente OFF_SCREEN para nunca aparecer no top-center antes de :hide(),
-- mostra-se brevemente para inicializar o WKWebView, e esconde-se com :hide() (orderOut)
-- para garantir que sai da window list e não intercepta cliques.
hs.timer.doAfter(0.8, function()
    pillView = hs.webview.new(OFF_SCREEN_FRAME, { developerExtrasEnabled = false })
    pillView:windowStyle({"borderless", "nonactivating"})
    pillView:level(hs.canvas.windowLevels.overlay)
    pillView:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    pillView:allowTextEntry(false)
    pillView:transparent(true)
    pillView:alpha(0)
    pillView:html(shellHTML())
    pillView:show()        -- brief show off-screen+invisible to attach WKWebView
    hs.timer.doAfter(0.1, function()
        if pillView then pillView:hide() end
    end)
end)

hs.printf("Whisper Dictation loaded — \xe2\x8c\xa5\xe2\x8c\x98L toggle (webview pill v4)")
