//
//  BDCache.h
//  BDCacheTest
//
//  Created by licong on 2018/12/26.
//  Copyright © 2018 licong. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "BDDiskCache.h"
#import "BDMemoryCache.h"


@class BDCache;

typedef void (^BDCacheBlock)(BDCache *cache);
typedef void (^BDCacheObjectBlock)(BDCache *cache, NSString *key, id object);

@interface BDCache : NSObject

/// the name of cache
@property (readonly) NSString *name;

/// A concurrent queue on which blocks passed to the asynchronous access methods are run.
@property (readonly) dispatch_queue_t queue;

///Synchronously retrieves the total byte count of the <diskCache> on the shared disk queue.
@property (readonly) NSUInteger diskByteCount;

/// The underlying disk cache, see <BDDiskCache> for additional configuration and trimming options.
@property (readonly) BDDiskCache *diskCache;

/// The underlying memory cache, see <BDMemoryCache> for additional configuration and trimming options.
@property (readonly) BDMemoryCache *memoryCache;

#pragma mark -
/// @name Initialization

/// The shared singleton cache instance.
+ (instancetype)sharedCache;

- (instancetype)initWithName:(NSString *)name;

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath;

#pragma mark -
/// @name Asynchronous Methods 异步方法

/**
 Retrieves the object for the specified key. This method returns immediately and executes the passed
 block after the object is available, potentially in parallel with other blocks on the <queue>.
 */
- (void)objectForKey:(NSString *)key block:(BDCacheObjectBlock)block;

/**
 Stores an object in the cache for the specified key. This method returns immediately and executes the
 passed block after the object has been stored, potentially in parallel with other blocks on the <queue>.
 */
- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key block:(BDCacheObjectBlock)block;

/**
 Removes the object for the specified key. This method returns immediately and executes the passed
 block after the object has been removed, potentially in parallel with other blocks on the <queue>.
 */
- (void)removeObjectForKey:(NSString *)key block:(BDCacheObjectBlock)block;

/**
 Removes all objects from the cache that have not been used since the specified date. This method returns immediately and
 executes the passed block after the cache has been trimmed, potentially in parallel with other blocks on the <queue>.
 */
- (void)trimToDate:(NSDate *)date block:(BDCacheBlock)block;

/**
 Removes all objects from the cache.This method returns immediately and executes the passed block after the
 cache has been cleared, potentially in parallel with other blocks on the <queue>.
 */
- (void)removeAllObjects:(BDCacheBlock)block;

#pragma mark -
/// @name Synchronous Methods 同步方法

/*
 Retrieves the object for the specified key. This method blocks the calling thread until the object is available.
 */
- (id)objectForKey:(NSString *)key;

/**
 Stores an object in the cache for the specified key. This method blocks the calling thread until the object has been set.
 */
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key;

/**
 Removes the object for the specified key. This method blocks the calling thread until the object
 has been removed.
 */
- (void)removeObjectForKey:(NSString *)key;

/**
 Removes all objects from the cache that have not been used since the specified date.
 This method blocks the calling thread until the cache has been trimmed.
 */
- (void)trimToDate:(NSDate *)date;

///  Removes all objects from the cache. This method blocks the calling thread until the cache has been cleared.
- (void)removeAllObjects;


@end


