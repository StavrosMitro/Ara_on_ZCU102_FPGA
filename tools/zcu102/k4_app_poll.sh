#!/bin/sh
# Usage: sh k4_app_poll.sh <wait_seconds>
GPIO=/sys/class/gpio/gpio412
EOC=0x5FFFF010
WAIT="$1"

echo "reset=0 -> running (poll up to $WAIT seconds)"
echo 0 > "$GPIO/value"
i=0
while [ $i -lt "$WAIT" ]; do
  e=$(devmem $EOC)
  if [ "$e" != "0xDEADDEAD" ]; then
    echo "DONE after ${i}s, exit code = $e (0x0 = clean PASS, nonzero = error count)"
    break
  fi
  sleep 1
  i=$((i+1))
done
FINAL=$(devmem $EOC)
if [ "$FINAL" = "0xDEADDEAD" ]; then
  echo "still running/hung after ${WAIT}s"
fi
echo "marker(0x70)=$(devmem 0x50000070)"
echo "POLL_DONE final=$FINAL"
