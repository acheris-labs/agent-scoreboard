import Darwin

// The controlling terminal of a process, as a device path like /dev/ttys004.
// Every process started in a terminal tab shares that tab's tty, so it names
// the tab even when the pid we hold is a wrapper rather than claude itself.
public enum ProcessTTY {
    public static func path(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // A missing pid is not an error to sysctl: it just returns no bytes.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let device = info.kp_eproc.e_tdev
        guard device != -1,  // NODEV: no controlling terminal
            let name = devname(device, S_IFCHR)
        else { return nil }
        let tty = String(cString: name)
        return tty == "??" ? nil : "/dev/" + tty
    }
}
