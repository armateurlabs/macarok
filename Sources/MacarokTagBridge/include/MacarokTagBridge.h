#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCTagDocument : NSObject
@property(nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *properties;
@property(nonatomic, copy, nullable) NSData *artworkData;
@property(nonatomic, copy, nullable) NSString *artworkMIMEType;
@property(nonatomic, copy, nullable) NSString *errorMessage;
@property(nonatomic, copy) NSString *format;
@property(nonatomic) double duration;
@property(nonatomic) NSInteger sampleRate;
@property(nonatomic) NSInteger channels;
@property(nonatomic) NSInteger bitsPerSample;
@end

FOUNDATION_EXPORT MCTagDocument *MCReadTags(NSURL *url);

/// Returns an error message, or nil on success. Only supplied properties change.
FOUNDATION_EXPORT NSString *_Nullable MCWriteTags(
    NSURL *url,
    NSDictionary<NSString *, NSString *> *properties,
    NSData *_Nullable artworkData,
    NSString *_Nullable artworkMIMEType
);

NS_ASSUME_NONNULL_END
