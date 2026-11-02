#!/usr/bin/env python3
"""
sweep_layers_over_bitstreams.py
================================
Unattended: program each FPGA bitstream in turn, run fc_layer16only and
conv_layer16only N times each, scrape every printed number into CSV.

  * Programming  : host-side  vivado_lab -mode batch   (JTAG / FT232H)
  * Board driving: pyserial on the CP2108 console (default /dev/ttyUSB0) through
                   the SD helper scripts k4_app_prep.sh / k4_app_poll.sh /
                   k4_console.sh   (must already be on the card)
  * Binaries     : /mnt/sd/fc_layer16only.fpga16.bin
                   /mnt/sd/conv_layer16only.fpga16.bin   (already staged)

Default target = the architectural sweep points (--list to see them):
  L4_V2048 LLC128K AXI128  (current top-level bitstream)
  L2_V2048 LLC1M   AXI64   (archive, 2026-09-02)
  L2_V1024 LLC1M   AXI64   (archive)   -- VLEN != 2048
  L4_V4096 LLC1M   AXI128  (archive)   -- VLEN != 2048
One byte-identical VLEN-2048 binary set runs on ALL of them.  On V1024/V4096 the printed loss legitimately changes (FP16
reduction order is VLMAX-dependent) -- that is recorded, not error-checked;
the cycle counts are the deliverable and are comparable across every config.

Outputs (under --outdir, default <bitdir>/sweep_results/):
  runs.csv         one row per (bitstream, app, run)      -- wide, every field
  cycles_long.csv  one row per (bitstream, app, run, stage) -- tidy / long
  raw/<bs>__<app>__run<n>.txt   full console capture of each run
  sweep.log        progress log

Resumable: re-running skips (bitstream, app, run) triples already recorded in
runs.csv.  Ctrl-C is safe -- rows are flushed as each run finishes.

Physical things it can't fix (it aborts with a clear message; fix + re-run):
  * FT232H JTAG off USB     -> vivado_lab "No matching targets"
  * CP2108 console off USB  -> serial ping fails at start
  * SD not in the board     -> mount / file check fails

Usage:
  ./sweep_layers_over_bitstreams.py --list           # show target set, exit
  ./sweep_layers_over_bitstreams.py --preflight       # 1 program + harness, exit
  ./sweep_layers_over_bitstreams.py                   # full run, default set
  ./sweep_layers_over_bitstreams.py --bitstreams '~/bitstreams/archive/*.bit'
  ./sweep_layers_over_bitstreams.py --apps fc --repeats 5
  ./sweep_layers_over_bitstreams.py --reprogram-each-run
  ./sweep_layers_over_bitstreams.py --port /dev/ttyUSB1   # default 'auto' probes CP2108 ttys

Never hangs: serial writes have a 10 s timeout, an unresponsive console fails in
~8 s, and a board that dies mid-sweep aborts with the CSV rows so far saved
(re-run to resume).
"""
import argparse, csv, glob, os, re, signal, subprocess, sys, time, datetime, hashlib

try:
    import serial  # pyserial
except ImportError:
    sys.exit("pyserial missing:  apt install python3-serial   (or pip install pyserial)")

# --------------------------------------------------------------------------- constants
BIT_DIR   = os.environ.get("BIT_DIR", os.path.expanduser("~/bitstreams"))
VIVADO    = os.environ.get("VIVADO_LAB", "/tools/Xilinx/Vivado_Lab/2021.1/bin/vivado_lab")
JTAG_DEV  = "xczu9_0"
JTAG_FREQ = 15000000

SD          = "/mnt/sd"
SD_DEV      = "/dev/mmcblk0p1"
FC_BIN      = "fc_layer16only.fpga16.bin"
CONV_BIN    = "conv_layer16only.fpga16.bin"
HARNESS_BIN = "conv_layer16only_noboot.fpga16.bin"

# ONE byte-identical binary set is run on every bitstream (binaries
# TUNING_BRIEF: "Application binaries must be byte-identical across configurations
# being compared").  The binaries are built VLEN=2048.
#
#   * loss is VLEN-dependent (FP16 reduction order changes with VLMAX) AND
#     lane-count-independent.  So the VLEN-2048 Spike loss is a valid oracle
#     ONLY on V2048 bitstreams; on V1024 / V4096 the loss legitimately differs
#     and is recorded but not error-checked.
#   * cycle counts are the actual deliverable and are comparable across ALL
#     configs (same binary).  FPGA-vs-FPGA only -- never vs Spike.
SPIKE_LOSS = {"fc": 1.314453, "conv": 0.723053}          # VLEN 2048 only
SPIKE_LOSS_V1024 = {"fc": 1.315755}                      # from SPIKE_REF_vggshapes note

# The binary on the SD must match the freshly-built one in apps/bin/ -- otherwise
# a stale copy would silently sweep the wrong shape/code.  Checked at startup
# against these reference copies (skipped with a warning if they are absent, or
# with --no-bin-md5-check).
APPS_BIN_DIR = os.environ.get("APPS_BIN_DIR", os.path.expanduser("~/cheshire_ara/deps/ara/apps/bin"))
# (per-run ref map is built in main() from --fc-bin / --conv-bin)

# default target = the architectural sweep points.  L4_V2048 is the current
# top-level bitstream; L2_V1024 / L2_V2048 / L4_V4096 are the 2026-09-02 archive
# builds.  Override any time with  --bitstreams '<glob>'
DEFAULT_GLOBS = [
    f"{BIT_DIR}/cheshire_top_xilinx_L4_V2048_*FPUH*FPRport1fix*.bit",
    f"{BIT_DIR}/bitstream_archive/cheshire_top_xilinx_L*_V*_*allfixes*.bit",
]
# NB: the VLEN-2048 binaries currently HANG on the V1024 bitstream (going to a
# smaller VLMAX than they were built/tiled for). Build fc/conv with
# ARA_CONFIGURATION=zcu102_l2_v1024 for that point, or --bitstreams to skip it.

LOGPATH = "/tmp/sweep.log"

# --------------------------------------------------------------------------- small utils
def log(msg):
    line = f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line, flush=True)
    try:
        with open(LOGPATH, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass

def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def parse_cfg(basename):
    lanes = re.search(r"_L(\d)_", basename)
    vlen  = re.search(r"_V(\d+)_", basename)
    m_llc = re.search(r"LLC(?:cache)?(\d+ *[KM]|)", basename)
    m_axi = re.search(r"AXI(\d+)", basename)
    date  = re.search(r"_(\d{8})\.bit$", basename)
    known = ["FPUHSD","FPUHS","FPUH","noDIVSQRT","DMA0","DMA1","AXI128","AXI64",
             "MaxRd24","noAtomics","noDbg","SPMfix","DMAfix","NaNboxfix",
             "FPRport1fix","allfixes","noprobes","upsizerfix"]
    tags = "+".join(k for k in known if k in basename)
    llc = "?"
    if m_llc:
        llc = (m_llc.group(1).replace(" ", "") or "default")
    return {"lanes": lanes.group(1) if lanes else "?",
            "vlen":  vlen.group(1)  if vlen  else "?",
            "axi":   m_axi.group(1) if m_axi else "",
            "llc": llc, "date": date.group(1) if date else "00000000", "tags": tags}

def bitstream_md5_ok(bitpath):
    """If a sibling <name>.md5 exists, verify it. Return (ok, expected_or_None)."""
    sidecar = os.path.splitext(bitpath)[0] + ".md5"
    if not os.path.exists(sidecar):
        return True, None
    want = open(sidecar).read().split()[0]
    return (md5(bitpath) == want), want

# --------------------------------------------------------------------------- serial board driver
class Board:
    """PS-Linux shell over the CP2108 console. Terminal echo is turned OFF so the
    only bytes coming back are real program output + our end-of-command marker.

    NB: we never call Serial.flush() -- it does termios.tcdrain(), which blocks
    FOREVER when the board is not draining its RX (powered off / hung / wrong
    cable). write_timeout makes write() itself fail fast instead."""
    def __init__(self, port, baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.3, write_timeout=10,
                                 exclusive=True)  # keep ModemManager etc. out mid-sweep
        time.sleep(0.4)
        self.ser.reset_input_buffer()
        # kill echo + line wrapping so long commands don't come back mangled
        self._w(b"stty -echo 2>/dev/null; stty cols 1000 2>/dev/null; "
                b"PS1='' ; printf '__READY__\\n'\n")
        t, got = time.time() + 8, ""
        while time.time() < t:
            got += self.ser.read(4096).decode("latin-1", "replace")
            if "__READY__" in got:
                break
        else:
            self.close()
            raise serial.SerialException(
                f"{port} opened but the board never answered in 8 s. "
                f"Board powered? PS Linux booted? right ttyUSB? "
                f"(lsusb | grep 10c4:ea71 ; screen {port} 115200 to check)")
        time.sleep(0.2)
        self.ser.reset_input_buffer()

    def _w(self, data):
        try:
            self.ser.write(data)
        except serial.SerialTimeoutException:
            raise serial.SerialException(
                f"serial write stalled >10 s on {self.ser.port} -- the board "
                f"stopped draining the console (hung / powered off).")

    def cmd(self, command, timeout=30):
        """Run one shell command; return (output_text, rc|None)."""
        tag = f"{int(time.time()*1e3) & 0xffffff:06x}"
        self._w(f"{command} ; printf '__EOC_{tag}_rc=%d__\\n' $?\n".encode())
        pat = re.compile(rf"__EOC_{tag}_rc=(\d+)__")
        buf, rc, deadline = "", None, time.time() + timeout
        while time.time() < deadline:
            chunk = self.ser.read(8192).decode("latin-1", "replace")
            if chunk:
                buf += chunk
                m = pat.search(buf)
                if m:
                    rc, buf = int(m.group(1)), buf[:m.start()]
                    break
        return buf.replace("\r", ""), rc

    def ping(self):
        try:
            out, rc = self.cmd("echo __PONG__", timeout=8)
        except serial.SerialException:
            return False
        return rc == 0 and "__PONG__" in out

    def close(self):
        try:
            self.ser.write(b"stty echo 2>/dev/null; true\n")
            time.sleep(0.2)
        except Exception:
            pass
        try:
            self.ser.close()
        except Exception:
            pass


def _usb_vid(tty):
    """VID:PID of the USB device behind /dev/ttyUSBn, or '' if unknown."""
    p = os.path.realpath(f"/sys/class/tty/{os.path.basename(tty)}/device")
    for _ in range(8):
        v, pr = f"{p}/idVendor", f"{p}/idProduct"
        if os.path.exists(v):
            try:
                return f"{open(v).read().strip()}:{open(pr).read().strip()}"
            except OSError:
                return ""
        p = os.path.dirname(p)
    return ""

def _alive(pid):
    try:
        os.kill(pid, 0); return True
    except OSError:
        return True if os.path.exists(f"/proc/{pid}") else False

TERM_RE = re.compile(r"\b(screen|SCREEN|picocom|minicom|tio|miniterm(?:\.py)?|cu)\b")

def _holders(dev):
    """[(pid, user, cmd)] holding `dev`. ps sees every user's processes (catches a
    root `sudo screen`); fuser catches same-user non-terminal holders."""
    out, seen = [], set()
    try:
        ps = subprocess.run(["ps", "-eo", "pid=,user=,args="],
                            capture_output=True, text=True, timeout=8).stdout
        for ln in ps.splitlines():
            parts = ln.split(None, 2)
            if len(parts) == 3 and parts[0].isdigit():
                pid, user, args = int(parts[0]), parts[1], parts[2]
                if pid != os.getpid() and dev in args and TERM_RE.search(args):
                    out.append((pid, user, args.strip())); seen.add(pid)
    except Exception:
        pass
    try:
        r = subprocess.run(["fuser", dev], capture_output=True, text=True, timeout=8)
        for tok in (r.stdout + " " + r.stderr).split():
            if tok.isdigit() and int(tok) != os.getpid() and int(tok) not in seen:
                out.append((int(tok), "?", f"(fuser: pid {tok})"))
    except Exception:
        pass
    return [(p, u, c) for (p, u, c) in out if _alive(p)]

def free_serial_ports(devs):
    """Best-effort free: kill our own serial-terminal holders, and try
    `sudo -n kill` for others (a leftover `sudo screen`). Logs everything."""
    me = {str(os.getuid()), os.environ.get("USER", ""), ""}
    try:
        import pwd; me.add(pwd.getpwuid(os.getuid()).pw_name)
    except Exception:
        pass
    subprocess.run(["screen", "-wipe"], capture_output=True)
    for d in devs:
        if not os.path.exists(d):
            continue
        for _ in range(2):
            hs = _holders(d)
            if not hs:
                break
            for pid, user, cmd in hs:
                tag = f"pid {pid} [{user}] {cmd[:55]}"
                if user in me or user == "?":
                    log(f"    freeing {d}: kill {tag}")
                    for s in (signal.SIGTERM, signal.SIGKILL):
                        try: os.kill(pid, s)
                        except OSError: break
                        time.sleep(0.8)
                        if not _alive(pid): break
                else:
                    log(f"    {d} held by {tag} -- trying sudo -n kill")
                    r = subprocess.run(["sudo", "-n", "kill", str(pid)],
                                       capture_output=True, text=True)
                    time.sleep(1)
                    if _alive(pid):
                        subprocess.run(["sudo", "-n", "kill", "-9", str(pid)],
                                       capture_output=True)
                        time.sleep(1)
                    log(f"      {'freed' if not _alive(pid) else 'STILL ALIVE -- run:  sudo kill ' + str(pid)}")
            time.sleep(1)

def find_console(explicit=None):
    """Return a live Board. If explicit port given, use only that. Otherwise try
    every CP2108 (10c4:ea71) tty, skipping the FT232H JTAG (0403:6014), and
    return the first that answers a ping."""
    if explicit:
        cands = [explicit]
    else:
        allt = sorted(glob.glob("/dev/ttyUSB*"))
        cands = [t for t in allt if _usb_vid(t).startswith("10c4:")] or allt
        jtag = [t for t in allt if _usb_vid(t).startswith("0403:")]
        if jtag:
            log(f"    (skipping JTAG {', '.join(jtag)})")

    free_serial_ports(cands)
    busy = []
    for t in cands:
        if not os.path.exists(t):
            continue
        try:
            bd = Board(t)
        except serial.SerialException as e:
            if "16" in str(e) or "busy" in str(e).lower():
                busy.append(t)
                log(f"    {t}: still BUSY after free attempt "
                    f"(holders: {_holders(t) or '?'})")
            else:
                log(f"    {t}: {e}")
            continue
        if bd.ping():
            log(f"    console = {t}  ({_usb_vid(t) or 'unknown'})")
            return bd
        bd.close()
        log(f"    {t}: opened but no shell")
    if busy:
        hs = _holders(busy[0])
        who = "; ".join(f"pid {p} [{u}] {c[:70]}" for p, u, c in hs) or "unknown"
        pids = " ".join(str(p) for p, _, _ in hs)
        raise serial.SerialException(
            f"console {busy[0]} is held and could not be freed.\n"
            f"    holder: {who}\n"
            f"    free it:  sudo kill {pids or '<pid>'}   "
            f"(or in that screen: Ctrl-A \\ )\n"
            f"    then re-run the sweep.")
    raise serial.SerialException(
        f"no responding board console among {cands or 'no /dev/ttyUSB*'}. "
        f"Board powered + PS Linux booted? (lsusb | grep 10c4:ea71)")

def mount_sd(bd):
    """Make sure the SD FAT partition is freshly mounted at SD. Idempotent:
    if it's already mounted and readable, leave it; else lazy-umount + remount."""
    if bd.cmd(f"test -e {SD}/k4_app_prep.sh", timeout=8)[1] == 0:
        return
    for _ in range(2):
        bd.cmd(f"umount -l {SD} 2>/dev/null; mkdir -p {SD}; "
               f"mount -t vfat {SD_DEV} {SD} 2>&1; true", timeout=25)
        if bd.cmd(f"test -e {SD}/k4_app_prep.sh", timeout=8)[1] == 0:
            log(f"    SD mounted at {SD}")
            return
        time.sleep(1)
    log(f"    !! could not mount {SD_DEV} at {SD} with helpers present")

# --------------------------------------------------------------------------- FPGA programming
def program(bitpath):
    tcl = "/tmp/sweep_prog.tcl"
    with open(tcl, "w") as f:
        f.write("open_hw_manager\nconnect_hw_server\n"
                "set t [lindex [get_hw_targets] 0]\nopen_hw_target $t\n"
                f"set_property PARAM.FREQUENCY {JTAG_FREQ} $t\n"
                f"set d [get_hw_devices {JTAG_DEV}]\ncurrent_hw_device $d\n"
                f"set_property PROGRAM.FILE {{{bitpath}}} $d\n"
                "program_hw_devices $d\nputs PROGRAM_DONE\n"
                "close_hw_target\ndisconnect_hw_server\nexit\n")
    t0 = time.time()
    p = subprocess.run([VIVADO, "-mode", "batch", "-source", tcl, "-nojournal", "-nolog"],
                       capture_output=True, text=True, timeout=300)
    out = p.stdout + p.stderr
    if "No matching targets" in out or "no current hw_target" in out:
        raise RuntimeError("JTAG/FT232H not found -- reseat the FT232H USB cable, then re-run")
    if "End of startup status: HIGH" not in out:
        raise RuntimeError("programming never reached 'startup status: HIGH':\n"
                           + "\n".join(out.splitlines()[-15:]))
    return time.time() - t0

# --------------------------------------------------------------------------- console parsing
CYC_RE   = re.compile(r"cycles\[epoch 1 batch 1/1\]:\s*(.+)")
BRK_RE   = re.compile(r"conv backward breakdown:\s*(.+)")
PRE_RE   = re.compile(r"precomputation cycles:\s*(\d+)")
LOSS_RE  = re.compile(r"epoch 1 step 1/1 loss:\s*([-\w.]+)")
SHAPE_RE = re.compile(r"out_h=(\d+),\s*out_w=(\d+),\s*in_channels=(\d+),\s*kk=(\d+),\s*ikk=(\d+)")
BATCH_RE = re.compile(r"batch size:\s*(\d+)")

def kv(s):
    d = {}
    for part in s.replace("\n", " ").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            k, v = k.strip(), v.strip()
            if re.fullmatch(r"-?\d+", v):
                d[k] = int(v)
    return d

def parse_console(text):
    r = {"loss": None, "batch": None, "precompute": None, "cycles_raw": "",
         "breakdown_raw": "", "shape": "", "mse_warn": ("MSE WARN" in text), "stages": {}}
    for rx, key in ((LOSS_RE, "loss"), (BATCH_RE, "batch"), (PRE_RE, "precompute")):
        m = rx.search(text)
        if m:
            r[key] = m.group(1) if key == "loss" else int(m.group(1))
    m = CYC_RE.search(text)
    if m:
        r["cycles_raw"] = m.group(1).strip()
        r["stages"].update(kv(m.group(1)))
    m = BRK_RE.search(text)
    if m:
        r["breakdown_raw"] = m.group(1).strip()
        for k, v in kv(m.group(1)).items():
            r["stages"]["bwd_" + k] = v
    m = SHAPE_RE.search(text)
    if m:
        r["shape"] = "out{}x{}_cin{}_kk{}_ikk{}".format(*m.groups())
    return r

def read_result_regs(bd):
    out, _ = bd.cmd("devmem 0x5FFFF010;devmem 0x50000004;devmem 0x50000050;"
                    "devmem 0x50000040;devmem 0x50000048;devmem 0x5000004C", timeout=15)
    vals = re.findall(r"(?m)^\s*(0x[0-9A-Fa-f]{8})\s*$", out)
    keys = ["sentinel", "nbytes", "trap_flag", "mcause", "mepc", "mtval"]
    return {k: (vals[i].lower() if i < len(vals) else "?") for i, k in enumerate(keys)}

# --------------------------------------------------------------------------- one staged run
def ensure_reset_line(bd):
    """gpio412 is the CVA6 reset. If its direction is 'in', `echo 0 > value`
    silently does nothing, the core never leaves reset, and the run is
    indistinguishable from a hang: sentinel stays 0xDEADDEAD and nbytes stays 0.
    This has cost many wasted runs, so re-assert it before every staged run
    rather than trusting that it is still 'out'."""
    d0, _ = bd.cmd("cat /sys/class/gpio/gpio412/direction 2>&1", timeout=8)
    # ALWAYS re-export and re-drive, never just check. sysfs can keep reporting
    # direction=out while the pin itself stopped driving -- a PL reprogram tears
    # down an EMIO route, and a power-cycle drops the export entirely (observed
    # 2026-09-04 13:15). Checking direction alone therefore proves nothing; the
    # only safe move is to re-establish the line from scratch before every run.
    bd.cmd("echo 412 > /sys/class/gpio/export 2>/dev/null; "
           "echo out > /sys/class/gpio/gpio412/direction 2>/dev/null; "
           "echo 1 > /sys/class/gpio/gpio412/value 2>/dev/null; true", timeout=10)
    d, _ = bd.cmd("cat /sys/class/gpio/gpio412/direction 2>&1", timeout=8)
    ok = "out" in d
    if "out" not in d0:
        log("    !! gpio412 was not driving (PL reprogram/power-cycle drops the "
            f"EMIO export) -- re-established, direction now: {d.strip().splitlines()[0][:20] if d.strip() else '?'}")
    return ok


def stage_and_run(bd, binname, poll_timeout):
    ensure_reset_line(bd)
    prep, _ = bd.cmd(f"sh {SD}/k4_app_prep.sh {SD}/{binname}", timeout=150)
    if "K4_APP_PREP_DONE" not in prep:
        return {"status": "PREP_FAIL", "console": "", "regs": {}, "poll_out": prep}
    poll, rc = bd.cmd(f"sh {SD}/k4_app_poll.sh {poll_timeout}", timeout=poll_timeout + 45)
    regs = read_result_regs(bd)

    if "DONE after" in poll:
        status = "OK"
    elif "still running/hung" in poll:
        status = "HANG"
    else:
        status = "POLL_UNKNOWN"
    if regs.get("trap_flag") == "0x7a7a7a7a":
        status = "TRAP"

    m = re.search(r"exit code = (0x[0-9A-Fa-f]+)", poll)
    exitcode = (m.group(1).lower() if m else regs.get("sentinel", "?"))

    console = ""
    if status in ("OK", "TRAP"):
        console, _ = bd.cmd(f"sh {SD}/k4_console.sh", timeout=120)
    elif status in ("HANG", "POLL_UNKNOWN"):
        # A hang is exactly when the console matters most: whatever the program
        # managed to print before wedging says where it got to. Guard it with a
        # byte count first so a garbage nbytes cannot make k4_console.sh spin.
        try:
            n = int(regs.get("nbytes", "0x0"), 16)
        except ValueError:
            n = 0
        if 0 < n <= 8192:
            console, _ = bd.cmd(f"sh {SD}/k4_console.sh", timeout=120)
    return {"status": status, "exitcode": exitcode, "console": console,
            "regs": regs, "poll_out": poll, "prep_out": prep}

# --------------------------------------------------------------------------- CSV
RUN_FIELDS = ["ts","bitstream","lanes","vlen","axi","llc","tags","date","md5",
              "app","run","status","exitcode",
              "sentinel","nbytes","trap_flag","mcause","mepc","mtval",
              "batch","shape","mse_warn","loss","loss_spike_ref","loss_rel_err_pct",
              "loss_oracle_valid",
              "precompute","forward","backward_or_total","update",
              "cycles_raw","breakdown_raw","prog_seconds"]

def load_done(runs_csv):
    done = set()
    if os.path.exists(runs_csv):
        with open(runs_csv) as f:
            for row in csv.DictReader(f):
                st = row.get("status") or ""
                # A SKIP_* row is NOT a result -- it records that the run never
                # happened (wedged board, harness gate refused, skipped after a
                # hang). Treating it as done meant a re-run into the same outdir
                # silently skipped everything and "completed" in 3 seconds, so
                # the only way to retry was to remember to pass a fresh --outdir.
                if st and not st.startswith("SKIP"):
                    done.add((row["bitstream"], row["app"], str(row["run"])))
    return done

def append_run(runs_csv, row):
    new = not os.path.exists(runs_csv)
    with open(runs_csv, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=RUN_FIELDS)
        if new: w.writeheader()
        w.writerow({k: row.get(k, "") for k in RUN_FIELDS})

def append_long(long_csv, row, stages):
    new = not os.path.exists(long_csv)
    with open(long_csv, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["ts","bitstream","lanes","vlen","axi","llc","tags",
                        "app","run","stage","cycles"])
        for st, v in stages.items():
            w.writerow([row["ts"], row["bitstream"], row["lanes"], row["vlen"],
                        row["axi"], row["llc"], row["tags"], row["app"], row["run"], st, v])

# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bitstreams", action="append",
                    help="glob(s) of .bit files (repeatable); default V2048 FPU-half set")
    ap.add_argument("--apps", default="fc,conv")
    ap.add_argument("--fc-bin", default=FC_BIN,
                    help="SD filename of the fc binary (for a per-VLEN build, "
                         "e.g. --fc-bin fc_layer16only_v1024.fpga16.bin)")
    ap.add_argument("--conv-bin", default=CONV_BIN)
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--port", default="auto",
                    help="serial console; 'auto' (default) probes every CP2108 tty")
    ap.add_argument("--fc-timeout", type=int, default=90)
    ap.add_argument("--conv-timeout", type=int, default=180)
    ap.add_argument("--outdir", default=f"{BIT_DIR}/sweep_results")
    ap.add_argument("--no-reprogram-each-run", action="store_true",
                    help="skip the reprogram before each run (faster, but a "
                         "leftover run can hang the next one on small-LLC parts)")
    ap.add_argument("--no-harness-check", action="store_true")
    ap.add_argument("--no-bin-md5-check", action="store_true",
                    help="don't require the SD binary to match apps/bin/")
    ap.add_argument("--keep-going-on-hang", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--preflight", action="store_true",
                    help="program the newest target + run the harness once, then exit")
    args = ap.parse_args()

    globs = args.bitstreams or DEFAULT_GLOBS
    bitfiles = sorted({p for g in globs for p in glob.glob(g)},
                      key=lambda p: (parse_cfg(os.path.basename(p))["date"],
                                     os.path.basename(p)), reverse=True)
    if not bitfiles:
        sys.exit(f"no bitstreams matched: {globs}")

    if args.list:
        for p in bitfiles:
            c = parse_cfg(os.path.basename(p))
            ok, want = bitstream_md5_ok(p)
            v = "" if c["vlen"] == "2048" else "  <- VLEN!=2048: loss differs, cycles OK"
            print(f"  {c['date']}  L{c['lanes']} V{c['vlen']:<4} AXI{c['axi']:<3} "
                  f"LLC{c['llc']:<7} {'md5OK' if ok else 'md5??' if want is None else 'md5BAD'} "
                  f" {os.path.basename(p)}{v}")
        napp = len([a for a in args.apps.split(',') if a.strip()])
        print(f"\n{len(bitfiles)} bitstreams x {napp} apps x {args.repeats} runs "
              f"= {len(bitfiles)*napp*args.repeats} runs")
        return

    os.makedirs(f"{args.outdir}/raw", exist_ok=True)
    global LOGPATH
    LOGPATH  = f"{args.outdir}/sweep.log"
    runs_csv = f"{args.outdir}/runs.csv"
    long_csv = f"{args.outdir}/cycles_long.csv"

    apps    = [a.strip() for a in args.apps.split(",") if a.strip()]
    appbin  = {"fc": args.fc_bin, "conv": args.conv_bin}
    apptmo  = {"fc": args.fc_timeout, "conv": args.conv_timeout}
    ref_bin = {args.fc_bin:   f"{APPS_BIN_DIR}/{args.fc_bin}",
               args.conv_bin: f"{APPS_BIN_DIR}/{args.conv_bin}"}
    done    = load_done(runs_csv)

    log(f"=== sweep: {len(bitfiles)} bitstreams, apps={apps}, repeats={args.repeats}, "
        f"resume-skip={len(done)}")

    try:
        bd = find_console(None if args.port in ("auto", "") else args.port)
    except serial.SerialException as e:
        sys.exit(str(e))

    mount_sd(bd)
    need = ["k4_app_prep.sh", "k4_app_poll.sh", "k4_console.sh"] + \
           [appbin[a] for a in apps]
    _, rc = bd.cmd("ls " + " ".join(f"{SD}/{n}" for n in need), timeout=15)
    if rc != 0:
        miss = [n for n in need if bd.cmd(f"test -e {SD}/{n}", timeout=8)[1] != 0]
        dev, _   = bd.cmd(f"ls -l {SD_DEV} 2>&1", timeout=8)
        mnt, _   = bd.cmd(f"mount | grep -E ' {SD} |mmcblk' ; true", timeout=8)
        lst, _   = bd.cmd(f"ls -a {SD} 2>&1", timeout=8)
        parts, _ = bd.cmd("ls /dev/mmcblk* 2>&1", timeout=8)
        bd.close()
        sys.exit(
            "SD helper files / binaries not found on the board.\n"
            f"  missing         : {miss}\n"
            f"  {SD_DEV}  : {dev.strip()}\n"
            f"  /dev/mmcblk*    : {parts.strip()}\n"
            f"  mount lines     : {mnt.strip() or '(none -- nothing mounted at %s)' % SD}\n"
            f"  {SD} contents   : {lst.strip()}\n"
            "  -> Is the SD physically in the BOARD slot (not the host reader)?\n"
            f"     If it is: on the board run  umount -l {SD}; mount -t vfat {SD_DEV} {SD}\n"
            "     and check dmesg for a FAT error (may need fsck.vfat).")
    for app in apps:
        b = appbin[app]
        h, _ = bd.cmd(f"md5sum {SD}/{b}", timeout=25)
        got = (h.split() or ["??"])[0]
        ref = ref_bin.get(b)
        want = md5(ref) if (ref and os.path.exists(ref)) else None
        log(f"on-card md5 {b}: {got}" + (f"  (apps/bin: {want})" if want
            else "  (no apps/bin reference to check against)"))
        if want and got != want and not args.no_bin_md5_check:
            bd.close()
            sys.exit(f"SD binary {b} ({got}) != apps/bin build ({want}). "
                     f"Re-copy {ref} to the SD, or pass --no-bin-md5-check.")

    harness = (not args.no_harness_check
               and bd.cmd(f"test -e {SD}/{HARNESS_BIN}", timeout=8)[1] == 0)

    if args.preflight:
        sec = program(bitfiles[0])
        log(f"preflight programmed {os.path.basename(bitfiles[0])} in {sec:.0f}s")
        hr = stage_and_run(bd, HARNESS_BIN if harness else appbin["fc"], 40)
        log(f"preflight run: status={hr['status']} regs={hr['regs']}")
        log(hr["console"][:1500] or hr["poll_out"][:1500])
        bd.cmd("echo 1 > /sys/class/gpio/gpio412/value ; true", timeout=8)
        bd.close()
        return

    def base_row(bs, cfg, bmd5, **extra):
        row = {f: "" for f in RUN_FIELDS}
        row.update(ts=datetime.datetime.now().isoformat(timespec="seconds"),
                   bitstream=bs, lanes=cfg["lanes"], vlen=cfg["vlen"], axi=cfg["axi"],
                   llc=cfg["llc"], tags=cfg["tags"], date=cfg["date"], md5=bmd5)
        row.update(extra)
        return row

    consec_harness_hang = 0
    try:
        for bp in bitfiles:
            bs  = os.path.basename(bp)
            cfg = parse_cfg(bs)
            todo = [(app, r) for app in apps for r in range(1, args.repeats + 1)
                    if (bs, app, str(r)) not in done]
            if not todo:
                log(f"--- {bs}: complete, skip")
                continue
            log(f"=== {bs}  L{cfg['lanes']} V{cfg['vlen']} AXI{cfg['axi']} "
                f"LLC{cfg['llc']} {cfg['tags']}")
            bmd5 = md5(bp)
            ok, want = bitstream_md5_ok(bp)
            if not ok:
                log(f"!! bitstream md5 {bmd5} != sidecar {want} -- SKIPPING {bs}")
                for app, r in todo:
                    append_run(runs_csv, base_row(bs, cfg, bmd5, app=app, run=r,
                                                  status="SKIP_BITSTREAM_MD5"))
                    done.add((bs, app, str(r)))
                continue
            prog_sec = program(bp)
            log(f"    programmed in {prog_sec:.0f}s")

            if harness:
                hr = stage_and_run(bd, HARNESS_BIN, 30)
                log(f"    harness gate: {hr['status']} "
                    f"sentinel={hr['regs'].get('sentinel')} "
                    f"nbytes={hr['regs'].get('nbytes')}")
                # On a gate hang, show whatever the gate binary managed to print.
                # nbytes==0 with no text => the core never started (board/reset).
                # nbytes>0 => the core RAN and wedged, which is a completely
                # different fault and points at the binary or the design.
                if hr["status"] != "OK" and hr.get("console"):
                    log("    gate console: " + hr["console"].strip()[:400].replace("\n", " | "))
                if hr["status"] == "HANG":
                    consec_harness_hang += 1
                    # 1st: this bitstream/binary combo can't run (e.g. the
                    # VLEN-2048 binary on a V1024 part) -- skip just this one.
                    # 2nd in a row (after a fresh program each): the board is
                    # WEDGED -- a prior hung run that reprogram won't clear.
                    for app, r in todo:
                        append_run(runs_csv, base_row(bs, cfg, bmd5, app=app, run=r,
                                   status="SKIP_HARNESS_HANG",
                                   prog_seconds=f"{prog_sec:.0f}", **hr["regs"]))
                        done.add((bs, app, str(r)))
                    if consec_harness_hang >= 2:
                        raise RuntimeError(
                            f"board WEDGED: {consec_harness_hang} bitstreams in a "
                            f"row hung the trivial harness right after a fresh "
                            f"program. Reprogram doesn't recover a hung CVA6 here "
                            f"-- POWER-CYCLE the ZCU102, then re-run (resume "
                            f"continues where this stopped).")
                    log(f"    -> skipping {bs} (harness won't run); continuing")
                    continue
                if hr["status"] != "OK":
                    for app, r in todo:
                        append_run(runs_csv, base_row(bs, cfg, bmd5, app=app, run=r,
                                   status=f"SKIP_HARNESS_{hr['status']}",
                                   prog_seconds=f"{prog_sec:.0f}", **hr["regs"]))
                        done.add((bs, app, str(r)))
                    continue
                consec_harness_hang = 0   # a good harness = board is not wedged

            hung = set()
            for app, r in todo:
                if app in hung and not args.keep_going_on_hang:
                    append_run(runs_csv, base_row(bs, cfg, bmd5, app=app, run=r,
                                                  status="SKIP_AFTER_HANG"))
                    done.add((bs, app, str(r)))
                    continue

                # Reprogram before EVERY run -- a fresh bitstream is the only
                # reliable LLC/DDR/CVA6 reset on this rig (esp. the small-LLC
                # bitstreams; a run left over from the harness or a prior app
                # otherwise hangs the next one). --no-reprogram-each-run trades
                # that safety for speed.
                if not args.no_reprogram_each_run:
                    prog_sec = program(bp)
                    log(f"    reprogrammed in {prog_sec:.0f}s")

                log(f"    {app} run {r}/{args.repeats} ...")
                res = stage_and_run(bd, appbin[app], apptmo[app])
                pc  = parse_console(res["console"])

                # loss oracle is VLEN-specific; only V2048 (and fc@V1024) have one
                oracle_ok = (cfg["vlen"] == "2048")
                sref = (SPIKE_LOSS.get(app) if oracle_ok
                        else SPIKE_LOSS_V1024.get(app) if cfg["vlen"] == "1024" else None)
                relerr = ""
                try:
                    if sref:
                        relerr = f"{100*(float(pc['loss'])-sref)/sref:+.3f}"
                except (TypeError, ValueError):
                    pass

                st = pc["stages"]
                row = base_row(bs, cfg, bmd5,
                    app=app, run=r, status=res["status"], exitcode=res["exitcode"],
                    sentinel=res["regs"].get("sentinel", ""),
                    nbytes=res["regs"].get("nbytes", ""),
                    trap_flag=res["regs"].get("trap_flag", ""),
                    mcause=res["regs"].get("mcause", ""),
                    mepc=res["regs"].get("mepc", ""),
                    mtval=res["regs"].get("mtval", ""),
                    batch=pc["batch"], shape=pc["shape"], mse_warn=pc["mse_warn"],
                    loss=pc["loss"], loss_spike_ref=(sref or ""),
                    loss_rel_err_pct=relerr,
                    loss_oracle_valid=("yes" if oracle_ok else "no-VLEN!=2048"),
                    precompute=pc["precompute"], forward=st.get("forward", ""),
                    backward_or_total=st.get("backward_total", st.get("backward", "")),
                    update=st.get("update", ""),
                    cycles_raw=pc["cycles_raw"], breakdown_raw=pc["breakdown_raw"],
                    prog_seconds=f"{prog_sec:.0f}")
                append_run(runs_csv, row)
                if st:
                    append_long(long_csv, row, st)
                done.add((bs, app, str(r)))

                with open(f"{args.outdir}/raw/{bs[:-4]}__{app}__run{r}.txt", "w") as f:
                    f.write(f"# {bs}\n# {app} run {r}  status={res['status']}\n"
                            f"# regs {res['regs']}\n\n### PREP ###\n{res['prep_out']}\n"
                            f"### POLL ###\n{res['poll_out']}\n### CONSOLE ###\n{res['console']}\n")

                log(f"      -> {res['status']} loss={pc['loss']} "
                    f"fwd={st.get('forward','')} bwd={row['backward_or_total']} "
                    f"sentinel={res['regs'].get('sentinel')} "
                    f"nbytes={res['regs'].get('nbytes')}")
                if res["status"] == "HANG":
                    hung.add(app)
                    # an app hang can leave the CVA6 spinning; verify the board
                    # still runs the trivial harness after a fresh program.
                    if harness:
                        program(bp)
                        h2 = stage_and_run(bd, HARNESS_BIN, 30)
                        log(f"    post-hang harness check: {h2['status']}")
                        if h2["status"] == "HANG":
                            raise RuntimeError(
                                f"board WEDGED after {app} hung on {bs}: a fresh "
                                f"program + trivial harness now also hangs. "
                                f"POWER-CYCLE the ZCU102, then re-run to resume.")
        log("=== sweep complete")
    except KeyboardInterrupt:
        log("!! interrupted -- CSV saved; re-run to resume")
    except (RuntimeError, serial.SerialException) as e:
        log(f"!! ABORT: {e}")
        log("   CSV rows so far are saved -- fix the board, then re-run to resume.")
        try: bd.close()
        except Exception: pass
        sys.exit(2)
    finally:
        try:
            bd.cmd("echo 1 > /sys/class/gpio/gpio412/value 2>/dev/null ; true", timeout=10)
        except Exception:
            pass
        bd.close()

    print(f"\n================= {runs_csv} =================")
    with open(runs_csv) as f:
        sys.stdout.write(f.read())
    print(f"\nwide  : {runs_csv}\nlong  : {long_csv}\nraw   : {args.outdir}/raw/\nlog   : {LOGPATH}")

if __name__ == "__main__":
    try:
        main()
    except serial.SerialException as e:
        sys.exit(f"serial/board error: {e}")
    except KeyboardInterrupt:
        sys.exit(130)
