//
//  HttpdnsNWHTTPClientTestHelper.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//

#import "HttpdnsNWHTTPClientTestHelper.h"

@implementation HttpdnsNWHTTPClientTestHelper

#pragma mark - HTTP 响应数据构造

+ (NSData *)createHTTPResponseWithStatus:(NSInteger)statusCode
                              statusText:(NSString *)statusText
                                 headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                    body:(nullable NSData *)body {
    NSMutableString *response = [NSMutableString string];

    // 状态行
    [response appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)statusCode, statusText ?: @"OK"];

    // 头部
    if (headers) {
        for (NSString *key in headers) {
            [response appendFormat:@"%@: %@\r\n", key, headers[key]];
        }
    }

    // 如果有 body 但没有 Content-Length，自动添加
    if (body && body.length > 0 && !headers[@"Content-Length"]) {
        [response appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    }

    // 空行分隔头部和 body
    [response appendString:@"\r\n"];

    NSMutableData *responseData = [[response dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];

    // 添加 body
    if (body) {
        [responseData appendData:body];
    }

    return [responseData copy];
}

+ (NSData *)createChunkedHTTPResponseWithStatus:(NSInteger)statusCode
                                        headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                         chunks:(NSArray<NSData *> *)chunks {
    return [self createChunkedHTTPResponseWithStatus:statusCode
                                             headers:headers
                                              chunks:chunks
                                            trailers:nil];
}

+ (NSData *)createChunkedHTTPResponseWithStatus:(NSInteger)statusCode
                                        headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                         chunks:(NSArray<NSData *> *)chunks
                                       trailers:(nullable NSDictionary<NSString *, NSString *> *)trailers {
    NSMutableString *response = [NSMutableString string];

    // 状态行
    [response appendFormat:@"HTTP/1.1 %ld OK\r\n", (long)statusCode];

    // 头部
    if (headers) {
        for (NSString *key in headers) {
            [response appendFormat:@"%@: %@\r\n", key, headers[key]];
        }
    }

    // Transfer-Encoding 头部
    [response appendString:@"Transfer-Encoding: chunked\r\n"];

    // 空行
    [response appendString:@"\r\n"];

    NSMutableData *responseData = [[response dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];

    // 添加每个 chunk
    for (NSData *chunk in chunks) {
        [responseData appendData:[self encodeChunk:chunk]];
    }

    // 添加终止 chunk
    if (trailers) {
        [responseData appendData:[self encodeLastChunkWithTrailers:trailers]];
    } else {
        [responseData appendData:[self encodeLastChunk]];
    }

    return [responseData copy];
}

#pragma mark - Chunked 编码工具

+ (NSData *)encodeChunk:(NSData *)data {
    return [self encodeChunk:data extension:nil];
}

+ (NSData *)encodeChunk:(NSData *)data extension:(nullable NSString *)extension {
    NSMutableString *chunkString = [NSMutableString string];

    // Chunk size（十六进制）
    if (extension) {
        [chunkString appendFormat:@"%lx;%@\r\n", (unsigned long)data.length, extension];
    } else {
        [chunkString appendFormat:@"%lx\r\n", (unsigned long)data.length];
    }

    NSMutableData *chunkData = [[chunkString dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];

    // Chunk data
    [chunkData appendData:data];

    // CRLF
    [chunkData appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    return [chunkData copy];
}

+ (NSData *)encodeLastChunk {
    return [@"0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
}

+ (NSData *)encodeLastChunkWithTrailers:(NSDictionary<NSString *, NSString *> *)trailers {
    NSMutableString *lastChunkString = [NSMutableString stringWithString:@"0\r\n"];

    // 添加 trailer 头部
    for (NSString *key in trailers) {
        [lastChunkString appendFormat:@"%@: %@\r\n", key, trailers[key]];
    }

    // 空行终止
    [lastChunkString appendString:@"\r\n"];

    return [lastChunkString dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - 测试数据生成

+ (NSData *)randomDataWithSize:(NSUInteger)size {
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (SecRandomCopyBytes(kSecRandomDefault, size, data.mutableBytes) != 0) {
        // 如果 SecRandom 失败，使用简单的随机数
        uint8_t *bytes = data.mutableBytes;
        for (NSUInteger i = 0; i < size; i++) {
            bytes[i] = arc4random_uniform(256);
        }
    }
    return [data copy];
}

+ (NSData *)jsonBodyWithDictionary:(NSDictionary *)dictionary {
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary
                                                       options:0
                                                         error:&error];
    if (error) {
        NSLog(@"JSON serialization error: %@", error);
        return nil;
    }
    return jsonData;
}

@end
