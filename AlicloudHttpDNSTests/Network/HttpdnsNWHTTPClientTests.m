//
//  HttpdnsNWHTTPClientTests.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <OCMock/OCMock.h>
#import "HttpdnsNWHTTPClient.h"
#import "HttpdnsNWHTTPClient_Internal.h"
#import "HttpdnsNWReusableConnection.h"
#import "HttpdnsNWHTTPClientTestHelper.h"

@interface HttpdnsNWHTTPClientTests : XCTestCase

@property (nonatomic, strong) HttpdnsNWHTTPClient *client;

@end

@implementation HttpdnsNWHTTPClientTests

- (void)setUp {
    [super setUp];
    self.client = [[HttpdnsNWHTTPClient alloc] init];
}

- (void)tearDown {
    self.client = nil;
    [super tearDown];
}

#pragma mark - A. HTTP 解析逻辑测试

#pragma mark - A1. Header 解析 (9个)

// A1.1 正常响应
- (void)testParseHTTPHeaders_ValidResponse_Success {
    NSData *data = [HttpdnsNWHTTPClientTestHelper createHTTPResponseWithStatus:200
                                                                     statusText:@"OK"
                                                                        headers:@{@"Content-Type": @"application/json"}
                                                                           body:nil];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultSuccess);
    XCTAssertEqual(statusCode, 200);
    XCTAssertNotNil(headers);
    XCTAssertEqualObjects(headers[@"content-type"], @"application/json"); // key 应该转为小写
    XCTAssertNil(error);
}

// A1.2 多个头部
- (void)testParseHTTPHeaders_MultipleHeaders_AllParsed {
    NSDictionary *testHeaders = @{
        @"Content-Type": @"application/json",
        @"Content-Length": @"123",
        @"Connection": @"keep-alive",
        @"X-Custom-Header": @"custom-value",
        @"Cache-Control": @"no-cache"
    };

    NSData *data = [HttpdnsNWHTTPClientTestHelper createHTTPResponseWithStatus:200
                                                                     statusText:@"OK"
                                                                        headers:testHeaders
                                                                           body:nil];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultSuccess);
    XCTAssertEqual(headers.count, testHeaders.count);
    // 验证所有头部都被解析，且 key 转为小写
    XCTAssertEqualObjects(headers[@"content-type"], @"application/json");
    XCTAssertEqualObjects(headers[@"content-length"], @"123");
    XCTAssertEqualObjects(headers[@"connection"], @"keep-alive");
    XCTAssertEqualObjects(headers[@"x-custom-header"], @"custom-value");
    XCTAssertEqualObjects(headers[@"cache-control"], @"no-cache");
}

// A1.3 不完整响应
- (void)testParseHTTPHeaders_IncompleteData_ReturnsIncomplete {
    NSString *incompleteResponse = @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n";
    NSData *data = [incompleteResponse dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultIncomplete);
}

// A1.4 无效状态行
- (void)testParseHTTPHeaders_InvalidStatusLine_ReturnsError {
    NSString *invalidResponse = @"INVALID\r\n\r\n";
    NSData *data = [invalidResponse dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultError);
    XCTAssertNotNil(error);
}

// A1.5 头部包含空格
- (void)testParseHTTPHeaders_HeadersWithWhitespace_Trimmed {
    NSString *responseWithSpaces = @"HTTP/1.1 200 OK\r\nContent-Type:  application/json  \r\n\r\n";
    NSData *data = [responseWithSpaces dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultSuccess);
    XCTAssertEqualObjects(headers[@"content-type"], @"application/json"); // 应该被 trim
}

// A1.6 头部没有值
- (void)testParseHTTPHeaders_EmptyHeaderValue_HandledGracefully {
    NSString *responseWithEmptyValue = @"HTTP/1.1 200 OK\r\nX-Empty-Header:\r\n\r\n";
    NSData *data = [responseWithEmptyValue dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultSuccess);
    XCTAssertEqualObjects(headers[@"x-empty-header"], @"");
}

// A1.7 状态码非数字
- (void)testParseHTTPHeaders_NonNumericStatusCode_ReturnsError {
    NSString *invalidStatusCode = @"HTTP/1.1 ABC OK\r\n\r\n";
    NSData *data = [invalidStatusCode dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultError);
}

// A1.8 状态码为零
- (void)testParseHTTPHeaders_StatusCodeZero_ReturnsError {
    NSString *zeroStatusCode = @"HTTP/1.1 0 OK\r\n\r\n";
    NSData *data = [zeroStatusCode dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultError);
}

// A1.9 头部没有冒号被跳过
- (void)testParseHTTPHeaders_HeaderWithoutColon_Skipped {
    NSString *responseWithInvalidHeader = @"HTTP/1.1 200 OK\r\nInvalidHeader\r\nContent-Type: application/json\r\n\r\n";
    NSData *data = [responseWithInvalidHeader dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex;
    NSInteger statusCode;
    NSDictionary *headers;
    NSError *error;

    HttpdnsHTTPHeaderParseResult result = [self.client tryParseHTTPHeadersInData:data
                                                                  headerEndIndex:&headerEndIndex
                                                                      statusCode:&statusCode
                                                                         headers:&headers
                                                                           error:&error];

    XCTAssertEqual(result, HttpdnsHTTPHeaderParseResultSuccess);
    XCTAssertEqualObjects(headers[@"content-type"], @"application/json"); // 有效头部正常解析
}

#pragma mark - A2. Chunked 编码检查 (8个)

// A2.1 单个 chunk
- (void)testCheckChunkedBody_SingleChunk_DetectsComplete {
    NSString *singleChunkBody = @"5\r\nhello\r\n0\r\n\r\n";
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", singleChunkBody];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultSuccess);
    XCTAssertNil(error);
}

// A2.2 多个 chunks
- (void)testCheckChunkedBody_MultipleChunks_DetectsComplete {
    NSString *multiChunkBody = @"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", multiChunkBody];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultSuccess);
    XCTAssertNil(error);
}

// A2.3 不完整 chunk
- (void)testCheckChunkedBody_IncompleteChunk_ReturnsIncomplete {
    NSString *incompleteChunkBody = @"5\r\nhel"; // 数据不完整
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", incompleteChunkBody];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultIncomplete);
}

// A2.4 带 chunk extension
- (void)testCheckChunkedBody_WithChunkExtension_Ignored {
    NSString *chunkWithExtension = @"5;name=value\r\nhello\r\n0\r\n\r\n";
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", chunkWithExtension];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    // headerEndIndex 指向第一个 \r\n\r\n 中的第一个 \r
    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultSuccess);
    XCTAssertNil(error);
}

// A2.5 无效十六进制 size
- (void)testCheckChunkedBody_InvalidHexSize_ReturnsError {
    NSString *invalidChunkSize = @"ZZZ\r\nhello\r\n0\r\n\r\n";
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", invalidChunkSize];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultError);
    XCTAssertNotNil(error);
}

// A2.6 Chunk size 溢出
- (void)testCheckChunkedBody_ChunkSizeOverflow_ReturnsError {
    NSString *overflowChunkSize = @"FFFFFFFFFFFFFFFF\r\n";
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", overflowChunkSize];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultError);
    XCTAssertNotNil(error);
}

// A2.7 缺少 CRLF 终止符
- (void)testCheckChunkedBody_MissingCRLFTerminator_ReturnsError {
    NSString *missingTerminator = @"5\r\nhelloXX0\r\n\r\n"; // 应该是 hello\r\n
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", missingTerminator];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultError);
    XCTAssertNotNil(error);
}

// A2.8 带 trailers
- (void)testCheckChunkedBody_WithTrailers_DetectsComplete {
    NSString *chunkWithTrailers = @"5\r\nhello\r\n0\r\nX-Trailer: value\r\nX-Custom: test\r\n\r\n";
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n\r\n%@", chunkWithTrailers];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger headerEndIndex = [@"HTTP/1.1 200 OK" length];
    NSError *error;

    HttpdnsHTTPChunkParseResult result = [self.client checkChunkedBodyCompletionInData:data
                                                                         headerEndIndex:headerEndIndex
                                                                                 error:&error];

    XCTAssertEqual(result, HttpdnsHTTPChunkParseResultSuccess);
    XCTAssertNil(error);
}

#pragma mark - A3. Chunked 解码 (2个)

// A3.1 多个 chunks 解码
- (void)testDecodeChunkedBody_MultipleChunks_DecodesCorrectly {
    NSArray *chunks = @[
        [@"hello" dataUsingEncoding:NSUTF8StringEncoding],
        [@" world" dataUsingEncoding:NSUTF8StringEncoding]
    ];

    NSData *chunkedData = [HttpdnsNWHTTPClientTestHelper createChunkedHTTPResponseWithStatus:200
                                                                                      headers:nil
                                                                                       chunks:chunks];

    // 提取 chunked body 部分（跳过 headers）
    NSData *headerData = [@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *bodyData = [chunkedData subdataWithRange:NSMakeRange(headerData.length, chunkedData.length - headerData.length)];

    NSError *error;
    NSData *decoded = [self.client decodeChunkedBody:bodyData error:&error];

    XCTAssertNotNil(decoded);
    XCTAssertNil(error);
    NSString *decodedString = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(decodedString, @"hello world");
}

// A3.2 无效格式返回 nil
- (void)testDecodeChunkedBody_InvalidFormat_ReturnsNil {
    NSString *invalidChunked = @"ZZZ\r\nbad data\r\n";
    NSData *bodyData = [invalidChunked dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error;
    NSData *decoded = [self.client decodeChunkedBody:bodyData error:&error];

    XCTAssertNil(decoded);
    XCTAssertNotNil(error);
}

#pragma mark - A4. 完整响应解析 (6个)

// A4.1 Content-Length 响应
- (void)testParseResponse_WithContentLength_ParsesCorrectly {
    NSString *bodyString = @"{\"ips\":[]}";
    NSData *bodyData = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    NSData *responseData = [HttpdnsNWHTTPClientTestHelper createHTTPResponseWithStatus:200
                                                                             statusText:@"OK"
                                                                                headers:@{@"Content-Type": @"application/json"}
                                                                                   body:bodyData];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:responseData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertTrue(success);
    XCTAssertEqual(statusCode, 200);
    XCTAssertNotNil(headers);
    XCTAssertEqualObjects(headers[@"content-type"], @"application/json");
    XCTAssertEqualObjects(body, bodyData);
    XCTAssertNil(error);
}

// A4.2 Chunked 响应
- (void)testParseResponse_WithChunkedEncoding_DecodesBody {
    NSArray *chunks = @[
        [@"{\"ips\"" dataUsingEncoding:NSUTF8StringEncoding],
        [@":[]}" dataUsingEncoding:NSUTF8StringEncoding]
    ];

    NSData *responseData = [HttpdnsNWHTTPClientTestHelper createChunkedHTTPResponseWithStatus:200
                                                                                       headers:@{@"Content-Type": @"application/json"}
                                                                                        chunks:chunks];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:responseData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertTrue(success);
    XCTAssertEqual(statusCode, 200);
    NSString *bodyString = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(bodyString, @"{\"ips\":[]}");
}

// A4.3 空 body
- (void)testParseResponse_EmptyBody_Success {
    NSData *responseData = [HttpdnsNWHTTPClientTestHelper createHTTPResponseWithStatus:204
                                                                             statusText:@"No Content"
                                                                                headers:nil
                                                                                   body:nil];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:responseData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertTrue(success);
    XCTAssertEqual(statusCode, 204);
    XCTAssertEqual(body.length, 0);
}

// A4.4 Content-Length 不匹配仍然成功
- (void)testParseResponse_ContentLengthMismatch_LogsButSucceeds {
    NSData *bodyData = [@"short" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *responseData = [HttpdnsNWHTTPClientTestHelper createHTTPResponseWithStatus:200
                                                                             statusText:@"OK"
                                                                                headers:@{@"Content-Length": @"100"} // 不匹配
                                                                                   body:bodyData];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:responseData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertTrue(success); // 仍然成功，只是日志警告
    XCTAssertEqualObjects(body, bodyData);
}

// A4.5 空数据返回错误
- (void)testParseResponse_EmptyData_ReturnsError {
    NSData *emptyData = [NSData data];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:emptyData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertFalse(success);
    XCTAssertNotNil(error);
}

// A4.6 只有 headers 无 body
- (void)testParseResponse_OnlyHeaders_EmptyBody {
    NSData *responseData = [HttpdnsNWHTTPClientTestHelper createHTTPResponseWithStatus:200
                                                                             statusText:@"OK"
                                                                                headers:@{@"Content-Type": @"text/plain"}
                                                                                   body:nil];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:responseData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertTrue(success);
    XCTAssertEqual(statusCode, 200);
    XCTAssertNotNil(headers);
    XCTAssertEqual(body.length, 0);
}

#pragma mark - C. 请求构建测试 (7个)

// C.1 基本 GET 请求
- (void)testBuildHTTPRequest_BasicGET_CorrectFormat {
    NSURL *url = [NSURL URLWithString:@"http://example.com/"];
    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:@"TestAgent"];

    XCTAssertTrue([request containsString:@"GET / HTTP/1.1\r\n"]);
    XCTAssertTrue([request containsString:@"Host: example.com\r\n"]);
    XCTAssertTrue([request containsString:@"User-Agent: TestAgent\r\n"]);
    XCTAssertTrue([request containsString:@"Accept: application/json\r\n"]);
    XCTAssertTrue([request containsString:@"Accept-Encoding: identity\r\n"]);
    XCTAssertTrue([request containsString:@"Connection: keep-alive\r\n"]);
    XCTAssertTrue([request hasSuffix:@"\r\n\r\n"]);
}

// C.2 带查询参数
- (void)testBuildHTTPRequest_WithQueryString_Included {
    NSURL *url = [NSURL URLWithString:@"http://example.com/path?foo=bar&baz=qux"];
    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:nil];

    XCTAssertTrue([request containsString:@"GET /path?foo=bar&baz=qux HTTP/1.1\r\n"]);
}

// C.3 包含 User-Agent
- (void)testBuildHTTPRequest_WithUserAgent_Included {
    NSURL *url = [NSURL URLWithString:@"http://example.com/"];
    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:@"CustomAgent/1.0"];

    XCTAssertTrue([request containsString:@"User-Agent: CustomAgent/1.0\r\n"]);
}

// C.4 HTTP 默认端口不显示
- (void)testBuildHTTPRequest_HTTPDefaultPort_NotInHost {
    NSURL *url = [NSURL URLWithString:@"http://example.com:80/"];
    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:nil];

    XCTAssertTrue([request containsString:@"Host: example.com\r\n"]);
    XCTAssertFalse([request containsString:@"Host: example.com:80\r\n"]);
}

// C.5 HTTPS 默认端口不显示
- (void)testBuildHTTPRequest_HTTPSDefaultPort_NotInHost {
    NSURL *url = [NSURL URLWithString:@"https://example.com:443/"];
    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:nil];

    XCTAssertTrue([request containsString:@"Host: example.com\r\n"]);
    XCTAssertFalse([request containsString:@"Host: example.com:443\r\n"]);
}

// C.6 非默认端口显示
- (void)testBuildHTTPRequest_NonDefaultPort_InHost {
    NSURL *url = [NSURL URLWithString:@"http://example.com:8080/"];
    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:nil];

    XCTAssertTrue([request containsString:@"Host: example.com:8080\r\n"]);
}

// C.7 固定头部存在
- (void)testBuildHTTPRequest_FixedHeaders_Present {
    NSURL *url = [NSURL URLWithString:@"http://example.com/"];
    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:nil];

    XCTAssertTrue([request containsString:@"Accept: application/json\r\n"]);
    XCTAssertTrue([request containsString:@"Accept-Encoding: identity\r\n"]);
    XCTAssertTrue([request containsString:@"Connection: keep-alive\r\n"]);
}

#pragma mark - E. TLS 验证测试 (4个占位符)

// 注意：TLS 验证测试需要真实的 SecTrustRef 或复杂的 mock
// 这些测试在实际环境中需要根据测试框架调整

// E.1 有效证书返回 YES
- (void)testEvaluateServerTrust_ValidCertificate_ReturnsYES {
    // 需要创建有效的 SecTrustRef 进行测试
    // 跳过或标记为手动测试
}

// E.2 Proceed 结果返回 YES
- (void)testEvaluateServerTrust_ProceedResult_ReturnsYES {
    // Mock SecTrustEvaluate 返回 kSecTrustResultProceed
}

// E.3 无效证书返回 NO
- (void)testEvaluateServerTrust_InvalidCertificate_ReturnsNO {
    // Mock SecTrustEvaluate 返回 kSecTrustResultDeny
}

// E.4 指定域名使用 SSL Policy
- (void)testEvaluateServerTrust_WithDomain_UsesSSLPolicy {
    // 验证使用了 SecPolicyCreateSSL(true, domain)
}

#pragma mark - F. 边缘情况测试 (5个)

// F.1 超长 URL
- (void)testPerformRequest_VeryLongURL_HandlesCorrectly {
    NSMutableString *longPath = [NSMutableString stringWithString:@"http://example.com/"];
    for (int i = 0; i < 1000; i++) {
        [longPath appendString:@"long/"];
    }

    NSURL *url = [NSURL URLWithString:longPath];
    XCTAssertNotNil(url);

    NSString *request = [self.client buildHTTPRequestStringWithURL:url userAgent:nil];
    XCTAssertTrue(request.length > 5000);
}

// F.2 空 User-Agent
- (void)testBuildRequest_EmptyUserAgent_NoUserAgentHeader {
    NSURL *url = [NSURL URLWithString:@"http://example.com/"];
    NSString *requestWithNil = [self.client buildHTTPRequestStringWithURL:url userAgent:nil];

    XCTAssertFalse([requestWithNil containsString:@"User-Agent:"]);
}

// F.3 超大响应体
- (void)testParseResponse_VeryLargeBody_HandlesCorrectly {
    NSData *largeBody = [HttpdnsNWHTTPClientTestHelper randomDataWithSize:5 * 1024 * 1024];
    NSData *responseData = [HttpdnsNWHTTPClientTestHelper createHTTPResponseWithStatus:200
                                                                             statusText:@"OK"
                                                                                headers:nil
                                                                                   body:largeBody];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:responseData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertTrue(success);
    XCTAssertEqual(body.length, largeBody.length);
}

// F.4 Chunked 解码失败回退到原始数据
- (void)testParseResponse_ChunkedDecodeFails_FallsBackToRaw {
    NSString *badChunked = @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nBAD_CHUNK_DATA";
    NSData *responseData = [badChunked dataUsingEncoding:NSUTF8StringEncoding];

    NSInteger statusCode;
    NSDictionary *headers;
    NSData *body;
    NSError *error;

    BOOL success = [self.client parseHTTPResponseData:responseData
                                            statusCode:&statusCode
                                               headers:&headers
                                                  body:&body
                                                 error:&error];

    XCTAssertTrue(success);
    XCTAssertNotNil(body);
}

// F.5 连接池 key 生成测试
- (void)testConnectionPoolKey_DifferentHosts_SeparateKeys {
    NSString *key1 = [self.client connectionPoolKeyForHost:@"host1.com" port:@"80" useTLS:NO];
    NSString *key2 = [self.client connectionPoolKeyForHost:@"host2.com" port:@"80" useTLS:NO];

    XCTAssertNotEqualObjects(key1, key2);
}

- (void)testConnectionPoolKey_DifferentPorts_SeparateKeys {
    NSString *key1 = [self.client connectionPoolKeyForHost:@"example.com" port:@"80" useTLS:NO];
    NSString *key2 = [self.client connectionPoolKeyForHost:@"example.com" port:@"8080" useTLS:NO];

    XCTAssertNotEqualObjects(key1, key2);
}

- (void)testConnectionPoolKey_HTTPvsHTTPS_SeparateKeys {
    NSString *keyHTTP = [self.client connectionPoolKeyForHost:@"example.com" port:@"80" useTLS:NO];
    NSString *keyHTTPS = [self.client connectionPoolKeyForHost:@"example.com" port:@"443" useTLS:YES];

    XCTAssertNotEqualObjects(keyHTTP, keyHTTPS);
}

@end
