#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class HttpdnsNWHTTPClient;

@interface HttpdnsNWReusableConnection : NSObject

@property (nonatomic, strong) NSDate *lastUsedDate;
@property (nonatomic, assign) BOOL inUse;
@property (nonatomic, assign, getter=isInvalidated, readonly) BOOL invalidated;

- (instancetype)initWithClient:(HttpdnsNWHTTPClient *)client
                          host:(NSString *)host
                          port:(NSString *)port
                        useTLS:(BOOL)useTLS NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (BOOL)openWithTimeout:(NSTimeInterval)timeout error:(NSError **)error;
- (nullable NSData *)sendRequestData:(NSData *)requestData
                             timeout:(NSTimeInterval)timeout
              remoteConnectionClosed:(BOOL *)remoteConnectionClosed
                               error:(NSError **)error;
- (BOOL)isViable;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

