#import <UIKit/UIKit.h>
#import "LSVersion.h"
#import "LSTracer.h"
#import "LSSpan.h"
#import "LSUtil.h"
#import "LSClockState.h"
#import "TBinaryProtocol.h"
#import "THTTPClient.h"
#import "TSocketClient.h"
#import "TTransportException.h"

NSString* const OTFormatTextMap = @"text_map";
NSString* const OTFormatBinary = @"binary";

NSString *const OTErrorDomain = @"opentracing.io";
NSInteger OTUnsupportedFormatCode = 1;
NSInteger OTInvalidCarrierCode = 2;
NSInteger OTTraceCorruptedCode = 3;

NSString* const LSDefaultHostport = @"collector.lightstep.com:443";

static const int kDefaultFlushIntervalSeconds = 30;
static const NSUInteger kDefaultMaxBufferedSpans = 5000;
static const NSUInteger kDefaultMaxBufferedLogs = 10000;
static const NSUInteger kDefaultMaxPayloadJSONLength = 32 * 1024;

static LSTracer* s_sharedInstance = nil;
static float kFirstRefreshDelay = 0;

@implementation LSTracer {
    NSDate* m_startTime;
    NSString* m_accessToken;
    NSString* m_runtimeGuid;
    RLRuntime* m_runtimeInfo;
    LSClockState* m_clockState;

    NSString* m_serviceUrl;
    RLReportingServiceClient* m_serviceStub;
    bool m_enabled;
    float m_refreshStubDelaySecs;  // if kFirstRefreshDelay, we've never tried to refresh.
    NSMutableArray* m_pendingSpanRecords;
    NSMutableArray* m_pendingLogRecords;
    dispatch_queue_t m_queue;
    dispatch_source_t m_flushTimer;

    UIBackgroundTaskIdentifier m_bgTaskId;
}

@synthesize flushIntervalSeconds = m_flushIntervalSeconds;
@synthesize maxLogRecords = m_maxLogRecords;
@synthesize maxSpanRecords = m_maxSpanRecords;
@synthesize maxPayloadJSONLength = m_maxPayloadJSONLength;

- (instancetype) initWithAccessToken:(NSString*)accessToken
                       componentName:(NSString*)componentName
                            hostport:(NSString*)hostport {

    if (self = [super init]) {
        self->m_serviceUrl = [NSString stringWithFormat:@"https://%@/_rpc/v1/reports/binary", hostport];
        self->m_accessToken = accessToken;
        self->m_runtimeGuid = [LSUtil hexGUID:[LSUtil generateGUID]];
        self->m_startTime = [NSDate date];
        NSMutableArray* runtimeAttrs = @[[[RLKeyValue alloc] initWithKey:@"lightstep_tracer_platform" Value:@"ios"],
                                         [[RLKeyValue alloc] initWithKey:@"lightstep_tracer_version" Value:LS_TRACER_VERSION],
                                         [[RLKeyValue alloc] initWithKey:@"component_name" Value:componentName],
                                         [[RLKeyValue alloc] initWithKey:@"component_guid" Value:self->m_runtimeGuid],
                                         [[RLKeyValue alloc] initWithKey:@"ios_version" Value:[[UIDevice currentDevice] systemVersion]],
                                         [[RLKeyValue alloc] initWithKey:@"device_model" Value:[[UIDevice currentDevice] model]]].mutableCopy;
        self->m_runtimeInfo = [[RLRuntime alloc]
                               initWithGuid:self->m_runtimeGuid
                               start_micros:[m_startTime toMicros]
                               group_name:componentName
                               attrs:runtimeAttrs];

        self->m_maxLogRecords = kDefaultMaxBufferedLogs;
        self->m_maxSpanRecords = kDefaultMaxBufferedSpans;
        self->m_maxPayloadJSONLength = kDefaultMaxPayloadJSONLength;
        self->m_flushIntervalSeconds = kDefaultFlushIntervalSeconds;
        self->m_pendingSpanRecords = [NSMutableArray array];
        self->m_pendingLogRecords = [NSMutableArray array];
        self->m_queue = dispatch_queue_create("com.resonancelabs.signal.rpc", DISPATCH_QUEUE_SERIAL);
        self->m_flushTimer = nil;
        self->m_refreshStubDelaySecs = kFirstRefreshDelay;
        self->m_enabled = true;  // if false, no longer collect tracing data
        self->m_clockState = [[LSClockState alloc] initWithLSTracer:self];
        self->m_bgTaskId = UIBackgroundTaskInvalid;
        [self _refreshStub];
    }
    return self;
}

+ (instancetype) initSharedTracer:(NSString*)accessToken
                    componentName:(NSString*)componentName
                         hostport:(NSString*)hostport {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_sharedInstance = [[super alloc] initWithAccessToken:accessToken componentName:componentName hostport:hostport];
    });
    return s_sharedInstance;
}

+ (instancetype) initSharedTracer:(NSString*)accessToken
                    componentName:(NSString*)componentName {
    return [LSTracer initSharedTracer:accessToken componentName:componentName hostport:LSDefaultHostport];
}

+ (instancetype) initSharedTracer:(NSString*)accessToken {
    NSString* bundleName = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleNameKey];
    return [LSTracer initSharedTracer:accessToken componentName:bundleName];
}

+ (LSTracer*) sharedTracer {
    if (s_sharedInstance == nil) {
        NSLog(@"Must call initSharedTracer before calling sharedTracer!");
    }
    return s_sharedInstance;
}

- (LSSpan*)startSpan:(NSString*)operationName {
    return [self startSpan:operationName parent:nil tags:nil startTime:[NSDate date]];
}

- (LSSpan*)startSpan:(NSString*)operationName
                tags:(NSDictionary*)tags {
    return [self startSpan:operationName parent:nil tags:tags startTime:[NSDate date]];
}

- (LSSpan*)startSpan:(NSString*)operationName
              parent:(LSSpan*)parentSpan {
    return [self startSpan:operationName parent:parentSpan tags:nil  startTime:[NSDate date]];
}

- (LSSpan*)startSpan:(NSString*)operationName
              parent:(LSSpan*)parentSpan
                tags:(NSDictionary*)tags {
    return [self startSpan:operationName parent:parentSpan tags:tags startTime:[NSDate date]];
}

- (LSSpan*)startSpan:(NSString*)operationName
              parent:(LSSpan*)parentSpan
                tags:(NSDictionary*)tags
           startTime:(NSDate*)startTime {
    // No locking required
    return [[LSSpan alloc] initWithTracer:self
                            operationName:operationName
                                   parent:parentSpan
                                     tags:tags
                                startTime:startTime];
}

- (bool)inject:(LSSpan*)span format:(NSString*)format carrier:(id)carrier {
    return [self inject:span format:format carrier:carrier error:nil];
}

// These strings are used for TextMap inject and join.
static NSString* kBasicTracerStatePrefix   = @"ot-tracer-";
static NSString* kTraceIdKey               = @"ot-tracer-traceid";
static NSString* kSpanIdKey                = @"ot-tracer-spanid";
static NSString* kSampledKey               = @"ot-tracer-sampled";
static NSString* kBasicTracerBaggagePrefix = @"ot-baggage-";

- (bool)inject:(LSSpan*)span format:(NSString*)format carrier:(id)carrier error:(NSError* __autoreleasing *)outError {
    if ([format isEqualToString:OTFormatTextMap]) {
        NSMutableDictionary *dict = carrier;
        [dict setObject:span.hexTraceId forKey:kTraceIdKey];
        [dict setObject:span.hexSpanId forKey:kSpanIdKey];
        [dict setObject:@"true" forKey:kSampledKey];
        for (NSString* key in span.tags) {
            [dict setObject:[span.tags objectForKey:key] forKey:[kBasicTracerBaggagePrefix stringByAppendingString:key]];
        }
        return true;
    } else if ([format isEqualToString:OTFormatBinary]) {
        if (outError != nil) {
            *outError = [NSError errorWithDomain:OTErrorDomain code:OTUnsupportedFormatCode userInfo:nil];
        }
        return false;
    } else {
        if (outError != nil) {
            *outError = [NSError errorWithDomain:OTErrorDomain code:OTUnsupportedFormatCode userInfo:nil];
        }
        return false;
    }
}

- (LSSpan*)join:(NSString*)operationName format:(NSString*)format carrier:(id)carrier {
    return [self join:operationName format:format carrier:carrier error:nil];
}

- (LSSpan*)join:(NSString*)operationName format:(NSString*)format carrier:(id)carrier error:(NSError* __autoreleasing *)outError {
    if ([format isEqualToString:OTFormatTextMap]) {
        NSMutableDictionary *dict = carrier;
        NSMutableDictionary *baggage;
        int foundRequiredFields = 0;
        UInt64 traceId = 0;
        UInt64 spanId = 0;
        for (NSString* key in dict) {
            if ([key hasPrefix:kBasicTracerBaggagePrefix]) {
                [baggage setObject:[dict objectForKey:key] forKey:[key substringFromIndex:kBasicTracerBaggagePrefix.length]];
            } else if ([key hasPrefix:kBasicTracerStatePrefix]) {
                if ([key isEqualToString:kTraceIdKey]) {
                    foundRequiredFields++;
                    traceId = [LSUtil guidFromHex:[dict objectForKey:key]];
                    if (traceId == 0) {
                        if (outError != nil) {
                            *outError = [NSError errorWithDomain:OTErrorDomain code:OTTraceCorruptedCode userInfo:nil];
                        }
                        return nil;
                    }
                } else if ([key isEqualToString:kSpanIdKey]) {
                    foundRequiredFields++;
                    spanId = [LSUtil guidFromHex:[dict objectForKey:key]];
                    if (spanId == 0) {
                        if (outError != nil) {
                            *outError = [NSError errorWithDomain:OTErrorDomain code:OTTraceCorruptedCode userInfo:nil];
                        }
                        return nil;
                    }
                } else if ([key isEqualToString:kSampledKey]) {
                    // TODO: care about sampled status at this layer
                }
            }
        }
        if (foundRequiredFields == 0) {
            // (no error per se, just didn't find a trace to join)
            return nil;
        }
        if (foundRequiredFields < 2) {
            if (outError != nil) {
                *outError = [NSError errorWithDomain:OTErrorDomain code:OTTraceCorruptedCode userInfo:nil];
            }
            return nil;
        }

        return [[LSSpan alloc] initWithTracer:self
                                operationName:operationName
                                      traceId:traceId
                                     parentId:spanId
                                         tags:nil
                                    startTime:[NSDate date]];
        return nil;
    } else if ([format isEqualToString:OTFormatBinary]) {
        if (outError != nil) {
            *outError = [NSError errorWithDomain:OTErrorDomain code:OTUnsupportedFormatCode userInfo:nil];
        }
        return nil;
    } else {
        if (outError != nil) {
            *outError = [NSError errorWithDomain:OTErrorDomain code:OTUnsupportedFormatCode userInfo:nil];
        }
        return nil;
    }
}

- (NSString*) serviceUrl {
    @synchronized(self) {
        return m_serviceUrl;
    }
}

- (NSString*) accessToken {
    @synchronized(self) {
        return m_accessToken;
    }
}

- (NSString*) runtimeGuid {
    // Immutable after init; no locking required
    return m_runtimeGuid;
}

- (NSUInteger) maxLogRecords {
    @synchronized(self) {
        return m_maxLogRecords;
    }
}

- (void) setMaxLogRecords:(NSUInteger)capacity {
    @synchronized(self) {
        m_maxLogRecords = capacity;
    }
}

- (NSUInteger) maxSpanRecords {
    @synchronized(self) {
        return m_maxSpanRecords;
    }
}

- (void) setMaxSpanRecords:(NSUInteger)capacity {
    @synchronized(self) {
        m_maxSpanRecords = capacity;
    }
}


- (bool) enabled {
    @synchronized(self) {
        return m_enabled;
    }
}

- (void) _appendSpanRecord:(RLSpanRecord*)sr {
    @synchronized(self) {
        if (!m_enabled) {
            return;
        }

        if (m_pendingSpanRecords.count < m_maxSpanRecords) {
            [m_pendingSpanRecords addObject:sr];
        }
    }
}

- (void) _appendLogRecord:(RLLogRecord*)lr {
    @synchronized(self) {
        if (!m_enabled) {
            return;
        }

        if (m_pendingLogRecords.count < m_maxLogRecords) {
            [m_pendingLogRecords addObject:lr];
        }
    }
}

// _refreshStub invokes _refreshImp in an asynchronous thread
- (void) _refreshStub {
    @synchronized(self) {
        if (!m_enabled) {
            // Noop.
            return;
        }
        if (m_serviceUrl == nil || m_serviceUrl.length == 0) {
            // Better safe than sorry (we don't think this should ever actually happen).
            NSLog(@"No service URL provided");
            return;
        }
        __weak __typeof__(self) weakSelf = self;
        dispatch_async(m_queue, ^{
            [weakSelf _refreshImp];
        });
    }
}

// Note: this method is intended to be invoked only by _refreshStub and off the
// main thread (i.e. there are sleep calls in this method).
//
- (void) _refreshImp {
    @synchronized(self) {
        if (m_flushTimer) {
            dispatch_source_cancel(m_flushTimer);
            m_flushTimer = 0;
        }

        // Don't actually sleep the first time we try to initiate m_serviceStub.
        if (m_refreshStubDelaySecs != kFirstRefreshDelay) {
            // Exponential backoff with a 5-minute max.
            m_refreshStubDelaySecs = MIN(60*5, m_refreshStubDelaySecs * 1.5);
            NSLog(@"LSTracer backing off for %@ seconds", @(m_refreshStubDelaySecs));
            [NSThread sleepForTimeInterval:m_refreshStubDelaySecs];
        }

        NSObject<TTransport>* transport = [[THTTPClient alloc] initWithURL:[NSURL URLWithString:m_serviceUrl] userAgent:nil timeout:10];
        TBinaryProtocol* protocol = [[TBinaryProtocol alloc] initWithTransport:transport strictRead:YES strictWrite:YES];
        m_serviceStub = [[RLReportingServiceClient alloc] initWithProtocol:protocol];
        if (!m_serviceStub) {
            return;
        }

        // Restart the backoff.
        m_refreshStubDelaySecs = 5;

        // Initialize and "resume" (i.e., "start") the m_flushTimer.
        m_flushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, m_queue);
        if (!m_flushTimer) {
            return;
        }

        dispatch_source_set_timer(m_flushTimer, DISPATCH_TIME_NOW, self->m_flushIntervalSeconds * NSEC_PER_SEC, NSEC_PER_SEC);
        __weak __typeof__(self) weakSelf = self;
        dispatch_source_set_event_handler(m_flushTimer, ^{
            [weakSelf flush];
        });
        dispatch_resume(m_flushTimer);
    }
}

- (void) flush {
    __weak __typeof__(self) weakSelf = self;
    @synchronized(self) {
        micros_t tsCorrection = m_clockState.offsetMicros;

        // TODO: there is not currently a good way to report this diagnostic
        // information
        /*if (tsCorrection != 0) {
            [self logEvent:@"cr/time_correction_state" payload:@{@"offset_micros": @(tsCorrection)}];
        }*/

        NSMutableArray* spansToFlush = m_pendingSpanRecords;
        NSMutableArray* logsToFlush = m_pendingLogRecords;
        m_pendingSpanRecords = [NSMutableArray array];
        m_pendingLogRecords = [NSMutableArray array];

        if (!m_enabled) {
            // Deliberately do this after clearing the pending records (just in case).
            return;
        }
        if (spansToFlush.count + logsToFlush.count == 0) {
            // Nothing to do.
            return;
        }
        if (m_bgTaskId != UIBackgroundTaskInvalid) {
            // Do not proceed if we are already flush()ing in the background.
            return;
        }

        // We really want this flush to go through, even if the app enters the
        // background and iOS wants to move on with its life.
        //
        // NOTES ABOUT THE BACKGROUND TASK: we store m_bgTaskId is a member, which
        // means that it's important we don't call this function recursively (and
        // thus overwrite/lose the background task id). There is a recursive-"ish"
        // aspect to this function, as rpcBlock calls _refreshStub on error which
        // enqueues a call to flushToService on m_queue. m_queue is serialized,
        // though, so we are guaranteed that only one flushToService call will be
        // extant at any given moment, and thus it's safe to store the background
        // task id in m_bgTaskId.
        void (^revertBlock)() = ^{
            [weakSelf _revertRecords:spansToFlush logs:logsToFlush];
        };
        m_bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"reslabs_flush"
                                                                  expirationHandler:revertBlock];
        if (m_bgTaskId == UIBackgroundTaskInvalid) {
            NSLog(@"unable to enter the background, so skipping flush");
            revertBlock();
            return;
        }

        RLAuth* auth = [[RLAuth alloc] initWithAccess_token:m_accessToken];
        RLReportRequest* req = [[RLReportRequest alloc]
                                initWithRuntime:m_runtimeInfo
                                span_records:spansToFlush
                                log_records:logsToFlush
                                timestamp_offset_micros:tsCorrection
                                oldest_micros:0
                                youngest_micros:0
                                counters:nil];

        dispatch_async(m_queue, ^{
            [weakSelf _flushReport:auth request:req];
        });
    }
}

// Called by flush() on a failed report.
// Note: do not call directly from outside flush().
- (void) _revertRecords:(NSArray*)spans
                   logs:(NSArray*)logs
{
    @synchronized(self) {
        // We apparently failed to flush these records, so re-enqueue them
        // at the heads of m_pending*Records. This is a little sketchy
        // since we don't actually *know* if the peer service saw them or
        // not, but this is the more conservative path as far as data loss
        // is concerned.
        [m_pendingSpanRecords insertObjects:spans
                                  atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, spans.count)]];
        [m_pendingLogRecords insertObjects:logs
                                 atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, logs.count)]];

        if (m_bgTaskId != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:m_bgTaskId];
            m_bgTaskId = UIBackgroundTaskInvalid;
        }
    }
}

// Note: do not call directly from outside flush()
- (void) _flushReport:(RLAuth*) auth request:(RLReportRequest*)req {
    // On any exception, start from scratch with _refreshStub. Don't
    // call revertBlock() to avoid a client feedback loop if the data
    // itself caused the exception.
    RLReportResponse* response = nil;
    @try {

        // The RPC is blocking. Do not include it in a locked section.
        micros_t originMicros = [LSClockState nowMicros];
        response = [m_serviceStub Report:auth request:req];
        micros_t destinationMicros = [LSClockState nowMicros];

        // Process the response info
        for (RLCommand* command in response.commands) {
            if (command.disable) {
                NSLog(@"NOTE: Signal LSTracer disabled by remote peer.");
                @synchronized(self) {
                    m_enabled = false;
                }
            }
        }
        if (response.timing.receive_microsIsSet && response.timing.transmit_microsIsSet) {
            // Update our local NTP-lite clock state with the latest measurements.
            @synchronized(self) {
                [m_clockState addSampleWithOriginMicros:originMicros
                                          receiveMicros:response.timing.receive_micros
                                         transmitMicros:response.timing.transmit_micros
                                      destinationMicros:destinationMicros];
            }
        }
    }
    @catch (TApplicationException* e)
    {
        NSLog(@"Thrift RPC exception %@: %@", [e name], [e description]);
        [self _refreshStub];
    }
    @catch (TException* e)
    {
        // TTransportException, or unknown type of exception: drop data since "first, [we want to] do no harm."
        NSLog(@"Unknown Thrift error %@: %@", [e name], [e description]);
        [self _refreshStub];
    }
    @catch (NSException* e)
    {
        // We really don't like catching NSException, but unfortunately
        // Thrift is sufficiently flaky that we will sleep better here
        // if we do.
        NSLog(@"Unexpected exception %@: %@", [e name], [e description]);
        [self _refreshStub];
    }

    @synchronized(self) {
        // We can safely end the background task at this point.
        [[UIApplication sharedApplication] endBackgroundTask:m_bgTaskId];
        m_bgTaskId = UIBackgroundTaskInvalid;
    }
}

@end