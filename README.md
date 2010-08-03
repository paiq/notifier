Notifier
========

This project contains the paiq.nl instant message notifier client. It aims at demonstrating a practical implementation of the [ilmpclient](http://github.com/ImplicitLink/ilmpclient) library.

There are three different applications:

* win32 system tray: Background notifier application, 'living' in the Windows system tray.
* darwin status bar item: Background notifier application, 'living' in the Mac OS X status bar.
* linux command line: Mainly for debugging purposes, but might be adapted to something useful.

Source checkout
---------------
There are two git submodule references in the source tree, [ilmpclient](http://github.com/ImplicitLink/ilmpclient) and [dsa_verify](http://github.com/ImplicitLink/dsa_verify). After cloning the git repository you should checkout these dependencies using `git submodule init; git submodule update`.

Compilation
-----------
The following environments should work:

* Windows 2000+ w/[nuwen.net MinGW distro](http://nuwen.net/mingw.html), *builds for __win32__*
* Windows 2000+ w/[cygwin](http://cygwin.net) (required packages: mingw libboost), *builds for __win32__*
* Mac OS X 10.4+ w/Developer Tools w/[compiled libboost](http://sourceforge.net/projects/boost/files/boost/1.43.0/), *builds for __darwin__*
* Mac OS X 10.4+ w/Developer Tools w/[darwinports libboost](http://boost.darwinports.com/), *builds for __darwin__*
* Debian Linux w/??? *builds for __linux, win32, darwin__*

A linux environment with is recommended. With MinGW one should be able to build the win32 notifier in a linux environment relatively painless. Internally, we also cross-compile for darwin on Debian Linux, but getting this set up is a little more tricky.

The makefile shows the supported builds on your platform. Use `make info` to list the available targets, then build one or more targets using, for instance, `make linux-paiq-debug`.

Using libboost
--------------
Both ilmpclient and the notifier rely on [libboost](http://boost.org/). For most platforms installation is pretty straightforward. When cross-compiling make sure the boost_system library is (statically) available for your cross-compiling target.

License
-------
The program sources are released under the GNU General Public License. The included icon and image resources are all rights reserved.
