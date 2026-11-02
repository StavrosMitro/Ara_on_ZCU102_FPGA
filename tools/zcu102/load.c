// load.c
// Loads a raw RISC-V binary into physical DDR memory via /dev/mem,
// so the CVA6 core (which sees this region as LlcOutRegionStart = 0x40000000)
// can fetch and execute it.
//
// Build (native on ARM):   gcc -O2 -static -o load load.c
// Build (cross-compile):   aarch64-linux-gnu-gcc -O2 -static -o load load.c
//
// Usage:                   ./load fmatmul.fpga.bin

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

// Physical address where the CVA6 expects its program.
// This matches LlcOutRegionStart in cheshire_pkg.sv.
#define LOAD_ADDR  0x40000000UL

// Size of the memory window we map. 512MB to cover program + training data.
#define MAP_SIZE   0x20000000UL

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <binary>\n", argv[0]);
        return 1;
    }

    // --- Step 1: Read the binary file into a host buffer ---
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror("fopen");
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (size <= 0) {
        fprintf(stderr, "Error: file is empty or unreadable\n");
        fclose(f);
        return 1;
    }
    if ((uint64_t)size > MAP_SIZE) {
        fprintf(stderr, "Error: binary (%ld bytes) larger than map window (%lu)\n",
                size, MAP_SIZE);
        fclose(f);
        return 1;
    }

    uint8_t *buf = malloc(size);
    if (!buf) {
        perror("malloc");
        fclose(f);
        return 1;
    }
    if (fread(buf, 1, size, f) != (size_t)size) {
        perror("fread");
        free(buf);
        fclose(f);
        return 1;
    }
    fclose(f);
    printf("Binary size: %ld bytes\n", size);

    // --- Step 2: Open /dev/mem to access physical memory ---
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        free(buf);
        return 1;
    }

    // --- Step 3: Map the physical DDR region into our virtual space ---
    void *mem = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, LOAD_ADDR);
    if (mem == MAP_FAILED) {
        perror("mmap");
        close(fd);
        free(buf);
        return 1;
    }
    printf("Mapped physical 0x%lX -> virtual %p\n", LOAD_ADDR, mem);

    // --- Step 4: Copy the binary into physical memory ---
    memcpy(mem, buf, size);
    printf("Wrote %ld bytes to physical 0x%lX\n", size, LOAD_ADDR);

    // --- Step 5: Read back the first word to verify the write landed ---
    uint32_t first_written = *(uint32_t *)buf;
    uint32_t first_read    = *(volatile uint32_t *)mem;
    printf("Verify first word: wrote 0x%08X, read 0x%08X -- %s\n",
           first_written, first_read,
           (first_read == first_written) ? "OK" : "FAIL");

    // Also check a word near the end, to catch partial-write issues
    if (size >= 8) {
        uint32_t last_off      = (uint32_t)(size - 4);
        uint32_t last_written  = *(uint32_t *)(buf + last_off);
        uint32_t last_read     = *(volatile uint32_t *)((uint8_t *)mem + last_off);
        printf("Verify last word:  wrote 0x%08X, read 0x%08X -- %s\n",
               last_written, last_read,
               (last_read == last_written) ? "OK" : "FAIL");
    }

    // --- Step 6: Flush and clean up ---
    msync(mem, size, MS_SYNC);   // ensure writes reach physical memory
    munmap(mem, MAP_SIZE);
    close(fd);
    free(buf);

    printf("Done. Binary loaded at 0x%lX.\n", LOAD_ADDR);
    printf("Next: deassert CVA6 reset (echo 0 > gpio412/value) to start execution.\n");
    return 0;
}