-- ============================================
-- Whisper Dictation — Option+Cmd+L toggle
-- Floating macOS pill via hs.webview
-- ============================================

local dictateScript = os.getenv("HOME") .. "/scripts/dictate.sh"

-- ============================================
-- Configuração
-- ============================================
local AUTO_ENTER = true   -- true = pressiona Enter automaticamente após colar
local isRecording = false
local pillView = nil
local animTimer = nil
local dotCount = 0
local recTask = nil
local pulseOn = true
local escHotkey = nil    -- forward declaration, created after cancelDictation
local enterHotkey = nil  -- forward declaration, created after stopDictation
local targetWindow = nil
local targetApp = nil

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
            }
            .dot {
                width: 10px; height: 10px; border-radius: 50%%;
                background: #ff4444;
                box-shadow: 0 0 8px 2px rgba(255,68,68,0.4);
                flex-shrink: 0;
                transition: opacity 0.4s ease;
            }
            .dot.hidden { display: none; }
            .text {
                flex: 1;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
                font-weight: 500;
                letter-spacing: -0.1px;
            }
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
            .badge:hover {
                background: rgba(255,255,255,0.18);
                color: rgba(255,255,255,0.7);
            }
            .badge:active {
                background: rgba(255,255,255,0.25);
            }
            .badge.hidden { display: none; }
        </style></head>
        <body>
            <div class="wrapper">
                <div class="pill" id="pill">
                    <div class="dot hidden" id="dot"></div>
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
    local js = string.format([[
        (function() {
            var pill = document.getElementById('pill');
            var dot = document.getElementById('dot');
            var text = document.getElementById('text');
            var badge = document.getElementById('badge');

            pill.style.background = '%s';
            pill.style.color = '%s';

            dot.className = 'dot%s';
            dot.style.opacity = '%s';

            text.textContent = '%s';

            badge.className = 'badge%s';
            badge.textContent = '%s';
        })();
    ]],
        opts.bg or "rgba(28,28,32,0.82)",
        opts.color or "rgba(255,255,255,0.9)",
        opts.showDot and "" or " hidden",
        opts.dotOpacity or "1",
        opts.text or "",
        opts.badge and "" or " hidden",
        opts.badge or ""
    )
    pillView:evaluateJavaScript(js)
end

-- ============================================
-- States
-- ============================================
local function showRecording()
    dotCount = (dotCount % 3) + 1
    pulseOn = not pulseOn
    updatePill({
        text = "Recording" .. string.rep(".", dotCount),
        bg = "rgba(28, 28, 32, 0.82)",
        color = "rgba(255,255,255,0.92)",
        showDot = true,
        dotOpacity = pulseOn and "1" or "0.4",
        badge = "Stop ↵",
    })
end

local function showTranscribing()
    updatePill({
        text = "Transcribing...",
        bg = "rgba(24, 26, 40, 0.82)",
        color = "rgba(140, 170, 255, 0.92)",
        showDot = false,
    })
end

local function showResult(text)
    if not text or text == "" then text = "(no text detected)" end
    if #text > 42 then text = text:sub(1, 39) .. "..." end
    updatePill({
        text = "✓ " .. text,
        bg = "rgba(22, 34, 26, 0.82)",
        color = "rgba(120, 240, 160, 0.92)",
        showDot = false,
    })
    hs.timer.doAfter(3.5, function()
        if pillView then pillView:delete(); pillView = nil end
    end)
end

local function hidePill()
    if pillView then pillView:delete(); pillView = nil end
end

-- ============================================
-- Dictation control
-- ============================================
local function startDictation()
    if isRecording then return end
    isRecording = true
    dotCount = 0
    pulseOn = true

    -- Guardar janela ativa AGORA (antes de qualquer mudança de foco)
    targetWindow = hs.window.focusedWindow()
    targetApp = hs.application.frontmostApplication()

    escHotkey:enable()
    enterHotkey:enable()
    ensurePill()
    hs.timer.doAfter(0.1, function()
        showRecording()
    end)

    animTimer = hs.timer.doEvery(0.6, function()
        if isRecording then showRecording() end
    end)

    recTask = hs.task.new("/opt/homebrew/bin/rec", function() end, {
        "-r", "16000", "-c", "1", "-b", "16", "/tmp/dictation.wav",
    })
    recTask:start()
end

-- Forward-declared above ensurePill so policyCallback can reference it
function stopDictation()
    if not isRecording then return end
    isRecording = false
    escHotkey:disable()
    enterHotkey:disable()

    if animTimer then animTimer:stop(); animTimer = nil end
    if recTask and recTask:isRunning() then recTask:terminate() end
    recTask = nil

    showTranscribing()

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
                if AUTO_ENTER then
                    hs.timer.doAfter(0.05, function()
                        hs.eventtap.keyStroke({}, "return")
                    end)
                end
                targetWindow = nil
                targetApp = nil
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
    if animTimer then animTimer:stop(); animTimer = nil end
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

-- Enter hotkey — para a gravação (tem prioridade sobre qualquer app)
enterHotkey = hs.hotkey.new({}, "return", function()
    if isRecording then stopDictation() end
end)

require("hs.ipc")
hs.printf("Whisper Dictation loaded — ⌥⌘L toggle (webview pill v3)")
