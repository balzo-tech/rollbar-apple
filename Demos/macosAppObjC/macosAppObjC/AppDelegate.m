//
//  AppDelegate.m
//  macosAppObjC
//
//  Created by Andrey Kornich on 2020-05-21.
//  Copyright © 2020 Andrey Kornich (Wide Spectrum Computing LLC). All rights reserved.
//

#import "AppDelegate.h"

#import "RollbarDeploysDemoClient.h"
#import "RollbarDemoSettings.h"

@import RollbarNotifier;
@import RollbarAUL;
@import RollbarKSCrash;
@import RollbarPLCrashReporter;

__attribute__((noinline)) static void crashIt (void) {
    /* Trigger a crash */
    ((char *)NULL)[1] = 0;
}

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    
    // Insert code here to initialize your application
    [self initRollbar];
    
    NSData *data = [[NSData alloc] init];
    NSError *error;
    NSJSONReadingOptions serializationOptions = (NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves);
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data
                                                            options:serializationOptions
                                                              error:&error];
    if (!payload && error) {
        [Rollbar log:RollbarLevel_Error
               error:error
                data:nil
             context:nil
         ];
    }
    
    @try {
        [self callTroublemaker];
    } @catch (NSException *exception) {
        [Rollbar errorException:exception data:nil context:@"from @try-@catch"];
    } @finally {
        [Rollbar infoMessage:@"Post-trouble notification!"  data:nil context:@"from @try-@finally"];
    }
    
    // now, cause a crash:
    
    [self callTroublemaker];
    @throw NSInternalInconsistencyException;
    //[self performSelector:@selector(die_die)];
    [self performSelector:NSSelectorFromString(@"crashme:") withObject:nil afterDelay:10];
    assert(NO);
    exit(0);
    crashIt();
    
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    
    // Insert code here to tear down your application

    [Rollbar infoMessage:@"The hosting application is terminating..."];
}

- (void)initRollbar {

    // configure Rollbar:
    RollbarConfig *config = [RollbarConfig new];
    config.destination.accessToken = ROLLBAR_DEMO_PAYLOADS_ACCESS_TOKEN;
    config.destination.environment = ROLLBAR_DEMO_ENVIRONMENT;
    //config.developerOptions.suppressSdkInfoLogging = YES;
    config.customData = @{ @"someKey": @"someValue", };
    config.telemetry.enabled = YES;
    config.telemetry.memoryStatsAutocollectionInterval = 0.5;
    config.telemetry.maximumTelemetryData = 30;

    [RollbarAulStoreMonitor.sharedInstance configureRollbarLogger:Rollbar.currentLogger];
    [RollbarAulStoreMonitor.sharedInstance start];

    // optional crash reporter:
    id<RollbarCrashCollector> crashCollector =
      //nil;
      //[[RollbarKSCrashCollector alloc] init];
      [[RollbarPLCrashCollector alloc] init];
    
    // init Rollbar shared instance:
    [Rollbar initWithConfiguration:config crashCollector:crashCollector];
    
    [Rollbar infoMessage:@"Rollbar is up and running! Enjoy your remote error and log monitoring..."];
}

- (void)demonstrateDeployApiUsage {
    
    RollbarDeploysDemoClient * rollbarDeploysIntro = [[RollbarDeploysDemoClient new] init];
    [rollbarDeploysIntro demoDeploymentRegistration];
    [rollbarDeploysIntro demoGetDeploymentDetailsById];
    [rollbarDeploysIntro demoGetDeploymentsPage];
}

- (void)callTroublemaker {
    NSArray *items = @[@"one", @"two", @"three"];
    NSLog(@"Here is the trouble-item: %@", items[10]);
}

@end
