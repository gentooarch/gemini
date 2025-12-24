/*
 ===========================================================================
 运行环境: macOS 15.0+ (Sequoia)
 优化目标: 
 1. 修复编译错误 (NSOpenPanel)
 2. 零磁盘缓存：所有网络请求、Cookie、窗口状态均只驻留在内存。
 3. 低功耗：利用 Metal GPU 进行毛玻璃渲染。
 4. 交互：支持 Cmd+C/V/A。
 编译命令: 
 clang++ -O3 -flto -fobjc-arc -framework Cocoa -framework Foundation -framework QuartzCore -framework UniformTypeIdentifiers main.mm -o GeminiApp
 ===========================================================================
 */

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>

// ==========================================
// 1. 全局配置
// ==========================================
static NSString *g_apiKey = @"YOUR_API_KEY_HERE"; 
const BOOL USE_PROXY = NO;
NSString *const PROXY_HOST = @"127.0.0.1";
const int PROXY_PORT = 7890; 
NSString *const MODEL_ENDPOINT = @"https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=";

// ==========================================
// 2. 核心 UI 控制器
// ==========================================
@interface MainWindowController : NSWindowController <NSWindowDelegate>
@property (strong) NSMutableArray<NSDictionary *> *chatHistory;
@property (strong) NSTextView *outputTextView;
@property (strong) NSTextField *inputField;
@property (strong) NSButton *sendButton;
@property (strong) NSURLSession *session;
@property (strong) id activityToken;
@end

@implementation MainWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 900, 720);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView;
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Gemini RAM-Only";
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = [NSColor clearColor]; 
    window.hasShadow = YES;
    window.releasedWhenClosed = YES;
    
    // [内存优化] 彻底禁用窗口状态自动保存到磁盘
    window.restorable = NO;
    window.identifier = nil; 

    self = [super initWithWindow:window];
    if (self) {
        _chatHistory = [NSMutableArray array];
        [self setupNetworkSession];
        [self setupUI];
        window.delegate = self;
    }
    return self;
}

- (void)setupNetworkSession {
    // [内存优化] 使用临时会话，数据仅保留在内存
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    
    // 强制禁用磁盘缓存
    config.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:128 * 1024 * 1024 
                                                     diskCapacity:0 
                                                         diskPath:nil];
    
    config.HTTPCookieStorage = nil; 
    config.URLCredentialStorage = nil;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    // 强制不读取本地缓存，不写入本地缓存
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;

    if (USE_PROXY) {
        config.connectionProxyDictionary = @{
            @"HTTPEnable": @YES, @"HTTPProxy": PROXY_HOST, @"HTTPPort": @(PROXY_PORT),
            @"HTTPSEnable": @YES, @"HTTPSProxy": PROXY_HOST, @"HTTPSPort": @(PROXY_PORT)
        };
    }
    self.session = [NSURLSession sessionWithConfiguration:config];
}

- (void)setupUI {
    NSView *containerView = self.window.contentView;
    containerView.wantsLayer = YES; 

    NSVisualEffectView *vibrantView = [[NSVisualEffectView alloc] initWithFrame:containerView.bounds];
    vibrantView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    vibrantView.material = NSVisualEffectMaterialUnderWindowBackground; 
    vibrantView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    vibrantView.state = NSVisualEffectStateActive;
    [containerView addSubview:vibrantView];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 100, 860, 560)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    self.outputTextView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
    self.outputTextView.editable = NO;
    self.outputTextView.selectable = YES; 
    self.outputTextView.font = [NSFont systemFontOfSize:15];
    self.outputTextView.textColor = [NSColor labelColor];
    self.outputTextView.drawsBackground = NO;
    self.outputTextView.verticallyResizable = YES;
    self.outputTextView.horizontallyResizable = NO;
    self.outputTextView.autoresizingMask = NSViewWidthSizable;
    self.outputTextView.textContainer.widthTracksTextView = YES;
    self.outputTextView.textContainerInset = NSMakeSize(10, 10);
    
    scrollView.documentView = self.outputTextView;
    [vibrantView addSubview:scrollView]; 
    
    CGFloat bottomPos = 30;
    
    self.sendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(onSendClicked)];
    self.sendButton.bezelStyle = NSBezelStyleRounded;
    self.sendButton.keyEquivalent = @"\r"; 
    self.sendButton.frame = NSMakeRect(NSWidth(containerView.bounds) - 100, bottomPos, 80, 32);
    self.sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [vibrantView addSubview:self.sendButton];
    
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(onClearClicked)];
    clearBtn.bezelStyle = NSBezelStyleRounded;
    clearBtn.frame = NSMakeRect(NSWidth(containerView.bounds) - 180, bottomPos, 70, 32);
    clearBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [vibrantView addSubview:clearBtn];
    
    NSButton *upBtn = [NSButton buttonWithTitle:@"Upload" target:self action:@selector(onUploadClicked)];
    upBtn.bezelStyle = NSBezelStyleRounded;
    upBtn.frame = NSMakeRect(NSWidth(containerView.bounds) - 265, bottomPos, 80, 32);
    upBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [vibrantView addSubview:upBtn];
    
    self.inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, bottomPos, NSWidth(containerView.bounds) - 295, 32)];
    self.inputField.placeholderString = @"Ask Gemini (No-Disk Mode)...";
    self.inputField.font = [NSFont systemFontOfSize:14];
    self.inputField.bezelStyle = NSTextFieldRoundedBezel;
    self.inputField.target = self;
    self.inputField.action = @selector(onSendClicked);
    self.inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [vibrantView addSubview:self.inputField];
}

- (void)appendLog:(NSString *)text color:(NSColor *)color isBold:(BOOL)isBold {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSFont *font = isBold ? [NSFont boldSystemFontOfSize:15] : [NSFont systemFontOfSize:15];
        NSDictionary *attrs = @{ NSForegroundColorAttributeName: color, NSFontAttributeName: font };
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n\n"] attributes:attrs];
        [self.outputTextView.textStorage appendAttributedString:as];
        [self.outputTextView scrollRangeToVisible:NSMakeRange(self.outputTextView.textStorage.length, 0)];
    });
}

- (void)callGeminiAPI {
    self.sendButton.enabled = NO;
    self.activityToken = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated reason:@"Gemini API Request"];

    NSString *urlString = [MODEL_ENDPOINT stringByAppendingString:g_apiKey];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    // 增加头部指令：告诉所有中继和系统不要存储此请求
    [request setValue:@"no-store, no-cache, must-revalidate" forHTTPHeaderField:@"Cache-Control"];

    NSDictionary *payload = @{@"contents": self.chatHistory};
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sendButton.enabled = YES;
            if (self.activityToken) {
                [[NSProcessInfo processInfo] endActivity:self.activityToken];
                self.activityToken = nil;
            }
        });

        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            @try {
                NSString *resText = json[@"candidates"][0][@"content"][@"parts"][0][@"text"];
                if (resText) {
                    [self appendLog:@"Gemini:" color:[NSColor labelColor] isBold:YES];
                    [self appendLog:resText color:[NSColor labelColor] isBold:NO];
                    [self addToHistoryWithRole:@"model" text:resText];
                }
            } @catch (NSException *e) {
                [self appendLog:@"[Error]: Failed to parse API." color:[NSColor systemRedColor] isBold:NO];
            }
        }
    }] resume];
}

- (void)addToHistoryWithRole:(NSString *)role text:(NSString *)text {
    [_chatHistory addObject:@{@"role": role, @"parts": @[@{@"text": text}]}];
}

- (void)onClearClicked {
    [_chatHistory removeAllObjects];
    self.outputTextView.string = @"";
}

- (void)onSendClicked {
    NSString *prompt = self.inputField.stringValue;
    if (prompt.length == 0) return;
    [self appendLog:@"You:" color:[NSColor systemBlueColor] isBold:YES];
    [self appendLog:prompt color:[NSColor labelColor] isBold:NO];
    [self addToHistoryWithRole:@"user" text:prompt];
    self.inputField.stringValue = @"";
    [self callGeminiAPI];
}

- (void)onUploadClicked {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypePlainText, UTTypeSourceCode, UTTypeJSON];
    // 默认即不添加到最近文档 (仅在 NSDocument 应用中自动添加)
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = [panel URLs].firstObject;
            NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
            if (content) {
                [self appendLog:[NSString stringWithFormat:@"[File Uploaded: %@]", url.lastPathComponent] color:[NSColor systemGreenColor] isBold:YES];
                [self addToHistoryWithRole:@"user" text:content];
                [self callGeminiAPI];
            }
        }
    }];
}
@end

// ==========================================
// 3. App Delegate
// ==========================================
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) MainWindowController *mwc;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)a {
    // 彻底禁用系统的状态恢复功能
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSQuitAlwaysKeepsWindows"];
    
    [self setupMenuBar];
    self.mwc = [[MainWindowController alloc] init];
    [self.mwc showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)setupMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [mainMenu addItemWithTitle:@"App" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    
    NSMenuItem *editMenuItem = [mainMenu addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];
    [NSApp setMainMenu:mainMenu];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return NO; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc > 1) g_apiKey = [NSString stringWithUTF8String:argv[1]];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}

