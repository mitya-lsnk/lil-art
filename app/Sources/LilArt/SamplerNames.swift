import Foundation
import MediaGenerationKit

extension SettingsImport {
  // MARK: sampler names

  /// The engine's sampler nearest to another program's name and schedule. Flow models (all
  /// the newer ones) want the "trailing" schedule unless told otherwise.
  static func samplerType(_ name: String?, scheduler: String?, flow: Bool) -> SamplerType? {
    guard let name else { return nil }
    let n = name.lowercased().replacingOccurrences(of: "_", with: " ")
    let schedule = ((scheduler ?? "") + " " + n).lowercased()
    let karras = schedule.contains("karras")
    let ays = schedule.contains("ays") || schedule.contains("align")
    if n.contains("tcd") { return flow ? .tCDTrailing : .TCD }
    if n.contains("lcm") { return .LCM }
    if n.contains("plms") { return .PLMS }
    if n.contains("ddim") { return flow ? .dDIMTrailing : .DDIM }
    if n.contains("unipc") || n.contains("uni pc") {
      return ays ? .uniPCAYS : (flow ? .uniPCTrailing : .uniPC)
    }
    if n.contains("sde") {
      return ays ? .DPMPPSDEAYS : karras ? .dPMPPSDEKarras : (flow ? .dPMPPSDETrailing : .dPMPPSDEKarras)
    }
    if n.contains("dpm") && n.contains("2m") || n.contains("dpmpp 2m") {
      return ays ? .DPMPP2MAYS : karras ? .dPMPP2MKarras : (flow ? .dPMPP2MTrailing : .dPMPP2MKarras)
    }
    if n.contains("euler") {
      return ays ? .eulerAAYS : (flow ? .eulerATrailing : .eulerA)
    }
    return Samplers.all.first { $0.1.lowercased() == name.lowercased() }?.0
  }
}
