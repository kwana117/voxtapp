-- ============================================
-- Whisper Dictation — Option+Cmd+L toggle
-- Floating macOS pill via hs.webview
-- ============================================

local dictateScript = os.getenv("HOME") .. "/scripts/dictate.sh"
local isRecording = false
local pillView = nil
local animTimer = nil
local dotCount = 0
local recTask = nil
local pulseOn = true

-- ============================================
-- Pill dimensions
-- ============================================
local PILL_W = 320
local PILL_H = 48
local PILL_Y = 12

local function getPillFrame()
    local scr = hs.screen.mainScreen():frame()
    return hs.geometry.rect(
        scr.x + math.floor((scr.w - PILL_W) / 2),
        scr.y + PILL_Y,
        PILL_W,
        PILL_H
    )
end

-- ============================================
-- HTML pill
-- ============================================
local function pillHTML(opts)
    -- opts: text, color, bgColor, dotColor, badge, icon
    local dot = ""
    if opts.dotColor then
        local opacity = opts.dotDim and "0.4" or "1"
        dot = string.format([[
            <div style="
                width:10px; height:10px; border-radius:50%%;
                background:%s; opacity:%s;
                box-shadow: 0 0 8px 2px %s;
                flex-shrink:0;
            "></div>
        ]], opts.dotColor, opacity, opts.dotColor)
    end

    local icon = ""
    if opts.icon then
        icon = string.format([[<span style="margin-right:4px;">%s</span>]], opts.icon)
    end

    local badge = ""
    if opts.badge then
        badge = string.format([[
            <div style="
                background: rgba(255,255,255,0.1);
                border-radius: 6px;
                padding: 3px 10px;
                font-size: 11px;
                color: rgba(255,255,255,0.45);
                white-space: nowrap;
                flex-shrink: 0;
                letter-spacing: 0.3px;
            ">%s</div>
        ]], opts.badge)
    end

    return string.format([[
        <html>
        <head><style>
            * { margin:0; padding:0; box-sizing:border-box; }
            html, body {
                background: transparent;
                overflow: hidden;
                height: 100%%;
            }
            .pill {
                display: flex;
                align-items: center;
                gap: 10px;
                height: 100%%;
                padding: 0 16px;
                background: %s;
                border-radius: 14px;
                border: 0.5px solid rgba(255,255,255,0.12);
                box-shadow:
                    0 4px 24px rgba(0,0,0,0.45),
                    0 1px 3px rgba(0,0,0,0.3),
                    inset 0 0.5px 0 rgba(255,255,255,0.06);
                backdrop-filter: blur(40px) saturate(1.5);
                -webkit-backdrop-filter: blur(40px) saturate(1.5);
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 13px;
                color: %s;
                -webkit-font-smoothing: antialiased;
            }
            .text {
                flex: 1;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
                font-weight: 500;
                letter-spacing: -0.1px;
            }
        </style></head>
        <body>
            <div class="pill">
                %s
                <div class="text">%s%s</div>
                %s
            </div>
        </body>
        </html>
    ]], opts.bgColor or "rgba(28,28,32,0.85)", opts.color or "rgba(255,255,255,0.9)",
        dot, icon, opts.text, badge)
end

local function showPill(opts)
    if pillView then pillView:delete(); pillView = nil end

    local frame = getPillFrame()
    pillView = hs.webview.new(frame, { developerExtrasEnabled = false })
    pillView:windowStyle({"borderless", "nonactivating"})
    pillView:level(hs.canvas.windowLevels.overlay)
    pillView:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    pillView:allowTextEntry(false)
    pillView:transparent(true)
    pillView:alpha(1.0)
    pillView:html(pillHTML(opts))
    pillView:show()
end

-- ============================================
-- States
-- ============================================
local function showRecording()
    dotCount = (dotCount % 3) + 1
    pulseOn = not pulseOn
    showPill({
        text = "Recording" .. string.rep(".", dotCount),
        bgColor = "rgba(28, 28, 32, 0.82)",
        color = "rgba(255,255,255,0.92)",
        dotColor = "#ff4444",
        dotDim = not pulseOn,
        badge = "Stop ⌥⌘L",
    })
end

local function showTranscribing()
    showPill({
        text = "Transcribing...",
        bgColor = "rgba(24, 26, 40, 0.82)",
        color = "rgba(140, 170, 255, 0.92)",
    })
end

local function showResult(text)
    if not text or text == "" then text = "(no text detected)" end
    if #text > 42 then text = text:sub(1, 39) .. "..." end
    showPill({
        text = text,
        bgColor = "rgba(22, 34, 26, 0.82)",
        color = "rgba(120, 240, 160, 0.92)",
        icon = "✓",
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
    showRecording()

    animTimer = hs.timer.doEvery(0.45, function()
        if isRecording then showRecording() end
    end)

    recTask = hs.task.new("/opt/homebrew/bin/rec", function() end, {
        "-r", "16000", "-c", "1", "-b", "16", "/tmp/dictation.wav",
    })
    recTask:start()
end

local function stopDictation()
    if not isRecording then return end
    isRecording = false

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
        showResult(result ~= "" and result or nil)
    end, { dictateScript, "stop-transcribe-only" }):start()
end

local function cancelDictation()
    if not isRecording then return end
    isRecording = false
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

hs.hotkey.bind({}, "escape", function()
    if isRecording then
        cancelDictation()
    else
        return false
    end
end)

require("hs.ipc")
hs.printf("Whisper Dictation loaded — ⌥⌘L toggle (webview pill)")
