# Running programs on the ZCU102

How to program the FPGA, stage a bare-metal binary, run it on CVA6 + Ara and read
its output, all from a terminal. Building the bitstream and the binaries is
covered in [building.md](building.md). The helper scripts mentioned here are in
[`tools/zcu102/`](../../tools/zcu102).

---

## 0. How it fits together

```
  host PC ──USB──┬── JTAG cable (FTDI FT232H, 0403:6014) → programs the PL with the .bit
                 └── CP2108 (10c4:ea71, on the board)    → UART → shell on the PS (ARM Linux)

  ZCU102:  PS (ARM, Linux from the SD card) ── HP0 AXI ── PL (Cheshire: CVA6 + Ara + LLC)
                         └────────── shared PS DDR ──────────┘
```

* You get **one shell**: Linux on the PS, over the CP2108 serial console, in `screen`.
* The **CVA6/Ara program is bare-metal** and does not use a UART. It writes its
  `printf` output into a **mailbox in the shared DDR**, and the PS reads it with
  `devmem`.
* PS Linux is limited to the first 1 GiB of DDR (`mem=1024M` in `uEnv.txt`).
  The program is loaded at `0x4000_0000`, which is above that.
* **`gpio412`** (a PS GPIO) drives the CVA6 **reset**: `1` = held in reset,
  `0` = running.
* **Reprogram the FPGA before every run.** Reprogramming resets the LLC to a
  clean state. Small-LLC builds in particular can hang on leftover LLC/DDR state
  from the previous run.
* Binaries reach the board on the **SD card**, which you move between the board's
  slot and a card reader on the host. The board mounts it at `/mnt/sd`
  (`/dev/mmcblk0p1`).

### Mailbox addresses (read/write from the PS shell with `devmem`)

| Address | Meaning | Values |
|---|---|---|
| `0x5FFFF010` | **sentinel / exit code** | `0xDEADDEAD` = staged or still running · `0x00000000` = pass · `0x0000000N` = N failed checks (tests) or exit code N (apps) |
| `0x50000004` | console byte count | valid bytes in the buffer below |
| `0x50002000` | console text buffer | the program's `printf` output, little-endian words |
| `0x50000050` | **trap flag** | `0x7A7A7A7A` = the core trapped. Any other value = no trap |
| `0x50000040` | `mcause` | meaningful only if the trap flag is set |
| `0x50000048` | `mepc` | 〃 |
| `0x5000004C` | `mtval` | for an illegal instruction (`mcause=2`), the instruction word |
| `0x50000070`–`0x50000094` | scratch markers | app-specific progress markers |

> A trap is real **only** when `0x50000050` reads `0x7A7A7A7A`. Otherwise the
> `mcause/mepc/mtval` slots contain whatever was in DDR before.

---

## 1. One-time SD card setup

FAT32 partition with:

| File | Where from |
|---|---|
| `BOOT.BIN`, `boot.scr`, `image.ub` | Xilinx PetaLinux **2021.1** pre-built images for the ZCU102 (from the ZCU102 BSP, `pre-built/linux/images/`) |
| `uEnv.txt` | `tools/zcu102/uEnv.txt`: sets `mem=1024M` so Linux leaves the upper DDR to CVA6 |
| `load` | built from `tools/zcu102/load.c`: `aarch64-linux-gnu-gcc -O2 -static -o load load.c` |
| `k4_app_prep.sh`, `k4_app_poll.sh`, `k4_console.sh` | `tools/zcu102/` |
| your `*.fpga16.bin` | `deps/ara/apps/bin/` |

Set the ZCU102 boot-mode switches (SW6) to SD boot and power on. The PL bitstream
in `BOOT.BIN` gets replaced as soon as you program over JTAG, so it does not
matter which one is in there.

---

## 2. Connect the console (once per session, or after any USB reseat)

The CP2108 exposes **4** tty nodes, and their numbering is **not stable**: after a
reboot or a USB reseat the block can shift (`ttyUSB0-3` ↔ `ttyUSB1-4`), and the
JTAG cable sometimes takes `ttyUSB0`. Check which node is which:

```bash
lsusb | grep -iE '10c4:ea71|0403:6014'          # 10c4:ea71 = console, 0403:6014 = JTAG
for n in /dev/ttyUSB*; do
  p=$(readlink -f "/sys/class/tty/$(basename $n)/device")
  while [ -n "$p" ] && [ ! -e "$p/idVendor" ]; do p=$(dirname "$p"); done
  echo "$n -> $(cat $p/idVendor):$(cat $p/idProduct)"
done
```

Use the **lowest-numbered `10c4` node**:

```bash
screen -dmS board /dev/ttyUSB1 115200      # <-- the node you found above
screen -r board                            # attach; Ctrl-A d to detach
```

Press Enter: you should get the PS shell prompt.

* Do **not** start the console as `sudo screen`. A root-owned `screen` keeps the
  port busy, and your user cannot see it with `fuser`/`lsof`. Add yourself to
  `dialout` instead. To clean up a leftover one: `sudo pkill -f 'SCREEN /dev/ttyUSB'`.
* If the CP2108 is missing from `lsusb`, reseat its USB cable. This happens
  regularly when the SD card is moved.

---

## 3. Check the reset line (before every run)

In the board shell:

```sh
cat /sys/class/gpio/gpio412/direction     # MUST print: out
cat /sys/class/gpio/gpio412/value

# if gpio412 is missing or direction is "in":
echo 412 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio412/direction
echo 1   > /sys/class/gpio/gpio412/value   # hold CVA6 in reset
```

If `direction` is `in`, `echo 0 > value` silently does nothing, and **every run
looks like a hang** with all-zero results.

---

## 4. Program the FPGA (before every run), host side

```bash
vivado_lab -mode batch -nojournal -nolog \
    -source tools/zcu102/program.tcl -tclargs /path/to/cheshire.zcu102.bit
```

It takes 1–2 minutes. It worked if the log shows **`End of startup status: HIGH`**
and `PROGRAM_DONE`.

* "No matching targets found": the JTAG cable dropped off USB. Reseat it and
  check `lsusb | grep 0403:6014`.
* "Cannot start server on port 3121": kill the stale `hw_server` and retry.

---

## 5. Stage the binary

### 5a. Copy it to the SD card (host, card in the reader)

```bash
cp deps/ara/apps/bin/mytest.fpga16.bin /media/$USER/BOOT/
md5sum /media/$USER/BOOT/mytest.fpga16.bin
sync && umount /media/$USER/BOOT
```

Move the SD card into the board's slot.

### 5b. Load it into DDR (board shell)

```sh
umount -l /mnt/sd 2>/dev/null
mkdir -p /mnt/sd && mount -t vfat /dev/mmcblk0p1 /mnt/sd
md5sum /mnt/sd/mytest.fpga16.bin                  # must match the host md5

sh /mnt/sd/k4_app_prep.sh /mnt/sd/mytest.fpga16.bin
```

`k4_app_prep.sh` asserts reset (`gpio412=1`), clears the console length and the
markers, sets the sentinel to `0xDEADDEAD`, writes the binary to DDR at
`0x40000000` with `load` (which reads back the first and last word), and
**leaves the core in reset**. Expected output:

```
LOAD_EXIT=0 LOAD_OUTPUT_LINES=...
STAGED, board HELD IN RESET
K4_APP_PREP_DONE
```

If you see `FATAL: LOAD FAILED` instead, the DDR write did not verify. Stop here.

---

## 6. Run it

```sh
sh /mnt/sd/k4_app_poll.sh 120        # release reset, poll the sentinel for up to 120 s
```

```
DONE after 7s, exit code = 0x00000000     <- 0x0 = pass; 0xN = N failures / exit N
POLL_DONE final=0x00000000
```

Typical run times: small tests ~15 s, `fc_layer16only` / `conv_layer16only`
~30 s, `vggnet16` fine-tuning 60–120 s.

Result registers:

```sh
echo "sentinel : $(devmem 0x5FFFF010)"
echo "bytes    : $(devmem 0x50000004)"
echo "trap flag: $(devmem 0x50000050)"      # 0x7A7A7A7A = trapped
echo "mcause   : $(devmem 0x50000040)"
echo "mepc     : $(devmem 0x50000048)"
echo "mtval    : $(devmem 0x5000004C)"
```

> The console buffer and the sentinel can sit in the LLC. If a run hangs, the PS
> may read `bytes=0` even though the program had made progress, because the data
> never reached DDR. "Nothing printed" is therefore not proof that nothing ran.

---

## 7. Read the program's output

### Option A: as text, on the board (simplest)

```sh
sh /mnt/sd/k4_console.sh
```

It decodes the buffer word by word. Output is slow, because the serial console is
slow, but verbatim. To keep a copy on the host, turn on `screen` logging before
you run it:

```bash
screen -S board -X logfile /tmp/board.log
screen -S board -X log on
#   ... run k4_console.sh in the session ...
screen -S board -X log off
```

### Option B: raw words on the board, decoded on the host

Board:

```sh
n=$(( $(devmem 0x50000004) )); i=0
while [ $i -lt $n ]; do devmem $(printf '0x%X' $((0x50002000 + i))); i=$((i+4)); done
```

Host, on the screen log you captured:

```bash
python3 - <<'EOF'
import re, struct
seg = open('/tmp/board.log').read()
w = [int(m, 16) for m in re.findall(r'^0x([0-9A-Fa-f]{8})\s*$', seg, re.M)]
print(b''.join(struct.pack('<I', x) for x in w).decode('ascii', errors='replace'))
EOF
```

### Option C: drive everything from the host

`screen -X stuff` types into the session. It **eats `$`**, so send only literal
command lines and expand variables on the host. Wait about 1.1 s per line.

```bash
NB=$(printf '0x%X' 1600)     # <- the real byte count from devmem 0x50000004
python3 -c "
base, n = 0x50002000, $NB
nw = (n + 3)//4
for c in range(0, nw, 8):
    print('; '.join(f'devmem {hex(base+(c+k)*4)}' for k in range(8) if c+k < nw))
" > /tmp/dump.txt

: > /tmp/board.log
screen -S board -X logfile /tmp/board.log ; screen -S board -X log on ; sleep 0.5
screen -S board -X stuff "echo DUMP_START$(printf '\r')" ; sleep 0.5
while IFS= read -r L; do screen -S board -X stuff "$L$(printf '\r')"; sleep 1.1; done < /tmp/dump.txt
sleep 2 ; screen -S board -X stuff "echo DUMP_END$(printf '\r')" ; sleep 2
screen -S board -X log off

python3 -c "
import re, struct
seg = open('/tmp/board.log').read().split('DUMP_START',1)[1].split('DUMP_END',1)[0]
w = [int(m,16) for m in re.findall(r'^0x([0-9A-Fa-f]{8})\s*\$', seg, re.M)]
print(b''.join(struct.pack('<I', x) for x in w)[:$NB].decode('ascii', errors='replace'))
"
```

To see what is on the screen right now without attaching:

```bash
screen -S board -X hardcopy /tmp/cap.txt ; tail -20 /tmp/cap.txt
```

---

## 8. Finish

Board:

```sh
echo 1 > /sys/class/gpio/gpio412/value      # hold CVA6 in reset
sync && umount /mnt/sd
```

Unmount the card before you pull it, on both sides. A card pulled while mounted
can corrupt the FAT, and the board then falls into a U-Boot PXE loop on the next
boot.

---

## 9. "It hung": confirm before you believe it

An all-zero result (`sentinel=0xDEADDEAD`, `bytes=0`, no trap) is usually a setup
problem:

1. Is `gpio412` direction `out`? (section 3)
2. Did programming succeed? (`End of startup status: HIGH`)
3. Run a small known-good binary on the same freshly programmed bitstream. If
   that one passes and yours does not, the hang is in your program.

Once a run has really hung, reprogramming does **not** always bring CVA6 back.
If even the known-good binary then hangs, **power-cycle the ZCU102**.

---

## 10. Pitfalls

| Symptom | Cause / fix |
|---|---|
| every run all-zero, "hang" | `gpio412` came back as `in` after re-export: `echo out > .../direction` |
| `vivado_lab`: "No matching targets" | JTAG cable dropped: reseat, `lsusb \| grep 0403:6014` |
| `screen` attaches to nothing | wrong `ttyUSB` node: re-map as in section 2 |
| serial port busy (EBUSY) | a leftover root `screen` holds it: `sudo pkill -f 'SCREEN /dev/ttyUSB'` |
| CP2108 gone after moving the SD card | reseat the CP2108 USB cable |
| `/mnt/sd`: "Directory bread failed" | `umount -l /mnt/sd`, then mount again |
| board stuck in a U-Boot PXE loop | SD was pulled while mounted: power-cycle |
| `dd`/`hexdump` on `/dev/mem` → "Bad address" | that window only works through `mmap` (`devmem`, `load`) |
| `mcause/mepc/mtval` look like a trap | not a trap unless `0x50000050 == 0x7A7A7A7A` |
| loss prints as a huge number instead of `nan` | `-ffast-math` removes NaN checks, so "a number" does not prove "finite" |
| cycle counts differ by ~0.5 % between runs | normal: results are deterministic, cycle counts are not. Take the median of 3 |

---

## 11. One run, condensed

```bash
# ---- host ----
cp mytest.fpga16.bin /media/$USER/BOOT/ && md5sum /media/$USER/BOOT/mytest.fpga16.bin
sync && umount /media/$USER/BOOT
#   >>> move the SD card to the board <<<
vivado_lab -mode batch -nojournal -nolog -source tools/zcu102/program.tcl -tclargs my.bit
#   wait for "End of startup status: HIGH"

# ---- board (screen -r board) ----
cat /sys/class/gpio/gpio412/direction                 # out
umount -l /mnt/sd 2>/dev/null; mount -t vfat /dev/mmcblk0p1 /mnt/sd
md5sum /mnt/sd/mytest.fpga16.bin                       # matches the host
sh /mnt/sd/k4_app_prep.sh /mnt/sd/mytest.fpga16.bin    # -> K4_APP_PREP_DONE
sh /mnt/sd/k4_app_poll.sh 120                          # -> exit code = 0xN
sh /mnt/sd/k4_console.sh                               # the program's output
echo 1 > /sys/class/gpio/gpio412/value; sync; umount /mnt/sd
```

---

## 12. Unattended runs over many bitstreams

`tools/zcu102/sweep_layers_over_bitstreams.py` automates sections 4–7. For every
bitstream it programs the FPGA, drives the board shell over pyserial (the SD
helper scripts and binaries must already be on the card), runs
`fc_layer16only` / `conv_layer16only` N times, and writes loss and cycle counts
to CSV. It can resume after an interruption, and it stops with a clear message
when the board needs a power-cycle.

```bash
pip install pyserial
export BIT_DIR=~/bitstreams              # where the .bit files are
export VIVADO_LAB=/tools/Xilinx/Vivado_Lab/2021.1/bin/vivado_lab
export APPS_BIN_DIR=$PWD/deps/ara/apps/bin   # to check the SD copies by md5
tools/zcu102/sweep_layers_over_bitstreams.py --list
tools/zcu102/sweep_layers_over_bitstreams.py --preflight     # one program + harness
tools/zcu102/sweep_layers_over_bitstreams.py --bitstreams "$BIT_DIR/*.bit" --repeats 3
```

The default bitstream globs and timeouts are at the top of the script.
