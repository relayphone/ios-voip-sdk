// Loaded into every process via the simulator's launchd environment.
// Loads the runtime only into the configured apps; links nothing but CoreFoundation.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__attribute__((constructor)) static void ck_bootstrap(void) {
  const char *wanted = getenv("CKSIM_BUNDLE_IDS");
  const char *runtime = getenv("CKSIM_RUNTIME");
  if (!wanted || !runtime) return;
  CFBundleRef bundle = CFBundleGetMainBundle();
  CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : NULL;
  if (!identifier) return;
  char id[256];
  if (!CFStringGetCString(identifier, id, sizeof id, kCFStringEncodingUTF8)) return;
  char list[1024];
  strlcpy(list, wanted, sizeof list);
  for (char *save = NULL, *item = strtok_r(list, ",", &save); item; item = strtok_r(NULL, ",", &save)) {
    if (strcmp(item, id) != 0) continue;
    void *handle = dlopen(runtime, RTLD_NOW);
    fprintf(stderr, "CKSIM bootstrap %s -> %s\n", id, handle ? "loaded" : dlerror());
    return;
  }
}
