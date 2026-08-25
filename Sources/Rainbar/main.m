#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <stdlib.h>

@interface RainAudioController : NSObject

@property (nonatomic) float volume;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly, copy) NSString *trackIdentifier;

- (instancetype)initWithTrackIdentifier:(NSString *)trackIdentifier;
- (BOOL)prepareWithError:(NSError **)error;
- (void)preloadTrackIdentifiers:(NSArray<NSString *> *)trackIdentifiers;
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
- (BOOL)selectTrackIdentifier:(NSString *)trackIdentifier error:(NSError **)error;

@end

@implementation RainAudioController {
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_playerNodes[2];
    AVAudioMixerNode *_mixNode;
    AVAudioUnitEQ *_eqUnit;
    NSMutableDictionary<NSString *, NSURL *> *_urlsByTrackIdentifier;
    NSMutableDictionary<NSString *, NSNumber *> *_durationsByTrackIdentifier;
    BOOL _engineConfigured;
    BOOL _playing;
    NSString *_trackIdentifier;
    NSTimeInterval _currentTrackDuration;
    NSInteger _activeNodeIndex;
    float _nodeLevels[2];
    float _nodeTrackGains[2];
    NSTimeInterval _nodeRemainingDurations[2];
    NSTimeInterval _nodeStartTimes[2];
    NSTimer *_loopTimer;
    NSTimer *_fadeTimer;
    NSTimeInterval _fadeStartTime;
    NSTimeInterval _fadeDuration;
    float _fadeStartLevel;
    float _fadeTargetLevel;
    float _fadeLevel;
    void (^_fadeCompletion)(void);
    NSTimer *_crossfadeTimer;
    NSTimeInterval _crossfadeStartTime;
    NSTimeInterval _crossfadeDuration;
    NSInteger _crossfadeFromIndex;
    NSInteger _crossfadeToIndex;
    float _crossfadeStartFromLevel;
    float _crossfadeStartToLevel;
    void (^_crossfadeCompletion)(void);
}

- (instancetype)initWithTrackIdentifier:(NSString *)trackIdentifier {
    self = [super init];
    if (self) {
        _engine = [[AVAudioEngine alloc] init];
        _playerNodes[0] = [[AVAudioPlayerNode alloc] init];
        _playerNodes[1] = [[AVAudioPlayerNode alloc] init];
        _mixNode = [[AVAudioMixerNode alloc] init];
        _urlsByTrackIdentifier = [[NSMutableDictionary alloc] init];
        _durationsByTrackIdentifier = [[NSMutableDictionary alloc] init];
        _eqUnit = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
        AVAudioUnitEQFilterParameters *highPass = _eqUnit.bands.firstObject;
        highPass.filterType = AVAudioUnitEQFilterTypeHighPass;
        highPass.frequency = 120.0f;
        highPass.bandwidth = 0.5f;
        highPass.bypass = NO;
        _volume = 0.65f;
        _fadeLevel = 0.0f;
        _trackIdentifier = [trackIdentifier copy];
        _activeNodeIndex = 0;
        _nodeTrackGains[0] = 1.0f;
        _nodeTrackGains[1] = 1.0f;
    }
    return self;
}

- (BOOL)isPlaying {
    return _playing;
}

- (void)setVolume:(float)volume {
    _volume = fminf(1.0f, fmaxf(0.0f, volume));
    [self applyGain];
}

- (NSString *)trackIdentifier {
    return _trackIdentifier;
}

- (BOOL)prepareWithError:(NSError **)error {
    if (![self prepareEngineWithError:error]) {
        return NO;
    }

    _currentTrackDuration = [self durationForTrackIdentifier:_trackIdentifier error:error];
    if (_currentTrackDuration <= 0.0) {
        return NO;
    }

    [self applyGain];

    if (!_engine.isRunning && ![_engine startAndReturnError:error]) {
        return NO;
    }

    return YES;
}

- (void)preloadTrackIdentifiers:(NSArray<NSString *> *)trackIdentifiers {
    for (NSString *identifier in trackIdentifiers) {
        NSError *error = nil;
        if (![self validateTrackIdentifier:identifier error:&error]) {
            NSLog(@"Rainbar could not preload %@: %@", identifier, error.localizedDescription);
        }
    }
}

- (BOOL)startWithError:(NSError **)error {
    if (![self prepareWithError:error]) {
        return NO;
    }

    [self cancelFadeTimer];
    [self cancelLoopTimer];
    [self cancelCrossfadeTimer];
    [self stopAllPlayerNodes];

    _activeNodeIndex = 0;
    _currentTrackDuration = [self durationForTrackIdentifier:_trackIdentifier error:error];
    if (_currentTrackDuration <= 0.0) {
        return NO;
    }

    _fadeLevel = 0.0f;
    if (![self startTrackIdentifier:_trackIdentifier onNodeIndex:_activeNodeIndex level:1.0f error:error]) {
        return NO;
    }

    _playing = YES;
    [self scheduleLoopTimer];
    [self fadeToLevel:1.0f duration:0.45 completion:nil];

    return YES;
}

- (void)stop {
    _playing = NO;
    [self cancelLoopTimer];
    [self cancelCrossfadeTimer];

    if (!_playerNodes[0].isPlaying && !_playerNodes[1].isPlaying) {
        [self cancelFadeTimer];
        _fadeLevel = 0.0f;
        [self applyGain];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self fadeToLevel:0.0f duration:0.45 completion:^{
        [weakSelf finishStopAfterFade];
    }];
}

- (BOOL)selectTrackIdentifier:(NSString *)trackIdentifier error:(NSError **)error {
    if ([_trackIdentifier isEqualToString:trackIdentifier]) {
        return YES;
    }

    if (![self validateTrackIdentifier:trackIdentifier error:error]) {
        return NO;
    }

    NSTimeInterval nextDuration = [self durationForTrackIdentifier:trackIdentifier error:error];
    if (nextDuration <= 0.0) {
        return NO;
    }

    if (!_playing) {
        _trackIdentifier = [trackIdentifier copy];
        _currentTrackDuration = nextDuration;
        return YES;
    }

    [self cancelLoopTimer];
    [self cancelCrossfadeTimer];

    NSInteger oldNodeIndex = _activeNodeIndex;
    NSInteger nextNodeIndex = 1 - oldNodeIndex;
    _nodeLevels[oldNodeIndex] = 1.0f;

    if (![self startTrackIdentifier:trackIdentifier onNodeIndex:nextNodeIndex level:0.0f error:error]) {
        [self scheduleLoopTimer];
        return NO;
    }

    _trackIdentifier = [trackIdentifier copy];
    _currentTrackDuration = nextDuration;

    __weak typeof(self) weakSelf = self;
    [self crossfadeFromIndex:oldNodeIndex toIndex:nextNodeIndex duration:0.65 completion:^{
        [weakSelf finishCrossfadeToActiveIndex:nextNodeIndex stoppingIndex:oldNodeIndex];
    }];

    return YES;
}

- (BOOL)prepareEngineWithError:(NSError **)error {
    if (![self validateTrackIdentifier:_trackIdentifier error:error]) {
        return NO;
    }

    if (_engineConfigured) {
        return YES;
    }

    [_engine attachNode:_playerNodes[0]];
    [_engine attachNode:_playerNodes[1]];
    [_engine attachNode:_mixNode];
    [_engine attachNode:_eqUnit];
    [_engine connect:_playerNodes[0] to:_mixNode format:nil];
    [_engine connect:_playerNodes[1] to:_mixNode format:nil];
    [_engine connect:_mixNode to:_eqUnit format:nil];
    [_engine connect:_eqUnit to:_engine.mainMixerNode format:nil];
    [_engine prepare];

    _engineConfigured = YES;

    return YES;
}

- (BOOL)validateTrackIdentifier:(NSString *)trackIdentifier error:(NSError **)error {
    NSNumber *existingDuration = _durationsByTrackIdentifier[trackIdentifier];
    if (existingDuration) {
        return YES;
    }

    NSURL *trackURL = [self URLForTrackIdentifier:trackIdentifier error:error];
    if (!trackURL) {
        return NO;
    }

    AVAudioFile *file = [[AVAudioFile alloc] initForReading:trackURL error:error];
    if (!file) {
        return NO;
    }

    NSTimeInterval duration = [self durationForAudioFile:file];
    if (duration <= 0.0) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.grinich.rainbar"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@.mp3 did not contain readable audio.", trackIdentifier]}];
        }
        return NO;
    }

    _durationsByTrackIdentifier[trackIdentifier] = @(duration);

    return YES;
}

- (NSURL *)URLForTrackIdentifier:(NSString *)trackIdentifier error:(NSError **)error {
    NSURL *existing = _urlsByTrackIdentifier[trackIdentifier];
    if (existing) {
        return existing;
    }

    NSURL *rainURL = [[NSBundle mainBundle] URLForResource:trackIdentifier withExtension:@"mp3" subdirectory:@"Audio"];
    if (!rainURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.grinich.rainbar"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@.mp3 is missing from the app bundle.", trackIdentifier]}];
        }
        return nil;
    }

    _urlsByTrackIdentifier[trackIdentifier] = rainURL;

    return rainURL;
}

- (NSTimeInterval)durationForTrackIdentifier:(NSString *)trackIdentifier error:(NSError **)error {
    if (![self validateTrackIdentifier:trackIdentifier error:error]) {
        return 0.0;
    }

    return _durationsByTrackIdentifier[trackIdentifier].doubleValue;
}

- (NSTimeInterval)durationForAudioFile:(AVAudioFile *)file {
    double sampleRate = file.processingFormat.sampleRate;
    if (sampleRate <= 0.0) {
        return 0.0;
    }

    return (NSTimeInterval)((double)file.length / sampleRate);
}

- (BOOL)startTrackIdentifier:(NSString *)trackIdentifier onNodeIndex:(NSInteger)nodeIndex level:(float)level error:(NSError **)error {
    NSURL *trackURL = [self URLForTrackIdentifier:trackIdentifier error:error];
    if (!trackURL) {
        return NO;
    }

    AVAudioFile *file = [[AVAudioFile alloc] initForReading:trackURL error:error];
    if (!file) {
        return NO;
    }

    AVAudioPlayerNode *node = _playerNodes[nodeIndex];
    [node stop];
    _nodeLevels[nodeIndex] = fminf(1.0f, fmaxf(0.0f, level));
    _nodeTrackGains[nodeIndex] = [self linearGainForTrackIdentifier:trackIdentifier];
    [self applyGain];

    double sampleRate = file.processingFormat.sampleRate;
    NSTimeInterval startOffset = [self randomStartOffsetForDuration:[self durationForAudioFile:file]];
    AVAudioFramePosition startFrame = (AVAudioFramePosition)llround(startOffset * sampleRate);
    startFrame = MAX(0, MIN(startFrame, file.length - 1));

    AVAudioFramePosition remainingFrames = file.length - startFrame;
    if (remainingFrames <= 0 || remainingFrames > UINT32_MAX) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.grinich.rainbar"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@.mp3 could not be scheduled from a random start point.", trackIdentifier]}];
        }
        return NO;
    }

    _nodeRemainingDurations[nodeIndex] = (NSTimeInterval)((double)remainingFrames / sampleRate);
    _nodeStartTimes[nodeIndex] = [NSDate timeIntervalSinceReferenceDate];

    [node scheduleSegment:file
            startingFrame:startFrame
               frameCount:(AVAudioFrameCount)remainingFrames
                   atTime:nil
        completionHandler:nil];
    [node play];

    return YES;
}

- (float)linearGainForTrackIdentifier:(NSString *)trackIdentifier {
    static NSDictionary<NSString *, NSNumber *> *gainByTrackIdentifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gainByTrackIdentifier = @{
            @"TentRoof": @(-8.0f),
            @"HawaiiLanai": @(6.0f),
            @"RooftopTentStorm": @(0.5f),
            @"TropicalTerrace": @(-5.5f),
            @"RainyCityTraffic": @(-8.0f),
            @"BangladeshRainStreet": @(-4.0f),
            @"HeavyRuralRain": @(0.0f),
            @"ForestCanopy": @(5.0f),
            @"ArizonaMonsoon": @(5.0f),
            @"LeipzigSpringRain": @(6.0f),
            @"ManhattanStorm": @(4.0f),
            @"SouthLondonRain": @(-7.0f),
            @"SonoraDesert": @(-5.5f),
            @"TorontoWetStreets": @(5.5f)
        };
    });

    NSNumber *gainInDecibels = gainByTrackIdentifier[trackIdentifier];
    if (!gainInDecibels) {
        return 1.0f;
    }

    return powf(10.0f, gainInDecibels.floatValue / 20.0f);
}

- (NSTimeInterval)randomStartOffsetForDuration:(NSTimeInterval)duration {
    NSTimeInterval maxOffset = fmin(30.0, fmax(0.0, duration - 30.0));
    if (maxOffset <= 0.0) {
        return 0.0;
    }

    uint32_t maxMilliseconds = (uint32_t)floor(maxOffset * 1000.0);
    return (NSTimeInterval)arc4random_uniform(maxMilliseconds + 1) / 1000.0;
}

- (NSTimeInterval)remainingDurationForNodeIndex:(NSInteger)nodeIndex {
    NSTimeInterval remainingDuration = _nodeRemainingDurations[nodeIndex];
    if (remainingDuration <= 0.0) {
        return _currentTrackDuration;
    }

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - _nodeStartTimes[nodeIndex];
    return fmax(0.0, remainingDuration - elapsed);
}

- (void)scheduleLoopTimer {
    [self cancelLoopTimer];

    if (!_playing || _currentTrackDuration <= 0.0) {
        return;
    }

    NSTimeInterval remainingDuration = [self remainingDurationForNodeIndex:_activeNodeIndex];
    NSTimeInterval crossfadeDuration = [self loopCrossfadeDurationForDuration:remainingDuration];
    NSTimeInterval delay = fmax(0.25, remainingDuration - crossfadeDuration);

    _loopTimer = [NSTimer timerWithTimeInterval:delay
                                         target:self
                                       selector:@selector(beginLoopCrossfade:)
                                       userInfo:nil
                                        repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_loopTimer forMode:NSRunLoopCommonModes];
}

- (NSTimeInterval)loopCrossfadeDurationForDuration:(NSTimeInterval)duration {
    if (duration <= 10.0) {
        return fmax(1.0, duration / 3.0);
    }

    return fmin(8.0, fmax(5.0, duration * 0.02));
}

- (void)beginLoopCrossfade:(NSTimer *)timer {
    (void)timer;
    _loopTimer = nil;

    if (!_playing) {
        return;
    }

    [self cancelCrossfadeTimer];

    NSInteger fromIndex = _activeNodeIndex;
    NSInteger toIndex = 1 - fromIndex;
    NSError *error = nil;
    if (![self startTrackIdentifier:_trackIdentifier onNodeIndex:toIndex level:0.0f error:&error]) {
        NSLog(@"Rainbar could not schedule loop for %@: %@", _trackIdentifier, error.localizedDescription);
        [self scheduleLoopTimer];
        return;
    }

    _nodeLevels[fromIndex] = 1.0f;

    NSTimeInterval remainingDuration = [self remainingDurationForNodeIndex:fromIndex];
    NSTimeInterval duration = fmin([self loopCrossfadeDurationForDuration:remainingDuration], fmax(0.4, remainingDuration));
    __weak typeof(self) weakSelf = self;
    [self crossfadeFromIndex:fromIndex toIndex:toIndex duration:duration completion:^{
        [weakSelf finishCrossfadeToActiveIndex:toIndex stoppingIndex:fromIndex];
    }];
}

- (void)finishCrossfadeToActiveIndex:(NSInteger)activeNodeIndex stoppingIndex:(NSInteger)stoppingNodeIndex {
    [_playerNodes[stoppingNodeIndex] stop];
    _nodeLevels[stoppingNodeIndex] = 0.0f;
    _nodeLevels[activeNodeIndex] = 1.0f;
    _activeNodeIndex = activeNodeIndex;
    [self applyGain];

    if (_playing) {
        [self scheduleLoopTimer];
    }
}

- (void)finishStopAfterFade {
    [self cancelLoopTimer];
    [self cancelCrossfadeTimer];
    [self stopAllPlayerNodes];
    _fadeLevel = 0.0f;
    [self applyGain];
}

- (void)stopAllPlayerNodes {
    [_playerNodes[0] stop];
    [_playerNodes[1] stop];
    _nodeLevels[0] = 0.0f;
    _nodeLevels[1] = 0.0f;
    _nodeRemainingDurations[0] = 0.0;
    _nodeRemainingDurations[1] = 0.0;
    _nodeStartTimes[0] = 0.0;
    _nodeStartTimes[1] = 0.0;
}

- (void)fadeToLevel:(float)targetLevel duration:(NSTimeInterval)duration completion:(void (^)(void))completion {
    [self cancelFadeTimer];

    _fadeStartLevel = _fadeLevel;
    _fadeTargetLevel = fminf(1.0f, fmaxf(0.0f, targetLevel));
    _fadeDuration = duration;
    _fadeStartTime = [NSDate timeIntervalSinceReferenceDate];
    _fadeCompletion = [completion copy];

    if (duration <= 0.0) {
        _fadeLevel = _fadeTargetLevel;
        [self applyGain];
        [self completeFade];
        return;
    }

    _fadeTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                         target:self
                                       selector:@selector(advanceFade:)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_fadeTimer forMode:NSRunLoopCommonModes];
}

- (void)advanceFade:(NSTimer *)timer {
    (void)timer;

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - _fadeStartTime;
    float progress = (float)fmin(1.0, fmax(0.0, elapsed / _fadeDuration));
    float easedProgress = progress * progress * (3.0f - 2.0f * progress);
    _fadeLevel = _fadeStartLevel + ((_fadeTargetLevel - _fadeStartLevel) * easedProgress);
    [self applyGain];

    if (progress >= 1.0f) {
        [self completeFade];
    }
}

- (void)completeFade {
    [_fadeTimer invalidate];
    _fadeTimer = nil;

    void (^completion)(void) = _fadeCompletion;
    _fadeCompletion = nil;

    if (completion) {
        completion();
    }
}

- (void)cancelFadeTimer {
    [_fadeTimer invalidate];
    _fadeTimer = nil;
    _fadeCompletion = nil;
}

- (void)crossfadeFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex duration:(NSTimeInterval)duration completion:(void (^)(void))completion {
    [self cancelCrossfadeTimer];

    _crossfadeFromIndex = fromIndex;
    _crossfadeToIndex = toIndex;
    _crossfadeStartFromLevel = _nodeLevels[fromIndex];
    _crossfadeStartToLevel = _nodeLevels[toIndex];
    _crossfadeDuration = duration;
    _crossfadeStartTime = [NSDate timeIntervalSinceReferenceDate];
    _crossfadeCompletion = [completion copy];

    if (duration <= 0.0) {
        _nodeLevels[fromIndex] = 0.0f;
        _nodeLevels[toIndex] = 1.0f;
        [self applyGain];
        [self completeCrossfade];
        return;
    }

    _crossfadeTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                              target:self
                                            selector:@selector(advanceCrossfade:)
                                            userInfo:nil
                                             repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_crossfadeTimer forMode:NSRunLoopCommonModes];
}

- (void)advanceCrossfade:(NSTimer *)timer {
    (void)timer;

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - _crossfadeStartTime;
    float progress = (float)fmin(1.0, fmax(0.0, elapsed / _crossfadeDuration));
    float easedProgress = progress * progress * (3.0f - 2.0f * progress);

    _nodeLevels[_crossfadeFromIndex] = _crossfadeStartFromLevel * (1.0f - easedProgress);
    _nodeLevels[_crossfadeToIndex] = _crossfadeStartToLevel + ((1.0f - _crossfadeStartToLevel) * easedProgress);
    [self applyGain];

    if (progress >= 1.0f) {
        [self completeCrossfade];
    }
}

- (void)completeCrossfade {
    [_crossfadeTimer invalidate];
    _crossfadeTimer = nil;

    void (^completion)(void) = _crossfadeCompletion;
    _crossfadeCompletion = nil;

    if (completion) {
        completion();
    }
}

- (void)cancelLoopTimer {
    [_loopTimer invalidate];
    _loopTimer = nil;
}

- (void)cancelCrossfadeTimer {
    [_crossfadeTimer invalidate];
    _crossfadeTimer = nil;
    _crossfadeCompletion = nil;
}

- (void)applyGain {
    float volume = fminf(1.0f, fmaxf(0.0f, _volume));

    if (volume <= 0.001f || _fadeLevel <= 0.001f) {
        _playerNodes[0].volume = 0.0f;
        _playerNodes[1].volume = 0.0f;
        _eqUnit.globalGain = 0.0f;
        return;
    }

    _playerNodes[0].volume = _fadeLevel * _nodeLevels[0] * _nodeTrackGains[0];
    _playerNodes[1].volume = _fadeLevel * _nodeLevels[1] * _nodeTrackGains[1];

    if (volume <= 0.5f) {
        float normalized = volume / 0.5f;
        _eqUnit.globalGain = -36.0f + (sqrtf(normalized) * 36.0f);
    } else {
        _eqUnit.globalGain = ((volume - 0.5f) / 0.5f) * 6.0f;
    }
}

@end

@interface RainTrackRowView : NSControl

@property (nonatomic, readonly, copy) NSString *trackIdentifier;
@property (nonatomic, getter=isSelected) BOOL selected;

- (instancetype)initWithTitle:(NSString *)title trackIdentifier:(NSString *)trackIdentifier;

@end

@implementation RainTrackRowView {
    NSTextField *_titleLabel;
    BOOL _hovered;
    BOOL _pressed;
}

- (instancetype)initWithTitle:(NSString *)title trackIdentifier:(NSString *)trackIdentifier {
    self = [super initWithFrame:NSMakeRect(0.0, 0.0, 250.0, 24.0)];
    if (!self) {
        return nil;
    }

    _trackIdentifier = [trackIdentifier copy];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self.widthAnchor constraintEqualToConstant:250.0].active = YES;
    [self.heightAnchor constraintEqualToConstant:24.0].active = YES;

    _titleLabel = [NSTextField labelWithString:title];
    _titleLabel.font = [NSFont menuFontOfSize:0.0];
    _titleLabel.textColor = NSColor.labelColor;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-10.0],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];

    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    for (NSTrackingArea *trackingArea in self.trackingAreas.copy) {
        [self removeTrackingArea:trackingArea];
    }

    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect;
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                                options:options
                                                                  owner:self
                                                               userInfo:nil];
    [self addTrackingArea:trackingArea];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)setSelected:(BOOL)selected {
    if (_selected == selected) {
        return;
    }

    _selected = selected;
    [self setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    _pressed = NO;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    _pressed = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _pressed = NO;
    [self setNeedsDisplay:YES];

    if (NSPointInRect(point, self.bounds)) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    if (self.selected || _hovered || _pressed) {
        if (self.selected) {
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.11] setFill];
        } else {
            CGFloat alpha = _pressed ? 0.14 : 0.08;
            [[NSColor.labelColor colorWithAlphaComponent:alpha] setFill];
        }

        NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1.0, 1.0)
                                                                       xRadius:5.0
                                                                       yRadius:5.0];
        [backgroundPath fill];
    }
}

@end

@interface RainControlsRowView : NSView

@end

@implementation RainControlsRowView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self.widthAnchor constraintEqualToConstant:250.0].active = YES;
    [self.heightAnchor constraintEqualToConstant:28.0].active = YES;

    return self;
}

@end

@interface RainMenuView : NSView

@property (nonatomic, copy) void (^volumeHandler)(float volume);
@property (nonatomic, copy) void (^toggleHandler)(BOOL shouldPlay);
@property (nonatomic, copy) void (^trackHandler)(NSString *trackIdentifier);

- (instancetype)initWithInitialVolume:(float)initialVolume
                               tracks:(NSArray<NSDictionary<NSString *, NSString *> *> *)tracks
              selectedTrackIdentifier:(NSString *)selectedTrackIdentifier;
- (void)setPlaybackEnabled:(BOOL)enabled;
- (void)setDisplayedVolume:(float)volume;
- (void)setDisplayedVolume:(float)volume animated:(BOOL)animated;
- (void)setSelectedTrackIdentifier:(NSString *)selectedTrackIdentifier;

@end

@implementation RainMenuView {
    RainControlsRowView *_controlsRow;
    NSSwitch *_powerSwitch;
    NSSlider *_volumeSlider;
    NSMutableDictionary<NSString *, RainTrackRowView *> *_trackRowsByIdentifier;
    NSTimer *_volumeAnimationTimer;
    NSTimeInterval _volumeAnimationStartTime;
    NSTimeInterval _volumeAnimationDuration;
    double _volumeAnimationStartValue;
    double _volumeAnimationTargetValue;
}

- (instancetype)initWithInitialVolume:(float)initialVolume
                               tracks:(NSArray<NSDictionary<NSString *, NSString *> *> *)tracks
              selectedTrackIdentifier:(NSString *)selectedTrackIdentifier {
    CGFloat viewHeight = 56.0 + ((CGFloat)tracks.count * 26.0);
    self = [super initWithFrame:NSMakeRect(0.0, 0.0, 278.0, viewHeight)];
    if (!self) {
        return nil;
    }

    _trackRowsByIdentifier = [[NSMutableDictionary alloc] initWithCapacity:tracks.count];

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 2.0;
    stack.edgeInsets = NSEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];

    _controlsRow = [[RainControlsRowView alloc] initWithFrame:NSZeroRect];

    NSStackView *volumeRow = [[NSStackView alloc] init];
    volumeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    volumeRow.alignment = NSLayoutAttributeCenterY;
    volumeRow.spacing = 8.0;
    volumeRow.translatesAutoresizingMaskIntoConstraints = NO;
    [_controlsRow addSubview:volumeRow];

    [NSLayoutConstraint activateConstraints:@[
        [volumeRow.leadingAnchor constraintEqualToAnchor:_controlsRow.leadingAnchor constant:4.0],
        [volumeRow.trailingAnchor constraintEqualToAnchor:_controlsRow.trailingAnchor constant:-4.0],
        [volumeRow.centerYAnchor constraintEqualToAnchor:_controlsRow.centerYAnchor]
    ]];

    _powerSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    _powerSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _powerSwitch.state = NSControlStateValueOff;
    _powerSwitch.controlSize = NSControlSizeSmall;
    _powerSwitch.target = self;
    _powerSwitch.action = @selector(toggleChanged:);
    [_powerSwitch.widthAnchor constraintEqualToConstant:38.0].active = YES;

    _volumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(0.0, 0.0, 196.0, 18.0)];
    _volumeSlider.minValue = 0.0;
    _volumeSlider.maxValue = 1.0;
    _volumeSlider.doubleValue = initialVolume;
    _volumeSlider.controlSize = NSControlSizeSmall;
    _volumeSlider.target = self;
    _volumeSlider.action = @selector(volumeChanged:);
    [_volumeSlider.widthAnchor constraintEqualToConstant:196.0].active = YES;

    [volumeRow addArrangedSubview:_powerSwitch];
    [volumeRow addArrangedSubview:_volumeSlider];
    [stack addArrangedSubview:_controlsRow];
    [stack setCustomSpacing:5.0 afterView:_controlsRow];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    [separator.widthAnchor constraintEqualToConstant:250.0].active = YES;
    [stack addArrangedSubview:separator];
    [stack setCustomSpacing:6.0 afterView:separator];

    for (NSDictionary<NSString *, NSString *> *track in tracks) {
        NSString *title = track[@"title"];
        NSString *identifier = track[@"identifier"];

        RainTrackRowView *trackRow = [[RainTrackRowView alloc] initWithTitle:title trackIdentifier:identifier];
        trackRow.target = self;
        trackRow.action = @selector(trackChanged:);
        [_trackRowsByIdentifier setObject:trackRow forKey:identifier];
        [stack addArrangedSubview:trackRow];
    }

    [self setSelectedTrackIdentifier:selectedTrackIdentifier];

    return self;
}

- (void)volumeChanged:(id)sender {
    [self cancelVolumeAnimation];

    if (self.volumeHandler) {
        self.volumeHandler((float)_volumeSlider.doubleValue);
    }
}

- (void)toggleChanged:(id)sender {
    (void)sender;

    BOOL shouldPlay = _powerSwitch.state == NSControlStateValueOn;
    if (shouldPlay && _volumeSlider.doubleValue <= 0.001) {
        if (self.volumeHandler) {
            self.volumeHandler(0.20f);
        }
        return;
    }

    if (self.toggleHandler) {
        self.toggleHandler(shouldPlay);
    }
}

- (void)setPlaybackEnabled:(BOOL)enabled {
    _powerSwitch.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setDisplayedVolume:(float)volume {
    [self setDisplayedVolume:volume animated:NO];
}

- (void)setDisplayedVolume:(float)volume animated:(BOOL)animated {
    double targetValue = fminf(1.0f, fmaxf(0.0f, volume));

    if (!animated) {
        [self cancelVolumeAnimation];
        _volumeSlider.doubleValue = targetValue;
        return;
    }

    [self cancelVolumeAnimation];

    _volumeAnimationStartValue = _volumeSlider.doubleValue;
    _volumeAnimationTargetValue = targetValue;
    _volumeAnimationStartTime = [NSDate timeIntervalSinceReferenceDate];
    _volumeAnimationDuration = 0.45;

    if (fabs(_volumeAnimationStartValue - _volumeAnimationTargetValue) <= 0.001) {
        _volumeSlider.doubleValue = _volumeAnimationTargetValue;
        return;
    }

    _volumeAnimationTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                                    target:self
                                                  selector:@selector(advanceVolumeAnimation:)
                                                  userInfo:nil
                                                   repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_volumeAnimationTimer forMode:NSRunLoopCommonModes];
}

- (void)cancelVolumeAnimation {
    [_volumeAnimationTimer invalidate];
    _volumeAnimationTimer = nil;
}

- (void)advanceVolumeAnimation:(NSTimer *)timer {
    (void)timer;

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - _volumeAnimationStartTime;
    double progress = fmin(1.0, fmax(0.0, elapsed / _volumeAnimationDuration));
    double easedProgress = progress < 0.5
        ? 4.0 * progress * progress * progress
        : 1.0 - pow(-2.0 * progress + 2.0, 3.0) / 2.0;

    _volumeSlider.doubleValue = _volumeAnimationStartValue + ((_volumeAnimationTargetValue - _volumeAnimationStartValue) * easedProgress);

    if (progress >= 1.0) {
        _volumeSlider.doubleValue = _volumeAnimationTargetValue;
        [self cancelVolumeAnimation];
    }
}

- (void)trackChanged:(id)sender {
    if (![sender isKindOfClass:RainTrackRowView.class]) {
        return;
    }

    RainTrackRowView *trackRow = sender;
    NSString *trackIdentifier = trackRow.trackIdentifier;
    if (![trackIdentifier isKindOfClass:NSString.class]) {
        return;
    }

    [self setSelectedTrackIdentifier:trackIdentifier];

    if (self.trackHandler) {
        self.trackHandler(trackIdentifier);
    }
}

- (void)setSelectedTrackIdentifier:(NSString *)selectedTrackIdentifier {
    for (NSString *identifier in _trackRowsByIdentifier) {
        RainTrackRowView *trackRow = _trackRowsByIdentifier[identifier];
        trackRow.selected = [identifier isEqualToString:selectedTrackIdentifier];
    }
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation AppDelegate {
    RainAudioController *_audio;
    NSStatusItem *_statusItem;
    NSMenu *_statusMenu;
    RainMenuView *_menuView;
    NSArray<NSDictionary<NSString *, NSString *> *> *_tracks;
    NSTimer *_rainAnimationTimer;
    NSInteger _rainAnimationFrame;
    float _lastNonZeroVolume;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [self configureTracks];
    _audio = [[RainAudioController alloc] initWithTrackIdentifier:@"HeavyRuralRain"];
    _lastNonZeroVolume = _audio.volume;
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    [self configureStatusItem];
    [self configureMenu];
    [self prewarmAudio];
}

- (void)configureStatusItem {
    NSStatusBarButton *button = _statusItem.button;
    button.toolTip = @"Rainbar";
    button.target = self;
    button.action = @selector(statusItemClicked:);
    [button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [self setStatusImageForPlaying:NO];
}

- (void)configureTracks {
    _tracks = @[
        @{@"title": @"Siberian Tent Rain", @"identifier": @"TentRoof", @"detail": @"2:11"},
        @{@"title": @"Hawaii Lanai", @"identifier": @"HawaiiLanai", @"detail": @"2:04"},
        @{@"title": @"Italy Rooftop Storm", @"identifier": @"RooftopTentStorm", @"detail": @"3:16"},
        @{@"title": @"Tropical Island Rain", @"identifier": @"TropicalTerrace", @"detail": @"4:47"},
        @{@"title": @"Sweden Traffic Rain", @"identifier": @"RainyCityTraffic", @"detail": @"5:00"},
        @{@"title": @"Bangladesh Rain Street", @"identifier": @"BangladeshRainStreet", @"detail": @"6:06"},
        @{@"title": @"Brazil Rural Rain", @"identifier": @"HeavyRuralRain", @"detail": @"6:40"},
        @{@"title": @"Forest Canopy", @"identifier": @"ForestCanopy", @"detail": @"9:01"},
        @{@"title": @"Arizona Monsoon", @"identifier": @"ArizonaMonsoon", @"detail": @"12:49"},
        @{@"title": @"Germany Spring Rain", @"identifier": @"LeipzigSpringRain", @"detail": @"7:56"},
        @{@"title": @"New York Storm", @"identifier": @"ManhattanStorm", @"detail": @"12:18"},
        @{@"title": @"London Rain", @"identifier": @"SouthLondonRain", @"detail": @"14:42"},
        @{@"title": @"Mexico Desert Storm", @"identifier": @"SonoraDesert", @"detail": @"11:00"},
        @{@"title": @"Toronto Wet Streets", @"identifier": @"TorontoWetStreets", @"detail": @"4:20"}
    ];
}

- (void)configureMenu {
    _statusMenu = [[NSMenu alloc] initWithTitle:@"Rainbar"];
    _statusMenu.delegate = self;

    _menuView = [[RainMenuView alloc] initWithInitialVolume:0.0f
                                                     tracks:_tracks
                                    selectedTrackIdentifier:_audio.trackIdentifier];

    __weak typeof(self) weakSelf = self;
    _menuView.volumeHandler = ^(float volume) {
        [weakSelf setRainVolume:volume];
    };

    _menuView.toggleHandler = ^(BOOL shouldPlay) {
        [weakSelf setRainPlaying:shouldPlay];
    };

    _menuView.trackHandler = ^(NSString *trackIdentifier) {
        [weakSelf selectTrackIdentifier:trackIdentifier];
    };

    NSMenuItem *controlsItem = [[NSMenuItem alloc] init];
    controlsItem.view = _menuView;
    [_statusMenu addItem:controlsItem];
    [_statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Rainbar" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [_statusMenu addItem:quitItem];
}

- (void)statusItemClicked:(id)sender {
    (void)sender;

    [self showStatusMenu];
}

- (void)showStatusMenu {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [_statusItem popUpStatusItemMenu:_statusMenu];
#pragma clang diagnostic pop
}

- (void)selectTrackIdentifier:(NSString *)trackIdentifier {
    NSError *error = nil;
    BOOL wasPlaying = _audio.playing;
    if (![_audio selectTrackIdentifier:trackIdentifier error:&error]) {
        [self presentAudioError:error];
        [_menuView setSelectedTrackIdentifier:_audio.trackIdentifier];
        return;
    }

    [_menuView setSelectedTrackIdentifier:_audio.trackIdentifier];

    if (!wasPlaying) {
        [self setRainPlaying:YES];
    }
}

- (void)setRainPlaying:(BOOL)shouldPlay {
    if (shouldPlay) {
        if (_audio.volume <= 0.001f) {
            _audio.volume = _lastNonZeroVolume > 0.001f ? _lastNonZeroVolume : 0.65f;
        }

        NSError *error = nil;
        if (![_audio startWithError:&error]) {
            [self presentAudioError:error];
            [self stopRainIconAnimation];
            return;
        }

        [self startRainIconAnimation];
    } else {
        [_audio stop];
        [self stopRainIconAnimation];
    }

    [_menuView setDisplayedVolume:shouldPlay ? _audio.volume : 0.0f animated:YES];
    [_menuView setPlaybackEnabled:shouldPlay];
    [self setStatusImageForPlaying:shouldPlay];
}

- (void)setRainVolume:(float)volume {
    float clampedVolume = fminf(1.0f, fmaxf(0.0f, volume));

    if (clampedVolume <= 0.001f) {
        if (_audio.playing) {
            [self setRainPlaying:NO];
        }

        [_menuView setDisplayedVolume:0.0f];
        return;
    }

    _lastNonZeroVolume = clampedVolume;
    _audio.volume = clampedVolume;

    if (!_audio.playing) {
        [self setRainPlaying:YES];
    } else {
        [_menuView setDisplayedVolume:clampedVolume];
        [self setStatusImageForPlaying:YES];
    }
}

- (void)prewarmAudio {
    NSMutableArray<NSString *> *trackIdentifiers = [[NSMutableArray alloc] initWithCapacity:_tracks.count];
    for (NSDictionary<NSString *, NSString *> *track in _tracks) {
        [trackIdentifiers addObject:track[@"identifier"]];
    }

    [_audio preloadTrackIdentifiers:trackIdentifiers];

    NSError *error = nil;
    if (![_audio prepareWithError:&error]) {
        NSLog(@"Rainbar audio prewarm failed: %@", error.localizedDescription);
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [_menuView setPlaybackEnabled:_audio.playing];
    [_menuView setDisplayedVolume:_audio.playing ? _audio.volume : 0.0f];
    [_menuView setSelectedTrackIdentifier:_audio.trackIdentifier];
}

- (void)setStatusImageForPlaying:(BOOL)playing {
    NSStatusBarButton *button = _statusItem.button;
    if (!button) {
        return;
    }

    button.image = [self statusImageForPlaying:playing frame:_rainAnimationFrame intensity:[self rainIntensityLevel]];
    button.title = @"";
}

- (void)startRainIconAnimation {
    if (_rainAnimationTimer) {
        return;
    }

    _rainAnimationFrame = 0;
    _rainAnimationTimer = [NSTimer timerWithTimeInterval:0.18
                                                  target:self
                                                selector:@selector(advanceRainIcon:)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_rainAnimationTimer forMode:NSRunLoopCommonModes];
}

- (void)stopRainIconAnimation {
    [_rainAnimationTimer invalidate];
    _rainAnimationTimer = nil;
    _rainAnimationFrame = 0;
    [self setStatusImageForPlaying:NO];
}

- (void)advanceRainIcon:(NSTimer *)timer {
    (void)timer;

    _rainAnimationFrame = (_rainAnimationFrame + 1) % 8;
    [self setStatusImageForPlaying:YES];
}

- (NSInteger)rainIntensityLevel {
    float volume = fminf(1.0f, fmaxf(0.0f, _audio.volume));

    if (volume < 0.25f) {
        return 1;
    }

    if (volume < 0.50f) {
        return 2;
    }

    if (volume < 0.75f) {
        return 3;
    }

    return 4;
}

- (NSImage *)statusImageForPlaying:(BOOL)playing frame:(NSInteger)frame intensity:(NSInteger)intensity {
    NSSize size = NSMakeSize(24.0, 20.0);
    NSImage *image = [[NSImage alloc] initWithSize:size];

    [image lockFocus];

    [[NSColor blackColor] setFill];

    NSBezierPath *cloud = [NSBezierPath bezierPath];
    [cloud moveToPoint:NSMakePoint(6.0, 7.2)];
    [cloud curveToPoint:NSMakePoint(4.0, 10.0)
          controlPoint1:NSMakePoint(4.8, 7.2)
          controlPoint2:NSMakePoint(4.0, 8.4)];
    [cloud curveToPoint:NSMakePoint(7.8, 13.1)
          controlPoint1:NSMakePoint(4.0, 11.8)
          controlPoint2:NSMakePoint(5.7, 13.1)];
    [cloud curveToPoint:NSMakePoint(13.0, 16.2)
          controlPoint1:NSMakePoint(8.5, 15.3)
          controlPoint2:NSMakePoint(10.9, 16.7)];
    [cloud curveToPoint:NSMakePoint(18.6, 14.8)
          controlPoint1:NSMakePoint(15.0, 17.6)
          controlPoint2:NSMakePoint(17.8, 16.9)];
    [cloud curveToPoint:NSMakePoint(22.0, 11.0)
          controlPoint1:NSMakePoint(20.7, 14.6)
          controlPoint2:NSMakePoint(22.0, 12.8)];
    [cloud curveToPoint:NSMakePoint(17.9, 7.2)
          controlPoint1:NSMakePoint(22.0, 8.8)
          controlPoint2:NSMakePoint(20.1, 7.2)];
    [cloud lineToPoint:NSMakePoint(6.0, 7.2)];
    [cloud closePath];
    [cloud fill];

    if (playing) {
        NSInteger level = MAX(1, MIN(4, intensity));
        NSUInteger dropCount = (NSUInteger)(level * 2);
        CGFloat speed = 0.85 + ((CGFloat)level * 0.22);
        CGFloat baseOffset = (CGFloat)(frame % 8) * speed;
        NSArray<NSNumber *> *xs = @[@7.0, @17.0, @11.0, @20.0, @5.0, @14.0, @9.0, @18.0];
        NSArray<NSNumber *> *phases = @[@0.0, @2.4, @1.1, @3.6, @4.7, @5.8, @6.9, @7.9];

        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.88] setStroke];

        for (NSUInteger index = 0; index < dropCount; index++) {
            CGFloat x = xs[index].doubleValue;
            CGFloat phase = phases[index].doubleValue;
            CGFloat cycle = 6.2;
            CGFloat y = 6.4 - fmod(baseOffset + phase, cycle);
            CGFloat length = 2.2 + ((CGFloat)level * 0.25);

            NSBezierPath *drop = [NSBezierPath bezierPath];
            drop.lineWidth = level >= 3 ? 1.35 : 1.2;
            [drop setLineCapStyle:NSLineCapStyleRound];
            [drop moveToPoint:NSMakePoint(x + 0.6, y)];
            [drop lineToPoint:NSMakePoint(x - 0.45, y - length)];
            [drop stroke];
        }
    }

    [image unlockFocus];
    image.template = YES;

    return image;
}

- (void)presentAudioError:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rainbar could not start audio.";
    alert.informativeText = error.localizedDescription ?: @"Unknown audio error.";
    [alert runModal];
}

- (void)quit:(id)sender {
    (void)sender;

    [_rainAnimationTimer invalidate];
    [_audio stop];
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }

    return 0;
}
