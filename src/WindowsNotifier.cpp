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

#define _WIN32_IE 0x0500

#define USERAGENT SITENAME " Notifier 1.0.1 (Windows)"
	// Used by server to determine whether we should update 

#ifdef DEBUG 
	#define UPDATEURL "http://" UPDATEHOST "/d/WebNoti_dbg.exe"
#else
	#define UPDATEURL "http://" UPDATEHOST "/d/WebNoti.exe"
#endif

// Hack around mingw/boost clash: http://groups.google.com/group/boost-list/browse_thread/thread/1146284e83aae91c
extern "C" void tss_cleanup_implemented() { }

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <winreg.h>
#include <process.h> // _beginthread
#include <shellapi.h>

#include <boost/asio.hpp>
#include <boost/algorithm/string/join.hpp>

#include "Notifier.h"

// Copies a std::string onto a static-sized buffer, appending with \0
#define strCopy(s, t) t[s.copy(t, sizeof(t)-1)] = '\0'

// UI constants {{{
#define ICON_NORMAL	1000 // $RESOURCE$ "res/normal.$SITE.ico"
#define ICON_GRAY	2000 // $RESOURCE$ "res/gray.$SITE.ico"
#define ICON_USERS	2001 // $RESOURCE$ "res/users.$SITE.ico"
#define ICON_MSG	2002 // $RESOURCE$ "res/msg.$SITE.ico"
#define WM_TRAYNOTIFY			(WM_USER + 1000)
#define NIN_BALLOONTIMEOUT		(WM_USER + 4)
#define NIN_BALLOONUSERCLICK	(WM_USER + 5)
#define NOTI_TRAYID		1001
#define DO_EXIT			1002
#define DO_ABOUT		1003 
#define DO_ENABLED		1004 
#define DO_LOGIN		1005 
#define DO_LOGOUT		1006 
#define DO_TOGGLEPOPUPS	1007 
#define DO_VISIT		1008
// }}}

void showBalloon(const std::string&, const std::string&, const std::string&);
void clearBalloon();
void setMenu(int,bool);
void setTooltip(const std::string&);
void setIcon(int);

// Threading setup: ui-thread and noti-thread. The noti-thread is managed by an io_service, and
// any calls to the notifier object are scheduled in this runloop. Since the win api functions
// are multi-entrant, we execute them directly from the noti-thread.

boost::asio::io_service notiRunloop;

class WindowsNotifier : public Notifier // {{{
{
	bool popups;
	
	void updateMenu()
	{
		setMenu(status, popups); // uiRunloop.post(...)
	}
	
	std::auto_ptr<boost::asio::deadline_timer> blinkTimer;
	void onBlink(const boost::system::error_code& err, int nextIcon, int curIcon) {
		if (err == boost::asio::error::operation_aborted)
			return;

		setIcon(nextIcon);
		
		blinkTimer.reset(new boost::asio::deadline_timer(ioService));
		blinkTimer->expires_from_now(boost::posix_time::seconds(1));
		blinkTimer->async_wait(boost::bind(&WindowsNotifier::onBlink, this,
				boost::asio::placeholders::error, curIcon, nextIcon));
	}
		
public:
	WindowsNotifier(boost::asio::io_service& ioService_) :
			Notifier(ioService_), popups(true), blinkTimer() {
	}

	void togglePopups()
	{
		popups = !popups;
		setConfigValue("popups", popups ? "true" : "false");
		updateMenu();
	}
	
	void enableOrOpen()
	{
		if (status!=s_enabled) setEnabled(true, true);
		else open();
	}
	
	virtual void initialize() {
		Notifier::initialize();
		popups = (getConfigValue("popups") == "true");
		updateMenu();
	}

	virtual void openUrl(const std::string& url)
	{
		ShellExecute(0, "open", url.c_str(), 0, 0, SW_MAXIMIZE);
	}

	virtual void notify(const std::string& title, const std::string& text, const std::string& url, bool sticky, bool prio)
	{
		if (!prio && !popups) return;

		if (title.size()) showBalloon(title, text, url); // uiRunloop.post(...)
		else clearBalloon(); // uiRunloop.post(...)
	}
	
	virtual void statusChanged()
	{
		Notifier::statusChanged();
		updateMenu();
	}
	
	virtual void icon(Icon i)
	{
#ifdef DEBUG
		std::cout << "icon: " << i << std::endl;
#endif
		blinkTimer.reset();
		
		if (i == i_disabled) setIcon(ICON_GRAY);
		else if (i == i_normal) setIcon(ICON_NORMAL);
		else if (i == i_users) {
			setIcon(ICON_USERS);
			onBlink(boost::system::error_code(), ICON_NORMAL, ICON_USERS);
		}
		else {
			setIcon(ICON_MSG);
			onBlink(boost::system::error_code(), ICON_NORMAL, ICON_MSG);
		}
	}
	
	virtual void tooltip(const std::list<std::string>& items)
	{
		setTooltip(boost::algorithm::join(items, "\r\n"));  // uiRunloop.post(...)
	}
	
	virtual void quit()
	{
		blinkTimer.reset();
		Notifier::quit();
	}
	
	virtual std::string getConfigValue(const std::string& name)
	{
		std::string value("");

		HKEY hkey;
		if (RegOpenKeyEx(HKEY_CURRENT_USER, "Software\\Implicit-Link\\WebNoti", 0, KEY_ALL_ACCESS, &hkey) == ERROR_SUCCESS) {
			unsigned long type = REG_SZ;
			unsigned char buf[4096];
			unsigned long bufSize = sizeof(buf);
			
			if (RegQueryValueEx(hkey, name.c_str(), 0, &type, buf, &bufSize) == ERROR_SUCCESS) 
				value = std::string((char *)buf, bufSize-1);
			
			RegCloseKey(hkey);
		}
			
#ifdef DEBUG
		std::cout << "getConfigValue(" << name << "): " << value << std::endl;
#endif
		return value;
	}
	
	virtual bool setConfigValue(const std::string& name, const std::string& value)
	{
#ifdef DEBUG
		std::cout << "setConfigValue(" << name << "): " << value << std::endl;
#endif
		HKEY hkey;
		unsigned long dispos;
		if (RegCreateKeyEx(HKEY_CURRENT_USER, "Software\\Implicit-Link\\WebNoti", 0, 0,
				REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, 0, &hkey, &dispos) != ERROR_SUCCESS) return false;
		bool success = (RegSetValueEx(hkey, name.c_str(), 0, REG_SZ, (BYTE *)value.c_str(), value.size()) == ERROR_SUCCESS);
		RegCloseKey(hkey);
		return success;
	}
	
	virtual void needUpdate(const std::string& url)
	{
		// Try to create a _autoupdate dir in our binary's path. If this is not
		// allowed we probably have no (UAC) permissions here, and we will skip the
		// update.
		TCHAR appFile[MAX_PATH];
		if (!GetModuleFileName(0, (LPTSTR)appFile, sizeof(appFile))) {
			serr("WinUpdater: unable to determine our application binary");
			return;
		}

		std::string appFileStr(appFile);
		
		std::cout << "WinUpdater: our binary is " << appFileStr << std::endl;
		
		std::string updateDirStr(appFileStr);
		size_t lastSlash = updateDirStr.find_last_of('\\');
		if (lastSlash == std::string::npos || lastSlash == 0) {
			std::stringstream msg; msg << "WinUpdater: application binary has no directory: " << appFileStr;
			serr(msg.str());
			return;
		}
		updateDirStr = updateDirStr.substr(0, lastSlash);
		updateDirStr.append("\\_autoupdate");
		
		TCHAR updateDir[MAX_PATH];
		strCopy(updateDirStr, updateDir);

		if (CreateDirectory(updateDir, 0) || GetLastError() == ERROR_ALREADY_EXISTS)
			updaterRun(url, boost::bind(&WindowsNotifier::installUpdate, this, _1, appFileStr, updateDirStr));
		else {
			std::stringstream msg; msg << "WinUpdater: unable to create " << updateDir << ", skipping update. GetLastError()=" << GetLastError();
			serr(msg.str());
		}
	}
	
	void installUpdate(boost::asio::streambuf* binary, const std::string& appFileStr, const std::string& updateDirStr)
	{
		if (!binary) return;

		// Install new binary by writing to file and swapping name with our running
		// binary. Then relaunch.
		
		TCHAR updateDir[MAX_PATH]; strCopy(updateDirStr, updateDir);
		TCHAR appFile[MAX_PATH]; strCopy(appFileStr, appFile);
		TCHAR tempFileNew[MAX_PATH]; // New binary
		TCHAR tempFileOld[MAX_PATH]; // Old binary
		
		if (!GetTempFileName(updateDir, "UD_", 0, tempFileOld) ||
				!GetTempFileName(updateDir, "UD_", 0, tempFileNew)) {
			serr("WinUpdater: unable to create temporary file");
			delete binary;
			return;
		} 
		
	    HANDLE fh = CreateFile((LPTSTR) tempFileNew, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	    if (fh == INVALID_HANDLE_VALUE) {
			std::stringstream msg; msg << "WinUpdater: unable to open temporary file for writing: " << tempFileNew; 
			serr(msg.str());
			delete binary;
			return;
	    } 
		
		// This can probably be optimized to a situation where the buffer is immediately
		// written to the file.
		char buf[8192];
		int readBytes;
		DWORD writtenBytes;
		bool ok;
		while (	(readBytes = binary->sgetn(buf, sizeof(buf))) &&
				(ok = WriteFile(fh, buf, readBytes, &writtenBytes, 0) ));

		CloseHandle(fh);
		delete binary;

		if (!ok) {
			std::stringstream msg; msg << "WinUpdater: unable to write to temporary file: " << tempFileNew; 
			serr(msg.str());
			return;
		}
		
		if (!MoveFileEx(appFile, tempFileOld, MOVEFILE_REPLACE_EXISTING)) {
			std::stringstream msg; msg << "WinUpdater: unable to move " << appFile << " to " << tempFileOld << std::endl;
			serr(msg.str());
			return;
		}

		if (!MoveFileEx(tempFileNew, appFile, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED)) {
			MoveFileEx(tempFileOld, appFile, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED); // Move back old one
			std::stringstream msg; msg << "WinUpdater: unable to move " << tempFileNew << " to " << appFile;
			serr(msg.str());
			return;
		}
		
		sout("WinUpdater: success; relaunching");
		
		ShellExecute(0, "open", appFile, "", 0, SW_SHOW);
		
		quit();
	}

	void cleanupUpdateTrash()
	{
		// Removes updates in .\_autoupdate, and then the directory. Should
		// be called at program launch.
		
		TCHAR appFile[MAX_PATH];
		if (!GetModuleFileName(0, (LPTSTR)appFile, sizeof(appFile)))
			return;

		std::string updateDir(appFile);
		size_t lastSlash = updateDir.find_last_of('\\');
		if (lastSlash == std::string::npos || lastSlash == 0)
			return;
		
		updateDir = updateDir.substr(0, lastSlash);
		updateDir.append("\\_autoupdate");
		
		std::string glob(updateDir);
		glob.append("\\UD_*.*");
		
		WIN32_FIND_DATA d;
		HANDLE h = FindFirstFile(glob.c_str(), &d);
		if (h != INVALID_HANDLE_VALUE) {
			do {
				std::string file(updateDir);
				file.append("\\");
				file.append(d.cFileName);
				if (!DeleteFile(file.c_str())) {
					std::cerr << "Unable to clean up " << file << std::endl;
					FindClose(h);
					return;
				} else std::cout << "Removed old update file " << file << std::endl;
			} while (FindNextFile(h, &d));
		}
		FindClose(h);
		
		RemoveDirectory(updateDir.c_str());
	}
}; // }}}

static char gszClassName[] = "WebNoti";
static HINSTANCE ghInstance = 0; // Global app handle.

WindowsNotifier notifier(notiRunloop); // Static initialization of the concrete notifier.

// -- UI stuff {{{
HWND hwnd;
NOTIFYICONDATA niData;
HICON iconNormal, iconGray, iconUsers, iconMsg;

std::string balloonUrl;

void showBalloon(const std::string& title, const std::string& msg, const std::string& url)
{
	balloonUrl = url;
	
	strCopy(title, niData.szInfoTitle);
	strCopy(msg, niData.szInfo);
	niData.uTimeout = 10000;
	niData.dwInfoFlags = 4;

	niData.uFlags = NIF_INFO;
	Shell_NotifyIcon(NIM_MODIFY, &niData);
}

void clearBalloon()
{
	strCopy(std::string(""), niData.szInfoTitle);
	strCopy(std::string(""), niData.szInfo);
	niData.uFlags = NIF_INFO;
	Shell_NotifyIcon(NIM_MODIFY, &niData);
}

void setIcon(int i)
{
	if (i == ICON_GRAY) niData.hIcon = iconGray;
	else if (i == ICON_USERS) niData.hIcon = iconUsers;
	else if (i == ICON_MSG) niData.hIcon = iconMsg;
	else niData.hIcon = iconNormal;
	niData.uFlags = NIF_ICON;
	Shell_NotifyIcon(NIM_MODIFY, &niData);
}

void setTooltip(const std::string& tooltip)
{
	strCopy(tooltip, niData.szTip);
	niData.uFlags = NIF_TIP;
	Shell_NotifyIcon(NIM_MODIFY, &niData);
}

HMENU hMenu = false;
void setMenu(int status, bool popups)
{
	if (hMenu) DestroyMenu(hMenu);
	hMenu = CreatePopupMenu();

	if (status == s_connected)
		AppendMenu(hMenu, MF_STRING, DO_VISIT, "&" SITENAME " openen");
	else if (status == s_enabled) {
		AppendMenu(hMenu, MF_STRING, DO_LOGOUT, "&Uitloggen");
		AppendMenu(hMenu, MF_STRING | (popups ? MF_CHECKED : MF_UNCHECKED), DO_TOGGLEPOPUPS, "&Popups");
	}

	AppendMenu(hMenu, MF_STRING, DO_EXIT, "&Afsluiten");

	if (status != s_connecting) {
		AppendMenu(hMenu, MF_SEPARATOR, 0, 0);
		if (status == s_enabled)
			AppendMenu(hMenu, MF_STRING, DO_VISIT, "&" SITENAME " openen");
		else if (status == s_disconnected)
			AppendMenu(hMenu, MF_STRING, DO_LOGIN, "Notifier verbinden");
		else if (status == s_connected)
			AppendMenu(hMenu, MF_STRING, DO_LOGIN, "Notifier inloggen");
	}
}

// -- Window event message callbacks
void cbCreate(HWND hwnd, WPARAM w, LPARAM l)
{
	// Took some time to figure out: using uFlags one can configure which
	// of the fields should be (re)examined when calling Shell_NotifyIcon.
	// So for every invocation, this field should be set accordingly.
	niData.cbSize			= sizeof(NOTIFYICONDATA);
	niData.hWnd				= hwnd;
	niData.uID				= NOTI_TRAYID;
	niData.uCallbackMessage	= WM_TRAYNOTIFY;
	niData.hIcon			= iconGray;
	niData.uFlags			= NIF_MESSAGE | NIF_ICON;
	Shell_NotifyIcon(NIM_ADD, &niData);
}

void cbTrayNotify(HWND hwnd, WPARAM w, LPARAM l) 
{
	if (w != NOTI_TRAYID) return;

	if (l == WM_LBUTTONDOWN)
		notiRunloop.post(boost::bind(&WindowsNotifier::enableOrOpen, &notifier));
	else if (l == WM_RBUTTONDOWN) {
		POINT point;
		GetCursorPos(&point);
		SetForegroundWindow(hwnd);
		TrackPopupMenu(hMenu, TPM_RIGHTALIGN, point.x, point.y, 0, hwnd, 0);
		SendMessage(hwnd, WM_NULL, 0, 0);
	}
	else if (l == NIN_BALLOONUSERCLICK) {
		if (balloonUrl.length()) notifier.openUrl(balloonUrl);
		clearBalloon();
	}
	else if (l == NIN_BALLOONTIMEOUT) {
		clearBalloon();
	}
}

void cbCommand(HWND hwnd, WPARAM w, LPARAM l)
{
	if (w == DO_EXIT)
		notiRunloop.post(boost::bind(&WindowsNotifier::quit, &notifier));
	else if (w == DO_ABOUT)
		notiRunloop.post(boost::bind(&Notifier::about, &notifier));
	else if (w == DO_LOGIN)
		notiRunloop.post(boost::bind(&Notifier::setEnabled, &notifier, true, true));
	else if (w == DO_LOGOUT)
		notiRunloop.post(boost::bind(&Notifier::setEnabled, &notifier, false, true));
	else if (w == DO_TOGGLEPOPUPS)
		notiRunloop.post(boost::bind(&WindowsNotifier::togglePopups, &notifier));
	else if (w == DO_VISIT)
		notiRunloop.post(boost::bind(&Notifier::open, &notifier));
}

void cbDestroy(HWND hwnd, WPARAM w, LPARAM l)
{
	niData.hWnd   = hwnd;
	niData.uID    = NOTI_TRAYID;
	Shell_NotifyIcon(NIM_DELETE, &niData);
 	
	DestroyMenu(hMenu);
	PostQuitMessage(0);
}

void cbPowerBroadcast(HWND hwnd, WPARAM w, LPARAM l)
{
	if (w == PBT_APMRESUMEAUTOMATIC) {
		std::cout << "Wake notification received; trying reconnect" << std::endl;
		notiRunloop.post(boost::bind(&Notifier::reconnect, &notifier));
	}
}
// }}}

LRESULT CALLBACK winProcMsg(HWND hwnd, UINT mes, WPARAM w, LPARAM l)
{
	if (mes == WM_CREATE) cbCreate(hwnd, w, l);
	else if (mes == WM_TRAYNOTIFY) cbTrayNotify(hwnd, w, l);
	else if (mes == WM_COMMAND) cbCommand(hwnd, w, l);
	else if (mes == WM_DESTROY) cbDestroy(hwnd, w, l);
	else if (mes == WM_POWERBROADCAST) cbPowerBroadcast(hwnd, w, l);
	else return DefWindowProc(hwnd, mes, w, l);

	return 0;
}

bool ctrlHandler(DWORD type)
{
	std::cout << "Received CTRL-C or equivalent" << std::endl;
	notiRunloop.post(boost::bind(&WindowsNotifier::quit, &notifier));
	return TRUE;
}

void notiThreadFunc(void* x)
{
	std::cout << "Notifier i/o runloop starting" << std::endl;
	notiRunloop.run();
	std::cout << "Notifier i/o runloop complete" << std::endl;
	
	// Tear down: WM_CLOSE will destroy our window, invoking cbDestroy;
	// then PostQuitMessage will make sure the UI event loop exits.
	SendMessage(hwnd, WM_CLOSE, 0, 0);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
	ghInstance = hInstance;
	
	notifier.cleanupUpdateTrash();

	// Load the various resources
	iconNormal	= (HICON) LoadImage(ghInstance,MAKEINTRESOURCE(ICON_NORMAL),IMAGE_ICON,16,16,0);
	iconGray	= (HICON) LoadImage(ghInstance,MAKEINTRESOURCE(ICON_GRAY),IMAGE_ICON,16,16,0);
	iconUsers	= (HICON) LoadImage(ghInstance,MAKEINTRESOURCE(ICON_USERS),IMAGE_ICON,16,16,0);
	iconMsg		= (HICON) LoadImage(ghInstance,MAKEINTRESOURCE(ICON_MSG),IMAGE_ICON,16,16,0);

	// Register 'window class'
	WNDCLASSEX winClass;
	winClass.cbSize 		= sizeof(WNDCLASSEX);
	winClass.style 			= 0;
	winClass.lpfnWndProc	= winProcMsg;
	winClass.cbClsExtra		= 0;
	winClass.cbWndExtra		= 0;
	winClass.hInstance		= ghInstance;
	winClass.hIcon			= LoadIcon(NULL, IDI_APPLICATION);
	winClass.hCursor		= LoadCursor(NULL, IDC_ARROW);
	winClass.hbrBackground	= (HBRUSH)(COLOR_WINDOW+1);
	winClass.lpszMenuName	= NULL;
	winClass.lpszClassName	= gszClassName;
	winClass.hIconSm		= LoadIcon(NULL, IDI_APPLICATION);

	if (!RegisterClassEx(&winClass)) {
		std::cerr << "Window Registration Failed" << std::endl;
		return -1;
	}

	hwnd = CreateWindowEx(WS_EX_STATICEDGE, gszClassName, "", WS_OVERLAPPEDWINDOW,
			CW_USEDEFAULT, CW_USEDEFAULT, 320, 240, NULL, NULL, ghInstance, NULL);
		
	if (!hwnd) {
		std::cerr << "Window Creation Failed" << std::endl;
		return -1;
	}

	SetConsoleCtrlHandler((PHANDLER_ROUTINE) ctrlHandler, TRUE);

	_beginthread(notiThreadFunc, 0, 0);

	std::cout << "Initializing notifier" << std::endl;
	notiRunloop.post(boost::bind(&Notifier::initialize, &notifier));
	
	MSG msg;
	while (GetMessage(&msg, 0, 0, 0) > 0) {
	    TranslateMessage(&msg);
	    DispatchMessage(&msg);
	}
	
    return msg.wParam;
}

