// Cenas por trás do texto ao vivo do VoxTap: seis desenhos que reagem à voz.
// Corre dentro da pílula (o Hammerspoon junta este ficheiro ao HTML) e na
// página de demonstração.
//
//   VoxScenes.feed(rms, graves, médios, agudos)   valores do microfone, ~20 por segundo
//   VoxScenes.simulate(true|false)                voz falsa, para pré-visualizar
//   VoxScenes.create(canvas) → { show(id, rodarSegs), hide() }
//   VoxScenes.list                                [{ id, name }] pela ordem do menu
//
// Os valores chegam aos saltos (20 por segundo); a fluidez vem de os suavizar a
// cada imagem. Sobe depressa, desce devagar, como um medidor de áudio.
(function () {
    "use strict";
    const TAU = Math.PI * 2;
    const COLS = [[255, 112, 72], [255, 82, 170], [96, 186, 255]];   // graves, médios, agudos
    const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
    const rgba = (c, a) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${clamp(a)})`;
    const taper = u => Math.pow(Math.sin(Math.PI * clamp(u)), 1.4);   // esbate as pontas

    // ── Som ────────────────────────────────────────────────────────────────
    const A = { lvl: 0, sh: [.4, .4, .2], tl: 0, tsh: [.4, .4, .2], onsets: 0, peak: .05, prev: 0 };
    const api = { onLevel: null };

    function target(lvl, bands) {
        const tot = bands[0] + bands[1] + bands[2];
        A.tl = clamp(lvl);
        A.tsh = tot > 0 ? bands.map(x => x / tot) : [1 / 3, 1 / 3, 1 / 3];
        if (A.tl - A.prev > .1 && A.tl > .15) A.onsets++;   // início de sílaba
        A.prev = A.tl;
        if (api.onLevel) api.onLevel(A.tl);
    }

    // RMS 0..1 e RMS de cada banda; ganho automático para a voz encher a cena.
    // O pico esquece-se em ~2 s (um "p" forte não abafa o resto da frase) e a
    // curva levanta a voz baixa, para a cena mexer mesmo a falar devagar.
    function feed(rms, lo, mi, hi) {
        if (sim.timer) return;
        A.peak = Math.max(rms, A.peak * .985, .02);
        target(Math.pow(clamp((rms - .004) / A.peak), .6), [lo, mi * 1.3, hi * 3.5]);
    }

    function mix(weights) {
        const c = [0, 0, 0];
        let s = 0;
        for (let k = 0; k < 3; k++) s += weights[k];
        for (let j = 0; j < 3; j++) for (let k = 0; k < 3; k++) c[j] += COLS[k][j] * weights[k] / (s || 1);
        return c;
    }

    // ── Voz simulada: sílabas com ataque rápido e queda lenta, frases e pausas ──
    const sim = { timer: null, syl: [], until: 0 };
    function simStep() {
        const now = performance.now();
        while (sim.until < now + 2500) {
            let t = Math.max(sim.until, now);
            const n = 6 + Math.floor(Math.random() * 10);
            for (let i = 0; i < n; i++) {
                const fric = Math.random() < .15;
                sim.syl.push({ t, amp: .45 + Math.random() * .55,
                    w: fric ? [.15, .25, .9] : [.35 + Math.random() * .6, .3 + Math.random() * .5, .05 + Math.random() * .3] });
                t += 150 + Math.random() * 120 + (Math.random() < .25 ? 90 : 0);
            }
            sim.until = t + 450 + Math.random() * 800;
        }
        sim.syl = sim.syl.filter(s => now - s.t < 1500);
        let e = 0;
        const b = [0, 0, 0];
        for (const s of sim.syl) {
            const x = now - s.t;
            if (x < 0) continue;
            const env = s.amp * (x < 40 ? x / 40 : Math.exp(-(x - 40) / 140));
            e += env;
            for (let k = 0; k < 3; k++) b[k] += env * s.w[k];
        }
        target(e * .85 + .015, b);
    }
    function simulate(on) {
        if (on && !sim.timer) { sim.until = 0; sim.syl = []; sim.timer = setInterval(simStep, 50); }
        if (!on && sim.timer) { clearInterval(sim.timer); sim.timer = null; target(0, [1, 1, 1]); }
    }

    // ── Cenas ──────────────────────────────────────────────────────────────
    const SCENES = {
        ribbon: {
            name: "Fita líquida",
            init(st) { st.ph = [0, 2, 4]; },
            draw(st, g, w, h, t, dt) {
                g.clearRect(0, 0, w, h);
                g.globalCompositeOperation = "lighter";
                const cy = h * .58, breathe = .05 + .03 * Math.sin(t * .0011);
                for (let k = 0; k < 3; k++) {
                    st.ph[k] += dt * (.0005 + .0035 * A.lvl) * (1 + k * .35);
                    const amp = h * (breathe + A.lvl * (.12 + .4 * A.sh[k]));
                    const f1 = 1.1 + k * .45, f2 = 2.3 + k * .7, thick = 5 + A.lvl * 10 * A.sh[k];
                    const ys = [];
                    for (let x = 0; x <= w + 4; x += 4) {
                        const u = x / w;
                        ys.push(cy + taper(u) * amp * (Math.sin(u * f1 * TAU + st.ph[k]) * .65 + Math.sin(u * f2 * TAU - st.ph[k] * 1.3) * .35));
                    }
                    const a = .10 + .35 * A.sh[k] * (.3 + A.lvl);
                    const fill = g.createLinearGradient(0, 0, w, 0);
                    fill.addColorStop(0, rgba(COLS[k], 0)); fill.addColorStop(.5, rgba(COLS[k], a)); fill.addColorStop(1, rgba(COLS[k], 0));
                    g.beginPath();
                    ys.forEach((y, i) => i ? g.lineTo(i * 4, y) : g.moveTo(0, y));
                    for (let i = ys.length - 1; i >= 0; i--) g.lineTo(i * 4, ys[i] + thick * taper(i * 4 / w) + (ys[i] - cy) * .3);
                    g.closePath(); g.fillStyle = fill; g.fill();
                    const line = g.createLinearGradient(0, 0, w, 0);
                    line.addColorStop(0, rgba(COLS[k], 0)); line.addColorStop(.5, rgba(COLS[k], .35 + .5 * A.lvl)); line.addColorStop(1, rgba(COLS[k], 0));
                    g.beginPath(); ys.forEach((y, i) => i ? g.lineTo(i * 4, y) : g.moveTo(0, y));
                    g.strokeStyle = line; g.lineWidth = 1.2; g.stroke();
                }
            },
        },

        particles: {
            name: "Partículas",
            init(st) {
                st.ph = 0;
                st.P = Array.from({ length: 170 }, (_, i) => ({ u: Math.random(), o: Math.random() * 2 - 1, s: .5 + Math.random(), k: i % 3, y: null, r: Math.random() }));
            },
            draw(st, g, w, h, t, dt) {
                g.globalCompositeOperation = "destination-out";   // rasto que se apaga
                g.fillStyle = "rgba(0,0,0,.22)"; g.fillRect(0, 0, w, h);
                g.globalCompositeOperation = "lighter";
                st.ph += dt * (.0006 + .003 * A.lvl);
                const cy = h * .58, amp = h * (.04 + .3 * A.lvl), spread = h * (.4 - .3 * A.lvl);
                for (const p of st.P) {
                    p.u = (p.u + dt * p.s * (.00002 + .00022 * A.lvl)) % 1;
                    const u = p.u;
                    const wave = taper(u) * (Math.sin(u * 12.566 + st.ph) * .6 + Math.sin(u * 31.4 - st.ph * 1.7) * .4);
                    const ty = cy + wave * amp + p.o * spread + Math.sin(t * .0007 * p.s + p.r * 9) * 4;
                    p.y = p.y == null ? ty : p.y + (ty - p.y) * .12;
                    const glow = .25 + .75 * A.lvl * (.4 + A.sh[p.k]);
                    const x = u * w, rad = 1.2 + 1.6 * A.lvl * p.r;
                    g.fillStyle = rgba(COLS[p.k], .08 * glow); g.beginPath(); g.arc(x, p.y, rad * 3.2, 0, TAU); g.fill();
                    g.fillStyle = rgba(COLS[p.k], .55 * glow); g.beginPath(); g.arc(x, p.y, rad, 0, TAU); g.fill();
                }
            },
        },

        ripples: {
            name: "Anel de ondas",
            init(st) { st.rings = []; st.idle = 0; },
            draw(st, g, w, h, t, dt, onsets) {
                g.clearRect(0, 0, w, h);
                g.globalCompositeOperation = "lighter";
                if (onsets) {
                    st.rings.push({ b: t, k: A.tsh.indexOf(Math.max(...A.tsh)), s: clamp(.4 + A.tl) });
                    st.idle = t;
                }
                if (t - st.idle > 2400) { st.rings.push({ b: t, k: 0, s: .25 }); st.idle = t; }   // respira no silêncio
                const cx = w / 2, cy = h * .58, LIFE = 1800;
                st.rings = st.rings.filter(r => t - r.b < LIFE);
                for (const r of st.rings) {
                    const a = (t - r.b) / LIFE, rad = 8 + Math.pow(a, .65) * w * .55, fade = Math.pow(1 - a, 1.6) * r.s;
                    g.beginPath(); g.ellipse(cx, cy, rad, rad * .36, 0, 0, TAU);
                    g.strokeStyle = rgba(COLS[r.k], .75 * fade); g.lineWidth = 1 + 2.5 * fade; g.stroke();
                }
                const c = mix(A.sh), cr = (18 + A.lvl * 110) / 2.6 * 1.4;
                g.save(); g.translate(cx, cy); g.scale(2.6, 1);
                const core = g.createRadialGradient(0, 0, 0, 0, 0, cr);
                core.addColorStop(0, rgba(c, .18 + .4 * A.lvl)); core.addColorStop(1, rgba(c, 0));
                g.fillStyle = core; g.beginPath(); g.arc(0, 0, cr, 0, TAU); g.fill();
                g.restore();
            },
        },

        aurora: {
            name: "Aurora",
            init(st) { st.ph = Math.random() * 10; },
            draw(st, g, w, h, t, dt) {
                g.clearRect(0, 0, w, h);
                g.globalCompositeOperation = "lighter";
                st.ph += dt * (.00025 + .0011 * A.lvl);
                const N = 30, sw = w / N;
                for (let i = 0; i < N; i++) {
                    const u = (i + .5) / N;
                    const n = .5 + .5 * Math.sin(u * 7.3 + st.ph * 2.1) * Math.sin(u * 3.1 - st.ph * 1.3 + 1.7);
                    const edge = h * (.78 + .08 * Math.sin(u * 9 + st.ph * 2.6));          // orla de baixo, a mais viva
                    const hh = h * (.15 + (.25 + .55 * A.lvl) * n * taper(u));
                    const x = u * w + Math.sin(st.ph * 3 + i * .7) * sw * .6;
                    const c = mix([A.sh[0] * (1.2 - u), A.sh[1] * (1 - Math.abs(u - .5)), A.sh[2] * (u + .2)]);
                    const a = (.10 + .32 * A.lvl) * (.5 + n);
                    const gr = g.createLinearGradient(0, edge + 3, 0, edge - hh);
                    gr.addColorStop(0, rgba(c, 0)); gr.addColorStop(.06, rgba(c, a)); gr.addColorStop(.35, rgba(c, a * .45)); gr.addColorStop(1, rgba(c, 0));
                    g.fillStyle = gr; g.fillRect(x - sw * .9, edge - hh, sw * 1.8, hh + 3);
                }
            },
        },

        lava: {
            name: "Bolhas de luz",
            init(st) {
                st.ph = Math.random() * 10; st.pulse = 0;
                st.B = Array.from({ length: 7 }, (_, i) => ({ k: i % 3, fx: .6 + Math.random() * .9, fy: .5 + Math.random() * 1.1, px: Math.random() * TAU, py: Math.random() * TAU, r0: Math.random() }));
            },
            draw(st, g, w, h, t, dt, onsets) {
                g.clearRect(0, 0, w, h);
                g.globalCompositeOperation = "lighter";
                st.ph += dt * (.00018 + .0009 * A.lvl);
                if (onsets) st.pulse = 1;
                st.pulse *= Math.pow(.992, dt);
                for (const b of st.B) {
                    const x = w * (.5 + .42 * Math.sin(st.ph * b.fx + b.px));
                    const y = h * (.55 + .28 * Math.sin(st.ph * b.fy + b.py));
                    const r = h * (.28 + .16 * b.r0) * (.55 + A.lvl * (.4 + A.sh[b.k] * 1.4) + st.pulse * .15);
                    const gr = g.createRadialGradient(x, y, 0, x, y, r);
                    gr.addColorStop(0, rgba(COLS[b.k], .2 + .35 * A.lvl));
                    gr.addColorStop(.55, rgba(COLS[b.k], .07 + .12 * A.lvl));
                    gr.addColorStop(1, rgba(COLS[b.k], 0));
                    g.fillStyle = gr; g.beginPath(); g.arc(x, y, r, 0, TAU); g.fill();
                }
            },
        },

        constellation: {
            name: "Constelação",
            init(st) { st.N = null; },
            draw(st, g, w, h, t, dt, onsets) {
                if (!st.N) st.N = Array.from({ length: 42 }, (_, i) => ({ x: Math.random() * w, y: Math.random() * h, a: Math.random() * TAU, s: .4 + Math.random(), k: i % 3, f: 0 }));
                g.clearRect(0, 0, w, h);
                g.globalCompositeOperation = "lighter";
                const speed = .006 + .045 * A.lvl, D = 40 + 110 * A.lvl;
                for (let i = 0; i < onsets; i++) st.N[Math.floor(Math.random() * st.N.length)].f = 1;
                for (const p of st.N) {
                    p.a += (Math.random() - .5) * .05;
                    p.x = (p.x + Math.cos(p.a) * speed * p.s * dt + w) % w;
                    p.y = (p.y + Math.sin(p.a) * speed * p.s * dt + h) % h;
                    p.f *= Math.pow(.994, dt);
                }
                g.lineWidth = 1;
                for (let i = 0; i < st.N.length; i++) {
                    const p = st.N[i];
                    for (let j = i + 1; j < st.N.length; j++) {
                        const q = st.N[j], d = Math.hypot(p.x - q.x, p.y - q.y);
                        if (d >= D) continue;
                        g.strokeStyle = rgba(COLS[p.k], (1 - d / D) * (.1 + .45 * A.lvl + .4 * Math.max(p.f, q.f)));
                        g.beginPath(); g.moveTo(p.x, p.y); g.lineTo(q.x, q.y); g.stroke();
                    }
                }
                for (const p of st.N) {
                    const r = 1 + 1.5 * A.lvl + p.f * 2.5, a = .35 + .5 * A.lvl * (.4 + A.sh[p.k]) + p.f * .5;
                    g.fillStyle = rgba(COLS[p.k], a * .15); g.beginPath(); g.arc(p.x, p.y, r * 3.5, 0, TAU); g.fill();
                    g.fillStyle = rgba(COLS[p.k], a); g.beginPath(); g.arc(p.x, p.y, r, 0, TAU); g.fill();
                }
            },
        },
    };
    const ORDER = ["ribbon", "particles", "ripples", "aurora", "lava", "constellation"];

    // ── Desenho: uma volta por imagem para todas as cenas visíveis ─────────
    const active = new Set();
    let raf = 0, last = 0;

    function frame(t) {
        const dt = Math.min(50, t - (last || t));
        last = t;
        const up = 1 - Math.pow(.65, dt / 16.7), down = 1 - Math.pow(.93, dt / 16.7), col = 1 - Math.pow(.92, dt / 16.7);
        A.lvl += (A.tl - A.lvl) * (A.tl > A.lvl ? up : down);
        for (let k = 0; k < 3; k++) A.sh[k] += (A.tsh[k] - A.sh[k]) * col;
        for (const inst of active) inst.draw(t, dt);
        raf = active.size ? requestAnimationFrame(frame) : 0;
        if (!raf) last = 0;
    }

    function create(canvas) {
        const g = canvas.getContext("2d");
        const inst = { id: null, st: {}, seen: A.onsets, rotate: 0, since: 0, hideTimer: null, swapTimer: null };
        canvas.style.transition = "opacity .45s ease";
        canvas.style.opacity = "0";

        function fit() {
            const dpr = window.devicePixelRatio || 1, w = canvas.clientWidth, h = canvas.clientHeight;
            if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
                canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
                g.setTransform(dpr, 0, 0, dpr, 0, 0);
            }
            return [w, h];
        }
        function use(id) {
            inst.id = SCENES[id] ? id : ORDER[0];
            inst.st = {};
            SCENES[inst.id].init(inst.st);
            g.globalCompositeOperation = "source-over";
            g.clearRect(0, 0, canvas.width, canvas.height);
        }
        inst.draw = (t, dt) => {
            const [w, h] = fit();
            if (!w || !h) return;
            if (inst.rotate && !inst.swapTimer && t - inst.since > inst.rotate * 1000) {
                // Troca a meio do ditado: apaga, muda de cena, acende.
                canvas.style.opacity = "0";
                inst.swapTimer = setTimeout(() => {
                    inst.swapTimer = null;
                    use(ORDER[(ORDER.indexOf(inst.id) + 1) % ORDER.length]);
                    inst.since = performance.now();
                    canvas.style.opacity = "1";
                }, 450);
            }
            const onsets = A.onsets - inst.seen;
            inst.seen = A.onsets;
            SCENES[inst.id].draw(inst.st, g, w, h, t, dt, onsets);
            g.globalCompositeOperation = "source-over";
        };
        inst.show = (id, rotateSecs) => {
            clearTimeout(inst.hideTimer);
            if (id !== inst.id || !active.has(inst)) use(id);
            inst.rotate = rotateSecs || 0;
            inst.since = performance.now();
            inst.seen = A.onsets;
            canvas.style.opacity = "1";
            active.add(inst);
            if (!raf) raf = requestAnimationFrame(frame);
        };
        inst.hide = () => {
            canvas.style.opacity = "0";
            clearTimeout(inst.swapTimer); inst.swapTimer = null;
            clearTimeout(inst.hideTimer);
            inst.hideTimer = setTimeout(() => active.delete(inst), 500);   // deixa acabar o esbatimento
        };
        return inst;
    }

    api.feed = feed;
    api.simulate = simulate;
    api.create = create;
    api.list = ORDER.map(id => ({ id, name: SCENES[id].name }));
    window.VoxScenes = api;
})();
