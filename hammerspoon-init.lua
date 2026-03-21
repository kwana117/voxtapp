-- ============================================
-- Whisper Dictation — Option+Cmd+L toggle
-- Floating macOS pill via hs.webview
-- ============================================

local dictateScript = os.getenv("HOME") .. "/scripts/dictate.sh"

-- ============================================
-- Configuração
-- ============================================
local AUTO_ENTER = true
local isRecording = false
local pillView = nil
local recTask = nil
local escHotkey = nil
local enterHotkey = nil
local shiftHotkey = nil
local targetWindow = nil
local targetApp = nil
local loadingSound = nil

-- ============================================
-- Sound feedback
-- ============================================
local function playSound(name, vol)
    local s = hs.sound.getByName(name)
    if s then s:volume(vol or 0.5); s:play() end
end

local function stopLoadingSound()
    if loadingSound then loadingSound:stop(); loadingSound = nil end
end

local function startLoadingSound()
    stopLoadingSound()
    loadingSound = hs.sound.getByName("Purr")
    if loadingSound then
        loadingSound:volume(0.18)
        loadingSound:looping(true)
        loadingSound:play()
    end
end

-- ============================================
-- Pill dimensions (webview is larger to hide window edges)
-- ============================================
local PILL_W = 320
local PILL_H = 48
local PAD = 20  -- extra padding around pill to hide window rect corners
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

-- ============================================
-- HTML shell (pill centred inside padded webview)
-- ============================================
local function shellHTML()
    return string.format([[
        <html>
        <head><style>
            * { margin:0; padding:0; box-sizing:border-box; }
            html, body {
                background: transparent !important;
                overflow: hidden;
                width: 100%%;
                height: 100%%;
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
                    0 8px 32px rgba(0,0,0,0.4),
                    0 2px 8px rgba(0,0,0,0.25);
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
            @keyframes waveBar {
                from { height: 3px;  opacity: 0.5; }
                to   { height: 16px; opacity: 1.0; }
            }
            .wave b {
                display: block;
                width: 3px;
                border-radius: 2px;
                background: #ff5252;
                box-shadow: 0 0 5px rgba(255,82,82,0.55);
                animation: waveBar 0.65s ease-in-out infinite alternate;
            }
            .wave b:nth-child(1) { animation-delay: 0.00s; }
            .wave b:nth-child(2) { animation-delay: 0.11s; }
            .wave b:nth-child(3) { animation-delay: 0.22s; }
            .wave b:nth-child(4) { animation-delay: 0.11s; }
            .wave b:nth-child(5) { animation-delay: 0.00s; }
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
                cursor: pointer;
                user-select: none;
                -webkit-user-select: none;
                transition: background 0.15s ease;
            }
            .badge:hover  { background: rgba(255,255,255,0.18); color: rgba(255,255,255,0.7); }
            .badge:active { background: rgba(255,255,255,0.25); }
            .badge.hidden { display: none; }
        </style></head>
        <body>
            <div class="wrapper">
                <div class="pill" id="pill">
                    <div class="wave hidden" id="wave"><b></b><b></b><b></b><b></b><b></b></div>
                    <div class="spinner hidden" id="spinner"></div>
                    <div class="text" id="text"></div>
                    <div class="badge hidden" id="badge"
                         onclick="window.location='hammerspoon://stop'; return false;"></div>
                </div>
            </div>
        </body>
        </html>
    ]], PAD, PILL_W, PILL_H)
end

-- URL event handler for badge click
hs.urlevent.bind("stop", function()
    if isRecording then stopDictation() end
end)

local function ensurePill()
    if pillView then return end
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
    })
end

local function showResult(text)
    stopLoadingSound()
    playSound("Glass", 0.5)
    if not text or text == "" then text = "(no text detected)" end
    if #text > 42 then text = text:sub(1, 39) .. "..." end
    updatePill({
        text  = "\xe2\x9c\x93 " .. text,
        bg    = "rgba(22, 34, 26, 0.82)",
        color = "rgba(120, 240, 160, 0.92)",
    })
    hs.timer.doAfter(3.5, function()
        if pillView then pillView:delete(); pillView = nil end
    end)
end

local function hidePill()
    stopLoadingSound()
    if pillView then pillView:delete(); pillView = nil end
end

-- ============================================
-- Dictation control
-- ============================================
local function startDictation()
    if isRecording then return end
    isRecording = true

    -- Guardar janela ativa AGORA (antes de qualquer mudança de foco)
    targetWindow = hs.window.focusedWindow()
    targetApp    = hs.application.frontmostApplication()

    escHotkey:enable()
    enterHotkey:enable()
    shiftHotkey:start()

    playSound("Tink", 0.45)
    ensurePill()
    hs.timer.doAfter(0.1, showRecording)

    recTask = hs.task.new("/opt/homebrew/bin/rec", function() end, {
        "-r", "16000", "-c", "1", "-b", "16", "/tmp/dictation.wav",
    })
    recTask:start()
end

-- Forward-declared above ensurePill so policyCallback can reference it
function stopDictation(autoEnter)
    if not isRecording then return end
    if autoEnter == nil then autoEnter = AUTO_ENTER end
    isRecording = false
    escHotkey:disable()
    enterHotkey:disable()
    shiftHotkey:stop()

    if recTask and recTask:isRunning() then recTask:terminate() end
    recTask = nil

    playSound("Pop", 0.35)
    showTranscribing()
    startLoadingSound()

    hs.task.new("/bin/bash", function(code, out, err)
        local result = ""
        local rf = io.open("/tmp/dictation.result", "r")
        if rf then
            result = rf:read("*a"):gsub("^%s+", ""):gsub("%s+$", "")
            rf:close()
            os.remove("/tmp/dictation.result")
        end

        if result ~= "" then
            -- Focar janela original e colar
            if targetWindow then
                targetWindow:focus()
            elseif targetApp then
                targetApp:activate(true)
            end
            hs.timer.doAfter(0.3, function()
                hs.eventtap.keyStroke({"cmd"}, "v")
                if autoEnter then
                    hs.timer.doAfter(0.05, function()
                        hs.eventtap.keyStroke({}, "return")
                    end)
                end
                targetWindow = nil
                targetApp    = nil
            end)
        end

        showResult(result ~= "" and result or nil)
    end, { dictateScript, "stop-transcribe-only" }):start()
end

local function cancelDictation()
    if not isRecording then return end
    isRecording = false
    escHotkey:disable()
    enterHotkey:disable()
    shiftHotkey:stop()
    if recTask and recTask:isRunning() then recTask:terminate() end
    recTask = nil
    hidePill()
    os.remove("/tmp/dictation.wav")
end

-- ============================================
-- Hotkeys
-- ============================================
hs.hotkey.bind({"cmd", "alt"}, "L", function()
    if isRecording then
        stopDictation()
    else
        startDictation()
    end
end)

-- Escape hotkey — enabled/disabled dynamically with recording state
escHotkey = hs.hotkey.new({}, "escape", function()
    cancelDictation()
end)

-- Enter hotkey — para a gravação e faz auto-enter (tem prioridade sobre qualquer app)
enterHotkey = hs.hotkey.new({}, "return", function()
    if isRecording then stopDictation(true) end
end)

-- Shift key tap — para a gravação e cola o texto SEM fazer Enter
-- Uses eventtap to detect shift key press (since shift alone isn't a regular hotkey)
shiftHotkey = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    if not isRecording then return false end
    local flags = event:getFlags()
    -- Detect shift key press (not release), and no other modifiers
    if flags.shift and not flags.cmd and not flags.alt and not flags.ctrl then
        stopDictation(false)
        return true  -- consume the event
    end
    return false
end)

require("hs.ipc")
hs.printf("Whisper Dictation loaded — \xe2\x8c\xa5\xe2\x8c\x98L toggle (webview pill v4)")
