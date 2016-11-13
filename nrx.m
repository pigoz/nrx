#import <mpv/client.h>
#import <mpv/opengl_cb.h>

#import <OpenGL/gl.h>
#import <stdio.h>
#import <stdlib.h>

#import <Cocoa/Cocoa.h>

static inline void check_error(int status)
{
    if (status < 0) {
        printf("mpv API error: %s\n", mpv_error_string(status));
        exit(1);
    }
}

static void* get_proc_address(void* ctx, const char* name)
{
    CFStringRef symbol = CFStringCreateWithCString(
        kCFAllocatorDefault, name, kCFStringEncodingASCII);
    void* addr = CFBundleGetFunctionPointerForName(
        CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl")), symbol);
    CFRelease(symbol);
    return addr;
}

static void glupdate(void* ctx);

@interface VideoView : NSOpenGLView
@property mpv_opengl_cb_context* glctx;
- (instancetype)initWithFrame:(NSRect)frame;
@end

@implementation VideoView
- (instancetype)initWithFrame:(NSRect)frame
{
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion4_1Core,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFANoRecovery,
        0
    };
    self = [super initWithFrame:frame
                    pixelFormat:[[NSOpenGLPixelFormat alloc]
                                    initWithAttributes:attributes]];

    if (self) {
        [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        GLint swapInt = 1;
        [[self openGLContext] setValues:&swapInt
                       forParameter:NSOpenGLCPSwapInterval];
        [[self openGLContext] makeCurrentContext];
        self.glctx = nil;
    }

    return self;
}

- (void)drawRect:(NSRect)dirtyRect
{
    if (self.glctx) {
        mpv_opengl_cb_draw(
            self.glctx, 0, self.bounds.size.width, -self.bounds.size.height);
    } else {
        // fill black
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    [[self openGLContext] flushBuffer];

    if (self.glctx) {
        mpv_opengl_cb_report_flip(self.glctx, 0);
    }
}
@end

@interface VideoWindow : NSWindow
@property (retain, readonly) VideoView* videoView;
@end

@implementation VideoWindow
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)initVideoView
{
    NSRect bounds = [[self contentView] bounds];
    _videoView = [[VideoView alloc] initWithFrame:bounds];
    [self.contentView addSubview:_videoView];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    mpv_handle* mpv;
    dispatch_queue_t queue;
    VideoWindow* window;
}
@end

static void wakeup(void*);

@implementation AppDelegate

- (void)createWindow
{
    int mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    window =
        [[VideoWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 720)
                                       styleMask:mask
                                         backing:NSBackingStoreBuffered
                                           defer:NO];

    // force a minimum size to stop opengl from exploding.
    [window setMinSize:NSMakeSize(200, 200)];
    [window initVideoView];
    [window setTitle:@"nrx"];
    [window makeMainWindow];
    [window makeKeyAndOrderFront:nil];

    NSMenu* m = [[NSMenu alloc] initWithTitle:@"AMainMenu"];
    NSMenuItem* item =
        [m addItemWithTitle:@"Apple" action:nil keyEquivalent:@""];
    NSMenu* sm = [[NSMenu alloc] initWithTitle:@"Apple"];
    [m setSubmenu:sm forItem:item];
    [sm addItemWithTitle:@"quit"
                  action:@selector(terminate:)
           keyEquivalent:@"q"];
    [NSApp setMenu:m];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    atexit_b(^{
        // Because activation policy has just been set to behave like a real
        // application, that policy must be reset on exit to prevent, among
        // other things, the menubar created here from remaining on screen.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    });

    // Read filename
    NSArray* args = [NSProcessInfo processInfo].arguments;
    if (args.count < 2) {
        NSLog(@"Expected filename on command line");
        exit(1);
    }
    NSString* filename = args[1];

    [self createWindow];

    mpv = mpv_create();
    if (!mpv) {
        printf("failed creating context\n");
        exit(1);
    }

    check_error(mpv_set_option_string(mpv, "terminal", "yes"));
    check_error(mpv_set_option_string(mpv, "msg-level", "all=v"));
    // check_error(mpv_request_log_messages(mpv, "warn"));

    check_error(mpv_initialize(mpv));
    check_error(mpv_set_option_string(mpv, "vo", "opengl-cb"));

    mpv_opengl_cb_context* glctx = mpv_get_sub_api(mpv, MPV_SUB_API_OPENGL_CB);
    if (!glctx) {
        puts("libmpv does not have the opengl-cb sub-API.");
        exit(1);
    }

    // pass the glctx context to our view
    window.videoView.glctx = glctx;
    int r = mpv_opengl_cb_init_gl(glctx, NULL, get_proc_address, NULL);
    if (r < 0) {
        puts("gl init has failed.");
        exit(1);
    }
    mpv_opengl_cb_set_update_callback(
        glctx, glupdate, (__bridge void*)window.videoView);

    // Deal with MPV in the background.
    queue = dispatch_queue_create("mpv", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        // Register to be woken up whenever mpv generates new events.
        mpv_set_wakeup_callback(mpv, wakeup, (__bridge void*)self);
        // Load the indicated file
        const char* cmd[] = { "loadfile", filename.UTF8String, NULL };
        check_error(mpv_command(mpv, cmd));
    });
}

static void glupdate(void* ctx)
{
    VideoView* videoView = (__bridge VideoView*)ctx;
    [videoView setNeedsDisplay:YES];
}

- (void)handleEvent:(mpv_event*)event
{
    switch (event->event_id) {
    case MPV_EVENT_LOG_MESSAGE: {
        struct mpv_event_log_message* msg
            = (struct mpv_event_log_message*)event->data;
        printf("[%s] %s: %s", msg->prefix, msg->level, msg->text);
    }

    default:
        printf("event: %s\n", mpv_event_name(event->event_id));
    }
}

- (void)readEvents
{
    dispatch_async(queue, ^{
        while (mpv) {
            mpv_event* event = mpv_wait_event(mpv, 0);
            if (event->event_id == MPV_EVENT_NONE)
                break;
            [self handleEvent:event];
        }
    });
}

static void wakeup(void* context)
{
    AppDelegate* a = (__bridge AppDelegate*)context;
    [a readEvents];
}

// quit when the window is closed.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app
{
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
    NSLog(@"Terminating.");
    mpv_opengl_cb_context* tmp = window.videoView.glctx;
    window.videoView.glctx = NULL;
    mpv_opengl_cb_set_update_callback(tmp, NULL, NULL);
    mpv_opengl_cb_uninit_gl(tmp);
    mpv_detach_destroy(mpv);
    return NSTerminateNow;
}

@end

// Delete this if you already have a main.m.
int main(int argc, const char* argv[])
{
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
