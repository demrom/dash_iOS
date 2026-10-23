// Capture real Dash diagnostics through the public ios_popen command boundary.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

static int (*shellMain)(int, char **);
int warning_shell_main(int argc, char **argv) { return shellMain(argc, argv); }

static BOOL captured(const char *command, const char *expected, int expectedStatus) {
    pid_t child = ios_fork();
    FILE *pipe = ios_popen(command, "r");
    if (!pipe) { ios_waitpid(child); return NO; }
    char output[256] = {0};
    size_t length = fread(output, 1, sizeof output - 1, pipe);
    int closeStatus = fclose(pipe);
    ios_waitpid(child);
    return closeStatus == 0 && ios_getCommandStatus() == expectedStatus && length == strlen(expected) && !strcmp(output, expected);
}

int warning_capture_main(int argc, char **argv) {
    for (int iteration = 0; iteration < 3; ++iteration)
        if (!captured("sh -c 'dash-missing-command 2>&1'", "sh: 1: dash-missing-command: not found\n", 127)) return 1;
    if (!captured("sh -c 'printf RECOVERY_OK'", "RECOVERY_OK", 0)) return 1;
    return fputs("MISSING_COMMAND_CAPTURE_OK\n", thread_stdout) == EOF;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        alarm(5);
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library || !(shellMain = dlsym(library, "main"))) return 2;
        initializeEnvironment();
        ios_switchSession("missing-command-capture");
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        void *registration = NULL;
        if (!input || !output || !error || ashell_register_owned_streams(input, output, error, &registration)) return 2;
        ios_setStreams(input, output, error);
        replaceCommand(@"sh", @"warning_shell_main", false);
        replaceCommand(@"warning-capture", @"warning_capture_main", false);
        joinMainThread = false;
        pid_t root = ios_fork();
        ios_system("warning-capture");
        ios_waitpid(root);
        ashell_wait_owned_streams(registration);
        int status = ios_getCommandStatus();
        rewind(output);
        char actual[64] = {0};
        size_t length = fread(actual, 1, sizeof actual - 1, output);
        rewind(error);
        BOOL passed = status == 0 && length == 27 && !strcmp(actual, "MISSING_COMMAND_CAPTURE_OK\n") && fgetc(error) == EOF;
        ashell_unregister_owned_streams(&registration);
        ios_setStreams(stdin, stdout, stderr);
        int inputClose = fclose(input), outputClose = fclose(output), errorClose = fclose(error);
        passed = passed && !inputClose && !outputClose && !errorClose;
        dlclose(library);
        alarm(0);
        dprintf(STDOUT_FILENO, "missing-command capture: status=%d %s\n", status, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
