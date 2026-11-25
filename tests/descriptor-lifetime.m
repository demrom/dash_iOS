// Drive descriptor-lifetime.sh through the public native command runtime.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <signal.h>
#include <unistd.h>

static NSString *quote(NSString *argument) {
    return [NSString stringWithFormat:@"'%@'", [argument stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static void timedOut(int signalNumber) {
    (void)signalNumber;
    _Exit(124);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *manager = NSFileManager.defaultManager;
        if (![manager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL] ||
            chdir(directory.fileSystemRepresentation)) return 2;
        signal(SIGALRM, timedOut);
        alarm(240);
        initializeEnvironment();
        ios_switchSession("descriptor-lifetime");
        NSString *bin = [[@(argv[1]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"bin"];
        ios_setenv("PATH", bin.fileSystemRepresentation, 1);
        ios_setStreams(stdin, stdout, stderr);
        joinMainThread = true;
        NSString *command = [NSString stringWithFormat:@"dash %@ %@", quote(@(argv[1])), quote(@(argv[2]))];
        int result = ios_system(command.UTF8String);
        int status = ios_getCommandStatus();
        alarm(0);
        chdir("/");
        if (![manager removeItemAtPath:directory error:NULL]) return 2;
        return result || status ? 1 : 0;
    }
}
