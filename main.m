// TurboBar: menu bar CPU load, temperature, fan speed and a Turbo Boost limiter for Intel Macs.
//
// Turbo is limited through macOS Low Power Mode. Writing the CPU's turbo register
// directly needs a kernel extension, which macOS no longer allows without lowering
// system security.

#import <AppKit/AppKit.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "MenuPanel.h"
#include "smc.h"

// The fan speed behind each option in the menu.
static const int kFanSpeeds[] = {kFanAuto, kFanMinPercent, 50, 75, 100};
static const NSInteger kFanSpeedCount = sizeof kFanSpeeds / sizeof kFanSpeeds[0];

// Seconds between readings. The tolerance lets macOS batch our wake-ups with others.
static const NSTimeInterval kInterval = 3.0;
static const NSTimeInterval kTolerance = 1.0;
// Smaller changes than this don't redraw the menu bar, which is the costliest thing we do.
static const int kRedrawStep = 2;
static const int kUnknown = -1;
static const int kNothingShown = -100;
// How long to wait for the fan helper to connect after it starts.
static const int kHelperConnectAttempts = 50;
static const useconds_t kHelperConnectDelay = 100000;

#pragma mark - Readings

// How hard the busiest fan is working: 0 is its idle speed, 100 is flat out.
static int FanPercent(void) {
    int highest = kUnknown;
    for (int i = 0; i < gFanCount; i++) {
        Fan *fan = &gFans[i];
        if (!SMCReadFloat(fan->speedKey, &fan->rpm)) continue;
        double percent = (fan->rpm - fan->min) / (fan->max - fan->min) * 100.0;
        highest = MAX(highest, (int)lround(MAX(0.0, MIN(100.0, percent))));
    }
    return highest;
}

static int CPUPercent(void) {
    static host_cpu_load_info_data_t previous;
    static host_t host;
    if (!host) host = mach_host_self();

    host_cpu_load_info_data_t now;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&now, &count) != KERN_SUCCESS) return kUnknown;

    uint32_t user = now.cpu_ticks[CPU_STATE_USER] - previous.cpu_ticks[CPU_STATE_USER];
    uint32_t system = now.cpu_ticks[CPU_STATE_SYSTEM] - previous.cpu_ticks[CPU_STATE_SYSTEM];
    uint32_t nice = now.cpu_ticks[CPU_STATE_NICE] - previous.cpu_ticks[CPU_STATE_NICE];
    uint32_t idle = now.cpu_ticks[CPU_STATE_IDLE] - previous.cpu_ticks[CPU_STATE_IDLE];
    previous = now;

    uint32_t busy = user + system + nice;
    uint32_t total = busy + idle;
    return total ? (int)lround(100.0 * busy / total) : kUnknown;
}

static int KernelInt(const char *name) {
    int value = kUnknown;
    size_t size = sizeof value;
    return sysctlbyname(name, &value, &size, NULL, 0) == 0 ? value : kUnknown;
}

static BOOL TurboIsLimited(void) {
    return KernelInt("machdep.xcpm.lpm_enabled") == 1;
}

#pragma mark - Temperatures

// Names for the other SMC sensors worth showing, grouped by menu section.
// Sensors this Mac doesn't have are left out.
typedef struct {
    const char *section, *key, *name;
} SensorLabel;

static const SensorLabel kSensorLabels[] = {
    {"CPU", "TCXC", "Package"},
    {"CPU", "TC0P", "Proximity"},
    {"CPU", "TCSA", "System agent"},
    {"Graphics", "TGDD", "Radeon"},
    {"Graphics", "TCGC", "Intel"},
    {"Graphics", "TG0P", "Proximity"},
    {"System", "TM0P", "Memory"},
    {"System", "TH0X", "SSD"},
    {"System", "TPCD", "Chipset"},
    {"System", "Tm0P", "Logic board"},
    {"System", "TW0P", "Wi-Fi"},
    {"System", "TB0T", "Battery"},
    {"System", "TTLD", "Thunderbolt L"},
    {"System", "TTRD", "Thunderbolt R"},
    {"Case", "Th1H", "Heatpipe 1"},
    {"Case", "Th2H", "Heatpipe 2"},
    {"Case", "TaLC", "Airflow L"},
    {"Case", "TaRC", "Airflow R"},
    {"Case", "Ts0P", "Palm rest"},
    {"Case", "TA0V", "Ambient"},
};
static const int kSensorLabelCount = sizeof kSensorLabels / sizeof kSensorLabels[0];

enum { kMaxCores = 16, kMaxSensors = kMaxCores + kSensorLabelCount };

typedef struct {
    uint32_t key;
    const char *section;
    char name[16];
    double celsius;  // NAN when it couldn't be read.
} Sensor;

// The CPU cores come first, so they head the CPU section.
static Sensor gSensors[kMaxSensors];
static int gSensorCount, gCoreCount;

static BOOL AddSensor(const char *key, const char *section, const char *name) {
    SMCMessage message;
    uint32_t code = FourCC(key);
    if (gSensorCount == kMaxSensors || !SMCCall(code, kSMCReadInfo, 0, &message)
        || message.info.type != FourCC("sp78")) return NO;

    Sensor *sensor = &gSensors[gSensorCount++];
    *sensor = (Sensor){.key = code, .section = section, .celsius = NAN};
    snprintf(sensor->name, sizeof sensor->name, "%s", name);
    return YES;
}

// Needs the SMC connection that OpenFans makes.
static void FindSensors(void) {
    // Core sensors are TC1C, TC2C and so on.
    static const char kCoreDigits[] = "0123456789ABCDEF";
    for (int i = 0; i < kMaxCores; i++) {
        char key[5] = {'T', 'C', kCoreDigits[i], 'C', '\0'};
        char name[16];
        snprintf(name, sizeof name, "Core %d", gCoreCount + 1);
        if (AddSensor(key, "CPU", name)) gCoreCount++;
    }
    for (int i = 0; i < kSensorLabelCount; i++) {
        AddSensor(kSensorLabels[i].key, kSensorLabels[i].section, kSensorLabels[i].name);
    }
}

// A sensor with no data reads zero.
static void ReadSensor(Sensor *sensor) {
    double celsius;
    sensor->celsius = SMCReadCelsius(sensor->key, &celsius) && celsius > 0 ? celsius : NAN;
}

// The mean of the core sensors. Only these are read on every tick.
static int CoreAverage(void) {
    double total = 0;
    int count = 0;
    for (int i = 0; i < gCoreCount; i++) {
        ReadSensor(&gSensors[i]);
        if (isnan(gSensors[i].celsius)) continue;
        total += gSensors[i].celsius;
        count++;
    }
    return count ? (int)lround(total / count) : kUnknown;
}

#pragma mark - Menu bar

static const CGFloat kStatusHeight = 18;
static const CGFloat kIconPointSize = 12;
static const CGFloat kIconToNumberGap = 2;
static const CGFloat kGroupGap = 5;

static const CGFloat kStatusScale = 2;

// Draws once into a bitmap, so showing the result never repeats the drawing work.
static NSImage *RenderedImage(NSSize size, void (^draw)(void)) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                       pixelsWide:(NSInteger)(size.width * kStatusScale)
                                                                       pixelsHigh:(NSInteger)(size.height * kStatusScale)
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSCalibratedRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
    bitmap.size = size;

    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    draw();
    [NSGraphicsContext restoreGraphicsState];

    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image addRepresentation:bitmap];
    return image;
}

// Vector symbols are slow to draw, so each one is turned into a bitmap once.
static NSImage *StatusSymbol(NSString *name) {
    NSImage *symbol = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
                       imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:kIconPointSize
                                                                                                    weight:NSFontWeightRegular]];
    NSSize symbolSize = symbol.size;
    NSSize size = NSMakeSize(ceil(symbolSize.width), ceil(symbolSize.height));
    return RenderedImage(size, ^{
        [symbol drawInRect:NSMakeRect((size.width - symbolSize.width) / 2, (size.height - symbolSize.height) / 2,
                                      symbolSize.width, symbolSize.height)];
    });
}

static NSDictionary *StatusNumberStyle(void) {
    static NSDictionary *style;
    if (!style) {
        style = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.blackColor,
        };
    }
    return style;
}

static NSString *StatusNumber(int value, NSString *unit) {
    return value < 0 ? @"-" : [NSString stringWithFormat:@"%d%@", value, unit];
}

// Always leaves room for two digits, so only a reading of 100 or more can shift the menu bar.
static CGFloat StatusNumberWidth(NSString *text, NSString *unit) {
    NSDictionary *style = StatusNumberStyle();
    NSString *widest = [@"00" stringByAppendingString:unit];
    return ceil(MAX([text sizeWithAttributes:style].width, [widest sizeWithAttributes:style].width));
}

static void DrawStatusSymbol(NSImage *symbol, CGFloat x, CGFloat width) {
    NSSize size = symbol.size;
    [symbol drawInRect:NSMakeRect(x + (width - size.width) / 2, (kStatusHeight - size.height) / 2, size.width, size.height)];
}

static void DrawStatusNumber(NSString *text, CGFloat x) {
    NSDictionary *style = StatusNumberStyle();
    [text drawAtPoint:NSMakePoint(x, (kStatusHeight - [text sizeWithAttributes:style].height) / 2) withAttributes:style];
}

// Everything is drawn in black. As a template image, macOS tints it to suit the menu bar.
static NSImage *StatusImage(int cpu, int temperature, int fan, BOOL limited) {
    static NSImage *turboOn, *turboOff, *cpuIcon, *temperatureIcon, *fanIcon;
    if (!turboOn) {
        turboOn = StatusSymbol(@"bolt.fill");
        turboOff = StatusSymbol(@"bolt.slash.fill");
        cpuIcon = StatusSymbol(@"cpu");
        temperatureIcon = StatusSymbol(@"thermometer.medium");
        fanIcon = StatusSymbol(@"fan.fill");
    }

    NSImage *turbo = limited ? turboOff : turboOn;
    NSString *cpuText = StatusNumber(cpu, @"");
    NSString *temperatureText = StatusNumber(temperature, @"°");
    NSString *fanText = StatusNumber(fan, @"");

    CGFloat turboWidth = ceil(MAX(turboOn.size.width, turboOff.size.width));
    CGFloat cpuIconWidth = ceil(cpuIcon.size.width);
    CGFloat temperatureIconWidth = ceil(temperatureIcon.size.width);
    CGFloat fanIconWidth = ceil(fanIcon.size.width);
    CGFloat cpuX = turboWidth + kGroupGap;
    CGFloat cpuNumberX = cpuX + cpuIconWidth + kIconToNumberGap;
    CGFloat temperatureX = cpuNumberX + StatusNumberWidth(cpuText, @"") + kGroupGap;
    CGFloat temperatureNumberX = temperatureX + temperatureIconWidth + kIconToNumberGap;
    CGFloat fanX = temperatureNumberX + StatusNumberWidth(temperatureText, @"°") + kGroupGap;
    CGFloat fanNumberX = fanX + fanIconWidth + kIconToNumberGap;
    CGFloat width = fanNumberX + StatusNumberWidth(fanText, @"");

    NSImage *image = RenderedImage(NSMakeSize(width, kStatusHeight), ^{
        DrawStatusSymbol(turbo, 0, turboWidth);
        DrawStatusSymbol(cpuIcon, cpuX, cpuIconWidth);
        DrawStatusNumber(cpuText, cpuNumberX);
        DrawStatusSymbol(temperatureIcon, temperatureX, temperatureIconWidth);
        DrawStatusNumber(temperatureText, temperatureNumberX);
        DrawStatusSymbol(fanIcon, fanX, fanIconWidth);
        DrawStatusNumber(fanText, fanNumberX);
    });
    image.template = YES;
    return image;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, MenuPanelDelegate>
@end

@implementation AppDelegate {
    NSStatusItem *_item;
    NSMenuItem *_panelItem;
    MenuPanel *_panel;  // Built the first time the menu opens.
    NSTimer *_timer;
    int _shownCPU, _shownTemperature, _shownFan;
    BOOL _shownLimited;
    int _fanPipe;     // Write end of the pipe to the fan helper, or -1 when it isn't running.
    int _fanPercent;  // The manual speed last sent to the helper.
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    OpenFans();
    FindSensors();
    _shownCPU = _shownTemperature = _shownFan = kNothingShown;
    _fanPipe = -1;

    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _item.menu = [self buildMenu];

    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(pause) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(pause) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [workspace addObserver:self selector:@selector(resume) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [workspace addObserver:self selector:@selector(resume) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    [self resume];
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    menu.autoenablesItems = NO;

    _panelItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit TurboBar" action:@selector(terminate:) keyEquivalent:@"q"].target = NSApp;
    return menu;
}

- (void)resume {
    if (_timer) return;
    [self tick];
    _timer = [NSTimer scheduledTimerWithTimeInterval:kInterval
                                              target:self
                                            selector:@selector(tick)
                                            userInfo:nil
                                             repeats:YES];
    _timer.tolerance = kTolerance;
}

- (void)pause {
    [_timer invalidate];
    _timer = nil;
}

- (void)tick {
    int cpu = CPUPercent();
    int temperature = CoreAverage();
    int fan = FanPercent();
    BOOL limited = TurboIsLimited();
    if (abs(cpu - _shownCPU) < kRedrawStep && abs(temperature - _shownTemperature) < kRedrawStep
        && abs(fan - _shownFan) < kRedrawStep && limited == _shownLimited) return;

    _shownCPU = cpu;
    _shownTemperature = temperature;
    _shownFan = fan;
    _shownLimited = limited;
    _item.button.image = StatusImage(cpu, temperature, fan, limited);
    _item.button.accessibilityLabel = [NSString stringWithFormat:@"Turbo %@, CPU %d percent, %d degrees, fan %d percent",
                                       limited ? @"off" : @"on", cpu, temperature, fan];
}

- (MenuPanel *)buildPanel {
    NSMutableArray<NSString *> *titles = [NSMutableArray new];
    NSMutableArray<NSMutableArray<NSString *> *> *names = [NSMutableArray new];
    for (int i = 0; i < gSensorCount; i++) {
        NSString *section = @(gSensors[i].section);
        if (![titles.lastObject isEqualToString:section]) {
            [titles addObject:section];
            [names addObject:[NSMutableArray new]];
        }
        [names.lastObject addObject:@(gSensors[i].name)];
    }
    return [[MenuPanel alloc] initWithSensorSections:titles
                                         sensorNames:names
                                            fanCount:gFanCount
                                          fanOptions:@[@"Auto", @"25%", @"50%", @"75%", @"Max"]
                                            delegate:self];
}

- (void)showTemperatures {
    // The tick that just ran has read the cores, so only the rest are read here.
    for (int i = gCoreCount; i < gSensorCount; i++) ReadSensor(&gSensors[i]);
    for (int i = 0; i < gSensorCount; i++) [_panel showSensor:i celsius:gSensors[i].celsius];

    double total = 0, hottest = 0;
    int count = 0;
    for (int i = 0; i < gCoreCount; i++) {
        double celsius = gSensors[i].celsius;
        if (isnan(celsius)) continue;
        total += celsius;
        hottest = MAX(hottest, celsius);
        count++;
    }
    // When there are cores, they head the CPU section, which is the first.
    if (count > 0) {
        NSString *summary = [NSString stringWithFormat:@"avg %@  ·  max %@",
                             TemperatureText(total / count), TemperatureText(hottest)];
        [_panel showSummary:summary forSection:0];
    }
}

// Runs only when the menu opens, so these rows cost nothing the rest of the time.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self tick];

    if (!_panel) {
        _panel = [self buildPanel];
        _panelItem.view = _panel;
    }

    BOOL limited = TurboIsLimited();
    const char *capName = limited ? "machdep.xcpm.lpm_plimit_max_100mhz_ratio" : "machdep.xcpm.hard_plimit_max_100mhz_ratio";
    [_panel showTurboOn:!limited maxGHz:KernelInt(capName) / 10.0];
    [self showTemperatures];

    for (int i = 0; i < gFanCount; i++) {
        [_panel showFan:i rpm:gFans[i].rpm minRPM:gFans[i].min maxRPM:gFans[i].max];
    }

    // Asks the hardware, so this also shows Auto after the helper's safety check takes over.
    int active = FansAreManual() ? _fanPercent : kFanAuto;
    for (NSInteger i = 0; i < kFanSpeedCount; i++) {
        if (kFanSpeeds[i] == active) [_panel showFanOption:i];
    }
}

#pragma mark - Actions

// One shell argument, safe whatever characters the text holds.
static NSString *ShellQuoted(NSString *text) {
    return [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

// An AppleScript string literal holding the text.
static NSString *AppleScriptString(NSString *text) {
    NSString *escaped = [[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                         stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

- (BOOL)runAsAdmin:(NSString *)command {
    NSString *source = [NSString stringWithFormat:@"do shell script %@ with administrator privileges",
                        AppleScriptString(command)];
    NSDictionary *error = nil;
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    if ([script executeAndReturnError:&error]) return YES;

    if ([error[NSAppleScriptErrorNumber] intValue] != userCanceledErr) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"That change didn't work";
        alert.informativeText = error[NSAppleScriptErrorMessage] ?: @"Unknown error";
        [alert runModal];
    }
    return NO;
}

- (void)panelDidToggleTurbo {
    [self runAsAdmin:[NSString stringWithFormat:@"/usr/bin/pmset -a lowpowermode %d", TurboIsLimited() ? 0 : 1]];
    [self tick];
}

- (void)closeFanPipe {
    if (_fanPipe >= 0) close(_fanPipe);
    _fanPipe = -1;
}

- (BOOL)sendFanPercent:(int)percent {
    if (_fanPipe < 0) return NO;
    char line[8];
    int length = snprintf(line, sizeof line, "%d\n", percent);
    if (write(_fanPipe, line, (size_t)length) == length) return YES;
    [self closeFanPipe];  // The helper has exited, so the next attempt must start a new one.
    return NO;
}

- (BOOL)startFanHelper {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (mkfifo(path.fileSystemRepresentation, 0600) != 0) return NO;

    NSString *helper = [NSBundle.mainBundle pathForAuxiliaryExecutable:@"turbofan"];
    BOOL started = [self runAsAdmin:[NSString stringWithFormat:@"%@ %@ >/dev/null 2>&1 &",
                                     ShellQuoted(helper), ShellQuoted(path)]];

    int pipe = -1;
    for (int attempt = 0; started && pipe < 0 && attempt < kHelperConnectAttempts; attempt++) {
        pipe = open(path.fileSystemRepresentation, O_WRONLY | O_NONBLOCK);
        if (pipe < 0) usleep(kHelperConnectDelay);
    }
    unlink(path.fileSystemRepresentation);

    _fanPipe = pipe;
    return pipe >= 0;
}

- (void)panelDidChooseFanOption:(NSInteger)index {
    int percent = kFanSpeeds[index];
    if (percent == kFanAuto) {
        [self sendFanPercent:kFanAuto];  // The helper restores Auto and exits.
        [self closeFanPipe];
        return;
    }
    if ([self sendFanPercent:percent] || ([self startFanHelper] && [self sendFanPercent:percent])) {
        _fanPercent = percent;
    }
}

@end

static AppDelegate *gDelegate;  // NSApplication holds its delegate weakly.

int main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);  // A vanished fan helper is handled where we write to it.
        gDelegate = [AppDelegate new];
        NSApplication.sharedApplication.delegate = gDelegate;
        [NSApp run];
    }
    return 0;
}
