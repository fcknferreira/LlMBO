// Gera os sons do LlMBO do zero (síntese, sem amostras nem dependências):
//   swift Design/render_sounds.swift Resources/Sounds
// Grava .aiff 16 bits/44,1 kHz mono (gera .wav e converte com afconvert). O build.sh copia para o app.
// Alto-falante de MacBook quase não toca abaixo de ~100 Hz: o grave vem com harmônicos (2×–5×) e uma
// saturação leve, para o ouvido "completar" a fundamental (fundamental ausente) mesmo sem subwoofer.
import Foundation

let rate = 44_100.0

struct Rng {   // ruído reprodutível: o mesmo arquivo a cada geração
    var s: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s % 1_000_000) / 500_000 - 1
    }
}

/// Passa-baixa de um polo com corte variável.
struct LowPass {
    var y = 0.0
    mutating func run(_ x: Double, cutoff: Double) -> Double {
        let a = 1 - exp(-2 * .pi * cutoff / rate)
        y += a * (x - y)
        return y
    }
}

func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

/// Tom grave rico: fundamental + harmônicos que o alto-falante pequeno consegue tocar.
func richTone(_ phase: Double, bright: Double) -> Double {
    sin(phase) + 0.75 * sin(2 * phase) + 0.55 * bright * sin(3 * phase)
        + 0.35 * bright * sin(4 * phase) + 0.2 * bright * sin(5 * phase)
}

func write(_ samples: [Double], to url: URL) {
    let peak = samples.map(abs).max() ?? 1
    let gain = 0.89 / max(peak, 1e-9)   // pico em −1 dBFS
    var pcm = Data()
    for x in samples {
        var v = Int16(max(-1, min(1, x * gain)) * 32767).littleEndian
        pcm.append(Data(bytes: &v, count: 2))
    }
    var d = Data()
    func u32(_ v: UInt32) { var v = v.littleEndian; d.append(Data(bytes: &v, count: 4)) }
    func u16(_ v: UInt16) { var v = v.littleEndian; d.append(Data(bytes: &v, count: 2)) }
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
    d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
    u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
    try! d.write(to: url)
}

/// Fim sem estalo e começo sem clique.
func edges(_ s: inout [Double]) {
    let fi = Int(0.008 * rate), fo = Int(0.03 * rate)
    for i in 0..<min(fi, s.count) { s[i] *= Double(i) / Double(fi) }
    for i in 0..<min(fo, s.count) { s[s.count - 1 - i] *= Double(i) / Double(fo) }
}

// MARK: - Horizonte: um buraco negro ganhando força, um puxão final e some.

func horizon() -> [Double] {
    let build = 1.9, surge = 0.16, collapse = 0.45
    let total = build + surge + collapse
    var out: [Double] = [], phase = 0.0, pulsePhase = 0.0, rng = Rng(), lp = LowPass(), lp2 = LowPass()
    for i in 0..<Int(total * rate) {
        let t = Double(i) / rate
        var f: Double, amp: Double, bright: Double, cutoff: Double, pulseRate: Double, noiseAmt: Double
        if t < build {
            let p = t / build
            f = 36 * pow(70.0 / 36, p)              // sobe de 36 para 70 Hz
            amp = (0.08 + 0.92 * pow(p, 2.2)) * 0.75   // começa baixinho, mas audível
            bright = 0.3 + 0.7 * p
            cutoff = 140 + 520 * p * p
            pulseRate = 2.5 + 11 * p * p            // gira cada vez mais rápido
            noiseAmt = 0.5
        } else if t < build + surge {
            let p = (t - build) / surge
            f = 70 + 18 * smooth(p)                 // o puxão final
            amp = 0.75 + 0.45 * smooth(p)
            bright = 1
            cutoff = 660 + 240 * p
            pulseRate = 13.5
            noiseAmt = 0.6
        } else {
            let p = (t - build - surge) / collapse
            f = 88 * pow(18.0 / 88, p)              // engolido: a altura despenca
            amp = 1.2 * exp(-6 * p)
            bright = 1 - 0.8 * p
            cutoff = 900 * (1 - p) + 60
            pulseRate = 13.5 * (1 - p)
            noiseAmt = 0.6 * (1 - p)
        }
        phase += 2 * .pi * f / rate
        pulsePhase += 2 * .pi * pulseRate / rate
        let pulse = 1 - 0.35 * (0.5 + 0.5 * sin(pulsePhase))
        let noise = lp2.run(lp.run(rng.next(), cutoff: cutoff), cutoff: cutoff) * 3.2
        let x = (richTone(phase, bright: bright) * 0.6 + noise * noiseAmt) * amp * pulse
        out.append(tanh(1.6 * x))                   // saturação leve: mais corpo no alto-falante
    }
    edges(&out)
    return out
}

// MARK: - Supernova: a estrela se contrai, explode abafada e sobra o zumbido grave até sumir.

func supernova() -> [Double] {
    let inhale = 0.55, total = 3.4
    var out: [Double] = [], ph = 0.0, thumpPh = 0.0, d1 = 0.0, d2 = 0.0, d3 = 0.0
    var rng = Rng(), lp = LowPass(), lp2 = LowPass(), rumble = LowPass()
    for i in 0..<Int(total * rate) {
        let t = Double(i) / rate
        var x = 0.0
        if t < inhale {
            // contração: um grave subindo e crescendo
            let p = t / inhale
            ph += 2 * .pi * (48 + 50 * p * p) / rate
            x += richTone(ph, bright: 0.4 + 0.5 * p) * pow(p, 2.5) * 0.45
        } else {
            let e = t - inhale
            // explosão abafada: ruído com passa-baixa descendo (sem o pico agudo)
            let cutoff = 160 + 1100 * exp(-e / 0.18)
            let burst = lp2.run(lp.run(rng.next(), cutoff: cutoff), cutoff: cutoff) * 3
            let burstEnv = min(e / 0.012, 1) * exp(-e / 0.32)
            x += burst * burstEnv * 1.1
            // o baque: seno que despenca de 120 para 42 Hz
            thumpPh += 2 * .pi * (42 + 78 * exp(-e / 0.09)) / rate
            x += richTone(thumpPh, bright: 0.8) * exp(-e / 0.38) * 0.8
            // o zumbido do buraco negro que sobra: 42 Hz com batimento lento e harmônicos
            d1 += 2 * .pi * 42 / rate
            d2 += 2 * .pi * 42.6 / rate
            d3 += 2 * .pi * 63.3 / rate                // quinta acima, bem baixa
            let droneIn = smooth(e / 0.5)
            let droneOut = exp(-max(0, e - 0.6) / 0.85)
            let drone = (richTone(d1, bright: 0.9) + richTone(d2, bright: 0.7)) * 0.32 + sin(d3) * 0.12
            let hiss = rumble.run(rng.next(), cutoff: 220) * 1.6
            x += (drone + hiss * 0.35) * droneIn * droneOut * 0.75
        }
        out.append(tanh(1.5 * x))
    }
    edges(&out)
    return out
}

// MARK: - Voyage: uma mensagem chegando de longe — três bipes suaves de telemetria, eco distante e um chiado de rádio.

func voyage() -> [Double] {
    let total = 2.3, delay = 0.24, feedback = 0.38
    // (início, frequência): dois bipes iguais e um mais alto, como "chegou".
    let beeps: [(Double, Double)] = [(0.10, 494), (0.28, 494), (0.52, 659.3)]   // faixa média (si e mi)
    let beepLen = 0.12
    var dry: [Double] = [], rng = Rng(), hissLP = LowPass(), hissHP = LowPass()
    for i in 0..<Int(total * rate) {
        let t = Double(i) / rate
        var x = 0.0
        for (start, f) in beeps where t >= start && t < start + beepLen + 0.25 {
            let e = t - start
            // ataque macio de 6 ms, corpo curto e cauda que se apaga
            let env = min(e / 0.006, 1) * (e < beepLen ? 1 : exp(-(e - beepLen) / 0.045))
            let wob = 1 + 0.004 * sin(2 * .pi * 5.5 * e)            // leve oscilação de rádio
            let ph = 2 * .pi * f * wob * e
            x += (sin(ph) + 0.35 * sin(2 * ph) + 0.12 * sin(3 * ph)) * env * 0.55   // harmônicos dão corpo
        }
        // chiado de rádio bem baixo (faixa média), que aparece e some
        let n = rng.next()
        let band = hissLP.run(n, cutoff: 2000) - hissHP.run(n, cutoff: 400)
        x += band * 0.05 * smooth(t / 0.08) * exp(-max(0, t - 0.7) / 0.5)
        dry.append(x)
    }
    // eco distante: cada volta mais baixa e mais abafada
    var out = dry, echoLP = LowPass()
    let d = Int(delay * rate)
    for i in d..<out.count {
        out[i] += echoLP.run(out[i - d], cutoff: 1600) * feedback
    }
    for i in 0..<out.count { out[i] = tanh(1.2 * out[i]) }
    edges(&out)
    return out
}

// MARK: - Espaçonave: uma espaçonave chega flutuando com um zumbido ondulante, passa por cima e vai embora.

func spaceship() -> [Double] {
    let total = 2.6, pass = 1.35
    var out: [Double] = [], ph = 0.0, mph = 0.0, sub = 0.0, rng = Rng(), nLP = LowPass(), nHP = LowPass()
    for i in 0..<Int(total * rate) {
        let t = Double(i) / rate
        // efeito Doppler: chega mais aguda, passa e desce
        let base = t < pass ? 260 + 90 * smooth(t / pass) : 350 * pow(0.55, smooth((t - pass) / 0.5))   // faixa média
        // ondulação que acelera ao se aproximar
        let wobRate = 5 + 4 * smooth(t / pass)
        let f = base * (1 + 0.035 * sin(2 * .pi * wobRate * t))
        ph += 2 * .pi * f / rate
        mph += 2 * .pi * f * 1.5 / rate                    // FM com razão 3:2 = timbre "de outro mundo"
        sub += 2 * .pi * f / 2 / rate
        let index = 0.6 + 1.4 * smooth(t / pass) * exp(-max(0, t - pass) / 0.6)
        let voice = sin(ph + index * sin(mph))
        let shimmer = 0.75 + 0.25 * sin(2 * .pi * 31 * t)  // trêmulo rápido, metálico
        // perto = mais alto: cresce até a passagem e se afasta
        let dist = t < pass ? 0.15 + 0.85 * pow(t / pass, 1.6) : exp(-(t - pass) / 0.42)
        // sopro do ar na passagem
        let n = rng.next()
        let whoosh = (nLP.run(n, cutoff: 1600) - nHP.run(n, cutoff: 300)) * exp(-pow((t - pass) / 0.22, 2))
        let x = (voice * shimmer * 0.6 + sin(sub) * 0.35 + 0.2 * sin(2 * ph)) * dist + whoosh * 0.35
        out.append(tanh(1.3 * x))
    }
    edges(&out)
    return out
}

// MARK: - Saturno: um gongo grave batido uma vez; os anéis ecoam e vibram devagar.

func saturn() -> [Double] {
    let total = 3.4, f0 = 98.0   // sol grave
    // parciais inarmônicas de gongo: (razão, nível, decaimento em s, batimento em Hz)
    let partials: [(Double, Double, Double, Double)] = [
        (1.00, 1.00, 2.6, 0.6), (1.52, 0.70, 2.0, 0.9), (2.01, 0.55, 1.6, 0.7),
        (2.68, 0.45, 1.2, 1.3), (3.43, 0.30, 0.9, 1.1), (4.22, 0.20, 0.6, 1.7), (5.31, 0.12, 0.4, 2.1)]
    var out: [Double] = [], rng = Rng(), lp = LowPass(), lp2 = LowPass()
    var phases = [Double](repeating: 0, count: partials.count * 2)
    for i in 0..<Int(total * rate) {
        let t = Double(i) / rate
        var x = 0.0
        for (k, (r, lvl, dec, beat)) in partials.enumerated() {
            // as parciais altas sobem um pouquinho no começo, como num gongo de verdade
            let glide = 1 + 0.012 * (r - 1) / 4 * (1 - exp(-t / 0.35))
            let f = f0 * r * glide
            phases[2 * k] += 2 * .pi * (f - beat / 2) / rate
            phases[2 * k + 1] += 2 * .pi * (f + beat / 2) / rate
            // as altas florescem depois do golpe (o "swell" do gongo)
            let bloom = r > 2 ? min(1, 0.35 + t / 0.4) : 1
            x += (sin(phases[2 * k]) + sin(phases[2 * k + 1])) * 0.5 * lvl * exp(-t / dec) * bloom
        }
        // o golpe: ruído abafado bem curto
        let hit = lp2.run(lp.run(rng.next(), cutoff: 900), cutoff: 900) * 3 * exp(-t / 0.03)
        out.append(tanh(1.4 * (x * 0.55 + hit * 0.6)))
    }
    edges(&out)
    return out
}

// MARK: - Nebulosa: um acorde quente e distante que cresce, brilha um pouco e some devagar.

func nebula() -> [Double] {
    let total = 3.6
    let notes = [73.42, 110.0, 146.83, 185.0, 220.0]   // ré maior aberto: ré, lá, ré, fá#, lá
    let detune = [-0.35, 0.0, 0.4]                      // três vozes levemente desafinadas por nota
    var phases = [Double](repeating: 0, count: notes.count * detune.count)
    var out: [Double] = [], filt = LowPass(), filt2 = LowPass(), sh1 = 0.0, sh2 = 0.0
    for i in 0..<Int(total * rate) {
        let t = Double(i) / rate
        var x = 0.0
        for (n, f) in notes.enumerated() {
            for (d, cents) in detune.enumerated() {
                let idx = n * detune.count + d
                phases[idx] += 2 * .pi * f * (1 + cents / 100 * 0.06) / rate
                let p = phases[idx]
                // timbre de corda macia: harmônicos que caem rápido
                x += (sin(p) + 0.5 * sin(2 * p) + 0.28 * sin(3 * p) + 0.15 * sin(4 * p) + 0.08 * sin(5 * p)) / Double(notes.count)
            }
        }
        // o filtro abre com o crescendo e fecha ao sumir
        let swell = smooth(t / 1.1) * exp(-max(0, t - 1.5) / 0.9)
        let cutoff = 350 + 1100 * swell
        var y = filt2.run(filt.run(x, cutoff: cutoff), cutoff: cutoff) * 1.6
        // brilho de estrelas bem baixo, uma oitava acima, que aparece no meio
        sh1 += 2 * .pi * 587.3 / rate; sh2 += 2 * .pi * 880.0 / rate
        let twinkle = (sin(sh1) * (0.5 + 0.5 * sin(2 * .pi * 3.1 * t)) + sin(sh2) * (0.5 + 0.5 * sin(2 * .pi * 2.3 * t + 1)))
        y += twinkle * 0.05 * exp(-pow((t - 1.6) / 0.7, 2))
        out.append(tanh(1.3 * y * swell))
    }
    edges(&out)
    return out
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, samples) in [("Horizonte", horizon()), ("Supernova", supernova()), ("Voyage", voyage()), ("Espaconave", spaceship()), ("Saturno", saturn()), ("Nebulosa", nebula())] {
    let wav = dir.appendingPathComponent("\(name).wav")
    write(samples, to: wav)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    p.arguments = ["-f", "AIFF", "-d", "BEI16", wav.path, dir.appendingPathComponent("\(name).aiff").path]
    try! p.run(); p.waitUntilExit()
    try? FileManager.default.removeItem(at: wav)
}
print("ok:", dir.path)
