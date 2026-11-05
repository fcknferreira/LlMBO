import CoreGraphics
// Imprime o estado da tela interna: "interna:acesa", "interna:apagada" ou "interna:fora" (desligada da lista).
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
let b = ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
if let b { print(CGDisplayIsAsleep(b) != 0 ? "interna:apagada" : "interna:acesa") } else { print("interna:fora") }
