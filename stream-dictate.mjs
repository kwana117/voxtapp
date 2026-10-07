#!/usr/bin/env node
// Ditado em tempo real: microfone → OpenAI gpt-live-transcribe → texto ao vivo.
//
// Uso (pelo Hammerspoon):
//   stream-dictate.mjs <dir>                  grava do microfone fixo até SIGTERM
//   stream-dictate.mjs <dir> --file a.wav     teste sem microfone, ao ritmo real
//
// stdout: uma linha JSON por evento
//   {"t":"ready"}                       ligação aberta, a transcrever
//   {"t":"live","text":"..."}           texto completo até agora (final + parcial)
//   {"t":"error","msg":"..."}           a API falhou; o áudio continua a ser gravado
//   {"t":"final","text":"...","failed":bool}   no fim; failed=true → usar fallback
//
// Sinais: SIGTERM = parar e entregar o texto; SIGINT = cancelar já.
// Todo o PCM (24 kHz mono s16le) fica em <dir>/_raw.pcm: alimenta o monitor de
// microfone do Hammerspoon e serve de fallback para o Whisper se a API falhar.
//
// Chave: VOXT_OPENAI_KEY em ~/.voxtapp.env, ou um ficheiro .env que já a guarde
// (VOXT_OPENAI_KEY_FILE + VOXT_OPENAI_KEY_VAR), ou OPENAI_API_KEY no ambiente.
// Cada sessão acrescenta "data segundos" a ~/.voxtapp-usage.log (custo = minutos × 0,017 $).

import { spawn } from "node:child_process";
import { appendFileSync, chmodSync, lstatSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";

const SAMPLE_RATE = 24000;              // o que a API Realtime espera
const CHUNK_BYTES = SAMPLE_RATE * 2 / 10; // 100 ms
const FINAL_TIMEOUT_MS = 6000;          // espera máxima pelo último bloco
// A API só fecha um bloco quando recebe "commit". Cortamos numa pausa depois de
// MIN_TURN_SECS, ou à força em MAX_TURN_SECS, para o buffer nunca crescer demais.
const MIN_TURN_SECS = 20;
const MAX_TURN_SECS = 120;
const PAUSE_MS = 400;
const SILENCE_RMS = 0.02;               // mesmo limiar do monitor de microfone

function loadEnvFile() {
    const env = {};
    try {
        for (const line of readFileSync(`${homedir()}/.voxtapp.env`, "utf8").split("\n")) {
            const m = line.match(/^\s*(VOXT_[\w]+)\s*=\s*"?([^"]*)"?\s*$/);
            if (m) env[m[1]] = m[2];
        }
    } catch { /* sem ficheiro: valores por omissão */ }
    return env;
}

const fileEnv = loadEnvFile();
const cfg = (k, d) => process.env[k] ?? fileEnv[k] ?? d;
const list = (s) => s.split(",").map(x => x.trim()).filter(Boolean);

// Lê uma variável de um ficheiro .env sem a pôr no ambiente de mais ninguém.
function keyFromFile(path, name) {
    if (!path) return "";
    try {
        const re = new RegExp(`^\\s*(?:export\\s+)?${name}\\s*=\\s*["']?([^"'\\s]+)`, "m");
        return readFileSync(path.replace(/^~(?=\/)/, homedir()), "utf8").match(re)?.[1] || "";
    } catch { return ""; }
}

const API_KEY = cfg("VOXT_OPENAI_KEY", "")
    || keyFromFile(cfg("VOXT_OPENAI_KEY_FILE", ""), cfg("VOXT_OPENAI_KEY_VAR", "OPENAI_API_KEY"))
    || process.env.OPENAI_API_KEY || "";
const MODEL = cfg("VOXT_STREAM_MODEL", "gpt-live-transcribe");
const DELAY = cfg("VOXT_STREAM_DELAY", "medium");
const LANGS = list(cfg("VOXT_STREAM_LANGS", "pt"));
const PROMPT = cfg("VOXT_STREAM_PROMPT",
    "Ditado informal em português de Portugal (tipo, epá, estás a ver, fixe), com termos técnicos em inglês.");
const KEYWORDS = list(cfg("VOXT_KEYTERMS", ""));
const INPUT_DEVICE = cfg("VOXT_INPUT_DEVICE", "MacBook Pro Microphone");

const dir = process.argv[2] || "/tmp/voxt-chunks";
const fileIdx = process.argv.indexOf("--file");
const testFile = fileIdx > 0 ? process.argv[fileIdx + 1] : null;
const rawPath = `${dir}/_raw.pcm`;

// A pasta guarda a tua voz e vive em /tmp: só tu a lês (700/600), e recusa-se
// se alguém a tiver trocado por um link ou for de outro utilizador.
rmSync(dir, { recursive: true, force: true });
{
    let st = null;
    try { mkdirSync(dir, { mode: 0o700 }); st = lstatSync(dir); } catch { /* alguém a criou entretanto */ }
    if (!st || st.isSymbolicLink() || !st.isDirectory() || st.uid !== process.getuid()) {
        process.stdout.write(JSON.stringify({ t: "final", text: "", failed: true }) + "\n");
        process.exit(1);
    }
    chmodSync(dir, 0o700);
}

process.stdout.on("error", () => {});   // Hammerspoon pode fechar o pipe primeiro
const emit = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");

// ── Estado da transcrição ──────────────────────────────────────────────────
const order = [];                     // item_id pela ordem em que aparecem
const texts = new Map();              // item_id → texto (deltas, depois o final)
let commitsSent = 0;
let commitsDone = 0;                  // blocos com transcrição final (ou falhada)
let apiFailed = !API_KEY;
let ws = null;
let wsOpen = false;
let pending = [];                     // áudio à espera da ligação abrir
let carry = Buffer.alloc(0);
let uncommittedBytes = 0;
let silenceMs = 0;
let sentBytes = 0;                    // áudio que chegou à API (é o que se paga)
let stopping = false;
let finished = false;

const fullText = () => order.map(id => (texts.get(id) || "").trim()).filter(Boolean).join(" ");

function touchItem(id) {
    if (!texts.has(id)) { texts.set(id, ""); order.push(id); }
}

// Uma linha por ditado: "data segundos estado". Conta o áudio enviado, mesmo
// em ditados cancelados ou em que a API falhou a meio, porque esse também se paga.
let usageLogged = false;
function logUsage(estado) {
    if (usageLogged || testFile) return;
    usageLogged = true;
    const secs = Math.round(sentBytes / (SAMPLE_RATE * 2));
    if (secs > 0) {
        try { appendFileSync(`${homedir()}/.voxtapp-usage.log`, `${new Date().toISOString()} ${secs} ${estado}\n`, { mode: 0o600 }); } catch {}
    }
}

function fail(msg) {
    if (!apiFailed) emit({ t: "error", msg });
    apiFailed = true;
    pending = [];
    if (stopping) finish();
}

function finish() {
    if (finished) return;
    finished = true;
    logUsage(apiFailed ? "falhou" : "ok");
    const text = fullText();
    emit({ t: "final", text, failed: !text });   // sem texto → o Hammerspoon tenta o Whisper
    try { ws?.close(); } catch {}
    process.exit(0);
}

function maybeFinish() {
    if (stopping && commitsDone >= commitsSent) finish();
}

function send(obj) {
    try { ws.send(JSON.stringify(obj)); } catch (e) { fail(`envio falhou: ${e.message}`); }
}

function sendAppend(buf) {
    send({ type: "input_audio_buffer.append", audio: buf.toString("base64") });
    sentBytes += buf.length;
}

function appendAudio(buf) {
    if (apiFailed) return;
    if (!wsOpen) { pending.push(buf); return; }
    sendAppend(buf);
}

function commit() {
    // A API rejeita commits com menos de 100 ms de áudio.
    if (apiFailed || uncommittedBytes < CHUNK_BYTES) return false;
    if (!wsOpen) return false;
    send({ type: "input_audio_buffer.commit" });
    commitsSent++;
    uncommittedBytes = 0;
    silenceMs = 0;
    return true;
}

function rms(buf) {
    let sum = 0;
    const n = buf.length >> 1;
    for (let i = 0; i < n; i++) { const s = buf.readInt16LE(i * 2) / 32768; sum += s * s; }
    return n ? Math.sqrt(sum / n) : 0;
}

// Junta o PCM em blocos de 100 ms, envia, e corta blocos longos numa pausa.
function onPcm(data) {
    appendFileSync(rawPath, data, { mode: 0o600 });
    carry = Buffer.concat([carry, data]);
    while (carry.length >= CHUNK_BYTES) {
        const chunk = carry.subarray(0, CHUNK_BYTES);
        carry = carry.subarray(CHUNK_BYTES);
        appendAudio(chunk);
        uncommittedBytes += chunk.length;
        silenceMs = rms(chunk) < SILENCE_RMS ? silenceMs + 100 : 0;
        const turnSecs = uncommittedBytes / (SAMPLE_RATE * 2);
        if (wsOpen && ((turnSecs >= MIN_TURN_SECS && silenceMs >= PAUSE_MS) || turnSecs >= MAX_TURN_SECS)) {
            commit();
        }
    }
}

// ── Ligação à OpenAI ───────────────────────────────────────────────────────
function connect() {
    if (apiFailed) { emit({ t: "error", msg: "sem chave OpenAI (ver VOXT_OPENAI_KEY em ~/.voxtapp.env)" }); return; }
    ws = new WebSocket("wss://api.openai.com/v1/realtime?intent=transcription", {
        headers: { Authorization: `Bearer ${API_KEY}` },
    });
    ws.onopen = () => {
        const transcription = { model: MODEL, delay: DELAY, prompt: PROMPT };
        if (LANGS.length) transcription.languages = LANGS;
        if (KEYWORDS.length) transcription.keywords = KEYWORDS;
        ws.send(JSON.stringify({
            type: "session.update",
            session: {
                type: "transcription",
                audio: { input: {
                    format: { type: "audio/pcm", rate: SAMPLE_RATE },
                    transcription,
                    turn_detection: null,
                } },
            },
        }));
    };
    ws.onmessage = (ev) => {
        let e;
        try { e = JSON.parse(typeof ev.data === "string" ? ev.data : Buffer.from(ev.data).toString()); } catch { return; }
        switch (e.type) {
            case "session.updated":
                if (!wsOpen) {
                    wsOpen = true;
                    for (const b of pending) sendAppend(b);
                    pending = [];
                    emit({ t: "ready" });
                    if (stopping) endStream();
                }
                break;
            case "conversation.item.input_audio_transcription.delta":
                touchItem(e.item_id);
                texts.set(e.item_id, texts.get(e.item_id) + (e.delta || ""));
                emit({ t: "live", text: fullText() });
                break;
            case "conversation.item.input_audio_transcription.completed":
                touchItem(e.item_id);
                texts.set(e.item_id, e.transcript || texts.get(e.item_id));
                commitsDone++;
                emit({ t: "live", text: fullText() });
                maybeFinish();
                break;
            case "conversation.item.input_audio_transcription.failed":
                commitsDone++;      // fica o texto parcial que já tínhamos
                maybeFinish();
                break;
            case "error": {
                const msg = e.error?.message || JSON.stringify(e.error || e);
                // Erro num commit durante a paragem (ex.: buffer vazio) não estraga o resto.
                if (stopping && commitsSent > commitsDone) { commitsDone++; maybeFinish(); }
                else fail(msg);
                break;
            }
        }
    };
    ws.onerror = (ev) => fail(`ligação falhou: ${ev.message || "erro de rede"}`);
    ws.onclose = (ev) => {
        const wasOpen = wsOpen;
        wsOpen = false;
        if (stopping) finish();
        else if (!finished) fail(`ligação fechou (${ev.code}${wasOpen ? "" : ", antes de abrir"})`);
    };
}

// ── Fonte de áudio ─────────────────────────────────────────────────────────
let rec = null;
let fileTimer = null;

function startMic() {
    rec = spawn("/opt/homebrew/bin/sox", [
        "-q", "-t", "coreaudio", "-r", "48000", "-c", "1", INPUT_DEVICE,
        "-r", String(SAMPLE_RATE), "-c", "1", "-b", "16", "-e", "signed", "-t", "raw", "-",
    ], { stdio: ["ignore", "pipe", "ignore"] });
    rec.stdout.on("data", onPcm);
    rec.on("exit", () => { rec = null; if (stopping) endStream(); });
}

function startFile(path) {
    // Converte para PCM 24 kHz e envia ao ritmo real.
    const conv = spawn("/opt/homebrew/bin/sox", [path, "-r", String(SAMPLE_RATE), "-c", "1", "-b", "16", "-e", "signed", "-t", "raw", "-"]);
    const parts = [];
    conv.stdout.on("data", d => parts.push(d));
    conv.on("exit", () => {
        const pcm = Buffer.concat(parts);
        let pos = 0;
        fileTimer = setInterval(() => {
            const b = pcm.subarray(pos, pos + CHUNK_BYTES);
            pos += CHUNK_BYTES;
            if (b.length) onPcm(b);
            if (pos >= pcm.length) { clearInterval(fileTimer); stop(); }
        }, 100);
    });
}

function endStream() {
    if (apiFailed || !ws) return finish();
    if (!wsOpen) return;                  // session.updated chama endStream() outra vez
    // Envia o resto do áudio (completado com silêncio até 100 ms) e fecha o bloco.
    if (carry.length) {
        const buf = Buffer.concat([carry, Buffer.alloc(Math.max(0, CHUNK_BYTES - carry.length))]);
        carry = Buffer.alloc(0);
        appendAudio(buf);
        uncommittedBytes += buf.length;
    }
    commit();
    maybeFinish();
}

function stop() {
    if (stopping) return;
    stopping = true;
    setTimeout(finish, FINAL_TIMEOUT_MS);
    if (rec) rec.kill("SIGTERM");   // o 'exit' do sox chama endStream()
    else endStream();
}

process.on("SIGTERM", stop);
process.on("SIGINT", () => {
    logUsage("cancelado");
    try { rec?.kill("SIGKILL"); ws?.close(); } catch {}
    process.exit(130);
});

connect();
if (testFile) startFile(testFile); else startMic();
