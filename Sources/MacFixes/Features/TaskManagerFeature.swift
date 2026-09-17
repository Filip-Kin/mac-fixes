import AppKit
import SwiftUI
import Darwin
import IOKit

extension Notification.Name {
    static let openTaskManager = Notification.Name("com.filipkin.macfixes.openTaskManager")
}

/// One process row.
struct ProcInfo: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let isApp: Bool
    var cpu: Double        // % of total CPU capacity (100 = all cores busy)
    var memory: UInt64     // physical footprint, bytes
    var disk: Double       // bytes/sec
    var net: Double        // bytes/sec (in + out)
    let user: String
    let arch: String
}

/// Samples all reachable processes on a timer, Windows-Task-Manager style.
@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var procs: [ProcInfo] = []
    @Published private(set) var totalCPU: Double = 0
    @Published private(set) var totalMemory: UInt64 = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published var selectedPID: pid_t?

    // System-wide metrics for the Performance tab.
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var diskRate: Double = 0        // bytes/s (read+write)
    @Published private(set) var diskRead: Double = 0        // bytes/s
    @Published private(set) var diskWrite: Double = 0       // bytes/s
    @Published private(set) var netRecv: Double = 0         // bytes/s
    @Published private(set) var netSend: Double = 0         // bytes/s
    @Published private(set) var gpu: Double = 0             // %
    @Published private(set) var gpuMem: UInt64 = 0          // bytes in use
    @Published private(set) var threadCount = 0
    @Published private(set) var diskHistory: [Double] = []       // MB/s (read+write)
    @Published private(set) var diskReadHistory: [Double] = []   // MB/s
    @Published private(set) var diskWriteHistory: [Double] = []  // MB/s
    @Published private(set) var netHistory: [Double] = []        // Mbps (recv+send)
    @Published private(set) var netRecvHistory: [Double] = []    // Mbps
    @Published private(set) var netSendHistory: [Double] = []    // Mbps
    @Published private(set) var gpuHistory: [Double] = []
    let cpuModel = SystemInfo.cpuModel()
    let ramTotal = ProcessInfo.processInfo.physicalMemory
    var processCount: Int { procs.count }
    var uptime: TimeInterval { SystemInfo.uptime() }
    @Published private(set) var coreHistories: [[Double]] = []   // one % history per logical CPU
    private var prevNet: (recv: UInt64, send: UInt64)?
    private var prevDisk: (read: UInt64, write: UInt64)?
    private var prevCores: [(used: UInt64, total: UInt64)] = []
    private let netMonitor = NetworkMonitor()

    private var prev: [pid_t: (cpu: UInt64, disk: UInt64)] = [:]
    private var lastTime = Date()
    private var timer: Timer?
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private var userCache: [uid_t: String] = [:]
    /// Mach time units -> nanoseconds (≈41.7 on Apple Silicon, 1 on Intel).
    private let tbRatio: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func start() {
        netMonitor.start()
        refresh()
        // 1 s cadence, matching the Windows Task Manager "60 seconds" graph.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; netMonitor.stop() }

    func endTask(_ pid: pid_t) { kill(pid, SIGTERM) }
    func forceEndTask(_ pid: pid_t) { kill(pid, SIGKILL) }

    private func refresh() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        lastTime = now

        var apps: [pid_t: NSRunningApplication] = [:]
        for a in NSWorkspace.shared.runningApplications { apps[a.processIdentifier] = a }

        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0) / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(cap) + 128)
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                  Int32(pids.count * MemoryLayout<pid_t>.size)) / Int32(MemoryLayout<pid_t>.size)

        var out: [ProcInfo] = []
        var newPrev: [pid_t: (UInt64, UInt64)] = [:]
        var totCPU = 0.0
        var totMem: UInt64 = 0
        var totThreads = 0

        for i in 0..<Int(max(0, count)) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ru = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }   // process we can't read (e.g. root) — skip

            let cpuNs = ru.ri_user_time + ru.ri_system_time
            let diskB = ru.ri_diskio_bytesread + ru.ri_diskio_byteswritten
            newPrev[pid] = (cpuNs, diskB)

            var cpu = 0.0, disk = 0.0
            if let p = prev[pid], dt > 0 {
                cpu = Double(cpuNs &- p.cpu) * tbRatio / (dt * 1e9) / cores * 100
                disk = Double(diskB &- p.disk) / dt
            }
            let app = apps[pid]
            let name = app?.localizedName ?? Self.processName(pid) ?? "pid \(pid)"
            let info = ProcInfo(id: pid, name: name, icon: app?.icon,
                                isApp: app?.activationPolicy == .regular,
                                cpu: max(0, cpu), memory: ru.ri_phys_footprint,
                                disk: max(0, disk), net: netMonitor.rate(for: pid),
                                user: userName(pid), arch: Self.archString(app))
            out.append(info)
            totCPU += info.cpu
            totMem += info.memory
            var ti = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) {
                totThreads += Int(ti.pti_threadnum)
            }
        }
        prev = newPrev
        procs = out
        totalCPU = min(100, totCPU)
        totalMemory = totMem
        threadCount = totThreads
        memUsed = SystemInfo.memoryUsed()
        let gpuStats = SystemInfo.gpuStats()
        gpu = gpuStats.util
        gpuMem = gpuStats.memUsed

        // Device-level disk read/write (IOKit block storage), rates by diff.
        let dc = SystemInfo.diskCounters()
        if let pd = prevDisk, dt > 0 {
            diskRead = max(0, Double(dc.read &- pd.read) / dt)
            diskWrite = max(0, Double(dc.write &- pd.write) / dt)
        }
        prevDisk = dc
        diskRate = diskRead + diskWrite

        let nc = SystemInfo.netCounters()
        if let pn = prevNet, dt > 0 {
            netRecv = max(0, Double(nc.recv &- pn.recv) / dt)
            netSend = max(0, Double(nc.send &- pn.send) / dt)
        }
        prevNet = nc

        // Per logical-core utilisation, rates by diff.
        let coreLoads = SystemInfo.perCoreLoad()
        if prevCores.count == coreLoads.count, dt > 0 {
            if coreHistories.count != coreLoads.count { coreHistories = Array(repeating: [], count: coreLoads.count) }
            for i in coreLoads.indices {
                let dUsed = Double(coreLoads[i].used &- prevCores[i].used)
                let dTotal = Double(coreLoads[i].total &- prevCores[i].total)
                let pct = dTotal > 0 ? min(100, max(0, dUsed / dTotal * 100)) : 0
                append(&coreHistories[i], pct)
            }
        }
        prevCores = coreLoads

        let memPct = ramTotal > 0 ? min(100, Double(memUsed) / Double(ramTotal) * 100) : 0
        append(&cpuHistory, totalCPU)
        append(&memHistory, memPct)
        append(&diskHistory, diskRate / 1_048_576)
        append(&diskReadHistory, diskRead / 1_048_576)
        append(&diskWriteHistory, diskWrite / 1_048_576)
        append(&netHistory, (netRecv + netSend) * 8 / 1_000_000)
        append(&netRecvHistory, netRecv * 8 / 1_000_000)
        append(&netSendHistory, netSend * 8 / 1_000_000)
        append(&gpuHistory, gpu)
    }

    static let capacity = 60   // 60 s of history at 1 s cadence

    private func append(_ arr: inout [Double], _ v: Double) {
        arr.append(v); if arr.count > Self.capacity { arr.removeFirst() }
    }

    private static func archString(_ app: NSRunningApplication?) -> String {
        switch app?.executableArchitecture {
        case NSBundleExecutableArchitectureARM64:  return "arm64"
        case NSBundleExecutableArchitectureX86_64: return "x86_64"
        default: return ""
        }
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private func userName(_ pid: pid_t) -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return "" }
        let uid = info.pbi_uid
        if let n = userCache[uid] { return n }
        let n = (getpwuid(uid)?.pointee.pw_name).map { String(cString: $0) } ?? "\(uid)"
        userCache[uid] = n
        return n
    }
}

// MARK: - System metrics

enum SystemInfo {
    static func cpuModel() -> String {
        for key in ["machdep.cpu.brand_string", "hw.model"] {
            var size = 0
            sysctlbyname(key, nil, &size, nil, 0)
            if size > 0 {
                var buf = [CChar](repeating: 0, count: size)
                sysctlbyname(key, &buf, &size, nil, 0)
                let s = String(cString: buf)
                if !s.isEmpty { return s }
            }
        }
        return "CPU"
    }

    static func uptime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    static func netCounters() -> (recv: UInt64, send: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var r: UInt64 = 0, s: UInt64 = 0
        var cur = addrs
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let name = c.pointee.ifa_name.map { String(cString: $0) } ?? ""
            guard !name.hasPrefix("lo"),
                  c.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let d = c.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            r += UInt64(d.pointee.ifi_ibytes)
            s += UInt64(d.pointee.ifi_obytes)
        }
        return (r, s)
    }

    static func gpuStats() -> (util: Double, memUsed: UInt64) {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var best = 0.0
        var mem: UInt64 = 0
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            if let props = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                for key in ["Device Utilization %", "GPU Core Utilization", "Renderer Utilization %"] {
                    if let v = props[key] as? Int { best = max(best, Double(v)) }
                    else if let v = props[key] as? Double { best = max(best, v) }
                }
                // GPU memory in use. Apple Silicon shares system RAM, so these
                // report unified-memory bytes assigned to the GPU right now.
                for key in ["In use system memory", "vramUsedBytes", "gartUsedBytes", "Alloc system memory"] {
                    if let v = props[key] as? NSNumber, v.uint64Value > 0 { mem = max(mem, v.uint64Value); break }
                }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        // Some keys report in 0-1e9 nanoseconds-of-busy; clamp anything absurd.
        return (best > 100 ? min(100, best / 10_000_000) : best, mem)
    }

    /// Cumulative device-level disk bytes read/written across all block drivers.
    static func diskCounters() -> (read: UInt64, write: UInt64) {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var read: UInt64 = 0, write: UInt64 = 0
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            if let stats = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                if let r = stats["Bytes (Read)"] as? NSNumber { read += r.uint64Value }
                if let w = stats["Bytes (Write)"] as? NSNumber { write += w.uint64Value }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return (read, write)
    }

    /// Cumulative busy/total ticks for each logical CPU.
    static func perCoreLoad() -> [(used: UInt64, total: UInt64)] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: UnsafeRawPointer(info))), size)
        }
        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount))
        var result: [(UInt64, UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user   = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_SYSTEM)]))
            let nice   = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_NICE)]))
            let idle   = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_IDLE)]))
            let used = user + system + nice
            result.append((used, used + idle))
        }
        return result
    }
}

// MARK: - Window

@MainActor
final class TaskManagerFeature {
    private var window: NSWindow?
    private var keyMonitor: Any?
    private let monitor = ProcessMonitor()

    func open() {
        if window == nil {
            let host = NSHostingController(rootView: TaskManagerView(monitor: monitor))
            let w = NSWindow(contentViewController: host)
            w.title = "Task Manager"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.appearance = NSAppearance(named: .darkAqua)   // Win11 dark look
            w.setContentSize(NSSize(width: 960, height: 640))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.monitor.stop()
                    if let m = self.keyMonitor { NSEvent.removeMonitor(m); self.keyMonitor = nil }
                }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.window?.isKeyWindow == true else { return e }
                if e.keyCode == 51 || e.keyCode == 117 {   // Delete / Forward Delete -> End task
                    if let pid = self.monitor.selectedPID { self.monitor.endTask(pid) }
                    return nil
                }
                return e
            }
        }
        monitor.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

private enum SortKey { case name, cpu, memory, disk, network }

private enum TMTab: String, CaseIterable {
    case processes = "Processes", performance = "Performance"
    case startup = "Startup apps", users = "Users", details = "Details", services = "Services"
    var icon: String {
        switch self {
        case .processes:  return "square.grid.3x3.square"
        case .performance: return "chart.line.uptrend.xyaxis"
        case .startup:    return "power"
        case .users:      return "person.2"
        case .details:    return "list.bullet.rectangle"
        case .services:   return "gearshape.2"
        }
    }
}

private enum PerfKey: String, CaseIterable { case cpu = "CPU", memory = "Memory", disk = "Disk", network = "Network", gpu = "GPU" }

private enum TM {
    static let bg      = Color(red: 0.13, green: 0.13, blue: 0.145)
    static let rail    = Color(red: 0.105, green: 0.105, blue: 0.12)
    static let header  = Color(red: 0.16, green: 0.16, blue: 0.175)
    static let hairline = Color.white.opacity(0.07)
    static let accent  = Color(red: 0.30, green: 0.62, blue: 1.0)   // selection
    static let heat    = Color(red: 0.55, green: 0.42, blue: 0.85)  // usage shading
    static let sec     = Color.white.opacity(0.55)

    // right-side column widths
    static let wStatus: CGFloat = 92, wCPU: CGFloat = 78, wMem: CGFloat = 90, wDisk: CGFloat = 82, wNet: CGFloat = 84
}

struct TaskManagerView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var tab: TMTab = .processes
    @State private var sort: SortKey = .cpu
    @State private var ascending = false
    @State private var railExpanded = false
    @State private var perfKey: PerfKey = .cpu
    @State private var cpuLogicalView = false
    @StateObject private var servicesLoader = ServicesLoader()
    @StateObject private var startupLoader = StartupLoader()

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().overlay(TM.hairline)
            Group {
                switch tab {
                case .processes:   processes
                case .details:     detailsTab
                case .performance: performanceTab
                case .startup:     startupTab
                case .users:       usersTab
                case .services:    servicesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TM.bg)
        }
        .frame(minWidth: 820, minHeight: 460)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    // MARK: Left navigation rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { railExpanded.toggle() } } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 15))
                    .foregroundStyle(TM.sec).frame(width: 52, height: 44)
            }.buttonStyle(.plain)
            ForEach(TMTab.allCases, id: \.self) { t in railItem(t.icon, t.rawValue, active: tab == t) { tab = t } }
            Spacer()
            railItem("gearshape", "Settings", active: false) {
                NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil)
            }
            .padding(.bottom, 6)
        }
        .frame(width: railExpanded ? 210 : 52, alignment: .leading)
        .background(TM.rail)
    }

    private func railItem(_ icon: String, _ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Rectangle().fill(active ? TM.accent : .clear).frame(width: 3, height: 18).clipShape(Capsule())
                if railExpanded {
                    Image(systemName: icon).frame(width: 20).padding(.leading, 12)
                    Text(title).padding(.leading, 12)
                    Spacer(minLength: 0)
                } else {
                    Image(systemName: icon).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40)
            .background(active ? Color.white.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : TM.sec)
        .help(title)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: tab.icon).font(.system(size: 40)).foregroundStyle(TM.sec)
            Text(tab.rawValue).font(.title3)
            Text("Coming soon").foregroundStyle(TM.sec)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Details tab

    private var detailsTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.system(size: 17, weight: .semibold))
                Spacer()
                toolButton("End task", "xmark", enabled: monitor.selectedPID != nil) {
                    if let s = monitor.selectedPID { monitor.endTask(s) }
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 70, alignment: .trailing)
                Text("User").frame(width: 130, alignment: .leading).padding(.leading, 16)
                Text("CPU").frame(width: 62, alignment: .trailing)
                Text("Memory").frame(width: 92, alignment: .trailing)
                Text("Architecture").frame(width: 96, alignment: .leading).padding(.leading, 16)
            }.font(.caption).foregroundStyle(TM.sec).padding(.horizontal, 16).padding(.vertical, 6)
            Divider().overlay(TM.hairline)
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(sorted(monitor.procs)) { detailsRow($0) } }
            }
        }
    }

    private func detailsRow(_ p: ProcInfo) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = p.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                else { Image(systemName: "square.dashed").font(.system(size: 15)).foregroundStyle(TM.sec).frame(width: 20) }
                Text(p.name).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("\(p.id)").frame(width: 70, alignment: .trailing).foregroundStyle(TM.sec).monospacedDigit()
            Text(p.user).frame(width: 130, alignment: .leading).padding(.leading, 16).foregroundStyle(TM.sec).lineLimit(1)
            Text(cpuText(p.cpu)).frame(width: 62, alignment: .trailing).monospacedDigit()
            Text(String(format: "%.1f MB", Double(p.memory) / 1_048_576)).frame(width: 92, alignment: .trailing).monospacedDigit()
            Text(p.arch).frame(width: 96, alignment: .leading).padding(.leading, 16).foregroundStyle(TM.sec)
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
        .background(monitor.selectedPID == p.id ? TM.accent.opacity(0.28) : .clear)
        .contentShape(Rectangle()).onTapGesture { monitor.selectedPID = p.id }
        .contextMenu { Button("End task") { monitor.endTask(p.id) }; Button("Force quit") { monitor.forceEndTask(p.id) } }
    }

    // MARK: Performance tab

    private var performanceTab: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(PerfKey.allCases, id: \.self) { perfMetricCard($0) }
                }.padding(8)
            }
            .frame(width: 246)
            .background(TM.rail)
            Divider().overlay(TM.hairline)
            perfDetail(perfKey)
        }
    }

    private func perfMetricCard(_ k: PerfKey) -> some View {
        Button { perfKey = k } label: {
            HStack(spacing: 12) {
                perfSpark(perfHistory(k), color: perfColor(k), scale: perfScale(k))
                    .frame(width: 74, height: 46)
                    .background(Color.black.opacity(0.25))
                    .overlay(Rectangle().stroke(perfColor(k).opacity(0.5), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.rawValue).font(.system(size: 14, weight: .medium))
                    Text(perfSubtitle(k)).font(.system(size: 12)).foregroundStyle(TM.sec).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(perfKey == k ? Color.white.opacity(0.10) : .clear))
            .overlay(alignment: .leading) {
                Rectangle().fill(perfKey == k ? perfColor(k) : .clear).frame(width: 3).clipShape(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func perfDetail(_ k: PerfKey) -> some View {
        let series = perfSeries(k)
        let scale = perfGraphScale(k)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(k.rawValue).font(.system(size: 26, weight: .semibold))
                Spacer()
                if k == .cpu {
                    Picker("", selection: $cpuLogicalView) {
                        Text("Overall").tag(false)
                        Text("Logical processors").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text(perfHardware(k)).font(.system(size: 15)).foregroundStyle(TM.sec).lineLimit(1)
            }

            if k == .cpu && cpuLogicalView {
                cpuLogicalGrid
            } else {
                HStack {
                    Text(perfAxisLabel(k)).font(.caption).foregroundStyle(TM.sec)
                    Spacer()
                    Text(perfAxisMax(k)).font(.caption).foregroundStyle(TM.sec)
                }
                perfGraph(series, scale: scale, fillFirst: series.count == 1)
                    .frame(maxWidth: .infinity).frame(height: 260)
                HStack {
                    Text("60 seconds").font(.caption2).foregroundStyle(TM.sec)
                    Spacer()
                    Text("0").font(.caption2).foregroundStyle(TM.sec)
                }
                if series.count > 1 {
                    HStack(spacing: 18) {
                        ForEach(series.indices, id: \.self) { i in
                            HStack(spacing: 6) {
                                Rectangle().fill(series[i].color).frame(width: 14, height: 3)
                                Text(series[i].label).font(.caption).foregroundStyle(TM.sec)
                                Text(series[i].current).font(.caption).monospacedDigit()
                            }
                        }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 14) {
                ForEach(perfStats(k), id: \.0) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.0).font(.system(size: 11)).foregroundStyle(TM.sec)
                        Text(s.1).font(.system(size: 18, weight: .medium)).monospacedDigit()
                    }
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Grid of one mini graph per logical CPU (Windows "Logical processors" view).
    private var cpuLogicalGrid: some View {
        let cores = monitor.coreHistories
        let cols = cores.count > 16 ? 8 : (cores.count > 4 ? 4 : max(1, cores.count))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols), spacing: 6) {
            ForEach(cores.indices, id: \.self) { i in
                VStack(spacing: 2) {
                    perfSpark(cores[i], color: perfColor(.cpu), scale: 100)
                        .frame(height: 64)
                        .background(Color.black.opacity(0.25))
                        .overlay(Rectangle().stroke(perfColor(.cpu).opacity(0.35), lineWidth: 0.5))
                    Text("CPU \(i)  \(Int((cores[i].last ?? 0).rounded()))%")
                        .font(.system(size: 9)).foregroundStyle(TM.sec)
                }
            }
        }
    }

    // Newest sample sits at the right edge; older scroll left over a fixed
    // 60-slot axis, so the x-scale never changes as history fills in.
    private static func xFor(_ i: Int, count: Int, width: CGFloat) -> CGFloat {
        let cap = ProcessMonitor.capacity
        return width - CGFloat(count - 1 - i) * (width / CGFloat(cap - 1))
    }

    // Mini sparkline for a metric card (no grid).
    private func perfSpark(_ history: [Double], color: Color, scale: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let y: (Double) -> CGFloat = { h - CGFloat(min(scale, max(0, $0)) / scale) * h }
            ZStack {
                Path { p in
                    guard history.count > 1 else { return }
                    p.move(to: CGPoint(x: Self.xFor(0, count: history.count, width: w), y: h))
                    for (i, v) in history.enumerated() {
                        p.addLine(to: CGPoint(x: Self.xFor(i, count: history.count, width: w), y: y(v)))
                    }
                    p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
                }.fill(color.opacity(0.25))
                Path { p in
                    guard history.count > 1 else { return }
                    for (i, v) in history.enumerated() {
                        let pt = CGPoint(x: Self.xFor(i, count: history.count, width: w), y: y(v))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }.stroke(color, lineWidth: 1.2)
            }
        }
    }

    // Big gridded graph, one or more lines. Fills the area under the first line
    // when `fillFirst` (single-metric look); multi-line graphs are lines only.
    private func perfGraph(_ series: [PerfSeries], scale: Double, fillFirst: Bool) -> some View {
        let gridColor = series.first?.color ?? TM.accent
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    let cols = 12, rows = 6
                    for i in 0...cols { let x = w * CGFloat(i) / CGFloat(cols); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) }
                    for j in 0...rows { let y = h * CGFloat(j) / CGFloat(rows); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                }.stroke(gridColor.opacity(0.14), lineWidth: 0.5)
                if fillFirst, let s = series.first {
                    Path { p in
                        guard s.history.count > 1 else { return }
                        p.move(to: CGPoint(x: Self.xFor(0, count: s.history.count, width: w), y: h))
                        for (i, v) in s.history.enumerated() {
                            p.addLine(to: CGPoint(x: Self.xFor(i, count: s.history.count, width: w), y: h - CGFloat(min(scale, max(0, v)) / scale) * h))
                        }
                        p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
                    }.fill(LinearGradient(colors: [s.color.opacity(0.35), s.color.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                }
                ForEach(series.indices, id: \.self) { idx in
                    let s = series[idx]
                    Path { p in
                        guard s.history.count > 1 else { return }
                        for (i, v) in s.history.enumerated() {
                            let pt = CGPoint(x: Self.xFor(i, count: s.history.count, width: w), y: h - CGFloat(min(scale, max(0, v)) / scale) * h)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }.stroke(s.color, lineWidth: 1.5)
                }
            }
        }
        .background(Color.black.opacity(0.25))
        .overlay(Rectangle().stroke(gridColor.opacity(0.4), lineWidth: 1))
    }

    struct PerfSeries {
        let history: [Double]
        let color: Color
        let label: String
        let current: String
    }

    private func perfSeries(_ k: PerfKey) -> [PerfSeries] {
        switch k {
        case .cpu:
            return [PerfSeries(history: monitor.cpuHistory, color: perfColor(k), label: "Utilization",
                               current: "\(Int(monitor.totalCPU.rounded()))%")]
        case .memory:
            return [PerfSeries(history: monitor.memHistory, color: perfColor(k), label: "In use",
                               current: "\(Int(memPercent.rounded()))%")]
        case .gpu:
            return [PerfSeries(history: monitor.gpuHistory, color: perfColor(k), label: "Utilization",
                               current: "\(Int(monitor.gpu.rounded()))%")]
        case .disk:
            return [PerfSeries(history: monitor.diskReadHistory, color: perfColor(k), label: "Read",
                               current: Self.rate(monitor.diskRead)),
                    PerfSeries(history: monitor.diskWriteHistory, color: Color(red: 0.55, green: 0.92, blue: 0.72), label: "Write",
                               current: Self.rate(monitor.diskWrite))]
        case .network:
            return [PerfSeries(history: monitor.netRecvHistory, color: perfColor(k), label: "Receive",
                               current: String(format: "%.1f Mbps", monitor.netRecv * 8 / 1_000_000)),
                    PerfSeries(history: monitor.netSendHistory, color: Color(red: 1.0, green: 0.82, blue: 0.45), label: "Send",
                               current: String(format: "%.1f Mbps", monitor.netSend * 8 / 1_000_000))]
        }
    }

    private func perfGraphScale(_ k: PerfKey) -> Double {
        switch k {
        case .cpu, .memory, .gpu: return 100
        case .disk, .network:
            let m = perfSeries(k).flatMap(\.history).max() ?? 0
            return max(1, m * 1.25)
        }
    }

    // MARK: Performance data helpers

    private var memInUseGB: Double { Double(monitor.memUsed) / 1_073_741_824 }
    private var memTotalGB: Double { Double(monitor.ramTotal) / 1_073_741_824 }

    private func perfColor(_ k: PerfKey) -> Color {
        switch k {
        case .cpu:     return TM.accent
        case .memory:  return TM.heat
        case .disk:    return Color(red: 0.20, green: 0.78, blue: 0.45)
        case .network: return Color(red: 0.96, green: 0.62, blue: 0.20)
        case .gpu:     return Color(red: 0.28, green: 0.80, blue: 0.80)
        }
    }
    private func perfHistory(_ k: PerfKey) -> [Double] {
        switch k {
        case .cpu:     return monitor.cpuHistory
        case .memory:  return monitor.memHistory
        case .disk:    return monitor.diskHistory
        case .network: return monitor.netHistory
        case .gpu:     return monitor.gpuHistory
        }
    }
    private func perfScale(_ k: PerfKey) -> Double {
        switch k {
        case .cpu, .memory, .gpu: return 100
        case .disk:    return max(1, (monitor.diskHistory.max() ?? 0) * 1.25)
        case .network: return max(1, (monitor.netHistory.max() ?? 0) * 1.25)
        }
    }
    private func perfValue(_ k: PerfKey) -> String {
        switch k {
        case .cpu:     return "\(Int(monitor.totalCPU.rounded()))%"
        case .memory:  return "\(Int(memPercent.rounded()))%"
        case .disk:    return Self.rate(monitor.diskRate)
        case .network: return String(format: "%.1f Mbps", (monitor.netRecv + monitor.netSend) * 8 / 1_000_000)
        case .gpu:     return "\(Int(monitor.gpu.rounded()))%"
        }
    }
    private func perfSubtitle(_ k: PerfKey) -> String {
        switch k {
        case .memory: return String(format: "%.1f/%.1f GB (%d%%)", memInUseGB, memTotalGB, Int(memPercent.rounded()))
        default:      return perfValue(k)
        }
    }
    private func perfHardware(_ k: PerfKey) -> String {
        switch k {
        case .cpu:     return monitor.cpuModel
        case .memory:  return String(format: "%.0f GB", memTotalGB.rounded())
        case .disk:    return "Disk 0"
        case .network: return "Network"
        case .gpu:     return "GPU"
        }
    }
    private func perfAxisLabel(_ k: PerfKey) -> String {
        switch k {
        case .cpu, .gpu: return "% Utilization"
        case .memory:    return "Memory usage"
        case .disk:      return "Disk transfer rate"
        case .network:   return "Throughput"
        }
    }
    private func perfAxisMax(_ k: PerfKey) -> String {
        switch k {
        case .cpu, .gpu: return "100%"
        case .memory:    return String(format: "%.0f GB", memTotalGB.rounded())
        case .disk:      return String(format: "%.0f MB/s", perfGraphScale(.disk))
        case .network:   return String(format: "%.0f Mbps", perfGraphScale(.network))
        }
    }
    private func perfStats(_ k: PerfKey) -> [(String, String)] {
        switch k {
        case .cpu:
            return [("Utilization", "\(Int(monitor.totalCPU.rounded()))%"),
                    ("Processes", "\(monitor.processCount)"),
                    ("Threads", "\(monitor.threadCount)"),
                    ("Up time", Self.uptimeString(monitor.uptime)),
                    ("Cores", "\(ProcessInfo.processInfo.processorCount)"),
                    ("Logical processors", "\(ProcessInfo.processInfo.activeProcessorCount)")]
        case .memory:
            return [("In use", String(format: "%.1f GB", memInUseGB)),
                    ("Available", String(format: "%.1f GB", max(0, memTotalGB - memInUseGB))),
                    ("Total", String(format: "%.0f GB", memTotalGB.rounded())),
                    ("Utilization", "\(Int(memPercent.rounded()))%")]
        case .disk:
            return [("Read speed", Self.rate(monitor.diskRead)),
                    ("Write speed", Self.rate(monitor.diskWrite)),
                    ("Active rate", Self.rate(monitor.diskRate))]
        case .network:
            return [("Receive", String(format: "%.1f Mbps", monitor.netRecv * 8 / 1_000_000)),
                    ("Send", String(format: "%.1f Mbps", monitor.netSend * 8 / 1_000_000)),
                    ("Total", String(format: "%.1f Mbps", (monitor.netRecv + monitor.netSend) * 8 / 1_000_000))]
        case .gpu:
            return [("Utilization", "\(Int(monitor.gpu.rounded()))%"),
                    ("Memory in use", monitor.gpuMem > 0 ? Self.bytes(monitor.gpuMem) : "—"),
                    ("Peak", "\(Int((monitor.gpuHistory.max() ?? 0).rounded()))%")]
        }
    }

    static func rate(_ bps: Double) -> String {
        if bps < 1 { return "0 KB/s" }
        if bps < 1_048_576 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.1f MB/s", bps / 1_048_576)
    }
    static func uptimeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%d:%02d:%02d:%02d", d, h, m, sec) }
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    // MARK: Startup apps tab

    private var startupTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Startup apps").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Open Login Items") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.plain).foregroundStyle(TM.accent)
                Button("Refresh") { startupLoader.load() }
                    .buttonStyle(.plain).foregroundStyle(TM.accent).padding(.leading, 14)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Source").frame(width: 150, alignment: .leading)
                Text("Status").frame(width: 110, alignment: .leading).padding(.leading, 16)
            }.font(.caption).foregroundStyle(TM.sec).padding(.horizontal, 16).padding(.vertical, 6)
            Divider().overlay(TM.hairline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(startupLoader.items) { it in
                        HStack(spacing: 0) {
                            HStack(spacing: 10) {
                                if let ic = it.icon { Image(nsImage: ic).resizable().frame(width: 20, height: 20) }
                                else { Image(systemName: "power").font(.system(size: 13)).foregroundStyle(TM.sec).frame(width: 20) }
                                Text(it.name).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(it.source).frame(width: 150, alignment: .leading).foregroundStyle(TM.sec).lineLimit(1)
                            Text(it.status).frame(width: 110, alignment: .leading).padding(.leading, 16)
                                .foregroundStyle(it.status == "Enabled" ? Color.green : TM.sec)
                        }.padding(.horizontal, 16).padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { if startupLoader.items.isEmpty { startupLoader.load() } }
    }

    // MARK: Users tab

    private var usersTab: some View {
        let groups = Dictionary(grouping: monitor.procs, by: { $0.user.isEmpty ? "—" : $0.user })
            .map { (user: $0.key,
                    cpu: $0.value.reduce(0.0) { $0 + $1.cpu },
                    mem: $0.value.reduce(UInt64(0)) { $0 + $1.memory },
                    n: $0.value.count) }
            .sorted { $0.cpu > $1.cpu }
        return VStack(spacing: 0) {
            HStack { Text("Users").font(.system(size: 17, weight: .semibold)); Spacer() }
                .padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 0) {
                Text("User").frame(maxWidth: .infinity, alignment: .leading)
                Text("Processes").frame(width: 90, alignment: .trailing)
                Text("CPU").frame(width: 70, alignment: .trailing)
                Text("Memory").frame(width: 100, alignment: .trailing)
            }.font(.caption).foregroundStyle(TM.sec).padding(.horizontal, 16).padding(.vertical, 6)
            Divider().overlay(TM.hairline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups, id: \.user) { g in
                        HStack(spacing: 0) {
                            HStack(spacing: 8) { Image(systemName: "person.crop.circle").foregroundStyle(TM.sec); Text(g.user) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(g.n)").frame(width: 90, alignment: .trailing).foregroundStyle(TM.sec)
                            Text(cpuText(g.cpu)).frame(width: 70, alignment: .trailing).monospacedDigit()
                            Text(String(format: "%.0f MB", Double(g.mem) / 1_048_576)).frame(width: 100, alignment: .trailing).monospacedDigit()
                        }.padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    // MARK: Services tab

    private var servicesTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Services").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Refresh") { servicesLoader.load() }.buttonStyle(.plain).foregroundStyle(TM.accent)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 70, alignment: .trailing)
                Text("Status").frame(width: 100, alignment: .leading).padding(.leading, 16)
            }.font(.caption).foregroundStyle(TM.sec).padding(.horizontal, 16).padding(.vertical, 6)
            Divider().overlay(TM.hairline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(servicesLoader.services) { s in
                        HStack(spacing: 0) {
                            Text(s.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(s.pid).frame(width: 70, alignment: .trailing).foregroundStyle(TM.sec).monospacedDigit()
                            Text(s.status).frame(width: 100, alignment: .leading).padding(.leading, 16)
                                .foregroundStyle(s.status == "Running" ? Color.green : TM.sec)
                        }.padding(.horizontal, 16).padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { if servicesLoader.services.isEmpty { servicesLoader.load() } }
    }

    // MARK: Processes tab

    private var apps: [ProcInfo] { sorted(monitor.procs.filter(\.isApp)) }
    private var background: [ProcInfo] { sorted(monitor.procs.filter { !$0.isApp }) }
    private var maxCPU: Double { max(1, monitor.procs.map(\.cpu).max() ?? 1) }
    private var maxMem: Double { Double(max(1, monitor.procs.map(\.memory).max() ?? 1)) }
    private var maxDisk: Double { max(1, monitor.procs.map(\.disk).max() ?? 1) }
    private var maxNet: Double { max(1, monitor.procs.map(\.net).max() ?? 1) }
    private var memPercent: Double {
        monitor.ramTotal > 0 ? min(100, Double(monitor.memUsed) / Double(monitor.ramTotal) * 100) : 0
    }

    private func sorted(_ list: [ProcInfo]) -> [ProcInfo] {
        let s = list.sorted { a, b in
            switch sort {
            case .name:   return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .cpu:    return a.cpu < b.cpu
            case .memory: return a.memory < b.memory
            case .disk:   return a.disk < b.disk
            case .network: return a.net < b.net
            }
        }
        return ascending ? s : s.reversed()
    }

    private var processes: some View {
        VStack(spacing: 0) {
            toolbar
            columnHeader
            Divider().overlay(TM.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if sort == .name {
                        sectionView("Apps", apps)
                        sectionView("Background processes", background)
                    } else {
                        ForEach(sorted(monitor.procs)) { row($0) }   // merged, sorted
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            Text("Processes").font(.system(size: 17, weight: .semibold))
            Spacer()
            toolButton("Run new task", "plus.square") { runNewTask() }
            toolButton("End task", "xmark", enabled: monitor.selectedPID != nil) {
                if let s = monitor.selectedPID { monitor.endTask(s) }
            }
            toolButton("Efficiency mode", "leaf", enabled: false) {}
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func toolButton(_ title: String, _ icon: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.callout)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .white : TM.sec.opacity(0.6))
        .disabled(!enabled)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            colHead("Name", .name, width: nil, align: .leading)
            Text("Status").font(.caption).foregroundStyle(TM.sec).frame(width: TM.wStatus, alignment: .leading)
            numHead(String(format: "%.0f%%", monitor.totalCPU), "CPU", .cpu, width: TM.wCPU)
            numHead(String(format: "%.0f%%", memPercent), "Memory", .memory, width: TM.wMem)
            numHead(Self.rate(monitor.diskRate), "Disk", .disk, width: TM.wDisk)
            numHead(Self.netText(monitor.procs.reduce(0) { $0 + $1.net }), "Network", .network, width: TM.wNet)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private func colHead(_ title: String, _ key: SortKey, width: CGFloat?, align: Alignment) -> some View {
        Button { toggleSort(key) } label: {
            HStack(spacing: 3) {
                if sort == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8)) }
                Text(title).font(.callout)
            }
            .frame(maxWidth: width == nil ? .infinity : width, alignment: align)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white)
    }

    private func numHead(_ value: String, _ name: String, _ key: SortKey, width: CGFloat) -> some View {
        Button { toggleSort(key) } label: {
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).font(.system(size: 15))
                HStack(spacing: 2) {
                    if sort == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 7)) }
                    Text(name).font(.caption).foregroundStyle(TM.sec)
                }
            }
            .padding(.trailing, 12)
            .frame(width: width, alignment: .trailing).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white)
    }

    private func toggleSort(_ key: SortKey) {
        if sort == key { ascending.toggle() } else { sort = key; ascending = false }
    }

    private func sectionView(_ title: String, _ rows: [ProcInfo]) -> some View {
        Section {
            ForEach(rows) { row($0) }
        } header: {
            Text("\(title) (\(rows.count))")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(TM.bg)
        }
    }

    private func row(_ p: ProcInfo) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = p.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                else { Image(systemName: "square.dashed").font(.system(size: 16)).foregroundStyle(TM.sec).frame(width: 22) }
                Text(p.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: TM.wStatus)
            heatCell(cpuText(p.cpu), value: p.cpu / maxCPU, width: TM.wCPU)
            heatCell(String(format: "%.1f MB", Double(p.memory) / 1_048_576), value: Double(p.memory) / maxMem, width: TM.wMem)
            heatCell(diskText(p.disk), value: p.disk / maxDisk, width: TM.wDisk)
            heatCell(Self.netText(p.net), value: p.net / maxNet, width: TM.wNet)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .background(monitor.selectedPID == p.id ? TM.accent.opacity(0.28) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { monitor.selectedPID = p.id }
        .contextMenu {
            Button("End task") { monitor.endTask(p.id) }
            Button("Force quit") { monitor.forceEndTask(p.id) }
        }
    }

    private func heatCell(_ text: String, value: Double, width: CGFloat) -> some View {
        Text(text)
            .font(.callout).monospacedDigit()
            .padding(.trailing, 12)
            .frame(width: width, alignment: .trailing)
            .padding(.vertical, 3)
            .background(TM.heat.opacity(min(0.5, max(0, value) * 0.5)))
    }

    private func cpuText(_ c: Double) -> String {
        c < 0.05 ? "0%" : String(format: c < 9.95 ? "%.1f%%" : "%.0f%%", c)
    }
    private func diskText(_ d: Double) -> String {
        if d < 1_000 { return "0 MB/s" }
        if d < 102_400 { return String(format: "%.0f KB/s", d / 1_024) }
        return String(format: "%.1f MB/s", d / 1_048_576)
    }

    static func bytes(_ n: UInt64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .memory
        return f.string(fromByteCount: Int64(n))
    }

    // Per-process network throughput, shown in Mbps like Windows.
    static func netText(_ bytesPerSec: Double) -> String {
        let mbps = bytesPerSec * 8 / 1_000_000
        if mbps < 0.05 { return "0 Mbps" }
        if mbps < 9.95 { return String(format: "%.1f Mbps", mbps) }
        return String(format: "%.0f Mbps", mbps)
    }

    private func runNewTask() {
        let alert = NSAlert()
        alert.messageText = "Create new task"
        alert.informativeText = "Type the name of a program or command to run."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cmd = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A bare word is treated as an app to open; anything else runs as a shell command.
        if !cmd.contains("/"), !cmd.contains(" ") {
            p.arguments = ["-lc", "open -a \"\(cmd)\" 2>/dev/null || \(cmd)"]
        } else {
            p.arguments = ["-lc", cmd]
        }
        try? p.run()
    }
}

// MARK: - Services (launchd)

struct Service: Identifiable {
    let id: String
    let name: String
    let pid: String
    let status: String
}

@MainActor
final class ServicesLoader: ObservableObject {
    @Published var services: [Service] = []

    func load() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var out: [Service] = []
        for line in text.split(separator: "\n").dropFirst() {   // first line is the header
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            let pidStr = String(cols[0])
            out.append(Service(id: String(cols[2]), name: String(cols[2]),
                               pid: pidStr == "-" ? "" : pidStr,
                               status: pidStr == "-" ? "Stopped" : "Running"))
        }
        services = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Startup apps

struct StartupItem: Identifiable {
    let id = UUID()
    let name: String
    let source: String
    let status: String
    let icon: NSImage?
}

/// Enumerates what launches at login: GUI login items (via System Events) plus
/// LaunchAgents / LaunchDaemons property lists. Read-only.
@MainActor
final class StartupLoader: ObservableObject {
    @Published var items: [StartupItem] = []

    func load() {
        var result: [StartupItem] = []

        // GUI login items (System Events; first use prompts for Automation).
        if let out = Self.runOsascript("tell application \"System Events\" to get the path of every login item"),
           !out.isEmpty {
            for path in out.components(separatedBy: ", ") where !path.trimmingCharacters(in: .whitespaces).isEmpty {
                let clean = path.trimmingCharacters(in: .whitespaces)
                let url = URL(fileURLWithPath: clean)
                let name = url.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: clean)
                icon.size = NSSize(width: 20, height: 20)
                result.append(StartupItem(name: name, source: "Login item", status: "Enabled", icon: icon))
            }
        }

        // LaunchAgents / LaunchDaemons plists.
        let fm = FileManager.default
        var dirs = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path)
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let kind = dir.contains("Daemons") ? "Launch daemon" : "Launch agent"
            for f in files where f.hasSuffix(".plist") {
                let full = dir + "/" + f
                guard let data = fm.contents(atPath: full),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }
                let label = (plist["Label"] as? String) ?? (f as NSString).deletingPathExtension
                let disabled = (plist["Disabled"] as? Bool) ?? false
                let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
                let status = disabled ? "Disabled" : (runAtLoad ? "Enabled" : "On demand")
                result.append(StartupItem(name: label, source: kind, status: status, icon: nil))
            }
        }

        items = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func runOsascript(_ src: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", src]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Per-process network (nettop)

/// Streams `nettop` in logging mode and derives per-process throughput by
/// diffing consecutive cumulative byte samples. macOS exposes no per-process
/// network counters through libproc, so shelling out to nettop is the standard
/// route. Thread-safe: nettop output is parsed off the main thread and the rate
/// table is read under a lock.
final class NetworkMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var rates: [pid_t: Double] = [:]        // bytes/sec (in+out) per pid
    private var prevSample: [pid_t: UInt64] = [:]   // previous cumulative in+out
    private var curSample: [pid_t: UInt64] = [:]    // sample being read
    private var buffer = Data()
    private var process: Process?
    private var pipe: Pipe?
    private let interval = 1.0                        // -s 1

    func start() {
        guard process == nil else { return }
        buffer.removeAll(); curSample.removeAll(); prevSample.removeAll()
        lock.lock(); rates.removeAll(); lock.unlock()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-x", "-s", "1", "-l", "0", "-J", "bytes_in,bytes_out"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
        do { try p.run() } catch { return }
        process = p
        pipe = out
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        pipe = nil
        lock.lock(); rates.removeAll(); lock.unlock()
    }

    func rate(for pid: pid_t) -> Double {
        lock.lock(); defer { lock.unlock() }
        return rates[pid] ?? 0
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) { parse(line) }
        }
    }

    private func parse(_ raw: String) {
        // A header line ("... bytes_in  bytes_out") starts each sample.
        if raw.contains("bytes_in") { finaliseSample(); return }
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 3,
              let inB = UInt64(tokens[tokens.count - 2]),
              let outB = UInt64(tokens[tokens.count - 1]) else { return }
        // name.pid is everything before the last two numbers; pid is after the last '.'.
        let nameField = tokens[0..<(tokens.count - 2)].joined(separator: " ")
        guard let dot = nameField.lastIndex(of: "."),
              let pid = pid_t(nameField[nameField.index(after: dot)...]) else { return }
        curSample[pid] = inB &+ outB
    }

    private func finaliseSample() {
        guard !curSample.isEmpty else { return }
        if !prevSample.isEmpty {
            var newRates: [pid_t: Double] = [:]
            for (pid, cum) in curSample where cum >= (prevSample[pid] ?? cum) {
                if let prev = prevSample[pid] { newRates[pid] = Double(cum - prev) / interval }
            }
            lock.lock(); rates = newRates; lock.unlock()
        }
        prevSample = curSample
        curSample = [:]
    }
}
