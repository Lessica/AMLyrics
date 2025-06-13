@import Darwin;
@import Foundation;
@import MediaPlayer;

@interface ICURLResponse : NSObject
@property (nonatomic, readonly) NSData *bodyData;
@end

// v24@?0@"ICURLResponse"8@"NSError"16
typedef void (^ICURLSessionCompletionHandler)(ICURLResponse *, NSError *);

@interface MSVLyricsLine : NSObject
@property (assign, nonatomic) NSTimeInterval startTime;
@property (assign, nonatomic) NSTimeInterval endTime;
@property (copy, nonatomic) NSAttributedString *lyricsText;
@property (nonatomic, strong) MSVLyricsLine *nextLine;
- (BOOL)containsTimeOffset:(NSTimeInterval)arg1 withErrorMargin:(NSTimeInterval)arg2;
@end

@interface ICMusicKitRequestContext : NSObject
@end

@interface ICMusicKitURLRequest : NSObject
@property (nonatomic, copy, readonly) ICMusicKitRequestContext *requestContext;
- (instancetype)initWithURL:(NSURL *)arg1 requestContext:(ICMusicKitRequestContext *)arg2;
@end

@interface MRContentItemMetadata : NSObject
@property (assign, nonatomic) NSInteger iTunesStoreIdentifier;
@property (assign, nonatomic) BOOL hasITunesStoreIdentifier;
@property (copy, nonatomic) NSString *title;
@property (copy, nonatomic) NSString *trackArtistName;
@property (nonatomic, copy) NSString *amLyricsTitle;
@property (assign, nonatomic) NSTimeInterval elapsedTime;
@property (assign, nonatomic) BOOL lyricsAvailable;
@property (assign, nonatomic) BOOL hasLyricsAvailable;
@property (assign, nonatomic) NSInteger lyricsAdamID;
@property (assign, nonatomic) BOOL hasLyricsAdamID;
@end

@interface MRContentItem : NSObject
@property (nonatomic, copy) MRContentItemMetadata *metadata;
@end

@interface MPNowPlayingContentItem : MPContentItem
@property (assign, nonatomic) NSInteger storeID;
@property (nonatomic, strong) NSTimer *amlTimer;
@property (assign, nonatomic) float playbackRate;
- (NSTimeInterval)calculatedElapsedTime;
- (void)setElapsedTime:(double)elapsedTime playbackRate:(float)arg2;
@end

@interface MSVLyricsTTMLParser : NSObject
- (instancetype)initWithTTMLData:(NSData *)data;
- (NSArray<MSVLyricsLine *> *)lyricLines;
- (id)parseWithError:(id*)arg1;
@end

@interface ICURLSession : NSObject
- (void)enqueueDataRequest:(id)arg1 withCompletionHandler:(ICURLSessionCompletionHandler)arg2;
@end

@interface MRNowPlayingPlayerClient : NSObject
@property (nonatomic, readonly) MRContentItem *nowPlayingContentItem;
- (void)sendContentItemChanges:(NSArray<MRContentItem *> *)contentItems;
@end

@interface MPNowPlayingInfoCenter (Private)
- (MPNowPlayingContentItem *)nowPlayingContentItem;
@end

// 定义任务结构
@interface LyricsTask : NSObject
@property (nonatomic, assign) NSInteger iTunesStoreID;
@property (nonatomic, assign) NSInteger lyricsAdamID;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, strong) NSURL *lyricURL;
@property (nonatomic, strong) NSString *lyricsFilePath;
@end

@implementation LyricsTask
@end

// 全局变量
static dispatch_queue_t gLyricsQueue = nil;
static ICURLSession *gSession = nil;
static ICMusicKitRequestContext *gRequestContext = nil;
static NSMutableArray<LyricsTask *> *gLyricsTaskQueue = nil; // 任务队列
static NSMutableSet<NSNumber *> *gPendingLyricsIDs = nil;    // 正在处理的ID集合
static BOOL gIsProcessingQueue = NO;                         // 队列处理标志
static NSString *gLyricsRootPath = nil;                      // 歌词缓存根目录
static NSInteger gLastLyricsAdamID = 0;                      // 上次处理的歌词ID
static NSMutableDictionary<NSNumber *, NSArray<MSVLyricsLine *> *> *gLyricsCache = nil; // 歌词缓存
static pthread_mutex_t gLyricsCacheMutex = PTHREAD_MUTEX_INITIALIZER;                   // 歌词缓存互斥锁
static MPNowPlayingInfoCenter *gNowPlayingInfoCenter = nil;  // 用于设置当前播放信息

%hook ICURLSession

- (void)enqueueDataRequest:(id)arg1 withCompletionHandler:(ICURLSessionCompletionHandler)arg2 {
    if (!gSession) {
        gSession = self;
    }
    if (!gRequestContext) {
        if ([arg1 isKindOfClass:%c(ICMusicKitURLRequest)]) {
            ICMusicKitURLRequest *req = arg1;
            gRequestContext = [req requestContext];
        }
    }
    %orig;
}

%end

// 初始化歌词缓存目录
static NSString *GetLyricsRootPath(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLyricsRootPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
        gLyricsRootPath = [gLyricsRootPath stringByAppendingPathComponent:@"AMLyrics"];
        [[NSFileManager defaultManager] createDirectoryAtPath:gLyricsRootPath withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return gLyricsRootPath;
}

// 处理歌词数据
static void ParseLyricsData(NSData *data, NSInteger iTunesStoreID, NSInteger lyricsAdamID) {
    if (!data || gLastLyricsAdamID == lyricsAdamID) {
        return;
    }
    NSError *parseError = nil;
    MSVLyricsTTMLParser *parser = [[%c(MSVLyricsTTMLParser) alloc] initWithTTMLData:data];
    [parser parseWithError:&parseError];
    if (parseError) {
#if DEBUG
        NSLog(@"Error parsing lyrics: %@", parseError);
#endif
        return;
    }
    NSMutableArray<MSVLyricsLine *> *lyricLines = [[parser lyricLines] mutableCopy];
#if DEBUG
    NSMutableArray *lyricData = [NSMutableArray array];
    for (MSVLyricsLine *line in lyricLines) {
        if (line.lyricsText.string.length > 0) {
            [lyricData addObject:@{
                @"startTime": @(line.startTime),
                @"endTime": @(line.endTime),
                @"text": line.lyricsText.string,
            }];
        }
    }
    NSLog(@"Fetched lyrics for item %lld: %@", (long long)lyricsAdamID, lyricData);
#endif
    pthread_mutex_lock(&gLyricsCacheMutex);
    [lyricLines sortUsingComparator:^NSComparisonResult(MSVLyricsLine *line1, MSVLyricsLine *line2) {
        if (line1.startTime < line2.startTime) {
            return NSOrderedAscending;
        } else if (line1.startTime > line2.startTime) {
            return NSOrderedDescending;
        } else {
            return NSOrderedSame;
        }
    }];
    gLyricsCache[@(iTunesStoreID)] = [lyricLines copy];
    pthread_mutex_unlock(&gLyricsCacheMutex);
    gLastLyricsAdamID = lyricsAdamID;
}

// 处理队列中的下一个任务
static void ProcessNextTask(void) {
    if (!gSession || !gRequestContext || [gLyricsTaskQueue count] == 0) {
        gIsProcessingQueue = NO;
        return;
    }
    
    gIsProcessingQueue = YES;
    LyricsTask *task = [gLyricsTaskQueue firstObject];
    [gLyricsTaskQueue removeObjectAtIndex:0];
    
    ICMusicKitURLRequest *request = [[%c(ICMusicKitURLRequest) alloc] initWithURL:task.lyricURL requestContext:gRequestContext];
    [gSession enqueueDataRequest:request withCompletionHandler:^(ICURLResponse *response, NSError *error) {
        dispatch_async(gLyricsQueue, ^{
            BOOL taskFailed = NO;
            
            if (error) {
#if DEBUG
                NSLog(@"Error fetching lyrics (retry %ld): %@", (long)task.retryCount, error);
#endif
                taskFailed = YES;
            } else if (![response.bodyData isKindOfClass:[NSData class]]) {
#if DEBUG
                NSLog(@"Invalid response body (retry %ld)", (long)task.retryCount);
#endif
                taskFailed = YES;
            } else {
                id object = [NSJSONSerialization JSONObjectWithData:response.bodyData options:0 error:nil];
                if ([object isKindOfClass:[NSDictionary class]]) {
                    object = ((NSDictionary *)object)[@"data"];
                    if ([object isKindOfClass:[NSArray class]]) {
                        object = ((NSArray *)object).firstObject;
                        if ([object isKindOfClass:[NSDictionary class]]) {
                            object = ((NSDictionary *)object)[@"attributes"];
                            if ([object isKindOfClass:[NSDictionary class]]) {
                                object = ((NSDictionary *)object)[@"ttml"];
                            }
                        }
                    }
                }
                
                if (![object isKindOfClass:[NSString class]]) {
#if DEBUG
                    NSLog(@"Invalid ttml data format (retry %ld)", (long)task.retryCount);
#endif
                    taskFailed = YES;
                } else {
                    NSData *data = [(NSString *)object dataUsingEncoding:NSUTF8StringEncoding];
                    if (data) {
                        // 保存到缓存文件
                        [data writeToFile:task.lyricsFilePath atomically:YES];
                        // 解析歌词数据
                        ParseLyricsData(data, task.iTunesStoreID, task.lyricsAdamID);
                    } else {
                        taskFailed = YES;
                    }
                }
            }
            
            if (taskFailed) {
                task.retryCount++;
                if (task.retryCount < 3) {
                    // 重试次数未达上限，加回队列尾部
                    [gLyricsTaskQueue addObject:task];
#if DEBUG
                    NSLog(@"Requeuing task for lyrics ID %lld, retry count: %ld", 
                        (long long)task.lyricsAdamID, (long)task.retryCount);
#endif
                } else {
                    // 已达最大重试次数，放弃该任务
#if DEBUG
                    NSLog(@"Giving up on lyrics ID %lld after 3 retries", (long long)task.lyricsAdamID);
                    [gPendingLyricsIDs removeObject:@(task.lyricsAdamID)];
#endif
                }
            } else {
                // 任务成功完成
                [gPendingLyricsIDs removeObject:@(task.lyricsAdamID)];
            }
            
            // 处理队列中的下一个任务
            ProcessNextTask();
        });
    }];
}

// 添加任务到队列
static void AddTaskToQueue(NSInteger iTunesStoreID, NSInteger lyricsAdamID, NSURL *lyricURL, NSString *lyricsFilePath) {
    // 延迟初始化队列和集合
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLyricsTaskQueue = [NSMutableArray array];
        gPendingLyricsIDs = [NSMutableSet set];
    });
    
    // 检查是否已在队列中
    if ([gPendingLyricsIDs containsObject:@(lyricsAdamID)]) {
#if DEBUG
        NSLog(@"Task for lyrics ID %lld already in queue", (long long)lyricsAdamID);
#endif
        return;
    }
    
    // 创建并添加新任务
    LyricsTask *task = [[LyricsTask alloc] init];
    task.iTunesStoreID = iTunesStoreID;
    task.lyricsAdamID = lyricsAdamID;
    task.retryCount = 0;
    task.lyricURL = lyricURL;
    task.lyricsFilePath = lyricsFilePath;
    
    [gLyricsTaskQueue addObject:task];
    [gPendingLyricsIDs addObject:@(lyricsAdamID)];
    
    // 如果队列未在处理中，开始处理
    if (!gIsProcessingQueue) {
        ProcessNextTask();
    }
}

%hook MRNowPlayingPlayerClient

- (void)sendContentItemChanges:(NSArray<MRContentItem *> *)contentItems {
    %orig;
    dispatch_async(gLyricsQueue, ^{
        
        MRContentItem *item = self.nowPlayingContentItem;
        if (!item.metadata.lyricsAvailable) {
            return;
        }

        NSInteger iTunesStoreID = item.metadata.iTunesStoreIdentifier;
        if (iTunesStoreID <= 0) {
            return;
        }
        
        NSInteger lyricsAdamID = item.metadata.lyricsAdamID;
        if (lyricsAdamID <= 0) {
            return;
        }
        
        NSString *lyricsRoot = GetLyricsRootPath();
        NSString *lyricsFilePath = [lyricsRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"syllable-lyrics_%lld.xml", (long long)lyricsAdamID]];
        BOOL lyricsCacheExists = [[NSFileManager defaultManager] fileExistsAtPath:lyricsFilePath];
        if (lyricsCacheExists) {
            NSData *cachedData = [NSData dataWithContentsOfFile:lyricsFilePath];
            ParseLyricsData(cachedData, iTunesStoreID, lyricsAdamID);
            return;
        }

        if (!gSession || !gRequestContext) {
            return;
        }
        
        NSString *languageCode = [[NSLocale preferredLanguages] firstObject];
        NSString *lyricURLString = [NSString stringWithFormat:@"https://amp-api.music.apple.com/v1/catalog/cn/songs/%lld/syllable-lyrics?l=%@", (long long)lyricsAdamID, languageCode];
        NSURL *lyricURL = [NSURL URLWithString:lyricURLString];
        
        // 添加任务到队列
        AddTaskToQueue(iTunesStoreID, lyricsAdamID, lyricURL, lyricsFilePath);
    });
}

%end

%hook MPNowPlayingInfoCenter

- (id)nowPlayingContentItem {
    if (!gNowPlayingInfoCenter) {
        gNowPlayingInfoCenter = self;
    }
    return %orig;
}

%end

%hook MPNowPlayingContentItem

%property (nonatomic, strong) NSTimer *amlTimer;

%new
- (void)amlTimerFired:(NSTimer *)timer {
#if DEBUG
    NSLog(@"→ amlTimerFired: %@", timer);
#endif
    double elapsedTime = [self calculatedElapsedTime];
    if (elapsedTime < 0) {
        elapsedTime = 0;
    }
    [self setElapsedTime:elapsedTime playbackRate:self.playbackRate];
}

- (void)setElapsedTime:(double)elapsedTime playbackRate:(float)playbackRate {
    %orig;
    if (!self.storeID) {
        return;
    }
    NSString *title = nil;
    MSVLyricsLine *nextLine = nil;
    pthread_mutex_lock(&gLyricsCacheMutex);
    NSArray<MSVLyricsLine *> *lyricLines = gLyricsCache[@(self.storeID)];
    for (MSVLyricsLine *line in [lyricLines reverseObjectEnumerator]) {
        if (elapsedTime >= line.startTime) {
            title = line.lyricsText.string;
            nextLine = line.nextLine;
            break;
        }
    }
    pthread_mutex_unlock(&gLyricsCacheMutex);
    [self.amlTimer invalidate];
    if (nextLine.startTime > elapsedTime) {
        self.amlTimer = [NSTimer scheduledTimerWithTimeInterval:(nextLine.startTime - elapsedTime) / playbackRate
                                                         target:self
                                                       selector:@selector(amlTimerFired:)
                                                       userInfo:nil
                                                        repeats:NO];
    } else {
        self.amlTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(amlTimerFired:)
                                                       userInfo:nil
                                                        repeats:NO];
    }
    if (title) {
        [self setTitle:title];
    }
}

- (void)setTrackArtistName:(NSString *)trackArtistName {
    if (!trackArtistName || trackArtistName.length == 0) {
        %orig;
        return;
    }
    %orig([NSString stringWithFormat:@"%@ — %@", self.title, trackArtistName]);
}

%end

#import "MediaRemote+Private.h"

@interface AMLMediaObserver : NSObject
@end

@implementation AMLMediaObserver {
    BOOL _isNowPlaying;
    NSTimer *_nowPlayingTimer;
    NSTimeInterval _lastUpdateTime;
    NSTimeInterval _elapsedTime;
    NSTimeInterval _duration;
    NSTimeInterval _playbackRate;
    NSInteger _iTunesStoreID;
    NSString *_currentLyricsLine;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isNowPlaying = NO;
        _nowPlayingTimer = nil;
        _lastUpdateTime = 0.0;
        _elapsedTime = 0.0;
        _duration = 0.0;
        _playbackRate = 1.0;
        _iTunesStoreID = 0;
        _currentLyricsLine = nil;

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(handleIsPlayingDidChangeNotification:)
                   name:(__bridge NSNotificationName)kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
                 object:nil];

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(handleNowPlayingInfoDidChangeNotification:)
                   name:(__bridge NSNotificationName)kMRMediaRemoteNowPlayingInfoDidChangeNotification
                 object:nil];

        MRMediaRemoteSetWantsNowPlayingNotifications(true);
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
            [self handleIsPlayingDidChange:isPlaying];
        });
        MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef userInfo) {
            [self handleNowPlayingInfoDidChange:(__bridge NSDictionary *)userInfo];
        });
    }
    return self;
}

- (void)handleIsPlayingDidChangeNotification:(NSNotification *)noti {
    NSDictionary *userInfo = noti.userInfo;
    BOOL isPlaying = [userInfo[(__bridge NSString *)kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey] boolValue];
    [self handleIsPlayingDidChange:isPlaying];
}

- (void)handleIsPlayingDidChange:(BOOL)isPlaying {
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        if (_isNowPlaying != isPlaying) {
            _isNowPlaying = isPlaying;
            [self resetCurrentLyricsLine];
        }
        [self updateNowPlayingInfo];
    });
}

- (void)handleNowPlayingInfoDidChangeNotification:(NSNotification *)noti {
    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef userInfo) {
        [self handleNowPlayingInfoDidChange:(__bridge NSDictionary *)userInfo];
    });
}

- (void)handleNowPlayingInfoDidChange:(NSDictionary *)userInfo {
    BOOL isMusic = [userInfo[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoIsMusicApp] boolValue];
    if (!isMusic) {
        return;
    }
    _lastUpdateTime = [NSDate timeIntervalSinceReferenceDate];
    _elapsedTime = [userInfo[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoElapsedTime] doubleValue];
    _duration = [userInfo[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoDuration] doubleValue];
    _playbackRate = [userInfo[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoPlaybackRate] doubleValue];
    if (_playbackRate < 1e-3) {
        _playbackRate = 1.0;
    }
    NSInteger iTunesStoreID = [userInfo[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier] integerValue];
    if (_iTunesStoreID != iTunesStoreID) {
        _iTunesStoreID = iTunesStoreID;
        [self resetCurrentLyricsLine];
    }
    [self updateNowPlayingInfo];
}

- (void)updateNowPlayingInfo {
    if (_isNowPlaying && !_nowPlayingTimer) {
        _nowPlayingTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                            target:self
                                                          selector:@selector(nowPlayingTimerFired:)
                                                          userInfo:nil
                                                           repeats:YES];
    }
    else if (!_isNowPlaying && _nowPlayingTimer) {
        [_nowPlayingTimer invalidate];
        _nowPlayingTimer = nil;
    }

    [self nowPlayingTimerFired:nil];
}

- (void)nowPlayingTimerFired:(NSTimer *)timer {
    if (!_isNowPlaying || _iTunesStoreID <= 0) {
        [self resetCurrentLyricsLine];
        return;
    }

    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval estimatedElapsedTime = _elapsedTime + (currentTime - _lastUpdateTime) * _playbackRate;

    NSString *currentLyricsLine = nil;
    pthread_mutex_lock(&gLyricsCacheMutex);
    NSArray<MSVLyricsLine *> *lyricLines = gLyricsCache[@(_iTunesStoreID)];
    for (MSVLyricsLine *line in lyricLines) {
        if (line.startTime <= estimatedElapsedTime && line.endTime >= estimatedElapsedTime) {
            currentLyricsLine = line.lyricsText.string;
            break;
        }
    }
    pthread_mutex_unlock(&gLyricsCacheMutex);

    if (_currentLyricsLine && !currentLyricsLine) {
        return;
    }

    if (!_currentLyricsLine && !currentLyricsLine) {
        [self resetCurrentLyricsLine];
        return;
    }

    if (![_currentLyricsLine isEqualToString:currentLyricsLine]) {
        _currentLyricsLine = currentLyricsLine;
        [self notifyCurrentLyricsLineChanged];
    }
}

- (void)resetCurrentLyricsLine {
    if (!_currentLyricsLine) {
        return;
    }
    _currentLyricsLine = nil;
    [self notifyCurrentLyricsLineChanged];
}

- (void)notifyCurrentLyricsLineChanged {
    NSLog(@"→ %@", _currentLyricsLine);
}

@end

static AMLMediaObserver *gMediaObserver = nil;

%ctor {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLyricsCache = [[NSMutableDictionary alloc] init];
        gLyricsQueue = dispatch_queue_create("com.82flex.amlyrics.queue", DISPATCH_QUEUE_SERIAL);
        gLyricsTaskQueue = [NSMutableArray array];
        gPendingLyricsIDs = [NSMutableSet set];
#if DEBUG
        // gMediaObserver = [[AMLMediaObserver alloc] init];
#endif
    });
}
