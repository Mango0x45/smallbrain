#include <sys/stat.h>

#include <stddef.h>
#include <stdio.h>

int
main(void)
{
	printf("Size of stat struct:\t%zu bytes\nOffset of st_size:\t%zu\n", sizeof(struct stat),
	       offsetof(struct stat, st_size));
	return 0;
}
