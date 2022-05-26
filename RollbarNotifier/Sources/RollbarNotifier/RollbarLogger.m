@import Foundation;

#if TARGET_OS_IOS | TARGET_OS_TV | TARGET_OS_MACCATALYST
@import UIKit;
#endif

@import RollbarCommon;

#import "RollbarLogger.h"
#import "RollbarLogger+Test.h"
#import "RollbarThread.h"
#import "RollbarTelemetryThread.h"
#import "RollbarReachability.h"
#import <sys/utsname.h>
#import "RollbarTelemetry.h"
#import "RollbarPayloadTruncator.h"
#import "RollbarConfig.h"

#import "RollbarPayloadDTOs.h"

#define MAX_PAYLOAD_SIZE 128 // The maximum payload size in kb

static NSString * const PAYLOADS_FILE_NAME = @"rollbar.payloads";
static NSString * const QUEUED_ITEMS_FILE_NAME = @"rollbar.items";
static NSString * const QUEUED_ITEMS_STATE_FILE_NAME = @"rollbar.state";

/// Rollbar API Service enforced payload rate limit:
static NSString * const RESPONSE_HEADER_RATE_LIMIT = @"x-rate-limit-limit";
/// Rollbar API Service enforced remaining payload count until the limit is reached:
static NSString * const RESPONSE_HEADER_REMAINING_COUNT = @"x-rate-limit-remaining";
/// Rollbar API Service enforced rate limit reset time for the current limit window:
static NSString * const RESPONSE_HEADER_RESET_TIME = @"x-rate-limit-reset";
/// Rollbar API Service enforced rate limit remaining seconds of the current limit window:
static NSString * const RESPONSE_HEADER_REMAINING_SECONDS = @"x-rate-limit-remaining-seconds";

static NSUInteger MAX_RETRY_COUNT = 5;

static NSString *payloadsFilePath = nil;
static NSString *oomDetectionFilePath = nil;
static NSString *queuedItemsFilePath = nil;
static NSString *stateFilePath = nil;
static NSMutableDictionary *queueState = nil;

static RollbarThread *rollbarThread = nil;

#if !TARGET_OS_WATCH
static RollbarReachability *reachability = nil;
static BOOL isNetworkReachable = YES;
#endif

@implementation RollbarLogger {
    NSDate *nextSendTime;
    
    @private
    NSDictionary *m_osData;
}

static RollbarLogger *sharedSingleton = nil;

/// This is essentially a static constructor for the type.
+ (void)initialize {
    
    if (self == [RollbarLogger class]) {
        
        // create working cache directory:
        [RollbarCachesDirectory ensureCachesDirectoryExists];
        NSString *cachesDirectory = [RollbarCachesDirectory directory];
        
        // make sure we have all the data files set:
        queuedItemsFilePath =
        [cachesDirectory stringByAppendingPathComponent:QUEUED_ITEMS_FILE_NAME];
        stateFilePath =
        [cachesDirectory stringByAppendingPathComponent:QUEUED_ITEMS_STATE_FILE_NAME];
        payloadsFilePath =
        [cachesDirectory stringByAppendingPathComponent:PAYLOADS_FILE_NAME];

        // either create or overwrite the payloads log file:
        [[NSFileManager defaultManager] createFileAtPath:payloadsFilePath
                                                contents:nil
                                              attributes:nil];
        
        // create the queued items file if does not exist already:
        if (![[NSFileManager defaultManager] fileExistsAtPath:queuedItemsFilePath]) {
            [[NSFileManager defaultManager] createFileAtPath:queuedItemsFilePath
                                                    contents:nil
                                                  attributes:nil];
        }
        
        // create state tracking file if does not exist already:
        if ([[NSFileManager defaultManager] fileExistsAtPath:stateFilePath]) {
            NSData *stateData = [NSData dataWithContentsOfFile:stateFilePath];
            if (stateData) {
                NSDictionary *state = [NSJSONSerialization JSONObjectWithData:stateData
                                                                      options:0
                                                                        error:nil];
                queueState = [state mutableCopy];
            } else {
                RollbarSdkLog(@"There was an error restoring saved queue state");
            }
        }
        if (!queueState) {
            queueState = [@{@"offset": [NSNumber numberWithUnsignedInt:0],
                            @"retry_count": [NSNumber numberWithUnsignedInt:0]} mutableCopy];
            [self saveQueueState];
        }

        RollbarConfig *config = [RollbarConfig new];

        // Setup the worker thread that sends the items that have been queued up in the item file set above:
        // TODO: !!! this needs to be redesigned taking in account multiple access tokens and endpoints !!!
        RollbarLogger *logger = [[RollbarLogger alloc] initWithConfiguration:config];
        rollbarThread =
        [[RollbarThread alloc] initWithNotifier:logger
                                  reportingRate:config.loggingOptions.maximumReportsPerMinute];
        [rollbarThread start];
        
#if !TARGET_OS_WATCH
        // Listen for reachability status so that the items are only sent when the internet is available:
        reachability = [RollbarReachability reachabilityForInternetConnection];
        isNetworkReachable = [reachability isReachable];
        reachability.reachableBlock = ^(RollbarReachability*reach) {
            [logger captureTelemetryDataForNetwork:true];
            isNetworkReachable = YES;
        };
        reachability.unreachableBlock = ^(RollbarReachability*reach) {
            [logger captureTelemetryDataForNetwork:false];
            isNetworkReachable = NO;
        };
        
        [reachability startNotifier];
#endif
    }
}

+ (nonnull RollbarLogger *)sharedInstance {
    @synchronized (self) {
        if (sharedSingleton == nil) {
            sharedSingleton = [[self alloc] init];
        }
        return sharedSingleton;
    }
}

+ (nonnull RollbarLogger *)createLoggerWithConfig:(nonnull RollbarConfig *)config {
    return [[self alloc] initWithConfiguration:config];
}

/// Designated notifier initializer
/// @param accessToken the access token
- (instancetype)initWithAccessToken:(NSString *)accessToken {
    RollbarConfig *config = [RollbarConfig new];
    config.destination.accessToken = accessToken;
    return [self initWithConfiguration:config];
}

/// Designated notifier initializer
/// @param configuration the config object
- (instancetype)initWithConfiguration:(RollbarConfig *)configuration {

    if ((self = [super init])) {
        
        [self updateConfiguration:configuration];

        NSString *cachesDirectory = [RollbarCachesDirectory directory];
        if (nil != self.configuration.developerOptions.payloadLogFile
            && self.configuration.developerOptions.payloadLogFile.length > 0) {
            
            payloadsFilePath =
            [cachesDirectory stringByAppendingPathComponent:self.configuration.developerOptions.payloadLogFile];
        }
        else {
            
            payloadsFilePath =
            [cachesDirectory stringByAppendingPathComponent:PAYLOADS_FILE_NAME];
        }

        self->nextSendTime = [[NSDate alloc] init];
    }

    return self;
}

- (void)logCrashReport:(NSString *)crashReport {

    RollbarConfig *config = self.configuration;
    
    if (YES == [self shouldSkipReporting:config.loggingOptions.crashLevel]) {
        return;
    }
    
    RollbarPayload *payload = [self buildRollbarPayloadWithLevel:config.loggingOptions.crashLevel
                                                         message:nil
                                                       exception:nil
                                                           error:nil
                                                           extra:nil
                                                     crashReport:crashReport
                                                         context:nil];
    [self report:payload];
}

- (void)log:(RollbarLevel)level
    message:(NSString *)message
       data:(NSDictionary<NSString *, id> *)data
    context:(NSString *)context {
    
    if (YES == [self shouldSkipReporting:level]) {
        return;
    }

    RollbarPayload *payload = [self buildRollbarPayloadWithLevel:level
                                                         message:message
                                                       exception:nil
                                                           error:nil
                                                           extra:data
                                                     crashReport:nil
                                                         context:context
                               ];
    [self report:payload];
}

- (void)log:(RollbarLevel)level
  exception:(NSException *)exception
       data:(NSDictionary<NSString *, id> *)data
    context:(NSString *)context {
    
    if (YES == [self shouldSkipReporting:level]) {
        return;
    }
    
    RollbarPayload *payload = [self buildRollbarPayloadWithLevel:level
                                                         message:nil
                                                       exception:exception
                                                           error:nil
                                                           extra:data
                                                     crashReport:nil
                                                         context:context
                               ];
    [self report:payload];
}

- (void)log:(RollbarLevel)level
      error:(NSError *)error
       data:(NSDictionary<NSString *, id> *)data
    context:(NSString *)context {

    if (YES == [self shouldSkipReporting:level]) {
        return;
    }
    
    RollbarPayload *payload = [self buildRollbarPayloadWithLevel:level
                                                         message:nil
                                                       exception:nil
                                                           error:error
                                                           extra:data
                                                     crashReport:nil
                                                         context:context
                               ];
    [self report:payload];
}

- (BOOL)shouldSkipReporting:(RollbarLevel)level {
    
    RollbarConfig *config = self.configuration;
    
    if (!config.developerOptions.enabled) {
        return YES;
    }
    
    if (level < config.loggingOptions.logLevel) {
        return YES;
    }
    
    return NO;
}

- (void)report:(RollbarPayload *)payload {
    if (payload) {
        [self queuePayload:payload.jsonFriendlyData];
    }
}

+ (void)saveQueueState {
    NSError *error;
    NSData *data = [NSJSONSerialization rollbar_dataWithJSONObject:queueState
                                                   options:0
                                                     error:&error
                                                      safe:true];
    if (error) {
        RollbarSdkLog(@"Error: %@", [error localizedDescription]);
    }
    [data writeToFile:stateFilePath atomically:YES];
}

- (void)processSavedItems {

#if !TARGET_OS_WATCH
    if (!isNetworkReachable) {
        RollbarSdkLog(@"Processing saved items: no network!");
        // Don't attempt sending if the network is known to be not reachable
        return;
    }
#endif
    
    NSUInteger startOffset = [queueState[@"offset"] unsignedIntegerValue];

    NSFileHandle *fileHandle =
    [NSFileHandle fileHandleForReadingAtPath:queuedItemsFilePath];
    [fileHandle seekToEndOfFile];
    __block unsigned long long fileLength = [fileHandle offsetInFile];
    [fileHandle closeFile];

    if (!fileLength) {
        if (NO == self.configuration.developerOptions.suppressSdkInfoLogging) {
            RollbarSdkLog(@"Processing saved items: no queued items in the file!");
        }
        return;
    }

    // Empty out the queued item file if all items have been processed already
    if (startOffset == fileLength) {
        [@"" writeToFile:queuedItemsFilePath
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];

        queueState[@"offset"] = [NSNumber numberWithUnsignedInteger:0];
        queueState[@"retry_count"] = [NSNumber numberWithUnsignedInteger:0];
        [RollbarLogger saveQueueState];
        if (NO == self.configuration.developerOptions.suppressSdkInfoLogging) {
            RollbarSdkLog(@"Processing saved items: emptied the queued items file.");
        }

        return;
    }

    // Iterate through the items file and send the items in batches.
    RollbarFileReader *reader =
    [[RollbarFileReader alloc] initWithFilePath:queuedItemsFilePath
                                      andOffset:startOffset];
    [reader enumerateLinesUsingBlock:^(NSString *line, NSUInteger nextOffset, BOOL *stop) {
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!lineData) {
            // All we can do is ignore this line
            RollbarSdkLog(@"Error converting file line to NSData: %@", line);
            return;
        }
        NSError *error;
        NSJSONReadingOptions serializationOptions = (NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves);
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:lineData
                                                                options:serializationOptions
                                                                  error:&error];

        if (!payload) {
            // Ignore this line if it isn't valid json and proceed to the next line
            RollbarSdkLog(@"Error restoring data from file to JSON: %@", error);
            RollbarSdkLog(@"Raw data from file failed conversion to JSON:");
            RollbarSdkLog(@"%@", lineData);
//            RollbarSdkLog(@"   error code: %@", error.code);
//            RollbarSdkLog(@"   error domain: %@", error.domain);
//            RollbarSdkLog(@"   error description: %@", error.description);
//            RollbarSdkLog(@"   error localized description: %@", error.localizedDescription);
//            RollbarSdkLog(@"   error failure reason: %@", error.localizedFailureReason);
//            RollbarSdkLog(@"   error recovery option: %@", error.localizedRecoveryOptions);
//            RollbarSdkLog(@"   error recovery suggestion: %@", error.localizedRecoverySuggestion);
            return;
        }

        BOOL shouldContinue = [self sendItem:payload nextOffset:nextOffset];

        if (!shouldContinue) {
            // Stop processing the file so that the current file offset will be
            // retried next time the file is processed
            *stop = YES;
            return;
        }
        
        // The file has had items added since we started iterating through it,
        // update the known file length to equal the next offset
        if (nextOffset > fileLength) {
            fileLength = nextOffset;
        }

    }];
}

#pragma mark - Payload DTO builders

-(RollbarPerson *)buildRollbarPerson {
    
    RollbarConfig *config = self.configuration;
    if (config && config.person && config.person.ID) {
        return config.person;
    }
    else {
        return nil;
    }
}

-(RollbarServer *)buildRollbarServer {
    
    RollbarConfig *config = self.configuration;
    if (config && config.server && !config.server.isEmpty) {
        return [[RollbarServer alloc] initWithCpu:nil
                                     serverConfig:config.server];
    }
    else {
        return nil;
    }
}

-(NSDictionary *)buildOSData {
    
    if (self->m_osData) {
        return self->m_osData;
    }
    
    NSBundle *mainBundle = [NSBundle mainBundle];
    
    NSString *version = nil;
    RollbarConfig *config = self.configuration;
    if (config
        && config.loggingOptions
        && config.loggingOptions.codeVersion
        && config.loggingOptions.codeVersion.length > 0) {
        
        version = config.loggingOptions.codeVersion;
    }
    else {
        version = [mainBundle objectForInfoDictionaryKey:(NSString*)kCFBundleVersionKey];
    }
    
    NSString *shortVersion = [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *bundleName = [mainBundle objectForInfoDictionaryKey:(NSString *)kCFBundleNameKey];
    NSString *bundleIdentifier = [mainBundle objectForInfoDictionaryKey:(NSString *)kCFBundleIdentifierKey];
    
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *deviceCode = [NSString stringWithCString:systemInfo.machine
                                              encoding:NSUTF8StringEncoding];
    
#if TARGET_OS_IOS | TARGET_OS_TV | TARGET_OS_MACCATALYST
    self->m_osData = @{
        @"os": @"iOS",
        @"os_version": [[UIDevice currentDevice] systemVersion],
        @"device_code": deviceCode,
        @"code_version": version ? version : @"",
        @"short_version": shortVersion ? shortVersion : @"",
        @"bundle_identifier": bundleIdentifier ? bundleIdentifier : @"",
        @"app_name": bundleName ? bundleName : @""
    };
#else
    NSOperatingSystemVersion osVer = [[NSProcessInfo processInfo] operatingSystemVersion];
    self->m_osData = @{
        @"os": @"macOS",
        @"os_version": [NSString stringWithFormat:@" %tu.%tu.%tu",
                        osVer.majorVersion,
                        osVer.minorVersion,
                        osVer.patchVersion
                        ],
        @"device_code": deviceCode,
        @"code_version": version ? version : @"",
        @"short_version": shortVersion ? shortVersion : @"",
        @"bundle_identifier": bundleIdentifier ? bundleIdentifier : @"",
        @"app_name": bundleName ? bundleName : [[NSProcessInfo processInfo] processName]
    };
#endif

    return self->m_osData;
}

-(RollbarClient *)buildRollbarClient {
    
    NSNumber *timestamp = [NSNumber numberWithInteger:[[NSDate date] timeIntervalSince1970]];

    RollbarConfig *config = self.configuration;
    if (config && config.loggingOptions) {
        switch(config.loggingOptions.captureIp) {
            case RollbarCaptureIpType_Full:
                return [[RollbarClient alloc] initWithDictionary:@{
                    @"timestamp": timestamp,
                    @"ios": [self buildOSData],
                    @"user_ip": @"$remote_ip"
                }];
            case RollbarCaptureIpType_Anonymize:
                return [[RollbarClient alloc] initWithDictionary:@{
                    @"timestamp": timestamp,
                    @"ios": [self buildOSData],
                    @"user_ip": @"$remote_ip_anonymize"
                }];
            case RollbarCaptureIpType_None:
                //no op
                break;
        }
    }

    return [[RollbarClient alloc] initWithDictionary:@{
        @"timestamp": timestamp,
        @"ios": [self buildOSData],
    }];
}

-(RollbarModule *)buildRollbarNotifierModule {

    RollbarConfig *config = self.configuration;
    if (config && config.notifier && !config.notifier.isEmpty) {
        
        RollbarModule *notifierModule =
        [[RollbarModule alloc] initWithDictionary:config.notifier.jsonFriendlyData.copy];
        [notifierModule setData:config.jsonFriendlyData byKey:@"configured_options"];
        return notifierModule;
    }
    
    return nil;
}

-(RollbarPayload *)buildRollbarPayloadWithLevel:(RollbarLevel)level
                                 message:(NSString *)message
                               exception:(NSException *)exception
                                   error:(NSError *)error
                                   extra:(NSDictionary *)extra
                             crashReport:(NSString *)crashReport
                                 context:(NSString *)context {

    // check critical config settings:
    RollbarConfig *config = self.configuration;
    if (!config
        || !config.destination
        || !config.destination.environment
        || config.destination.environment.length == 0) {
        
        return nil;
    }

    // compile payload data proper body:
    RollbarBody *body = [RollbarBody alloc];
    if (crashReport) {
        body = [body initWithCrashReport:crashReport];
    }
    else if (error) {
        body = [body initWithError:error];
    }
    else if (exception) {
        body = [body initWithException:exception];
    }
    else if (message) {
        body = [body initWithMessage:message];
    }
    else {
        return nil;
    }
    
    if (!body) {
        return nil;
    }
    
    // this is done only for backward compatibility for customers that used to rely on this undocumented
    // extra data with a message:
    if (message && extra) {
        [body.message setData:extra byKey:@"extra"];
    }
    
    // compile payload data:
    RollbarData *data = [[RollbarData alloc] initWithEnvironment:config.destination.environment
                                                            body:body];
    if (!data) {
        return nil;
    }
    
    NSMutableDictionary *customData =
        [NSMutableDictionary dictionaryWithDictionary:self.configuration.customData];
    if (crashReport || exception) {
        // neither crash report no exception payload objects have placeholders for any extra data
        // or an extra message, let's preserve them as the custom data:
        if (extra) {
            customData[@"error.extra"] = extra;
        }
        if (message && message.length > 0) {
            customData[@"error.message"] = message;
        }
    }

    data.level = level;
    data.language = RollbarAppLanguage_ObjectiveC;
    data.platform = @"client";
    data.uuid = [NSUUID UUID];
    data.custom = [[RollbarDTO alloc] initWithDictionary:customData];
    data.notifier = [self buildRollbarNotifierModule];
    data.person = [self buildRollbarPerson];
    data.server = [self buildRollbarServer];
    data.client = [self buildRollbarClient];
    if (context && context.length > 0) {
        data.context = context;
    }
    if (config.loggingOptions) {
        data.framework = config.loggingOptions.framework;
        if (config.loggingOptions.requestId
            && (config.loggingOptions.requestId.length > 0)) {

            [data setData:config.loggingOptions.requestId byKey:@"requestId"];
        }
    }
    
    // Transform payload data, if necessary
    if ([self shouldIgnoreRollbarData:data]) {
        return nil;
    }
    data = [self modifyRollbarData:data];
    data = [self scrubRollbarData:data];

    RollbarPayload *payload = [[RollbarPayload alloc] initWithAccessToken:config.destination.accessToken
                                                                     data:data];

    return payload;
}

-(BOOL)shouldIgnoreRollbarData:(nonnull RollbarData *)incomingData {

    BOOL shouldIgnore = NO;
    if (self.configuration.checkIgnoreRollbarData) {
        @try {
            shouldIgnore = self.configuration.checkIgnoreRollbarData(incomingData);
            return shouldIgnore;
        } @catch(NSException *e) {
            RollbarSdkLog(@"checkIgnore error: %@", e.reason);

            // Remove checkIgnore to prevent future exceptions
            self.configuration.checkIgnoreRollbarData = nil;
            return NO;
        }
    }

    return shouldIgnore;
}

-(RollbarData *)modifyRollbarData:(nonnull RollbarData *)incomingData {

    if (self.configuration.modifyRollbarData) {
        return self.configuration.modifyRollbarData(incomingData);
    }
    return incomingData;
}

-(RollbarData *)scrubRollbarData:(nonnull RollbarData *)incomingData {

    NSSet *scrubFieldsSet = [self getScrubFields];
    if (!scrubFieldsSet || scrubFieldsSet.count == 0) {
        return incomingData;
    }
    
    NSMutableDictionary *mutableJsonFriendlyData = incomingData.jsonFriendlyData.mutableCopy;
    for (NSString *key in scrubFieldsSet) {
        if ([mutableJsonFriendlyData valueForKeyPath:key]) {
            [self createMutablePayloadWithData:mutableJsonFriendlyData forPath:key];
            [mutableJsonFriendlyData setValue:@"*****" forKeyPath:key];
        }
    }

    return [[RollbarData alloc] initWithDictionary:mutableJsonFriendlyData];
}

-(NSSet *)getScrubFields {
    
    RollbarConfig *config = self.configuration;
    if (!config
        || !config.dataScrubber
        || config.dataScrubber.isEmpty
        || !config.dataScrubber.enabled
        || !config.dataScrubber.scrubFields
        || config.dataScrubber.scrubFields.count == 0) {
        
        return [NSSet set];
    }
    
    NSMutableSet *actualFieldsToScrub = config.dataScrubber.scrubFields.mutableCopy;
    if (config.dataScrubber.safeListFields.count > 0) {
        // actualFieldsToScrub =
        // config.dataScrubber.scrubFields - config.dataScrubber.whitelistFields
        // while using case insensitive field name comparison:
        actualFieldsToScrub = [NSMutableSet new];
        for(NSString *key in config.dataScrubber.scrubFields) {
            BOOL isWhitelisted = false;
            for (NSString *whiteKey in config.dataScrubber.safeListFields) {
                if (NSOrderedSame == [key caseInsensitiveCompare:whiteKey]) {
                    isWhitelisted = true;
                }
            }
            if (!isWhitelisted) {
                [actualFieldsToScrub addObject:key];
            }
        }
    }
    
    return actualFieldsToScrub;
}

#pragma mark - LEGACY payload data builders

- (void)queuePayload:(NSDictionary *)payload {
    
    [self performSelector:@selector(queuePayload_OnlyCallOnThread:)
                 onThread:rollbarThread
               withObject:payload
            waitUntilDone:NO
     ];
}

- (void)queuePayload_OnlyCallOnThread:(NSDictionary *)payload {
    
    NSError *error = nil;
    NSData *data = [NSJSONSerialization rollbar_dataWithJSONObject:payload
                                                           options:0
                                                             error:&error
                                                              safe:true];
    if (nil == data) {
        
        RollbarSdkLog(@"Couldn't generate and save JSON data from: %@", payload);
        if (error) {

            RollbarSdkLog(@"    Error: %@", [error localizedDescription]);
        }
        return;
    }
    
    [RollbarFileWriter appendSafelyData:data toFile:queuedItemsFilePath];

    [[RollbarTelemetry sharedInstance] clearAllData];
}

- (BOOL)sendItem:(NSDictionary *)payload
       nextOffset:(NSUInteger)nextOffset {
    
    RollbarPayload *rollbarPayload =
    [[RollbarPayload alloc] initWithDictionary:[payload copy]];
    if (nil == rollbarPayload) {
        
        RollbarSdkLog(
            @"Couldn't init and send RollbarPayload with data: %@",
            payload
        );
//        queueState[@"offset"] = [NSNumber numberWithUnsignedInteger:nextOffset];
//        queueState[@"retry_count"] = [NSNumber numberWithUnsignedInteger:0];
//        [RollbarLogger saveQueueState];
        return YES; // no retry needed
    }
    
    NSMutableDictionary *newPayload =
    [NSMutableDictionary dictionaryWithDictionary:payload];
    [RollbarPayloadTruncator truncatePayload:newPayload];
    if (nil == newPayload) {
        
        RollbarSdkLog(
            @"Couldn't send truncated payload that is nil"
        );
//        queueState[@"offset"] = [NSNumber numberWithUnsignedInteger:nextOffset];
//        queueState[@"retry_count"] = [NSNumber numberWithUnsignedInteger:0];
//        [RollbarLogger saveQueueState];
        return YES; // no retry needed
    }

    NSError *error;
    NSData *jsonPayload = [NSJSONSerialization rollbar_dataWithJSONObject:newPayload
                                                          options:0
                                                            error:&error
                                                             safe:true];
    if (nil == jsonPayload) {
        
        RollbarSdkLog(
            @"Couldn't send jsonPayload that is nil"
        );
        if (nil != error) {
            
            RollbarSdkLog(
                @"   DETAILS: an error while generating JSON data: %@",
                error
            );
        }
//        queueState[@"offset"] = [NSNumber numberWithUnsignedInteger:nextOffset];
//        queueState[@"retry_count"] = [NSNumber numberWithUnsignedInteger:0];
//        [RollbarLogger saveQueueState];
        return YES; // no retry needed
    }
    
    if (NSOrderedDescending != [nextSendTime compare: [[NSDate alloc] init] ]) {
        
        NSUInteger retryCount =
        [queueState[@"retry_count"] unsignedIntegerValue];

        RollbarConfig *rollbarConfig =
        [[RollbarConfig alloc] initWithDictionary:rollbarPayload.data.notifier.jsonFriendlyData[@"configured_options"]];
        
        if (0 == retryCount && YES == rollbarConfig.developerOptions.logPayload) {
            if (NO == rollbarConfig.developerOptions.suppressSdkInfoLogging) {
                RollbarSdkLog(@"About to send payload: %@",
                           [[NSString alloc] initWithData:jsonPayload
                                                 encoding:NSUTF8StringEncoding]
                           );
            }

            // - save this payload into a proper payloads log file:
            //*****************************************************
            
            // compose the payloads log file path:
            NSString *cachesDirectory = [RollbarCachesDirectory directory];
            NSString *payloadsLogFilePath =
            [cachesDirectory stringByAppendingPathComponent:rollbarConfig.developerOptions.payloadLogFile];
            
            [RollbarFileWriter appendSafelyData:jsonPayload toFile:payloadsLogFilePath];
        }
        
        BOOL success =
        rollbarConfig ? [self sendPayload:jsonPayload usingConfig:rollbarConfig]
        : [self sendPayload:jsonPayload]; // backward compatibility with just upgraded very old SDKs...
        
        if (!success) {
            
            if (retryCount < MAX_RETRY_COUNT) {
                
                queueState[@"retry_count"] =
                [NSNumber numberWithUnsignedInteger:retryCount + 1];
                
                [RollbarLogger saveQueueState];
                
                // Return NO so that the current batch will be retried next time
                return NO;
            }
        }
    }
    else {
        
        RollbarSdkLog(
            @"Omitting payload until nextSendTime is reached: %@",
            [[NSString alloc] initWithData:jsonPayload encoding:NSUTF8StringEncoding]
        );
    }
    
    queueState[@"offset"] = [NSNumber numberWithUnsignedInteger:nextOffset];
    queueState[@"retry_count"] = [NSNumber numberWithUnsignedInteger:0];
    [RollbarLogger saveQueueState];
    
    return YES;
}

- (BOOL)sendPayload:(nonnull NSData *)payload
        usingConfig:(nonnull RollbarConfig  *)config {
    
    if ((nil == payload)
        || (nil == self.configuration)
        || (nil == self.configuration.destination)
        || (nil == self.configuration.destination.endpoint)
        || (nil == self.configuration.destination.accessToken)
        || (0 == self.configuration.destination.endpoint.length)
        || (0 == self.configuration.destination.accessToken.length)
        ) {
        
        return NO;
    }
    
    NSURL *url = [NSURL URLWithString:config.destination.endpoint];
    if (nil == url) {
        return NO;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:config.destination.accessToken forHTTPHeaderField:@"X-Rollbar-Access-Token"];
    [request setHTTPBody:payload];

    if (YES == config.developerOptions.logPayload) {
        NSString *payloadString = [[NSString alloc]initWithData:payload
                                                       encoding:NSUTF8StringEncoding
                                   ];
        NSLog(@"%@", payloadString);
        //TODO: if config.developerOptions.logPayloadFile is defined, save the payload into the file...
    }

    if (NO == config.developerOptions.transmit) {
        return YES; // we just successfully short-circuit here...
    }

    __block BOOL result = NO;

    // This requires iOS 7.0+
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSession *session = [NSURLSession sharedSession];

    if (config.httpProxy.enabled
        || config.httpsProxy.enabled) {

        NSDictionary *connectionProxyDictionary =
        @{
          @"HTTPEnable"   : [NSNumber numberWithBool:config.httpProxy.enabled],
          @"HTTPProxy"    : config.httpProxy.proxyUrl,
          @"HTTPPort"     : [NSNumber numberWithUnsignedInteger:config.httpProxy.proxyPort],
          @"HTTPSEnable"  : [NSNumber numberWithBool:config.httpsProxy.enabled],
          @"HTTPSProxy"   : config.httpsProxy.proxyUrl,
          @"HTTPSPort"    : [NSNumber numberWithUnsignedInteger:config.httpsProxy.proxyPort]
          };

        NSURLSessionConfiguration *sessionConfig =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
        sessionConfig.connectionProxyDictionary = connectionProxyDictionary;
        session = [NSURLSession sessionWithConfiguration:sessionConfig];
    }

    NSURLSessionDataTask *dataTask =
        [session dataTaskWithRequest:request
                   completionHandler:^(
                                       NSData * _Nullable data,
                                       NSURLResponse * _Nullable response,
                                       NSError * _Nullable error) {
            result = [self checkPayloadResponse:response
                                          error:error
                                           data:data];
            dispatch_semaphore_signal(sem);
        }];
    [dataTask resume];

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    return result;
}

/// This is a DEPRECATED method left for some backward compatibility for very old clients eventually moving to this more recent implementation.
/// Use/maintain sendPayload:usingConfig: instead!
- (BOOL)sendPayload:(NSData *)payload {

    if ((nil == payload)
        || (nil == self.configuration)
        || (nil == self.configuration.destination)
        || (nil == self.configuration.destination.endpoint)
        || (nil == self.configuration.destination.accessToken)
        || (0 == self.configuration.destination.endpoint.length)
        || (0 == self.configuration.destination.accessToken.length)
        ) {
        
        return NO;
    }
    
    NSURL *url = [NSURL URLWithString:self.configuration.destination.endpoint];
    if (nil == url) {
        return NO;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.configuration.destination.accessToken forHTTPHeaderField:@"X-Rollbar-Access-Token"];
    [request setHTTPBody:payload];

    if (YES == self.configuration.developerOptions.logPayload) {
        NSString *payloadString = [[NSString alloc]initWithData:payload
                                                       encoding:NSUTF8StringEncoding
                                   ];
        NSLog(@"%@", payloadString);
        //TODO: if self.configuration.logPayloadFile is defined, save the payload into the file...
    }

    if (NO == self.configuration.developerOptions.transmit) {
        return YES; // we just successfully short-circuit here...
    }

    __block BOOL result = NO;

    // This requires iOS 7.0+
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSession *session = [NSURLSession sharedSession];

    if (self.configuration.httpProxy.enabled
        || self.configuration.httpsProxy.enabled) {

        NSDictionary *connectionProxyDictionary =
        @{
            @"HTTPEnable"   : [NSNumber numberWithInt:self.configuration.httpProxy.enabled],
            @"HTTPProxy"    : self.configuration.httpProxy.proxyUrl,
            @"HTTPPort"     : @(self.configuration.httpProxy.proxyPort),
            @"HTTPSEnable"  : [NSNumber numberWithInt:self.configuration.httpsProxy.enabled],
            @"HTTPSProxy"   : self.configuration.httpsProxy.proxyUrl,
            @"HTTPSPort"    : @(self.configuration.httpsProxy.proxyPort)
          };

        NSURLSessionConfiguration *sessionConfig =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
        sessionConfig.connectionProxyDictionary = connectionProxyDictionary;
        session = [NSURLSession sessionWithConfiguration:sessionConfig];
    }

    NSURLSessionDataTask *dataTask =
        [session dataTaskWithRequest:request
                   completionHandler:^(
                                       NSData * _Nullable data,
                                       NSURLResponse * _Nullable response,
                                       NSError * _Nullable error) {
            result = [self checkPayloadResponse:response
                                          error:error
                                           data:data];
            dispatch_semaphore_signal(sem);
        }];
    [dataTask resume];

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    return result;
}

- (BOOL)checkPayloadResponse:(NSURLResponse *)response
                       error:(NSError *)error
                        data:(NSData *)data {

    if (NO == self.configuration.developerOptions.suppressSdkInfoLogging) {
                
        RollbarSdkLog(@"HTTP response from Rollbar: %@", response);
    }

    // Lookup rate limiting headers and adjust reporting rate accordingly:
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSDictionary *httpHeaders = [httpResponse allHeaderFields];
    //int rateLimit = [[httpHeaders valueForKey:RESPONSE_HEADER_RATE_LIMIT] intValue];
    int rateLimitLeft =
        [[httpHeaders valueForKey:RESPONSE_HEADER_REMAINING_COUNT] intValue];
    int rateLimitSeconds =
        [[httpHeaders valueForKey:RESPONSE_HEADER_REMAINING_SECONDS] intValue];
    if (rateLimitLeft > 0) {
        nextSendTime = [[NSDate alloc] init];
    }
    else {
        nextSendTime =
        [[NSDate alloc] initWithTimeIntervalSinceNow:rateLimitSeconds];
    }

    if (error) {
        RollbarSdkLog(@"There was an error reporting to Rollbar");
        RollbarSdkLog(@"Error: %@", [error localizedDescription]);
    } else {
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
        if ([httpResponse statusCode] == 200) {
            if (NO == self.configuration.developerOptions.suppressSdkInfoLogging) {
                RollbarSdkLog(@"Success");
            }
            return YES;
        } else {
            RollbarSdkLog(@"There was a problem reporting to Rollbar");
            if (data) {
                RollbarSdkLog(
                           @"Response: %@",
                           [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil]);
            }
        }
    }
    return NO;
}

#pragma mark - Payload truncate

- (void)createMutablePayloadWithData:(NSMutableDictionary *)data
                             forPath:(NSString *)path {
                                 
    NSArray *pathComponents = [path componentsSeparatedByString:@"."];
    NSString *currentPath = @"";

    for (int i=0; i<pathComponents.count; i++) {
        NSString *part = pathComponents[i];
        currentPath = i == 0 ? part
            : [NSString stringWithFormat:@"%@.%@", currentPath, part];
        id val = [data valueForKeyPath:currentPath];
        if (!val) return;
        if ([val isKindOfClass:[NSArray class]]
            && ![val isKindOfClass:[NSMutableArray class]]) {
            
            NSMutableArray *newVal = [NSMutableArray arrayWithArray:val];
            [data setValue:newVal forKeyPath:currentPath];
        } else if ([val isKindOfClass:[NSDictionary class]]
                   && ![val isKindOfClass:[NSMutableDictionary class]]) {
            
            NSMutableDictionary *newVal =
            [NSMutableDictionary dictionaryWithDictionary:val];
            [data setValue:newVal forKeyPath:currentPath];
        }
    }
}

#pragma mark - Update configuration methods

- (void)updateConfiguration:(RollbarConfig *)configuration {

    self.configuration = configuration;
}

- (void)updateAccessToken:(NSString *)accessToken {
    self.configuration.destination.accessToken = accessToken;
}

- (void)updateReportingRate:(NSUInteger)maximumReportsPerMinute {
    if (nil != self.configuration) {
        self.configuration.loggingOptions.maximumReportsPerMinute = maximumReportsPerMinute;
    }
    if (nil != rollbarThread) {
        [rollbarThread cancel];
        rollbarThread =
        [[RollbarThread alloc] initWithNotifier:self
                                  reportingRate:maximumReportsPerMinute];
        [rollbarThread start];
    }
}
    
#pragma mark - Network telemetry data

- (void)captureTelemetryDataForNetwork:(BOOL)reachable {
#if !TARGET_OS_WATCH
    if (self.configuration.telemetry.captureConnectivity
        && isNetworkReachable != reachable) {
        NSString *status = reachable ? @"Connected" : @"Disconnected";
        NSString *networkType = @"Unknown";
        NetworkStatus networkStatus = [reachability currentReachabilityStatus];
        if (networkStatus == ReachableViaWiFi) {
            networkType = @"WiFi";
        }
        else if (networkStatus == ReachableViaWWAN) {
            networkType = @"Cellular";
        }
        [[RollbarTelemetry sharedInstance]
         recordConnectivityEventForLevel:RollbarLevel_Warning
                                  status:status
                               extraData:@{@"network": networkType}];
    }
#endif
}

@end

#pragma mark - RollbarLogger (Test)

static NSString * const QUEUED_TELEMETRY_ITEMS_FILE_NAME = @"rollbar.telemetry";

@implementation RollbarLogger (Test)

+ (void)clearSdkDataStore {
    
    [RollbarLogger clearLogItemsStore];
    [RollbarLogger _clearFile:[RollbarLogger _telemetryItemsStorePath]];
    [RollbarLogger _clearFile:[RollbarLogger _payloadsLogStorePath]];
}

+ (void)clearLogItemsStore {

    [RollbarLogger _clearFile:[RollbarLogger _logItemsStoreStatePath]];
    [RollbarLogger _clearFile:[RollbarLogger _logItemsStorePath]];
}

+ (void)clearSdkFile:(nonnull NSString *)sdkFileName {
    
    [RollbarLogger _clearFile:[RollbarLogger _getSDKDataFilePath:sdkFileName]];
}

+ (nonnull NSArray<NSMutableDictionary *> *)readLogItemsFromStore {
    
    NSString *filePath = [RollbarLogger _logItemsStorePath];
    return [RollbarLogger readPayloadsDataFromFile:filePath];
}

+ (nonnull NSArray<NSMutableDictionary *> *)readPayloadsFromSdkLog {
    
    NSString *filePath = [RollbarLogger _payloadsLogStorePath];
    return [RollbarLogger readPayloadsDataFromFile:filePath];
}

+ (nonnull NSArray<NSMutableDictionary *> *)readPayloadsDataFromFile:(nonnull NSString *)filePath {
    
    RollbarFileReader *reader = [[RollbarFileReader alloc] initWithFilePath:filePath
                                                                  andOffset:0];
    
    NSMutableArray<NSMutableDictionary *> *items = [NSMutableArray array];
    [reader enumerateLinesUsingBlock:^(NSString *line, NSUInteger nextOffset, BOOL *stop) {
        NSError *error = nil;
        NSMutableDictionary *payload =
        [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                        options:(NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves)
                                          error:&error
        ];
        if ((nil == payload) && (nil != error)) {
            RollbarSdkLog(@"Error serializing log item from the store: %@", [error localizedDescription]);
            return;
        }
        else if (nil == payload) {
            RollbarSdkLog(@"Error serializing log item from the store!");
            return;
        }
        
        NSMutableDictionary *data = payload[@"data"];
        [items addObject:data];
    }];
    
    return items;
}

+ (void)flushRollbarThread {
    
    [RollbarLogger performSelector:@selector(_test_doNothing)
                          onThread:[RollbarLogger _test_rollbarThread]
                        withObject:nil
                     waitUntilDone:YES
    ];
}

+ (void)_clearFile:(nonnull NSString *)filePath {
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    BOOL fileExists = [fileManager fileExistsAtPath:filePath];
    
    if (fileExists) {
        BOOL success = [fileManager removeItemAtPath:filePath
                                               error:&error];
        if (!success) {
            NSLog(@"Error: %@", [error localizedDescription]);
        }
        [[NSFileManager defaultManager] createFileAtPath:filePath
                                                contents:nil
                                              attributes:nil];
    }
}

+ (nonnull NSString *)_logItemsStorePath {
    
    return [RollbarLogger _getSDKDataFilePath:QUEUED_ITEMS_FILE_NAME];
}

+ (nonnull NSString *)_logItemsStoreStatePath {
    
    return [RollbarLogger _getSDKDataFilePath:QUEUED_ITEMS_STATE_FILE_NAME];
}

+ (nonnull NSString *)_telemetryItemsStorePath {
    
    return [RollbarLogger _getSDKDataFilePath:QUEUED_TELEMETRY_ITEMS_FILE_NAME];
}

+ (nonnull NSString *)_payloadsLogStorePath {
    
    return [RollbarLogger _getSDKDataFilePath:PAYLOADS_FILE_NAME];
}

+ (nonnull NSString *)_getSDKDataFilePath:(nonnull NSString *)sdkFileName {
    
    NSString *cachesDirectory = [RollbarCachesDirectory directory];
    return [cachesDirectory stringByAppendingPathComponent:sdkFileName];
}

+ (NSThread *)_test_rollbarThread {
    
    return rollbarThread;
}

+ (void)_test_doNothing {
    
    // no-Op simulation...
}

@end
