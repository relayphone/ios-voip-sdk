#include <notify.h>
#include <stdio.h>
int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr,"usage: cksim-notify NOTIFICATION\n"); return 2; }
  return notify_post(argv[1]) == NOTIFY_STATUS_OK ? 0 : 1;
}
