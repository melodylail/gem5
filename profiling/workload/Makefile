# profiling/workload/Makefile
.PHONY: all clean

all: workload

workload: workload.c
	gcc -O2 -static -o workload workload.c -lm

clean:
	rm -f workload
