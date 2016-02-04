//
//  CameraView.m
//  Cam
//
//  Created by Darren Leak on 2015/12/29.
//  Copyright © 2015 TheCodingRoom. All rights reserved.
//

#import "CameraView.h"

@implementation CameraView

@synthesize isRecording;
@synthesize cropFilter;

/////////////////////////////////////////////////////
//
// AVFoundation variables
//
/////////////////////////////////////////////////////

AVCaptureSession *captureSession;
AVCaptureDevice *device;
AVCaptureDeviceInput *videoDeviceInput;
AVCaptureVideoDataOutput *videoDataOutput;
AVAssetWriter *aw;
AVAssetWriterInput *awInput;
AVAssetWriterInputPixelBufferAdaptor *awInputpixelBufferAdaptor;



/////////////////////////////////////////////////////
//
// Queue
//
/////////////////////////////////////////////////////

dispatch_queue_t sessionQueue;



/////////////////////////////////////////////////////
//
// General Properties/Variables
//
/////////////////////////////////////////////////////
NSURL *fileURL;
int fps = 60;
int frameCount = 0;
CFAbsoluteTime startTimeStamp;



/////////////////////////////////////////////////////
//
// Setup
//
/////////////////////////////////////////////////////

- (void)cvSetup
{
    isRecording = NO;
    
    [self setupFilters];
    [self createFile];
    [self setDevice];
    
    if (device != nil)
    {
        [self startCaptureSession];
    }
}

- (void)setupFilters
{
    ////////////////////////////////////////
    //
    // Crop Filter
    //
    ////////////////////////////////////////
    
    cropFilter = [[CropFilter alloc] init];
    cropFilter.setupContext;
}

- (void)startCaptureSession
{
    sessionQueue = dispatch_queue_create("videoQueue", DISPATCH_QUEUE_SERIAL);
    
    // TODO : This needs to be updated for the actual app!
    captureSession = [[AVCaptureSession alloc] init];
    captureSession.sessionPreset = AVCaptureSessionPreset3840x2160;
    
    // add device input
    videoDeviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:device error:nil];
    
    // add the device to the session
    if ([captureSession canAddInput:videoDeviceInput])
    {
        [captureSession addInput:videoDeviceInput];
    }
    
    // setup the preview layer
    AVCaptureVideoPreviewLayer *previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:captureSession];
    [[self layer] addSublayer:previewLayer];
    previewLayer.frame = self.layer.frame;
    
    // setup video output
    videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    videoDataOutput.videoSettings = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA] forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    [videoDataOutput setSampleBufferDelegate:self queue:sessionQueue];
    
    if ([captureSession canAddOutput:videoDataOutput])
    {
        [captureSession addOutput:videoDataOutput];
    }

    dispatch_async(sessionQueue, ^{
        [captureSession startRunning];
    });
}

// TODO : This needs to be selectable
- (void)setDevice
{
    for (AVCaptureDevice *d in AVCaptureDevice.devices)
    {
        if ([d hasMediaType:AVMediaTypeVideo])
        {
            // set to back camera
            if ([d position] == AVCaptureDevicePositionBack)
            {
                device = d;
            }
        }
    }
}

- (void)createFile
{
    NSString *fileName = [NSString stringWithFormat:@"%i%@", (int)[[NSDate date] timeIntervalSince1970], @".mov"];
    fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
}

- (void)startRecording
{
    NSLog(@"Start recording");
    isRecording = YES;
    [self createFile];
    
    aw = [[AVAssetWriter alloc] initWithURL:fileURL fileType:AVFileTypeQuickTimeMovie error:nil];
    NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   AVVideoCodecJPEG, AVVideoCodecKey,
                                   [NSNumber numberWithInt:3840], AVVideoWidthKey,
                                   [NSNumber numberWithInt:2160], AVVideoHeightKey,
                                   nil];
    awInput = [AVAssetWriterInput
               assetWriterInputWithMediaType:AVMediaTypeVideo
               outputSettings:videoSettings];
    awInput.expectsMediaDataInRealTime = YES;
    
    awInputpixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor
                                 assetWriterInputPixelBufferAdaptorWithAssetWriterInput:awInput
                                 sourcePixelBufferAttributes:nil];
    
    // add the writer input to the writer
    if ([aw canAddInput:awInput])
    {
        [aw addInput:awInput];
    }
    
    startTimeStamp = CFAbsoluteTimeGetCurrent();
    
    [aw startWriting];
    [aw startSessionAtSourceTime:kCMTimeZero];
}

- (void)stopRecording
{
    NSLog(@"Stop recording");
    dispatch_async(sessionQueue, ^{
        [captureSession stopRunning];
        
        [aw finishWritingWithCompletionHandler:^{
            isRecording = NO;
            
            if (aw.status == AVAssetWriterStatusFailed)
            {
                NSLog(@"AW Status : %@", aw.error);
                NSLog(@"Write failed");
            }
            else
            {
                [awInput markAsFinished];
                
                // Hopefully this will write the file
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    
                    PHAssetChangeRequest *changeRequest = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
                    NSParameterAssert(changeRequest);
                    NSLog(@"Start writing");
                    
                } completionHandler:^(BOOL success, NSError *error) {
                    [self clearTmpDirectory];
                    NSLog(@"Finished updating asset. %@", (success ? @"Success." : error));
                    
                }];
            }
            [captureSession startRunning];
        }];
    });
}

//just for testing
CGFloat xPos = 0;

- (void)recordFrames:(CMSampleBufferRef)sampleBuffer currentFrameCount:(int)currentFrameCount
{
    if (awInputpixelBufferAdaptor.assetWriterInput.readyForMoreMediaData)
    {
        cropFilter.outputRect = CGRectMake(xPos, 0.0, 1920.0, 1080.0);
        CFAbsoluteTime curTime = CFAbsoluteTimeGetCurrent();
        double elapsedTime = curTime - startTimeStamp;
        CMTime frameTime = CMTimeMake((elapsedTime * fps), fps);
        CVPixelBufferRef cvpbr = [cropFilter cropImage:CMSampleBufferGetImageBuffer(sampleBuffer)];
        
        CVPixelBufferLockBaseAddress(cvpbr, 0);
        bool appended = [awInputpixelBufferAdaptor appendPixelBuffer:cvpbr withPresentationTime:frameTime];
        CVPixelBufferUnlockBaseAddress(cvpbr, 0);
        
        CVPixelBufferRelease(cropFilter.pixelBuffer);
        
        xPos++;
    }
}

//clear everything from the temp directory
- (void)clearTmpDirectory
{
    NSArray* tmpDirectory = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL];
    for (NSString *file in tmpDirectory) {
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), file] error:NULL];
    }
}



/////////////////////////////////////////////////////
//
// Protocols
//
/////////////////////////////////////////////////////

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (isRecording)
    {
        [self recordFrames:sampleBuffer currentFrameCount:frameCount];
        frameCount++;
    }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    
}

@end
