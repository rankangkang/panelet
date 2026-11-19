#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

static NSString *directory;
static BOOL host;
static pid_t destination;
static NSInteger targetWindow;
static CGPoint targetOrigin;
static NSInteger activateTarget;
static NSWindow *window;
static BOOL externalTarget;
static CGSize viewportSize;
static void record(NSDictionary *fields) {
    NSMutableDictionary *row=[fields mutableCopy];
    row[@"time"]=@(NSProcessInfo.processInfo.systemUptime);
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:[directory stringByAppendingPathComponent:host?@"host.jsonl":@"target.jsonl"]];
    [file seekToEndOfFile]; [file writeData:data]; [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}
static CGPoint pointer(void) { CGEventRef e=CGEventCreate(NULL); CGPoint p=CGEventGetLocation(e); CFRelease(e); return p; }
@interface ProbeWindow : NSPanel
@end
@implementation ProbeWindow
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen { return frame; }
- (BOOL)canBecomeKeyWindow { return !(host && activateTarget==3); }
- (BOOL)canBecomeMainWindow { return !(host && activateTarget==3); }
- (void)sendEvent:(NSEvent *)e {
    if (e.type==NSEventTypeLeftMouseDown || e.type==NSEventTypeLeftMouseDragged || e.type==NSEventTypeLeftMouseUp || e.type==NSEventTypeKeyDown) {
        CGPoint p=pointer(); NSPoint local=e.locationInWindow;
        record(@{@"event":@(e.type),@"local":@[@(local.x),@(local.y)],@"pointer":@[@(p.x),@(p.y)],@"active":@(NSApp.active),@"key":@(self.keyWindow),@"window":@(e.windowNumber)});
    }
    [super sendEvent:e];
}
@end
@interface Surface : NSView <NSDraggingDestination>
@property NSImage *image;
@property NSInteger downs;
@property NSInteger drags;
@property NSInteger ups;
@end
@implementation Surface
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSArray *files=[sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]?:@[];
    NSMutableArray *paths=NSMutableArray.array; for(NSURL *url in files)[paths addObject:url.lastPathComponent];
    record(@{@"nativeDragEntered":paths,@"location":@[@(sender.draggingLocation.x),@(sender.draggingLocation.y)]});
    return NSDragOperationNone;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect {
    [NSColor.systemIndigoColor setFill]; NSRectFill(self.bounds);
    if (self.image) [self.image drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
    else [@"Drag here" drawAtPoint:NSMakePoint(40,145) withAttributes:@{NSForegroundColorAttributeName:NSColor.whiteColor,NSFontAttributeName:[NSFont systemFontOfSize:24]}];
}
- (void)forward:(NSEvent *)e {
    NSPoint local=[self convertPoint:e.locationInWindow fromView:nil];
    NSDictionary *state=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"target-state.json"]] options:0 error:nil];
    targetOrigin=CGPointMake([state[@"origin"][0] doubleValue],[state[@"origin"][1] doubleValue]);
    NSPoint projected=NSMakePoint(targetOrigin.x+local.x,targetOrigin.y+local.y);
    if (activateTarget && (e.type==NSEventTypeLeftMouseDown || e.type==NSEventTypeRightMouseDown))
        [[NSRunningApplication runningApplicationWithProcessIdentifier:destination] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    NSInteger recipientWindow=targetWindow;
    CGPoint recipientOrigin=targetOrigin;
    if(externalTarget) {
        typedef int (*Find)(int,int,int,int,const CGPoint*,CGPoint*,CGWindowID*,int*);
        Find find=(Find)dlsym(RTLD_DEFAULT,"SLSFindWindowAndOwner");
        int (*connection)(void)=(int(*)(void))dlsym(RTLD_DEFAULT,"SLSMainConnectionID");
        CGWindowID hit=0; int owner=0; CGPoint hitLocal;
        if(find && connection && find(connection(),0,1,0,&projected,&hitLocal,&hit,&owner)==0 && hit) {
            NSArray *entries=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,hit));
            NSDictionary *item=entries.firstObject;
            if([item[(__bridge NSString*)kCGWindowOwnerPID] intValue]==destination) {
                CGRect bounds=CGRectZero;
                CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)item[(__bridge NSString*)kCGWindowBounds],&bounds);
                recipientWindow=hit; recipientOrigin=bounds.origin;
            }
        }
    }
    NSEvent *routed=[NSEvent mouseEventWithType:e.type location:NSMakePoint(local.x,viewportSize.height-local.y) modifierFlags:e.modifierFlags timestamp:e.timestamp windowNumber:recipientWindow context:nil eventNumber:e.eventNumber clickCount:e.clickCount pressure:e.pressure];
    CGEventRef copy=CGEventCreateCopy(routed.CGEvent);
    // Undocumented AppKit destination-window field used by existing PID-posting probes.
    CGEventSetIntegerValueField(copy,(CGEventField)51,recipientWindow);
    CGEventSetIntegerValueField(copy,kCGEventTargetUnixProcessID,destination);
    CGEventSetLocation(copy,CGPointMake(targetOrigin.x+local.x,targetOrigin.y+local.y));
    typedef void (*SetWindowLocation)(CGEventRef,double,double);
    SetWindowLocation setLocation=(SetWindowLocation)dlsym(RTLD_DEFAULT,"CGEventSetWindowLocation");
    if (!setLocation) { record(@{@"error":@"CGEventSetWindowLocation unavailable"}); CFRelease(copy); return; }
    // This fixture uses a 28-point title bar on the tested macOS version.
    setLocation(copy,projected.x-recipientOrigin.x,projected.y-recipientOrigin.y+(externalTarget?0:28));
    CGEventSetIntegerValueField(copy,kCGMouseEventSubtype,0);
    CGEventSetIntegerValueField(copy,(CGEventField)58,1);
    CGEventSetIntegerValueField(copy,kCGMouseEventWindowUnderMousePointer,recipientWindow);
    CGEventSetIntegerValueField(copy,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,recipientWindow);
    CGEventSetIntegerValueField(copy,kCGEventSourceUserData,0x50414e45);
    CGEventPostToPid(destination,copy); CFRelease(copy);
    CGPoint actual=pointer();
    record(@{@"forward":@(e.type),@"recipientWindow":@(recipientWindow),@"target":@[@(projected.x),@(projected.y)],@"pointer":@[@(actual.x),@(actual.y)]});
}
- (void)keyDown:(NSEvent *)e {
    if (host && activateTarget==2) {
        CGEventRef event=CGEventCreateCopy(e.CGEvent);
        CGEventSetIntegerValueField(event,kCGEventTargetUnixProcessID,destination);
        CGEventSetIntegerValueField(event,(CGEventField)51,targetWindow);
        CGEventPostToPid(destination,event); CFRelease(event);
        record(@{@"forwardKey":@YES});
    } else [super keyDown:e];
}
- (void)mouseMoved:(NSEvent *)e { if(host) [self forward:e]; }
- (void)rightMouseDown:(NSEvent *)e { if(host) [self forward:e]; }
- (void)rightMouseUp:(NSEvent *)e { if(host) [self forward:e]; }
- (void)rightMouseDragged:(NSEvent *)e { if(host) [self forward:e]; }
- (void)mouseDown:(NSEvent *)e { if(host) [self forward:e]; else { self.downs++; record(@{@"dragDown":@(self.downs)}); } }
- (void)mouseDragged:(NSEvent *)e { if(host) [self forward:e]; else { self.drags++; record(@{@"dragMove":@(self.drags)}); } }
- (void)mouseUp:(NSEvent *)e { if(host) [self forward:e]; else { self.ups++; record(@{@"dragUp":@(self.ups)}); } }
@end
@interface Delegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property NSTextField *field;
@property NSPanel *overlay;
@end
@implementation Delegate
- (void)overlayClick:(id)sender { record(@{@"overlayClick":@YES}); }
- (void)clicked:(id)sender { record(@{@"button":@YES}); }
- (void)controlTextDidChange:(NSNotification *)note { record(@{@"text":self.field.stringValue}); }
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSArray *args=NSProcessInfo.processInfo.arguments;
    if(host) activateTarget=[args[9] integerValue];
    NSDictionary *external=host?[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"target-state.json"]] options:0 error:nil]:nil;
    externalTarget=[external[@"external"] boolValue];
    viewportSize=externalTarget?CGSizeMake([external[@"size"][0] doubleValue],[external[@"size"][1] doubleValue]):CGSizeMake(400,260);
    CGPoint origin=CGPointMake([args[3] doubleValue],[args[4] doubleValue]);
    CGFloat h=CGDisplayBounds(CGMainDisplayID()).size.height;
    window=[[ProbeWindow alloc] initWithContentRect:NSMakeRect(origin.x,h-origin.y-viewportSize.height,viewportSize.width,viewportSize.height) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|((host && activateTarget==3)?NSWindowStyleMaskNonactivatingPanel:0) backing:NSBackingStoreBuffered defer:NO];
    window.acceptsMouseMovedEvents=YES;
    window.title=host?@"Panelet input projection prototype":@"Panelet input target";
    window.releasedWhenClosed=NO;
    if(host) { window.level=NSFloatingWindowLevel; ((NSPanel *)window).hidesOnDeactivate=NO; }
    Surface *surface=[[Surface alloc] initWithFrame:NSMakeRect(0,0,viewportSize.width,viewportSize.height)];
    window.contentView=surface;
    if(externalTarget) [surface registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    if(host) {
        destination=[args[5] intValue]; targetWindow=[args[6] integerValue];
        targetOrigin=CGPointMake([args[7] doubleValue],[args[8] doubleValue]); activateTarget=[args[9] integerValue];
        surface.image=[[NSImage alloc] initWithContentsOfFile:[directory stringByAppendingPathComponent:@"target.png"]];
    } else {
        NSButton *button=[NSButton buttonWithTitle:@"Count click" target:self action:@selector(clicked:)];
        button.frame=NSMakeRect(25,25,150,36); [surface addSubview:button];
        self.field=[[NSTextField alloc] initWithFrame:NSMakeRect(25,80,340,30)];
        self.field.placeholderString=@"Type here"; self.field.delegate=self; [surface addSubview:self.field];
    }
    [window makeFirstResponder:surface];
    [window makeKeyAndOrderFront:nil]; if (!(host && activateTarget==3)) [NSApp activateIgnoringOtherApps:YES];
    [window setFrameOrigin:NSMakePoint(origin.x,h-origin.y-viewportSize.height)];
    NSDictionary *state=@{@"pid":@(getpid()),@"window":@(window.windowNumber),@"origin":@[@(origin.x),@(origin.y)]};
    [[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:host?@"host-state.json":@"target-state.json"] atomically:YES];
    [NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) {
        if (host && !self.overlay && [[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:@"show-overlay"]]) {
            self.overlay=[[NSPanel alloc] initWithContentRect:NSMakeRect(520,h-400,180,80) styleMask:NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
            self.overlay.level=NSFloatingWindowLevel+1; self.overlay.hidesOnDeactivate=NO;
            NSButton *button=[NSButton buttonWithTitle:@"Native overlay" target:self action:@selector(overlayClick:)]; button.frame=NSMakeRect(0,0,180,80);
            [self.overlay.contentView addSubview:button]; [self.overlay orderFrontRegardless]; record(@{@"overlayShown":@YES});
        }
        NSRect content=[window convertRectToScreen:window.contentView.bounds];
        NSDictionary *current=@{@"pid":@(getpid()),@"window":@(window.windowNumber),@"origin":@[@(content.origin.x),@(h-NSMaxY(content))],@"text":self.field.stringValue?:@"",@"editing":@(self.field.currentEditor!=nil),@"key":@(window.keyWindow),@"active":@(NSApp.active),@"responder":NSStringFromClass([window.firstResponder class])?:@""};
        [[NSJSONSerialization dataWithJSONObject:current options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:host?@"host-state.json":@"target-state.json"] atomically:YES];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:host?@"stop-host":@"stop-target"]]) [NSApp terminate:nil];
    }];
}
@end

static int printTextEditWindow(NSString *title) {
    pid_t pid = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TextEdit"].firstObject.processIdentifier;
    NSArray<NSDictionary *> *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *entry in windows) {
        if (pid == 0 || [entry[(__bridge NSString *)kCGWindowOwnerPID] intValue] != pid ||
            [entry[(__bridge NSString *)kCGWindowLayer] intValue] != 0 ||
            ![entry[(__bridge NSString *)kCGWindowName] isEqual:title]) continue;
        NSNumber *number = entry[(__bridge NSString *)kCGWindowNumber];
        CGRect frame;
        if (!number || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)entry[(__bridge NSString *)kCGWindowBounds], &frame)) continue;
        [matches addObject:@{
            @"pid": @(pid), @"window": number, @"external": @YES,
            @"origin": @[@(frame.origin.x), @(frame.origin.y)],
            @"size": @[@(frame.size.width), @(frame.size.height)]
        }];
    }
    if (matches.count != 1) {
        fputs("Make one visible TextEdit test window with the exact title on a virtual display.\n", stderr);
        return 2;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:matches.firstObject options:0 error:nil];
    if (!json) return 2;
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
}

int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--textedit-window") == 0) return printTextEditWindow(@(argv[2]));
        if (argc < 2) return 2;
        host = strcmp(argv[1], "host") == 0;
        if (host ? argc != 10 : argc != 5 || strcmp(argv[1], "target") != 0) return 2;
        directory = @(argv[2]);
        [[NSFileManager defaultManager] createFileAtPath:[directory stringByAppendingPathComponent:host?@"host.jsonl":@"target.jsonl"] contents:nil attributes:nil];
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) Delegate *delegate = Delegate.new;
        NSApp.delegate = delegate;
        [NSApp run];
    }
}
