#import "ABStdoutPCMWriter.h"

#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>

extern void ABShutdownStreaming(void);

NSString *const ABStdoutPCMWriterErrorDomain = @"ABStdoutPCMWriterError";

@implementation ABStdoutPCMWriter {
    FILE *_stdoutFile;
    AVAudioEngine *_engine;
    AVAudioConverter *_converter;
    AVAudioFormat *_destinationFormat;
}

- (instancetype)initWithStdoutFile:(FILE *)stdoutFile {
    self = [super init];
    if (self) {
        _stdoutFile = stdoutFile;
    }
    return self;
}

- (void)stop {
    AVAudioEngine *engine = _engine;
    if (engine == nil) {
        return;
    }
    AVAudioInputNode *input = engine.inputNode;
    [input removeTapOnBus:0];
    [engine stop];
    _engine = nil;
    _converter = nil;
    _destinationFormat = nil;
}

- (void)ab_handleTapBuffer:(AVAudioPCMBuffer *)inputBuffer {
    if (inputBuffer == nil || inputBuffer.frameLength == 0) {
        return;
    }
    AVAudioConverter *converter = _converter;
    AVAudioFormat *dstFormat = _destinationFormat;
    FILE *out = _stdoutFile;
    if (converter == nil || dstFormat == nil || out == NULL) {
        return;
    }

    double srcRate = inputBuffer.format.sampleRate;
    double dstRate = dstFormat.sampleRate;
    if (srcRate <= 0.0) {
        srcRate = 1.0;
    }
    double ratio = dstRate / srcRate;
    AVAudioFrameCount outCapacity =
        (AVAudioFrameCount)ceil((double)inputBuffer.frameLength * ratio) + 64;
    if (outCapacity < 1) {
        outCapacity = 1;
    }

    AVAudioPCMBuffer *outputBuffer =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFormat frameCapacity:outCapacity];
    if (outputBuffer == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            fprintf(stderr, "audiobridge: failed to allocate PCM output buffer.\n");
            ABShutdownStreaming();
            exit(1);
        });
        return;
    }

    __block BOOL suppliedInput = NO;
    NSError *convertError = nil;
    BOOL converted = [converter convertToBuffer:outputBuffer
                                          error:&convertError
                             withInputFromBlock:^AVAudioPCMBuffer *_Nullable(AVAudioPacketCount inNumberOfPackets,
                                                                             AVAudioConverterInputStatus *_Nonnull outStatus) {
                                 (void)inNumberOfPackets;
                                 if (suppliedInput) {
                                     *outStatus = AVAudioConverterInputStatus_NoDataNow;
                                     return nil;
                                 }
                                 suppliedInput = YES;
                                 *outStatus = AVAudioConverterInputStatus_HaveData;
                                 return inputBuffer;
                             }];
    if (!converted || convertError != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = convertError.localizedDescription ?: @"PCM conversion failed.";
            const char *utf8 = message.UTF8String;
            fprintf(stderr, "audiobridge: %s\n", utf8 != NULL ? utf8 : "PCM conversion failed.");
            ABShutdownStreaming();
            exit(1);
        });
        return;
    }

    if (outputBuffer.frameLength == 0) {
        return;
    }

    AVAudioChannelCount channels = dstFormat.channelCount;
    size_t bytes = (size_t)outputBuffer.frameLength * (size_t)channels * sizeof(int16_t);
    int16_t *samples = outputBuffer.int16ChannelData[0];
    if (samples == NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            fprintf(stderr, "audiobridge: unexpected non-interleaved PCM layout.\n");
            ABShutdownStreaming();
            exit(1);
        });
        return;
    }

    size_t written = fwrite(samples, 1, bytes, out);
    if (written != bytes) {
        dispatch_async(dispatch_get_main_queue(), ^{
            fprintf(stderr, "audiobridge: stdout write failed.\n");
            ABShutdownStreaming();
            exit(1);
        });
    }
}

- (BOOL)startWithTargetSampleRateHz:(double)targetSampleRateHz quiet:(BOOL)quiet error:(NSError **)error {
    [self stop];

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = engine.inputNode;
    AVAudioFormat *sourceFormat = [inputNode outputFormatForBus:0];
    if (sourceFormat.channelCount == 0 || sourceFormat.sampleRate <= 0.0) {
        if (error) {
            *error = [NSError errorWithDomain:ABStdoutPCMWriterErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"Invalid input node format (channels or sample rate).",
                                     }];
        }
        return NO;
    }

    double effectiveDstRate =
        targetSampleRateHz > 0.0 ? targetSampleRateHz : sourceFormat.sampleRate;
    AVAudioChannelCount channelCount = sourceFormat.channelCount;

    AVAudioFormat *destinationFormat =
        [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                         sampleRate:effectiveDstRate
                                           channels:channelCount
                                        interleaved:YES];
    if (destinationFormat == nil) {
        if (error) {
            *error = [NSError errorWithDomain:ABStdoutPCMWriterErrorDomain
                                         code:2
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"Could not build interleaved s16le output format.",
                                     }];
        }
        return NO;
    }

    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:sourceFormat toFormat:destinationFormat];
    if (converter == nil) {
        if (error) {
            *error = [NSError errorWithDomain:ABStdoutPCMWriterErrorDomain
                                         code:3
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"Could not create AVAudioConverter.",
                                     }];
        }
        return NO;
    }

    __weak ABStdoutPCMWriter *weakSelf = self;
    [inputNode installTapOnBus:0 bufferSize:4096 format:nil block:^(AVAudioPCMBuffer *_Nonnull buffer,
                                                                     AVAudioTime *_Nonnull when) {
        (void)when;
        ABStdoutPCMWriter *strong = weakSelf;
        if (strong != nil) {
            [strong ab_handleTapBuffer:buffer];
        }
    }];

    [engine prepare];
    NSError *startError = nil;
    if (![engine startAndReturnError:&startError]) {
        [inputNode removeTapOnBus:0];
        if (error) {
            *error = startError;
        }
        return NO;
    }

    _engine = engine;
    _converter = converter;
    _destinationFormat = destinationFormat;

    if (!quiet) {
        fprintf(stderr, "pcm: s16le interleaved rate=%.0f channels=%u\n", effectiveDstRate,
                (unsigned int)channelCount);
    }
    return YES;
}

- (BOOL)rebuildForRouteChangeWithTargetSampleRateHz:(double)targetSampleRateHz
                                               quiet:(BOOL)quiet
                                               error:(NSError **)error {
    [self stop];
    return [self startWithTargetSampleRateHz:targetSampleRateHz quiet:quiet error:error];
}

@end
