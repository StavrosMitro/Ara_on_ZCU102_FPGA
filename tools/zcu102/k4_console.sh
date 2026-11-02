#!/bin/sh
# Dump the CVA6/Ara DDR console buffer as text.
BUF=0x50002000
n=$(devmem 0x50000004); n=$((n))
echo "=== console: $n bytes ==="
i=0
while [ $i -lt $n ]; do
  w=$(devmem $(printf '0x%X' $((BUF + i)))); v=$((w))
  o0=$(printf '%03o' $((v & 255)))
  o1=$(printf '%03o' $(((v >> 8) & 255)))
  o2=$(printf '%03o' $(((v >> 16) & 255)))
  o3=$(printf '%03o' $(((v >> 24) & 255)))
  printf "\\$o0\\$o1\\$o2\\$o3"
  i=$((i + 4))
done
echo
echo "=== end ($n bytes) ==="
