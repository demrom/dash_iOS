// Verify the environment delivered by Dash to a real embedded command.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
extern char **environmentVariables(pid_t);
extern pid_t ios_currentPid(void);
static int (*shellMain)(int, char **);
int environment_shell_main(int argc, char **argv) { return shellMain(argc, argv); }
int environment_probe_main(int argc, char **argv) {
    BOOL exported = NO, assigned = NO, hidden = NO, malformed = NO;
    for (char **entry = environmentVariables(ios_currentPid()); entry && *entry; ++entry) {
        exported |= !strcmp(*entry, "DASH_EXPORTED=kept");
        assigned |= !strcmp(*entry, "DASH_INLINE=assigned");
        hidden |= !strncmp(*entry, "DASH_HIDDEN=", sizeof("DASH_HIDDEN=") - 1);
        malformed |= !strchr(*entry, '=');
    }
    return !exported || !assigned || hidden || malformed;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        alarm(5);
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library || !(shellMain = dlsym(library, "main"))) return 2;
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL]) return 2;
        NSString *marker = [directory stringByAppendingPathComponent:@"environment-probe"];
        FILE *file = fopen(marker.fileSystemRepresentation, "w");
        if (!file || fclose(file)) return 2;
        initializeEnvironment();
        ios_switchSession("exported-environment");
        ios_setenv("PATH", directory.fileSystemRepresentation, 1);
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        void *owner = NULL;
        if (!input || !output || !error || ashell_register_owned_streams(input, output, error, &owner)) return 2;
        ios_setStreams(input, output, error);
        replaceCommand(@"sh", @"environment_shell_main", false);
        replaceCommand(@"environment-probe", @"environment_probe_main", false);
        joinMainThread = true;
        int result = ios_system("sh -c 'export DASH_EXPORTED=kept; DASH_HIDDEN=local; unset MAIL TERM; DASH_INLINE=assigned environment-probe && printf RECOVERY_OK'");
        ashell_wait_owned_streams(owner);
        fflush(output);
        rewind(output); rewind(error);
        char actual[32] = {0};
        size_t count = fread(actual, 1, sizeof actual - 1, output);
        BOOL passed = result == 0 && count == 11 && !strcmp(actual, "RECOVERY_OK") && fgetc(error) == EOF;
        ashell_unregister_owned_streams(&owner);
        ios_setStreams(stdin, stdout, stderr);
        int inputClose = fclose(input), outputClose = fclose(output), errorClose = fclose(error);
        passed = passed && !inputClose && !outputClose && !errorClose;
        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
        dlclose(library);
        alarm(0);
        puts(passed ? "PASS: exported environment, command assignment and recovery" : "FAIL: command environment");
        return passed ? 0 : 1;
    }
}
