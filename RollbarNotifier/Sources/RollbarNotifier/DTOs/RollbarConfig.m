#import "RollbarConfig.h"
#import "RollbarCachesDirectory.h"
#import "RollbarDestination.h"
#import "RollbarDeveloperOptions.h"
#import "RollbarProxy.h"
#import "RollbarScrubbingOptions.h"
#import "RollbarServerConfig.h"
#import "RollbarPerson.h"
#import "RollbarModule.h"
#import "RollbarTelemetryOptions.h"
#import "RollbarTelemetryOptions.h"
#import "RollbarLoggingOptions.h"
#import <Foundation/Foundation.h>

#pragma mark - constants

static NSString * const NOTIFIER_VERSION = @"2.3.4";

static NSString * const NOTIFIER_NAME = @"rollbar-apple";

#define NOTIFIER_NAME_PREFIX = @"rollbar-";

#if TARGET_OS_IPHONE | TARGET_OS_IOS
static NSString * const OPERATING_SYSTEM = @"ios";
#elif TARGET_OS_OSX
static NSString * const OPERATING_SYSTEM = @"macos";
#elif TARGET_OS_TV
static NSString * const OPERATING_SYSTEM = @"tvos";
#elif TARGET_OS_WATCH
static NSString * const OPERATING_SYSTEM = @"watchos";
#else
static NSString * const OPERATING_SYSTEM = @"*os";
#endif

#pragma mark - static data

#pragma mark - data fields

static NSString * const DFK_DESTINATION = @"destination";
static NSString * const DFK_DEVELOPER_OPTIONS = @"developerOptions";
static NSString * const DFK_LOGGING_OPTIONS = @"loggingOptions";
static NSString * const DFK_DATA_SCRUBBER = @"dataScrubber";
static NSString * const DFK_HTTP_PROXY = @"httpProxy";
static NSString * const DFK_HTTPS_PROXY = @"httpsProxy";
static NSString * const DFK_SERVER = @"server";
static NSString * const DFK_PERSON = @"person";
static NSString * const DFK_NOTIFIER = @"notifier";
static NSString * const DFK_TELEMETRY = @"telemetry";
static NSString * const DFK_CUSTOM = @"custom";

#pragma mark - class implementation

@implementation RollbarConfig

#pragma mark - initializers

- (instancetype)init {

    self = [super initWithDictionary:@{
        DFK_DESTINATION:[RollbarDestination new].jsonFriendlyData,
        DFK_DEVELOPER_OPTIONS:[RollbarDeveloperOptions new].jsonFriendlyData,
        DFK_LOGGING_OPTIONS:[RollbarLoggingOptions new].jsonFriendlyData,
        DFK_HTTP_PROXY:[RollbarProxy new].jsonFriendlyData,
        DFK_HTTPS_PROXY:[RollbarProxy new].jsonFriendlyData,
        DFK_DATA_SCRUBBER:[RollbarScrubbingOptions new].jsonFriendlyData,
        DFK_TELEMETRY:[RollbarTelemetryOptions new].jsonFriendlyData,
        DFK_NOTIFIER:[[RollbarModule alloc] initWithName:NOTIFIER_NAME version:NOTIFIER_VERSION].jsonFriendlyData,
        DFK_SERVER:[RollbarServerConfig new].jsonFriendlyData,
        DFK_PERSON: [NSMutableDictionary<NSString *, id> new],
        DFK_CUSTOM: [NSMutableDictionary<NSString *, id> new]
    }];
    return self;
}


#pragma mark - Rollbar destination

- (RollbarDestination *)destination {
    id data = [self safelyGetDictionaryByKey:DFK_DESTINATION];
    id dto = [[RollbarDestination alloc] initWithDictionary:data];
    return dto;
}

- (void)setDestination:(RollbarDestination *)destination {
    [self setDataTransferObject:destination forKey:DFK_DESTINATION];
}

#pragma mark - Developer options

- (RollbarDeveloperOptions *)developerOptions {
    id data = [self safelyGetDictionaryByKey:DFK_DEVELOPER_OPTIONS];
    return [[RollbarDeveloperOptions alloc] initWithDictionary:data];
}

- (void)setDeveloperOptions:(RollbarDeveloperOptions *)developerOptions {
    [self setDataTransferObject:developerOptions forKey:DFK_DEVELOPER_OPTIONS];
}

#pragma mark - Logging options

- (RollbarLoggingOptions *)loggingOptions {
    id data = [self safelyGetDictionaryByKey:DFK_LOGGING_OPTIONS];
    return [[RollbarLoggingOptions alloc] initWithDictionary:data];
}

- (void)setLoggingOptions:(RollbarLoggingOptions *)developerOptions {
    [self setDataTransferObject:developerOptions forKey:DFK_LOGGING_OPTIONS];
}

#pragma mark - Notifier

- (RollbarModule *)notifier {
    id data = [self safelyGetDictionaryByKey:DFK_NOTIFIER];
    return [[RollbarModule alloc] initWithDictionary:data];
}

- (void)setNotifier:(RollbarModule *)developerOptions {
    [self setDataTransferObject:developerOptions forKey:DFK_NOTIFIER];
}

#pragma mark - Data scrubber

- (RollbarScrubbingOptions *)dataScrubber {
    id data = [self safelyGetDictionaryByKey:DFK_DATA_SCRUBBER];
    return [[RollbarScrubbingOptions alloc] initWithDictionary:data];
}

- (void)setDataScrubber:(RollbarScrubbingOptions *)value {
    [self setDataTransferObject:value forKey:DFK_DATA_SCRUBBER];
}

#pragma mark - Server

- (RollbarServerConfig *)server {
    id data = [self safelyGetDictionaryByKey:DFK_SERVER];
    return [[RollbarServerConfig alloc] initWithDictionary:data];
}

- (void)setServer:(RollbarServerConfig *)value {
    [self setDataTransferObject:value forKey:DFK_SERVER];
}

#pragma mark - Person

- (RollbarPerson *)person {
    id data = [self safelyGetDictionaryByKey:DFK_PERSON];
    return [[RollbarPerson alloc] initWithDictionary:data];
}

- (void)setPerson:(RollbarPerson *)value {
    [self setDataTransferObject:value forKey:DFK_PERSON];
}

#pragma mark - HTTP Proxy Settings

- (RollbarProxy *)httpProxy {
    id data = [self safelyGetDictionaryByKey:DFK_HTTP_PROXY];
    return [[RollbarProxy alloc] initWithDictionary:data];
}

- (void)setHttpProxy:(RollbarProxy *)value {
    [self setDataTransferObject:value forKey:DFK_HTTP_PROXY];
}

#pragma mark - HTTPS Proxy Settings

- (RollbarProxy *)httpsProxy {
    id data = [self safelyGetDictionaryByKey:DFK_HTTPS_PROXY];
    return [[RollbarProxy alloc] initWithDictionary:data];
}

- (void)setHttpsProxy:(RollbarProxy *)value {
    [self setDataTransferObject:value forKey:DFK_HTTPS_PROXY];
}

#pragma mark - Telemetry

- (RollbarTelemetryOptions *)telemetry {
    id data = [self safelyGetDictionaryByKey:DFK_TELEMETRY];
    return [[RollbarTelemetryOptions alloc] initWithDictionary:data];
}

- (void)setTelemetry:(RollbarTelemetryOptions *)value {
    [self setDataTransferObject:value forKey:DFK_TELEMETRY];
}

#pragma mark - Convenience Methods

- (void)setPersonId:(nonnull NSString*)personId
           username:(nullable NSString*)username
              email:(nullable NSString*)email {
    self.person.ID = personId;
    self.person.username = username;
    self.person.email = email;
}

- (void)setServerHost:(nullable NSString *)host
                 root:(nullable NSString*)root
               branch:(nullable NSString*)branch
          codeVersion:(nullable NSString*)codeVersion {
    self.server.host = host;
    self.server.root = root;
    self.server.branch = branch;
    self.server.codeVersion = codeVersion;
}

- (void)setNotifierName:(nullable NSString *)name
                version:(nullable NSString *)version {
    self.notifier.name = name;
    self.notifier.version = version;
}

#pragma mark - Custom data

- (NSDictionary<NSString *, id> *)customData {
    NSMutableDictionary *result = [self safelyGetDictionaryByKey:DFK_CUSTOM];
    return result;
}

- (void)setCustomData:(NSDictionary<NSString *, id> *)value {
    [self setDictionary:value forKey:DFK_CUSTOM];
}

//#pragma mark - RollbarPersistent protocol
//
//- (BOOL)loadFromFile:(nonnull NSString *)filePath {
//}
//
//- (BOOL)saveToFile:(nonnull NSString *)filePath {
//}

@end
