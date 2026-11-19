#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <dlfcn.h>

static const int64_t probeTag = 0x50414e45;
static const uint32_t virtualVendor = 0x5653;
typedef int (*FindWindow)(int, int, int, int, const CGPoint *, CGPoint *, CGWindowID *, int *);
typedef int (*ConnectionID)(void);

typedef struct {
    CGEventType type;
    CGWindowID window;
    CGPoint point;
    double observedAt;
} Observation;

static Observation observations[32];
static NSUInteger observationCount;
static BOOL observing;

static double uptime(void) { return NSProcessInfo.processInfo.systemUptime; }

static CGPoint cursor(void) {
    CGEventRef event = CGEventCreate(NULL);
    CGPoint location = event ? CGEventGetLocation(event) : CGPointZero;
    if (event) CFRelease(event);
    return location;
}

static void postInput(CGEventRef event) {
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, probeTag);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void postMouse(CGEventType type, CGPoint point) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, kCGMouseButtonLeft);
    if (!event) return;
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    postInput(event);
}

static void postKey(CGKeyCode key, BOOL down, CGEventFlags flags) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, key, down);
    if (!event) return;
    CGEventSetFlags(event, flags);
    if (key == kVK_Control) CGEventSetType(event, kCGEventFlagsChanged);
    postInput(event);
}

static CGEventRef observe(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    if (observing && event && observationCount < sizeof(observations) / sizeof(observations[0]) &&
        CGEventGetIntegerValueField(event, kCGEventSourceUserData) == probeTag) {
        CGWindowID window = (CGWindowID)CGEventGetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        observations[observationCount++] = (Observation){type, window, CGEventGetLocation(event), uptime()};
    }
    return event;
}

static NSNumber *physicalSelector(pid_t pid, const CGRect screens[3], BOOL requireAllScreens) {
    NSArray<NSDictionary *> *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *window in windows) {
        NSNumber *layer = window[(__bridge NSString *)kCGWindowLayer];
        NSNumber *number = window[(__bridge NSString *)kCGWindowNumber];
        NSDictionary *bounds = window[(__bridge NSString *)kCGWindowBounds];
        if (layer.intValue < CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) ||
            [window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != pid ||
            [window[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= 0 || !number || !bounds) continue;
        CGRect frame;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &frame)) continue;
        NSMutableArray<NSNumber *> *group = groups[layer];
        if (!group) {
            group = [NSMutableArray arrayWithArray:@[@0, @0, @0]];
            groups[layer] = group;
        }
        for (int i = 0; i < 3; ++i) {
            if (CGRectContainsRect(frame, CGRectInset(screens[i], 1, 1)) &&
                CGRectContainsRect(CGRectInset(screens[i], -16, -16), frame)) group[i] = number;
        }
    }
    for (NSArray<NSNumber *> *group in groups.allValues) {
        if (group[0].unsignedIntValue && (!requireAllScreens || ![group containsObject:@0])) return group[0];
    }
    return nil;
}

static int printDisplays(void) {
    CGDirectDisplayID displays[64];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(64, displays, &count) != kCGErrorSuccess || count == 0) return 1;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID id = displays[i];
        CGRect frame = CGDisplayBounds(id);
        printf("%u %s (%.0f, %.0f) %.0f × %.0f\n", id,
               CGDisplayVendorNumber(id) == virtualVendor ? "Panelet virtual" : "other",
               frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    return 0;
}

static int runTrial(CFRunLoopSourceRef tapSource, pid_t pid, const CGRect screens[3],
                    FindWindow findWindow, int connection) {
    CGRect physical = screens[0], upper = screens[1];
    CGPoint saved = cursor();
    CGPoint start = CGPointMake(CGRectGetMinX(upper) + CGRectGetWidth(upper) * .40, CGRectGetMaxY(upper) - 38);
    CGPoint mapped = CGPointMake(start.x - CGRectGetMinX(upper) + CGRectGetMinX(physical),
                                 start.y - CGRectGetMinY(upper) + CGRectGetMinY(physical));
    CFRunLoopAddSource(CFRunLoopGetCurrent(), tapSource, kCFRunLoopDefaultMode);
    BOOL pressed = NO;
    BOOL invoked = NO;
    int result = 1;
    @try {
        if (CGWarpMouseCursorPosition(start) != kCGErrorSuccess) return 1;
        postMouse(kCGEventMouseMoved, start);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .03, false);
        postKey(kVK_Control, YES, kCGEventFlagMaskControl);
        postKey(kVK_ANSI_1, YES, kCGEventFlagMaskControl);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .012, false);
        postKey(kVK_ANSI_1, NO, kCGEventFlagMaskControl);
        postKey(kVK_Control, NO, 0);
        invoked = YES;
        double deadline = uptime() + 2.0;
        NSNumber *selector = nil;
        while (!(selector = physicalSelector(pid, screens, YES)) && uptime() < deadline) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, .004, false);
        }
        if (!selector) {
            fputs("Ctrl+1 did not produce the expected PixPin selection windows.\n", stderr);
            return 1;
        }
        double shownAt = uptime();
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .007, false);
        CGPoint local;
        CGWindowID hit = 0;
        int owner = 0;
        CGWindowID expected = selector.unsignedIntValue;
        BOOL alreadyReady = findWindow(connection, 0, 1, 0, &mapped, &local, &hit, &owner) == 0 && hit == expected;
        CGPoint pointer = cursor();
        if (!CGRectContainsPoint(upper, pointer) && !CGRectContainsPoint(physical, pointer)) {
            fputs("The pointer left the test display before mouse down.\n", stderr);
            return 1;
        }
        double pressedAt = uptime();
        observing = YES;
        pressed = YES;
        postMouse(kCGEventLeftMouseDown, pointer);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .009, false);
        CGFloat dx = MIN(28, CGRectGetWidth(upper) / 10);
        for (int i = 1; i <= 4; i++) {
            CGPoint origin = CGRectContainsPoint(physical, cursor()) ? mapped : start;
            postMouse(kCGEventLeftMouseDragged, CGPointMake(origin.x + dx * i, origin.y + 19 * i));
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, .010, false);
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .22, false);

        double firstDelivery = -1;
        NSUInteger drags = 0, wrongEvents = 0;
        CGPoint lastDrag = CGPointZero;
        for (NSUInteger i = 0; i < observationCount; i++) {
            Observation sample = observations[i];
            BOOL routed = sample.window == expected && CGRectContainsPoint(physical, sample.point);
            if (!routed) wrongEvents++;
            if (sample.type == kCGEventLeftMouseDown && routed && firstDelivery < 0) {
                firstDelivery = (sample.observedAt - pressedAt) * 1000;
            } else if (sample.type == kCGEventLeftMouseDragged) {
                drags++;
                lastDrag = sample.point;
            }
        }
        BOOL endpoint = drags > 0 && hypot(lastDrag.x - mapped.x - 4 * dx, lastDrag.y - mapped.y - 76) < 3;
        BOOL passed = firstDelivery >= 0 && wrongEvents == 0 && drags == 4 && endpoint;
        printf("{\"visible_to_click_ms\":%.2f,\"physical_ready_before_down\":%d,"
               "\"first_delivery_ms\":%.3f,\"drag_events\":%lu,\"wrong_events\":%lu,\"passed\":%d}\n",
               (pressedAt - shownAt) * 1000, alreadyReady, firstDelivery, (unsigned long)drags,
               (unsigned long)wrongEvents, passed);
        result = passed ? 0 : 1;
    } @finally {
        observing = NO;
        if (invoked && physicalSelector(pid, screens, NO)) {
            postKey(kVK_Escape, YES, 0);
            postKey(kVK_Escape, NO, 0);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, .05, false);
        }
        if (pressed) postMouse(kCGEventLeftMouseUp, cursor());
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .15, false);
        CGWarpMouseCursorPosition(saved);
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, kCFRunLoopDefaultMode);
    }
    return result;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--displays") == 0) return printDisplays();
        if (argc != 4) {
            fprintf(stderr, "Usage: %s PHYSICAL_ID UPPER_VIRTUAL_ID LOWER_VIRTUAL_ID\n", argv[0]);
            return 2;
        }
        CGRect screens[3];
        for (int i = 0; i < 3; i++) {
            char *end;
            unsigned long number = strtoul(argv[i + 1], &end, 10);
            if (end == argv[i + 1] || *end || number == 0 || number > UINT32_MAX ||
                !CGDisplayIsActive((CGDirectDisplayID)number) ||
                (CGDisplayVendorNumber((CGDirectDisplayID)number) == virtualVendor) != (i != 0)) {
                fputs("Supply an active physical display and two active Panelet virtual displays.\n", stderr);
                return 2;
            }
            screens[i] = CGDisplayBounds((CGDirectDisplayID)number);
        }
        CGRect physical = screens[0], upper = screens[1], lower = screens[2];
        if (CGRectGetMinX(upper) != CGRectGetMinX(lower) || CGRectGetMaxY(upper) != CGRectGetMinY(lower) ||
            CGRectGetWidth(upper) != CGRectGetWidth(physical) || CGRectGetWidth(lower) != CGRectGetWidth(physical) ||
            CGRectGetHeight(upper) + CGRectGetHeight(lower) != CGRectGetHeight(physical) ||
            CGRectGetHeight(upper) < 80 || CGRectGetHeight(lower) < 80) {
            fputs("The probe requires an upper/lower split that matches the physical display.\n", stderr);
            return 2;
        }
        NSArray<NSRunningApplication *> *pixpin = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.depthpicture.PixPin"];
        if (pixpin.count != 1 || physicalSelector(pixpin.firstObject.processIdentifier, screens, NO)) {
            fputs("Start one instance of PixPin and close its existing selection before testing.\n", stderr);
            return 2;
        }
        if (!CGPreflightPostEventAccess() || !CGPreflightListenEventAccess()) {
            fputs("The probe requires permission to post and observe mouse events.\n", stderr);
            return 2;
        }
        FindWindow findWindow = (FindWindow)dlsym(RTLD_DEFAULT, "SLSFindWindowAndOwner");
        ConnectionID connectionID = (ConnectionID)dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        int connection = connectionID ? connectionID() : 0;
        if (!findWindow || !connection) {
            fputs("WindowServer hit testing is unavailable.\n", stderr);
            return 2;
        }
        CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseDragged);
        CFMachPortRef tap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGTailAppendEventTap,
                                            kCGEventTapOptionListenOnly, mask, observe, NULL);
        if (!tap) return 2;
        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
        int result = source ? runTrial(source, pixpin.firstObject.processIdentifier, screens, findWindow, connection) : 2;
        if (source) CFRelease(source);
        CFRelease(tap);
        return result;
    }
}
