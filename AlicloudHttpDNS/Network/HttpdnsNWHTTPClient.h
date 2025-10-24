#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HttpdnsNWHTTPClientResponse : NSObject

@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSData *body;

@end

@interface HttpdnsNWHTTPClient : NSObject

- (nullable HttpdnsNWHTTPClientResponse *)performRequestWithURLString:(NSString *)urlString
                                                            userAgent:(NSString *)userAgent
                                                              timeout:(NSTimeInterval)timeout
                                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

