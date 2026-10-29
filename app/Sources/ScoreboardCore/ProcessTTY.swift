import Darwin

// The controlling terminal of a process, as a device path like /dev/ttys004.
// Every process started in a terminal tab shares that tab's tty, so it names
// the tab even when the pid we hold is a wrapper rather than claude itself.
public enum ProcessTTY {
    public static func path(of pid: Int32) -> String? {
        info(of: pid).flatMap(tty)
    }

    /// The ttys of a process and each of its ancestors, nearest first. A
    /// wrapper that gives claude its own pty (e.g. a session sharer) hides the
    /// terminal tab's tty from the process itself, but not from its ancestors.
    public static func lineage(of pid: Int32) -> [String] {
        var ttys: [String] = []
        var current = pid
        while current > 1, let info = info(of: current) {
            if let tty = tty(of: info) { ttys.append(tty) }
            current = info.kp_eproc.e_ppid
        }
        return ttys
    }

    private static func info(of pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // A missing pid is not an error to sysctl: it just returns no bytes.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info
    }

    private static func tty(of info: kinfo_proc) -> String? {
        let device = info.kp_eproc.e_tdev
        guard device != -1,  // NODEV: no controlling terminal
            let name = devname(device, S_IFCHR)
        else { return nil }
        let tty = String(cString: name)
        return tty == "??" ? nil : "/dev/" + tty
    }
}
