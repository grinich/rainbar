#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ServiceManagement/ServiceManagement.h>
#import <math.h>
#import <stdlib.h>
#import <unistd.h>

static NSString *const RainbarErrorDomain = @"com.grinich.rainbar";
static NSString *const RainbarSelectedTrackIdentifierDefaultsKey = @"RainbarSelectedTrackIdentifier";
static NSString *const RainbarVolumeDefaultsKey = @"RainbarVolume";
static NSString *const RainbarLastUpdateCheckDateDefaultsKey = @"RainbarLastUpdateCheckDate";

@interface RainUpdater : NSObject

@property (nonatomic, copy) void (^busyHandler)(BOOL busy);

- (instancetype)initWithOwner:(NSString *)owner
                         repo:(NSString *)repo
                    assetName:(NSString *)assetName;
- (void)checkAutomatically;
- (void)checkManually;

@end

@implementation RainUpdater {
    NSString *_owner;
    NSString *_repo;
    NSString *_assetName;
    BOOL _busy;
    NSURLSessionDataTask *_releaseTask;
    NSURLSessionDownloadTask *_downloadTask;
}

- (instancetype)initWithOwner:(NSString *)owner
                         repo:(NSString *)repo
                    assetName:(NSString *)assetName {
    self = [super init];
    if (!self) {
        return nil;
    }

    _owner = [owner copy];
    _repo = [repo copy];
    _assetName = [assetName copy];

    return self;
}

- (void)checkAutomatically {
    NSDate *lastCheckDate = [[NSUserDefaults standardUserDefaults] objectForKey:RainbarLastUpdateCheckDateDefaultsKey];
    if ([lastCheckDate isKindOfClass:NSDate.class] && [[NSDate date] timeIntervalSinceDate:lastCheckDate] < (24.0 * 60.0 * 60.0)) {
        NSLog(@"Rainbar updater: skipped automatic check because it already ran recently.");
        return;
    }

    [self checkForUpdatesPresentingNoUpdate:NO];
}

- (void)checkManually {
    [self checkForUpdatesPresentingNoUpdate:YES];
}

- (void)checkForUpdatesPresentingNoUpdate:(BOOL)presentNoUpdate {
    if (_busy) {
        return;
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest", _owner, _repo]];
    if (!url) {
        return;
    }

    [self setBusy:YES];
    NSLog(@"Rainbar updater: checking GitHub Releases.");

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"Rainbar/%@", [self currentVersion]] forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    _releaseTask = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleReleaseResponseData:data response:response error:error presentingNoUpdate:presentNoUpdate];
        });
    }];
    [_releaseTask resume];
}

- (void)handleReleaseResponseData:(NSData *)data
                          response:(NSURLResponse *)response
                             error:(NSError *)error
                presentingNoUpdate:(BOOL)presentNoUpdate {
    _releaseTask = nil;

    if (error) {
        [self setBusy:NO];
        [self presentErrorIfNeeded:error presenting:presentNoUpdate];
        return;
    }

    NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        NSError *statusError = [self errorWithDescription:[NSString stringWithFormat:@"GitHub returned HTTP %ld while checking for updates.", (long)httpResponse.statusCode]
                                                     code:20];
        [self setBusy:NO];
        [self presentErrorIfNeeded:statusError presenting:presentNoUpdate];
        return;
    }

    NSError *jsonError = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!jsonObject || ![jsonObject isKindOfClass:NSDictionary.class]) {
        [self setBusy:NO];
        [self presentErrorIfNeeded:jsonError ?: [self errorWithDescription:@"GitHub returned an unreadable update response." code:21]
                         presenting:presentNoUpdate];
        return;
    }

    NSDictionary *release = (NSDictionary *)jsonObject;
    NSString *tagName = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : nil;
    NSString *latestVersion = [self normalizedVersionString:tagName];
    NSURL *downloadURL = [self downloadURLFromRelease:release];

    if (latestVersion.length == 0 || !downloadURL) {
        [self setBusy:NO];
        [self presentErrorIfNeeded:[self errorWithDescription:@"The latest GitHub release does not include a Rainbar app download." code:22]
                         presenting:presentNoUpdate];
        return;
    }

    NSString *currentVersion = [self currentVersion];
    NSLog(@"Rainbar updater: latest release %@, current app %@.", latestVersion, currentVersion);
    if ([self compareVersion:latestVersion toVersion:currentVersion] != NSOrderedDescending) {
        [self markUpdateCheckComplete];
        [self setBusy:NO];
        if (presentNoUpdate) {
            [self presentInformationalAlertWithTitle:@"Rainbar is up to date"
                                             message:[NSString stringWithFormat:@"You are running Rainbar %@.", currentVersion]];
        }
        return;
    }

    [self downloadAndInstallVersion:latestVersion fromURL:downloadURL presenting:presentNoUpdate];
}

- (NSURL *)downloadURLFromRelease:(NSDictionary *)release {
    NSArray *assets = [release[@"assets"] isKindOfClass:NSArray.class] ? release[@"assets"] : nil;
    for (id assetObject in assets) {
        if (![assetObject isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSDictionary *asset = (NSDictionary *)assetObject;
        NSString *name = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : nil;
        NSString *urlString = [asset[@"browser_download_url"] isKindOfClass:NSString.class] ? asset[@"browser_download_url"] : nil;
        if ([name isEqualToString:_assetName] && urlString.length > 0) {
            return [NSURL URLWithString:urlString];
        }
    }

    return nil;
}

- (void)downloadAndInstallVersion:(NSString *)version fromURL:(NSURL *)downloadURL presenting:(BOOL)presenting {
    if (!_busy) {
        [self setBusy:YES];
    }
    NSLog(@"Rainbar updater: downloading %@ from %@.", version, downloadURL.absoluteString);

    __weak typeof(self) weakSelf = self;
    _downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:downloadURL
                                                    completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        (void)response;
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setBusy:NO];
                [weakSelf presentErrorIfNeeded:error presenting:presenting];
            });
            return;
        }

        [weakSelf extractAndInstallDownloadedZipAtURL:location version:version presenting:presenting];
    }];
    [_downloadTask resume];
}

- (void)extractAndInstallDownloadedZipAtURL:(NSURL *)location version:(NSString *)version presenting:(BOOL)presenting {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *updateDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[[NSUUID UUID] UUIDString] isDirectory:YES];
    NSURL *zipURL = [updateDirectory URLByAppendingPathComponent:_assetName];

    NSError *error = nil;
    if (![fileManager createDirectoryAtURL:updateDirectory withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![fileManager moveItemAtURL:location toURL:zipURL error:&error]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO];
            [self presentErrorIfNeeded:error presenting:presenting];
        });
        return;
    }

    NSLog(@"Rainbar updater: downloaded update to %@.", zipURL.path);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *extractError = nil;
        if (![self extractZipAtURL:zipURL intoDirectory:updateDirectory error:&extractError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setBusy:NO];
                [self presentErrorIfNeeded:extractError presenting:presenting];
            });
            return;
        }

        NSURL *newAppURL = [updateDirectory URLByAppendingPathComponent:@"Rainbar.app" isDirectory:YES];
        if (![self validateAppAtURL:newAppURL expectedVersion:version error:&extractError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setBusy:NO];
                [self presentErrorIfNeeded:extractError presenting:presenting];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self installExtractedAppAtURL:newAppURL updateDirectory:updateDirectory presenting:presenting];
        });
    });
}

- (BOOL)extractZipAtURL:(NSURL *)zipURL intoDirectory:(NSURL *)directoryURL error:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/ditto";
    task.arguments = @[@"-x", @"-k", zipURL.path, directoryURL.path];

    NSPipe *errorPipe = [NSPipe pipe];
    task.standardError = errorPipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (error) {
            *error = [self errorWithDescription:[NSString stringWithFormat:@"Could not unzip the Rainbar update: %@", exception.reason]
                                           code:30];
        }
        return NO;
    }

    if (task.terminationStatus != 0) {
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        if (error) {
            *error = [self errorWithDescription:errorOutput.length > 0 ? errorOutput : @"Could not unzip the Rainbar update."
                                           code:31];
        }
        return NO;
    }

    return YES;
}

- (BOOL)validateAppAtURL:(NSURL *)appURL expectedVersion:(NSString *)expectedVersion error:(NSError **)error {
    NSBundle *bundle = [NSBundle bundleWithURL:appURL];
    if (!bundle) {
        if (error) {
            *error = [self errorWithDescription:@"The downloaded update did not contain Rainbar.app." code:40];
        }
        return NO;
    }

    NSString *bundleIdentifier = bundle.bundleIdentifier;
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![bundleIdentifier isEqualToString:@"com.grinich.rainbar"] ||
        [self compareVersion:[self normalizedVersionString:version] toVersion:expectedVersion] != NSOrderedSame) {
        if (error) {
            *error = [self errorWithDescription:@"The downloaded app did not match the expected Rainbar release." code:41];
        }
        return NO;
    }

    return YES;
}

- (void)installExtractedAppAtURL:(NSURL *)newAppURL updateDirectory:(NSURL *)updateDirectory presenting:(BOOL)presenting {
    NSURL *currentAppURL = NSBundle.mainBundle.bundleURL.URLByResolvingSymlinksInPath;
    NSURL *parentURL = currentAppURL.URLByDeletingLastPathComponent;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    BOOL appExists = [fileManager fileExistsAtPath:currentAppURL.path isDirectory:&isDirectory] && isDirectory;

    if (!((appExists && [fileManager isWritableFileAtPath:currentAppURL.path]) ||
          (!appExists && [fileManager isWritableFileAtPath:parentURL.path]))) {
        [self setBusy:NO];
        [self presentErrorIfNeeded:[self errorWithDescription:@"Rainbar does not have permission to replace the current app. Download the latest release from GitHub and replace Rainbar.app manually."
                                                         code:50]
                         presenting:presenting];
        return;
    }

    NSURL *scriptURL = [updateDirectory URLByAppendingPathComponent:@"install-rainbar-update.sh"];
    NSString *script = @"#!/bin/sh\n"
        "APP_PATH=\"$1\"\n"
        "NEW_APP=\"$2\"\n"
        "APP_PID=\"$3\"\n"
        "UPDATE_DIR=\"$4\"\n"
        "PREF_DOMAIN=\"com.grinich.rainbar\"\n"
        "log() { /usr/bin/logger -t RainbarUpdater \"Rainbar updater: $1\"; }\n"
        "log \"waiting for app to quit\"\n"
        "while kill -0 \"$APP_PID\" 2>/dev/null; do\n"
        "  sleep 0.2\n"
        "done\n"
        "BACKUP=\"$UPDATE_DIR/Rainbar.app.previous\"\n"
        "rm -rf \"$BACKUP\"\n"
        "if [ -d \"$APP_PATH\" ]; then\n"
        "  log \"backing up current app\"\n"
        "  /usr/bin/ditto \"$APP_PATH\" \"$BACKUP\" || exit 1\n"
        "  log \"clearing current app bundle\"\n"
        "  /usr/bin/find \"$APP_PATH\" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || exit 1\n"
        "else\n"
        "  /bin/mkdir -p \"$APP_PATH\" || exit 1\n"
        "fi\n"
        "log \"installing new app bundle\"\n"
        "if /usr/bin/ditto \"$NEW_APP\" \"$APP_PATH\"; then\n"
        "  /usr/bin/xattr -dr com.apple.quarantine \"$APP_PATH\" 2>/dev/null || true\n"
        "  log \"opening updated app\"\n"
        "  /usr/bin/open \"$APP_PATH\"\n"
        "  rm -rf \"$UPDATE_DIR\"\n"
        "  exit 0\n"
        "fi\n"
        "log \"install failed, restoring previous app\"\n"
        "/usr/bin/defaults delete \"$PREF_DOMAIN\" RainbarLastUpdateCheckDate 2>/dev/null || true\n"
        "if [ -d \"$APP_PATH\" ]; then\n"
        "  /usr/bin/find \"$APP_PATH\" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true\n"
        "fi\n"
        "if [ -d \"$BACKUP\" ]; then\n"
        "  /usr/bin/ditto \"$BACKUP\" \"$APP_PATH\"\n"
        "  /usr/bin/open \"$APP_PATH\"\n"
        "fi\n"
        "exit 1\n";

    NSError *error = nil;
    if (![script writeToURL:scriptURL atomically:YES encoding:NSUTF8StringEncoding error:&error] ||
        ![fileManager setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:scriptURL.path error:&error]) {
        [self setBusy:NO];
        [self presentErrorIfNeeded:error presenting:presenting];
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[scriptURL.path, currentAppURL.path, newAppURL.path, [NSString stringWithFormat:@"%d", getpid()], updateDirectory.path];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        [self setBusy:NO];
        [self presentErrorIfNeeded:[self errorWithDescription:[NSString stringWithFormat:@"Could not start the updater: %@", exception.reason] code:51]
                         presenting:presenting];
        return;
    }

    NSLog(@"Rainbar updater: installer launched, quitting for relaunch.");
    [NSApp terminate:nil];
}

- (void)markUpdateCheckComplete {
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:RainbarLastUpdateCheckDateDefaultsKey];
}

- (NSString *)currentVersion {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [self normalizedVersionString:version] ?: @"0";
}

- (NSString *)normalizedVersionString:(NSString *)version {
    if (![version isKindOfClass:NSString.class]) {
        return nil;
    }

    NSString *normalized = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([normalized hasPrefix:@"v"] || [normalized hasPrefix:@"V"]) {
        normalized = [normalized substringFromIndex:1];
    }

    return normalized;
}

- (NSComparisonResult)compareVersion:(NSString *)leftVersion toVersion:(NSString *)rightVersion {
    NSArray<NSString *> *leftParts = [[self normalizedVersionString:leftVersion] componentsSeparatedByString:@"."];
    NSArray<NSString *> *rightParts = [[self normalizedVersionString:rightVersion] componentsSeparatedByString:@"."];
    NSUInteger count = MAX(leftParts.count, rightParts.count);

    for (NSUInteger index = 0; index < count; index++) {
        NSInteger leftValue = index < leftParts.count ? leftParts[index].integerValue : 0;
        NSInteger rightValue = index < rightParts.count ? rightParts[index].integerValue : 0;

        if (leftValue < rightValue) {
            return NSOrderedAscending;
        }

        if (leftValue > rightValue) {
            return NSOrderedDescending;
        }
    }

    return NSOrderedSame;
}

- (NSError *)errorWithDescription:(NSString *)description code:(NSInteger)code {
    return [NSError errorWithDomain:RainbarErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Rainbar update failed."}];
}

- (void)presentErrorIfNeeded:(NSError *)error presenting:(BOOL)presenting {
    if (!presenting) {
        NSLog(@"Rainbar update check failed: %@", error.localizedDescription);
        return;
    }

    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rainbar could not update";
    alert.informativeText = error.localizedDescription ?: @"An unknown update error occurred.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)presentInformationalAlertWithTitle:(NSString *)title message:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    if (self.busyHandler) {
        self.busyHandler(busy);
    }
}

@end

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

    NSTimeInterval scheduledDuration = (NSTimeInterval)((double)remainingFrames / sampleRate);
    NSTimeInterval quietTailSkipDuration = [self quietTailSkipDurationForTrackIdentifier:trackIdentifier];
    _nodeRemainingDurations[nodeIndex] = fmax(1.0, scheduledDuration - quietTailSkipDuration);
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
            @"MumbaiRain": @(0.0f),
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

- (NSTimeInterval)quietTailSkipDurationForTrackIdentifier:(NSString *)trackIdentifier {
    static NSDictionary<NSString *, NSNumber *> *skipDurationByTrackIdentifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skipDurationByTrackIdentifier = @{
            @"ArizonaMonsoon": @(48.0),
            @"HawaiiLanai": @(4.5),
            @"LeipzigSpringRain": @(2.5),
            @"ManhattanStorm": @(5.5)
        };
    });

    NSNumber *skipDuration = skipDurationByTrackIdentifier[trackIdentifier];
    return skipDuration ? skipDuration.doubleValue : 0.0;
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
    RainUpdater *_updater;
    NSMenuItem *_updateMenuItem;
    NSMenuItem *_openAtLoginMenuItem;
    NSArray<NSDictionary<NSString *, NSString *> *> *_tracks;
    NSTimer *_rainAnimationTimer;
    NSInteger _rainAnimationFrame;
    float _lastNonZeroVolume;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [self configureTracks];
    _audio = [[RainAudioController alloc] initWithTrackIdentifier:[self savedTrackIdentifier]];
    _audio.volume = [self savedVolume];
    _lastNonZeroVolume = _audio.volume > 0.001f ? _audio.volume : 0.65f;
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    [self configureStatusItem];
    [self configureMenu];
    [self configureUpdater];
    [self prewarmAudio];
    [self scheduleAutomaticUpdateCheck];
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
        @{@"title": @"Mumbai Rain", @"identifier": @"MumbaiRain", @"detail": @"2:33"},
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

    _updateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates..." action:@selector(checkForUpdates:) keyEquivalent:@""];
    _updateMenuItem.target = self;
    [_statusMenu addItem:_updateMenuItem];

    _openAtLoginMenuItem = [[NSMenuItem alloc] initWithTitle:@"Open at Login" action:@selector(toggleOpenAtLogin:) keyEquivalent:@""];
    _openAtLoginMenuItem.target = self;
    [_statusMenu addItem:_openAtLoginMenuItem];
    [self refreshOpenAtLoginMenuItem];
    [_statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Rainbar" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [_statusMenu addItem:quitItem];
}

- (void)configureUpdater {
    _updater = [[RainUpdater alloc] initWithOwner:@"grinich"
                                             repo:@"rainbar"
                                        assetName:@"Rainbar.app.zip"];

    __weak typeof(self) weakSelf = self;
    _updater.busyHandler = ^(BOOL busy) {
        [weakSelf setUpdateBusy:busy];
    };
}

- (void)scheduleAutomaticUpdateCheck {
    RainUpdater *updater = _updater;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [updater checkAutomatically];
    });
}

- (void)setUpdateBusy:(BOOL)busy {
    _updateMenuItem.enabled = !busy;
    _updateMenuItem.title = busy ? @"Updating Rainbar..." : @"Check for Updates...";
}

- (void)checkForUpdates:(id)sender {
    (void)sender;
    [_updater checkManually];
}

- (void)toggleOpenAtLogin:(id)sender {
    (void)sender;

    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;
    BOOL enabled = service.status == SMAppServiceStatusEnabled;
    BOOL success = enabled ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];

    if (!success) {
        [self presentOpenAtLoginError:error];
    }

    [self refreshOpenAtLoginMenuItem];
}

- (void)refreshOpenAtLoginMenuItem {
    SMAppServiceStatus status = [SMAppService mainAppService].status;
    _openAtLoginMenuItem.state = status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _openAtLoginMenuItem.enabled = status != SMAppServiceStatusNotFound;
}

- (void)presentOpenAtLoginError:(NSError *)error {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rainbar could not change Open at Login";
    alert.informativeText = error.localizedDescription ?: @"Open System Settings and check Login Items if macOS requires approval.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (NSString *)savedTrackIdentifier {
    NSString *savedIdentifier = [[NSUserDefaults standardUserDefaults] stringForKey:RainbarSelectedTrackIdentifierDefaultsKey];
    if ([self isValidTrackIdentifier:savedIdentifier]) {
        return savedIdentifier;
    }

    return @"HeavyRuralRain";
}

- (float)savedVolume {
    id savedVolume = [[NSUserDefaults standardUserDefaults] objectForKey:RainbarVolumeDefaultsKey];
    if ([savedVolume respondsToSelector:@selector(floatValue)]) {
        return fminf(1.0f, fmaxf(0.0f, [savedVolume floatValue]));
    }

    return 0.65f;
}

- (BOOL)isValidTrackIdentifier:(NSString *)trackIdentifier {
    if (![trackIdentifier isKindOfClass:NSString.class]) {
        return NO;
    }

    for (NSDictionary<NSString *, NSString *> *track in _tracks) {
        if ([track[@"identifier"] isEqualToString:trackIdentifier]) {
            return YES;
        }
    }

    return NO;
}

- (void)saveSelectedTrackIdentifier:(NSString *)trackIdentifier {
    if ([self isValidTrackIdentifier:trackIdentifier]) {
        [[NSUserDefaults standardUserDefaults] setObject:trackIdentifier forKey:RainbarSelectedTrackIdentifierDefaultsKey];
    }
}

- (void)saveVolume:(float)volume {
    [[NSUserDefaults standardUserDefaults] setFloat:fminf(1.0f, fmaxf(0.0f, volume)) forKey:RainbarVolumeDefaultsKey];
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
    [self saveSelectedTrackIdentifier:_audio.trackIdentifier];

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
    [self saveVolume:clampedVolume];

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
    [self refreshOpenAtLoginMenuItem];
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
