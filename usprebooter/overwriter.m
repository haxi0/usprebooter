@import Darwin;
@import Foundation;
@import MachO;

#import <mach-o/fixup-chains.h>
#import "vm_unaligned_copy_switch_race.h"
#import "overwriter.h"
#import "troller.h"
#import "fun/thanks_opa334dev_htrowii.h"
#include "util.h"

static bool overwrite_file_mdc(int fd, NSData* sourceData) {
  for (int off = 0; off < sourceData.length; off += 0x4000) {
    bool success = false;
    for (int i = 0; i < 2; i++) {
      if (unaligned_copy_switch_race(
              fd, off, sourceData.bytes + off,
              off + 0x4000 > sourceData.length ? sourceData.length - off : 0x4000, true)) {
        success = true;
        break;
      }
    }
    if (!success) {
        NSLog(@"MDC overwrite failed");
      return false;
    }
  }
  return true;
}

char* getPatchedLaunchdCopy(void) {
    char* prebootpath = return_boot_manifest_hash_main();
    static char originallaunchd[256];
    sprintf(originallaunchd, "%s/%s", prebootpath, "patchedlaunchd");
//    NSString *fakelaunchdPath = [NSString stringWithUTF8String:originallaunchd];
    NSLog(@"patchedlaunchd: %s", originallaunchd);
    return originallaunchd;
}

char* getOriginalLaunchdCopy(void) {
    char* prebootpath = return_boot_manifest_hash_main();
    static char originallaunchd[256];
    sprintf(originallaunchd, "%s/%s", prebootpath, "originallaunchd");
//    NSString *fakelaunchdPath = [NSString stringWithUTF8String:originallaunchd];
    NSLog(@"originallaunchd: %s", originallaunchd);
    return originallaunchd;
}

bool overwrite_patchedlaunchd_kfd(void) {
    char* patchedlaunchd = getPatchedLaunchdCopy();
    char* originallaunchdcopy = getOriginalLaunchdCopy();
    NSLog(@"usprebooter: KFD writing");
    funVnodeOverwrite2(patchedlaunchd, originallaunchdcopy);
    funVnodeOverwrite2(patchedlaunchd, "/sbin/launchd");
    return true;
}

bool overwrite_patchedlaunchd_mdc(void) {
    NSLog(@"usprebooter: MDC writing");
    char* patchedlaunchd = getPatchedLaunchdCopy();
    int to_file_index = open(patchedlaunchd, O_RDONLY);
    if (to_file_index == -1) {
        NSLog(@"patched launchd filepath doesn't exist!\n");
        return -1;
    }
    off_t to_file_size = lseek(to_file_index, 0, SEEK_END);

    char* originallaunchdcopy = getOriginalLaunchdCopy();
    int from_file_index = open(originallaunchdcopy, O_RDONLY);
    if (from_file_index == -1) {
        NSLog(@"original launchd filepath doesn't exist!\n");
        return -1;
    }
    off_t from_file_size = lseek(from_file_index, 0, SEEK_END);
    
    
    if(to_file_size < from_file_size) {
        close(from_file_index);
        close(to_file_index);
        NSLog(@"[-] File is too big to overwrite!\n");
        return -1;
    }
    
    NSLog(@"mmap as readonly\n");
    char* to_file_data = mmap(NULL, to_file_size, PROT_READ, MAP_PRIVATE, to_file_index, 0);
    if (to_file_data == MAP_FAILED) {
        NSLog(@"can't overwrite");
        close(to_file_index);
        return 0;
    }
    
    NSLog(@"mmap as readonly\n");
    char* from_file_data = mmap(NULL, from_file_size, PROT_READ, MAP_PRIVATE, from_file_index, 0);
    if (from_file_data == MAP_FAILED) {
        NSLog(@"can't overwrite");
        close(from_file_index);
        return 0;
    }
//    if (!sourceData) {
//        NSLog(@"can't patchfind");
//        return false;
//    }
//    usleep(100);
    NSData* to_file_data2 = [NSData dataWithBytes:to_file_data length:to_file_size];
    NSData* from_file_data2 = [NSData dataWithBytes:from_file_data length:from_file_size];
    if (!overwrite_file_mdc(to_file_index, from_file_data2)) {
        overwrite_file_mdc(to_file_index, to_file_data2);
        munmap(to_file_data, to_file_size);
        NSLog(@"can't overwrite");
        return false;
    }
    munmap(to_file_data, to_file_size);
    return true;
}

void ptraceTest(void) {
    NSLog(@"usprebooter: ppid before: %d", getppid());
    ptraceMe();
    NSLog(@"usprebooter: ppid after: %d", getppid());
}
bool overwrite_patchedlaunchdstage2_mdc(void) {
    NSLog(@"usprebooter: MDC writing patched launchd shim to /sbin/launchd");
    if (ptraceMe() /*0*/ == 0) {
        int to_file_index = open("/sbin/launchd", O_RDONLY | O_CLOEXEC);
        if (to_file_index == -1) {
            NSLog(@"/sbin/launchd filepath doesn't exist!\n");
            return -1;
        }
        off_t to_file_size = lseek(to_file_index, 0, SEEK_END);
        
        char* patchedlaunchdshim = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"shim"] UTF8String];
        int from_file_index = open(patchedlaunchdshim, O_RDONLY | O_CLOEXEC);
        if (from_file_index == -1) {
            NSLog(@"original launchd filepath doesn't exist!\n");
            return -1;
        }
        off_t from_file_size = lseek(from_file_index, 0, SEEK_END);
        
        if(to_file_size < from_file_size) {
            close(from_file_index);
            close(to_file_index);
            NSLog(@"[-] File is too big to overwrite!\n");
            return -1;
        }
        
        //mmap as read only
        NSLog(@"mmap as readonly file 1\n");
        char* to_file_data = mmap(nil, to_file_size, PROT_READ, MAP_SHARED, to_file_index, 0);
        if (to_file_data == MAP_FAILED) {
            NSLog(@"can't overwrite");
            close(to_file_index);
            return 0;
        }
        
        NSLog(@"mmap as readonly file 2\n");
        char* from_file_data = mmap(nil, from_file_size, PROT_READ, MAP_SHARED, from_file_index, 0);
        if (from_file_data == MAP_FAILED) {
            NSLog(@"can't overwrite");
            close(from_file_index);
            return 0;
        }
        
        NSData* to_file_data2 = [NSData dataWithBytes:to_file_data length:to_file_size];
        NSData* from_file_data2 = [NSData dataWithBytes:from_file_data length:from_file_size];
        if (!overwrite_file_mdc(to_file_index, from_file_data2)) {
            overwrite_file_mdc(to_file_index, to_file_data2);
            munmap(to_file_data, to_file_size);
            NSLog(@"can't overwrite");
            return false;
        }
        
        munmap(to_file_data, to_file_size);
        return true;
    } else {
        NSLog(@"ptrace failed");
        return false;
    }
}
