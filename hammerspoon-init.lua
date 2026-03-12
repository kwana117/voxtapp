-- ============================================
-- Whisper Dictation — Option+Cmd+L toggle
-- Com barra de estado visual
-- ============================================

local dictateScript = os.getenv("HOME") .. "/scripts/dictate.sh"
local isRecording = false
local statusBar = nil
local statusTimer = nil
local dotCount = 0
local recTask = nil

-- ============================================
-- Barra de estado (canvas no topo do ecrã)
-- ============================================
local BAR_HEIGHT = 36

local function getBarFrame()
    local screen = hs.screen.mainScreen():frame()
    return { x = screen.x, y = screen.y, w = screen.w, h = BAR_HEIGHT }
end

local function createBar(text, bgColor, textColor)
    if statusBar then statusBar:delete() end
    local frame = getBarFrame()
    statusBar = hs.canvas.new(frame)
    statusBar:level(hs.canvas.windowLevels.overlay)
    statusBar:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    statusBar[1] = {
        type = "rectangle",
        frame = { x = 0, y = 0, w = "100%", h = "100%" },
        roundedRectRadii = { xRadius = 0, yRadius = 0 },
        fillColor = bgColor,
        strokeWidth = 0,
    }

    local startIdx = 2
    if isRecording then
        statusBar[2] = {
            type = "circle",
            frame = { x = 14, y = 10, w = 16, h = 16 },
            fillColor = { red = 1, green = 0.2, blue = 0.2, alpha = 1 },
            strokeWidth = 0,
        }
        startIdx = 3
    end

    local textX = isRecording and 40 or 14
    statusBar[startIdx] = {
        type = "text",
        frame = { x = textX, y = 0, w = frame.w - textX - 20, h = BAR_HEIGHT },
        text = hs.styledtext.new(text, {
            font = { name = ".AppleSystemUIFont", size = 14 },
            color = textColor,
            paragraphStyle = { lineHeightMultiple = 2.2 },
        }),
    }

    statusBar:alpha(0.92)
    statusBar:show()
end

local function showRecording()
    dotCount = (dotCount % 3) + 1
    local dots = string.rep(".", dotCount)
    createBar(
        "Recording" .. dots .. "   (⌥⌘L to stop)",
        { red = 0.1, green = 0.1, blue = 0.15, alpha = 0.95 },
        { red = 1, green = 1, blue = 1, alpha = 0.9 }
    )
end

local function showTranscribing()
    isRecording = false  -- ensure dot indicator gone
    createBar(
        "Transcribing...",
        { red = 0.1, green = 0.1, blue = 0.2, alpha = 0.95 },
        { red = 0.6, green = 0.7, blue = 1, alpha = 0.9 }
    )
end

local function showResult(text)
    isRecording = false
    if not text or text == "" then
        text = "(nenhum texto detectado)"
    end
    createBar(
        "✓ " .. text,
        { red = 0.05, green = 0.15, blue = 0.1, alpha = 0.95 },
        { red = 0.5, green = 1, blue = 0.7, alpha = 0.9 }
    )
    hs.timer.doAfter(4, function()
        if statusBar then statusBar:delete(); statusBar = nil end
    end)
end

local function hideBar()
    if statusBar then statusBar:delete(); statusBar = nil end
end

-- ============================================
-- Recording: launch rec directly via hs.task
-- This way Hammerspoon controls the process
-- ============================================
local function startDictation()
    if isRecording then return end
    isRecording = true
    dotCount = 0
    showRecording()

    statusTimer = hs.timer.doEvery(0.5, function()
        if isRecording then showRecording() end
    end)

    -- Start rec directly (not via script) — non-blocking because rec runs forever
    recTask = hs.task.new("/opt/homebrew/bin/rec", function(code, out, err)
        -- rec terminated (we killed it)
    end, {
        "-r", "16000", "-c", "1", "-b", "16", "/tmp/dictation.wav"
    })
    recTask:start()
end

local function stopDictation()
    if not isRecording then return end
    isRecording = false

    if statusTimer then statusTimer:stop(); statusTimer = nil end

    -- Kill rec
    if recTask and recTask:isRunning() then
        recTask:terminate()
    end
    recTask = nil

    showTranscribing()

    -- Run transcription in background via hs.task (this one finishes)
    hs.task.new("/bin/bash", function(code, out, err)
        -- Read result
        local result = ""
        local rf = io.open("/tmp/dictation.result", "r")
        if rf then
            result = rf:read("*a"):gsub("^%s+", ""):gsub("%s+$", "")
            rf:close()
            os.remove("/tmp/dictation.result")
        end
        if result ~= "" then
            showResult(result)
        else
            showResult(nil)
        end
    end, { dictateScript, "stop-transcribe-only" }):start()
end

local function cancelDictation()
    if not isRecording then return end
    isRecording = false
    if statusTimer then statusTimer:stop(); statusTimer = nil end
    if recTask and recTask:isRunning() then recTask:terminate() end
    recTask = nil
    hideBar()
    os.remove("/tmp/dictation.wav")
end

-- ============================================
-- Eventtap global — Option+Cmd+L toggle
-- ============================================
local keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    local keyCode = event:getKeyCode()
    local flags = event:getFlags()

    if keyCode == 37 and flags.cmd and flags.alt and not flags.ctrl and not flags.shift then
        if isRecording then
            stopDictation()
        else
            startDictation()
        end
        return true
    end
    return false
end)
keyTap:start()

require("hs.ipc")
hs.printf("Whisper Dictation loaded — Option+Cmd+L toggle")
