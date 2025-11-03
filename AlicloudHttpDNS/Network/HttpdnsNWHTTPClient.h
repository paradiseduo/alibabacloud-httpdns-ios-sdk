#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class HttpdnsNWReusableConnection;

@interface HttpdnsNWHTTPClientResponse : NSObject

@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSData *body;

@end

@interface HttpdnsNWHTTPClient : NSObject

/// 全局共享实例，复用底层连接池；线程安全
+ (instancetype)sharedInstance;

- (nullable HttpdnsNWHTTPClientResponse *)performRequestWithURLString:(NSString *)urlString
                                                            userAgent:(NSString *)userAgent
                                                              timeout:(NSTimeInterval)timeout
                                                                error:(NSError **)error;

@end

#if DEBUG
@interface HttpdnsNWHTTPClient (TestInspection)

@property (nonatomic, assign, readonly) NSUInteger connectionCreationCount;
@property (nonatomic, assign, readonly) NSUInteger connectionReuseCount;

- (NSUInteger)connectionPoolCountForKey:(NSString *)key;
- (NSArray<NSString *> *)allConnectionPoolKeys;
- (NSUInteger)totalConnectionCount;
- (void)resetPoolStatistics;
- (NSArray<HttpdnsNWReusableConnection *> *)connectionsInPoolForKey:(NSString *)key;

@end
#endif

NS_ASSUME_NONNULL_END
