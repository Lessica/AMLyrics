@import Darwin;
@import Foundation;
@import MediaPlayer;

// Interface for Apple Music URL response
@interface ICURLResponse : NSObject
@property (nonatomic, readonly) NSData *bodyData;
@end

// Completion handler type for ICURLSession
typedef void (^ICURLSessionCompletionHandler)(ICURLResponse *, NSError *);

// Represents a single line of lyrics with timing information
@interface MSVLyricsLine : NSObject
@property (assign, nonatomic) NSTimeInterval startTime;
@property (assign, nonatomic) NSTimeInterval endTime;
@property (copy, nonatomic) NSAttributedString *lyricsText;
@property (nonatomic, strong) MSVLyricsLine *nextLine;
- (BOOL)containsTimeOffset:(NSTimeInterval)arg1 withErrorMargin:(NSTimeInterval)arg2;
@end

// Request context for Apple MusicKit
@interface ICMusicKitRequestContext : NSObject
@end

// URL request for Apple MusicKit
@interface ICMusicKitURLRequest : NSObject
@property (nonatomic, copy, readonly) ICMusicKitRequestContext *requestContext;
- (instancetype)initWithURL:(NSURL *)arg1 requestContext:(ICMusicKitRequestContext *)arg2;
@end

// Metadata for a content item (song)
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

// Represents a content item (song)
@interface MRContentItem : NSObject
@property (nonatomic, copy) MRContentItemMetadata *metadata;
@end

// Now playing content item with additional properties
@interface MPNowPlayingContentItem : MPContentItem
@property (assign, nonatomic) NSInteger storeID;
@property (nonatomic, strong) NSTimer *amlTimer;
@property (assign, nonatomic) float playbackRate;
- (NSTimeInterval)calculatedElapsedTime;
- (void)setElapsedTime:(double)elapsedTime playbackRate:(float)arg2;
@end

// Parser for TTML lyrics data
@interface MSVLyricsTTMLParser : NSObject
- (instancetype)initWithTTMLData:(NSData *)data;
- (NSArray<MSVLyricsLine *> *)lyricLines;
- (id)parseWithError:(id*)arg1;
@end

// Apple MusicKit URL session
@interface ICURLSession : NSObject
- (void)enqueueDataRequest:(id)arg1 withCompletionHandler:(ICURLSessionCompletionHandler)arg2;
@end

// Now playing player client
@interface MRNowPlayingPlayerClient : NSObject
@property (nonatomic, readonly) MRContentItem *nowPlayingContentItem;
- (void)sendContentItemChanges:(NSArray<MRContentItem *> *)contentItems;
@end

// Private extension for now playing info center
@interface MPNowPlayingInfoCenter (Private)
- (MPNowPlayingContentItem *)nowPlayingContentItem;
@end

// Definition of a lyrics fetch task
@interface LyricsTask : NSObject
@property (nonatomic, assign) NSInteger iTunesStoreID;      // iTunes Store identifier for the song
@property (nonatomic, assign) NSInteger lyricsAdamID;       // Lyrics Adam ID
@property (nonatomic, assign) NSInteger retryCount;         // Retry count for the task
@property (nonatomic, strong) NSURL *lyricURL;              // URL to fetch lyrics
@property (nonatomic, strong) NSString *lyricsFilePath;     // Local file path for cached lyrics
@end

@implementation LyricsTask
@end

// Global variables for lyrics management
static dispatch_queue_t gLyricsQueue = nil; // Serial queue for lyrics operations
static ICURLSession *gSession = nil; // Shared URL session
static ICMusicKitRequestContext *gRequestContext = nil; // Shared request context
static NSMutableArray<LyricsTask *> *gLyricsTaskQueue = nil; // Task queue for lyrics fetching
static NSMutableSet<NSNumber *> *gPendingLyricsIDs = nil; // Set of lyrics IDs currently being processed
static BOOL gIsProcessingQueue = NO; // Whether the queue is being processed
static NSString *gLyricsRootPath = nil; // Root directory for lyrics cache
static NSInteger gLastLyricsAdamID = 0; // Last processed lyrics Adam ID
static NSMutableDictionary<NSNumber *, NSArray<MSVLyricsLine *> *> *gLyricsCache = nil; // In-memory lyrics cache
static pthread_mutex_t gLyricsCacheMutex = PTHREAD_MUTEX_INITIALIZER; // Mutex for lyrics cache
static MPNowPlayingInfoCenter *gNowPlayingInfoCenter = nil; // Reference to now playing info center

// Initialize and return the root path for lyrics cache directory
static NSString *GetLyricsRootPath(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLyricsRootPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
        gLyricsRootPath = [gLyricsRootPath stringByAppendingPathComponent:@"AMLyrics"];
        [[NSFileManager defaultManager] createDirectoryAtPath:gLyricsRootPath withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return gLyricsRootPath;
}

// Parse lyrics data and store it in the in-memory cache
static void ParseLyricsData(NSData *data, NSInteger iTunesStoreID, NSInteger lyricsAdamID, NSString *sourceHint) {
    if (!data || gLastLyricsAdamID == lyricsAdamID) {
        return;
    }
    pthread_mutex_lock(&gLyricsCacheMutex);
    // Check if lyrics for this song are already cached
    if (gLyricsCache[@(iTunesStoreID)]) {
        pthread_mutex_unlock(&gLyricsCacheMutex);
        return;
    }
    pthread_mutex_unlock(&gLyricsCacheMutex);
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
    NSLog(@"Fetched %@ lyrics for item %lld: %@", sourceHint, (long long)lyricsAdamID, lyricData);
#endif
    // Sort lyrics lines by start time
    [lyricLines sortUsingComparator:^NSComparisonResult(MSVLyricsLine *line1, MSVLyricsLine *line2) {
        if (line1.startTime < line2.startTime) {
            return NSOrderedAscending;
        } else if (line1.startTime > line2.startTime) {
            return NSOrderedDescending;
        } else {
            return NSOrderedSame;
        }
    }];
    pthread_mutex_lock(&gLyricsCacheMutex);
    gLyricsCache[@(iTunesStoreID)] = [lyricLines copy];
    pthread_mutex_unlock(&gLyricsCacheMutex);
    gLastLyricsAdamID = lyricsAdamID;
}

// Process the next lyrics fetch task in the queue
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
                // Parse JSON response and extract TTML lyrics string
                id object = [NSJSONSerialization JSONObjectWithData:response.bodyData options:0 error:nil];
                if ([object isKindOfClass:[NSDictionary class]]) {
                    if (((NSDictionary *)object)[@"data"]) {
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
                    } else if (((NSDictionary *)object)[@"ttml"]) {
                        object = ((NSDictionary *)object)[@"ttml"];
                    }
                }
                
                if (![object isKindOfClass:[NSString class]]) {
#if DEBUG
                    NSLog(@"Invalid ttml data format (retry %ld): %@", (long)task.retryCount, object);
#endif
                    taskFailed = YES;
                } else {
                    NSData *data = [(NSString *)object dataUsingEncoding:NSUTF8StringEncoding];
                    if (data) {
                        // Save lyrics data to cache file
                        [data writeToFile:task.lyricsFilePath atomically:YES];
                        // Parse and cache lyrics
                        ParseLyricsData(data, task.iTunesStoreID, task.lyricsAdamID, @"fetched");
                    } else {
                        taskFailed = YES;
                    }
                }
            }
            
            if (taskFailed) {
                task.retryCount++;
                if (task.retryCount < 3) {
                    // Retry if not reached max retry count, re-add to queue
                    [gLyricsTaskQueue addObject:task];
#if DEBUG
                    NSLog(@"Requeuing task for lyrics ID %lld, retry count: %ld", 
                        (long long)task.lyricsAdamID, (long)task.retryCount);
#endif
                } else {
                    // Give up after 3 retries
#if DEBUG
                    NSLog(@"Giving up on lyrics ID %lld after 3 retries", (long long)task.lyricsAdamID);
                    [gPendingLyricsIDs removeObject:@(task.lyricsAdamID)];
#endif
                }
            } else {
                // Task completed successfully
                [gPendingLyricsIDs removeObject:@(task.lyricsAdamID)];
            }
            
            // Process the next task in the queue
            ProcessNextTask();
        });
    }];
}

// Add a new lyrics fetch task to the queue
static void AddTaskToQueue(NSInteger iTunesStoreID, NSInteger lyricsAdamID, NSURL *lyricURL, NSString *lyricsFilePath) {
    // Lazy initialization of queue and set
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLyricsTaskQueue = [NSMutableArray array];
        gPendingLyricsIDs = [NSMutableSet set];
    });
    
    // Check if the task is already in the queue
    if ([gPendingLyricsIDs containsObject:@(lyricsAdamID)]) {
#if DEBUG
        NSLog(@"Task for lyrics ID %lld already in queue", (long long)lyricsAdamID);
#endif
        return;
    }
    
    // Create and add new task
    LyricsTask *task = [[LyricsTask alloc] init];
    task.iTunesStoreID = iTunesStoreID;
    task.lyricsAdamID = lyricsAdamID;
    task.retryCount = 0;
    task.lyricURL = lyricURL;
    task.lyricsFilePath = lyricsFilePath;
    
    [gLyricsTaskQueue addObject:task];
    [gPendingLyricsIDs addObject:@(lyricsAdamID)];
    
    // Start processing if not already running
    if (!gIsProcessingQueue) {
        ProcessNextTask();
    }
}

%group AMLyricsPrimary

%hook ICURLSession

// Hook to capture session and request context for lyrics fetching
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

%hook MRNowPlayingPlayerClient

// Hook to detect content item changes and trigger lyrics fetching
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
        
        NSInteger lyricsAdamID;
        NSString *lyricURLString;
        NSString *languageCode = [[NSLocale preferredLanguages] firstObject];
        if ([item.metadata respondsToSelector:@selector(lyricsAdamID)]) {
            lyricsAdamID = item.metadata.lyricsAdamID;
            lyricURLString = [NSString stringWithFormat:@"https://amp-api.music.apple.com/v1/catalog/cn/songs/%lld/syllable-lyrics?l=%@", (long long)lyricsAdamID, languageCode];
        } else {
            lyricsAdamID = iTunesStoreID;
            lyricURLString = [NSString stringWithFormat:@"https://se2.itunes.apple.com/WebObjects/MZStoreElements2.woa/wa/ttmlLyrics?id=%lld&l=%@", (long long)iTunesStoreID, languageCode];
        }
        if (lyricsAdamID <= 0) {
            return;
        }
        
        NSString *lyricsRoot = GetLyricsRootPath();
        NSString *lyricsFilePath = [lyricsRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"syllable-lyrics_%lld.xml", (long long)lyricsAdamID]];
        BOOL lyricsCacheExists = [[NSFileManager defaultManager] fileExistsAtPath:lyricsFilePath];
        if (lyricsCacheExists) {
            NSData *cachedData = [NSData dataWithContentsOfFile:lyricsFilePath];
            ParseLyricsData(cachedData, iTunesStoreID, lyricsAdamID, @"cached");
            return;
        }

        if (!gSession || !gRequestContext) {
            return;
        }
        
        NSURL *lyricURL = [NSURL URLWithString:lyricURLString];
        
        // Add fetch task to queue
        AddTaskToQueue(iTunesStoreID, lyricsAdamID, lyricURL, lyricsFilePath);
    });
}

%end

%hook MPNowPlayingInfoCenter

// Hook to capture reference to now playing info center
- (MPNowPlayingContentItem *)nowPlayingContentItem {
    if (!gNowPlayingInfoCenter) {
        gNowPlayingInfoCenter = self;
    }
    return %orig;
}

%end

%hook MPNowPlayingContentItem

%property (nonatomic, strong) NSTimer *amlTimer;

// Clean up timer on deallocation
- (void)dealloc {
    [self.amlTimer invalidate];
    self.amlTimer = nil;
    %orig;
}

// Timer callback for updating lyrics display
%new
- (void)amlTimerFired:(NSTimer *)timer {
#if DEBUG
    NSLog(@"→ amlTimerFired: item %@ timer %@", self, timer);
#endif
    if (!self.storeID || gNowPlayingInfoCenter.nowPlayingContentItem.storeID != self.storeID) {
        [timer invalidate];
        self.amlTimer = nil;
        return;
    }
    double elapsedTime = [self calculatedElapsedTime];
    if (elapsedTime < 0) {
        elapsedTime = 0;
    }
    [self setElapsedTime:elapsedTime playbackRate:self.playbackRate];
}

// Hook to update lyrics and schedule next timer when playback time changes
- (void)setElapsedTime:(double)elapsedTime playbackRate:(float)playbackRate {
    %orig;
    [self.amlTimer invalidate];
    self.amlTimer = nil;
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

// Hook to update track artist name display
- (void)setTrackArtistName:(NSString *)trackArtistName {
    if (!trackArtistName || trackArtistName.length == 0) {
        %orig;
        return;
    }
    %orig([NSString stringWithFormat:@"%@ — %@", self.title, trackArtistName]);
}

%end

%end

%group AMCrashPatcher

// Patch to prevent crash in VSSubscriptionRegistrationCenter
%hook VSSubscriptionRegistrationCenter

- (void)registerSubscription:(id)arg1 {
    return;
}

%end

%end

// Entry point for the tweak, initialize global state and groups
%ctor {
    dlopen("/System/Library/Frameworks/VideoSubscriberAccount.framework/VideoSubscriberAccount", RTLD_NOW);
    %init(AMCrashPatcher);
    %init(AMLyricsPrimary);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLyricsCache = [[NSMutableDictionary alloc] init];
        gLyricsQueue = dispatch_queue_create("com.82flex.amlyrics.queue", DISPATCH_QUEUE_SERIAL);
        gLyricsTaskQueue = [NSMutableArray array];
        gPendingLyricsIDs = [NSMutableSet set];
    });
}
