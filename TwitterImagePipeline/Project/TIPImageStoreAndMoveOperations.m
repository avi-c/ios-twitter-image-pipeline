//
//  TIPImageStoreAndMoveOperations.m
//  TwitterImagePipeline
//
//  Created on 1/13/16.
//  Copyright © 2016 Twitter. All rights reserved.
//

#include <stdatomic.h>

#import "TIP_Project.h"
#import "TIPError.h"
#import "TIPGlobalConfiguration+Project.h"
#import "TIPImageDiskCache.h"
#import "TIPImageFetchRequest.h"
#import "TIPImageMemoryCache.h"
#import "TIPImagePipeline+Project.h"
#import "TIPImageRenderedCache.h"
#import "TIPImageStoreAndMoveOperations.h"
#import "UIImage+TIPAdditions.h"

// Static asserts to ensure the Fetch/Store options are 1:1 matching

TIPStaticAssert(TIPImageFetchNoOptions == TIPImageStoreNoOptions, NoOptionsMissmatch);
TIPStaticAssert(TIPImageFetchDoNotResetExpiryOnAccess == TIPImageStoreDoNotResetExpiryOnAccess, DoNotResetExpiryOnAccessMissmatch);
TIPStaticAssert(TIPImageFetchTreatAsPlaceholder == TIPImageStoreTreatAsPlaceholder, TreatAsPlaceholderMissmatch);

NS_ASSUME_NONNULL_BEGIN

@interface TIPImageStoreOperation ()
@property (nonatomic, readonly) id<TIPImageStoreRequest> request;
@property (nonatomic, readonly) TIPImagePipeline *pipeline;
@property (nonatomic, copy, readonly, nullable) TIPImagePipelineOperationCompletionBlock storeCompletionBlock;
@end

@interface TIPImageStoreOperation (Private)
static NSData * __nullable _getImageData(PRIVATE_SELF(TIPImageStoreOperation));
static NSString * __nullable _getImageFilePath(PRIVATE_SELF(TIPImageStoreOperation));
static NSDictionary<NSString *, id> * __nullable _getDecoderConfigMap(PRIVATE_SELF(TIPImageStoreOperation));
static TIPImageContainer * __nullable _getImageContainer(PRIVATE_SELF(TIPImageStoreOperation));
static TIPCompleteImageEntryContext *_getEntryContext(PRIVATE_SELF(TIPImageStoreOperation),
                                                      NSURL *imageURL,
                                                      TIPImageContainer * __nullable imageContainer);
static void _asyncStoreMemoryEntry(PRIVATE_SELF(TIPImageStoreOperation),
                                   TIPImageCacheEntry *memoryEntry,
                                   void(^complete)(BOOL));
@end

@implementation TIPDisabledExternalMutabilityOperation

- (void)_tip_addDependency:(NSOperation *)op
{
    [super addDependency:op];
}

- (void)makeDependencyOfTargetOperation:(NSOperation *)op
{
    [op addDependency:self];
}

- (void)cancel
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)addDependency:(NSOperation *)op
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)removeDependency:(NSOperation *)op
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setQueuePriority:(NSOperationQueuePriority)queuePriority
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setCompletionBlock:(nullable void (^)(void))completionBlock
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setThreadPriority:(double)threadPriority
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setQualityOfService:(NSQualityOfService)qualityOfService
{
    [super doesNotRecognizeSelector:_cmd];
}

@end

@implementation TIPImageStoreOperation
{
    TIPImageStoreHydrationOperation *_hydrationOperation;
}

- (instancetype)initWithRequest:(id<TIPImageStoreRequest>)request
                       pipeline:(TIPImagePipeline *)pipeline
                     completion:(nullable TIPImagePipelineOperationCompletionBlock)completion
{
    if (self = [super init]) {
        _request = request;
        _pipeline = pipeline;
        _storeCompletionBlock = [completion copy];
    }
    return self;
}

- (void)setHydrationDependency:(TIPImageStoreHydrationOperation *)dependency
{
    if (_hydrationOperation) {
        return;
    }

    _hydrationOperation = dependency;
    [super _tip_addDependency:dependency];
}

- (void)main
{
    @autoreleasepool {
        void (^completion)(TIPImageCacheEntry * __nullable, NSError * __nullable);
        completion = ^(TIPImageCacheEntry * __nullable completedEntry,
                       NSError * __nullable completedError) {
            TIPAssert((completedEntry != nil) ^ (completedError != nil));

            if (completedEntry) {
                [self.pipeline postCompletedEntry:completedEntry manual:YES];
            }

            TIPImagePipelineOperationCompletionBlock block = self.storeCompletionBlock;
            if (block) {
                const BOOL success = completedEntry != nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    block(self, success, completedError);
                });
            }
        };

        // Check hydration
        if (_hydrationOperation) {
            NSError *hydrationError = _hydrationOperation.error;
            if (hydrationError) {
                completion(nil, hydrationError);
                return;
            } else if (_hydrationOperation.hydratedRequest) {
                _request = _hydrationOperation.hydratedRequest;
            }
        }

        // Confirm Caches
        if (!_pipeline.diskCache && !_pipeline.memoryCache) {
            completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain
                                                code:TIPImageStoreErrorCodeNoCacheForStoring
                                            userInfo:nil]);
            return;
        }

        // Pull out image info
        NSData *imageData = _getImageData(self);
        NSString *imageFilePath = _getImageFilePath(self);
        TIPImageContainer *imageContainer = _getImageContainer(self);

        // Validate image info
        TIPAssertMessage(imageContainer != nil || imageData != nil || imageFilePath != nil, @"%@ didn't have any image info", NSStringFromClass([_request class]));
        if (!imageContainer && !imageData && !imageFilePath) {
            completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain
                                                code:TIPImageStoreErrorCodeImageNotProvided
                                            userInfo:nil]);
            return;
        }

        // Pull out and validate URL
        NSURL *imageURL = _request.imageURL;
        TIPAssert(imageURL != nil);
        if (!imageURL) {
            completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain
                                                code:TIPImageStoreErrorCodeImageURLNotProvided
                                            userInfo:nil]);
            return;
        }

        // Pull out the identifier
        NSString *identifier = TIPImageStoreRequestGetImageIdentifier(_request);

        // Create context
        TIPCompleteImageEntryContext *context = _getEntryContext(self, imageURL, imageContainer);

        // Create Memory Entry
        TIPImageCacheEntry *memoryEntry = nil;
        if (_pipeline.memoryCache) {
            memoryEntry = [[TIPImageCacheEntry alloc] init];
            if (imageContainer) {
                memoryEntry.completeImage = imageContainer;
                TIPAssert(memoryEntry.completeImage);
            } else if (imageData) {
                memoryEntry.completeImageData = imageData;
            } else {
                TIPAssert(imageFilePath);
                memoryEntry.completeImageFilePath = imageFilePath;
            }
        }

        // Create Disk Entry
        TIPImageCacheEntry *diskEntry = nil;
        if (_pipeline.diskCache) {
            diskEntry = [[TIPImageCacheEntry alloc] init];
            if (imageFilePath && ([[NSFileManager defaultManager] fileExistsAtPath:imageFilePath] || (!imageData && !imageContainer))) {
                diskEntry.completeImageFilePath = imageFilePath;
            } else if (imageData) {
                diskEntry.completeImageData = imageData;
            } else {
                TIPAssert(imageContainer);
                diskEntry.completeImage = imageContainer;
                TIPAssert(diskEntry.completeImage);
            }
        }

        // Finish hydrating entries
        if (memoryEntry) {
            memoryEntry.completeImageContext = [context copy];
            memoryEntry.identifier = identifier;
        }
        if (diskEntry) {
            diskEntry.completeImageContext = [context copy];
            diskEntry.identifier = identifier;
        }

        // Update caches
        [_pipeline.renderedCache clearImagesWithIdentifier:identifier];

        if (diskEntry) {
            [_pipeline.diskCache updateImageEntry:diskEntry
                          forciblyReplaceExisting:!context.treatAsPlaceholder];
        }

        if (memoryEntry) {
            if (memoryEntry.completeImage != nil) {
                [_pipeline.memoryCache updateImageEntry:memoryEntry
                                forciblyReplaceExisting:!context.treatAsPlaceholder];
            } else {
                if (diskEntry) {
                    // clear memory cache first, in case actual store fails we'll want to fall back to the disk cache for loading
                    [_pipeline.memoryCache clearImageWithIdentifier:identifier];
                }
                _asyncStoreMemoryEntry(self, memoryEntry, ^(BOOL success) {
                    if (success) {
                        completion(memoryEntry, nil);
                    } else if (diskEntry) {
                        completion(diskEntry, nil);
                    } else {
                        completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain
                                                            code:TIPImageStoreErrorCodeStorageFailed
                                                        userInfo:nil]);
                    }
                });
                return; // async completion
            }
        }

        completion(memoryEntry ?: diskEntry, nil);
    }
}

@end

@implementation TIPImageStoreOperation (Private)

static NSData * __nullable _getImageData(PRIVATE_SELF(TIPImageStoreOperation))
{
    if (!self) {
        return nil;
    }
    return [self->_request respondsToSelector:@selector(imageData)] ? self->_request.imageData : nil;
}

static NSString * __nullable _getImageFilePath(PRIVATE_SELF(TIPImageStoreOperation))
{
    if (!self) {
        return nil;
    }
    return [self->_request respondsToSelector:@selector(imageFilePath)] ? self->_request.imageFilePath : nil;
}

static NSDictionary<NSString *, id> * __nullable _getDecoderConfigMap(PRIVATE_SELF(TIPImageStoreOperation))
{
    if (!self) {
        return nil;
    }
    return [self->_request respondsToSelector:@selector(decoderConfigMap)] ? self->_request.decoderConfigMap : nil;
}

static TIPImageContainer * __nullable _getImageContainer(PRIVATE_SELF(TIPImageStoreOperation))
{
    if (!self) {
        return nil;
    }

    TIPImageContainer *imageContainer = nil;
    if ([self->_request respondsToSelector:@selector(image)]) {
        UIImage *image = self->_request.image;
        if (image.CIImage) {
            image = [image tip_CGImageBackedImageAndReturnError:NULL];
        }

        if (image) {
            if (image.images.count > 0) {
                NSUInteger loopCount = [self->_request respondsToSelector:@selector(animationLoopCount)] ? self->_request.animationLoopCount : 0;
                NSArray<NSNumber *> *durations = [self->_request respondsToSelector:@selector(animationFrameDurations)] ? self->_request.animationFrameDurations : nil;
                imageContainer = [[TIPImageContainer alloc] initWithAnimatedImage:image
                                                                        loopCount:loopCount
                                                                   frameDurations:durations];
            } else {
                imageContainer = [[TIPImageContainer alloc] initWithImage:image];
            }
            TIPAssert(imageContainer != nil);
        }
    }
    return imageContainer;
}

static TIPCompleteImageEntryContext *_getEntryContext(PRIVATE_SELF(TIPImageStoreOperation),
                                                      NSURL *imageURL,
                                                      TIPImageContainer * __nullable imageContainer)
{
    TIPAssert(self);
    if (!self) {
        return nil;
    }

    TIPCompleteImageEntryContext *context = [[TIPCompleteImageEntryContext alloc] init];
    const TIPImageStoreOptions options = [self->_request respondsToSelector:@selector(options)] ?
                                                [self->_request options] :
                                                TIPImageStoreNoOptions;
    context.updateExpiryOnAccess = TIP_BITMASK_EXCLUDES_FLAGS(options, TIPImageStoreDoNotResetExpiryOnAccess);
    context.treatAsPlaceholder = TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPImageStoreTreatAsPlaceholder);
    context.TTL = [self->_request respondsToSelector:@selector(timeToLive)] ?
                        [self->_request timeToLive] :
                        -1.0;
    if (context.TTL <= 0.0) {
        context.TTL = TIPTimeToLiveDefault;
    }
    context.URL = imageURL;
    if (imageContainer) {
        context.dimensions = imageContainer.dimensions;
    } else if ([self->_request respondsToSelector:@selector(imageDimensions)]) {
        context.dimensions = self->_request.imageDimensions;
    }
    if ([self->_request respondsToSelector:@selector(imageType)]) {
        context.imageType = [self->_request imageType];
    }
    if (imageContainer) {
        context.animated = imageContainer.isAnimated;
    } else {
        if ([context.imageType isEqualToString:TIPImageTypeGIF]) {
            context.animated = YES;
        }
    }
    return context;
}

static void _asyncStoreMemoryEntry(PRIVATE_SELF(TIPImageStoreOperation),
                                   TIPImageCacheEntry *memoryEntry,
                                   void(^complete)(BOOL))
{
    if (!self) {
        return;
    }

    TIPImageMemoryCache *memoryCache = self.pipeline.memoryCache;
    NSDictionary<NSString *, id> *decoderConfigMap = _getDecoderConfigMap(self);
    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        TIPImageContainer *container = nil;
        if (memoryEntry.completeImageData) {
            container = [TIPImageContainer imageContainerWithData:memoryEntry.completeImageData
                                                 decoderConfigMap:decoderConfigMap
                                                   codecCatalogue:nil];
        } else if (memoryEntry.completeImageFilePath) {
            container = [TIPImageContainer imageContainerWithFilePath:memoryEntry.completeImageFilePath
                                                     decoderConfigMap:decoderConfigMap
                                                       codecCatalogue:nil
                                                            memoryMap:memoryEntry.completeImageContext.isAnimated];
        } else {
            container = memoryEntry.completeImage;
        }

        memoryEntry.completeImageFilePath = nil;
        memoryEntry.completeImageData = nil;

        if (container) {
            [container decode];
            memoryEntry.completeImageContext.dimensions = container.dimensions;
            memoryEntry.completeImage = container;

            [memoryCache updateImageEntry:memoryEntry forciblyReplaceExisting:YES];
        }

        complete(container != nil);
    }];
    [[TIPGlobalConfiguration sharedInstance] enqueueImagePipelineOperation:op];
}

@end

@implementation TIPImageStoreHydrationOperation
{
    id<TIPImageStoreRequest> _request;
    TIPImagePipeline *_pipeline;
    id<TIPImageStoreRequestHydrater> _hydrater;

    volatile atomic_bool _isFinished;
    volatile atomic_bool _isExecuting;
    volatile atomic_bool _didStart;
}

- (instancetype)initWithRequest:(id<TIPImageStoreRequest>)request
                       pipeline:(TIPImagePipeline *)pipeline
                       hydrater:(id<TIPImageStoreRequestHydrater>)hydrater
{
    TIPAssert(request);
    TIPAssert(pipeline);
    TIPAssert(hydrater);

    if (!request || !pipeline || !hydrater) {
        return nil;
    }

    if (self = [super init]) {
        _request = request;
        _pipeline = pipeline;
        _hydrater = hydrater;
        atomic_init(&_isFinished, false);
        atomic_init(&_isExecuting, false);
        atomic_init(&_didStart, false);
    }
    return self;
}

- (BOOL)isAsynchronous
{
    return YES;
}

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isExecuting
{
    return atomic_load(&_isExecuting);
}

- (BOOL)isFinished
{
    return atomic_load(&_isFinished);
}

- (void)start
{
    tip_defer(^{
        atomic_store(&(self->_didStart), true);
    });

    [self willChangeValueForKey:@"isExecuting"];
    atomic_store(&_isExecuting, true);
    [self didChangeValueForKey:@"isExecuting"];

    [_hydrater tip_hydrateImageStoreRequest:_request
                              imagePipeline:_pipeline
                                 completion:^(id<TIPImageStoreRequest> newRequest, NSError *error) {
        _complete(self, newRequest, error);
    }];
}

static void _complete(PRIVATE_SELF(TIPImageStoreHydrationOperation),
                      id<TIPImageStoreRequest> __nullable request,
                      NSError * __nullable error)
{
    if (!self) {
        return;
    }

    if (false == atomic_load(&self->_didStart)) {
        // Completed synchronously, don't want to mess up "isAsynchronous" behavior
        [[TIPGlobalConfiguration sharedInstance] enqueueImagePipelineOperation:[NSBlockOperation blockOperationWithBlock:^{
            _complete(self, request, error);
        }]];
        return;
    }

    if (error) {
        self->_error = error;
    } else {
        self->_hydratedRequest = request ?: self->_request;
    }

    [self willChangeValueForKey:@"isFinished"];
    [self willChangeValueForKey:@"isExecuting"];
    atomic_store(&self->_isExecuting, false);
    atomic_store(&self->_isFinished, true);
    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

@end

@implementation TIPImageMoveOperation
{
    TIPImagePipelineOperationCompletionBlock _completion;
}

- (instancetype)initWithPipeline:(TIPImagePipeline *)pipeline
              originalIdentifier:(NSString *)oldIdentifier
               updatedIdentifier:(NSString *)newIdentifier
                      completion:(nullable TIPImagePipelineOperationCompletionBlock)completion
{
    TIPAssert(pipeline != nil);
    if (self = [super init]) {
        _pipeline = pipeline;
        _originalIdentifier = [oldIdentifier copy];
        _updatedIdentifier = [newIdentifier copy];
        _completion = [completion copy];
    }
    return self;
}

- (void)main
{
    NSError *error = nil;
    TIPImageDiskCache *cache = _pipeline.diskCache;
    if (!cache) {
        error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:EINVAL
                                userInfo:nil];
    } else {
        const BOOL success = [cache renameImageEntryWithIdentifier:_originalIdentifier
                                                      toIdentifier:_updatedIdentifier error:&error];
        TIPAssert(!success ^ !error);
        if (success) {
            [_pipeline clearImageWithIdentifier:_originalIdentifier];
        }
    }

    TIPImagePipelineOperationCompletionBlock completion = _completion;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(self, !error, error);
        });
    }
}

@end

NS_ASSUME_NONNULL_END
