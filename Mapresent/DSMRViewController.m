//
//  DSMRViewController.m
//  Mapresent
//
//  Created by Justin Miller on 1/24/12.
//  Copyright (c) 2012 Development Seed. All rights reserved.
//

#import "DSMRViewController.h"

#import "DSMRTimelineMarker.h"
#import "DSMRWrapperController.h"
#import "DSMRThemePicker.h"

#import "RMMapView.h"
#import "RMScrollView.h"
#import "RMMBTilesTileSource.h"
#import "RMTileStreamSource.h"

#import "UIImage-Extensions.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>

@interface DSMRViewController () 

@property (nonatomic, strong) IBOutlet RMMapView *mapView;
@property (nonatomic, strong) IBOutlet UILabel *mapLabel;
@property (nonatomic, strong) IBOutlet UIView *inspectorView;
@property (nonatomic, strong) IBOutlet DSMRTimelineView *timelineView;
@property (nonatomic, strong) IBOutlet UITableView *markerTableView;
@property (nonatomic, strong) IBOutlet UIButton *playButton;
@property (nonatomic, strong) IBOutlet UIButton *audioButton;
@property (nonatomic, strong) IBOutlet UILabel *timeLabel;
@property (nonatomic, strong) NSMutableArray *markers;
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSMutableArray *themes;
@property (nonatomic, strong) NSDictionary *chosenThemeInfo;
@property (nonatomic, assign) dispatch_queue_t serialQueue;
@property (nonatomic, assign) dispatch_queue_t processingQueue;

- (IBAction)pressedPlay:(id)sender;
- (IBAction)pressedExport:(id)sender;
- (void)fireMarkerAtIndex:(NSInteger)index;
- (CVPixelBufferRef )pixelBufferFromCGImage:(CGImageRef)image size:(CGSize)size;

@end

#pragma mark -

@implementation DSMRViewController

@synthesize mapView;
@synthesize mapLabel;
@synthesize inspectorView;
@synthesize timelineView;
@synthesize markerTableView;
@synthesize playButton;
@synthesize audioButton;
@synthesize timeLabel;
@synthesize markers;
@synthesize recorder;
@synthesize player;
@synthesize themes;
@synthesize chosenThemeInfo;
@synthesize serialQueue;
@synthesize processingQueue;

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.mapView.delegate = self;
    
    self.mapView.tileSource = [[RMMBTilesTileSource alloc] initWithTileSetURL:[[NSBundle mainBundle] URLForResource:@"geography-class" withExtension:@"mbtiles"]];
    self.mapView.decelerationMode = RMMapDecelerationFast;
    self.mapView.zoom = 1.396605;
    
    [RMMapView class]; // avoid code stripping
    
    timeLabel.text = @"0.000000";

    markers = [NSMutableArray array];

    if ([[NSUserDefaults standardUserDefaults] arrayForKey:@"markers"])
        for (NSData *savedMarker in [[NSUserDefaults standardUserDefaults] arrayForKey:@"markers"])
            [markers addObject:[NSKeyedUnarchiver unarchiveObjectWithData:savedMarker]];
    
    [self.markerTableView reloadData];
    
    self.timelineView.delegate = self;
    
    [self.timelineView redrawMarkers];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playToggled:)       name:DSMRTimelineViewPlayToggled               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playProgressed:)    name:DSMRTimelineViewPlayProgressed            object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillBackground:) name:UIApplicationWillResignActiveNotification object:nil];
    
    serialQueue     = dispatch_queue_create("mapresent.serial", DISPATCH_QUEUE_SERIAL);
    processingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    return UIInterfaceOrientationIsLandscape(interfaceOrientation);
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:DSMRTimelineViewPlayToggled               object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:DSMRTimelineViewPlayProgressed            object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
}

#pragma mark -

- (IBAction)pressedPlay:(id)sender
{
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    
    if ([self.markers count] && [[[self.markers objectAtIndex:0] valueForKey:@"timeOffset"] floatValue] == 0 && [self.timeLabel.text floatValue] == 0)
        [self fireMarkerAtIndex:0];
    
    if (self.timelineView.isExporting)
    {
        self.timelineView.exporting = NO;
        ((RMScrollView *)[self.mapView.subviews objectAtIndex:1]).animationDuration = 1.0;
        
        // give capture some time to wrap up
        //
        dispatch_async(self.serialQueue, ^(void) { sleep(2); });
        
        // clean up capture frames
        //
        dispatch_async(self.serialQueue, ^(void)
        {
            for (NSString *imageFile in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil])
            {
                if ([imageFile hasPrefix:@"snap_"] && [imageFile hasSuffix:@".png"])
                {
//                    dispatch_async(self.processingQueue, ^(void)
//                    {
//                        // these are not thread-safe, but that doesn't matter (much) for now
//                        //
                        UIImage *originalImage = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"%@/%@", NSTemporaryDirectory(), imageFile]];
                        UIImage *croppedImage  = [originalImage imageAtRect:CGRectMake(20, 350, 498, 674)];
                        UIImage *rotatedImage  = [croppedImage imageRotatedByDegrees:90.0];

                        [UIImagePNGRepresentation(rotatedImage) writeToFile:[NSString stringWithFormat:@"%@/%@", NSTemporaryDirectory(), imageFile] atomically:YES];
                    
                    NSLog(@"processed %@", imageFile);
//                    });
                }
            }
        });
        
        // make the video
        //
        dispatch_async(self.serialQueue, ^(void)
        {
            CGSize size = CGSizeMake(674, 498);
            
            
            NSString *betaCompressionDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"export.m4v"];
            
            NSError *error = nil;
            
            unlink([betaCompressionDirectory UTF8String]);
            
            //----initialize compression engine
            AVAssetWriter *videoWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:betaCompressionDirectory]
                                                                   fileType:AVFileTypeQuickTimeMovie
                                                                      error:&error];
            NSParameterAssert(videoWriter);
            if(error)
                NSLog(@"error = %@", [error localizedDescription]);
            
            NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:AVVideoCodecH264, AVVideoCodecKey,
                                           [NSNumber numberWithInt:size.width], AVVideoWidthKey,
                                           [NSNumber numberWithInt:size.height], AVVideoHeightKey, nil];
            AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
            
            NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                                                   [NSNumber numberWithInt:kCVPixelFormatType_32ARGB], kCVPixelBufferPixelFormatTypeKey, nil];
            
            AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                                                                                             sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
            NSParameterAssert(writerInput);
            NSParameterAssert([videoWriter canAddInput:writerInput]);
            
            if ([videoWriter canAddInput:writerInput])
                NSLog(@"I can add this input");
            else
                NSLog(@"i can't add this input");
            
            [videoWriter addInput:writerInput];
            
            [videoWriter startWriting];
            [videoWriter startSessionAtSourceTime:kCMTimeZero];
            
            //---
            // insert demo debugging code to write the same image repeated as a movie
            
//            CGImageRef theImage = [[UIImage imageNamed:@"Lotus.png"] CGImage];
            
//            dispatch_queue_t    dispatchQueue = dispatch_queue_create("mediaInputQueue", NULL);
            int __block         frame = 0;
            
            for (NSString *imageFile in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil])
            {
                if ([imageFile hasPrefix:@"snap_"] && [imageFile hasSuffix:@".png"])
                {
                    
                    NSLog(@"doing %@", imageFile);
                    
                    while ( ! [writerInput isReadyForMoreMediaData])
                        [NSThread sleepForTimeInterval:0.5];
                    
                    UIImage *image = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"%@/%@", NSTemporaryDirectory(), imageFile]];

                    CVPixelBufferRef buffer = (CVPixelBufferRef)[self pixelBufferFromCGImage:[image CGImage] size:size];
                    if (buffer)
                    {
                        if(![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMakeWithSeconds(frame * (1.0 / 64.0), 1000)])
                            NSLog(@"FAIL");
                        else
                            NSLog(@"Success:%d", frame);
                        CFRelease(buffer);
                    }
                    
                    frame++;
                }

                
                
            }
            
            [writerInput markAsFinished];
            [videoWriter finishWriting];
//            [videoWriter release];
        });
        
        // log that we're done
        //
        dispatch_async(self.serialQueue, ^(void)
        {
            NSLog(@"video done"); 
            
            NSString *writtenFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"export.m4v"];
            NSString *finalFile   = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"export.m4v"];

            [[NSFileManager defaultManager] removeItemAtPath:finalFile error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:writtenFile toPath:finalFile error:nil];
            
            dispatch_async(dispatch_get_main_queue(), ^(void)
            {
                NSURL *movieURL = [NSURL fileURLWithPath:finalFile];

                MPMoviePlayerViewController *moviePresenter = [[MPMoviePlayerViewController alloc] initWithContentURL:movieURL];

                moviePresenter.moviePlayer.shouldAutoplay = NO;
                
                [self presentMoviePlayerViewControllerAnimated:moviePresenter];
            });
        });
    }
    
    [self.timelineView togglePlay];
}
                       
- (CVPixelBufferRef )pixelBufferFromCGImage:(CGImageRef)image size:(CGSize)size
{
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGImageCompatibilityKey, 
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGBitmapContextCompatibilityKey, nil];
    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef) options, &pxbuffer);
    // CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pxbuffer);
    
    NSParameterAssert(status == kCVReturnSuccess && pxbuffer != NULL); 
    
    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    NSParameterAssert(pxdata != NULL);
    
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, size.width, size.height, 8, CVPixelBufferGetBytesPerRow(pxbuffer)/*4*size.width*/, rgbColorSpace, kCGImageAlphaPremultipliedFirst);
    NSParameterAssert(context);
    
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)), image);
    
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    
    return pxbuffer;
}

- (IBAction)pressedExport:(id)sender
{
    if ( ! self.timelineView.isExporting)
    {
        for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil])
            if ([file hasPrefix:@"snap_"] && [file hasSuffix:@".png"])
                [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@", NSTemporaryDirectory(), file] error:nil];
        
        ((RMScrollView *)[self.mapView.subviews objectAtIndex:1]).animationDuration = 8.0;
        
        self.timelineView.exporting = YES;
        
        [NSTimer scheduledTimerWithTimeInterval:(1.0 / 8.0) target:self selector:@selector(takeSnapshot:) userInfo:nil repeats:YES];
        
        [self.timelineView togglePlay];
    }
}

CGImageRef UIGetScreenImage(void); // um, FIXME

- (void)takeSnapshot:(NSTimer *)timer
{
    static int i = 0;
    
    if ( ! self.timelineView.isExporting)
    {
        [timer invalidate];
        i = 0;
        return;
    }
    
    NSString *filename = [NSString stringWithFormat:@"%@/snap_%@%i.png", NSTemporaryDirectory(), (i < 10 ? @"00" : (i < 100 ? @"0" : @"")), i];
    
    CGImageRef image = UIGetScreenImage();
    
    dispatch_async(self.processingQueue, ^(void)
    {
        [UIImagePNGRepresentation([UIImage imageWithCGImage:image]) writeToFile:filename atomically:YES];
    });
    
    i++;
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerBeforeViewController:(UIViewController *)viewController
{
    int index = [self.themes indexOfObject:((DSMRThemePicker *)viewController).info];
    
    if (index > 0)
        return [[DSMRThemePicker alloc] initWithInfo:[self.themes objectAtIndex:(index - 1)]];
        
    return nil;
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerAfterViewController:(UIViewController *)viewController
{
    int index = [self.themes indexOfObject:((DSMRThemePicker *)viewController).info];
    
    if (index < [self.themes count] - 1)
        return [[DSMRThemePicker alloc] initWithInfo:[self.themes objectAtIndex:(index + 1)]];
    
    return nil;
}

- (void)pageViewController:(UIPageViewController *)pageViewController didFinishAnimating:(BOOL)finished previousViewControllers:(NSArray *)previousViewControllers transitionCompleted:(BOOL)completed
{
    int index = [self.themes indexOfObject:((DSMRThemePicker *)[pageViewController.viewControllers lastObject]).info];

    self.chosenThemeInfo = [self.themes objectAtIndex:index];
}

- (IBAction)pressedTheme:(id)sender
{
    [NSURLConnection sendAsynchronousRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://api.tiles.mapbox.com/v1/mapbox/tilesets.json"]]
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *responseData, NSError *error)
                           {
                               self.themes = [NSMutableArray array];
                               
                               for (NSDictionary *tileset in [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil])
                               {
                                   RMTileStreamSource *source = [[RMTileStreamSource alloc] initWithInfo:tileset];
                                   
                                   if ([source coversFullWorld])
                                       [self.themes addObject:tileset];
                               }
                               
                               UIPageViewController *pager = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStylePageCurl
                                                                                             navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                                                                                                           options:[NSDictionary dictionaryWithObject:[NSNumber numberWithInteger:UIPageViewControllerSpineLocationMin] forKey:UIPageViewControllerOptionSpineLocationKey]];
                               
                               [pager setViewControllers:[NSArray arrayWithObject:[[DSMRThemePicker alloc] initWithInfo:[self.themes objectAtIndex:0]]]
                                                                                                              direction:UIPageViewControllerNavigationDirectionForward 
                                                                                                               animated:NO 
                                                                                                             completion:nil];
                               
                               pager.dataSource = self;
                               pager.delegate   = self;
                               
                               DSMRWrapperController *wrapper = [[DSMRWrapperController alloc] initWithRootViewController:pager];

                               wrapper.navigationBar.barStyle = UIBarStyleBlackTranslucent;
                               
                               wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
                               wrapper.modalTransitionStyle   = UIModalTransitionStyleCrossDissolve;
                               
                               pager.navigationItem.title = @"Choose Theme";
                               
                               pager.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                                                      target:self
                                                                                                                      action:@selector(dismissModalViewControllerAnimated:)];
                               
                               pager.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Choose"
                                                                                                          style:UIBarButtonItemStyleDone
                                                                                                         target:self
                                                                                                         action:@selector(addThemeTransition:)];
                               
                               self.chosenThemeInfo = [self.themes objectAtIndex:0];
                               
                               [self presentModalViewController:wrapper animated:YES];
                           }];
}

- (void)addThemeTransition:(id)sender
{
    [self dismissModalViewControllerAnimated:YES];
    
    DSMRTimelineMarker *marker = [[DSMRTimelineMarker alloc] init];
    
    marker.timeOffset     = [self.timeLabel.text doubleValue];
    marker.tileSourceInfo = self.chosenThemeInfo;
    
    if ([self.markers count])
    {
        int startCount = [self.markers count];
        
        for (DSMRTimelineMarker *otherMarker in [self.markers copy])
        {
            if ([self.timeLabel.text doubleValue] < otherMarker.timeOffset)
            {
                [self.markers insertObject:marker atIndex:[self.markers indexOfObject:otherMarker]];
                
                break;
            }
        }
        
        if ([self.markers count] == startCount)
            [self.markers addObject:marker];
    }
    else
    {
        [self.markers addObject:marker];
    }
    
    [self.markerTableView reloadData];
    
    [self.timelineView redrawMarkers];
}

- (IBAction)pressedAudio:(id)sender
{
    if ( ! self.recorder.recording)
    {
        [self.audioButton setTitle:@"Stop" forState:UIControlStateNormal];

        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:nil];

        NSURL *recordURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@.rec", NSTemporaryDirectory(), [[NSProcessInfo processInfo] globallyUniqueString]]];
        
        NSDictionary *settings = [NSDictionary dictionaryWithObjectsAndKeys:
                                     [NSNumber numberWithFloat:8000.0],                  AVSampleRateKey,
                                     [NSNumber numberWithInt:kAudioFormatAppleLossless], AVFormatIDKey,
                                     [NSNumber numberWithInt:1],                         AVNumberOfChannelsKey,
                                     [NSNumber numberWithInt:AVAudioQualityMax],         AVEncoderAudioQualityKey,
                                     nil];
        
        self.recorder = [[AVAudioRecorder alloc] initWithURL:recordURL settings:settings error:nil];
        
        [self.recorder record];        
    }
    else
    {
        [self.recorder stop];

        [self.audioButton setTitle:@"Audio" forState:UIControlStateNormal];

        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        
        AVAudioPlayer *clip = [[AVAudioPlayer alloc] initWithContentsOfURL:self.recorder.url error:nil];
        
        DSMRTimelineMarker *marker = [[DSMRTimelineMarker alloc] init];
        
        marker.timeOffset = [self.timeLabel.text doubleValue];
        marker.recording  = [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:[self.recorder.url absoluteString]]];
        marker.duration   = clip.duration;
        
        [[NSFileManager defaultManager] removeItemAtURL:self.recorder.url error:nil];
        
        if ([self.markers count])
        {
            int startCount = [self.markers count];
            
            for (DSMRTimelineMarker *otherMarker in [self.markers copy])
            {
                if ([self.timeLabel.text doubleValue] < otherMarker.timeOffset)
                {
                    [self.markers insertObject:marker atIndex:[self.markers indexOfObject:otherMarker]];
                    
                    break;
                }
            }
            
            if ([self.markers count] == startCount)
                [self.markers addObject:marker];
        }
        else
        {
            [self.markers addObject:marker];
        }
        
        [self.markerTableView reloadData];
        
        [self.timelineView redrawMarkers];
    }
}

- (IBAction)pressedMarker:(id)sender
{
    UIGraphicsBeginImageContext(self.mapView.bounds.size);
    
    [self.mapView.layer renderInContext:UIGraphicsGetCurrentContext()];
    
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    
    DSMRTimelineMarker *marker = [[DSMRTimelineMarker alloc] init];
    
    marker.southWest  = self.mapView.latitudeLongitudeBoundingBox.southWest;
    marker.northEast  = self.mapView.latitudeLongitudeBoundingBox.northEast;
    marker.center     = self.mapView.centerCoordinate;
    marker.timeOffset = [self.timeLabel.text doubleValue];
    marker.sourceName = [self.mapView.tileSource shortName];
    marker.snapshot   = snapshot;
    
    if ([self.markers count])
    {
        int startCount = [self.markers count];
        
        for (DSMRTimelineMarker *otherMarker in [self.markers copy])
        {
            if ([self.timeLabel.text doubleValue] < otherMarker.timeOffset)
            {
                [self.markers insertObject:marker atIndex:[self.markers indexOfObject:otherMarker]];
                
                break;
            }
        }
        
        if ([self.markers count] == startCount)
            [self.markers addObject:marker];
    }
    else
    {
        [self.markers addObject:marker];
    }

    [self.markerTableView reloadData];
    
    [self.timelineView redrawMarkers];
}

#pragma mark -

- (void)fireMarkerAtIndex:(NSInteger)index
{
    DSMRTimelineMarker *marker = [self.markers objectAtIndex:index];
    
    if (marker.sourceName)
    {
        [self.mapView zoomWithLatitudeLongitudeBoundsSouthWest:marker.southWest northEast:marker.northEast animated:YES];
    }
    else if (marker.recording)
    {
        self.player = [[AVAudioPlayer alloc] initWithData:marker.recording error:nil];
    
        [self.player performSelector:@selector(play) withObject:nil afterDelay:0.0];
    }
    else if (marker.tileSourceInfo)
    {
        [self.mapView performSelector:@selector(setTileSource:) withObject:[[RMTileStreamSource alloc] initWithInfo:marker.tileSourceInfo] afterDelay:0.0];
    }
}

- (void)appWillBackground:(NSNotification *)notification
{
    NSMutableArray *savedMarkers = [NSMutableArray array];
    
    for (DSMRTimelineMarker *marker in self.markers)
        [savedMarkers addObject:[NSKeyedArchiver archivedDataWithRootObject:marker]];
    
    [[NSUserDefaults standardUserDefaults] setObject:savedMarkers forKey:@"markers"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)playToggled:(NSNotification *)notification
{
    [self.playButton setTitle:([self.playButton.currentTitle isEqualToString:@"Play"] ? @"Pause" : @"Play") forState:UIControlStateNormal];
}

- (void)playProgressed:(NSNotification *)notification
{
    self.timeLabel.text = [NSString stringWithFormat:@"%f", [((NSNumber *)[notification object]) floatValue] / 64];
    
    if ([self.playButton.currentTitle isEqualToString:@"Pause"] && [[self.markers valueForKeyPath:@"timeOffset"] containsObject:[NSNumber numberWithDouble:[self.timeLabel.text doubleValue]]])
    {
        for (DSMRTimelineMarker *marker in self.markers)
        {
            if (marker.timeOffset == [self.timeLabel.text doubleValue])
            {
                [self fireMarkerAtIndex:[self.markers indexOfObject:marker]];
                
                break;
            }
        }
    }
}

#pragma mark -

- (void)mapViewRegionDidChange:(RMMapView *)mapView
{
    self.mapLabel.text = [NSString stringWithFormat:@"%f, %f", self.mapView.centerCoordinate.latitude, self.mapView.centerCoordinate.longitude];
}

#pragma mark -

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self.markers count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *DSMRViewControllerMarkerIdentifier = @"DSMRViewControllerMarkerIdentifier";
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:DSMRViewControllerMarkerIdentifier];
    
    if ( ! cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:DSMRViewControllerMarkerIdentifier];
    
    DSMRTimelineMarker *marker = [self.markers objectAtIndex:indexPath.row];

    if (marker.sourceName)
    {
        cell.textLabel.text = [NSString stringWithFormat:@"Map @ %fs", marker.timeOffset];

        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%f, %f)", marker.sourceName, marker.center.latitude, marker.center.longitude];
    }
    else if (marker.recording)
    {
        cell.textLabel.text = [NSString stringWithFormat:@"Audio @ %fs", marker.timeOffset];

        cell.detailTextLabel.text = [NSString stringWithFormat:@"%f seconds", marker.duration];
    }
    else if (marker.tileSourceInfo)
    {
        cell.textLabel.text = [NSString stringWithFormat:@"Theme @ %fs", marker.timeOffset];
        
        cell.detailTextLabel.text = [marker.tileSourceInfo objectForKey:@"name"];
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self.markers removeObjectAtIndex:indexPath.row];
    
    [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationLeft];
    
    [self.timelineView redrawMarkers];
}

#pragma mark -

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    [self fireMarkerAtIndex:indexPath.row];
}

#pragma mark -

- (NSArray *)timelineMarkers
{
    return [NSArray arrayWithArray:self.markers];
}

@end