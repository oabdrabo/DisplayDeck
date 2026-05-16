# Makefile for DisplayDisabler.app
# Build:   make
# Clean:   make clean
# Install: make install (copies to /Applications)

APP_NAME   = DisplayDisabler
BUNDLE     = $(APP_NAME).app
SRCDIR     = src
BUILDDIR   = build

CC         = clang
CFLAGS     = -fobjc-arc -Wall -Wextra -O2 -fstack-protector-strong \
             -mmacosx-version-min=14.0 -MMD -MP -I$(SRCDIR)
FRAMEWORKS = -framework Cocoa -framework CoreGraphics -framework IOKit \
             -framework ServiceManagement -framework UserNotifications \
             -framework CoreDisplay

SOURCES    = $(SRCDIR)/main.m $(SRCDIR)/AppDelegate.m $(SRCDIR)/DisplayManager.m \
             $(SRCDIR)/Brightness.m $(SRCDIR)/HiDPIInjector.m
OBJECTS    = $(patsubst $(SRCDIR)/%.m,$(BUILDDIR)/%.o,$(SOURCES))
DEPS       = $(OBJECTS:.o=.d)
EXECUTABLE = $(APP_NAME)

.PHONY: all clean bundle sign install uninstall icon

all: bundle sign

-include $(DEPS)

$(BUILDDIR)/%.o: $(SRCDIR)/%.m | $(BUILDDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

$(EXECUTABLE): $(OBJECTS)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(OBJECTS) -o $@

# Render AppIcon.icns from the "display" SF Symbol on a dark rounded-rect
# background. One-shot build-time helper; the .icns is committed to the
# repo so CI / downstream builders don't need to re-run it.
AppIcon.icns: $(SRCDIR)/build_icon.m
	@$(CC) -fobjc-arc -O0 -mmacosx-version-min=14.0 -framework Cocoa \
	    $(SRCDIR)/build_icon.m -o /tmp/dd-build-icon
	@/tmp/dd-build-icon AppIcon.iconset
	@iconutil -c icns AppIcon.iconset -o AppIcon.icns
	@rm -rf AppIcon.iconset /tmp/dd-build-icon
	@echo "Built AppIcon.icns"

icon: AppIcon.icns

bundle: $(EXECUTABLE) AppIcon.icns
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources"
	@cp $(EXECUTABLE) "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@/bin/echo -n "APPL????" > "$(BUNDLE)/Contents/PkgInfo"
	@echo "Built $(BUNDLE)"

sign: bundle
	@codesign --force --sign - "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@codesign --force --sign - "$(BUNDLE)"
	@echo "Signed $(BUNDLE) (ad-hoc)"

install: all
	@cp -R "$(BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"

uninstall:
	@rm -rf "/Applications/$(BUNDLE)"
	@echo "Removed /Applications/$(BUNDLE)"

clean:
	@rm -rf $(BUILDDIR) $(EXECUTABLE) AppIcon.icns
	@rm -rf "$(BUNDLE)" AppIcon.iconset
	@echo "Cleaned"
