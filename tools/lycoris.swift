import Foundation

// Same check as LoRAConverter.lycorisKind: read only the safetensors JSON header.
func lycorisKind(_ url: URL) -> String? {
  guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
  defer { try? handle.close() }
  guard let lengthBytes = try? handle.read(upToCount: 8), lengthBytes.count == 8 else { return nil }
  let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
  guard length > 0, length < 200_000_000,
    let header = try? handle.read(upToCount: Int(length)),
    let text = String(data: header, encoding: .utf8)
  else { return nil }
  if text.contains("lokr_w") { return "LoKr" }
  if text.contains("hada_w") { return "LoHa" }
  return nil
}

let home = FileManager.default.homeDirectoryForCurrentUser
for name in ["Krea 2 - Penis Lora v3.safetensors", "snofs_krea_v1_4.safetensors"] {
  let url = home.appendingPathComponent("Downloads/\(name)")
  let t0 = Date()
  let kind = lycorisKind(url)
  print(String(format: "%@… → %@ · %.1f мс", String(name.prefix(12)), kind ?? "обычная lora", Date().timeIntervalSince(t0) * 1000))
}
