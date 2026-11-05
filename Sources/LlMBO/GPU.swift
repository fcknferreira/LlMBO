import Foundation
import IOKit

/// Uso de GPU por processo, como o "% GPU" do Monitor de Atividade, sem root: cada cliente do acelerador
/// (filhos do IOAccelerator, ex.: AGXDeviceUserClient) traz "IOUserClientCreator" = "pid 618, WindowServer" e
/// "AppUsage" = [{accumulatedGPUTime (ns)}]. A diferença entre duas leituras ÷ o tempo passado = fração de GPU.
/// Serve para IA local (Ollama, LM Studio, MLX…), que trabalha na GPU com a CPU quase parada.
final class GPUSampler {
    private var last: [Int32: UInt64] = [:]
    private var lastAt: Date?

    /// % de GPU de cada pid desde a leitura anterior (vazio na primeira).
    func sample() -> [Int32: Double] {
        let now = Date()
        let totals = Self.accumulated()
        defer { last = totals; lastAt = now }
        guard let lastAt else { return [:] }
        let elapsed = now.timeIntervalSince(lastAt) * 1e9
        guard elapsed > 0 else { return [:] }
        var out: [Int32: Double] = [:]
        for (pid, ns) in totals {
            let before = last[pid] ?? ns   // processo novo: começa a contar na próxima leitura
            if ns > before { out[pid] = Double(ns - before) / elapsed * 100 }
        }
        return out
    }

    /// Tempo de GPU acumulado (ns) por pid.
    static func accumulated() -> [Int32: UInt64] {
        var out: [Int32: UInt64] = [:]
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(services) }
        while case let accel = IOIteratorNext(services), accel != 0 {
            defer { IOObjectRelease(accel) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }),   // "pid 618, WindowServer"
                      let usage = property(client, "AppUsage") as? [[String: Any]] else { continue }
                let ns = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                out[pid, default: 0] += ns
            }
            IOObjectRelease(children)
        }
        return out
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
