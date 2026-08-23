// Host-only shims for symbols that exist on a jailbroken device but not on
// the Mac Catalyst host the test suite runs on. Nothing here is compiled
// into the tweak (the Theos Makefile only globs Source/).
#import <Foundation/Foundation.h>
#include <string.h>
#include <sys/syslimits.h>

// libroot (rootless/roothide path resolution). On the host the "jailbreak
// root" is just "/", so the path passes through unchanged.
char *_Nullable libroot_dyn_jbrootpath(const char *_Nullable path, char *_Nullable resolvedPath) {
    if (!path) return NULL;
    if (resolvedPath) { strlcpy(resolvedPath, path, PATH_MAX); return resolvedPath; }
    return (char *)path;
}
