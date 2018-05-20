//
//  TIPImageDownloadInternalContext.m
//  TwitterImagePipeline
//
//  Created on 10/14/15.
//  Copyright © 2015 Twitter. All rights reserved.
//

#import "TIP_Project.h"
#import "TIPError.h"
#import "TIPGlobalConfiguration+Project.h"
#import "TIPImageDownloadInternalContext.h"
#import "TIPTiming.h"

NS_ASSUME_NONNULL_BEGIN

@implementation TIPImageDownloadInternalContext
{
    NSMutableArray<id<TIPImageDownloadDelegate>> *_delegates;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _delegates = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)delegateCount
{
    return _delegates.count;
}

- (nullable TIPImageFetchOperation *)associatedImageFetchOperation
{
    for (id<TIPImageDownloadDelegate> delegate in _delegates) {
        if ([delegate isKindOfClass:[TIPImageFetchOperation class]]) {
            return (id)delegate;
        }
    }
    return nil;
}

- (nullable id<TIPImageDownloadDelegate>)firstDelegate
{
    return _delegates.firstObject;
}

- (NSOperationQueuePriority)downloadPriority
{
    NSOperationQueuePriority pri = NSOperationQueuePriorityVeryLow;
    for (id<TIPImageDownloadDelegate> delegate in _delegates) {
        const NSOperationQueuePriority delegatePriority = delegate.imageDownloadRequest.imageDownloadPriority;
        pri = MAX(pri, delegatePriority);
    }
    return pri;
}

- (BOOL)containsDelegate:(id<TIPImageDownloadDelegate>)delegate
{
    return [_delegates containsObject:delegate];
}

- (void)addDelegate:(id<TIPImageDownloadDelegate>)delegate
{
    [_delegates addObject:delegate];
}

- (void)removeDelegate:(id<TIPImageDownloadDelegate>)delegate
{
    NSUInteger count = _delegates.count;
    [_delegates removeObject:delegate];
    if (count > _delegates.count) {
        id<TIPImageFetchDownload> download = self.download;
        [TIPImageDownloadInternalContext executeDelegate:delegate suspendingQueue:NULL block:^(id<TIPImageDownloadDelegate> blockDelegate) {
            [blockDelegate imageDownload:(id)download didCompleteWithPartialImage:nil lastModified:nil byteSize:0 imageType:nil image:nil imageRenderLatency:0.0 statusCode:0 error:[NSError errorWithDomain:TIPImageFetchErrorDomain code:TIPImageFetchErrorCodeCancelled userInfo:nil]];
        }];
    }
}

- (void)executePerDelegateSuspendingQueue:(nullable dispatch_queue_t)queue
                                    block:(void(^)(id<TIPImageDownloadDelegate>))block;
{
    for (id<TIPImageDownloadDelegate> delegate in _delegates) {
        [TIPImageDownloadInternalContext executeDelegate:delegate
                                         suspendingQueue:queue block:block];
    }
}

+ (void)executeDelegate:(id<TIPImageDownloadDelegate>)delegate
        suspendingQueue:(nullable dispatch_queue_t)queue
                  block:(void (^)(id<TIPImageDownloadDelegate>))block;
{
    dispatch_queue_t delegateQueue = [delegate respondsToSelector:@selector(imageDownloadDelegateQueue)] ? delegate.imageDownloadDelegateQueue : NULL;
    if (delegateQueue) {
        if (queue) {
            dispatch_suspend(queue);
        }
        dispatch_async(delegateQueue, ^{
            block(delegate);
            if (queue) {
                dispatch_resume(queue);
            }
        });
    } else {
        block(delegate);
    }
}

@end

NS_ASSUME_NONNULL_END
