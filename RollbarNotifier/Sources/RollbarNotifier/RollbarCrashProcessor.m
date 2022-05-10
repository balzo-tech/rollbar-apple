#import "RollbarCrashProcessor.h"
#import "Rollbar.h"

@implementation RollbarCrashProcessor

- (void)onCrashReportsCollectionCompletion:(NSArray<RollbarCrashReportData *> *)crashReports {
    
    self->_totalProcessedReports += crashReports.count;
    
    for (RollbarCrashReportData *crashRecord in crashReports) {
        [Rollbar logCrashReport:crashRecord.crashReport];
        
        // Let's sleep this thread for a few seconds to give the items processing thread a chance
        // to send the payload logged above so that we can handle cases when the SDK is initialized
        // right/shortly before a persistent application crash (that we have no control over) if any:
        [NSThread sleepForTimeInterval:5.0f]; // [sec]
    }
}

- (instancetype)init {
    
    if ((self = [super init])) {
        
        self->_totalProcessedReports = 0;
    }
    return self;
}

@end
