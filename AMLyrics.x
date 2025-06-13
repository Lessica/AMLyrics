@import Foundation;

#import <Foundation/Foundation.h>

struct BlockDescriptor {
    unsigned long reserved;
    unsigned long size;
    void *rest[1];
};

struct Block {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct BlockDescriptor *descriptor;
};

__used
static const char *BlockSig(id blockObj)
{
    struct Block *block = (__bridge void *)blockObj;
    struct BlockDescriptor *descriptor = block->descriptor;

    int copyDisposeFlag = 1 << 25;
    int signatureFlag = 1 << 30;

    assert(block->flags & signatureFlag);

    int index = 0;
    if (block->flags & copyDisposeFlag)
        index += 2;

    return descriptor->rest[index];
}

@interface ICURLResponse : NSObject
@property (nonatomic, readonly) NSData *bodyData;
@end

// v24@?0@"ICURLResponse"8@"NSError"16
typedef void (^ICURLSessionCompletionHandler)(ICURLResponse *, NSError *);

@interface MSVLyricsLine : NSObject
@property (assign, nonatomic) NSTimeInterval startTime;
@property (assign, nonatomic) NSTimeInterval endTime;
@property (copy, nonatomic) NSAttributedString *lyricsText;
@end

@interface ICMusicKitRequestContext : NSObject
@end

@interface ICMusicKitURLRequest : NSObject
@property (nonatomic, copy, readonly) ICMusicKitRequestContext *requestContext;
- (instancetype)initWithURL:(NSURL *)arg1 requestContext:(ICMusicKitRequestContext *)arg2;
@end

@interface MRContentItemMetadata : NSObject
@property (assign, nonatomic) bool lyricsAvailable;
@property (assign, nonatomic) bool hasLyricsAvailable;
@property (assign, nonatomic) long long lyricsAdamID;
@property (assign, nonatomic) bool hasLyricsAdamID;
@end

@interface MRContentItem : NSObject
@property (nonatomic, copy) MRContentItemMetadata *metadata;
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
@end

static ICURLSession *gSession = nil;
static ICMusicKitRequestContext *gRequestContext = nil;

%hook MSVLyricsTTMLParser

- (instancetype)initWithTTMLData:(NSData *)data {
	%log;
	return %orig;
}

- (id)parseWithError:(id*)arg1 {
	id ret = %orig;
#if DEBUG
	NSMutableArray *lyricLines = [NSMutableArray array];
	for (MSVLyricsLine *line in [self lyricLines]) {
		NSString *text = line.lyricsText.string;
		if (text.length == 0) {
			continue;
		}
		[lyricLines addObject:@{
			@"startTime": @(line.startTime),
			@"endTime": @(line.endTime),
			@"text": text,
		}];
	}
	NSLog(@"Parsed lyric lines: %@", lyricLines);
#endif
	return ret;
}

%end

%hook MPModelLyrics

- (void)setTTML:(NSString *)ttml {
#if DEBUG
	%log;
#endif
	%orig;
}

%end

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

%hook MRNowPlayingPlayerClient

- (void)sendContentItemChanges:(NSArray<MRContentItem *> *)contentItems {
	%orig;
	if (!gSession || !gRequestContext) {
		return;
	}
	MRContentItem *item = self.nowPlayingContentItem;
	if (item.metadata.lyricsAvailable) {
		NSString *lyricURLString = [NSString stringWithFormat:@"https://amp-api.music.apple.com/v1/catalog/cn/songs/%lld/syllable-lyrics?l=zh-Hans-CN", item.metadata.lyricsAdamID];
		NSURL *lyricURL = [NSURL URLWithString:lyricURLString];
		ICMusicKitURLRequest *request = [[%c(ICMusicKitURLRequest) alloc] initWithURL:lyricURL requestContext:gRequestContext];
		[gSession enqueueDataRequest:request withCompletionHandler:^(ICURLResponse *response, NSError *error) {
			if (error) {
				NSLog(@"Error fetching lyrics: %@", error);
				return;
			}
			if ([response.bodyData isKindOfClass:[NSData class]]) {
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
				if ([object isKindOfClass:[NSString class]]) {
					NSData *data = [object dataUsingEncoding:NSUTF8StringEncoding];
					NSError *parseError = nil;
					MSVLyricsTTMLParser *parser = [[%c(MSVLyricsTTMLParser) alloc] initWithTTMLData:data];
					[parser parseWithError:&parseError];
					if (parseError) {
						NSLog(@"Error parsing lyrics: %@", parseError);
					}
					NSArray<MSVLyricsLine *> *lyricLines = [parser lyricLines];
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
					NSLog(@"Fetched lyrics for item %lld: %@", item.metadata.lyricsAdamID, lyricData);
				}
			}
		}];
	}
}

%end

%ctor {
}
