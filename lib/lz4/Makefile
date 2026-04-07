ccflags-y += -O3 \
    -DLZ4_FREESTANDING=0 \
    -DLZ4_FAST_DEC_LOOP=1

obj-y += lz4.o lz4hc.o
CFLAGS_lz4.o  += -DLZ4_HEAPMODE=1
CFLAGS_lz4hc.o += -DLZ4HC_HEAPMODE=1
