/*
 ===========================================================================
 macOS Native Gemini Client (High Performance, Context-Aware, Debuggable)
 
 编译命令:
 clang++ main.mm -o GeminiApp -framework Cocoa -framework Security -std=c++17 -fobjc-arc
 
 运行:
 ./GeminiApp
 ===========================================================================
 */

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <iostream>

// ==========================================
// 1. 配置区域 (请在此处修改)
// ==========================================

// [必填] 替换为你的 Gemini API Key
const std::string API_KEY = "key";

// [可选] 如果你需要 VPN/代理才能访问 Google，请将此处设为 true 并修改端口
// 常规端口: Clash=7890, Surge=6152, v2ray=10809
const bool USE_PROXY = false;
const std::string PROXY_HOST = "127.0.0.1";
const int PROXY_PORT = 7890; 

const std::string MODEL_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=";

// ==========================================
// 2. C++ 逻辑层: 数据结构与 JSON 处理
// ==========================================

struct ChatMessage {
    std::string role; // "user" or "model"
    std::string text;
};

class GeminiClient {
public:
    // 手写 JSON 转义，保持极简依赖，性能极高
    static std::string escapeJSON(const std::string& input) {
        std::string output;
        output.reserve(input.length() + 20);
        for (char c : input) {
            switch (c) {
                case '"':  output += "\\\""; break;
                case '\\': output += "\\\\"; break;
                case '\b': output += "\\b"; break;
                case '\f': output += "\\f"; break;
                case '\n': output += "\\n"; break;
                case '\r': output += "\\r"; break;
                case '\t': output += "\\t"; break;
                default:   output += c;     break;
            }
        }
        return output;
    }

    // 将整个聊天历史打包成 JSON
    static NSString* buildRequestBody(const std::vector<ChatMessage>& history) {
        std::string json = "{\"contents\": [";
        
        for (size_t i = 0; i < history.size(); ++i) {
            const auto& msg = history[i];
            
            json += "{\"role\": \"";
            json += msg.role;
            json += "\", \"parts\": [{\"text\": \"";
            json += escapeJSON(msg.text);
            json += "\"}]}";
            
            if (i < history.size() - 1) {
                json += ",";
            }
        }
        
        json += "]}";
        return [NSString stringWithUTF8String:json.c_str()];
    }
};

// ==========================================
// 3. UI 控制器 (Objective-C)
// ==========================================

@interface MainWindowController : NSWindowController {
    std::vector<ChatMessage> _chatHistory; // C++ Vector 存储上下文
}
@property (strong) NSTextView *outputTextView;
@property (strong) NSTextField *inputField;
@property (strong) NSButton *sendButton;
@end

@implementation MainWindowController

- (instancetype)init {
    // 创建高性能原生窗口
    NSRect frame = NSMakeRect(0, 0, 800, 600);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Native Gemini (Clang/Obj-C++)";
    window.minSize = NSMakeSize(400, 300);
    [window center];
    
    self = [super initWithWindow:window];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;
    
    // 1. ScrollView
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 60, 760, 520)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    // 2. TextView (高性能配置)
    self.outputTextView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
    self.outputTextView.minSize = NSMakeSize(0.0, 0.0);
    self.outputTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.outputTextView.verticallyResizable = YES;
    self.outputTextView.horizontallyResizable = NO;
    self.outputTextView.autoresizingMask = NSViewWidthSizable;
    self.outputTextView.textContainer.containerSize = NSMakeSize(scrollView.contentSize.width, FLT_MAX);
    self.outputTextView.textContainer.widthTracksTextView = YES;
    self.outputTextView.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
    self.outputTextView.editable = NO;
    
    scrollView.documentView = self.outputTextView;
    [contentView addSubview:scrollView];
    
    // 3. 输入框
    self.inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 20, 560, 30)];
    self.inputField.placeholderString = @"Ask Gemini...";
    self.inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.inputField.target = self;
    self.inputField.action = @selector(onSendClicked); // 回车发送
    [contentView addSubview:self.inputField];
    
    // 4. 清除按钮
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(onClearClicked)];
    clearBtn.frame = NSMakeRect(590, 20, 70, 32);
    clearBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    clearBtn.bezelStyle = NSBezelStyleRounded;
    [contentView addSubview:clearBtn];

    // 5. 发送按钮
    self.sendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(onSendClicked)];
    self.sendButton.frame = NSMakeRect(670, 20, 110, 32);
    self.sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.sendButton.bezelStyle = NSBezelStyleRounded;
    [contentView addSubview:self.sendButton];
}

// 辅助日志输出
- (void)appendLog:(NSString *)text color:(NSColor *)color {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *attrs = @{NSForegroundColorAttributeName: color, NSFontAttributeName: [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]};
        NSAttributedString *attrString = [[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n\n"] attributes:attrs];
        [self.outputTextView.textStorage appendAttributedString:attrString];
        [self.outputTextView scrollRangeToVisible:NSMakeRange(self.outputTextView.string.length, 0)];
    });
}

- (void)onClearClicked {
    _chatHistory.clear();
    self.outputTextView.string = @"";
    [self appendLog:@"[Context Cleared]" color:[NSColor systemGrayColor]];
}

- (void)onSendClicked {
    NSString *prompt = self.inputField.stringValue;
    if (prompt.length == 0) return;
    
    [self appendLog:[NSString stringWithFormat:@"You: %@", prompt] color:[NSColor systemBlueColor]];
    self.inputField.stringValue = @"";
    self.sendButton.enabled = NO;
    
    // 1. 存入历史 (User)
    _chatHistory.push_back({"user", [prompt UTF8String]});
    
    // 2. 发起请求
    [self callGeminiAPI];
}

// 核心网络请求方法 (包含详细错误处理)
- (void)callGeminiAPI {
    // 检查 Key
    if (API_KEY == "YOUR_GEMINI_API_KEY") {
        [self appendLog:@"[Error] Please edit main.mm and set your API_KEY." color:[NSColor systemRedColor]];
        self.sendButton.enabled = YES;
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%s%s", MODEL_ENDPOINT.c_str(), API_KEY.c_str()];
    NSURL *url = [NSURL URLWithString:urlString];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    // 构造 Body
    NSString *jsonBody = GeminiClient::buildRequestBody(_chatHistory);
    request.HTTPBody = [jsonBody dataUsingEncoding:NSUTF8StringEncoding];
    
    // 配置 Session (含代理支持)
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    if (USE_PROXY) {
        NSNumber *port = [NSNumber numberWithInt:PROXY_PORT];
        NSString *host = [NSString stringWithUTF8String:PROXY_HOST.c_str()];
        config.connectionProxyDictionary = @{
            @"HTTPEnable": @YES, @"HTTPProxy": host, @"HTTPPort": port,
            @"HTTPSEnable": @YES, @"HTTPSProxy": host, @"HTTPSPort": port
        };
    }
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        
        dispatch_async(dispatch_get_main_queue(), ^{ self.sendButton.enabled = YES; });

        // 1. 网络连接错误
        if (error) {
            [self appendLog:[@"Network Error: " stringByAppendingString:error.localizedDescription] color:[NSColor systemRedColor]];
            return;
        }
        
        // 2. 解析 JSON
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        
        // 3. 非法 JSON (常见于 VPN 问题导致的 HTML 返回)
        if (jsonError) {
            NSString *rawStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            // 截取前200个字符避免刷屏
            if (rawStr.length > 200) rawStr = [[rawStr substringToIndex:200] stringByAppendingString:@"..."];
            [self appendLog:[NSString stringWithFormat:@"Response is not JSON (check Proxy?): %@", rawStr] color:[NSColor systemRedColor]];
            return;
        }
        
        @try {
            // 4. 检查 API 显式返回的 Error
            if (json[@"error"]) {
                NSString *msg = json[@"error"][@"message"];
                NSString *code = [NSString stringWithFormat:@"%@", json[@"error"][@"code"]];
                [self appendLog:[NSString stringWithFormat:@"API Error (%@): %@", code, msg] color:[NSColor systemRedColor]];
                
                // 回滚最后一条用户消息，防止历史记录坏死
                if (_chatHistory.size() > 0 && _chatHistory.back().role == "user") {
                    _chatHistory.pop_back();
                }
                return;
            }
            
            // 5. 解析正常回复
            NSArray *candidates = json[@"candidates"];
            if (candidates && candidates.count > 0) {
                // 安全检查
                NSString *finishReason = candidates[0][@"finishReason"];
                if ([finishReason isEqualToString:@"SAFETY"]) {
                    [self appendLog:@"[Blocked] Content blocked by safety settings." color:[NSColor systemOrangeColor]];
                    return;
                }
                
                NSDictionary *content = candidates[0][@"content"];
                NSArray *parts = content[@"parts"];
                if (parts && parts.count > 0) {
                    NSString *text = parts[0][@"text"];
                    if (text) {
                        [self appendLog:[NSString stringWithFormat:@"Gemini: %@", text] color:[NSColor labelColor]];
                        // 存入历史
                        _chatHistory.push_back({"model", [text UTF8String]});
                    }
                }
            } else {
                // 6. 既无 Error 也无 Content
                NSString *blockReason = json[@"promptFeedback"][@"blockReason"];
                if (blockReason) {
                    [self appendLog:[NSString stringWithFormat:@"[Feedback] Blocked reason: %@", blockReason] color:[NSColor systemOrangeColor]];
                } else {
                    [self appendLog:@"No content returned. Unknown API state." color:[NSColor systemGrayColor]];
                }
            }
        } @catch (NSException *e) {
             [self appendLog:@"JSON Structure Mismatch." color:[NSColor systemRedColor]];
        }
    }];
    
    [task resume];
}

@end

// ==========================================
// 4. App Delegate (菜单与激活)
// ==========================================

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) MainWindowController *mainWindowController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // 构建主菜单 (必须有，否则无法复制粘贴和退出)
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];
    [NSApp setMainMenu:menubar];
    
    // Quit 菜单
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit GeminiApp" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    
    // Edit 菜单 (支持 Cmd+C, Cmd+V, Cmd+A)
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenuItem setSubmenu:editMenu];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    // 显示窗口
    self.mainWindowController = [[MainWindowController alloc] init];
    [self.mainWindowController showWindow:self];
    [self.mainWindowController.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

// ==========================================
// 5. Main 入口
// ==========================================

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        // 设置为常规 App (显示 Dock 图标和 UI)
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        
        [app run];
    }
    return 0;
}
