//
//  BDDiskCache.m
//  BDCacheTest
//
//  Created by licong on 2018/12/26.
//  Copyright © 2018 licong. All rights reserved.
//

#import "BDDiskCache.h"
#import "BDCacheBackgroundTaskManager.h"


#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#endif

#define BDDiskCacheError(error) if (error) { NSLog(@"%@ (%d) ERROR: %@", \
[[NSString stringWithUTF8String:__FILE__] lastPathComponent], \
__LINE__, [error localizedDescription]); }


static id <BDCacheBackgroundTaskManager> BDCacheBackgroundTaskManager;

NSString * const BDDiskCachePrefix = @"com.buding.BDDiskCache";
NSString * const BDDiskCacheShareName = @"BDDiskCacheShared";

@interface BDDiskCache ()
@property (assign) NSUInteger byteCount;
@property (strong, nonatomic) NSURL *cacheURL;
@property (assign, nonatomic) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableDictionary *dates;
@property (nonatomic, strong) NSMutableDictionary *sizes;
@end

@implementation BDDiskCache
@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize byteLimit = _byteLimit;
@synthesize ageLimit = _ageLimit;

#pragma mark - Initialization -

- (instancetype)initWithName:(NSString *)name {
    NSString *rootPath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return [self initWithName:name rootPath:rootPath];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath {
    if (!name)
        return nil;
    if (self = [super init]) {
        _name = name;
        _queue = [BDDiskCache sharedQueue];
        
        _willAddObjectBlock = nil;
        _willRemoveObjectBlock = nil;
        _willRemoveAllObjectsBlock = nil;
        _didAddObjectBlock = nil;
        _didRemoveObjectBlock = nil;
        _didRemoveAllObjectsBlock = nil;
        
        _byteCount = 0;
        _byteLimit = 0;
        _ageLimit = 0.0;
        
        _dates = [[NSMutableDictionary alloc] init];
        _sizes = [[NSMutableDictionary alloc] init];
        
        NSString *pathComponent = [NSString stringWithFormat:@"%@.%@",BDDiskCachePrefix,_name];
        _cacheURL = [NSURL fileURLWithPathComponents:@[rootPath, pathComponent]];
        
        __weak BDDiskCache *weakSelf = self;
        dispatch_async(_queue, ^{
            __strong BDDiskCache *strongSelf = weakSelf;
            [strongSelf createCacheDirectory];
            [strongSelf initializeDiskProperties];
        });
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@.%@.%p",BDDiskCachePrefix,_name,self];
}

+ (instancetype)shareCache {
    static id cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[self alloc] initWithName:BDDiskCacheShareName];
    });
    return cache;
}

+ (dispatch_queue_t)sharedQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create([BDDiskCachePrefix UTF8String], DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

#pragma mark - Private Methods -
/// 为key生成一个URL
- (NSURL *)encodedFileURLForKey:(NSString *)key {
    if (![key length]) {
        return nil;
    }
    return [_cacheURL URLByAppendingPathComponent:[self encodedString:key]];
}
/// 为URL还原出原本的Key值
- (NSString *)keyForEncodedFileURL:(NSURL *)url {
    NSString *fileName = [url lastPathComponent];
    if (!fileName) {
        return nil;
    }
    return [self decodedString:fileName];
}

- (NSString *)encodedString:(NSString *)string {
    if (![string length]) {
        return @"";
    }
    //CFSTR("a")是存放在一个全局字典里面的，下次用到CFSTR("a")的时候先查字典里面有没有，如果有就是用存在的，如果没有则分配一个，并且放到字典里面。
    //一：CFSTR分配出来的字符串对象是不能自己释放的，如果你释放了下次在使用就会使用到一个野对象；
    //二：多线程使用可能会出问题，因为全局的字典是没有锁的。
    CFStringRef static const charsToEscape = CFSTR(".:/");
    CFStringRef escapedString = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                        (__bridge CFStringRef)string,
                                                                        NULL,
                                                                        charsToEscape,
                                                                        kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)escapedString;
}

- (NSString *)decodedString:(NSString *)string {
    if (![string length]) {
        return @"";
    }
    CFStringRef unescapedString = CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault,
                                                                                          (__bridge CFStringRef)string,
                                                                                          CFSTR(""),
                                                                                          kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)unescapedString;
}

#pragma mark - Private Trash Methods -
/// 生成垃圾站操作线程(为后台线程)
+ (dispatch_queue_t)shareTrashQueue {
    static dispatch_queue_t trashQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *queueName = [NSString stringWithFormat:@"%@.trash",BDDiskCachePrefix];
        trashQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(trashQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    });
    return trashQueue;
}

/// 生成垃圾站URL(在临时文件夹中)
+ (NSURL *)sharedTrashURL {
    static NSURL *sharedTrashURL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedTrashURL = [[[NSURL alloc] initFileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:BDDiskCachePrefix isDirectory:YES];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[sharedTrashURL path]]) {
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtURL:sharedTrashURL
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
            BDDiskCacheError(error);
        }
    });
    return sharedTrashURL;
}

/// 把itemURL的资源，移动到垃圾站中
+ (BOOL)moveItemAtURLToTrash:(NSURL *)itemURL {
    if (![[NSFileManager defaultManager] fileExistsAtPath:[itemURL path]])
        return NO;
    
    NSError *error = nil;
    //globallyUniqueString 获取唯一标识
    NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
    NSURL *uniqueTrashURL = [[BDDiskCache sharedTrashURL] URLByAppendingPathComponent:uniqueString];
    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:itemURL toURL:uniqueTrashURL error:&error];
    BDDiskCacheError(error);
    return moved;
}

+ (void)emptyTrash {
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    
    dispatch_async([self shareTrashQueue], ^{
        NSError *error = nil;
        NSArray *trashedItems = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[self sharedTrashURL]
                                                              includingPropertiesForKeys:nil
                                                                                 options:0
                                                                                   error:&error];
        BDDiskCacheError(error);
        for (NSURL *trashedItemURL in trashedItems) {
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtURL:trashedItemURL error:&error];
            BDDiskCacheError(error);
        }
        
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}

#pragma mark - Private Queue Methods -
/// 创建cache文件夹
- (BOOL)createCacheDirectory {
    if ([[NSFileManager defaultManager] fileExistsAtPath:[_cacheURL path]]) {
        return NO;
    }
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtURL:_cacheURL
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:&error];
    BDDiskCacheError(error);
    return success;
}

/// 获取缓存文件的信息（包括时间、大小）
- (void)initializeDiskProperties {
    NSUInteger byteCount = 0;
    NSArray *keys = @[NSURLContentModificationDateKey, NSURLTotalFileSizeKey];
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:_cacheURL
                                                   includingPropertiesForKeys:keys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                        error:&error];
    BDDiskCacheError(error);
    for (NSURL *fileURL in files) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        error = nil;
        NSDictionary *dictionary = [fileURL resourceValuesForKeys:keys error:&error];
        BDDiskCacheError(error);
        
        NSDate *date = [dictionary objectForKey:NSURLContentModificationDateKey];
        if (date && key) {
            [_dates setObject:date forKey:key];
        }
        
        NSNumber *fileSize = [dictionary objectForKey:NSURLTotalFileSizeKey];
        if (fileSize) {
            [_sizes setObject:fileSize forKey:key];
            byteCount += [fileSize unsignedIntegerValue];
        }
    }
    
    if (byteCount > 0) {
        self.byteCount = byteCount;
    }
}

/// 修改fileURL的修改时间
- (BOOL)setFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL {
    if (!date || !fileURL) {
        return NO;
    }
    
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: date}
                                                    ofItemAtPath:[fileURL path]
                                                           error:&error];
    BDDiskCacheError(error);
    if (success) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        if (key) {
            [_dates setObject:date forKey:key];
        }
    }
    return success;
}
/// 删除key对应的文件
- (BOOL)removeFileAndExcuteBlocksForKey:(NSString *)key {
    NSURL *fileURL = [self encodedFileURLForKey:key];
    if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
        return NO;
    }
    if (_willRemoveObjectBlock) {
        _willRemoveObjectBlock(self, key, nil, fileURL);
    }
    BOOL trashed = [BDDiskCache moveItemAtURLToTrash:fileURL];
    if (!trashed) {
        return NO;
    }
    [BDDiskCache emptyTrash];
    NSNumber *byteSize = [_sizes objectForKey:key];
    if (byteSize) {
        self.byteCount = _byteCount - [byteSize unsignedIntegerValue];
    }
    [_sizes removeObjectForKey:key];
    [_dates removeObjectForKey:key];
    if (_didRemoveObjectBlock) {
        _didRemoveObjectBlock(self, key, nil, fileURL);
    }
    return YES;
    
}

/// 当缓存大于指定值，根据文件的大小，从大到小删除文件
- (void)trimDiskToSize:(NSUInteger)trimByteCount {
    if (_byteCount <= trimByteCount) {
        return;
    }
    NSArray *keysSortedBySize = [_sizes keysSortedByValueUsingSelector:@selector(compare:)];
    
    for (NSString *key in [keysSortedBySize reverseObjectEnumerator]) {
        [self removeFileAndExcuteBlocksForKey:key];
        if (_byteCount <= trimByteCount) {
            break;
        }
    }
}

/// 当缓存大于指定值，根据日期从旧到新删除文件
- (void)trimDiskToSizeByDate:(NSUInteger)trimByteCount {
    if (_byteCount <= trimByteCount) {
        return;
    }
    NSArray *keySortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    for (NSString *key in keySortedByDate) { // oldest objects first
        [self removeFileAndExcuteBlocksForKey:key];
        if (_byteCount <= trimByteCount) {
            break;
        }
    }
}

/// 当小于指定日期的缓存 则被删除
- (void)trimDiskToDate:(NSDate *)trimDate {
    NSArray *keySortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    for (NSString *key in keySortedByDate) {
        NSDate *accessDate = [_dates objectForKey:key];
        if (!accessDate) {
            continue;
        }
        if ([accessDate compare:trimDate] == NSOrderedAscending) {
            [self removeFileAndExcuteBlocksForKey:key];
        }else {
            break;
        }
    }
}

/// 超过存储的日期限额ageLimit(秒为单位)，则把过期的资源删除
- (void)trimToAgeLimitRecursively {
    if (_ageLimit == 0.0) {
        return;
    }
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-_ageLimit];
    [self trimDiskToDate:date];
    __weak BDDiskCache *weakSelf = self;
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_ageLimit * NSEC_PER_SEC));
    dispatch_after(time, _queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        [strongSelf trimToAgeLimitRecursively];
    });
}

#pragma mark - Public Asynchronous Methods -


- (void)objectForKey:(NSString *)key block:(BDDiskCacheObjectBlock)block {
    if (!key || !block) {
        return;
    }
    NSDate *now = [NSDate date];
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        id <NSCoding> object = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            @try {
                object = [NSKeyedUnarchiver unarchiveObjectWithFile:[fileURL path]];
            } @catch (NSException *exception) {
                NSError *error = nil;
                [[NSFileManager defaultManager] removeItemAtPath:[fileURL path] error:&error];
                BDDiskCacheError(error);
            }
            [strongSelf setFileModificationDate:now forURL:fileURL];
        }
        block(strongSelf, key, object, fileURL);
    });
}

- (void)fileURLForKey:(NSString *)key block:(BDDiskCacheObjectBlock)block {
    if (!key || !block) {
        return;
    }
    NSDate *now = [NSDate date];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [strongSelf setFileModificationDate:now forURL:fileURL];
        }else {
            fileURL = nil;
        }
        block(strongSelf, key, nil, fileURL);
    });
}

/// 为key值添加object
- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key block:(BDDiskCacheObjectBlock)block {
    if (!key || !object) {
        return;
    }
    NSDate *now = [NSDate date];
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        //生成文件路径
        NSURL *fileURL = [self encodedFileURLForKey:key];
        if (strongSelf->_willAddObjectBlock) {
            strongSelf->_willAddObjectBlock(strongSelf, key, object, fileURL);
        }

        //进行归档操作
        BOOL written = [NSKeyedArchiver archiveRootObject:object toFile:[fileURL path]];
        
        if (written) {
            [strongSelf setFileModificationDate:now forURL:fileURL];
            NSError *error = nil;
            //获取文件的大小
            NSDictionary *values = [fileURL resourceValuesForKeys:@[NSURLTotalFileAllocatedSizeKey] error:&error];
            BDDiskCacheError(error);
            //修改储存的文件大小值
            NSNumber *diskFileSize = [values objectForKey:NSURLTotalFileAllocatedSizeKey];
            if (diskFileSize) {
                NSNumber *oldEntry = [strongSelf->_sizes objectForKey:key];
                if ([oldEntry isKindOfClass:[NSNumber class]]) {
                    strongSelf.byteCount = strongSelf.byteCount - [oldEntry unsignedIntegerValue];
                }
                [strongSelf.sizes setObject:diskFileSize forKey:key];
                strongSelf.byteCount += [diskFileSize unsignedIntegerValue];
            }
            //当缓存大于限额，则需要进行删除缓存操作
            if (strongSelf->_byteLimit > 0 && strongSelf->_byteCount > strongSelf->_byteLimit) {
                [strongSelf trimDiskToSizeByDate:strongSelf->_byteLimit];
            }
        }
        else {
            fileURL = nil;
        }
        
        if (strongSelf->_didAddObjectBlock) {
            strongSelf->_didAddObjectBlock(strongSelf, key, object, fileURL);
        }
        if (block) {
            block(strongSelf, key, object, fileURL);
        }
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}

- (void)removeObjectForKey:(NSString *)key block:(BDDiskCacheObjectBlock)block {
    if (!key) {
        return;
    }
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        __strong BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        NSURL *fileURL = [self encodedFileURLForKey:key];
        [strongSelf removeFileAndExcuteBlocksForKey:key];
        if (block) {
            block(strongSelf, key, nil, fileURL);
        }
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}



- (void)trimToSize:(NSUInteger)trimByteCount block:(BDDiskCacheBlock)block {
    if (trimByteCount == 0) {
        [self removeAllObjects:block];
        return;
    }
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        [strongSelf trimDiskToSize:trimByteCount];
        if (block) {
            block(strongSelf);
        }
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}

- (void)trimToSizeByDate:(NSUInteger)byteCount block:(BDDiskCacheBlock)block {
    if (byteCount == 0) {
        [self removeAllObjects:block];
        return;
    }
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        [strongSelf trimDiskToSizeByDate:byteCount];
        if (block) {
            block(strongSelf);
        }
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}

- (void)trimToDate:(NSDate *)date block:(BDDiskCacheBlock)block {
    if (!date) {
        return;
    }
    if ([date isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects:block];
        return;
    }
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    __weak BDDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        
        [strongSelf trimDiskToDate:date];
        
        if (block)
            block(strongSelf);
        
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}

- (void)removeAllObjects:(BDDiskCacheBlock)block {
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        if (strongSelf->_willRemoveAllObjectsBlock) {
            strongSelf->_willRemoveAllObjectsBlock(strongSelf);
        }
        //清空缓存
        [BDDiskCache moveItemAtURLToTrash:strongSelf->_cacheURL];
        [BDDiskCache emptyTrash];
        
        [strongSelf->_dates removeAllObjects];
        [strongSelf->_sizes removeAllObjects];
        strongSelf.byteCount = 0;
        
        //重新建立缓存文件夹
        [strongSelf createCacheDirectory];
        if (strongSelf->_didRemoveAllObjectsBlock) {
            strongSelf->_didRemoveAllObjectsBlock(strongSelf);
        }
        if (block) {
            block(strongSelf);
        }
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}

- (void)enumerateObjectsWithBlock:(BDDiskCacheObjectBlock)block completionBlock:(BDDiskCacheBlock)completionBlock {
    if (!block) {
        return;
    }
    UIBackgroundTaskIdentifier taskID = [BDCacheBackgroundTaskManager beginBackgroundTask];
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        NSArray *keysSortedByDate = [strongSelf->_dates keysSortedByValueUsingSelector:@selector(compare:)];
        for (NSString *key in keysSortedByDate) {
            NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
            block(strongSelf, key, nil, fileURL);
        }
        if (completionBlock) {
            completionBlock(strongSelf);
        }
        [BDCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}

#pragma mark - Public Synchronous Methods -
- (id<NSCoding>)objectForKey:(NSString *)key {
    if (!key) {
        return nil;
    }
    __block id<NSCoding> obj = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self objectForKey:key block:^(BDDiskCache * _Nonnull cache, NSString * _Nonnull key, id<NSCoding>  _Nullable object, NSURL * _Nonnull fileURL) {
        obj = object;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    // GCD中的对象在6.0之前是不参与ARC的，而6.0之后 在ARC下使用GCD也不用关心释放问题
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
    return obj;
}

- (NSURL *)fileURLForKey:(NSString *)key {
    if (!key) {
        return nil;
    }
    __block NSURL *fileURLForKey = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self fileURLForKey:key block:^(BDDiskCache * _Nonnull cache, NSString * _Nonnull key, id<NSCoding>  _Nullable object, NSURL * _Nonnull fileURL) {
        fileURLForKey = fileURL;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
    return fileURLForKey;
}

- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key {
    if (!object || !key) {
        return;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self setObject:object forKey:key block:^(BDDiskCache * _Nonnull cache, NSString * _Nonnull key, id<NSCoding>  _Nullable object, NSURL * _Nonnull fileURL) {
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
    
    [self removeObjectForKey:key block:^(BDDiskCache * _Nonnull cache, NSString * _Nonnull key, id<NSCoding>  _Nullable object, NSURL * _Nonnull fileURL) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)trimToSize:(NSUInteger)byteCount {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self trimToSize:byteCount block:^(BDDiskCache * _Nonnull cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)trimToSizeByDate:(NSUInteger)byteCount {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self trimToSizeByDate:byteCount block:^(BDDiskCache * _Nonnull cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)trimToDate:(NSDate *)date {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self trimToDate:date block:^(BDDiskCache * _Nonnull cache) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)removeAllObjects {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self removeAllObjects:^(BDDiskCache * _Nonnull cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)enumerateObjectsWithBlock:(BDDiskCacheObjectBlock)block {
    if (!block) {
        return;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self enumerateObjectsWithBlock:block completionBlock:^(BDDiskCache * _Nonnull cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

#pragma mark - Public Thread Safe Accessors -

- (BDDiskCacheObjectBlock)willAddObjectBlock {
    __block BDDiskCacheObjectBlock block = nil;
    dispatch_sync(_queue, ^{
        block = _willAddObjectBlock;
    });
    return block;
}

- (void)setWillAddObjectBlock:(BDDiskCacheObjectBlock)willAddObjectBlock {
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_willAddObjectBlock = [willAddObjectBlock copy];
    });
}

- (BDDiskCacheObjectBlock)willRemoveObjectBlock {
    __block BDDiskCacheObjectBlock block = nil;
    dispatch_sync(_queue, ^{
        block = self->_willRemoveObjectBlock;
    });
    return block;
}

- (void)setWillRemoveObjectBlock:(BDDiskCacheObjectBlock)willRemoveObjectBlock {
    __weak BDDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_willRemoveObjectBlock = [willRemoveObjectBlock copy];
    });
}

- (BDDiskCacheBlock)willRemoveAllObjectsBlock {
    __block BDDiskCacheBlock block = nil;
    dispatch_sync(_queue, ^{
        block = self->_willRemoveAllObjectsBlock;
    });
    return block;
}

- (void)setWillRemoveAllObjectsBlock:(BDDiskCacheBlock)willRemoveAllObjectsBlock {
    __weak BDDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_willRemoveAllObjectsBlock = [willRemoveAllObjectsBlock copy];
    });
}

- (BDDiskCacheObjectBlock)didAddObjectBlock {
    __block BDDiskCacheObjectBlock block = nil;
    dispatch_sync(_queue, ^{
        block = self->_didAddObjectBlock;
    });
    return block;
}

- (void)setDidAddObjectBlock:(BDDiskCacheObjectBlock)didAddObjectBlock {
    __weak BDDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didAddObjectBlock = [didAddObjectBlock copy];
    });
}

- (BDDiskCacheObjectBlock)didRemoveObjectBlock {
    __block BDDiskCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = self->_didRemoveObjectBlock;
    });
    
    return block;
}

- (void)setDidRemoveObjectBlock:(BDDiskCacheObjectBlock)didRemoveObjectBlock {
    __weak BDDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didRemoveObjectBlock = [didRemoveObjectBlock copy];
    });
}

- (BDDiskCacheBlock)didRemoveAllObjectsBlock {
    __block BDDiskCacheBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = self->_didRemoveAllObjectsBlock;
    });
    
    return block;
}

- (void)setDidRemoveAllObjectsBlock:(BDDiskCacheBlock)didRemoveAllObjectsBlock {
    __weak BDDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didRemoveAllObjectsBlock = [didRemoveAllObjectsBlock copy];
    });
}

- (NSUInteger)byteLimit {
    __block NSUInteger byteLimit = 0;
    dispatch_sync(_queue, ^{
        byteLimit = self->_byteLimit;
    });
    return byteLimit;
}

- (void)setByteLimit:(NSUInteger)byteLimit {
    __weak BDDiskCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_byteLimit = byteLimit;
        
        if (byteLimit > 0)
            [strongSelf trimDiskToSizeByDate:byteLimit];
    });
}

- (NSTimeInterval)ageLimit {
    __block NSTimeInterval ageLimit = 0.0;
    
    dispatch_sync(_queue, ^{
        ageLimit = self->_ageLimit;
    });
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit {
    __weak BDDiskCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        BDDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_ageLimit = ageLimit;
        
        [strongSelf trimToAgeLimitRecursively];
    });
}

#pragma mark - Background Tasks -
+ (void)setBackgroundTaskManager:(id<BDCacheBackgroundTaskManager>)backgroundTaskManager {
    BDCacheBackgroundTaskManager = backgroundTaskManager;
}

@end
