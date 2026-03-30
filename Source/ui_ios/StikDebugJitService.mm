#import "StikDebugJitService.h"
#include "AppConfig.h"
#import "PreferenceDefs.h"
#include <unistd.h>

@implementation StikDebugJitService

- (id)init
{
	if(self = [super init])
	{
		[self registerPreferences];
	}
	return self;
}

+ (StikDebugJitService*)sharedStikDebugJitService
{
	static StikDebugJitService* sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  sharedInstance = [[self alloc] init];
	});
	return sharedInstance;
}

- (void)registerPreferences
{
	CAppConfig::GetInstance().RegisterPreferenceBoolean(PREFERENCE_STIKDEBUG_JIT_ENABLED, false);
}

- (BOOL)isRunningInLiveContainer
{
	return (getenv("LC_HOME_PATH") != NULL);
}

- (void)startProcess
{
	//Don't start the process if it's not enabled
	if(!CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_STIKDEBUG_JIT_ENABLED))
	{
		return;
	}

	//Don't start the process if we've already started it
	if(self.processStarted)
	{
		return;
	}

	self.processStarted = YES;

	//Check if StikDebug is installed
	NSURL* stikDebugURL = [NSURL URLWithString:@"stikjit://"];
	if(![[UIApplication sharedApplication] canOpenURL:stikDebugURL])
	{
		NSLog(@"StikDebug is not installed.");
		return;
	}

	//Build the JIT enable URL
	//When running inside LiveContainer, we need to target LiveContainer's process,
	//not Play!'s bundle. LiveContainer hosts Play! as a dylib in its own process space.
	//StikDebug supports a "pid" parameter which is the most reliable approach.
	NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier];
	pid_t currentPid = getpid();
	NSString* urlString;

	if([self isRunningInLiveContainer])
	{
		//Inside LiveContainer: mainBundle.bundleIdentifier already returns LiveContainer's
		//bundle ID (LiveContainer swaps it). Send both bundle-id and pid for maximum
		//compatibility. PID-based approach is most reliable on iOS 17.4+.
		urlString = [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d", bundleId, currentPid];
		NSLog(@"StikDebug: Running inside LiveContainer. Requesting JIT with bundle-id=%@, pid=%d", bundleId, currentPid);
	}
	else
	{
		//Normal standalone: use bundle-id as before
		urlString = [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@", bundleId];
		NSLog(@"StikDebug: Running standalone. Requesting JIT with bundle-id=%@", bundleId);
	}

	NSURL* enableJitURL = [NSURL URLWithString:urlString];

	[[UIApplication sharedApplication] openURL:enableJitURL
	                                   options:@{}
	                         completionHandler:^(BOOL success) {
	  if(success)
	  {
		  NSLog(@"StikDebug: Successfully opened StikDebug to enable JIT.");
		  self.jitEnabled = YES;
	  }
	  else
	  {
		  NSLog(@"StikDebug: Failed to open StikDebug URL: %@", urlString);
	  }
	}];
}

@end
