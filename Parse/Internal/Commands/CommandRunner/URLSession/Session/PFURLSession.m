/**
 * Copyright (c) 2015-present, Parse, LLC.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "PFURLSession.h"
#import "PFURLSession_Private.h"

#import <Bolts/BFTaskCompletionSource.h>

#import "BFTask+Private.h"
#import "PFCommandResult.h"
#import "PFMacros.h"
#import "PFAssert.h"
#import "PFURLSessionJSONDataTaskDelegate.h"
#import "PFURLSessionUploadTaskDelegate.h"
#import "PFURLSessionFileDownloadTaskDelegate.h"

typedef void (^PFURLSessionTaskCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error);

@interface PFURLSession () <NSURLSessionDelegate, NSURLSessionTaskDelegate> {
    dispatch_queue_t _sessionTaskQueue;
    NSURLSession *_urlSession;
    NSMutableDictionary *_delegatesDictionary;
    dispatch_queue_t _delegatesAccessQueue;
}

@end

@implementation PFURLSession

///--------------------------------------
#pragma mark - Init
///--------------------------------------

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration
                             delegate:(id<PFURLSessionDelegate>)delegate {
    // NOTE: cast to id suppresses warning about designated initializer.
    return [(id)self initWithURLSession:[NSURLSession sessionWithConfiguration:configuration
                                                                     delegate:self
                                                                delegateQueue:nil]
                               delegate:delegate];
}

- (instancetype)initWithURLSession:(NSURLSession *)session
                          delegate:(id<PFURLSessionDelegate>)delegate {
    self = [super init];
    if (!self) return nil;

    _delegate = delegate;
    _urlSession = session;

    _sessionTaskQueue = dispatch_queue_create("com.parse.urlSession.tasks", DISPATCH_QUEUE_SERIAL);

    _delegatesDictionary = [NSMutableDictionary dictionary];
    _delegatesAccessQueue = dispatch_queue_create("com.parse.urlSession.delegates", DISPATCH_QUEUE_CONCURRENT);

    return self;
}

+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                delegate:(id<PFURLSessionDelegate>)delegate {
    return [[self alloc] initWithConfiguration:configuration delegate:delegate];
}

+ (instancetype)sessionWithURLSession:(nonnull NSURLSession *)session
                             delegate:(id<PFURLSessionDelegate>)delegate {
    return [[self alloc] initWithURLSession:session delegate:delegate];
}

///--------------------------------------
#pragma mark - Teardown
///--------------------------------------

- (void)invalidateAndCancel {
    [_urlSession invalidateAndCancel];
}

///--------------------------------------
#pragma mark - Network Requests
///--------------------------------------

- (BFTask *)performDataURLRequestAsync:(NSURLRequest *)request
                            forCommand:(PFRESTCommand *)command
                     cancellationToken:(BFCancellationToken *)cancellationToken {
    if (cancellationToken.cancellationRequested) {
        return [BFTask cancelledTask];
    }

    @weakify(self);
    return [BFTask taskFromExecutor:[BFExecutor defaultPriorityBackgroundExecutor] withBlock:^id{
        @strongify(self);
        if (cancellationToken.cancellationRequested) {
            return [BFTask cancelledTask];
        }

        __block NSURLSessionDataTask *task = nil;
        dispatch_sync(_sessionTaskQueue, ^{
            task = [_urlSession dataTaskWithRequest:request];
        });
        PFURLSessionDataTaskDelegate *delegate = [PFURLSessionJSONDataTaskDelegate taskDelegateForDataTask:task
                                                                                     withCancellationToken:cancellationToken];
        return [self _performDataTask:task withDelegate:delegate];
    }];
}

- (BFTask *)performFileUploadURLRequestAsync:(NSURLRequest *)request
                                  forCommand:(PFRESTCommand *)command
                   withContentSourceFilePath:(NSString *)sourceFilePath
                           cancellationToken:(BFCancellationToken *)cancellationToken
                               progressBlock:(PFProgressBlock)progressBlock {
    if (cancellationToken.cancellationRequested) {
        return [BFTask cancelledTask];
    }

    @weakify(self);
    return [BFTask taskFromExecutor:[BFExecutor defaultPriorityBackgroundExecutor] withBlock:^id{
        @strongify(self);
        if (cancellationToken.cancellationRequested) {
            return [BFTask cancelledTask];
        }

        __block NSURLSessionDataTask *task = nil;
        dispatch_sync(_sessionTaskQueue, ^{
            task = [_urlSession uploadTaskWithRequest:request fromFile:[NSURL fileURLWithPath:sourceFilePath]];
        });
        PFURLSessionUploadTaskDelegate *delegate = [PFURLSessionUploadTaskDelegate taskDelegateForDataTask:task
                                                                                     withCancellationToken:cancellationToken
                                                                                       uploadProgressBlock:progressBlock];
        return [self _performDataTask:task withDelegate:delegate];
    }];
}

- (BFTask *)performFileDownloadURLRequestAsync:(NSURLRequest *)request
                                  toFileAtPath:(NSString *)filePath
                         withCancellationToken:(nullable BFCancellationToken *)cancellationToken
                                 progressBlock:(nullable PFProgressBlock)progressBlock {
    if (cancellationToken.cancellationRequested) {
        return [BFTask cancelledTask];
    }

    @weakify(self);
    return [BFTask taskFromExecutor:[BFExecutor defaultPriorityBackgroundExecutor] withBlock:^id{
        @strongify(self);
        if (cancellationToken.cancellationRequested) {
            return [BFTask cancelledTask];
        }

        __block NSURLSessionDataTask *task = nil;
        dispatch_sync(_sessionTaskQueue, ^{
            task = [_urlSession dataTaskWithRequest:request];
        });
        PFURLSessionFileDownloadTaskDelegate *delegate = [PFURLSessionFileDownloadTaskDelegate taskDelegateForDataTask:task
                                                                                                 withCancellationToken:cancellationToken
                                                                                                        targetFilePath:filePath
                                                                                                         progressBlock:progressBlock];
        return [self _performDataTask:task withDelegate:delegate];
    }];
}

- (BFTask *)_performDataTask:(NSURLSessionDataTask *)dataTask withDelegate:(PFURLSessionDataTaskDelegate *)delegate {
    [self.delegate urlSession:self willPerformURLRequest:dataTask.originalRequest];

    @weakify(self);
    return [BFTask taskFromExecutor:[BFExecutor defaultExecutor] withBlock:^id{
        @strongify(self);
        NSNumber *taskIdentifier = @(dataTask.taskIdentifier);
        [self setDelegate:delegate forDataTask:dataTask];

        BFTask *resultTask = [delegate.resultTask continueWithBlock:^id(BFTask *task) {
            @strongify(self);
            [self.delegate urlSession:self
                 didPerformURLRequest:dataTask.originalRequest
                      withURLResponse:delegate.response
                       responseString:delegate.responseString];

            [self _removeDelegateForTaskWithIdentifier:taskIdentifier];
            return task;
        }];
        [dataTask resume];

        return resultTask;
    }];
}

///--------------------------------------
#pragma mark - Private
///--------------------------------------

- (PFURLSessionDataTaskDelegate *)_taskDelegateForTask:(NSURLSessionTask *)task {
    __block PFURLSessionDataTaskDelegate *delegate = nil;
    dispatch_sync(_delegatesAccessQueue, ^{
        delegate = _delegatesDictionary[@(task.taskIdentifier)];
    });
    return delegate;
}

- (void)setDelegate:(PFURLSessionDataTaskDelegate *)delegate forDataTask:(NSURLSessionDataTask *)task {
    dispatch_barrier_async(_delegatesAccessQueue, ^{
        _delegatesDictionary[@(task.taskIdentifier)] = delegate;
    });
}

- (void)_removeDelegateForTaskWithIdentifier:(NSNumber *)identifier {
    dispatch_barrier_async(_delegatesAccessQueue, ^{
        [_delegatesDictionary removeObjectForKey:identifier];
    });
}

///--------------------------------------
#pragma mark - Certificate
///--------------------------------------

static NSString *hostedParseCertName = @"HostedParse";
static NSString *parseCertName = @"ParseCom";
static NSString *parseAPI = @"api.parse.com";

- (SecKeyRef)publicKeyForParseDomain:(NSString *)domain {
    NSString *certName = [domain isEqualToString:parseAPI] ? parseCertName : hostedParseCertName;
    //1. Load certificate from main bundle
    NSString *certPath = [[NSBundle mainBundle] pathForResource:certName ofType:@"der"];
    //2. Get the contents of the certificate and load to NSData
    NSData *certData = [NSData dataWithContentsOfFile:certPath];
    //3. Get CFDataRef of the certificate data
    CFDataRef certDataRef = (__bridge CFDataRef)certData;
    //4. Create certificate with the data
    SecCertificateRef certificateRef = SecCertificateCreateWithData(NULL, certDataRef);
    //5. Returns a policy object for the default X.509 policy
    SecPolicyRef policyRef = SecPolicyCreateBasicX509();

    SecTrustRef localTrust = NULL;
    SecTrustResultType localTrustEvaluationResult = kSecTrustResultInvalid;
    SecKeyRef localKey = NULL;

    if(SecTrustCreateWithCertificates((CFTypeRef)certificateRef, policyRef, &localTrust) == noErr) {

        if(SecTrustEvaluate(localTrust, &localTrustEvaluationResult) == noErr &&
           localTrustEvaluationResult != kSecTrustResultInvalid &&
           localTrustEvaluationResult != kSecTrustResultFatalTrustFailure &&
           localTrustEvaluationResult != kSecTrustResultOtherError) {
            //6. Returns the public key for a leaf certificate after it has been evaluated.
            localKey = SecTrustCopyPublicKey(localTrust);
        }

        CFRelease((CFTypeRef)localTrust);
    }

    if(certificateRef) {
        CFRelease((CFTypeRef)certificateRef);
    }
    CFRelease((CFTypeRef)policyRef);
    return localKey;
}

///--------------------------------------
#pragma mark - NSURLSessionDelegate
///--------------------------------------

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust) {

        SecTrustRef serverTrust = challenge.protectionSpace.serverTrust; //not explicitly retained
        SecKeyRef serverKey = SecTrustCopyPublicKey(serverTrust);
        SecKeyRef localKey = [self publicKeyForParseDomain:challenge.protectionSpace.host];

        if([((__bridge id)serverKey) isEqual:((__bridge id)localKey)]) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:serverTrust]);
        } else {
            completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
        }

        if(serverKey) {
            CFRelease((CFTypeRef)serverKey);
        }
        if(localKey) {
            CFRelease((CFTypeRef)localKey);
        }

    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

///--------------------------------------
#pragma mark - NSURLSessionTaskDelegate
///--------------------------------------

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    PFURLSessionDataTaskDelegate *delegate = [self _taskDelegateForTask:task];
    [delegate URLSession:session
                    task:task
         didSendBodyData:bytesSent
          totalBytesSent:totalBytesSent
totalBytesExpectedToSend:totalBytesExpectedToSend];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    PFURLSessionDataTaskDelegate *delegate = [self _taskDelegateForTask:task];
    [delegate URLSession:session task:task didCompleteWithError:error];
}

///--------------------------------------
#pragma mark - NSURLSessionDataDelegate
///--------------------------------------

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    PFURLSessionDataTaskDelegate *delegate = [self _taskDelegateForTask:dataTask];
    [delegate URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    PFURLSessionDataTaskDelegate *delegate = [self _taskDelegateForTask:dataTask];
    [delegate URLSession:session dataTask:dataTask didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {
    completionHandler(nil); // Prevent any caching for security reasons
}

@end
