target	= smallbrain

CC	= cc
CFLAGS	= -g -no-pie

all: ${target}
${target}: ${target}.s
	m4 macros.m4 $< >out.s
	${CC} ${CFLAGS} -o $@ out.s

.PHONY: bench clean
bench:
	hyperfine -S sh -w 200 -r 100000 "./smallbrain tests/towers-of-hanoi.bf"
clean:
	rm -f ${target} out.s
