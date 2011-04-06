#
# Paiq notifier framework - http://opensource.implicit-link.com/
# Copyright 2010 Implicit Link
#

TARGETS  	:= paiq-release paiq-debug nextlover-release nextlover-debug
PLATFORMS	:= win32 linux linux64 darwin darwin64

# host platform specific configuration {{{
HOST_PLATFORM := $(if $(PWD),$(patsubst CYGWIN_%,win32,$(subst Linux,linux,$(subst Darwin,darwin,$(shell uname)))),win32native)
isWin32Native = $(filter win32native,$(HOST_PLATFORM))

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

ERROR			:= @$(call echo,Unable to build this target on a $(HOST_PLATFORM) platform.) && $(binfalse)

GPP				:= $(ERROR)
AR				:= $(ERROR)
WINDRES			:= $(ERROR)

define HostTempl.linux
	GPP.linux			:= g++
	GPP.linux64			:= g++
	AR.linux			:= ar
	AR.linux64			:= ar

	$(if $(shell i686-apple-darwin9-g++ --version 2>/dev/null),
 	GPP.darwin		:= i686-apple-darwin9-g++
	GPP.darwin64	:= i686-apple-darwin9-g++
	AR.darwin		:= i686-apple-darwin9-ar
	AR.darwin64		:= i686-apple-darwin9-ar,)

	$(if $(shell i586-mingw32msvc-g++ --version 2>/dev/null),
 	GPP.win32		:= i586-mingw32msvc-g++
	AR.win32		:= i586-mingw32msvc-ar
	WINDRES.win32	:= i586-mingw32msvc-windres,)
endef

define HostTempl.win32
	GPP.win32			:= g++-3 -mno-cygwin
	AR.win32			:= ar
	WINDRES.win32		:= windres
endef

define HostTempl.win32native
	GPP.win32			:= g++
	AR.win32			:= ar
endef

define HostTempl.darwin
	GPP.darwin			:= g++
	GPP.darwin64		:= g++
	AR.darwin			:= ar
	AR.darwin64			:= ar
endef

$(eval $(call HostTempl.$(HOST_PLATFORM)))
# }}}

# Additional CFLAGS / LFLAGS can also be supplied on the cli.
CFLAGS.release	:= $(CFLAGS) -Os
CFLAGS.debug	:= $(CFLAGS) -g -DILMPDEBUG -DDEBUG
CFLAGS.darwin64.release	:= $(CFLAGS.release) -m64
CFLAGS.darwin64.debug	:= $(CFLAGS.debug) -m64
CFLAGS.linux64.release	:= $(CFLAGS.release) -m64
CFLAGS.linux64.debug	:= $(CFLAGS.debug) -m64

LFLAGS.release  := $(LFLAGS) -s
LFLAGS.debug	:= $(LFLAGS)

# functions {{{
getPlatform = $(word 1,$(subst -, ,$(1)))
getSite		= $(word 2,$(subst -, ,$(1)))
getVariant	= $(word 3,$(subst -, ,$(1)))
isDebug		= $(filter debug, $(call getVariant,$(1)))

# resolves a 'specialized' variable. Tries VAR.{platform}.{variant}, VAR.{platform}, VAR.{variant}, VAR.
var = $(strip $(or $($1.$(call getPlatform,$2).$(call getVariant,$2)),$($1.$(call getPlatform,$2)),$($1.$(call getVariant,$2)),$($(1))))
# }}}

# basic targets {{{
info:
	@$(call echo,Platform=$(PLATFORM))
	@$(call echo,Targets: $(strip $(foreach p,$(PLATFORMS),$(foreach t,$(TARGETS), \
		$(if $(filter $(ERROR),$(call var,GPP,$(p)-$(t))),, \
		\n $(p)-$(t) \
			(GPP=$(call var,GPP,$(p)-$(t)), CFLAGS=$(call var,CFLAGS,$(p)-$(t)), \
			LFLAGS=$(call var,LFLAGS,$(p)-$(t)) ))))))
	
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
# }}}

### dsa_verify library {{{

build/%/dsa_verify_mp_math.o: ext/dsa_verify/mp_math.c ext/dsa_verify/*.h
	$(call var,GPP,$*) $(call var,CFLAGS,$*) -o $@ -c $<

build/%/dsa_verify_sha1.o: ext/dsa_verify/sha1.c ext/dsa_verify/*.h
	$(call var,GPP,$*) $(call var,CFLAGS,$*) -o $@ -c $<

build/%/dsa_verify_dsa_verify.o: ext/dsa_verify/dsa_verify.c ext/dsa_verify/*.h
	$(call var,GPP,$*) $(call var,CFLAGS,$*) -o $@ -c $<

build/%/dsa_verify.a: build/%/dsa_verify_mp_math.o build/%/dsa_verify_sha1.o build/%/dsa_verify_dsa_verify.o
	$(call var,AR,$*) -rs $@ $^ 
# }}}

### win32 builds WebNoti.exe {{{ 

build/win32-%/WindowsNotifier.o: src/WindowsNotifier.cpp src/Notifier.h ext/ilmpclient/*.h ext/dsa_verify/*.h
	$(call var,GPP,win32,$*) $(call var,CFLAGS,win32,$*) \
		-include src/SiteSpecifics.$(call getSite,$*).h -c -o $@ $<

build/win32-%/WindowsNotifierRes.o: src/WindowsNotifier.cpp
	$(if $(isWin32Native), \
		(echo 1000 ICON "res/normal.$(call getSite,$*).ico" & \
		echo 2000 ICON "res/gray.$(call getSite,$*).ico" & \
		echo 2001 ICON "res/users.$(call getSite,$*).ico" & \
		echo 2002 ICON "res/msg.$(call getSite,$*).ico"), \
		perl -nle 'print "$$1 ICON $$2" if /([0-9]+)\s*\/\/\s*\$$RESOURCE\$$\s*(\".*\")\s*$$/' < $< \
				| sed 's/$$SITE/$(call getSite,$*)/g' ) \
			| $(call var,WINDRES,win32,$*) -o $@

# TODO: Implement something for win32native here:
#       http://stackoverflow.com/questions/3389902/advanced-grep-perl-like-text-file-processing-on-win32

build/win32%/WebNoti.exe: build/win32-%/WindowsNotifier.o build/win32-%/WindowsNotifierRes.o build/win32-%/dsa_verify.o
	$(call var,GPP,win32$*) $^ -o $@ $(call var,LFLAGS,win32$*)
# }}}

### darwin builds WebNoti.app {{{

build/darwin%/MacNotifier.o: src/MacNotifier.mm src/Notifier.h ext/ilmpclient/*.h ext/dsa_verify/*.h ext/tinygrowl/*.h
	$(call var,GPP,darwin$*) $(call var,CFLAGS,darwin$*) \
		-Iext/ilmpclient -Iext/dsa_verify -Iext/tinygrowl \
		-include src/SiteSpecifics.$(call getSite,darwin$*).h -c -o $@ $<

build/darwin%/tinygrowl.o: ext/tinygrowl/TinyGrowlClient.m ext/tinygrowl/*.h
	$(call var,GPP,darwin$*) $(call var,CFLAGS,darwin$*) -c -o $@ $<

build/darwin%/WebNoti.app: res/darwin-info.plist
	mkdir -p build/darwin$*/WebNoti.app/Contents
	cp $< build/darwin$*/WebNoti.app/Contents/Info.plist

# Copy resources annotated in our source file to Contents/Resources/
build/darwin%/WebNoti.app/Contents/Resources: src/MacNotifier.mm
	mkdir -p build/darwin$*/WebNoti.app/Contents/Resources
	$(shell perl -nle 'print "cp $$2 build/darwin$*/WebNoti.app/Contents/Resources/$$1;" \
		if /"(.*)"\s*\/\/\s*\$$RESOURCE\$$\s*\"(.*)\"\s*$$/' < $< | sed 's/$$SITE/$(call getSite,darwin$*)/g')

build/darwin%/WebNoti.app/Contents/MacOS/Notifier: build/darwin%/MacNotifier.o build/darwin%/tinygrowl.o build/darwin%/dsa_verify.a
	mkdir -p build/darwin$*/WebNoti.app/Contents/MacOS
	$(call var,GPP,darwin$*) $(call var,LFLAGS,darwin$*) -framework Cocoa -lSystem -lboost_system -o $@ $^
# }}}

### linux builds ConsoleNotifier {{{

build/linux%/ConsoleNotifier.o: src/ConsoleNotifier.cpp src/Notifier.h ext/ilmpclient/*.h
	$(call var,GPP,linux$*) $(call var,CFLAGS,linux$*) \
		-Iext/ilmpclient -Iext/dsa_verify \
		-include src/SiteSpecifics.$(call getSite,linux$*).h -c -o $@ $< 

build/linux%/ConsoleNotifier: build/linux%/ConsoleNotifier.o build/linux%/dsa_verify.a
	$(call var,GPP,linux$*) $(call var,LFLAGS,linux$*) -lboost_system -lboost_thread -o $@ $^

# }}}

define TargetTempl
 win32-$(1): _init-win32-$(1) build/win32-$(1)/WebNoti.exe
 clean-win32-$(1): _clean-win32-$(1)

 linux-$(1): _init-linux-$(1) build/linux-$(1)/ConsoleNotifier
 clean-linux-$(1): _clean-linux-$(1)

 linux64-$(1): _init-linux64-$(1) build/linux64-$(1)/ConsoleNotifier
 clean-linux64-$(1): _clean-linux64-$(1)

 darwin-$(1): _init-darwin-$(1) build/darwin-$(1)/WebNoti.app build/darwin-$(1)/WebNoti.app/Contents/Resources build/darwin-$(1)/WebNoti.app/Contents/MacOS/Notifier
 clean-darwin-$(1): _clean-darwin-$(1)

 darwin64-$(1): _init-darwin64-$(1) build/darwin64-$(1)/WebNoti.app build/darwin64-$(1)/WebNoti.app/Contents/Resources build/darwin64-$(1)/WebNoti.app/Contents/MacOS/Notifier
 clean-darwin64-$(1): _clean-darwin64-$(1)
endef

$(foreach t,$(TARGETS), $(eval $(call TargetTempl,$(t))))
