//
//  HttpdnsNWHTTPClientTestHelper.h
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HttpdnsNWHTTPClientTestHelper : NSObject

#pragma mark - HTTP 响应数据构造

// 构造标准 HTTP 响应数据
+ (NSData *)createHTTPResponseWithStatus:(NSInteger)statusCode
                              statusText:(NSString *)statusText
                                 headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                    body:(nullable NSData *)body;

// 构造 chunked 编码的 HTTP 响应
+ (NSData *)createChunkedHTTPResponseWithStatus:(NSInteger)statusCode
                                        headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                         chunks:(NSArray<NSData *> *)chunks;

// 构造 chunked 编码的 HTTP 响应（带 trailers）
+ (NSData *)createChunkedHTTPResponseWithStatus:(NSInteger)statusCode
                                        headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                         chunks:(NSArray<NSData *> *)chunks
                                       trailers:(nullable NSDictionary<NSString *, NSString *> *)trailers;

#pragma mark - Chunked 编码工具

// 编码单个 chunk
+ (NSData *)encodeChunk:(NSData *)data;

// 编码单个 chunk（带 extension）
+ (NSData *)encodeChunk:(NSData *)data extension:(nullable NSString *)extension;

// 编码终止 chunk（size=0）
+ (NSData *)encodeLastChunk;

// 编码终止 chunk（带 trailers）
+ (NSData *)encodeLastChunkWithTrailers:(NSDictionary<NSString *, NSString *> *)trailers;

#pragma mark - 测试数据生成

// 生成指定大小的随机数据
+ (NSData *)randomDataWithSize:(NSUInteger)size;

// 生成 JSON 格式的响应体
+ (NSData *)jsonBodyWithDictionary:(NSDictionary *)dictionary;

@end

NS_ASSUME_NONNULL_END
