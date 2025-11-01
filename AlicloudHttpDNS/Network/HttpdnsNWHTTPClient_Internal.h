// Internal helpers for NW HTTP client
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/SecTrust.h>
#import "HttpdnsNWHTTPClient.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, HttpdnsHTTPHeaderParseResult) {
    HttpdnsHTTPHeaderParseResultIncomplete = 0,
    HttpdnsHTTPHeaderParseResultSuccess,
    HttpdnsHTTPHeaderParseResultError,
};

typedef NS_ENUM(NSInteger, HttpdnsHTTPChunkParseResult) {
    HttpdnsHTTPChunkParseResultIncomplete = 0,
    HttpdnsHTTPChunkParseResultSuccess,
    HttpdnsHTTPChunkParseResultError,
};

@interface HttpdnsNWHTTPClient (Internal)

// TLS 验证
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain;

// HTTP 头部解析
- (HttpdnsHTTPHeaderParseResult)tryParseHTTPHeadersInData:(NSData *)data
                                          headerEndIndex:(nullable NSUInteger *)headerEndIndex
                                              statusCode:(nullable NSInteger *)statusCode
                                                 headers:(NSDictionary<NSString *, NSString *> *__autoreleasing _Nullable * _Nullable)headers
                                                   error:(NSError * _Nullable * _Nullable)error;

// Chunked 编码检查
- (HttpdnsHTTPChunkParseResult)checkChunkedBodyCompletionInData:(NSData *)data
                                                 headerEndIndex:(NSUInteger)headerEndIndex
                                                         error:(NSError * _Nullable * _Nullable)error;

// Chunked 编码解码
- (nullable NSData *)decodeChunkedBody:(NSData *)bodyData error:(NSError * _Nullable * _Nullable)error;

// 完整 HTTP 响应解析
- (BOOL)parseHTTPResponseData:(NSData *)data
                   statusCode:(nullable NSInteger *)statusCode
                      headers:(NSDictionary<NSString *, NSString *> *__autoreleasing _Nullable * _Nullable)headers
                         body:(NSData *__autoreleasing _Nullable * _Nullable)body
                        error:(NSError * _Nullable * _Nullable)error;

// HTTP 请求构建
- (NSString *)buildHTTPRequestStringWithURL:(NSURL *)url userAgent:(NSString *)userAgent;

// 连接池 key 生成
- (NSString *)connectionPoolKeyForHost:(NSString *)host port:(NSString *)port useTLS:(BOOL)useTLS;

// 错误转换
+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description;

@end

#if DEBUG
// 测试专用：连接池检查 API
@interface HttpdnsNWHTTPClient (TestInspection)

// 获取指定 pool key 的连接数量
- (NSUInteger)connectionPoolCountForKey:(NSString *)key;

// 获取所有连接池 keys
- (NSArray<NSString *> *)allConnectionPoolKeys;

// 获取连接池总连接数
- (NSUInteger)totalConnectionCount;

// 连接创建计数（用于验证连接复用）
@property (atomic, assign) NSUInteger connectionCreationCount;

// 连接复用计数（用于验证连接复用）
@property (atomic, assign) NSUInteger connectionReuseCount;

// 重置统计计数器（每个测试开始前调用）
- (void)resetPoolStatistics;

@end
#endif

NS_ASSUME_NONNULL_END
