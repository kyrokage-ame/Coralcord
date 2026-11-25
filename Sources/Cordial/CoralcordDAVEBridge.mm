#import "CoralcordDAVEBridge.h"

#include "../../Vendor/libdave/include/dave/dave.h"

#include <dispatch/dispatch.h>
#include <string>
#include <unordered_set>
#include <vector>

static NSString * const CoralcordDAVEErrorDomain = @"app.coralcord.dave";

static NSError *CoralcordMakeDAVEError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:CoralcordDAVEErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSData *CoralcordCopyBytes(const uint8_t *bytes, size_t length) {
    if (length == 0) return [NSData data];
    if (bytes == nullptr) return nil;
    return [NSData dataWithBytes:bytes length:length];
}

@implementation CoralcordDAVEBridge {
    DAVESessionHandle _session;
    DAVEEncryptorHandle _encryptor;
    DAVEKeyRatchetHandle _senderRatchet;
    dispatch_queue_t _queue;
    NSString *_selfUserID;
    NSMutableDictionary<NSString *, NSValue *> *_decryptors;
    NSMutableDictionary<NSString *, NSValue *> *_decryptorRatchets;
    NSMutableSet<NSString *> *_recognizedUsers;
    std::unordered_set<uint32_t> _assignedSSRCs;
    BOOL _groupInitialized;
}

- (nullable instancetype)initWithSelfUserID:(NSString *)userID error:(NSError **)error {
    if (userID.length == 0) {
        if (error) *error = CoralcordMakeDAVEError(1, @"The Discord user ID is empty.");
        return nil;
    }
    self = [super init];
    if (!self) return nil;

    _queue = dispatch_queue_create("app.coralcord.dave.serial", DISPATCH_QUEUE_SERIAL);
    _selfUserID = [userID copy];
    _decryptors = [[NSMutableDictionary alloc] init];
    _decryptorRatchets = [[NSMutableDictionary alloc] init];
    _recognizedUsers = [[NSMutableSet alloc] initWithObjects:userID, nil];
    _session = daveSessionCreate(nullptr, nullptr, nullptr, nullptr);
    _encryptor = daveEncryptorCreate();
    if (_session == nullptr || _encryptor == nullptr) {
        if (_session != nullptr) daveSessionDestroy(_session);
        if (_encryptor != nullptr) daveEncryptorDestroy(_encryptor);
        _session = nullptr;
        _encryptor = nullptr;
        if (error) *error = CoralcordMakeDAVEError(2, @"libdave could not create its MLS session or frame encryptor.");
        [self release];
        return nil;
    }
    // DAVE passthrough is never allowed: a missing MLS key must stop media rather than leak Opus.
    daveEncryptorSetPassthroughMode(_encryptor, false);
    return self;
}

- (void)dealloc {
    dispatch_sync(_queue, ^{
        for (NSValue *value in self->_decryptors.allValues) {
            DAVEDecryptorHandle decryptor = (DAVEDecryptorHandle)value.pointerValue;
            if (decryptor != nullptr) daveDecryptorDestroy(decryptor);
        }
        for (NSValue *value in self->_decryptorRatchets.allValues) {
            DAVEKeyRatchetHandle ratchet = (DAVEKeyRatchetHandle)value.pointerValue;
            if (ratchet != nullptr) daveKeyRatchetDestroy(ratchet);
        }
        if (self->_encryptor != nullptr) {
            daveEncryptorSetKeyRatchet(self->_encryptor, nullptr);
            daveEncryptorDestroy(self->_encryptor);
        }
        if (self->_senderRatchet != nullptr) daveKeyRatchetDestroy(self->_senderRatchet);
        if (self->_session != nullptr) daveSessionDestroy(self->_session);
        self->_senderRatchet = nullptr;
        self->_encryptor = nullptr;
        self->_session = nullptr;
    });
    [_selfUserID release];
    [_decryptors release];
    [_decryptorRatchets release];
    [_recognizedUsers release];
    [super dealloc];
}

- (void)clearMediaStateLocked {
    for (NSString *userID in _recognizedUsers) {
        if (![userID isEqualToString:_selfUserID]) {
            daveSessionRemoveRecognizedUser(_session, userID.UTF8String);
        }
    }
    for (NSValue *value in _decryptors.allValues) {
        DAVEDecryptorHandle decryptor = (DAVEDecryptorHandle)value.pointerValue;
        if (decryptor != nullptr) daveDecryptorDestroy(decryptor);
    }
    for (NSValue *value in _decryptorRatchets.allValues) {
        DAVEKeyRatchetHandle ratchet = (DAVEKeyRatchetHandle)value.pointerValue;
        if (ratchet != nullptr) daveKeyRatchetDestroy(ratchet);
    }
    [_decryptors removeAllObjects];
    [_decryptorRatchets removeAllObjects];
    [_recognizedUsers removeAllObjects];
    [_recognizedUsers addObject:_selfUserID];
    if (_senderRatchet != nullptr) {
        daveEncryptorSetKeyRatchet(_encryptor, nullptr);
        daveKeyRatchetDestroy(_senderRatchet);
        _senderRatchet = nullptr;
    }
    _assignedSSRCs.clear();
}

- (void)initializeGroupWithID:(uint64_t)groupID version:(uint16_t)version error:(NSError **)error {
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (groupID == 0 || version == 0 || version > daveMaxSupportedProtocolVersion()) {
            failure = CoralcordMakeDAVEError(3, @"The DAVE group ID or negotiated protocol version is invalid or unsupported.");
            return;
        }
        [self clearMediaStateLocked];
        self->_groupInitialized = NO;
        daveSessionInit(self->_session, version, groupID, self->_selfUserID.UTF8String);
        daveSessionSetProtocolVersion(self->_session, version);
        self->_groupInitialized = YES;
        daveEncryptorSetPassthroughMode(self->_encryptor, false);
    });
    if (error) *error = failure;
}

- (void)setExternalSenderData:(NSData *)data error:(NSError **)error {
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized || data.length == 0) {
            failure = CoralcordMakeDAVEError(4, @"Cannot install an empty external sender before initializing the DAVE group.");
            return;
        }
        daveSessionSetExternalSender(self->_session, (const uint8_t *)data.bytes, data.length);
    });
    if (error) *error = failure;
}

- (void)addRecognizedUser:(NSString *)userID error:(NSError **)error {
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized || userID.length == 0) {
            failure = CoralcordMakeDAVEError(5, @"Cannot add an empty or pre-session DAVE participant.");
            return;
        }
        daveSessionAddRecognizedUser(self->_session, userID.UTF8String);
        [self->_recognizedUsers addObject:userID];
        [self refreshRatchetsLocked];
    });
    if (error) *error = failure;
}

- (void)removeRecognizedUser:(NSString *)userID {
    if (userID.length == 0 || [userID isEqualToString:_selfUserID]) return;
    dispatch_sync(_queue, ^{
        daveSessionRemoveRecognizedUser(self->_session, userID.UTF8String);
        [self->_recognizedUsers removeObject:userID];
        NSValue *decryptorValue = self->_decryptors[userID];
        if (decryptorValue) daveDecryptorDestroy((DAVEDecryptorHandle)decryptorValue.pointerValue);
        NSValue *ratchetValue = self->_decryptorRatchets[userID];
        if (ratchetValue) daveKeyRatchetDestroy((DAVEKeyRatchetHandle)ratchetValue.pointerValue);
        [self->_decryptors removeObjectForKey:userID];
        [self->_decryptorRatchets removeObjectForKey:userID];
    });
}

- (NSData *)keyPackageData:(NSError **)error {
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized) {
            failure = CoralcordMakeDAVEError(6, @"DAVE group is not initialized.");
            return;
        }
        uint8_t *bytes = nullptr;
        size_t length = 0;
        daveSessionGetMarshalledKeyPackage(self->_session, &bytes, &length);
        result = CoralcordCopyBytes(bytes, length);
        daveFree(bytes);
        if (result == nil || result.length == 0) {
            failure = CoralcordMakeDAVEError(7, @"libdave did not produce a key package.");
        }
    });
    if (error) *error = failure;
    return result ?: [NSData data];
}

- (NSData *)processProposals:(NSData *)data error:(NSError **)error {
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized || data.length == 0) {
            failure = CoralcordMakeDAVEError(8, @"Cannot process empty proposals or an uninitialized DAVE group.");
            return;
        }
        uint8_t *bytes = nullptr;
        size_t length = 0;
        daveSessionProcessProposals(self->_session, (const uint8_t *)data.bytes, data.length, &bytes, &length);
        result = CoralcordCopyBytes(bytes, length);
        daveFree(bytes);
        if (result == nil || result.length == 0) {
            failure = CoralcordMakeDAVEError(9, @"libdave did not produce a commit/welcome response for the proposals.");
            return;
        }
        [self refreshRatchetsLocked];
    });
    if (error) *error = failure;
    return result ?: [NSData data];
}

- (void)processCommit:(NSData *)data error:(NSError **)error {
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized || data.length == 0) {
            failure = CoralcordMakeDAVEError(10, @"Cannot process an empty commit or an uninitialized DAVE group.");
            return;
        }
        DAVECommitResultHandle result = daveSessionProcessCommit(self->_session, (const uint8_t *)data.bytes, data.length);
        if (result == nullptr) {
            failure = CoralcordMakeDAVEError(11, @"libdave rejected the MLS commit.");
            return;
        }
        const BOOL failed = daveCommitResultIsFailed(result);
        const BOOL ignored = daveCommitResultIsIgnored(result);
        daveCommitResultDestroy(result);
        if (failed) {
            failure = CoralcordMakeDAVEError(12, @"libdave failed to apply the MLS commit.");
            return;
        }
        if (!ignored) [self refreshRatchetsLocked];
    });
    if (error) *error = failure;
}

- (void)processWelcome:(NSData *)data error:(NSError **)error {
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized || data.length == 0) {
            failure = CoralcordMakeDAVEError(13, @"Cannot process an empty welcome or an uninitialized DAVE group.");
            return;
        }
        DAVEWelcomeResultHandle result = daveSessionProcessWelcome(self->_session, (const uint8_t *)data.bytes, data.length);
        if (result == nullptr) {
            failure = CoralcordMakeDAVEError(14, @"libdave rejected the MLS welcome.");
            return;
        }
        daveWelcomeResultDestroy(result);
        [self refreshRatchetsLocked];
    });
    if (error) *error = failure;
}

- (NSData *)encryptFrame:(NSData *)frame ssrc:(uint32_t)ssrc error:(NSError **)error {
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized || frame.length == 0 || !daveEncryptorHasKeyRatchet(self->_encryptor)) {
            failure = CoralcordMakeDAVEError(15, @"DAVE sender ratchet is not ready; plaintext media is blocked.");
            return;
        }
        if (self->_assignedSSRCs.insert(ssrc).second) {
            daveEncryptorAssignSsrcToCodec(self->_encryptor, ssrc, DAVE_CODEC_OPUS);
        }
        const size_t capacity = daveEncryptorGetMaxCiphertextByteSize(self->_encryptor, DAVE_MEDIA_TYPE_AUDIO, frame.length);
        if (capacity == 0) {
            failure = CoralcordMakeDAVEError(16, @"libdave could not determine the DAVE ciphertext size.");
            return;
        }
        std::vector<uint8_t> output(capacity);
        size_t written = 0;
        const DAVEEncryptorResultCode code = daveEncryptorEncrypt(
            self->_encryptor, DAVE_MEDIA_TYPE_AUDIO, ssrc,
            (const uint8_t *)frame.bytes, frame.length,
            output.data(), output.size(), &written);
        if (code != DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS || written == 0 || written > output.size()) {
            failure = CoralcordMakeDAVEError(17, [NSString stringWithFormat:@"libdave frame encryption failed (code %d).", (int)code]);
            return;
        }
        result = [NSData dataWithBytes:output.data() length:written];
    });
    if (error) *error = failure;
    return result ?: [NSData data];
}

- (NSData *)decryptFrame:(NSData *)frame userID:(NSString *)userID error:(NSError **)error {
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (!self->_groupInitialized || frame.length == 0 || userID.length == 0) {
            failure = CoralcordMakeDAVEError(18, @"The DAVE receive frame or participant identity is invalid.");
            return;
        }
        DAVEDecryptorHandle decryptor = [self decryptorForUserLocked:userID error:&failure];
        if (decryptor == nullptr) return;
        const size_t capacity = daveDecryptorGetMaxPlaintextByteSize(decryptor, DAVE_MEDIA_TYPE_AUDIO, frame.length);
        if (capacity == 0) {
            failure = CoralcordMakeDAVEError(19, @"libdave could not determine the DAVE plaintext size.");
            return;
        }
        std::vector<uint8_t> output(capacity);
        size_t written = 0;
        const DAVEDecryptorResultCode code = daveDecryptorDecrypt(
            decryptor, DAVE_MEDIA_TYPE_AUDIO, (const uint8_t *)frame.bytes, frame.length,
            output.data(), output.size(), &written);
        if (code != DAVE_DECRYPTOR_RESULT_CODE_SUCCESS || written == 0 || written > output.size()) {
            failure = CoralcordMakeDAVEError(20, [NSString stringWithFormat:@"libdave frame decryption failed (code %d).", (int)code]);
            return;
        }
        result = [NSData dataWithBytes:output.data() length:written];
    });
    if (error) *error = failure;
    return result ?: [NSData data];
}

- (BOOL)isSenderReady {
    __block BOOL ready = NO;
    dispatch_sync(_queue, ^{
        ready = self->_groupInitialized && daveEncryptorHasKeyRatchet(self->_encryptor);
    });
    return ready;
}

- (DAVEDecryptorHandle)decryptorForUserLocked:(NSString *)userID error:(NSError **)error {
    if (![_recognizedUsers containsObject:userID]) {
        daveSessionAddRecognizedUser(_session, userID.UTF8String);
        [_recognizedUsers addObject:userID];
    }
    NSValue *existing = _decryptors[userID];
    if (existing) return (DAVEDecryptorHandle)existing.pointerValue;

    DAVEKeyRatchetHandle ratchet = daveSessionGetKeyRatchet(_session, userID.UTF8String);
    if (ratchet == nullptr) {
        if (error) *error = CoralcordMakeDAVEError(21, @"No MLS receive ratchet is available for this participant yet.");
        return nullptr;
    }
    DAVEDecryptorHandle decryptor = daveDecryptorCreate();
    if (decryptor == nullptr) {
        daveKeyRatchetDestroy(ratchet);
        if (error) *error = CoralcordMakeDAVEError(22, @"libdave could not create a receive decryptor.");
        return nullptr;
    }
    daveDecryptorTransitionToPassthroughMode(decryptor, false);
    daveDecryptorTransitionToKeyRatchet(decryptor, ratchet);
    _decryptors[userID] = [NSValue valueWithPointer:decryptor];
    _decryptorRatchets[userID] = [NSValue valueWithPointer:ratchet];
    return decryptor;
}

- (void)refreshRatchetsLocked {
    DAVEKeyRatchetHandle sender = daveSessionGetKeyRatchet(_session, _selfUserID.UTF8String);
    if (sender != nullptr) {
        daveEncryptorSetKeyRatchet(_encryptor, sender);
        if (_senderRatchet != nullptr) daveKeyRatchetDestroy(_senderRatchet);
        _senderRatchet = sender;
    }
    for (NSString *userID in _recognizedUsers) {
        if ([userID isEqualToString:_selfUserID]) continue;
        DAVEKeyRatchetHandle ratchet = daveSessionGetKeyRatchet(_session, userID.UTF8String);
        if (ratchet == nullptr) continue;
        DAVEDecryptorHandle decryptor = nullptr;
        NSValue *decryptorValue = _decryptors[userID];
        if (decryptorValue) {
            decryptor = (DAVEDecryptorHandle)decryptorValue.pointerValue;
        } else {
            decryptor = daveDecryptorCreate();
            if (decryptor != nullptr) {
                daveDecryptorTransitionToPassthroughMode(decryptor, false);
                _decryptors[userID] = [NSValue valueWithPointer:decryptor];
            }
        }
        if (decryptor == nullptr) {
            daveKeyRatchetDestroy(ratchet);
            continue;
        }
        daveDecryptorTransitionToKeyRatchet(decryptor, ratchet);
        NSValue *oldValue = _decryptorRatchets[userID];
        if (oldValue) daveKeyRatchetDestroy((DAVEKeyRatchetHandle)oldValue.pointerValue);
        _decryptorRatchets[userID] = [NSValue valueWithPointer:ratchet];
    }
}

@end
