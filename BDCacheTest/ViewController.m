//
//  ViewController.m
//  BDCacheTest
//
//  Created by licong on 2018/12/26.
//  Copyright © 2018 licong. All rights reserved.
//

#import "ViewController.h"
#import "BDCache/BDDiskCache.h"
#import "BDCache/BDMemoryCache.h"

@interface Animal : NSObject<NSCoding>
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *age;
@end

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    [self testDiskCache];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id a = [[BDMemoryCache shareCache] objectForKey:@"a"];
        NSLog(@"____%@",a);
    });
}

- (void)testDiskCache {
    BDMemoryCache *cache = [BDMemoryCache shareCache];
    [cache setDidAddObjectBlock:^(BDMemoryCache *cache, NSString *key, id object) {
        NSLog(@"did add %@",object);
    }];
    [cache setWillAddObjectBlock:^(BDMemoryCache *cache, NSString *key, id object) {
        NSLog(@"will add %@",object);
    }];
    [cache setWillRemoveObjectBlock:^(BDMemoryCache *cache, NSString *key, id object) {
        NSLog(@"will remove %@",object);
    }];
    [cache setDidAddObjectBlock:^(BDMemoryCache *cache, NSString *key, id object) {
        NSLog(@"did remove %@",object);
    }];
    [cache setDidRemoveAllObjectsBlock:^(BDMemoryCache *cache) {
        NSLog(@"did r all");
    }];
    [cache setWillRemoveAllObjectsBlock:^(BDMemoryCache *cache) {
        NSLog(@"will r all");
    }];
    [cache setObject:@"a" forKey:@"a"];
    [cache removeObjectForKey:@"a"];
    [cache setObject:@"b" forKey:@"b"];
    [cache setObject:@"c" forKey:@"c"];
    [cache removeAllObjects];
}


@end

@interface Animal ()

@end

@implementation Animal
- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.name forKey:@"name"];
    [aCoder encodeObject:self.age forKey:@"age_"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self.name = [aDecoder decodeObjectForKey:@"name"];
    self.age = [aDecoder decodeObjectForKey:@"age_"];
    return self;
}


@end
