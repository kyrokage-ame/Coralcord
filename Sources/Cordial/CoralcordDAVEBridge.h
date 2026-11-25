#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Serializes libdave calls and never permits media pass-through.
@interface CoralcordDAVEBridge : NSObject
- (nullable instancetype)initWithSelfUserID:(NSString *)userID error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)initializeGroupWithID:(uint64_t)groupID version:(uint16_t)version error:(NSError **)error;
- (void)setExternalSenderData:(NSData *)data error:(NSError **)error;
- (void)addRecognizedUser:(NSString *)userID error:(NSError **)error;
- (void)removeRecognizedUser:(NSString *)userID;
- (NSData *)keyPackageData:(NSError **)error;
- (NSData *)processProposals:(NSData *)data error:(NSError **)error;
- (void)processCommit:(NSData *)data error:(NSError **)error;
- (void)processWelcome:(NSData *)data error:(NSError **)error;
- (NSData *)encryptFrame:(NSData *)frame ssrc:(uint32_t)ssrc error:(NSError **)error;
- (NSData *)decryptFrame:(NSData *)frame userID:(NSString *)userID error:(NSError **)error;
- (BOOL)isSenderReady;
@end

NS_ASSUME_NONNULL_END
