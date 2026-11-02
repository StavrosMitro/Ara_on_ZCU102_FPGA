#!/bin/sh
# Usage: sh k4_app_prep.sh <bin_path>
GPIO=/sys/class/gpio/gpio412
LEN=0x50000004
EOC=0x5FFFF010
BIN="$1"

[ -d "$GPIO" ] || echo 412 > /sys/class/gpio/export 2>/dev/null
echo out > "$GPIO/direction" 2>/dev/null
[ -e /mnt/sd/load ] || { mkdir -p /mnt/sd; mount -t vfat /dev/mmcblk0p1 /mnt/sd 2>/dev/null; }

echo "reset=1"; echo 1 > "$GPIO/value"
devmem $LEN 32 0
for a in 0x50000070 0x50000074 0x50000078 0x5000007C 0x50000080 0x50000084 0x50000088 0x5000008C 0x50000090 0x50000094; do devmem $a 32 0; done
devmem $EOC 32 0xDEADDEAD
echo "loading $BIN"
/mnt/sd/load "$BIN" > /mnt/sd/k4_load_out.txt 2>&1
rc=$?
lines=$(wc -l < /mnt/sd/k4_load_out.txt)
echo "LOAD_EXIT=$rc LOAD_OUTPUT_LINES=$lines"
echo "LOAD_GREP_MATCHES:"
grep -i -E "verify|error|fail|fatal|byte" /mnt/sd/k4_load_out.txt | tail -20
echo "LOAD_OUTPUT_TAIL:"
tail -5 /mnt/sd/k4_load_out.txt
[ $rc -eq 0 ] || { echo "FATAL: LOAD FAILED"; exit 1; }
echo "STAGED, board HELD IN RESET"
echo "K4_APP_PREP_DONE"
