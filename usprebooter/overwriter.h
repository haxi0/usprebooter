//
//  overwriter.h
//  usprebooter
//
//  Created by LL on 1/12/23.
//

#ifndef overwriter_h
#define overwriter_h
bool overwrite_patchedlaunchd_mdc(void);
bool overwrite_patchedlaunchdstage2_mdc(void);
bool overwrite_patchedlaunchd_kfd(void);
char* getPatchedLaunchdCopy(void);
void ptraceTest(void);
#endif /* overwriter_h */
