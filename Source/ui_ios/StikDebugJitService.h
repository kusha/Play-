#import <UIKit/UIKit.h>

@interface StikDebugJitService : NSObject

+ (StikDebugJitService*)sharedStikDebugJitService;
- (void)registerPreferences;
- (void)startProcess;

@property bool processStarted;
@property bool jitEnabled;

@end
