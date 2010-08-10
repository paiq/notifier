/*
 * Paiq notifier framework - http://opensource.implicit-link.com/
 * Copyright (c) 2010 Implicit Link
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#import <Cocoa/Cocoa.h>
#import <GrowlApplicationBridge.h>

#define USERAGENT SITENAME " Notifier 0.9.9 (Mac)"
	// Used by server to determine whether we should update 

#ifdef DEBUG 
	#define UPDATEURL "http://" UPDATEHOST "/d/WebNoti_dbg.app.tbz2"
#else
	#define UPDATEURL "http://" UPDATEHOST "/d/WebNoti.app.tbz2"
#endif

// objc<->c++ go-along glue {{{
	
// Hack around some objc definitions and reserved keywords. Damn, this is ugly.
#undef check
#define id cpp_id 
#define Protocol cpp_Protocol
	// Some vars in our (boost) includes are called 'id' or 'Protocol'; objc doesn't like this

#include <boost/asio.hpp>
#include <sys/stat.h>

#include "Notifier.h"
#undef id
#undef Protocol

// std::string <-> NSString
@interface NSString(ObjCPlusPlus)
- (std::string) stdString;
- (NSString *) initWithStdString: (std::string)str;
+ (NSString *) stringWithStdString: (std::string)str;
@end

@implementation NSString(ObjCPlusPlus)
- (std::string) stdString { return std::string([self UTF8String]); }
- (NSString *) initWithStdString:(std::string)str { return [self initWithUTF8String:str.c_str()]; }
+ (NSString *) stringWithStdString:(std::string)str { return [NSString stringWithUTF8String:str.c_str()]; }
@end
// }}}

// UI constants {{{
#define ICON_APP	@"app.icns"		// $RESOURCE$ "res/$SITE.icns"

#define ICON_NORMAL	@"normal.ico"	// $RESOURCE$ "res/mac-normal.$SITE.ico"
#define ICON_ALT	@"alt.ico"		// $RESOURCE$ "res/mac-alt.$SITE.ico"
#define ICON_GRAY	@"gray.ico"		// $RESOURCE$ "res/mac-gray.$SITE.ico"
#define ICON_MSG	@"msg.ico"		// $RESOURCE$ "res/mac-msg.$SITE.ico"
#define ICON_USERS	@"users.ico"	// $RESOURCE$ "res/mac-users.$SITE.ico"
//}}}

boost::asio::io_service notiRunloop;

class MacNotifier : public Notifier
{
	bool popups;
	
	NSMutableArray *tooltipArray;
	
	void updateMenu()
	{
		NSNumber *nsStatus = [[NSNumber alloc] initWithInt: status];
		NSNumber *nsPopups = [[NSNumber alloc] initWithBool: popups];
		
		NSDictionary *opts = [[NSDictionary alloc] initWithObjectsAndKeys:
				tooltipArray, @"tooltip",
				nsPopups, @"popups",
				nsStatus, @"status", nil];

		[nsPopups release];
		[nsStatus release];
		
		[[NSApp delegate] performSelectorOnMainThread: @selector(setMenu:)
		                                   withObject: opts
		                                waitUntilDone: NO];
		
		[opts release];
	}
	
	void setIcon(NSString *icon)
	{
		[[NSApp delegate] performSelectorOnMainThread: @selector(setIcon:)
		                                   withObject: icon
		                                waitUntilDone: NO];
	}
	
	NSString *blinkIcon;
	bool blinking;
	std::auto_ptr<boost::asio::deadline_timer> blinkTimer;
	void onBlinkTimer(const boost::system::error_code& err) {
		if (err == boost::asio::error::operation_aborted)
			return;

		setIcon(blinking ? blinkIcon : ICON_NORMAL);
		
		blinking = !blinking;
		
		blinkTimer.reset(new boost::asio::deadline_timer(ioService));
		blinkTimer->expires_from_now(boost::posix_time::seconds(1));
		blinkTimer->async_wait(boost::bind(&MacNotifier::onBlinkTimer, this, boost::asio::placeholders::error));
	}
	
	NSDate *initTime;
	void initialize() {
		initTime = [[NSDate alloc] init];
		popups = (getConfigValue("popups") == "true");
		updateMenu();
	}
	
public:
	MacNotifier(boost::asio::io_service& ioService_) :
			Notifier(ioService_), popups(false), tooltipArray(0), blinkIcon(0),
			blinking(false), blinkTimer(), initTime(0) {
				
		ioService.post(boost::bind(&MacNotifier::initialize, this));
	}

	~MacNotifier()
	{
		[initTime release];
		[blinkIcon release];
		[tooltipArray release];
	}
	
	void togglePopups()
	{
		popups = !popups;
		updateMenu();
		setConfigValue("popups", popups ? "true" : "false");
	}
	
	void setMotdSong(std::string& motd)
	{
		if (status != s_enabled) return;
		(IlmpCommand(ilmp.get(), "User.setMotdSong") << motd).send();
	}
	
	virtual void notify(const std::string& title, const std::string& text, const std::string& url, bool sticky)
	{
		if (!sticky && (!popups || (initTime && [initTime timeIntervalSinceNow] > -5))) return;
			// Do not popup non-sticky messages if popups are disabled or the first seconds after launch.
		
		NSString *nsTitle = [[NSString alloc] initWithStdString: title];
		NSString *nsText = [[NSString alloc] initWithStdString: text];
		NSString *nsUrl = [[NSString alloc] initWithStdString: url];
		NSNumber *nsSticky = [[NSNumber alloc] initWithBool: sticky];
		
		NSDictionary *opts = [[NSDictionary alloc] initWithObjectsAndKeys:
				nsTitle, @"title",
				nsText, @"text",
				nsUrl, @"url", 
				nsSticky, @"sticky", nil];
		
		[nsTitle release];
		[nsText release];
		[nsUrl release];
		[nsSticky release];
		
		[[NSApp delegate] performSelectorOnMainThread: @selector(notify:)
		                                   withObject: opts
		                                waitUntilDone: NO];
		
		[opts release];
	}
	
	virtual void statusChanged()
	{
		NSString *newBlinkIcon = 0;

		if (unreadMsgs) newBlinkIcon = ICON_MSG;
		else if (users.size()) setIcon(ICON_USERS);
		else if (status == s_enabled) setIcon(ICON_NORMAL);
		else setIcon(ICON_GRAY);
		
		if (newBlinkIcon) {
			[blinkIcon release];
			blinkIcon = newBlinkIcon;
			blinking = false;
			onBlinkTimer(boost::system::error_code()); // Will replace the old timer
		}
		else if (!newBlinkIcon)
			blinkTimer.reset();
		
		updateMenu();
	}
	
	virtual void openUrl(const std::string& url)
	{
		NSString *url0 = [[NSString alloc] initWithStdString:url];
#ifdef DEBUG
		NSLog(@"openUrl: %@", url0);
#endif
		
		NSURL *url1 = [[NSURL alloc] initWithString:url0];
		[url0 release];
		
		bool success = [[NSWorkspace sharedWorkspace] openURL:url1];
		[url1 release];
	}
	
	virtual void tooltip(const std::list<std::string>& items)
	{
		if (!tooltipArray)
			tooltipArray = [[NSMutableArray alloc] initWithCapacity:5];
		
		[tooltipArray removeAllObjects];
		for (std::list<std::string>::const_iterator it = items.begin(); it != items.end(); it++) {
			NSString *item = [[NSString alloc] initWithStdString:*it];
			[tooltipArray addObject:item];
			[item release];
		}
		
#ifdef DEBUG
		NSLog(@"tooltip: %@", tooltipArray);
#endif
		
		updateMenu();		
	}
	
	virtual void quit()
	{
		blinkTimer.reset();
		
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		[[NSUserDefaults standardUserDefaults] synchronize];
		[pool release];
		
		Notifier::quit();
	}
	
	virtual std::string getConfigValue(const std::string& name)
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			// NSUserDefaults logic autoreleases stuff.
			
		NSString *nsName = [NSString stringWithStdString:name];
		NSString *nsValue = [[NSUserDefaults standardUserDefaults] stringForKey:nsName];
		
#ifdef DEBUG
		NSLog(@"getConfigValue(%@): %@", nsName, nsValue);
#endif
		std::string r = (nsValue == nil) ? "" : [nsValue stdString];
		
		[pool release];
		
		return r;
	}
	
	virtual bool setConfigValue(const std::string& name, const std::string& value)
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			// NSUserDefaults logic autoreleases stuff.
		
		NSString *nsName = [NSString stringWithStdString:name];
		NSString *nsValue = [NSString stringWithStdString:value];
#ifdef DEBUG
		NSLog(@"setConfigValue(%@): %@", nsName, nsValue);
#endif

		[[NSUserDefaults standardUserDefaults] setObject:nsValue forKey:nsName];
		
		[pool release];
		
		return true;
	}
	
	virtual void needUpdate(const std::string& url)
	{
		updaterRun(url, boost::bind(&MacNotifier::installUpdate, this, _1));
	}
	
	void installUpdate(boost::asio::streambuf* binary)
	{
		if (!binary) return;
		
		if (mkdir("/tmp/WebNotiUpdate", 0700) < 0) {
			std::cerr << "Updater: unable to create temporary directory" << std::endl;
			delete binary;
			return;
		}
		
		char tempDir[] = "/tmp/WebNotiUpdate/new-XXXXXX";
		if (!mkdtemp(tempDir)) {
			std::cerr << "Updater: unable to create temporary directory" << std::endl;
			delete binary;
			return;
		}
		
		std::cout << "Updater: extracting update in " << tempDir << std::endl;
		
		std::stringstream cmd;
		cmd << "tar -xj -C'" << tempDir << "'";
		FILE* tar = popen(cmd.str().c_str(), "w");
		
		if (!tar) {
			std::cerr << "Updater: unable to launch `tar`" << std::endl;
			delete binary;
			return;
		}
		
		// This can probably be optimized to a situation where the buffer is immediately
		// written to the file.
		char buf[8192];
		int readBytes;
		bool ok;
		while (	(readBytes = binary->sgetn(buf, sizeof(buf))) &&
				(ok = (fwrite(buf, readBytes, 1, tar) == 1)) );

		int tarRet = pclose(tar);
		delete binary;

		if (!ok) {
			std::cerr << "Updater: unable to write to `tar` pipe" << std::endl;
			return;
		}

		if (tarRet != 0) {
			std::cerr << "Updater: `tar` returned error code " << tarRet << std::endl;
			return;
		}

		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		std::string appPath = [[[NSBundle mainBundle] bundlePath] stdString];
		[pool release];
		
		std::string newAppPath(tempDir); // Source of new app
		newAppPath.append("/WebNoti.app");
		
		memcpy(tempDir, "/tmp/WebNotiUpdate/old-XXXXXX", sizeof(tempDir));
		
		if (!mkdtemp(tempDir)) {
			std::cerr << "Updater: unable to create temporary directory" << std::endl;
			return;
		}
		
		std::string oldAppPath(tempDir); // Target of old app
		oldAppPath.append("/WebNoti.app");

		std::cout << "Updater: moving " << appPath << " to " << oldAppPath << std::endl;
		if (rename(appPath.c_str(), oldAppPath.c_str()) < 0) {
			std::cerr << "Updater: unable to move old AppBundle from " << appPath << " to " << oldAppPath << std::endl;
			return;
		}

		std::cout << "Updater: moving " << newAppPath << " to " << appPath << std::endl;
		if (rename(newAppPath.c_str(), appPath.c_str()) < 0) {
			rename(oldAppPath.c_str(), appPath.c_str()); // Move back old one.
			std::cerr << "Updater: unable to move new AppBundle from " << newAppPath << " to " << appPath << std::endl;
			return;
		}
		
		std::cerr << "Updater: done; relaunching" << std::endl;
		
		// Relaunch notifier through `open` wrapper.
		pool = [[NSAutoreleasePool alloc] init];
		[NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:[NSArray arrayWithObjects:@"-W", [NSString stringWithStdString:appPath],nil]];
		[pool release];
			// execv would also be pretty nice here to replace our running image with the update,
			// but this would not allow a change of binary name for instance.
		
		quit();
	}

	void cleanupUpdateTrash()
	{
		// (Try to) clean up /tmp/NotifierUpdate; we assume we have a pool in place here.
		NSFileManager *fm = [NSFileManager defaultManager];

		if ([fm respondsToSelector:@selector(removeItemAtPath:error:)]) // >= 10.5
			[fm removeItemAtPath:@"/tmp/WebNotiUpdate" error:nil];
		else if ([fm respondsToSelector:@selector(removeFileAtPath:handler:)]) // < 10.5
			[fm removeFileAtPath:@"/tmp/WebNotiUpdate" handler:nil];
	}
};

MacNotifier notifier(notiRunloop); // Static initialization of the concrete notifier.

// AppDelegate {{{
@interface AppDelegate : NSObject<GrowlApplicationBridgeDelegate
#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
,NSMenuDelegate
#endif
> {
	NSStatusItem *statusItem;
	NSMenu *menu;
	NSDictionary *menuOpts;
	
	bool menuOpened;
	bool iTunesToMotto;
}
@end

@implementation AppDelegate

- (void) notify:(NSDictionary *)opts
{
#ifdef DEBUG
	NSLog(@"notify: %@", opts);
#endif

	NSString* title = [opts objectForKey: @"title"];
	NSString* text = [opts objectForKey: @"text"];
	NSString* url = [opts objectForKey: @"url"];
	NSNumber* sticky = [opts objectForKey: @"sticky"];

	if (![title length] || ![text length]) return;
		// Growl does not seem to support removing notifications (!?)

	[GrowlApplicationBridge notifyWithTitle: title
	                            description: text
	                       notificationName: @"notifications"
	                               iconData: [[NSImage imageNamed:ICON_APP] TIFFRepresentation]
	                               priority: 1
	                               isSticky: sticky && [sticky boolValue]
	                           clickContext: url ? url : @"none"
	                             identifier: @"notification"];
}

- (void) setIcon:(NSString *)icon 
{
	NSImage *i = [NSImage imageNamed:icon];
	[i setSize:NSMakeSize(20, 20)];
	[statusItem setImage: i];
}

// Menu rendering and handling {{{
- (void) menuOpenHandler:(id)sender
{
	notiRunloop.post(boost::bind(&Notifier::open, &notifier));
}

- (void) menuLoginHandler:(id)sender
{
	notiRunloop.post(boost::bind(&Notifier::setEnabled, &notifier, true, true));
}

- (void) menuLogoutHandler:(id)sender
{
	notiRunloop.post(boost::bind(&Notifier::setEnabled, &notifier, false, true));
}

- (void) menuAboutHandler:(id)sender
{
	notiRunloop.post(boost::bind(&Notifier::about, &notifier));
}

- (void) menuPopupsHandler:(id)sender
{
	notiRunloop.post(boost::bind(&MacNotifier::togglePopups, &notifier));
}

- (void) menuQuitHandler:(id)sender
{
	notiRunloop.post(boost::bind(&Notifier::quit, &notifier));
}

- (void) menuWillClose:(NSMenu *)_menu
{
	menuOpened = NO;
}

- (void) menuWillOpen:(NSMenu *)_menu
{
	// assert _menu == menu
	menuOpened = YES;
	
	if ([menu respondsToSelector:@selector(removeAllItems)])
		[(id)menu removeAllItems];
	else {
		while ([menu itemAtIndex:0] != nil)
			[menu removeItemAtIndex:0];
	}
	
	if (!menuOpts) return;

#ifdef DEBUG	
	NSLog(@"menuOpts: %@", menuOpts);
#endif

	// Check if the option key is pressed. This will reveal some additional features. >= 10.6 only.
	bool optionKey = [NSEvent respondsToSelector:@selector(modifierFlags)] && ((int)[NSEvent modifierFlags] & NSAlternateKeyMask);

	int status = [[menuOpts objectForKey: @"status"] intValue];
	
	NSMenuItem *item = 0;
	if (status == s_enabled)
		item = [menu addItemWithTitle: [NSString stringWithUTF8String: SITENAME " openen"] action: @selector(menuOpenHandler:) keyEquivalent: @""];
	else if (status == s_disconnected)
		item = [menu addItemWithTitle: @"Notifier verbinden" action: @selector(menuLoginHandler:) keyEquivalent: @""];
	else if (status == s_connected)
		item = [menu addItemWithTitle: @"Notifier inloggen" action: @selector(menuLoginHandler:) keyEquivalent: @""];
	
	if (item) [menu addItem:[NSMenuItem separatorItem]];
	
	NSArray *tooltip = [menuOpts objectForKey: @"tooltip"];
	
	if (tooltip && [tooltip count] > 0) {
		for (int i = 0; i < [tooltip count]; i++) {
			item = [menu addItemWithTitle:[tooltip objectAtIndex: i] action:nil keyEquivalent: @""];
			[item setEnabled: NO];
		}

		[menu addItem:[NSMenuItem separatorItem]];
	}
	
	if (status == s_connected)
		[menu addItemWithTitle: [NSString stringWithUTF8String: SITENAME " openen"] action: @selector(menuOpenHandler:) keyEquivalent: @""];
	else if (status == s_enabled) {
		[menu addItemWithTitle: @"Uitloggen" action: @selector(menuLogoutHandler:) keyEquivalent: @""];
		item = [menu addItemWithTitle: @"Popups" action: @selector(menuPopupsHandler:) keyEquivalent: @""];
		if ([[menuOpts objectForKey: @"popups"] boolValue]) [item setState: NSOnState];
	}

	if (optionKey)
		[menu addItemWithTitle: @"Versie informatie" action: @selector(menuAboutHandler:) keyEquivalent: @""];

	[menu addItemWithTitle: @"Afsluiten" action: @selector(menuQuitHandler:) keyEquivalent: @""];
	
	if (status == s_enabled && (optionKey || iTunesToMotto)) {
		[menu addItem: [NSMenuItem separatorItem]];
		
		item = [menu addItemWithTitle: @"iTunes ⇢ what's up?!" action:@selector(iTunesSettingChanged:) keyEquivalent:@""];
		[item setState: (iTunesToMotto ? NSOnState : NSOffState)];
	}
}
// }}}

- (void) setMenu:(NSDictionary *)opts
{
	[menuOpts release];
	menuOpts = [opts retain];
	// The actual menu is configured lazily in menuWillOpen

	if (menuOpened)
		[self menuWillOpen:menu]; // Update if menu is rendered
}

- (void) receiveWakeNote: (NSNotification*) note
{
	NSLog(@"Wake notification received; trying reconnect");
	notiRunloop.post(boost::bind(&Notifier::reconnect, &notifier));
}

- (void) applicationDidFinishLaunching:(NSNotification *)notification
{
	menuOpened = NO;
	iTunesToMotto = NO;
	menuOpts = 0;

	NSLog(@"Registering Growl delegate");
	try {
		[GrowlApplicationBridge setGrowlDelegate:self];
		if (![GrowlApplicationBridge isGrowlInstalled]) throw 1;
	}
	catch (...) {
		NSString *growlReminder = [[NSUserDefaults standardUserDefaults] stringForKey:@"growlReminder"];

		if (growlReminder == nil || growlReminder == @"true") {
			int r = NSRunAlertPanel(@"Growl niet geinstalleerd", @"We kunnen geen notificaties tonen zolang Growl niet geinstalleerd is.",
					@"Ga naar website", @"Herinner me niet meer", @"Nu even niet");
			if (r == NSAlertDefaultReturn)
				[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://growl.info/"]];
			else if (r == NSAlertAlternateReturn)
				[[NSUserDefaults standardUserDefaults] setObject:@"false" forKey:@"growlReminder"];
		}
	}

	NSLog(@"Subscribing to system wake notifications");
	//[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self 
    //		selector: @selector(receiveSleepNote:) name: NSWorkspaceWillSleepNotification object: NULL];
	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self 
	                                                       selector: @selector(receiveWakeNote:)
	                                                           name: NSWorkspaceDidWakeNotification
	                                                         object: nil];

	NSLog(@"Adding StatusBar item");
	statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength] retain];
	[statusItem setHighlightMode:YES];
	[self setIcon:ICON_GRAY];
	
	NSImage *i = [NSImage imageNamed:ICON_ALT];
	[i setSize:NSMakeSize(20, 20)];
	[statusItem setAlternateImage:i];
	
	menu = [[NSMenu alloc] init];
	[menu setDelegate:self];
	[menu addItem:[NSMenuItem separatorItem]];
	
	[statusItem setMenu:menu];
}

- (void) dealloc
{
	[statusItem release];
	[menu release];
	[menuOpts release];
	
	[super dealloc];
}

// Growl protocol {{{
- (void) growlNotificationWasClicked: (id)clickContext
{
	if ([clickContext length])
		notiRunloop.post(boost::bind(&MacNotifier::openUrl, &notifier, [clickContext stdString]));
}

- (NSDictionary *) registrationDictionaryForGrowl {
	return [NSDictionary dictionaryWithObjectsAndKeys:
				[NSArray arrayWithObjects: @"notifications", nil], GROWL_NOTIFICATIONS_ALL,
				[NSArray arrayWithObjects: @"notifications", nil], GROWL_NOTIFICATIONS_DEFAULT, nil];
}

- (NSString *) applicationNameForGrowl {
	return [NSString stringWithUTF8String: SITENAME " notifier"];
}
// }}}

// AutoLaunch - registers this app as LoginItem when running from /Applications/. {{{
- (void) configAutoLaunch
{
    NSString* appPath = [[NSBundle mainBundle] bundlePath];

	NSLog(@"Our appPath is %@", appPath);

    if (![appPath hasPrefix:@"/Applications/"]) {
		NSLog(@"Running outside /Applications; not registering in LoginItems.");
        return;
    }

    // Read the loginwindow preferences.
    NSMutableArray *loginItems = [[[(id) CFPreferencesCopyValue(
            (CFStringRef)@"AutoLaunchedApplicationDictionary",
            (CFStringRef)@"loginwindow",
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost) autorelease] mutableCopy] autorelease];

    // Look if the application is in the loginItems already.
    for (int i = 0; i < [loginItems count]; i++) {
        NSDictionary *item = [loginItems objectAtIndex:i];
		NSLog(@"item = %@", item);
        if ([[item objectForKey:@"Path"] isEqualToString:appPath]) {
            return;
        }
    }

	NSLog(@"Not yet registered as LoginItem; attempting to do so now");
	
    NSDictionary *loginDict;

    loginDict = [NSDictionary dictionaryWithObjectsAndKeys:
        appPath, @"Path",
        [NSNumber numberWithBool:NO], @"Hide",
        nil, nil];
    [loginItems addObject:loginDict];

    // Write the loginwindow preferences.
    CFPreferencesSetValue((CFStringRef)@"AutoLaunchedApplicationDictionary",
                          loginItems,
                          (CFStringRef)@"loginwindow",
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);

    CFPreferencesSynchronize((CFStringRef) @"loginwindow",
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);

    NSLog(@"Application successfully installed as LoginItem");
}
// }}}

// iTunes to motto {{{

// Very basic implementation: only artist/name, and only on notifications. Using 
// scripting bridge to get data immediately (allowing a better implementation)
// is significantly more complex.

- (void) iTunesChanged:(NSNotification *)notification
{
	NSDictionary *itunes = [notification userInfo];
	NSString *motto = @"";
	
	if ([[itunes objectForKey:@"Player State"] isEqualToString:@"Playing"])
		motto = [NSString stringWithFormat:@"%@ - %@", [itunes objectForKey:@"Artist"], [itunes objectForKey:@"Name"]];
	
	NSLog(@"iTunes: %@", motto);
	
	notiRunloop.post(boost::bind(&MacNotifier::setMotdSong, &notifier, [motto stdString]));
}

- (void) iTunesSettingChanged:(NSMenuItem *)item
{	
	iTunesToMotto = !iTunesToMotto;
	[item setState: (iTunesToMotto ? NSOnState : NSOffState)];
	
	if (iTunesToMotto) {
		NSLog(@"Registering for iTunes notifications");

		[[NSDistributedNotificationCenter defaultCenter] addObserver: self
		                                                    selector: @selector(iTunesChanged:)
		                                                        name: @"com.apple.iTunes.playerInfo"
		                                                      object: nil];
	}
	else {
		[[NSDistributedNotificationCenter defaultCenter] removeObserver: self
		                                                           name: @"com.apple.iTunes.playerInfo"
		                                                         object: nil];
	}

}

// }}}

- (void) notiThread: (id)ignore
{
	// No NSAutoReleasePool in place: all our objc allocations in this thread are 
	// to be manually released.
	NSLog(@"Notifier i/o runloop starting");
	notiRunloop.run();
	NSLog(@"Notifier i/o runloop complete");

	[NSApp terminate:nil];
}

@end
// }}}

int main(int argc, char *argv[])
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];

	notifier.cleanupUpdateTrash();
	
	AppDelegate *d = [[AppDelegate alloc] init];
	
	[d configAutoLaunch];
	
	NSLog(@"Launching notifier thread");
	[NSThread detachNewThreadSelector:@selector(notiThread:) toTarget:d withObject:nil];

	[NSApp setDelegate:[d autorelease]];
	
	NSLog(@"Darwin ui runloop starting");
	[NSApp run];
		// Never reaches here due to [NSApp terminate:] behavior
	NSLog(@"Darwin ui runloop complete");

    [pool release];

    return EXIT_SUCCESS;
}
