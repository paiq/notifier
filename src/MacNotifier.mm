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
#import <TinyGrowlClient.h>

#define USERAGENT SITENAME " Notifier 1.0.1 (Mac)"
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

void uiRunloopPost(SEL selector, ...)
{
	// Dispatches to UI runloop method that accepts an NSArray* with options.
	NSMutableArray *options = [[NSMutableArray alloc] init];

	va_list optionsList;
	va_start(optionsList, selector);
	while (id option = va_arg(optionsList, id))
    	[options addObject: option];
	va_end(optionsList);

	[[NSApp delegate] performSelectorOnMainThread: selector
	                                   withObject: options
	                                waitUntilDone: false];
	
	[options release];
}

class MacNotifier : public Notifier
{
	// Delegating menu updates {{{
	NSMutableArray *tooltipArray;
	void updateMenu()
	{
		NSNumber *nsStatus = [[NSNumber alloc] initWithInt: status];
		
		uiRunloopPost(@selector(setMenu:), nsStatus, tooltipArray, 0);

		[nsStatus release];
	}
	// }}}
	
	// Delegating icon updates {{{
	NSString *iconIcon;
	NSString *iconTitle;
	void setIcon(NSString *icon)
	{
		iconIcon = [icon retain];
		uiRunloopPost(@selector(setIcon:), iconIcon, iconTitle, 0);
	}

	void setIconTitle(NSString *title)
	{
		iconTitle = [title retain];
		uiRunloopPost(@selector(setIcon:), iconIcon, iconTitle, 0);
	}
	
	std::auto_ptr<boost::asio::deadline_timer> blinkTimer;
	void onBlink(const boost::system::error_code& err, NSString *nextIcon, NSString *curIcon) {
		if (err == boost::asio::error::operation_aborted) {
			[nextIcon release];
			[curIcon release];
			return;
		}

		setIcon(nextIcon);
		
		blinkTimer.reset(new boost::asio::deadline_timer(ioService));
		blinkTimer->expires_from_now(boost::posix_time::seconds(1));
		blinkTimer->async_wait(boost::bind(&MacNotifier::onBlink, this,
				boost::asio::placeholders::error, curIcon, nextIcon));
	}
	// }}}
	
public:
	MacNotifier(boost::asio::io_service& ioService_) :
			Notifier(ioService_), tooltipArray(0), iconIcon(ICON_GRAY), iconTitle(@""),
			blinkTimer() {
	}

	~MacNotifier()
	{
		// Can't cleanup blinkTimer here, but instances are not destroyed anyway.
		[tooltipArray release];
		[iconIcon release];
		[iconTitle release];
	}
	
	void setMotdSong(std::string& motd)
	{
		if (status != s_enabled) return;
		(IlmpCommand(ilmp.get(), "User.setMotdSong") << motd).send();
	}
	
	virtual void initialize() {
		Notifier::initialize();
		updateMenu();
	}
	
	virtual void dataChanged()
	{
		Notifier::dataChanged();
		
		// Additionally update our menu icon title.
		if (status == s_enabled && unreadMsgs) {
			NSString *title = [[NSString alloc] initWithFormat: @"%d", unreadMsgs];
			setIconTitle(title);
			[title release];
		}
		else setIconTitle(@"");
	}
	
	virtual void openUrl(const std::string& url)
	{
		NSString *url0 = [[NSString alloc] initWithStdString:url];
#ifdef DEBUG
		NSLog(@"openUrl: %@", url0);
#endif
		
		NSURL *url1 = [[NSURL alloc] initWithString:url0];
		[url0 release];
		
		[[NSWorkspace sharedWorkspace] openURL:url1];
		[url1 release];
	}
	
	virtual void notify(const std::string& title, const std::string& text, const std::string& url, bool sticky, bool prio)
	{
		NSString *nsTitle = [[NSString alloc] initWithStdString: title];
		NSString *nsText = [[NSString alloc] initWithStdString: text];
		NSString *nsUrl = [[NSString alloc] initWithStdString: url];
		NSNumber *nsSticky = [[NSNumber alloc] initWithBool: sticky];
		
		uiRunloopPost(@selector(notify:), nsTitle, nsText, nsUrl, nsSticky, 0);
		
		[nsTitle release];
		[nsText release];
		[nsUrl release];
		[nsSticky release];
	}
	
	virtual void icon(Icon i)
	{
#ifdef DEBUG
		NSLog(@"icon: %d", i);
#endif
		blinkTimer.reset();
		
		if (i == i_disabled) setIcon(ICON_GRAY);
		else if (i == i_users) setIcon(ICON_USERS);
		else if (i == i_normal) setIcon(ICON_NORMAL);
		else {
			setIcon(ICON_MSG);
			onBlink(boost::system::error_code(), ICON_NORMAL, ICON_MSG);
		}
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
		
		if (mkdir("/tmp/WebNotiUpdate", 0700) < 0 && errno != EEXIST) {
			serr("MacUpdater: unable to create temporary directory");
			delete binary;
			return;
		}
		
		char tempDir[] = "/tmp/WebNotiUpdate/new-XXXXXX";
		if (!mkdtemp(tempDir)) {
			serr("MacUpdater: unable to create temporary directory");
			delete binary;
			return;
		}
		
		std::cout << "MacUpdater: extracting update in " << tempDir << std::endl;
		
		std::stringstream cmd;
		cmd << "tar -xj -C'" << tempDir << "'";
		FILE* tar = popen(cmd.str().c_str(), "w");
		
		if (!tar) {
			serr("MacUpdater: unable to launch `tar`");
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
			serr("MacUpdater: unable to write to `tar` pipe");
			return;
		}

		if (tarRet != 0) {
			std::stringstream msg; msg << "MacUpdater: `tar` returned error code " << tarRet;
			serr(msg.str());
			return;
		}

		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		std::string appPath = [[[NSBundle mainBundle] bundlePath] stdString];
		[pool release];
		
		std::string newAppPath(tempDir); // Source of new app
		newAppPath.append("/WebNoti.app");
		
		memcpy(tempDir, "/tmp/WebNotiUpdate/old-XXXXXX", sizeof(tempDir));
		
		if (!mkdtemp(tempDir)) {
			serr("MacUpdater: unable to create temporary directory");
			return;
		}
		
		std::string oldAppPath(tempDir); // Target of old app
		oldAppPath.append("/WebNoti.app");

		std::cout << "MacUpdater: moving " << appPath << " to " << oldAppPath << std::endl;
		if (rename(appPath.c_str(), oldAppPath.c_str()) < 0) {
			std::stringstream msg; msg << "MacUpdater: unable to move old AppBundle from " << appPath << " to " << oldAppPath;
			serr(msg.str());
			return;
		}

		std::cout << "MacUpdater: moving " << newAppPath << " to " << appPath << std::endl;
		if (rename(newAppPath.c_str(), appPath.c_str()) < 0) {
			rename(oldAppPath.c_str(), appPath.c_str()); // Move back old one.
			std::stringstream msg; msg << "MacUpdater: unable to move new AppBundle from " << newAppPath << " to " << appPath;
			serr(msg.str());
			return;
		}
		
		sout("MacUpdater: success; relaunching");
		
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

		[fm removeFileAtPath:@"/tmp/WebNotiUpdate" handler:nil];
		// [fm removeItemAtPath:@"/tmp/WebNotiUpdate" error:nil];
		// The latter is the preferred way of doing things >= 10.5
	}
};

MacNotifier notifier(notiRunloop); // Static initialization of the concrete notifier.

// AppDelegate {{{
@interface AppDelegate : NSObject
#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
<NSMenuDelegate>
#endif
{
	NSStatusItem *statusItem;
	NSMenu *menu;
	NSArray *menuOpts;
	
	bool menuOpened;
	bool iTunesToMotto;

	TinyGrowlClient *growl;
}
@end

@implementation AppDelegate

- (void) notify:(NSArray *)opts
{
#ifdef DEBUG
	NSLog(@"notify: %@", opts);
#endif

	NSString* title		= [opts objectAtIndex: 0];
	NSString* text		= [opts objectAtIndex: 1];
	NSString* url		= [opts objectAtIndex: 2];
	NSNumber* sticky	= [opts objectAtIndex: 3];

	if (![title length] || ![text length]) return;
		// Growl does not support removing notifications (!?)

	[growl notifyWithType:@"notification"
	                title:title
	          description:text
	         clickContext:url ? url : @""];
}

- (void) setIcon:(NSArray *)opts
{
#ifdef DEBUG
	NSLog(@"setIcon: %@", opts);
#endif

	NSString* icon = [opts objectAtIndex: 0];
	NSString* text = [opts objectAtIndex: 1];
	
	NSImage *i = [NSImage imageNamed:icon];
	[i setSize:NSMakeSize(20, 20)];
	[statusItem setImage: i];
	[statusItem setTitle: text ? text : @""];
}

// Menu rendering and handling {{{
- (void) menuOpenHandler:(id)sender		{ notiRunloop.post(boost::bind(&Notifier::open, &notifier)); }
- (void) menuLoginHandler:(id)sender	{ notiRunloop.post(boost::bind(&Notifier::setEnabled, &notifier, true, true)); }
- (void) menuLogoutHandler:(id)sender	{ notiRunloop.post(boost::bind(&Notifier::setEnabled, &notifier, false, true)); }
- (void) menuAboutHandler:(id)sender	{ notiRunloop.post(boost::bind(&Notifier::about, &notifier)); }
- (void) menuQuitHandler:(id)sender		{ notiRunloop.post(boost::bind(&Notifier::quit, &notifier)); }

- (void) menuWillClose:(NSMenu *)_menu	{
	menuOpened = false;
}

- (void) menuWillOpen:(NSMenu *)_menu
{
	// assert _menu == menu
	
	menuOpened = true;

	// [menu removeAllItems] is only supported >= 10.6
	while ([menu numberOfItems])
		[menu removeItemAtIndex:0];
	
	if (!menuOpts) return;

#ifdef DEBUG	
	NSLog(@"menuOpts: %@", menuOpts);
#endif

	// Check if the option key is pressed. This will reveal some additional features. >= 10.6 only.
	bool optionKey = [NSEvent respondsToSelector:@selector(modifierFlags)] && ((int)[NSEvent modifierFlags] & NSAlternateKeyMask);

	int status = [[menuOpts objectAtIndex: 0] intValue];
	
	NSMenuItem *item = 0;
	if (status == s_enabled)
		item = [menu addItemWithTitle: [NSString stringWithUTF8String: SITENAME " openen"] action: @selector(menuOpenHandler:) keyEquivalent: @""];
	else if (status == s_disconnected)
		item = [menu addItemWithTitle: @"Notifier verbinden" action: @selector(menuLoginHandler:) keyEquivalent: @""];
	else if (status == s_connected)
		item = [menu addItemWithTitle: @"Notifier inloggen" action: @selector(menuLoginHandler:) keyEquivalent: @""];
	
	if (item) [menu addItem:[NSMenuItem separatorItem]];
	
	NSArray *tooltip = [menuOpts objectAtIndex: 1];
	
	if (tooltip && [tooltip count] > 0) {
		for (int i = 0; i < [tooltip count]; i++) {
			item = [menu addItemWithTitle:[tooltip objectAtIndex: i] action:nil keyEquivalent: @""];
			[item setEnabled: false];
		}

		[menu addItem:[NSMenuItem separatorItem]];
	}
	
	if (status == s_connected)
		[menu addItemWithTitle: [NSString stringWithUTF8String: SITENAME " openen"] action: @selector(menuOpenHandler:) keyEquivalent: @""];
	else if (status == s_enabled)
		[menu addItemWithTitle: @"Uitloggen" action: @selector(menuLogoutHandler:) keyEquivalent: @""];

	if (optionKey)
		[menu addItemWithTitle: @"Versie informatie" action: @selector(menuAboutHandler:) keyEquivalent: @""];

	[menu addItemWithTitle: @"Afsluiten" action: @selector(menuQuitHandler:) keyEquivalent: @""];
	
	if (status == s_enabled && (optionKey || iTunesToMotto)) {
		[menu addItem: [NSMenuItem separatorItem]];

		NSString *text = [NSString stringWithUTF8String:"iTunes \xe2\x87\xa2 what's up?!"]; 
			// due to compiler bug not detecting when a static string should be put in a utf-16 container

		item = [menu addItemWithTitle:text action:@selector(iTunesSettingChanged:) keyEquivalent:@""];
		[item setState: (iTunesToMotto ? NSOnState : NSOffState)];
	}
}
// }}}

- (void) setMenu:(NSArray *)opts
{
	[menuOpts release];
	menuOpts = [opts retain];
	// The actual menu is configured lazily in menuWillOpen

	if (menuOpened)
		[self menuWillOpen:menu]; // Update if menu is rendered
}

- (void) receiveWakeNote:(NSNotification*)note
{
	NSLog(@"Wake notification received; trying reconnect");
	notiRunloop.post(boost::bind(&Notifier::reconnect, &notifier));
}

- (void) receiveSleepNote:(NSNotification*)note
{
	notiRunloop.dispatch(boost::bind(&Notifier::disconnect, &notifier));
	NSLog(@"Sleep notification received; disconnected");
}

- (void) applicationDidFinishLaunching:(NSNotification *)notification
{
	menuOpened = false;
	iTunesToMotto = false;
	menuOpts = 0;

	NSLog(@"Registering Growl delegate");
	[growl release];
	growl = [TinyGrowlClient new];
	[growl setDelegate:self];
	[growl setAppName:[NSString stringWithUTF8String: SITENAME " notifier"]];
	[growl setAllNotifications: [NSArray arrayWithObjects: @"notification", nil]];
	[growl registerApplication];

	NSLog(@"Subscribing to system wake notifications");
	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self 
	                                                       selector: @selector(receiveSleepNote:)
	                                                           name: NSWorkspaceWillSleepNotification
	                                                         object: nil];
	
	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self 
	                                                       selector: @selector(receiveWakeNote:)
	                                                           name: NSWorkspaceDidWakeNotification
	                                                         object: nil];

	NSLog(@"Adding StatusBar item");
	statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
	[statusItem setHighlightMode:true];
	[self setIcon:[NSArray arrayWithObjects: ICON_GRAY, @"", nil]];
	
	NSImage *i = [NSImage imageNamed:ICON_ALT];
	[i setSize:NSMakeSize(20, 20)];
	[statusItem setAlternateImage:i];
	
	menu = [[NSMenu alloc] init];
	[menu setDelegate:self];
	[menu addItem:[NSMenuItem separatorItem]];
	
	[statusItem setMenu:menu];
	
	NSLog(@"Initializing notifier");
	notiRunloop.post(boost::bind(&Notifier::initialize, &notifier));
}

- (void) dealloc
{
	[statusItem release];
	[menu release];
	[menuOpts release];
	
	[super dealloc];
}

// tinygrowl protocol {{{
- (void) tinyGrowlClient:(TinyGrowlClient*)sender didClick:(id)clickContext
{
	if ([clickContext length])
		notiRunloop.post(boost::bind(&MacNotifier::openUrl, &notifier, [clickContext stdString]));
}

static bool showingReminder = false;
- (void)tinyGrowlClient:(TinyGrowlClient*)sender didChangeRunning:(bool)running
{
	if (!showingReminder && !running) {
		NSString *growlReminder = [[NSUserDefaults standardUserDefaults] stringForKey:@"growlReminder"];

		if (![growlReminder isEqualToString:@"false"]) { 
			showingReminder = true;
			int r = NSRunAlertPanel(@"Growl niet geinstalleerd",
					@"We kunnen geen notificaties tonen zolang Growl niet actief is. Als Growl wel geinstalleerd is, is deze wellicht uitgeschakeld in Systeemvoorkeuren.",
					@"Ga naar www.growl.info", @"Herinner me niet meer", @"Nu even niet");

			if (r == NSAlertDefaultReturn) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://growl.info/"]];
			else if (r == NSAlertAlternateReturn) [[NSUserDefaults standardUserDefaults] setObject:@"false" forKey:@"growlReminder"];

			showingReminder = false;
		}
	}
 	else if (showingReminder && running) [NSApp abortModal]; 

	if (menuOpened) [self menuWillOpen:menu]; // update if menu is rendered
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
        [NSNumber numberWithBool:false], @"Hide",
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

	NSDistributedNotificationCenter* dnc = [NSDistributedNotificationCenter defaultCenter];
	if (iTunesToMotto) [dnc addObserver:self selector:@selector(iTunesChanged:) name: @"com.apple.iTunes.playerInfo" object: nil];
	else [dnc removeObserver:self name: @"com.apple.iTunes.playerInfo" object: nil];
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
