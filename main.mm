/*
 ===========================================================================
 运行环境: macOS 12.0+ 
 编译命令: 
 clang++ -fobjc-arc -framework Cocoa -framework Foundation -framework UniformTypeIdentifiers main.mm -o GeminiApp
 ./GeminiApp
 ===========================================================================
 */

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string>
#include <vector>

// ==========================================
// 1. 配置区域
// ==========================================

// [必填] 替换为你的 Gemini API Key
const std::string API_KEY = "Key";

const bool USE_PROXY = false;
const std::string PROXY_HOST = "127.0.0.1";
const int PROXY_PORT = 7890; 

const std::string MODEL_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=";

// ==========================================
// 2. C++ 逻辑层
// ==========================================

struct ChatMessage {
    std::string role; 
    std::string text;
};

class GeminiClient {
public:
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

    static NSString* buildRequestBody(const std::vector<ChatMessage>& history) {
        std::string json = "{\"contents\": [";
        for (size_t i = 0; i < history.size(); ++i) {
            const auto& msg = history[i];
            json += "{\"role\": \"";
            json += msg.role;
            json += "\", \"parts\": [{\"text\": \"";
            json += escapeJSON(msg.text);
            json += "\"}]}";
            if (i < history.size() - 1) json += ",";
        }
        json += "]}";
        return [NSString stringWithUTF8String:json.c_str()];
    }
};

// ==========================================
// 3. UI 控制器
// ==========================================

@interface MainWindowController : NSWindowController {
    std::vector<ChatMessage> _chatHistory; 
}
@property (strong) NSTextView *outputTextView;
@property (strong) NSTextField *inputField;
@property (strong) NSButton *sendButton;
@property (strong) NSButton *uploadButton;
@end

@implementation MainWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 900, 700);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Native Gemini (Safe File Upload)";
    window.minSize = NSMakeSize(600, 500);
    [window center];
    
    self = [super initWithWindow:window];
    if (self) {
        [self setupUI];
    }
    return self;
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

- (void)onClearClicked {
    _chatHistory.clear();
    self.outputTextView.string = @"";
    [self appendLog:@"[System] Chat history cleared from RAM." color:[NSColor systemGrayColor]];
}

// ==========================================
// 修复后的文件上传逻辑
// ==========================================
- (void)onUploadClicked {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;

    if (@available(macOS 12.0, *)) {
        // 使用更稳妥的方式获取类型，避免直接使用可能未定义的常量
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        [types addObject:UTTypePlainText];   // .txt
        [types addObject:UTTypeSourceCode];  // 代码类
        [types addObject:UTTypeJSON];        // .json
        
        // 动态查找 Markdown 和 Log 类型，防止因常量未定义导致编译失败
        UTType *mdType = [UTType typeWithFilenameExtension:@"md"];
        if (mdType) [types addObject:mdType];
        
        UTType *logType = [UTType typeWithFilenameExtension:@"log"];
        if (logType) [types addObject:logType];

        panel.allowedContentTypes = types;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        panel.allowedFileTypes = @[@"txt", @"md", @"cpp", @"h", @"py", @"json", @"log"];
#pragma clang diagnostic pop
    }
    
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = [[panel URLs] firstObject];
            NSError *error;
            NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
            
            if (error) {
                [self appendLog:[@"Error reading file: " stringByAppendingString:error.localizedDescription] color:[NSColor systemRedColor]];
                return;
            }
            
            NSString *fileName = [url lastPathComponent];
            [self appendLog:[NSString stringWithFormat:@"[File: %@ Uploaded]", fileName] color:[NSColor systemGreenColor]];
            
            std::string prompt = "Uploaded File Content (" + std::string([fileName UTF8String]) + "):\n---\n" + [content UTF8String] + "\n---\nPlease summarize this file.";
            _chatHistory.push_back({"user", prompt});
            
            [self callGeminiAPI];
        }
    }];
}

- (void)onSendClicked {
    NSString *prompt = self.inputField.stringValue;
    if (prompt.length == 0) return;
    [self appendLog:[NSString stringWithFormat:@"You: %@", prompt] color:[NSColor systemBlueColor]];
    _chatHistory.push_back({"user", [prompt UTF8String]});
    self.inputField.stringValue = @"";
    [self callGeminiAPI];
}

- (void)callGeminiAPI {
    if (API_KEY == "YOUR_API_KEY_HERE") {
        [self appendLog:@"[Error] Please set your API_KEY in the code." color:[NSColor systemRedColor]];
        return;
    }
    self.sendButton.enabled = NO;
    self.uploadButton.enabled = NO;

    NSString *urlString = [NSString stringWithFormat:@"%s%s", MODEL_ENDPOINT.c_str(), API_KEY.c_str()];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [GeminiClient::buildRequestBody(_chatHistory) dataUsingEncoding:NSUTF8StringEncoding];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    if (USE_PROXY) {
        NSString *host = [NSString stringWithUTF8String:PROXY_HOST.c_str()];
        NSNumber *port = [NSNumber numberWithInt:PROXY_PORT];
        config.connectionProxyDictionary = @{ @"HTTPEnable":@YES, @"HTTPProxy":host, @"HTTPPort":port, @"HTTPSEnable":@YES, @"HTTPSProxy":host, @"HTTPSPort":port };
    }
    
    [[[NSURLSession sessionWithConfiguration:config] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sendButton.enabled = YES;
            self.uploadButton.enabled = YES;
            if (error) {
                [self appendLog:[@"Network Error: " stringByAppendingString:error.localizedDescription] color:[NSColor systemRedColor]];
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json[@"error"]) {
                [self appendLog:[NSString stringWithFormat:@"API Error: %@", json[@"error"][@"message"]] color:[NSColor systemRedColor]];
            } else if (json[@"candidates"]) {
                @try {
                    NSString *text = json[@"candidates"][0][@"content"][@"parts"][0][@"text"];
                    if (text) {
                        [self appendLog:[NSString stringWithFormat:@"Gemini: %@", text] color:[NSColor labelColor]];
                        _chatHistory.push_back({"model", [text UTF8String]});
                    }
                } @catch (NSException *e) {
                    [self appendLog:@"Unexpected JSON format." color:[NSColor systemOrangeColor]];
                }
            }
        });
    }] resume];
}
@end

// ==========================================
// 4. App Delegate & Main
// ==========================================

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) MainWindowController *mainWindowController;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)a {
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
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
