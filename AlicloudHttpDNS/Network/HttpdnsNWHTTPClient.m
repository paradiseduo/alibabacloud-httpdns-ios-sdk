#import "HttpdnsNWHTTPClient.h"
#import "HttpdnsNWReusableConnection.h"
#import "HttpdnsNWHTTPClient_Internal.h"

#import <Network/Network.h>
#import <Security/SecCertificate.h>
#import <Security/SecPolicy.h>
#import <Security/SecTrust.h>

#import "HttpdnsInternalConstant.h"
#import "HttpdnsLog_Internal.h"
#import "HttpdnsPublicConstant.h"
#import "HttpdnsUtil.h"

@interface HttpdnsNWHTTPClientResponse ()
@end

@implementation HttpdnsNWHTTPClientResponse
@end

static const NSUInteger kHttpdnsNWHTTPClientMaxIdleConnectionsPerKey = 4;
static const NSTimeInterval kHttpdnsNWHTTPClientIdleConnectionTimeout = 30.0;
static const NSTimeInterval kHttpdnsNWHTTPClientDefaultTimeout = 10.0;

// decoupled reusable connection implementation moved to HttpdnsNWReusableConnection.{h,m}

@interface HttpdnsNWHTTPClient ()

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<HttpdnsNWReusableConnection *> *> *connectionPool;
@property (nonatomic, strong) dispatch_queue_t poolQueue;

#if DEBUG
// 测试专用统计计数器
@property (atomic, assign) NSUInteger connectionCreationCount;
@property (atomic, assign) NSUInteger connectionReuseCount;
#endif

- (NSString *)connectionPoolKeyForHost:(NSString *)host port:(NSString *)port useTLS:(BOOL)useTLS;
- (HttpdnsNWReusableConnection *)dequeueConnectionForHost:(NSString *)host
                                                     port:(NSString *)port
                                                   useTLS:(BOOL)useTLS
                                                  timeout:(NSTimeInterval)timeout
                                                    error:(NSError **)error;
- (void)returnConnection:(HttpdnsNWReusableConnection *)connection
                   forKey:(NSString *)key
              shouldClose:(BOOL)shouldClose;
- (void)pruneConnectionPool:(NSMutableArray<HttpdnsNWReusableConnection *> *)pool
              referenceDate:(NSDate *)referenceDate;
- (NSString *)buildHTTPRequestStringWithURL:(NSURL *)url userAgent:(NSString *)userAgent;
- (BOOL)parseHTTPResponseData:(NSData *)data
                   statusCode:(NSInteger *)statusCode
                      headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                         body:(NSData *__autoreleasing *)body
                        error:(NSError **)error;
- (HttpdnsHTTPHeaderParseResult)tryParseHTTPHeadersInData:(NSData *)data
                                          headerEndIndex:(NSUInteger *)headerEndIndex
                                              statusCode:(NSInteger *)statusCode
                                                 headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                                                   error:(NSError **)error;
- (HttpdnsHTTPChunkParseResult)checkChunkedBodyCompletionInData:(NSData *)data
                                                 headerEndIndex:(NSUInteger)headerEndIndex
                                                         error:(NSError **)error;
- (NSData *)decodeChunkedBody:(NSData *)bodyData error:(NSError **)error;
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain;
+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description;

@end

@implementation HttpdnsNWHTTPClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _poolQueue = dispatch_queue_create("com.alibaba.sdk.httpdns.network.pool", DISPATCH_QUEUE_SERIAL);
        _connectionPool = [NSMutableDictionary dictionary];
    }
    return self;
}

- (nullable HttpdnsNWHTTPClientResponse *)performRequestWithURLString:(NSString *)urlString
                                                            userAgent:(NSString *)userAgent
                                                              timeout:(NSTimeInterval)timeout
                                                                error:(NSError **)error {
    HttpdnsLogDebug("Send Network.framework request URL: %@", urlString);
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid resolve URL"}];
        }
        return nil;
    }

    NSTimeInterval requestTimeout = timeout > 0 ? timeout : kHttpdnsNWHTTPClientDefaultTimeout;

    NSString *host = url.host;
    if (![HttpdnsUtil isNotEmptyString:host]) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing host in resolve URL"}];
        }
        return nil;
    }

    BOOL useTLS = [[url.scheme lowercaseString] isEqualToString:@"https"];
    NSString *portString = url.port ? url.port.stringValue : (useTLS ? @"443" : @"80");

    NSString *requestString = [self buildHTTPRequestStringWithURL:url userAgent:userAgent];
    NSData *requestData = [requestString dataUsingEncoding:NSUTF8StringEncoding];
    if (!requestData) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to encode HTTP request"}];
        }
        return nil;
    }

    NSError *connectionError = nil;
    HttpdnsNWReusableConnection *connection = [self dequeueConnectionForHost:host
                                                                         port:portString
                                                                       useTLS:useTLS
                                                                      timeout:requestTimeout
                                                                        error:&connectionError];
    if (!connection) {
        if (error) {
            *error = connectionError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                            code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Unable to obtain network connection"}];
        }
        return nil;
    }

    NSString *poolKey = [self connectionPoolKeyForHost:host port:portString useTLS:useTLS];
    BOOL remoteClosed = NO;
    NSError *exchangeError = nil;
    NSData *rawResponse = [connection sendRequestData:requestData
                                              timeout:requestTimeout
                               remoteConnectionClosed:&remoteClosed
                                                error:&exchangeError];

    if (!rawResponse) {
        [self returnConnection:connection forKey:poolKey shouldClose:YES];
        if (error) {
            *error = exchangeError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Network request failed"}];
        }
        return nil;
    }

    NSInteger statusCode = 0;
    NSDictionary<NSString *, NSString *> *headers = nil;
    NSData *bodyData = nil;
    NSError *parseError = nil;
    if (![self parseHTTPResponseData:rawResponse statusCode:&statusCode headers:&headers body:&bodyData error:&parseError]) {
        [self returnConnection:connection forKey:poolKey shouldClose:YES];
        if (error) {
            *error = parseError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                       code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse HTTP response"}];
        }
        return nil;
    }

    BOOL shouldClose = remoteClosed;
    NSString *connectionHeader = headers[@"connection"];
    if ([HttpdnsUtil isNotEmptyString:connectionHeader] && [connectionHeader rangeOfString:@"close" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        shouldClose = YES;
    }
    NSString *proxyConnectionHeader = headers[@"proxy-connection"];
    if (!shouldClose && [HttpdnsUtil isNotEmptyString:proxyConnectionHeader] && [proxyConnectionHeader rangeOfString:@"close" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        shouldClose = YES;
    }

    [self returnConnection:connection forKey:poolKey shouldClose:shouldClose];

    HttpdnsNWHTTPClientResponse *response = [HttpdnsNWHTTPClientResponse new];
    response.statusCode = statusCode;
    response.headers = headers ?: @{};
    response.body = bodyData ?: [NSData data];
    return response;
}

- (NSString *)connectionPoolKeyForHost:(NSString *)host port:(NSString *)port useTLS:(BOOL)useTLS {
    NSString *safeHost = host ?: @"";
    NSString *safePort = port ?: @"";
    return [NSString stringWithFormat:@"%@:%@:%@", safeHost, safePort, useTLS ? @"tls" : @"tcp"];
}

- (HttpdnsNWReusableConnection *)dequeueConnectionForHost:(NSString *)host
                                                     port:(NSString *)port
                                                   useTLS:(BOOL)useTLS
                                                  timeout:(NSTimeInterval)timeout
                                                    error:(NSError **)error {
    NSString *key = [self connectionPoolKeyForHost:host port:port useTLS:useTLS];
    NSDate *now = [NSDate date];
    __block HttpdnsNWReusableConnection *connection = nil;

    dispatch_sync(self.poolQueue, ^{
        NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
        if (!pool) {
            pool = [NSMutableArray array];
            self.connectionPool[key] = pool;
        }
        [self pruneConnectionPool:pool referenceDate:now];
        for (HttpdnsNWReusableConnection *candidate in pool) {
            if (!candidate.inUse && [candidate isViable]) {
                candidate.inUse = YES;
                candidate.lastUsedDate = now;
                connection = candidate;
                break;
            }
        }
    });

    if (connection) {
#if DEBUG
        self.connectionReuseCount++;
#endif
        return connection;
    }

    HttpdnsNWReusableConnection *newConnection = [[HttpdnsNWReusableConnection alloc] initWithClient:self
                                                                                                 host:host
                                                                                                 port:port
                                                                                               useTLS:useTLS];
    if (!newConnection) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create network connection"}];
        }
        return nil;
    }

    if (![newConnection openWithTimeout:timeout error:error]) {
        [newConnection invalidate];
        return nil;
    }

#if DEBUG
    self.connectionCreationCount++;
#endif

    newConnection.inUse = YES;
    newConnection.lastUsedDate = now;

    dispatch_sync(self.poolQueue, ^{
        NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
        if (!pool) {
            pool = [NSMutableArray array];
            self.connectionPool[key] = pool;
        }
        [pool addObject:newConnection];
        [self pruneConnectionPool:pool referenceDate:[NSDate date]];
    });

    return newConnection;
}

- (void)returnConnection:(HttpdnsNWReusableConnection *)connection
                   forKey:(NSString *)key
              shouldClose:(BOOL)shouldClose {
    if (!connection || !key) {
        return;
    }

    NSDate *now = [NSDate date];
    dispatch_async(self.poolQueue, ^{
        NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
        if (!pool) {
            pool = [NSMutableArray array];
            self.connectionPool[key] = pool;
        }

        if (shouldClose || connection.isInvalidated) {
            [connection invalidate];
            [pool removeObject:connection];
        } else {
            connection.inUse = NO;
            connection.lastUsedDate = now;
            if (![pool containsObject:connection]) {
                [pool addObject:connection];
            }
            [self pruneConnectionPool:pool referenceDate:now];
        }

        if (pool.count == 0) {
            [self.connectionPool removeObjectForKey:key];
        }
    });
}

- (void)pruneConnectionPool:(NSMutableArray<HttpdnsNWReusableConnection *> *)pool referenceDate:(NSDate *)referenceDate {
    if (!pool || pool.count == 0) {
        return;
    }

    NSTimeInterval idleLimit = kHttpdnsNWHTTPClientIdleConnectionTimeout;
    for (NSInteger idx = (NSInteger)pool.count - 1; idx >= 0; idx--) {
        HttpdnsNWReusableConnection *candidate = pool[(NSUInteger)idx];
        if (!candidate) {
            [pool removeObjectAtIndex:(NSUInteger)idx];
            continue;
        }
        NSDate *lastUsed = candidate.lastUsedDate ?: [NSDate distantPast];
        BOOL expired = !candidate.inUse && referenceDate && [referenceDate timeIntervalSinceDate:lastUsed] > idleLimit;
        if (candidate.isInvalidated || expired) {
            [candidate invalidate];
            [pool removeObjectAtIndex:(NSUInteger)idx];
        }
    }

    if (pool.count <= kHttpdnsNWHTTPClientMaxIdleConnectionsPerKey) {
        return;
    }

    while (pool.count > kHttpdnsNWHTTPClientMaxIdleConnectionsPerKey) {
        NSInteger removeIndex = NSNotFound;
        NSDate *oldestDate = nil;
        for (NSInteger idx = 0; idx < (NSInteger)pool.count; idx++) {
            HttpdnsNWReusableConnection *candidate = pool[(NSUInteger)idx];
            if (candidate.inUse) {
                continue;
            }
            NSDate *candidateDate = candidate.lastUsedDate ?: [NSDate distantPast];
            if (!oldestDate || [candidateDate compare:oldestDate] == NSOrderedAscending) {
                oldestDate = candidateDate;
                removeIndex = idx;
            }
        }
        if (removeIndex == NSNotFound) {
            break;
        }
        HttpdnsNWReusableConnection *candidate = pool[(NSUInteger)removeIndex];
        [candidate invalidate];
        [pool removeObjectAtIndex:(NSUInteger)removeIndex];
    }
}

- (NSString *)buildHTTPRequestStringWithURL:(NSURL *)url userAgent:(NSString *)userAgent {
    NSString *pathComponent = url.path.length > 0 ? url.path : @"/";
    NSMutableString *path = [NSMutableString stringWithString:pathComponent];
    if (url.query.length > 0) {
        [path appendFormat:@"?%@", url.query];
    }

    BOOL isTLS = [[url.scheme lowercaseString] isEqualToString:@"https"];
    NSInteger portValue = url.port ? url.port.integerValue : (isTLS ? 443 : 80);
    BOOL isDefaultPort = (!url.port) || (isTLS && portValue == 443) || (!isTLS && portValue == 80);

    NSMutableString *hostHeader = [NSMutableString stringWithString:url.host ?: @""];
    if (!isDefaultPort && url.port) {
        [hostHeader appendFormat:@":%@", url.port];
    }

    NSMutableString *request = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\n", path];
    [request appendFormat:@"Host: %@\r\n", hostHeader];
    if ([HttpdnsUtil isNotEmptyString:userAgent]) {
        [request appendFormat:@"User-Agent: %@\r\n", userAgent];
    }
    [request appendString:@"Accept: application/json\r\n"];
    [request appendString:@"Accept-Encoding: identity\r\n"];
    [request appendString:@"Connection: keep-alive\r\n\r\n"];
    return request;
}

- (HttpdnsHTTPHeaderParseResult)tryParseHTTPHeadersInData:(NSData *)data
                                          headerEndIndex:(NSUInteger *)headerEndIndex
                                              statusCode:(NSInteger *)statusCode
                                                 headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                                                   error:(NSError **)error {
    if (!data || data.length == 0) {
        return HttpdnsHTTPHeaderParseResultIncomplete;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger headerEnd = NSNotFound;
    for (NSUInteger idx = 0; idx + 3 < length; idx++) {
        if (bytes[idx] == '\r' && bytes[idx + 1] == '\n' && bytes[idx + 2] == '\r' && bytes[idx + 3] == '\n') {
            headerEnd = idx;
            break;
        }
    }

    if (headerEnd == NSNotFound) {
        return HttpdnsHTTPHeaderParseResultIncomplete;
    }

    if (headerEndIndex) {
        *headerEndIndex = headerEnd;
    }

    NSData *headerData = [data subdataWithRange:NSMakeRange(0, headerEnd)];
    NSString *headerString = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (![HttpdnsUtil isNotEmptyString:headerString]) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to decode HTTP headers"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing HTTP status line"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSString *statusLine = lines.firstObject;
    NSArray<NSString *> *statusParts = [statusLine componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *filteredParts = [NSMutableArray array];
    for (NSString *component in statusParts) {
        if (component.length > 0) {
            [filteredParts addObject:component];
        }
    }

    if (filteredParts.count < 2) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid HTTP status line"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSInteger localStatus = [filteredParts[1] integerValue];
    if (localStatus <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid HTTP status code"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSMutableDictionary<NSString *, NSString *> *headerDict = [NSMutableDictionary dictionary];
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSUInteger idx = 1; idx < lines.count; idx++) {
        NSString *line = lines[idx];
        if (line.length == 0) {
            continue;
        }
        NSRange colonRange = [line rangeOfString:@":"];
        if (colonRange.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:colonRange.location] stringByTrimmingCharactersInSet:trimSet];
        NSString *value = [[line substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:trimSet];
        if (key.length > 0) {
            headerDict[[key lowercaseString]] = value ?: @"";
        }
    }

    if (statusCode) {
        *statusCode = localStatus;
    }
    if (headers) {
        *headers = [headerDict copy];
    }
    return HttpdnsHTTPHeaderParseResultSuccess;
}

- (HttpdnsHTTPChunkParseResult)checkChunkedBodyCompletionInData:(NSData *)data
                                                 headerEndIndex:(NSUInteger)headerEndIndex
                                                         error:(NSError **)error {
    if (!data || headerEndIndex == NSNotFound) {
        return HttpdnsHTTPChunkParseResultIncomplete;
    }

    NSUInteger length = data.length;
    NSUInteger cursor = headerEndIndex + 4;
    if (cursor > length) {
        return HttpdnsHTTPChunkParseResultIncomplete;
    }

    const uint8_t *bytes = data.bytes;
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    while (cursor < length) {
        NSUInteger lineEnd = cursor;
        while (lineEnd + 1 < length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) {
            lineEnd++;
        }
        if (lineEnd + 1 >= length) {
            return HttpdnsHTTPChunkParseResultIncomplete;
        }

        NSData *sizeData = [data subdataWithRange:NSMakeRange(cursor, lineEnd - cursor)];
        NSString *sizeString = [[NSString alloc] initWithData:sizeData encoding:NSUTF8StringEncoding];
        if (![HttpdnsUtil isNotEmptyString:sizeString]) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk size"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }

        NSString *trimmed = [[sizeString componentsSeparatedByString:@";"] firstObject];
        trimmed = [trimmed stringByTrimmingCharactersInSet:trimSet];
        const char *cStr = trimmed.UTF8String;
        char *endPtr = NULL;
        unsigned long long chunkSize = strtoull(cStr, &endPtr, 16);
        if (endPtr == NULL || endPtr == cStr) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk size"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }

        if (chunkSize > NSUIntegerMax - cursor) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Chunk size overflow"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }

        cursor = lineEnd + 2;
        if (chunkSize == 0) {
            NSUInteger trailerCursor = cursor;
            while (YES) {
                if (trailerCursor + 1 >= length) {
                    return HttpdnsHTTPChunkParseResultIncomplete;
                }
                NSUInteger trailerLineEnd = trailerCursor;
                while (trailerLineEnd + 1 < length && !(bytes[trailerLineEnd] == '\r' && bytes[trailerLineEnd + 1] == '\n')) {
                    trailerLineEnd++;
                }
                if (trailerLineEnd + 1 >= length) {
                    return HttpdnsHTTPChunkParseResultIncomplete;
                }
                if (trailerLineEnd == trailerCursor) {
                    return HttpdnsHTTPChunkParseResultSuccess;
                }
                trailerCursor = trailerLineEnd + 2;
            }
        }

        if (cursor + (NSUInteger)chunkSize > length) {
            return HttpdnsHTTPChunkParseResultIncomplete;
        }
        cursor += (NSUInteger)chunkSize;
        if (cursor + 1 >= length) {
            return HttpdnsHTTPChunkParseResultIncomplete;
        }
        if (bytes[cursor] != '\r' || bytes[cursor + 1] != '\n') {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk terminator"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }
        cursor += 2;
    }

    return HttpdnsHTTPChunkParseResultIncomplete;
}

- (BOOL)parseHTTPResponseData:(NSData *)data
                   statusCode:(NSInteger *)statusCode
                      headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                         body:(NSData *__autoreleasing *)body
                        error:(NSError **)error {
    if (!data || data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty HTTP response"}];
        }
        return NO;
    }

    NSUInteger headerEnd = NSNotFound;
    NSInteger localStatus = 0;
    NSDictionary<NSString *, NSString *> *headerDict = nil;
    NSError *headerError = nil;
    HttpdnsHTTPHeaderParseResult headerResult = [self tryParseHTTPHeadersInData:data
                                                                headerEndIndex:&headerEnd
                                                                    statusCode:&localStatus
                                                                       headers:&headerDict
                                                                         error:&headerError];
    if (headerResult != HttpdnsHTTPHeaderParseResultSuccess) {
        if (error) {
            if (headerResult == HttpdnsHTTPHeaderParseResultIncomplete) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing HTTP header terminator"}];
            } else {
                *error = headerError;
            }
        }
        return NO;
    }

    NSUInteger bodyStart = headerEnd + 4;
    NSData *bodyData = bodyStart <= data.length ? [data subdataWithRange:NSMakeRange(bodyStart, data.length - bodyStart)] : [NSData data];

    NSString *transferEncoding = headerDict[@"transfer-encoding"];
    if ([HttpdnsUtil isNotEmptyString:transferEncoding] && [transferEncoding rangeOfString:@"chunked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSError *chunkError = nil;
        NSData *decoded = [self decodeChunkedBody:bodyData error:&chunkError];
        if (!decoded) {
            HttpdnsLogDebug("Chunked decode failed, fallback to raw body, error: %@", chunkError);
            decoded = bodyData;
        }
        bodyData = decoded;
    } else {
        NSString *contentLengthValue = headerDict[@"content-length"];
        if ([HttpdnsUtil isNotEmptyString:contentLengthValue]) {
            long long expected = [contentLengthValue longLongValue];
            if (expected >= 0 && (NSUInteger)expected != bodyData.length) {
                HttpdnsLogDebug("Content-Length mismatch, expected: %lld, actual: %lu", expected, (unsigned long)bodyData.length);
            }
        }
    }

    if (statusCode) {
        *statusCode = localStatus;
    }
    if (headers) {
        *headers = headerDict ?: @{};
    }
    if (body) {
        *body = bodyData;
    }
    return YES;
}

- (NSData *)decodeChunkedBody:(NSData *)bodyData error:(NSError **)error {
    if (!bodyData) {
        return [NSData data];
    }

    const uint8_t *bytes = bodyData.bytes;
    NSUInteger length = bodyData.length;
    NSUInteger cursor = 0;
    NSMutableData *decoded = [NSMutableData data];
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    while (cursor < length) {
        NSUInteger lineEnd = cursor;
        while (lineEnd + 1 < length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) {
            lineEnd++;
        }
        if (lineEnd + 1 >= length) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunked encoding"}];
            }
            return nil;
        }

        NSData *sizeData = [bodyData subdataWithRange:NSMakeRange(cursor, lineEnd - cursor)];
        NSString *sizeString = [[NSString alloc] initWithData:sizeData encoding:NSUTF8StringEncoding];
        if (![HttpdnsUtil isNotEmptyString:sizeString]) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk size"}];
            }
            return nil;
        }
        NSString *trimmed = [[sizeString componentsSeparatedByString:@";"] firstObject];
        trimmed = [trimmed stringByTrimmingCharactersInSet:trimSet];
        const char *cStr = trimmed.UTF8String;
        char *endPtr = NULL;
        unsigned long chunkSize = strtoul(cStr, &endPtr, 16);
        // 检查是否是无效的十六进制字符串
        if (endPtr == cStr) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk size format"}];
            }
            return nil;
        }
        cursor = lineEnd + 2;
        if (chunkSize == 0) {
            if (cursor + 1 < length) {
                cursor += 2;
            }
            break;
        }
        if (cursor + chunkSize > length) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Chunk size exceeds buffer"}];
            }
            return nil;
        }
        [decoded appendBytes:bytes + cursor length:chunkSize];
        cursor += chunkSize;
        if (cursor + 1 >= length || bytes[cursor] != '\r' || bytes[cursor + 1] != '\n') {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk terminator"}];
            }
            return nil;
        }
        cursor += 2;
    }

    return decoded;
}

- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain {
    // 测试专用：通过环境变量跳过 TLS 验证
    // 仅在设置 HTTPDNS_SKIP_TLS_VERIFY 环境变量时生效（用于本地 mock server 测试）
    if (getenv("HTTPDNS_SKIP_TLS_VERIFY") != NULL) {
        return YES;
    }

    // 生产环境标准 TLS 验证流程
    NSMutableArray *policies = [NSMutableArray array];
    if (domain) {
        [policies addObject:(__bridge_transfer id) SecPolicyCreateSSL(true, (__bridge CFStringRef) domain)];
    } else {
        [policies addObject:(__bridge_transfer id) SecPolicyCreateBasicX509()];
    }
    SecTrustSetPolicies(serverTrust, (__bridge CFArrayRef) policies);
    SecTrustResultType result;
    SecTrustEvaluate(serverTrust, &result);
    if (result == kSecTrustResultRecoverableTrustFailure) {
        CFDataRef errDataRef = SecTrustCopyExceptions(serverTrust);
        SecTrustSetExceptions(serverTrust, errDataRef);
        SecTrustEvaluate(serverTrust, &result);
    }
    return (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
}

+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if ([HttpdnsUtil isNotEmptyString:description]) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    if (nwError) {
        CFErrorRef cfError = nw_error_copy_cf_error(nwError);
        if (cfError) {
            NSError *underlyingError = CFBridgingRelease(cfError);
            if (underlyingError) {
                userInfo[NSUnderlyingErrorKey] = underlyingError;
                if (!userInfo[NSLocalizedDescriptionKey] && underlyingError.localizedDescription) {
                    userInfo[NSLocalizedDescriptionKey] = underlyingError.localizedDescription;
                }
            }
        }
    }
    if (!userInfo[NSLocalizedDescriptionKey]) {
        userInfo[NSLocalizedDescriptionKey] = @"Network operation failed";
    }
    return [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                               code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                           userInfo:userInfo];
}

@end

#if DEBUG
// 测试专用：连接池检查 API 实现
@implementation HttpdnsNWHTTPClient (TestInspection)

- (NSUInteger)connectionPoolCountForKey:(NSString *)key {
    __block NSUInteger count = 0;
    dispatch_sync(self.poolQueue, ^{
        NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
        count = pool ? pool.count : 0;
    });
    return count;
}

- (NSArray<NSString *> *)allConnectionPoolKeys {
    __block NSArray<NSString *> *keys = nil;
    dispatch_sync(self.poolQueue, ^{
        keys = [self.connectionPool.allKeys copy];
    });
    return keys ?: @[];
}

- (NSUInteger)totalConnectionCount {
    __block NSUInteger total = 0;
    dispatch_sync(self.poolQueue, ^{
        for (NSMutableArray *pool in self.connectionPool.allValues) {
            total += pool.count;
        }
    });
    return total;
}

- (void)resetPoolStatistics {
    self.connectionCreationCount = 0;
    self.connectionReuseCount = 0;
}

@end
#endif
