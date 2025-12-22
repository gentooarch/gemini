/*
 ===========================================================================
 运行环境: macOS 12.0+ 
 编译命令: 
 clang++ -fobjc-arc -framework Cocoa -framework Foundation -framework UniformTypeIdentifiers main.mm -o GeminiApp
 
 运行方式:
 1. 使用默认Key: ./GeminiApp
 2. 使用临时Key: ./GeminiApp 你的API_KEY_在这里
 ===========================================================================
 */

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ==========================================
// 1. 全局配置
// ==========================================

static NSString *g_apiKey = @"key"; 

const BOOL USE_PROXY = NO;
NSString *const PROXY_HOST = @"127.0.0.1";
const int PROXY_PORT = 7890; 

// 使用最新的 Gemini 2.0 Flash 模型以获得更好的性能
NSString *const MODEL_ENDPOINT = @"https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=";

// ==========================================
// 2. UI 控制器
// ==========================================

@interface MainWindowController : NSWindowController 
@property (strong) NSMutableArray<NSDictionary *> *chatHistory; // 存储对话历史
@property (strong) NSTextView *outputTextView;
@property (strong) NSTextField *inputField;
@property (strong) NSButton *sendButton;
@property (strong) NSButton *uploadButton;
@property (strong) NSURLSession *session; // 复用 Session
@end

@implementation MainWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 900, 700);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Native Gemini (High Performance)";
    window.minSize = NSMakeSize(600, 500);
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
        // 使用现代字符串 Key 消除弃用警告
        config.connectionProxyDictionary = @{
            @"HTTPEnable":  @YES,
            @"HTTPProxy":   PROXY_HOST,
            @"HTTPPort":    @(PROXY_PORT),
            @"HTTPSEnable": @YES,
            @"HTTPSProxy":  PROXY_HOST,
            @"HTTPSPort":   @(PROXY_PORT)
        };
    }
    // 复用 Session 以利用 HTTP Keep-Alive 减少握手延迟
    self.session = [NSURLSession sessionWithConfiguration:config];
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;
    
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 75, 860, 605)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    self.outputTextView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
    self.outputTextView.editable = NO;
    self.outputTextView.font = [NSFont systemFontOfSize:14];
    self.outputTextView.autoresizingMask = NSViewWidthSizable;
    
    scrollView.documentView = self.outputTextView;
    [contentView addSubview:scrollView];
    
    self.inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 20, 500, 35)];
    self.inputField.placeholderString = @"Ask something or upload a file...";
    self.inputField.font = [NSFont systemFontOfSize:14];
    self.inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.inputField.target = self;
    self.inputField.action = @selector(onSendClicked);
    [contentView addSubview:self.inputField];
    
    self.uploadButton = [NSButton buttonWithTitle:@"📎 Upload" target:self action:@selector(onUploadClicked)];
    self.uploadButton.frame = NSMakeRect(530, 20, 100, 35);
    self.uploadButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.uploadButton.bezelStyle = NSBezelStyleRounded;
    [contentView addSubview:self.uploadButton];

    NSButton *clearBtn = [NSButton buttonWithTitle:@"🗑️ Clear" target:self action:@selector(onClearClicked)];
    clearBtn.frame = NSMakeRect(635, 20, 90, 35);
    clearBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    clearBtn.bezelStyle = NSBezelStyleRounded;
    [contentView addSubview:clearBtn];

    self.sendButton = [NSButton buttonWithTitle:@"➤ Send" target:self action:@selector(onSendClicked)];
    self.sendButton.frame = NSMakeRect(730, 20, 150, 35);
    self.sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.sendButton.bezelStyle = NSBezelStyleRounded;
    [contentView addSubview:self.sendButton];
}

- (void)appendLog:(NSString *)text color:(NSColor *)color {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *attrs = @{NSForegroundColorAttributeName: color, NSFontAttributeName: [NSFont systemFontOfSize:14]};
        NSAttributedString *attrString = [[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n\n"] attributes:attrs];
        [self.outputTextView.textStorage appendAttributedString:attrString];
        [self.outputTextView scrollRangeToVisible:NSMakeRange(self.outputTextView.string.length, 0)];
    });
}

- (void)addToHistoryWithRole:(NSString *)role text:(NSString *)text {
    // 构造 Gemini 要求的 JSON 结构：{"role":"...", "parts":[{"text":"..."}]}
    [_chatHistory addObject:@{
        @"role": role,
        @"parts": @[@{@"text": text}]
    }];
}

- (void)onClearClicked {
    [_chatHistory removeAllObjects];
    self.outputTextView.string = @"";
    [self appendLog:@"[System] Chat history cleared." color:[NSColor systemGrayColor]];
}

- (void)onUploadClicked {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    if (@available(macOS 12.0, *)) {
        panel.allowedContentTypes = @[UTTypePlainText, UTTypeSourceCode, UTTypeJSON];
    }

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = [[panel URLs] firstObject];
            
            // 性能优化：在后台线程读取文件，避免阻塞 UI
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSError *error;
                NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) {
                        [self appendLog:[@"Error reading file: " stringByAppendingString:error.localizedDescription] color:[NSColor systemRedColor]];
                        return;
                    }
                    
                    NSString *fileName = [url lastPathComponent];
                    [self appendLog:[NSString stringWithFormat:@"[File: %@ Uploaded]", fileName] color:[NSColor systemGreenColor]];
                    
                    NSString *prompt = [NSString stringWithFormat:@"Uploaded File Content (%@):\n---\n%@\n---\nPlease summarize this file.", fileName, content];
                    [self addToHistoryWithRole:@"user" text:prompt];
                    [self callGeminiAPI];
                });
            });
        }
    }];
}

- (void)onSendClicked {
    NSString *prompt = self.inputField.stringValue;
    if (prompt.length == 0) return;
    
    [self appendLog:[NSString stringWithFormat:@"You: %@", prompt] color:[NSColor systemBlueColor]];
    [self addToHistoryWithRole:@"user" text:prompt];
    self.inputField.stringValue = @"";
    [self callGeminiAPI];
}

- (void)callGeminiAPI {
    self.sendButton.enabled = NO;
    self.uploadButton.enabled = NO;

    NSString *urlString = [MODEL_ENDPOINT stringByAppendingString:g_apiKey];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    // 性能优化：直接使用系统级序列化，自动处理字符转义，效率极高
    NSDictionary *payload = @{@"contents": _chatHistory};
    NSData *httpBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    request.HTTPBody = httpBody;

    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sendButton.enabled = YES;
            self.uploadButton.enabled = YES;
            
            if (error) {
                [self appendLog:[@"Network Error: " stringByAppendingString:error.localizedDescription] color:[NSColor systemRedColor]];
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            
            // 防御性编程：安全解析嵌套的 JSON
            if (json[@"error"]) {
                [self appendLog:[NSString stringWithFormat:@"API Error: %@", json[@"error"][@"message"]] color:[NSColor systemRedColor]];
            } else {
                @try {
                    NSArray *candidates = json[@"candidates"];
                    if (candidates.count > 0) {
                        NSString *text = candidates[0][@"content"][@"parts"][0][@"text"];
                        if (text) {
                            [self appendLog:[NSString stringWithFormat:@"Gemini: %@", text] color:[NSColor labelColor]];
                            [self addToHistoryWithRole:@"model" text:text];
                        }
                    }
                } @catch (NSException *e) {
                    [self appendLog:@"[Error] Unexpected response format from API." color:[NSColor systemOrangeColor]];
                }
            }
        });
    }] resume];
}
@end

// ==========================================
// 3. App Delegate & Main
// ==========================================

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) MainWindowController *mainWindowController;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)a {
    // 设置简单的菜单
    NSMenu *menubar = [NSMenu new];
    NSMenuItem *appMenuItem = [NSMenuItem new];
    [menubar addItem:appMenuItem];
    [NSApp setMainMenu:menubar];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];

    NSMenuItem *editMenuItem = [NSMenuItem new];
    [menubar addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];

    self.mainWindowController = [[MainWindowController alloc] init];
    [self.mainWindowController showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            g_apiKey = [NSString stringWithUTF8String:argv[1]];
            printf("[Config] Using API Key from command line.\n");
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
