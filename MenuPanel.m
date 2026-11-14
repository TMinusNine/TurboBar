#import "MenuPanel.h"

static const CGFloat kPanelWidth = 268;
static const CGFloat kInset = 14;
static const CGFloat kHeaderHeight = 46;
static const CGFloat kFanRowHeight = 30;
static const CGFloat kSensorRowHeight = 17;
// Names may run into the value's frame as far as a two-digit reading leaves free.
static const CGFloat kSensorValueWidth = 36;
static const CGFloat kSensorNameReserve = 28;
static const CGFloat kColumnGap = 16;
static const CGFloat kIconColumn = 26;
// Readings at or above these are tinted. The fan helper gives up its reduced speed at 90.
static const double kWarmCelsius = 80;
static const double kHotCelsius = 90;
// NSTextField draws its text this far inside its frame.
static const CGFloat kLabelPadding = 2;
// NSSwitch draws itself this far inside its frame.
static const CGFloat kSwitchFramePadding = 5;

static NSTextField *Label(NSRect frame, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.frame = NSInsetRect(frame, -kLabelPadding, 0);
    label.font = font;
    label.textColor = color;
    return label;
}

static NSAttributedString *Styled(NSString *text, NSFont *font, NSColor *color) {
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    }];
}

static NSString *WholeNumber(double value) {
    return [NSNumberFormatter localizedStringFromNumber:@(lround(value))
                                            numberStyle:NSNumberFormatterDecimalStyle];
}

NSString *TemperatureText(double celsius) {
    return isnan(celsius) ? @"–" : [NSString stringWithFormat:@"%ld°", lround(celsius)];
}

static NSTextField *SectionHeading(NSRect frame, NSString *title) {
    NSTextField *heading = Label(frame, [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    heading.stringValue = title;
    return heading;
}

#pragma mark - Fan row

@interface LevelBar : NSView
@property (nonatomic) double level;  // 0 to 1.
@end

@implementation LevelBar

- (void)setLevel:(double)level {
    _level = MAX(0.0, MIN(1.0, level));
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect track = self.bounds;
    CGFloat radius = NSHeight(track) / 2;
    [NSColor.quaternaryLabelColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:radius yRadius:radius] fill];

    if (_level <= 0) return;
    NSRect filled = track;
    filled.size.width = MAX(NSHeight(track), NSWidth(track) * _level);
    [NSColor.controlAccentColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:filled xRadius:radius yRadius:radius] fill];
}

@end

@interface FanRow : NSView
- (instancetype)initWithOrigin:(NSPoint)origin width:(CGFloat)width name:(NSString *)name;
- (void)showRPM:(double)rpm minRPM:(double)minRPM maxRPM:(double)maxRPM;
@end

@implementation FanRow {
    NSString *_name;
    NSTextField *_speed;
    NSTextField *_range;
    LevelBar *_bar;
}

- (BOOL)isFlipped {
    return YES;
}

- (instancetype)initWithOrigin:(NSPoint)origin width:(CGFloat)width name:(NSString *)name {
    self = [super initWithFrame:NSMakeRect(origin.x, origin.y, width, kFanRowHeight)];
    if (!self) return nil;

    _name = name;
    _speed = Label(NSMakeRect(0, 0, 150, 16), [NSFont systemFontOfSize:12], NSColor.labelColor);
    _range = Label(NSMakeRect(width - 100, 1, 100, 14),
                   [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
                   NSColor.tertiaryLabelColor);
    _range.alignment = NSTextAlignmentRight;
    _bar = [[LevelBar alloc] initWithFrame:NSMakeRect(0, 19, width, 3)];

    [self addSubview:_speed];
    [self addSubview:_range];
    [self addSubview:_bar];
    return self;
}

- (void)showRPM:(double)rpm minRPM:(double)minRPM maxRPM:(double)maxRPM {
    // Fixed-width digits keep the speeds of every fan lined up.
    NSFont *regular = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    [text appendAttributedString:Styled([_name stringByAppendingString:@"   "], regular, NSColor.secondaryLabelColor)];
    [text appendAttributedString:Styled(WholeNumber(rpm),
                                        [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
                                        NSColor.labelColor)];
    [text appendAttributedString:Styled(@" rpm", regular, NSColor.secondaryLabelColor)];
    _speed.attributedStringValue = text;

    _range.stringValue = [NSString stringWithFormat:@"%@ – %@", WholeNumber(minRPM), WholeNumber(maxRPM)];
    _bar.level = (rpm - minRPM) / (maxRPM - minRPM);
}

@end

#pragma mark - Panel

@implementation MenuPanel {
    __weak id<MenuPanelDelegate> _delegate;
    NSImageView *_turboIcon;
    NSTextField *_turboTitle;
    NSTextField *_turboDetail;
    NSSwitch *_turboSwitch;
    NSMutableArray<NSTextField *> *_sensorValues;
    NSMutableArray<NSTextField *> *_sectionSummaries;
    NSMutableArray<FanRow *> *_fanRows;
    NSSegmentedControl *_fanSpeed;
}

- (BOOL)isFlipped {
    return YES;
}

- (instancetype)initWithSensorSections:(NSArray<NSString *> *)sectionTitles
                           sensorNames:(NSArray<NSArray<NSString *> *> *)sensorNames
                              fanCount:(int)fanCount
                            fanOptions:(NSArray<NSString *> *)fanOptions
                              delegate:(id<MenuPanelDelegate>)delegate {
    self = [super initWithFrame:NSMakeRect(0, 0, kPanelWidth, 0)];
    if (!self) return nil;

    _delegate = delegate;
    [self addTurboHeader];

    CGFloat bottom = kHeaderHeight;
    if (sectionTitles.count > 0) bottom = [self addSensorSections:sectionTitles names:sensorNames top:bottom];
    if (fanCount > 0) bottom = [self addFanSectionForCount:fanCount options:fanOptions top:bottom];
    [self setFrameSize:NSMakeSize(kPanelWidth, bottom)];
    return self;
}

- (void)addDividerAt:(CGFloat)y {
    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(kInset, y, kPanelWidth - 2 * kInset, 1)];
    divider.boxType = NSBoxSeparator;
    [self addSubview:divider];
}

- (void)addTurboHeader {
    NSImage *bolt = [NSImage imageWithSystemSymbolName:@"bolt.fill" accessibilityDescription:nil];
    _turboIcon = [NSImageView imageViewWithImage:bolt];
    _turboIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium];
    _turboIcon.frame = NSMakeRect(kInset, 13, 20, 20);

    CGFloat textX = kInset + kIconColumn;
    _turboTitle = Label(NSMakeRect(textX, 7, 150, 17),
                        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
    _turboDetail = Label(NSMakeRect(textX, 24, 150, 14), [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);

    _turboSwitch = [NSSwitch new];
    _turboSwitch.controlSize = NSControlSizeSmall;
    _turboSwitch.target = self;
    _turboSwitch.action = @selector(turboSwitchChanged:);
    _turboSwitch.accessibilityLabel = @"Turbo Boost";
    [_turboSwitch sizeToFit];
    NSSize size = _turboSwitch.frame.size;
    _turboSwitch.frame = NSMakeRect(kPanelWidth - kInset - size.width + kSwitchFramePadding,
                                    (kHeaderHeight - size.height) / 2, size.width, size.height);

    [self addSubview:_turboIcon];
    [self addSubview:_turboTitle];
    [self addSubview:_turboDetail];
    [self addSubview:_turboSwitch];
}

// Sensors sit in two columns, each a name with its reading on the right.
// Returns the y position just below the sections.
- (CGFloat)addSensorSections:(NSArray<NSString *> *)titles names:(NSArray<NSArray<NSString *> *> *)names top:(CGFloat)top {
    CGFloat width = kPanelWidth - 2 * kInset;
    CGFloat columnWidth = (width - kColumnGap) / 2;
    NSFont *nameFont = [NSFont systemFontOfSize:12];
    NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];

    _sensorValues = [NSMutableArray new];
    _sectionSummaries = [NSMutableArray new];

    [self addDividerAt:top];
    CGFloat y = top + 8;
    for (NSUInteger section = 0; section < titles.count; section++) {
        [self addSubview:SectionHeading(NSMakeRect(kInset, y + 2, columnWidth, 14), titles[section])];
        NSTextField *summary = Label(NSMakeRect(kInset + columnWidth / 2, y + 2, width - columnWidth / 2, 14),
                                     [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                                     NSColor.secondaryLabelColor);
        summary.alignment = NSTextAlignmentRight;
        [self addSubview:summary];
        [_sectionSummaries addObject:summary];
        y += 20;

        NSArray<NSString *> *sectionNames = names[section];
        for (NSUInteger i = 0; i < sectionNames.count; i++) {
            CGFloat x = kInset + (CGFloat)(i % 2) * (columnWidth + kColumnGap);
            CGFloat rowY = y + (CGFloat)(i / 2) * kSensorRowHeight;

            NSTextField *name = Label(NSMakeRect(x, rowY, columnWidth - kSensorNameReserve, 15), nameFont,
                                      NSColor.secondaryLabelColor);
            name.stringValue = sectionNames[i];
            name.lineBreakMode = NSLineBreakByTruncatingTail;

            NSTextField *value = Label(NSMakeRect(x + columnWidth - kSensorValueWidth, rowY, kSensorValueWidth, 15),
                                       valueFont, NSColor.labelColor);
            value.alignment = NSTextAlignmentRight;

            [self addSubview:name];
            [self addSubview:value];
            [_sensorValues addObject:value];
        }
        y += (CGFloat)((sectionNames.count + 1) / 2) * kSensorRowHeight + 6;
    }
    return y;
}

// Returns the y position just below the section.
- (CGFloat)addFanSectionForCount:(int)fanCount options:(NSArray<NSString *> *)options top:(CGFloat)top {
    CGFloat width = kPanelWidth - 2 * kInset;
    CGFloat y = top;

    [self addDividerAt:y];
    y += 10;

    _fanRows = [NSMutableArray new];
    for (int i = 0; i < fanCount; i++) {
        NSString *name = [NSString stringWithFormat:@"Fan %d", i + 1];
        FanRow *row = [[FanRow alloc] initWithOrigin:NSMakePoint(kInset, y) width:width name:name];
        [self addSubview:row];
        [_fanRows addObject:row];
        y += kFanRowHeight;
    }

    [self addSubview:SectionHeading(NSMakeRect(kInset, y + 2, width, 14), @"Fan Speed")];
    y += 20;

    _fanSpeed = [NSSegmentedControl segmentedControlWithLabels:options
                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                        target:self
                                                        action:@selector(fanSpeedChanged:)];
    _fanSpeed.controlSize = NSControlSizeSmall;
    _fanSpeed.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _fanSpeed.segmentDistribution = NSSegmentDistributionFillEqually;
    _fanSpeed.accessibilityLabel = @"Fan Speed";
    [_fanSpeed sizeToFit];
    CGFloat height = NSHeight(_fanSpeed.frame);
    _fanSpeed.frame = NSMakeRect(kInset, y, width, height);
    [self addSubview:_fanSpeed];

    return y + height + 8;
}

#pragma mark Showing values

- (void)showTurboOn:(BOOL)on maxGHz:(double)maxGHz {
    _turboIcon.contentTintColor = on ? NSColor.systemOrangeColor : NSColor.tertiaryLabelColor;
    _turboTitle.stringValue = on ? @"Turbo ON" : @"Turbo OFF";
    _turboDetail.stringValue = [NSString stringWithFormat:@"%.1f GHz max", maxGHz];
    _turboSwitch.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)showSensor:(NSInteger)index celsius:(double)celsius {
    NSTextField *value = _sensorValues[(NSUInteger)index];
    value.stringValue = TemperatureText(celsius);
    value.textColor = celsius >= kHotCelsius    ? NSColor.systemRedColor
                    : celsius >= kWarmCelsius   ? NSColor.systemOrangeColor
                                                : NSColor.labelColor;
}

- (void)showSummary:(NSString *)summary forSection:(NSInteger)section {
    _sectionSummaries[(NSUInteger)section].stringValue = summary;
}

- (void)showFan:(int)index rpm:(double)rpm minRPM:(double)minRPM maxRPM:(double)maxRPM {
    [_fanRows[(NSUInteger)index] showRPM:rpm minRPM:minRPM maxRPM:maxRPM];
}

- (void)showFanOption:(NSInteger)index {
    _fanSpeed.selectedSegment = index;
}

#pragma mark Actions

// The menu closes first, because these actions can open a password prompt.
- (void)closeMenuThen:(dispatch_block_t)action {
    [self.enclosingMenuItem.menu cancelTracking];
    [NSRunLoop.mainRunLoop performInModes:@[NSDefaultRunLoopMode] block:action];
}

- (void)turboSwitchChanged:(NSSwitch *)sender {
    id<MenuPanelDelegate> delegate = _delegate;
    [self closeMenuThen:^{
        [delegate panelDidToggleTurbo];
    }];
}

- (void)fanSpeedChanged:(NSSegmentedControl *)sender {
    id<MenuPanelDelegate> delegate = _delegate;
    NSInteger index = sender.selectedSegment;
    [self closeMenuThen:^{
        [delegate panelDidChooseFanOption:index];
    }];
}

@end
