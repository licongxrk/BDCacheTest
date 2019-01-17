//
//  BDCacheBackgroundTaskManager.h
//  BDCacheTest
//
//  Created by licong on 2018/12/26.
//  Copyright © 2018 licong. All rights reserved.
//

#import <Foundation/Foundation.h>

#if __IPHONE_OS_VERSION_MIN_REQUIREDE >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#else
typedef NSUInteger UIBackgroundTaskIdentifier;
#endif

@protocol BDCacheBackgroundTaskManager <NSObject>

/**
 Marks the beginning of a new long-running background task.
 
 @return A unique identifier for the new background task. You must pass this value to the `endBackgroundTask:` method to
 mark the end of this task. This method returns `UIBackgroundTaskInvalid` if running in the background is not possible.
 */
- (UIBackgroundTaskIdentifier)beginBackgroundTask;

/**
 Marks the end of a specific long-running background task.
 
 @param identifier An identifier returned by the `beginBackgroundTaskWithExpirationHandler:` method.
 */
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier;

@end

