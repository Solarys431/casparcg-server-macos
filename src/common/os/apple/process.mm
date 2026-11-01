#include "process.h"

#import <Foundation/Foundation.h>

namespace caspar {

bool disable_process_power_throttling()
{
    // Held until the process exits. NSActivityUserInitiated also keeps the system from idle sleep;
    // NSActivityLatencyCritical asks for the timer precision that frame pacing needs.
    static id activity = nil;
    if (activity != nil)
        return true;

    @autoreleasepool {
        activity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                              reason:@"CasparCG Server is playing out"];
        [activity retain];
    }
    return activity != nil;
}

} // namespace caspar
