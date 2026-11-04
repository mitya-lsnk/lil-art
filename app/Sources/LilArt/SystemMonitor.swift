import Darwin
import Foundation
import IOKit

/// What the machine is doing right now: memory of the engine and the app, load on the processor
/// and the graphics, power per block, and the chip's temperature.
///
/// Everything is read without administrator rights. Load and memory come from public system
/// calls. Power comes from IOReport and temperature from the HID sensor service, the same
/// sources Activity-style monitors use; if either is missing on some Mac, its line is left out.
@MainActor
final class SystemMonitor: ObservableObject {
  struct Reading: Equatable {
    var engineGB = 0.0
    var appGB = 0.0
    var freeGB = 0.0
    var cpuLoad: Double?
    var gpuLoad: Double?
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var chipTemp: Double?

    var usedByUsGB: Double { engineGB + appGB }
  }

  @Published private(set) var now = Reading()

  private var previousTicks: (busy: UInt64, total: UInt64)?
  private let power = PowerReader()
  private let thermal = ThermalReader()
  private let graphics = GPUReader()
  // Every mach_host_self() call adds a send-right reference; once a second for hours adds up.
  private let hostPort: mach_port_t = mach_host_self()

  func sample(enginePID: Int32?) {
    var next = Reading()
    next.appGB = Mem.footprintGB()
    next.freeGB = Mem.systemAvailableGB()
    next.engineGB = enginePID.map(Self.footprintGB) ?? 0
    next.cpuLoad = readCPU() ?? now.cpuLoad
    next.gpuLoad = graphics.read()
    if let watts = power.read() {
      next.cpuWatts = watts.cpu
      next.gpuWatts = watts.gpu
      next.aneWatts = watts.ane
    } else {
      next.cpuWatts = now.cpuWatts
      next.gpuWatts = now.gpuWatts
      next.aneWatts = now.aneWatts
    }
    next.chipTemp = thermal.read()
    if next != now { now = next }
  }

  private func readCPU() -> Double? {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard
      host_processor_info(
        hostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
      let info
    else { return nil }
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: info)),
        vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    var busy: UInt64 = 0
    var total: UInt64 = 0
    for cpu in 0..<Int(cpuCount) {
      let base = cpu * Int(CPU_STATE_MAX)
      func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
      let working = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
      busy += working
      total += working + ticks(CPU_STATE_IDLE)
    }
    defer { previousTicks = (busy, total) }
    guard let previous = previousTicks, total > previous.total, busy >= previous.busy else {
      return nil
    }
    return Double(busy - previous.busy) / Double(total - previous.total)
  }

  private static func footprintGB(_ pid: Int32) -> Double {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    return result == 0 ? Double(usage.ri_phys_footprint) / 1_073_741_824 : 0
  }
}

/// GPU busy share from the accelerator's "PerformanceStatistics" property.
///
/// The accelerator services are looked up once and kept: asking the registry for the whole
/// property dictionary every second copies a lot of data that is never used.
private final class GPUReader {
  private var services: [io_service_t] = []

  deinit { release() }

  private func release() {
    for service in services { IOObjectRelease(service) }
    services = []
  }

  private func find() {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
      services.append(service)
    }
  }

  func read() -> Double? {
    if services.isEmpty { find() }
    var busiest: Double?
    for service in services {
      guard
        let property = IORegistryEntryCreateCFProperty(
          service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue(),
        let statistics = property as? NSDictionary,
        let value = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
      else { continue }
      busiest = max(busiest ?? value, value)
    }
    // nothing readable: the device may be gone (an external GPU), so look again next time
    if busiest == nil { release() }
    return busiest.map { $0 / 100 }
  }
}

/// Energy per block from IOReport's "Energy Model" group, turned into watts between two looks.
private final class PowerReader {
  private typealias CopyChannels =
    @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
  private typealias CreateSubscription =
    @convention(c) (
      UnsafeMutableRawPointer?, CFMutableDictionary,
      UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
    ) -> UnsafeMutableRawPointer?
  private typealias CreateSamples =
    @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
  private typealias CreateDelta =
    @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
  private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
  private typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64

  private var subscription: UnsafeMutableRawPointer?
  private var channels: CFMutableDictionary?
  private var createSamples: CreateSamples?
  private var createDelta: CreateDelta?
  private var channelName: GetString?
  private var unitLabel: GetString?
  private var integerValue: GetInteger?
  private var last: (samples: CFDictionary, at: Date)?

  init() {
    guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
    func symbol<T>(_ name: String, _: T.Type) -> T? {
      dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
    }
    guard let copyChannels = symbol("IOReportCopyChannelsInGroup", CopyChannels.self),
      let createSubscription = symbol("IOReportCreateSubscription", CreateSubscription.self),
      let group = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
    else { return }
    var subscribed: Unmanaged<CFMutableDictionary>?
    guard let made = createSubscription(nil, group, &subscribed, 0, nil),
      let list = subscribed?.takeRetainedValue()
    else { return }
    subscription = made
    channels = list
    createSamples = symbol("IOReportCreateSamples", CreateSamples.self)
    createDelta = symbol("IOReportCreateSamplesDelta", CreateDelta.self)
    channelName = symbol("IOReportChannelGetChannelName", GetString.self)
    unitLabel = symbol("IOReportChannelGetUnitLabel", GetString.self)
    integerValue = symbol("IOReportSimpleGetIntegerValue", GetInteger.self)
  }

  func read() -> (cpu: Double, gpu: Double, ane: Double)? {
    guard let subscription, let channels, let createSamples, let createDelta, let channelName,
      let unitLabel, let integerValue,
      let samples = createSamples(subscription, channels, nil)?.takeRetainedValue()
    else { return nil }
    let at = Date()
    defer { last = (samples, at) }
    guard let previous = last else { return nil }
    let seconds = at.timeIntervalSince(previous.at)
    guard seconds > 0.2,
      let delta = createDelta(previous.samples, samples, nil)?.takeRetainedValue(),
      let rawList = CFDictionaryGetValue(delta, Unmanaged.passUnretained(Self.channelsKey).toOpaque())
    else { return nil }
    let list = Unmanaged<CFArray>.fromOpaque(rawList).takeUnretainedValue()
    var cpu = 0.0
    var gpu = 0.0
    var ane = 0.0
    // The delta holds dozens of channels and only three matter. Compare them as CFStrings and
    // read the value of those alone, instead of bridging every channel to Swift objects.
    for index in 0..<CFArrayGetCount(list) {
      guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
      let entry = Unmanaged<CFDictionary>.fromOpaque(raw).takeUnretainedValue()
      guard let name = channelName(entry)?.takeUnretainedValue() else { continue }
      let isCPU = CFEqual(name, Self.cpuName)
      let isGPU = !isCPU && CFEqual(name, Self.gpuName)
      let isANE = !isCPU && !isGPU && CFEqual(name, Self.aneName)
      guard isCPU || isGPU || isANE else { continue }
      let unit = (unitLabel(entry)?.takeUnretainedValue() as String?) ?? "mJ"
      let joules = Double(integerValue(entry, 0)) * Self.joules(per: unit)
      if isCPU {
        cpu += joules
      } else if isGPU {
        gpu += joules
      } else {
        ane += joules
      }
    }
    return (cpu / seconds, gpu / seconds, ane / seconds)
  }

  private static let channelsKey = "IOReportChannels" as CFString
  private static let cpuName = "CPU Energy" as CFString
  private static let gpuName = "GPU Energy" as CFString
  private static let aneName = "ANE" as CFString

  private static func joules(per unit: String) -> Double {
    switch unit {
    case "nJ": return 1e-9
    case "uJ", "µJ": return 1e-6
    case "J": return 1
    default: return 1e-3
    }
  }
}

@_silgen_name("IOHIDEventSystemClientCreate")
private func hidClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func hidClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func hidClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func hidServiceCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func hidServiceCopyEvent(
  _ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64
) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func hidEventGetFloat(_ event: CFTypeRef, _ field: Int32) -> Double

/// The chip's own die sensors. Apple Silicon reports them for the whole die, not split into
/// processor and graphics, so the hottest one is what gets shown.
private final class ThermalReader {
  private var client: CFTypeRef?
  private var sensors: [CFTypeRef] = []

  init() {
    guard let made = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
    client = made
    _ = hidClientSetMatching(made, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    guard let list = hidClientCopyServices(made)?.takeRetainedValue() else { return }
    var fallback: [CFTypeRef] = []
    for index in 0..<CFArrayGetCount(list) {
      guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
      let service = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
      let name =
        (hidServiceCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
      if name.hasPrefix("PMU tdie") {
        sensors.append(service)
      } else if name.lowercased().contains("soc") || name.contains("tdie") {
        fallback.append(service)
      }
    }
    if sensors.isEmpty { sensors = fallback }
  }

  func read() -> Double? {
    var hottest: Double?
    for sensor in sensors {
      guard let event = hidServiceCopyEvent(sensor, 15, 0, 0)?.takeRetainedValue() else { continue }
      let value = hidEventGetFloat(event, 15 << 16)
      guard value > 0, value < 130 else { continue }
      hottest = max(hottest ?? value, value)
    }
    return hottest
  }
}
