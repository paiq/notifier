TARGETS  	:= paiq-release paiq-debug
PLATFORMS	:= linux win32 darwin

PLATFORM := $(if $(PWD),$(patsubst CYGWIN_%,win32,$(subst Linux,linux,$(subst Darwin,darwin,$(shell uname)))),win32native)

isWin32Native = $(filter win32native,$(PLATFORM))

ifeq ($(isWin32Native),)
	# linux / darwin / win32
	bintrue	:= true
	binfalse:= false
	echo	= printf "$1\n"
else
	# win32native
	bintrue	:= rem
	binfalse:= exit
	echo	= $(subst echo &,echo.&,$(subst echo &,echo.&,echo $(subst \n,& echo ,$1)))
		# Pretty ugly, but works in most cases. Parameters should not end with \n though.
endif

DARWIN_GRAWL	:= Growl
		# or Growl-WithInstaller, but this explodes the bundle.

getSite		= $(word 1,$(subst -, ,$(1)))
getVariant	= $(word 2,$(subst -, ,$(1)))
isDebug		= $(filter debug, $(call getVariant,$(1)))

ERROR			:= @$(call echo,Unable to build this target on a $(PLATFORM) platform.) && $(binfalse)

GPP				:= g++
WINDRES.win32	:= windres

# Additional CFLAGS / LFLAGS can also be supplied on the cli.
CFLAGS.release	:= $(CFLAGS) -Iext/ilmpclient -Iext/dsa_verify -Os
CFLAGS.debug	:= $(CFLAGS.release) -g -O0 -DILMPDEBUG -DDEBUG
CFLAGS.darwin.release	:= $(CFLAGS.release) -Iext/$(DARWIN_GRAWL).framework/Headers
CFLAGS.darwin.debug		:= $(CFLAGS.debug) -Iext/$(DARWIN_GRAWL).framework/Headers
CFLAGS.win32.release	:= $(CFLAGS.release) -D_WIN32_WINNT=0x0501 -DWINVER=0x0501
CFLAGS.win32.debug		:= $(CFLAGS.debug) -D_WIN32_WINNT=0x0501 -DWINVER=0x0501

LFLAGS			:= $(LFLAGS) -lboost_system
LFLAGS.release  := $(LFLAGS)
LFLAGS.win32    := $(LFLAGS) -lws2_32 -s # the -s flag mysteriously crashes the notifier on OSX
LFLAGS.win32.release    := $(LFLAGS.release) -lws2_32 -mwindows
LFLAGS.darwin			:= $(LFLAGS) -framework Cocoa -Fext/ -framework $(DARWIN_GRAWL)
LFLAGS.darwin.release	:= $(LFLAGS.release) -framework Cocoa -Fext/ -framework $(DARWIN_GRAWL)
LFLAGS.linux			:= $(LFLAGS) -lboost_thread
LFLAGS.linux.release	:= $(LFLAGS.release) -lboost_thread

DSA_VERIFY_SRCS := $(wildcard ext/dsa_verify/*.c)

define HostTempl.linux
 GPP.darwin			:= $(if $(shell i686-apple-darwin11-g++-4.7 --version 2>/dev/null),i686-apple-darwin11-g++-4.7,$(ERROR))
 STRIP.darwin		:= $(if $(shell i686-apple-darwin11-g++-4.7 --version 2>/dev/null),i686-apple-darwin11-strip,$(ERROR))
 GPP.win32			:= $(if $(shell i586-mingw32msvc-g++ --version 2>/dev/null),i586-mingw32msvc-g++,$(ERROR))
 WINDRES.win32		:= i586-mingw32msvc-windres
endef

define HostTempl.win32
 GPP.darwin			:= $(ERROR)
 GPP.linux			:= $(ERROR)
 GPP.win32			:= g++-3 -mno-cygwin
endef

define HostTempl.win32native
 GPP.darwin			:= $(ERROR)
 GPP.linux			:= $(ERROR)
endef

define HostTempl.darwin
 GPP.linux			:= $(ERROR)
 GPP.win32			:= $(ERROR)
endef

$(eval $(call HostTempl.$(PLATFORM)))

# var resolves a 'specialized' variable. Tries VAR.{platform}.{variant}, VAR.{platform}, VAR.{variant}, VAR.
var = $(strip $(or $($1.$2.$(call getVariant,$3)),$($1.$2),$($1.$(call getVariant,$3)),$($(1))))

info:
	@$(call echo,Platform=$(PLATFORM))
	@$(call echo,Targets: $(strip $(foreach p,$(PLATFORMS),$(foreach t,$(TARGETS), \
		$(if $(filter $(ERROR),$(call var,GPP,$(p),$(t))),, \
		\n $(p)-$(t) \
			(GPP=$(call var,GPP,$(p),$(t)), CFLAGS=$(call var,CFLAGS,$(p),$(t)), \
			LFLAGS=$(call var,LFLAGS,$(p),$(t)) ))))))
	
clean:
	$(if $(isWin32Native), \
		del /q /s build\* && rmdir /q /s build, \
		rm -Rf build)

_clean-%:
	$(if $(isWin32Native), \
		del /q /s build\$*\* && rmdir /q /s build\$*, \
		rm -Rf build/$*)

_init-%: 
	$(if $(isWin32Native), \
		@if not exist "build\$*" mkdir "build\$*", \
		@mkdir -p build/$*) 

### win32 builds WebNoti.exe ###

build/win32-%/WebNoti.exe: build/win32-%/WindowsNotifier.o build/win32-%/WindowsNotifierRes.o $(DSA_VERIFY_SRCS)
	$(call var,GPP,win32,$*) $^ -o $@ $(call var,LFLAGS,win32,$*)
	i586-mingw32msvc-strip $@

build/win32-%/WindowsNotifier.o: src/WindowsNotifier.cpp src/Notifier.h ext/ilmpclient/*.h ext/dsa_verify/*.h
	$(call var,GPP,win32,$*) \
		$(call var,CFLAGS,win32,$*) \
		-c -o $@ -include src/SiteSpecifics.$(call getSite,$*).h \
		$<

build/win32-%/WindowsNotifierRes.o: src/WindowsNotifier.cpp
		perl -nle 'print "$$1 ICON $$2" if /([0-9]+)\s*\/\/\s*\$$RESOURCE\$$\s*(\".*\")\s*$$/' < $< \
				| sed 's/[.]ico/~$(call getSite,$*).ico/g' \
				| $(call var,WINDRES,win32,$*) -o $@
# TODO: Implement something for win32native here:
#       http://stackoverflow.com/questions/3389902/advanced-grep-perl-like-text-file-processing-on-win32

### darwin builds WebNoti.app ###

build/darwin-%/WebNoti.app: res/darwin-info.plist
	@$(call echo,Preparing app bundle structure)
	@mkdir -p build/darwin-$*/WebNoti.app/Contents
	cp $< build/darwin-$*/WebNoti.app/Contents/Info.plist
	@mkdir -p build/darwin-$*/WebNoti.app/Contents/Frameworks
	@test -d build/darwin-$*/WebNoti.app/Contents/Framework/$(DARWIN_GRAWL).framework || \
		($(call echo,Copying $(DARWIN_GRAWL) framework) && \
		(cp -R ext/$(DARWIN_GRAWL).framework build/darwin-$*/WebNoti.app/Contents/Frameworks/))

build/darwin-%/WebNoti.app/Contents/Resources: src/MacNotifier.mm
	# Copy resources annotated in our source file to Contents/Resources/
	@mkdir -p build/darwin-$*/WebNoti.app/Contents/Resources
	$(shell perl -nle 'print "cp $$2 build/darwin-$*/WebNoti.app/Contents/Resources/$$1;" \
		if /"(.*)"\s*\/\/\s*\$$RESOURCE\$$\s*\"(.*)\"\s*$$/' < $< | sed 's/$$SITE/$(call getSite,$*)/g')

build/darwin-%/MacNotifier.o: src/MacNotifier.mm src/Notifier.h ext/ilmpclient/*.h ext/dsa_verify/*.h
	$(call var,GPP,darwin,$*) \
		$(call var,CFLAGS,darwin,$*) \
		-c -o $@ -include src/SiteSpecifics.$(call getSite,$*).h \
		$<

build/darwin-%/WebNoti.app/Contents/MacOS/Notifier: build/darwin-%/MacNotifier.o $(DSA_VERIFY_SRCS) build/darwin-%/WebNoti.app 
	@mkdir -p build/darwin-$*/WebNoti.app/Contents/MacOS
	$(call var,GPP,darwin,$*) $< $(DSA_VERIFY_SRCS) $(call var,LFLAGS,darwin,$*) -o $@
	$(call var,STRIP,darwin,$*) $@

### linux builds ConsoleNotifier ###

build/linux-%/ConsoleNotifier: build/linux-%/ConsoleNotifier.o $(DSA_VERIFY_SRCS)
	$(call var,GPP,linux,$*) $(call var,LFLAGS,linux,$*) $^ -o $@

build/linux-%/ConsoleNotifier.o: src/ConsoleNotifier.cpp src/Notifier.h ext/ilmpclient/*.h
	$(call var,GPP,linux,$*) \
		$(call var,CFLAGS,linux,$*) \
		-c -o $@ -include src/SiteSpecifics.$(call getSite,$*).h \
		$<

define TargetTempl
 win32-$(1): _init-win32-$(1) build/win32-$(1)/WebNoti.exe
 clean-win32-$(1): _clean-win32-$(1)

 linux-$(1): _init-linux-$(1) build/linux-$(1)/ConsoleNotifier
 clean-linux-$(1): _clean-linux-$(1)

 darwin-$(1): _init-darwin-$(1) build/darwin-$(1)/WebNoti.app build/darwin-$(1)/WebNoti.app/Contents/Resources build/darwin-$(1)/WebNoti.app/Contents/MacOS/Notifier
 clean-darwin-$(1): _clean-darwin-$(1)
endef

$(foreach t,$(TARGETS), $(eval $(call TargetTempl,$(t))))
