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

- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain;
- (HttpdnsHTTPHeaderParseResult)tryParseHTTPHeadersInData:(NSData *)data
                                          headerEndIndex:(NSUInteger *)headerEndIndex
                                              statusCode:(NSInteger *)statusCode
                                                 headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                                                   error:(NSError **)error;
- (HttpdnsHTTPChunkParseResult)checkChunkedBodyCompletionInData:(NSData *)data
                                                 headerEndIndex:(NSUInteger)headerEndIndex
                                                         error:(NSError **)error;
+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description;

@end

NS_ASSUME_NONNULL_END
