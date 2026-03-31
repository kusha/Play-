#import <SDWebImage/UIImageView+WebCache.h>
#import "CoverViewController.h"
#import "EmulatorViewController.h"
#import "SettingsViewController.h"
#import "../ui_shared/BootablesProcesses.h"
#import "../ui_shared/BootablesDbClient.h"
#import "PathUtils.h"
#import "BackgroundLayer.h"
#import "CoverViewCell.h"
#import "AltServerJitService.h"
#import "StikDebugJitService.h"
#include <sys/mman.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#include <unistd.h>

static bool TestJitWithMmap()
{
	// iOS 26 TXM JIT test: dual-mapping with StikDebug-mediated region preparation
	long page_size = sysconf(_SC_PAGESIZE);
	
	// Step 1: Allocate RW pages
	void* rwPage = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	if(rwPage == MAP_FAILED) return false;
	
	// Step 2: vm_remap for RX alias
	vm_address_t rxPage = 0;
	vm_prot_t cur_prot, max_prot;
	kern_return_t kr = vm_remap(mach_task_self(), &rxPage, page_size, 0,
								VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR,
								mach_task_self(), (mach_vm_address_t)rwPage,
								false, &cur_prot, &max_prot, VM_INHERIT_NONE);
	if(kr != KERN_SUCCESS) { munmap(rwPage, page_size); return false; }
	
	// Step 3: Ask StikDebug to prepare region (brk #0xf00d, x16=1)
	__asm__ volatile(
		"mov x0, %0\n"
		"mov x1, %1\n"
		"mov x16, #1\n"
		"brk #0xf00d\n"
		:: "r"(rxPage), "r"((uint64_t)page_size)
		: "x0", "x1", "x16"
	);
	
	// Step 4: Write a simple "ret" instruction through RW mapping
	uint32_t retInstr = 0xD65F03C0; // ARM64 ret
	memcpy(rwPage, &retInstr, sizeof(retInstr));
	sys_icache_invalidate((void*)rxPage, page_size);
	
	// Step 5: Try executing from RX mapping
	typedef void (*TestFunc)(void);
	TestFunc func = (TestFunc)rxPage;
	func();
	
	// Cleanup
	vm_deallocate(mach_task_self(), rxPage, page_size);
	munmap(rwPage, page_size);
	return true;
}

static bool IsJitAvailable()
{
	//Definitive test: can we actually allocate JIT memory?
	if(TestJitWithMmap()) return true;
	//If ppid != 1, it means we're being run in the debugger
	if(getppid() != 1) return true;
	if([[AltServerJitService sharedAltServerJitService] jitEnabled])
	{
		return true;
	}
	if([[StikDebugJitService sharedStikDebugJitService] jitEnabled])
	{
		return true;
	}
	{
		//Check if we can scan the mobile directory (only possible if jailbroken)
		std::error_code errorCode;
		fs::directory_iterator dirIterator("/private/var/mobile", errorCode);
		if(!errorCode)
		{
			return true;
		}
	}
	return false;
}

@interface CoverViewController ()

@end

@implementation CoverViewController

static NSString* const reuseIdentifier = @"coverCell";

- (void)buildCollectionWithForcedFullScan:(BOOL)forceFullDeviceScan
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Building collection" message:@"Please wait..." preferredStyle:UIAlertControllerStyleAlert];

	CGRect aivRect = CGRectMake(0, 0, 40, 40);

	UIActivityIndicatorView* aiv = [[UIActivityIndicatorView alloc] initWithFrame:aivRect];
	[aiv startAnimating];

	UIViewController* vc = [[UIViewController alloc] init];
	vc.preferredContentSize = aivRect.size;
	[vc.view addSubview:aiv];
	[alert setValue:vc forKey:@"contentViewController"];

	[self presentViewController:alert animated:YES completion:nil];

	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_async(queue, ^{
	  auto activeDirs = GetActiveBootableDirectories();
	  if(forceFullDeviceScan)
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games on filesystem...";
		  });
		  ScanBootables("/private/var/mobile");
	  }
	  else if(!activeDirs.empty())
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games in active directories...";
		  });
		  for(const auto& activeDir : activeDirs)
		  {
			  ScanBootables(activeDir, false);
		  }
	  }

	  //Always scan games in app storage. The app's path change when it's reinstalled,
	  //thus, games from the previous installation won't be found (will be deleted in PurgeInexistingFiles).
	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Scanning games in app storage...";
	  });
	  ScanBootables(Framework::PathUtils::GetPersonalDataPath());

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Purging inexisting files...";
	  });
	  PurgeInexistingFiles();

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Fetching game titles...";
	  });
	  FetchGameTitles();

	  if(_bootables)
	  {
		  delete _bootables;
		  _bootables = nullptr;
	  }
	  _bootables = new BootableArray(BootablesDb::CClient::GetInstance().GetBootables());

	  //Done
	  dispatch_async(dispatch_get_main_queue(), ^{
		[alert dismissViewControllerAnimated:YES completion:nil];
		[self.collectionView reloadData];
	  });
	});
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	CAGradientLayer* bgLayer = [BackgroundLayer blueGradient];
	bgLayer.frame = self.view.bounds;
	[self.view.layer insertSublayer:bgLayer atIndex:0];

	self.collectionView.allowsMultipleSelection = NO;
	if(@available(iOS 11.0, *))
	{
		self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
	}

	[[AltServerJitService sharedAltServerJitService] startProcess];
	[[StikDebugJitService sharedStikDebugJitService] startProcess];
	[self buildCollectionWithForcedFullScan:NO];
}

- (void)viewDidUnload
{
	assert(_bootables != nullptr);
	delete _bootables;

	[super viewDidUnload];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
	// resize your layers based on the view’s new bounds
	[[[self.view.layer sublayers] objectAtIndex:0] setFrame:self.view.bounds];
}

- (BOOL)shouldAutorotate
{
	if([self isViewLoaded] && self.view.window)
	{
		return YES;
	}
	else
	{
		return NO;
	}
}

#pragma mark <UICollectionViewDataSource>

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)collectionView
{
	return 1;
}

- (NSString*)collectionView:(UICollectionView*)collectionView titleForHeaderInSection:(NSInteger)section
{
	return @"";
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section
{
	return _bootables ? _bootables->size() : 0;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView cellForItemAtIndexPath:(NSIndexPath*)indexPath
{
	CoverViewCell* cell = (CoverViewCell*)[collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier forIndexPath:indexPath];

	auto bootable = (*_bootables)[indexPath.row];
	UIImage* placeholder = [UIImage imageNamed:@"boxart.png"];
	cell.nameLabel.text = [NSString stringWithUTF8String:bootable.title.c_str()];
	cell.backgroundView = [[UIImageView alloc] initWithImage:placeholder];

	if(!bootable.coverUrl.empty())
	{
		NSString* coverUrl = [NSString stringWithUTF8String:bootable.coverUrl.c_str()];
		[(UIImageView*)cell.backgroundView sd_setImageWithURL:[NSURL URLWithString:coverUrl] placeholderImage:placeholder];
	}

	return cell;
}

#pragma mark <UICollectionViewDelegate>

- (BOOL)shouldPerformSegueWithIdentifier:(NSString*)identifier sender:(id)sender
{
	if([identifier isEqualToString:@"showEmulator"] && !IsJitAvailable())
	{
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"JIT unavailable" message:@"JIT doesn't seem to be available at the moment. If JIT is not available, the emulator will crash. Do you wish to continue?" preferredStyle:UIAlertControllerStyleAlert];
		{
			UIAlertAction* continueAction = [UIAlertAction
			    actionWithTitle:@"Continue"
			              style:UIAlertActionStyleDefault
			            handler:^(UIAlertAction*) {
				          [self performSegueWithIdentifier:@"showEmulator" sender:sender];
			            }];
			[alert addAction:continueAction];
		}
		{
			UIAlertAction* cancelAction = [UIAlertAction
			    actionWithTitle:@"Cancel"
			              style:UIAlertActionStyleCancel
			            handler:^(UIAlertAction*){}];
			[alert addAction:cancelAction];
		}
		{
			UIAlertAction* helpAction = [UIAlertAction
			    actionWithTitle:@"Help"
			              style:UIAlertActionStyleDefault
			            handler:^(UIAlertAction*) {
				          [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/jpd002/Play-#running-on-ios"]];
			            }];
			[alert addAction:helpAction];
		}
		[self presentViewController:alert animated:YES completion:nil];
		return NO;
	}
	return YES;
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender
{
	if([segue.identifier isEqualToString:@"showEmulator"])
	{
		NSIndexPath* indexPath = [[self.collectionView indexPathsForSelectedItems] objectAtIndex:0];
		auto bootable = (*_bootables)[indexPath.row];
		BootablesDb::CClient::GetInstance().SetLastBootedTime(bootable.path, time(nullptr));
		EmulatorViewController* emulatorViewController = segue.destinationViewController;
		emulatorViewController.bootablePath = [NSString stringWithUTF8String:bootable.path.native().c_str()];
		[self.collectionView deselectItemAtIndexPath:indexPath animated:NO];
	}
	else if([segue.identifier isEqualToString:@"showSettings"])
	{
		UINavigationController* navViewController = segue.destinationViewController;
		SettingsViewController* settingsViewController = (SettingsViewController*)navViewController.visibleViewController;
		settingsViewController.allowFullDeviceScan = true;
		settingsViewController.allowGsHandlerSelection = true;
		settingsViewController.completionHandler = ^(bool fullScanRequested) {
		  [[AltServerJitService sharedAltServerJitService] startProcess];
		  [[StikDebugJitService sharedStikDebugJitService] startProcess];
		  if(fullScanRequested)
		  {
			  [self buildCollectionWithForcedFullScan:YES];
		  }
		};
	}
}

- (IBAction)onExit:(id)sender
{
	exit(0);
}

@end
