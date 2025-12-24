/*
 ===========================================================================
 运行环境: macOS 15.0+ (Sequoia)
 优化目标: 修复全屏布局与文字复制, 去除图标简化UI, 保持 Metal GPU 极低功耗
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
// 建议使用正式模型名如 gemini-1.5-flash
NSString *const MODEL_ENDPOINT = @"https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=";

// ==========================================
// 2. UI 控制器
// ==========================================
@interface MainWindowController : NSWindowController 
@property (strong) NSMutableArray<NSDictionary *> *chatHistory;
@property (strong) NSTextView *outputTextView;
@property (strong) NSTextField *inputField;
@property (strong) NSButton *sendButton;
@property (strong) NSButton *uploadButton;
@property (strong) NSURLSession *session;
@property (strong) id activityToken;
@end

@implementation MainWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 900, 700);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView;
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Gemini Native";
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = [NSColor clearColor]; 
    window.opaque = NO; 
    window.minSize = NSMakeSize(600, 400);
    [window center];
    
    self = [super initWithWindow:window];
    if (self) {
        _chatHistory = [NSMutableArray array];
        [self setupNetworkSession];
        [self setupUI];
    }
    return self;
}

- (void)setupNetworkSession {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
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

    // 背景模糊层 (GPU 加速)
    NSVisualEffectView *vibrantView = [[NSVisualEffectView alloc] initWithFrame:containerView.bounds];
    vibrantView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    vibrantView.material = NSVisualEffectMaterialUnderWindowBackground; 
    vibrantView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    vibrantView.state = NSVisualEffectStateActive;
    [containerView addSubview:vibrantView];

    // 1. 滚动区域
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 85, 860, 580)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    // 2. 文本显示区 (关键修复：selectable = YES)
    self.outputTextView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
    self.outputTextView.editable = NO;
    self.outputTextView.selectable = YES; // 允许选中复制
    self.outputTextView.font = [NSFont systemFontOfSize:14];
    self.outputTextView.textColor = [NSColor labelColor];
    self.outputTextView.drawsBackground = NO;
    self.outputTextView.verticallyResizable = YES;
    self.outputTextView.horizontallyResizable = NO;
    self.outputTextView.autoresizingMask = NSViewWidthSizable;
    self.outputTextView.textContainer.widthTracksTextView = YES;
    
    scrollView.documentView = self.outputTextView;
    [vibrantView addSubview:scrollView]; 
    
    // 3. 底部控制栏
    CGFloat bottomMargin = 25;
    CGFloat buttonHeight = 32;
    CGFloat spacing = 10;
    
    // Send 按钮
    self.sendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(onSendClicked)];
    self.sendButton.bezelStyle = NSBezelStyleRounded;
    self.sendButton.keyEquivalent = @"\r"; // 回车触发
    NSRect sendFrame = NSMakeRect(NSWidth(containerView.bounds) - 100, bottomMargin, 80, buttonHeight);
    self.sendButton.frame = sendFrame;
    self.sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [vibrantView addSubview:self.sendButton];
    
    // Clear 按钮
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(onClearClicked)];
    clearBtn.bezelStyle = NSBezelStyleRounded;
    NSRect clearFrame = NSMakeRect(sendFrame.origin.x - 70 - spacing, bottomMargin, 70, buttonHeight);
    clearBtn.frame = clearFrame;
    clearBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [vibrantView addSubview:clearBtn];
    
    // Upload 按钮
    self.uploadButton = [NSButton buttonWithTitle:@"Upload" target:self action:@selector(onUploadClicked)];
    self.uploadButton.bezelStyle = NSBezelStyleRounded;
    NSRect uploadFrame = NSMakeRect(clearFrame.origin.x - 80 - spacing, bottomMargin, 80, buttonHeight);
    self.uploadButton.frame = uploadFrame;
    self.uploadButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [vibrantView addSubview:self.uploadButton];
    
    // 输入框
    CGFloat inputWidth = uploadFrame.origin.x - 20 - spacing;
    self.inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, bottomMargin, inputWidth, buttonHeight)];
    self.inputField.placeholderString = @"Type message here...";
    self.inputField.font = [NSFont systemFontOfSize:14];
    self.inputField.bezelStyle = NSTextFieldRoundedBezel;
    self.inputField.target = self;
    self.inputField.action = @selector(onSendClicked);
    self.inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [vibrantView addSubview:self.inputField];
}

- (void)appendLog:(NSString *)text color:(NSColor *)color {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *attrs = @{
            NSForegroundColorAttributeName: color,
            NSFontAttributeName: [NSFont systemFontOfSize:14]
        };
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

    NSDictionary *payload = @{@"contents": self.chatHistory};
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (self.activityToken) {
            [[NSProcessInfo processInfo] endActivity:self.activityToken];
            self.activityToken = nil;
        }

        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            @try {
                NSString *resText = json[@"candidates"][0][@"content"][@"parts"][0][@"text"];
                if (resText) {
                    [self appendLog:[@"Gemini: " stringByAppendingString:resText] color:[NSColor labelColor]];
                    [self addToHistoryWithRole:@"model" text:resText];
                }
            } @catch (NSException *e) {
                [self appendLog:@"[Error: Invalid response from API]" color:[NSColor systemRedColor]];
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sendButton.enabled = YES;
        });
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
    [self appendLog:[@"You: " stringByAppendingString:prompt] color:[NSColor systemBlueColor]];
    [self addToHistoryWithRole:@"user" text:prompt];
    self.inputField.stringValue = @"";
    [self callGeminiAPI];
}

- (void)onUploadClicked {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypePlainText, UTTypeSourceCode];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = [panel URLs].firstObject;
            NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
            if (content) {
                [self appendLog:[NSString stringWithFormat:@"[File: %@]", url.lastPathComponent] color:[NSColor systemGreenColor]];
                [self addToHistoryWithRole:@"user" text:content];
                [self callGeminiAPI];
            }
        }
    }];
}
@end

// ==========================================
// 3. App Delegate (添加菜单栏支持)
// ==========================================
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) MainWindowController *mwc;
@end

@implementation AppDelegate

- (void)setupMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    
    // 1. App Menu
    NSMenuItem *appMenuItem = [mainMenu addItemWithTitle:@"App" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    
    // 2. Edit Menu (关键：有了这个 Cmd+C 才能生效)
    NSMenuItem *editMenuItem = [mainMenu addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];
    
    [NSApp setMainMenu:mainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)a {
    [self setupMenuBar];
    self.mwc = [[MainWindowController alloc] init];
    [self.mwc showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
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
