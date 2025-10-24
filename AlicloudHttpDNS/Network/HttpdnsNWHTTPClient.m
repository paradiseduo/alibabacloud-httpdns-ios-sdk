#import "HttpdnsNWHTTPClient.h"

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

@interface HttpdnsNWHTTPClient ()

- (NSString *)buildHTTPRequestStringWithURL:(NSURL *)url userAgent:(NSString *)userAgent;
- (BOOL)parseHTTPResponseData:(NSData *)data
                   statusCode:(NSInteger *)statusCode
                      headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                         body:(NSData *__autoreleasing *)body
                        error:(NSError **)error;
- (NSData *)decodeChunkedBody:(NSData *)bodyData error:(NSError **)error;
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain;
+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description;

@end

@implementation HttpdnsNWHTTPClient

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

    timeout = timeout > 0 ? timeout : 10.0;

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

    dispatch_queue_t queue = dispatch_queue_create("com.alibaba.sdk.httpdns.network.connection", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSMutableData *responseBuffer = [NSMutableData data];
    __block NSError *blockError = nil;
    __block BOOL finished = NO;
    __block BOOL hasResponse = NO;
    __block BOOL signaled = NO;

    dispatch_block_t signalIfNeeded = ^{
        if (!signaled) {
            signaled = YES;
            dispatch_semaphore_signal(semaphore);
        }
    };

    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, portString.UTF8String);
    if (!endpoint) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create endpoint"}];
        }
        return nil;
    }

    __weak typeof(self) weakSelf = self;
    nw_parameters_t parameters = NULL;
    if (useTLS) {
        parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tlsOptions) {
            if (!tlsOptions) {
                return;
            }
            sec_protocol_options_t secOptions = nw_tls_copy_sec_protocol_options(tlsOptions);
            if (secOptions) {
                if (![HttpdnsUtil isIPv4Address:host] && ![HttpdnsUtil isIPv6Address:host]) {
                    sec_protocol_options_set_tls_server_name(secOptions, host.UTF8String);
                }
                sec_protocol_options_set_verify_block(secOptions, ^(sec_protocol_metadata_t metadata, sec_trust_t secTrust, sec_protocol_verify_complete_t complete) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    BOOL isValid = NO;
                    if (secTrust && strongSelf) {
                        SecTrustRef trustRef = sec_trust_copy_ref(secTrust);
                        if (trustRef) {
                            NSString *validIP = ALICLOUD_HTTPDNS_VALID_SERVER_CERTIFICATE_IP;
                            isValid = [strongSelf evaluateServerTrust:trustRef forDomain:validIP];
                            if (!isValid && [HttpdnsUtil isNotEmptyString:host]) {
                                isValid = [strongSelf evaluateServerTrust:trustRef forDomain:host];
                            }
                            if (!isValid && !blockError) {
                                blockError = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                                 code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                             userInfo:@{NSLocalizedDescriptionKey: @"TLS trust validation failed"}];
                            }
                            CFRelease(trustRef);
                        }
                    }
                    complete(isValid);
                }, queue);
            }
        }, ^(nw_protocol_options_t tcpOptions) {
            nw_tcp_options_set_no_delay(tcpOptions, true);
        });
    } else {
        parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcpOptions) {
            nw_tcp_options_set_no_delay(tcpOptions, true);
        });
    }

    if (!parameters) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create network parameters"}];
        }
        return nil;
    }

    nw_connection_t connection = nw_connection_create(endpoint, parameters);
    if (!connection) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create network connection"}];
        }
        return nil;
    }

    nw_connection_set_queue(connection, queue);

    dispatch_data_t requestPayload = dispatch_data_create(requestData.bytes, requestData.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);

    __block void (^receiveBlock)(dispatch_data_t, nw_content_context_t, bool, nw_error_t);
    __block __weak void (^weakReceiveBlock)(dispatch_data_t, nw_content_context_t, bool, nw_error_t);
    receiveBlock = ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t receiveError) {
        if (receiveError && !blockError) {
            blockError = [HttpdnsNWHTTPClient errorFromNWError:receiveError description:@"Receive failed"];
            nw_connection_cancel(connection);
        }
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                if (buffer && size > 0) {
                    [responseBuffer appendBytes:buffer length:size];
                    hasResponse = YES;
                }
                return true;
            });
        }
        if (is_complete) {
            finished = YES;
            signalIfNeeded();
        } else if (!receiveError) {
            void (^callback)(dispatch_data_t, nw_content_context_t, bool, nw_error_t) = weakReceiveBlock;
            if (callback) {
                nw_connection_receive(connection, 1, UINT32_MAX, callback);
            }
        }
    };
    // 通过弱引用避免接收回调相互持有导致循环引用
    weakReceiveBlock = receiveBlock;

    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t stateError) {
        switch (state) {
            case nw_connection_state_ready: {
                nw_connection_send(connection, requestPayload, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {
                    if (sendError && !blockError) {
                        blockError = [HttpdnsNWHTTPClient errorFromNWError:sendError description:@"Send failed"];
                        nw_connection_cancel(connection);
                        return;
                    }
                    nw_connection_receive(connection, 1, UINT32_MAX, receiveBlock);
                });
                break;
            }
            case nw_connection_state_failed: {
                if (stateError && !blockError) {
                    blockError = [HttpdnsNWHTTPClient errorFromNWError:stateError description:@"Connection failed"];
                }
                finished = YES;
                signalIfNeeded();
                break;
            }
            case nw_connection_state_cancelled: {
                finished = YES;
                signalIfNeeded();
                break;
            }
            default:
                break;
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), queue, ^{
        if (!finished) {
            if (!blockError) {
                blockError = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                 code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                             userInfo:@{NSLocalizedDescriptionKey: @"Network request timed out"}];
            }
            nw_connection_cancel(connection);
        }
    });

    nw_connection_start(connection);
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    nw_connection_cancel(connection);

    if (blockError) {
        if (error) {
            *error = blockError;
        }
        return nil;
    }

    if (!hasResponse) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty HTTP response"}];
        }
        return nil;
    }

    NSInteger statusCode = 0;
    NSDictionary<NSString *, NSString *> *headers = nil;
    NSData *bodyData = nil;
    NSError *parseError = nil;
    if (![self parseHTTPResponseData:responseBuffer statusCode:&statusCode headers:&headers body:&bodyData error:&parseError]) {
        if (error) {
            *error = parseError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                       code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse HTTP response"}];
        }
        return nil;
    }

    HttpdnsNWHTTPClientResponse *response = [HttpdnsNWHTTPClientResponse new];
    response.statusCode = statusCode;
    response.headers = headers ?: @{};
    response.body = bodyData ?: [NSData data];
    return response;
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
    [request appendString:@"Connection: close\r\n\r\n"];
    return request;
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
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing HTTP header terminator"}];
        }
        return NO;
    }

    NSData *headerData = [data subdataWithRange:NSMakeRange(0, headerEnd)];
    NSString *headerString = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (![HttpdnsUtil isNotEmptyString:headerString]) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to decode HTTP headers"}];
        }
        return NO;
    }

    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing HTTP status line"}];
        }
        return NO;
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
        return NO;
    }

    NSInteger localStatus = [filteredParts[1] integerValue];
    if (localStatus <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid HTTP status code"}];
        }
        return NO;
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

    NSUInteger bodyStart = headerEnd + 4;
    NSData *bodyData = bodyStart <= length ? [data subdataWithRange:NSMakeRange(bodyStart, length - bodyStart)] : [NSData data];

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
        *headers = headerDict;
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
        unsigned long chunkSize = strtoul(trimmed.UTF8String, NULL, 16);
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
