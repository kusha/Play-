#import "StikDebugJitService.h"
#include "AppConfig.h"
#import "PreferenceDefs.h"

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

	//Build the JIT enable URL with our bundle ID
	NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier];
	NSString* urlString = [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@", bundleId];
	NSURL* enableJitURL = [NSURL URLWithString:urlString];

	[[UIApplication sharedApplication] openURL:enableJitURL
	                                   options:@{}
	                         completionHandler:^(BOOL success) {
	  if(success)
	  {
		  NSLog(@"Successfully opened StikDebug to enable JIT.");
		  self.jitEnabled = YES;
	  }
	  else
	  {
		  NSLog(@"Failed to open StikDebug URL.");
	  }
	}];
}

@end
