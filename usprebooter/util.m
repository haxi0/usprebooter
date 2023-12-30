//
//  util.m
//  usprebooter
//
//  Created by LL on 29/11/23.
//

#import <Foundation/Foundation.h>
#import "util.h"
#import <spawn.h>
#import <copyfile.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>

#include <sys/types.h>
#define PT_TRACE_ME 0
/* Attach to a process that is already running. */
//PTRACE_ATTACH = 16,
#define PT_ATTACH 16

/* Detach from a process attached to with PTRACE_ATTACH.  */
//PTRACE_DETACH = 17,
#define PT_DETACH 17
#define PT_ATTACHEXC    14    /* attach to running process with signal exception */
int ptrace(int, pid_t, caddr_t, int);

NSString *getExecutablePath(void)
{
    uint32_t len = PATH_MAX;
    char selfPath[len];
    _NSGetExecutablePath(selfPath, &len);
    NSLog(@"executable path: %@", [NSString stringWithUTF8String:selfPath]);
    return [NSString stringWithUTF8String:selfPath];
}

int fd_is_valid(int fd)
{
    return fcntl(fd, F_GETFD) != -1 || errno != EBADF;
}

NSString* getNSStringFromFile(int fd)
{
    NSMutableString* ms = [NSMutableString new];
    ssize_t num_read;
    char c;
    if(!fd_is_valid(fd)) return @"";
    while((num_read = read(fd, &c, sizeof(c))))
    {
        [ms appendString:[NSString stringWithFormat:@"%c", c]];
        if(c == '\n') break;
    }
    return ms.copy;
}

void printMultilineNSString(NSString* stringToPrint)
{
    NSCharacterSet *separator = [NSCharacterSet newlineCharacterSet];
    NSArray* lines = [stringToPrint componentsSeparatedByCharactersInSet:separator];
    for(NSString* line in lines)
    {
        NSLog(@"%@", line);
    }
}

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

int spawnRoot(NSString* path, NSArray* args, NSString** stdOut, NSString** stdErr)
{
    NSMutableArray* argsM = args.mutableCopy ?: [NSMutableArray new];
    [argsM insertObject:path.lastPathComponent atIndex:0];
    
    NSUInteger argCount = [argsM count];
    char **argsC = (char **)malloc((argCount + 1) * sizeof(char*));

    for (NSUInteger i = 0; i < argCount; i++)
    {
        argsC[i] = strdup([[argsM objectAtIndex:i] UTF8String]);
    }
    argsC[argCount] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);

    int outErr[2];
    if(stdErr)
    {
        pipe(outErr);
        posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&action, outErr[0]);
    }

    int out[2];
    if(stdOut)
    {
        pipe(out);
        posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&action, out[0]);
    }
    
    pid_t task_pid;
    int status = -200;
    int spawnError = posix_spawn(&task_pid, [path UTF8String], &action, &attr, (char* const*)argsC, NULL);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; i < argCount; i++)
    {
        free(argsC[i]);
    }
    free(argsC);
    
    if(spawnError != 0)
    {
        NSLog(@"We down");
        NSLog(@"posix_spawn error %d\n", spawnError);
        return spawnError;
    }

    do
    {
        pid_t waitpids = waitpid(task_pid, &status, 0);
        if (waitpids != -1) {
            NSLog(@"Child status %d", WEXITSTATUS(status));
        } else
        {
//            perror("waitpid");
//            NSLog(@"waitpid returned %@", waitpids);
            return -222;
        }
    } while (!WIFEXITED(status) && !WIFSIGNALED(status));

    if(stdOut)
    {
        close(out[1]);
        NSString* output = getNSStringFromFile(out[0]);
        *stdOut = output;
    }

    if(stdErr)
    {
        close(outErr[1]);
        NSString* errorOutput = getNSStringFromFile(outErr[0]);
        *stdErr = errorOutput;
    }
//    NSLog(@"%@", status);
    return WEXITSTATUS(status);
}



void enumerateProcessesUsingBlock(void (^enumerator)(pid_t pid, NSString* executablePath, BOOL* stop))
{
    static int maxArgumentSize = 0;
    if (maxArgumentSize == 0) {
        size_t size = sizeof(maxArgumentSize);
        if (sysctl((int[]){ CTL_KERN, KERN_ARGMAX }, 2, &maxArgumentSize, &size, NULL, 0) == -1) {
            perror("sysctl argument size");
            maxArgumentSize = 4096; // Default
        }
    }
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    struct kinfo_proc *info;
    size_t length;
    uint64_t count;
    
    if (sysctl(mib, 3, NULL, &length, NULL, 0) < 0)
        return;
    if (!(info = malloc(length)))
        return;
    if (sysctl(mib, 3, info, &length, NULL, 0) < 0) {
        free(info);
        return;
    }
    count = length / sizeof(struct kinfo_proc);
    for (int i = 0; i < count; i++) {
        @autoreleasepool {
        pid_t pid = info[i].kp_proc.p_pid;
        if (pid == 0) {
            continue;
        }
        size_t size = maxArgumentSize;
        char* buffer = (char *)malloc(length);
        if (sysctl((int[]){ CTL_KERN, KERN_PROCARGS2, pid }, 3, buffer, &size, NULL, 0) == 0) {
            NSString* executablePath = [NSString stringWithCString:(buffer+sizeof(int)) encoding:NSUTF8StringEncoding];
            
            BOOL stop = NO;
            enumerator(pid, executablePath, &stop);
            if(stop)
            {
                free(buffer);
                break;
            }
        }
        free(buffer);
        }
    }
    free(info);
}

void killall(NSString* processName, BOOL softly)
{
    enumerateProcessesUsingBlock(^(pid_t pid, NSString* executablePath, BOOL* stop)
    {
        if([executablePath.lastPathComponent isEqualToString:processName])
        {
            if(softly)
            {
                kill(pid, SIGTERM);
            }
            else
            {
                kill(pid, SIGKILL);
            }
        }
    });
}

void respring(void)
{
    killall(@"SpringBoard", YES);
    exit(0);
}

// ptrace(PT_TRACE_ME,0,0,0); spawn roothelper (spawn 2nd roothelper, getpid()) -> ptrace main app
int ptraceMe(void) {
    NSString *mainBundlePath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"trolltoolsroothelper"];
    NSLog(@"ptrace: helper is %@", mainBundlePath);
    NSLog(@"ptrace: pid is %d", getpid());
    NSString *stdOut;
    NSString *stdErr;
    ptrace(PT_TRACE_ME,0,0,0);
    int myPid = getpid();
    char pidString[100];
    sprintf(pidString, "%d", myPid);
    spawnRoot(mainBundlePath, @[@"ptrace", [NSString stringWithUTF8String: pidString], @""], nil, nil);
    ptrace(PT_ATTACH, getpid(), 0, 0);
    ptrace(PT_DETACH, getpid(), 0, 0);
    return 0;
}

//#import <Foundation/Foundation.h>

int opainject(pid_t pid, NSString* dylib) {
    NSString *mainBundlePath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"trolltoolsroothelper"];
//    NSString *dylibPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks"];
    NSString *dylibPath = @"/var/mobile/Documents/VendettaTweakSigned";
//    dylibPath = [dylibPath stringByAppendingPathComponent:dylib];
    char pidString[100];
    sprintf(pidString, "%d", pid);
    spawnRoot(mainBundlePath, @[@"opainject", [NSString stringWithUTF8String: pidString], dylibPath], nil, nil);
    return 0;
}

