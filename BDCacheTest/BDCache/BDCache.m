//
//  BDCache.m
//  BDCacheTest
//
//  Created by licong on 2018/12/26.
//  Copyright © 2018 licong. All rights reserved.
//

#import "BDCache.h"

NSString * const BDCachePrefix = @"com.BDCache";
NSString * const BDCacheSharedName = @"BDCacheShared";

@interface BDCache ()
#if OS_OBJECT_USE_OBJC
@property (strong, nonatomic) dispatch_queue_t queue;
#else
@property (assign, nonatomic) dispatch_queue_t queue;
#endif
@end

@implementation BDCache

#pragma mark - Initialization -

#if !OS_OBJECT_USE_OBJC
- (void)dealloc {
    dispatch_release(_queue);
    _queue = nil;
}
#endif

- (instancetype)initWithName:(NSString *)name {
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath {
    if (!name) {
        return nil;
    }
    if (self = [super init]) {
        _name = [name copy];
        
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.%p",BDCachePrefix,self];
        _queue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        
        _diskCache = [[BDDiskCache alloc] initWithName:_name rootPath:rootPath];
        _memoryCache = [[BDMemoryCache alloc] init];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@.%@.%p",BDCachePrefix, _name, self];
}

+ (instancetype)sharedCache {
    static id cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[self alloc] initWithName:BDCacheSharedName];
    });
    return cache;
}

#pragma mark - Public Asynchronous Methods -

- (void)objectForKey:(NSString *)key block:(BDCacheObjectBlock)block {
    if (!key || !block) {
        return;
    }
    __weak BDCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        __weak BDCache *weakSelf = strongSelf;
        [strongSelf->_memoryCache objectForKey:key block:^(BDMemoryCache *cache, NSString *key, id object) {
            BDCache *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            
            if (object) {
                [strongSelf->_diskCache fileURLForKey:key block:^(BDDiskCache * _Nonnull cache, NSString * _Nonnull key, id<NSCoding>  _Nullable object, NSURL * _Nonnull fileURL) {
                    // update the access time on disk
                }];
                __weak BDCache *weakSelf = strongSelf;
                dispatch_async(strongSelf->_queue, ^{
                    BDCache *strongSelf = weakSelf;
                    if (strongSelf) {
                        block(strongSelf, key, object);
                    }
                });
            }else {
                __weak BDCache *weakSelf = strongSelf;
                [strongSelf->_diskCache objectForKey:key block:^(BDDiskCache * _Nonnull cache, NSString * _Nonnull key, id<NSCoding>  _Nullable object, NSURL * _Nonnull fileURL) {
                    BDCache *strongSelf = weakSelf;
                    if (!strongSelf) {
                        return;
                    }
                    [strongSelf->_memoryCache setObject:object forKey:key block:nil];
                    __weak BDCache *weakSelf = strongSelf;
                    dispatch_async(strongSelf->_queue, ^{
                        BDCache *strongSelf = weakSelf;
                        if (strongSelf) {
                            block(strongSelf, key, object);
                        }
                    });
                }];
            }
        }];
    });
}

- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key block:(BDCacheObjectBlock)block {
    if (!key || !object) {
        return;
    }
    dispatch_group_t group = nil;
    BDMemoryCacheObjectBlock memBlock = nil;
    BDDiskCacheObjectBlock diskBlock = nil;
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(BDMemoryCache *cache, NSString *key, id object) {
            dispatch_group_leave(group);
        };
        diskBlock = ^(BDDiskCache *cache, NSString *key, id<NSCoding> object, NSURL *fileURL) {
            dispatch_group_leave(group);
        };
    }
    
    [_memoryCache setObject:object forKey:key block:memBlock];
    [_diskCache setObject:object forKey:key block:diskBlock];
    
    if (group) {
        __weak BDCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            BDCache *strongSelf = weakSelf;
            if (strongSelf) {
                block(strongSelf, key, object);
            }
        });
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)removeObjectForKey:(NSString *)key block:(BDCacheObjectBlock)block {
    if (!key) {
        return;
    }
    dispatch_group_t group = nil;
    BDMemoryCacheObjectBlock memBlock = nil;
    BDDiskCacheObjectBlock diskBlock = nil;
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        memBlock = ^(BDMemoryCache *cache, NSString *key, id object) {
            dispatch_group_leave(group);
        };
        diskBlock = ^(BDDiskCache *cache, NSString *key, id<NSCoding> object, NSURL *fileURL) {
            dispatch_group_leave(group);
        };
    }
    [_memoryCache removeObjectForKey:key block:memBlock];
    [_diskCache removeObjectForKey:key block:diskBlock];
    if (group) {
        __weak BDCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            BDCache *strongSelf = weakSelf;
            if (strongSelf) {
                block(strongSelf, key, nil);
            }
        });
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)removeAllObjects:(BDCacheBlock)block {
    dispatch_group_t group = nil;
    BDMemoryCacheBlock memBlock = nil;
    BDDiskCacheBlock diskBlock = nil;
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        memBlock = ^(BDMemoryCache *cache) {
            dispatch_group_leave(group);
        };
        diskBlock = ^(BDDiskCache *cache) {
            dispatch_group_leave(group);
        };
    }
    [_memoryCache removeAllObjects:memBlock];
    [_diskCache removeAllObjects:diskBlock];
    
    if (group) {
        __weak BDCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            BDCache *strongSelf = weakSelf;
            if (strongSelf) {
                block(strongSelf);
            }
        });
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)trimToDate:(NSDate *)date block:(BDCacheBlock)block {
    if (!date) {
        return;
    }
    dispatch_group_t group = nil;
    BDMemoryCacheBlock memBlock = nil;
    BDDiskCacheBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        memBlock = ^(BDMemoryCache *cache) {
            dispatch_group_leave(group);
        };
        diskBlock = ^(BDDiskCache *cache) {
            dispatch_group_leave(group);
        };
    }
    [_memoryCache trimToDate:date block:memBlock];
    [_diskCache trimToDate:date block:diskBlock];
    
    if (group) {
        __weak BDCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            BDCache *strongSelf = weakSelf;
            if (strongSelf) {
                block(strongSelf);
            }
        });
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

#pragma mark - Public Synchronous Accessors -

- (NSUInteger)diskByteCount {
    __block NSUInteger byteCount = 0;
    dispatch_sync([BDDiskCache sharedQueue], ^{
        byteCount = self.diskCache.byteCount;
    });
    return byteCount;
}

#pragma mark - Public Synchronous Methods -

- (id)objectForKey:(NSString *)key {
    if (!key) {
        return nil;
    }
    __block id objectForKey = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self objectForKey:key block:^(BDCache *cache, NSString *key, id object) {
        objectForKey = object;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
    
    return objectForKey;
}

- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key {
    if (!key || !object) {
        return;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self setObject:object forKey:key block:^(BDCache *cache, NSString *key, id object) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
    
}

- (void)removeObjectForKey:(NSString *)key {
    if (!key) {
        return;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self removeObjectForKey:key block:^(BDCache *cache, NSString *key, id object) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)trimToDate:(NSDate *)date {
    if (!date) {
        return;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self trimToDate:date block:^(BDCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)removeAllObjects {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self removeAllObjects:^(BDCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

@end
