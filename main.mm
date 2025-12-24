/*
 ===========================================================================
 运行环境: macOS 15.0+ (Sequoia)
 优化目标: 修复全屏布局错位, 去除图标简化UI, 保持 Metal GPU 极低功耗
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
static NSString *g_apiKey = @"key"; 
const BOOL USE_PROXY = NO;
NSString *const PROXY_HOST = @"127.0.0.1";
const int PROXY_PORT = 7890; 
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
    config.allowsExpensiveNetworkAccess = YES;
    config.waitsForConnectivity = YES; 
    config.networkServiceType = NSURLNetworkServiceTypeBackground; 
    self.session = [NSURLSession sessionWithConfiguration:config];
}

- (void)setupUI {
    NSView *containerView = self.window.contentView;
    containerView.wantsLayer = YES;

    // 背景模糊层 (GPU)
    NSVisualEffectView *vibrantView = [[NSVisualEffectView alloc] initWithFrame:containerView.bounds];
    vibrantView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    vibrantView.material = NSVisualEffectMaterialHeaderView; 
    vibrantView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    vibrantView.state = NSVisualEffectStateActive;
    [containerView addSubview:vibrantView];

    // ------------------------------------------------------
    // 滚动区域 (占据大部分空间)
    // ------------------------------------------------------
    // 底部留出 60px 给输入框和按钮
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 80, 860, 600)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSNoBorder;
    // 高度可变，宽度可变，底部距离固定（即底部向上拉伸）
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    scrollView.wantsLayer = YES;
    scrollView.drawsBackground = NO;
    scrollView.contentView.wantsLayer = YES; // 关键：GPU 滚动
    
    self.outputTextView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
    self.outputTextView.editable = NO;
    self.outputTextView.font = [NSFont systemFontOfSize:14];
    self.outputTextView.textColor = [NSColor labelColor];
    self.outputTextView.drawsBackground = NO;
    
    self.outputTextView.layoutManager.allowsNonContiguousLayout = YES; 
    self.outputTextView.layoutManager.backgroundLayoutEnabled = YES; 
    self.outputTextView.autoresizingMask = NSViewWidthSizable;
    
    scrollView.documentView = self.outputTextView;
    [vibrantView addSubview:scrollView]; 
    
    // ------------------------------------------------------
    // 底部控制区域 (布局修正版)
    // ------------------------------------------------------
    CGFloat bottomMargin = 25;
    CGFloat buttonHeight = 32;
    CGFloat spacing = 10;
    
    // 1. Send 按钮 (最右侧，锚定右边)
    NSButton *sendBtn = [NSButton buttonWithTitle:@"Send" target:self action:@selector(onSendClicked)];
    sendBtn.bezelStyle = NSBezelStyleRounded;
    sendBtn.keyEquivalent = @"\r";
    sendBtn.wantsLayer = YES;
    [sendBtn sizeToFit]; // 自动计算文字宽度
    
    // 手动调整一下宽度使其稍微宽一点
    NSRect sendFrame = sendBtn.frame;
    sendFrame.size.width = 80; 
    sendFrame.size.height = buttonHeight;
    sendFrame.origin.y = bottomMargin;
    // X 坐标 = 容器宽度 - 按钮宽度 - 右边距
    sendFrame.origin.x = NSWidth(containerView.bounds) - sendFrame.size.width - 20;
    sendBtn.frame = sendFrame;
    // 关键：左边距可变(NSViewMinXMargin) = 靠右固定
    sendBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.sendButton = sendBtn;
    [vibrantView addSubview:sendBtn];
    
    // 2. Clear 按钮 (在 Send 左边)
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(onClearClicked)];
    clearBtn.bezelStyle = NSBezelStyleRounded;
    clearBtn.wantsLayer = YES;
    NSRect clearFrame = NSMakeRect(0, bottomMargin, 60, buttonHeight);
    clearFrame.origin.x = sendFrame.origin.x - clearFrame.size.width - spacing;
    clearBtn.frame = clearFrame;
    clearBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; // 靠右
    [vibrantView addSubview:clearBtn];
    
    // 3. Upload 按钮 (在 Clear 左边)
    self.uploadButton = [NSButton buttonWithTitle:@"Upload" target:self action:@selector(onUploadClicked)];
    self.uploadButton.bezelStyle = NSBezelStyleRounded;
    self.uploadButton.wantsLayer = YES;
    NSRect uploadFrame = NSMakeRect(0, bottomMargin, 70, buttonHeight);
    uploadFrame.origin.x = clearFrame.origin.x - uploadFrame.size.width - spacing;
    self.uploadButton.frame = uploadFrame;
    self.uploadButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; // 靠右
    [vibrantView addSubview:self.uploadButton];
    
    // 4. 输入框 (剩余空间，锚定左边，宽度拉伸)
    CGFloat inputX = 20;
    // 宽度 = Upload按钮的左边缘 - 输入框左边缘 - 间距
    CGFloat inputWidth = uploadFrame.origin.x - inputX - spacing;
    
    self.inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(inputX, bottomMargin, inputWidth, buttonHeight)];
    self.inputField.placeholderString = @"Type message here...";
    self.inputField.font = [NSFont systemFontOfSize:14];
    self.inputField.bezelStyle = NSTextFieldRoundedBezel;
    self.inputField.focusRingType = NSFocusRingTypeDefault;
    self.inputField.target = self;
    self.inputField.action = @selector(onSendClicked);
    
    self.inputField.wantsLayer = YES;
    self.inputField.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    
    // 关键：宽度可变(NSViewWidthSizable) = 跟随窗口拉伸
    self.inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    
    [vibrantView addSubview:self.inputField];
}

- (void)appendLog:(NSString *)text color:(NSColor *)color {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSDictionary *attrs = @{
            NSForegroundColorAttributeName: color,
            NSFontAttributeName: [NSFont systemFontOfSize:14]
        };
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n\n"] attributes:attrs];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTextStorage *storage = self.outputTextView.textStorage;
            [storage beginEditing];
            [storage appendAttributedString:as];
            [storage endEditing];
            [self.outputTextView scrollRangeToVisible:NSMakeRange(storage.length, 0)];
        });
    });
}

- (void)callGeminiAPI {
    self.sendButton.enabled = NO;
    // 告诉系统：用户正在等待，请勿 App Nap
    self.activityToken = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityAutomaticTerminationDisabled reason:@"Gemini API Request"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *urlString = [MODEL_ENDPOINT stringByAppendingString:g_apiKey];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        NSDictionary *payload = @{@"contents": self.chatHistory};
        NSData *httpBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        request.HTTPBody = httpBody;

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
                } @catch (NSException *e) {}
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.sendButton.enabled = YES;
            });
        }] resume];
    });
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
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
                if (content) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendLog:[NSString stringWithFormat:@"[File: %@]", url.lastPathComponent] color:[NSColor systemGreenColor]];
                        [self addToHistoryWithRole:@"user" text:content];
                        [self callGeminiAPI];
                    });
                }
            });
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

