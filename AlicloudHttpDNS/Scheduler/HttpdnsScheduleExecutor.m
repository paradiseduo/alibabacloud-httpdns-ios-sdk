//
//  HttpdnsScheduleExecutor.m
//  AlicloudHttpDNS
//
//  Created by ElonChan（地风） on 2017/4/11.
//  Copyright © 2017年 alibaba-inc.com. All rights reserved.
//

#import "HttpdnsScheduleExecutor.h"
#import "HttpdnsLog_Internal.h"
#import "HttpdnsService_Internal.h"
#import "HttpdnsInternalConstant.h"
#import "HttpdnsUtil.h"
#import "HttpdnsScheduleCenter.h"
#import "HttpdnsHostObject.h"
#import "HttpdnsReachability.h"
#import "HttpdnsPublicConstant.h"
#import "HttpdnsNWHTTPClient.h"

@interface HttpdnsScheduleExecutor ()
@property (nonatomic, strong) HttpdnsNWHTTPClient *httpClient;
@end

@implementation HttpdnsScheduleExecutor {
    NSInteger _accountId;
    NSTimeInterval _timeoutInterval;
}

- (instancetype)init {
    if (!(self = [super init])) {
        return nil;
    }
    // 兼容旧路径：使用全局单例读取，但多账号场景下建议使用新init接口
    _accountId = [HttpDnsService sharedInstance].accountID;
    _timeoutInterval = [HttpDnsService sharedInstance].timeoutInterval;
    _httpClient = [HttpdnsNWHTTPClient new];
    return self;
}

- (instancetype)initWithAccountId:(NSInteger)accountId timeout:(NSTimeInterval)timeoutInterval {
    if (!(self = [self init])) {
        return nil;
    }
    _accountId = accountId;
    _timeoutInterval = timeoutInterval;
    return self;
}

/**
 * 拼接 URL
 * 2024.6.12今天起，调度服务由后端就近调度，不再需要传入region参数，但为了兼容不传region默认就是国内region的逻辑，默认都传入region=global
 * https://203.107.1.1/100000/ss?region=global&platform=ios&sdk_version=3.1.7&sid=LpmJIA2CUoi4&net=wifi
 */
- (NSString *)constructRequestURLWithUpdateHost:(NSString *)updateHost {
    NSString *urlPath = [NSString stringWithFormat:@"%ld/ss?region=global&platform=ios&sdk_version=%@", (long)_accountId, HTTPDNS_IOS_SDK_VERSION];
    urlPath = [self urlFormatSidNetBssid:urlPath];
    urlPath = [urlPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"`#%^{}\"[]|\\<> "].invertedSet];
    return [NSString stringWithFormat:@"https://%@/%@", updateHost, urlPath];
}

// url 添加 sid net
- (NSString *)urlFormatSidNetBssid:(NSString *)url {
    NSString *sessionId = [HttpdnsUtil generateSessionID];
    if ([HttpdnsUtil isNotEmptyString:sessionId]) {
        url = [NSString stringWithFormat:@"%@&sid=%@", url, sessionId];
    }

    NSString *netType = [[HttpdnsReachability sharedInstance] currentReachabilityString];
    if ([HttpdnsUtil isNotEmptyString:netType]) {
        url = [NSString stringWithFormat:@"%@&net=%@", url, netType];
    }
    return url;
}

- (NSDictionary *)fetchRegionConfigFromServer:(NSString *)updateHost error:(NSError **)pError {
    NSString *fullUrlStr = [self constructRequestURLWithUpdateHost:updateHost];
    HttpdnsLogDebug("ScRequest URL: %@", fullUrlStr);
    NSTimeInterval timeout = _timeoutInterval > 0 ? _timeoutInterval : HTTPDNS_DEFAULT_REQUEST_TIMEOUT_INTERVAL;
    NSString *userAgent = [HttpdnsUtil generateUserAgent];

    NSError *requestError = nil;
    HttpdnsNWHTTPClientResponse *response = [self.httpClient performRequestWithURLString:fullUrlStr
                                                                               userAgent:userAgent
                                                                                 timeout:timeout
                                                                                   error:&requestError];
    if (!response) {
        if (pError) {
            *pError = requestError;
            HttpdnsLogDebug("ScRequest failed with url: %@, error: %@", fullUrlStr, requestError);
        }
        return nil;
    }

    if (response.statusCode != 200) {
        NSDictionary *dict = @{@"ResponseCode": [NSString stringWithFormat:@"%ld", (long)response.statusCode]};
        if (pError) {
            *pError = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                          code:ALICLOUD_HTTPDNS_HTTPS_NO_DATA_ERROR_CODE
                                      userInfo:dict];
        }
        return nil;
    }

    NSError *jsonError = nil;
    id jsonValue = [NSJSONSerialization JSONObjectWithData:response.body options:kNilOptions error:&jsonError];
    if (jsonError) {
        if (pError) {
            *pError = jsonError;
            HttpdnsLogDebug("ScRequest JSON parse error, url: %@, error: %@", fullUrlStr, jsonError);
        }
        return nil;
    }

    NSDictionary *result = [HttpdnsUtil getValidDictionaryFromJson:jsonValue];
    if (result) {
        HttpdnsLogDebug("ScRequest get response: %@", result);
        return result;
    }

    if (pError) {
        *pError = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                      code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                  userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse JSON response"}];
    }
    if (pError != NULL) {
        HttpdnsLogDebug("ScRequest failed with url: %@, response body invalid", fullUrlStr);
    }
    return nil;
}

@end
