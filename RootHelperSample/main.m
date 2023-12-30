#import <stdio.h>
@import Foundation;
#import "uicache.h"
#import <sys/stat.h>
#import <dlfcn.h>
#import <spawn.h>
#import <objc/runtime.h>
#import "TSUtil.h"
#import <sys/utsname.h>
#import <SpringBoardServices/SpringBoardServices.h>
#import <Security/Security.h>

#import "codesign.h"
#import "coretrust_bug.h"
#import <choma/FAT.h>
#import <choma/MachO.h>
#import <choma/FileStream.h>
#import <choma/Host.h>

#include <sys/types.h>
/* Attach to a process that is already running. */
//PTRACE_ATTACH = 16,
#define PT_ATTACH 16

/* Detach from a process attached to with PTRACE_ATTACH.  */
//PTRACE_DETACH = 17,
#define PT_DETACH 17
#define PT_ATTACHEXC    14    /* attach to running process with signal exception */
#define PT_TRACE_ME 0
int ptrace(int, pid_t, caddr_t, int);


NSString* usprebooterPath()
{
    NSError* mcmError;
    MCMAppContainer* appContainer = [MCMAppContainer containerWithIdentifier:@"pisshill.usprebooter" createIfNecessary:NO existed:NULL error:&mcmError];
    if(!appContainer) return nil;
    return appContainer.url.path;
}

NSString* usprebooterappPath()
{
    return [usprebooterPath() stringByAppendingPathComponent:@"usprebooter.app"];
}

//BOOL isLdidInstalled(void)
//{
//    NSString* ldidPath = [trollStoreAppPath() stringByAppendingPathComponent:@"ldid"];
//    return [[NSFileManager defaultManager] fileExistsAtPath:ldidPath];
//}

int runLdid(NSArray* args, NSString** output, NSString** errorOutput)
{
    NSString* ldidPath = [usprebooterappPath() stringByAppendingPathComponent:@"ldid"];
    NSMutableArray* argsM = args.mutableCopy ?: [NSMutableArray new];
    [argsM insertObject:ldidPath.lastPathComponent atIndex:0];

    NSUInteger argCount = [argsM count];
    char **argsC = (char **)malloc((argCount + 1) * sizeof(char*));

    for (NSUInteger i = 0; i < argCount; i++)
    {
        argsC[i] = strdup([[argsM objectAtIndex:i] UTF8String]);
    }
    argsC[argCount] = NULL;

    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);

    int outErr[2];
    pipe(outErr);
    posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&action, outErr[0]);

    int out[2];
    pipe(out);
    posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&action, out[0]);
    
    pid_t task_pid;
    int status = -200;
    int spawnError = posix_spawn(&task_pid, [ldidPath fileSystemRepresentation], &action, NULL, (char* const*)argsC, NULL);
    for (NSUInteger i = 0; i < argCount; i++)
    {
        free(argsC[i]);
    }
    free(argsC);

    if(spawnError != 0)
    {
        NSLog(@"posix_spawn error %d\n", spawnError);
        return spawnError;
    }

    do
    {
        if (waitpid(task_pid, &status, 0) != -1) {
            //printf("Child status %dn", WEXITSTATUS(status));
        } else
        {
            perror("waitpid");
            return -222;
        }
    } while (!WIFEXITED(status) && !WIFSIGNALED(status));

    close(outErr[1]);
    close(out[1]);

    NSString* ldidOutput = getNSStringFromFile(out[0]);
    if(output)
    {
        *output = ldidOutput;
    }

    NSString* ldidErrorOutput = getNSStringFromFile(outErr[0]);
    if(errorOutput)
    {
        *errorOutput = ldidErrorOutput;
    }

    return WEXITSTATUS(status);
}

int signAdhoc(NSString *filePath, NSDictionary *entitlements) // lets just assume ldid is included ok
{
//        if(!isLdidInstalled()) return 173;

        NSString *entitlementsPath = nil;
        NSString *signArg = @"-s";
        NSString* errorOutput;
        if(entitlements)
        {
            NSData *entitlementsXML = [NSPropertyListSerialization dataWithPropertyList:entitlements format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
            if (entitlementsXML) {
                entitlementsPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] stringByAppendingPathExtension:@"plist"];
                [entitlementsXML writeToFile:entitlementsPath atomically:NO];
                signArg = [@"-S" stringByAppendingString:entitlementsPath];
                signArg = [@"-M" stringByAppendingString:@"/sbin/launchd"];
            }
            
        }
        NSLog(@"roothelper: running ldid");
        int ldidRet = runLdid(@[signArg, filePath], nil, &errorOutput);
        if (entitlementsPath) {
            [[NSFileManager defaultManager] removeItemAtPath:entitlementsPath error:nil];
        }

        NSLog(@"roothelper: ldid exited with status %d", ldidRet);

        NSLog(@"roothelper: - ldid error output start -");

        printMultilineNSString(errorOutput);

        NSLog(@"roothelper: - ldid error output end -");

        if(ldidRet == 0)
        {
            return 0;
        }
        else
        {
            return 175;
        }
    //}
}

NSSet<NSString*>* immutableAppBundleIdentifiers(void)
{
	NSMutableSet* systemAppIdentifiers = [NSMutableSet new];

	LSEnumerator* enumerator = [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
	LSApplicationProxy* appProxy;
	while(appProxy = [enumerator nextObject])
	{
		if(appProxy.installed)
		{
			if(![appProxy.bundleURL.path hasPrefix:@"/private/var/containers"])
			{
				[systemAppIdentifiers addObject:appProxy.bundleIdentifier.lowercaseString];
			}
		}
	}

	return systemAppIdentifiers.copy;
}

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
//        NSLog(@"Hello from the other side! our uid is %u and our pid is %d", getuid(), getpid());
        loadMCMFramework();
        NSString* action = [NSString stringWithUTF8String:argv[1]];
        NSString* source = [NSString stringWithUTF8String:argv[2]];
        NSString* destination = [NSString stringWithUTF8String:argv[3]];
        
        if ([action isEqual: @"writedata"]) {
            [source writeToFile:destination atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else if ([action isEqual: @"filemove"]) {
            [[NSFileManager defaultManager] moveItemAtPath:source toPath:destination error:nil];
        } else if ([action isEqual: @"filecopy"]) {
            NSLog(@"roothelper: cp");
            [[NSFileManager defaultManager] copyItemAtPath:source toPath:destination error:nil];
        } else if ([action isEqual: @"makedirectory"]) {
            NSLog(@"roothelper: mkdir");
            [[NSFileManager defaultManager] createDirectoryAtPath:source withIntermediateDirectories:true attributes:nil error:nil];
        } else if ([action isEqual: @"removeitem"]) {
            NSLog(@"roothelper: rm");
            [[NSFileManager defaultManager] removeItemAtPath:source error:nil];
        } else if ([action isEqual: @"permissionset"]) {
            NSLog(@"roothelper chmod %@", source); // just pass in 755
            NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
            [dict setObject:[NSNumber numberWithInt:755]  forKey:NSFilePosixPermissions];
            [[NSFileManager defaultManager] setAttributes:dict ofItemAtPath:source error:nil];
            //        } else if ([action isEqual: @"rebuildiconcache"]) {
            //            cleanRestrictions();
            //            [[LSApplicationWorkspace defaultWorkspace] _LSPrivateRebuildApplicationDatabasesForSystemApps:YES internal:YES user:YES];
            //            refreshAppRegistrations();
            //            killall(@"backboardd");
        } else if ([action isEqual: @"codesignlaunchd"]) {
            NSLog(@"roothelper: adhoc sign + fastsign");
            NSDictionary* entitlements = @{
                @"get-task-allow": [NSNumber numberWithBool:YES],
                @"platform-application": [NSNumber numberWithBool:YES],
            };
            NSString* patchedLaunchdCopy = [NSString stringWithUTF8String: getPatchedLaunchdCopy()];
            signAdhoc(patchedLaunchdCopy, entitlements); // source file, NSDictionary with entitlements
            NSString *fastPathSignPath = [usprebooterappPath() stringByAppendingPathComponent:@"fastPathSign"];
            NSString *stdOut;
            NSString *stdErr;
            spawnRoot(fastPathSignPath, @[@"-i", patchedLaunchdCopy, @"-r", @"-o", patchedLaunchdCopy], &stdOut, &stdErr);
        } else if ([action isEqual: @"codesignapp"]) { // source overwrites destination
            NSLog(@"roothelper: adhoc sign + fastsign app!!!");
            NSDictionary* entitlements = @{
                @"get-task-allow": [NSNumber numberWithBool:YES],
                @"platform-application": [NSNumber numberWithBool:YES],
            };
            NSString* appPath = source;
            signAdhoc(appPath, entitlements); // source file, NSDictionary with entitlements
            NSString *fastPathSignPath = [usprebooterappPath() stringByAppendingPathComponent:@"fastPathSign"];
            NSString *stdOut;
            NSString *stdErr;
            spawnRoot(fastPathSignPath, @[@"-i", appPath, @"-r", @"-o", appPath], &stdOut, &stdErr);
        } else if ([action isEqual: @"ptrace"]) {
            NSLog(@"roothelper: stage 1 ptrace");
            NSLog(@"roothelper: ppid is %d", getppid());
            NSString *stdOut;
            NSString *stdErr;
            NSLog(@"trolltoolshelper path %@", rootHelperPath());
            spawnRoot(rootHelperPath(), @[@"ptrace2", source, @""], &stdOut, &stdErr);
            kill(getpid(), 1);
        } else if ([action isEqual: @"ptrace2"]) {
            NSLog(@"roothelper: stage 2 ptrace, app pid: %@", source);
            NSLog(@"roothelper: ppid is %d", getppid());
            int pidInt = [source intValue];
////             source = pid of app.
////             ptrace the source, the pid of the original app
////             then detach immediately
////            ptrace(PT_TRACE_ME,0,0,0);
            ptrace(PT_ATTACH, pidInt, 0, 0);
            ptrace(PT_DETACH, pidInt, 0, 0);
        } else if ([action isEqual: @"opainject"]) {
            NSLog(@"roothelper: opainject"); // source -> pid of app, destination -> location to dylib
            NSString* dylibPath = [usprebooterappPath() stringByAppendingPathComponent:destination];
            int pidInt = [source intValue];
            NSString *stdOut;
            NSString *stdErr;
            spawnRoot([usprebooterappPath() stringByAppendingPathComponent:@"opainject_arm64_signed"], @[@(pidInt), dylibPath], &stdOut, &stdErr);
        }
        return 0;
    }
}
