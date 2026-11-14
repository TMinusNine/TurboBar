// The custom content of TurboBar's menu: Turbo header, temperatures, fan readouts and fan speed control.

#import <AppKit/AppKit.h>

// "72°", or a dash when the reading is NAN.
NSString *TemperatureText(double celsius);

@protocol MenuPanelDelegate <NSObject>
- (void)panelDidToggleTurbo;
- (void)panelDidChooseFanOption:(NSInteger)index;
@end

@interface MenuPanel : NSView

// Each section has a title and the names of its sensors. Sensors are later
// addressed by their position across all sections, in order.
- (instancetype)initWithSensorSections:(NSArray<NSString *> *)sectionTitles
                           sensorNames:(NSArray<NSArray<NSString *> *> *)sensorNames
                              fanCount:(int)fanCount
                            fanOptions:(NSArray<NSString *> *)fanOptions
                              delegate:(id<MenuPanelDelegate>)delegate;

- (void)showTurboOn:(BOOL)on maxGHz:(double)maxGHz;
- (void)showSensor:(NSInteger)index celsius:(double)celsius;
- (void)showSummary:(NSString *)summary forSection:(NSInteger)section;
- (void)showFan:(int)index rpm:(double)rpm minRPM:(double)minRPM maxRPM:(double)maxRPM;
- (void)showFanOption:(NSInteger)index;

@end
