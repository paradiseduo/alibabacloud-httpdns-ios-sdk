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

#if DEBUG
// 测试专用：连接状态检查与操作
@interface HttpdnsNWReusableConnection (DebugInspection)

// 状态检查（这些属性已在主接口暴露，这里仅为文档明确）
// @property lastUsedDate - 可读写
// @property inUse - 可读写
// @property invalidated - 只读

// 测试辅助方法
- (void)debugSetLastUsedDate:(nullable NSDate *)date;
- (void)debugSetInUse:(BOOL)inUse;
- (void)debugInvalidate;

@end
#endif

NS_ASSUME_NONNULL_END

