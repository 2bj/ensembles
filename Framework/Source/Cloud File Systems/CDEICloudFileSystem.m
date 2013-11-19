//
//  CDEICloudFileSystem.m
//  Ensembles
//
//  Created by Drew McCormack on 20/09/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import "CDEICloudFileSystem.h"
#import "CDECloudDirectory.h"
#import "CDECloudFile.h"

@implementation CDEICloudFileSystem {
    NSFileManager *fileManager;
    NSURL *rootDirectoryURL;
    NSMetadataQuery *metadataQuery;
    NSOperationQueue *operationQueue;
    NSString *ubiquityContainerIdentifier;
    id ubiquityIdentityObserver;
}

- (instancetype)initWithUbiquityContainerIdentifier:(NSString *)newIdentifier
{
    self = [super init];
    if (self) {
        fileManager = [[NSFileManager alloc] init];
        
        operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.maxConcurrentOperationCount = 1;
        
        rootDirectoryURL = nil;
        metadataQuery = nil;
        ubiquityContainerIdentifier = [newIdentifier copy];
        ubiquityIdentityObserver = nil;
        
        [self performInitialPreparation:NULL];
    }
    return self;
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:CDEException reason:@"iCloud initializer requires container identifier" userInfo:nil];
    return nil;
}

- (void)dealloc
{
    [self removeUbiquityContainerNotificationObservers];
    [self stopMonitoring];
    [operationQueue cancelAllOperations];
}

#pragma mark - User Identity

- (id <NSObject, NSCoding, NSCopying>)identityToken
{
    return [fileManager ubiquityIdentityToken];
}

#pragma mark - Initial Preparation

- (void)performInitialPreparation:(CDECompletionBlock)completion
{
    if (fileManager.ubiquityIdentityToken) {
        [self setupRootDirectory:^{
            [self startMonitoringMetadata];
            [self addUbiquityContainerNotificationObservers];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil);
            });
        }];
    }
    else {
        [self addUbiquityContainerNotificationObservers];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil);
        });
    }
}

#pragma mark - Root Directory

- (void)setupRootDirectory:(CDECodeBlock)completion
{
    [operationQueue addOperationWithBlock:^{
        NSURL *newURL = [fileManager URLForUbiquityContainerIdentifier:ubiquityContainerIdentifier];
        newURL = [newURL URLByAppendingPathComponent:@"com.mentalfaculty.ensembles.clouddata"];
        rootDirectoryURL = newURL;
        NSAssert(rootDirectoryURL, @"Could not retrieve URLForUbiquityContainerIdentifier. Check container id for iCloud");
                 
        NSError *error = nil;
        __block BOOL fileExistsAtPath = NO;
        __block BOOL existingFileIsDirectory = NO;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:rootDirectoryURL options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *newURL) {
            fileExistsAtPath = [fileManager fileExistsAtPath:newURL.path isDirectory:&existingFileIsDirectory];
        }];
        if (error) CDELog(CDELoggingLevelWarning, @"File coordinator error: %@", error);
        
        error = nil;
        if (!fileExistsAtPath) {
            [coordinator coordinateWritingItemAtURL:rootDirectoryURL options:0 error:&error byAccessor:^(NSURL *newURL) {
                [fileManager createDirectoryAtURL:newURL withIntermediateDirectories:YES attributes:nil error:NULL];
            }];
        }
        else if (fileExistsAtPath && !existingFileIsDirectory) {
            [coordinator coordinateWritingItemAtURL:rootDirectoryURL options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *newURL) {
                [fileManager removeItemAtURL:newURL error:NULL];
                [fileManager createDirectoryAtURL:newURL withIntermediateDirectories:YES attributes:nil error:NULL];
            }];
        }
        if (error) CDELog(CDELoggingLevelWarning, @"File coordinator error: %@", error);
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (completion) completion();
        });
    }];
}

- (NSString *)fullPathForPath:(NSString *)path
{
    return [rootDirectoryURL.path stringByAppendingPathComponent:path];
}

#pragma mark - Notifications

- (void)removeUbiquityContainerNotificationObservers
{
    [[NSNotificationCenter defaultCenter] removeObserver:ubiquityIdentityObserver];
    ubiquityIdentityObserver = nil;
}

- (void)addUbiquityContainerNotificationObservers
{
    [self removeUbiquityContainerNotificationObservers];
    ubiquityIdentityObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSUbiquityIdentityDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [self stopMonitoring];
        [self willChangeValueForKey:@"identityToken"];
        [self didChangeValueForKey:@"identityToken"];
    }];
}

#pragma mark - Connection

- (BOOL)isConnected
{
    return fileManager.ubiquityIdentityToken != nil;
}

- (void)connect:(CDECompletionBlock)completion
{
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL loggedIn = fileManager.ubiquityIdentityToken != nil;
        NSError *error = loggedIn ? nil : [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeAuthenticationFailure userInfo:@{NSLocalizedDescriptionKey : NSLocalizedString(@"User is not logged into iCloud.", @"")} ];
        if (completion) completion(error);
    });
}

#pragma mark - Metadata Query to download new files

- (void)startMonitoringMetadata
{
    [self stopMonitoring];
 
    if (!rootDirectoryURL) return;
    
    // Determine downloading key. This is OS dependent.
    NSString *isDownloadedKey = nil;
    
    #if (__IPHONE_OS_VERSION_MIN_REQUIRED < 30000) && (__MAC_OS_X_VERSION_MIN_REQUIRED < 1090)
        isDownloadedKey = NSMetadataUbiquitousItemIsDownloadedKey;
    #else
        isDownloadedKey = NSMetadataUbiquitousItemDownloadingStatusDownloaded;
    #endif
    
    metadataQuery = [[NSMetadataQuery alloc] init];
    metadataQuery.notificationBatchingInterval = 10.0;
    metadataQuery.searchScopes = [NSArray arrayWithObject:NSMetadataQueryUbiquitousDataScope];
    metadataQuery.predicate = [NSPredicate predicateWithFormat:@"%K = FALSE AND %K = FALSE AND %K ENDSWITH '.cdeevent' AND %K BEGINSWITH %@",
        isDownloadedKey, NSMetadataUbiquitousItemIsDownloadingKey, NSMetadataItemFSNameKey, NSMetadataItemPathKey, rootDirectoryURL.path];
    
    NSNotificationCenter *notifationCenter = [NSNotificationCenter defaultCenter];
    [notifationCenter addObserver:self selector:@selector(initiateDownloads:) name:NSMetadataQueryDidFinishGatheringNotification object:metadataQuery];
    [notifationCenter addObserver:self selector:@selector(initiateDownloads:) name:NSMetadataQueryDidUpdateNotification object:metadataQuery];
    
    [metadataQuery startQuery];
}

- (void)stopMonitoring
{
    if (!metadataQuery) return;
    
    [metadataQuery disableUpdates];
    [metadataQuery stopQuery];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidFinishGatheringNotification object:metadataQuery];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidUpdateNotification object:metadataQuery];
    
    metadataQuery = nil;
}

- (void)initiateDownloads:(NSNotification *)notif
{
    [metadataQuery disableUpdates];
    
    NSUInteger count = [metadataQuery resultCount];
    for ( NSUInteger i = 0; i < count; i++ ) {
        @autoreleasepool {
            NSURL *url = [metadataQuery valueOfAttribute:NSMetadataItemURLKey forResultAtIndex:i];
            dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
            dispatch_async(queue, ^{
                NSError *error;
                BOOL startedDownload = [fileManager startDownloadingUbiquitousItemAtURL:url error:&error];
                if ( !startedDownload ) CDELog(CDELoggingLevelWarning, @"Error starting download: %@", error);
            });
        }
    }

    [metadataQuery enableUpdates];
}

#pragma mark - File Operations

- (void)fileExistsAtPath:(NSString *)path completion:(void(^)(BOOL exists, BOOL isDirectory, NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *newURL) {
            BOOL isDirectory;
            BOOL exists = [fileManager fileExistsAtPath:newURL.path isDirectory:&isDirectory];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(exists, isDirectory, nil);
            });
        }];
        
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(NO, NO, error);
            });
        }
    }];
}

- (void)contentsOfDirectoryAtPath:(NSString *)path completion:(void(^)(NSArray *contents, NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *newURL) {
            NSMutableArray *contents = [[NSMutableArray alloc] init];
            NSDirectoryEnumerator *dirEnum = [fileManager enumeratorAtPath:[self fullPathForPath:path]];
            NSString *filename;
            while ((filename = [dirEnum nextObject])) {
                if ([filename hasPrefix:@"."]) continue; // Skip .DS_Store and other system files
                NSString *filePath = [path stringByAppendingPathComponent:filename];
                if ([dirEnum.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) {
                    [dirEnum skipDescendants];
                    
                    CDECloudDirectory *dir = [[CDECloudDirectory alloc] init];
                    dir.name = filename;
                    dir.path = filePath;
                    [contents addObject:dir];
                }
                else {
                    CDECloudFile *file = [CDECloudFile new];
                    file.name = filename;
                    file.path = filePath;
                    file.size = dirEnum.fileAttributes.fileSize;
                    [contents addObject:file];
                }
            }
            
            if (block) dispatch_async(dispatch_get_main_queue(), ^{
                block(contents, nil);
            });
        }];
        
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(nil, error);
            });
        }
    }];

}

- (void)createDirectoryAtPath:(NSString *)path completion:(CDECompletionBlock)block
{
    [operationQueue addOperationWithBlock:^{
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateWritingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *newURL) {
            NSError *fileManagerError = nil;
            [fileManager createDirectoryAtPath:newURL.path withIntermediateDirectories:NO attributes:nil error:&fileManagerError];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(fileManagerError);
            });
        }];
        
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(error);
            });
        }
    }];
}

- (void)removeItemAtPath:(NSString *)path completion:(CDECompletionBlock)block
{
    [operationQueue addOperationWithBlock:^{
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForDeleting error:&error byAccessor:^(NSURL *newURL) {
            NSError *fileManagerError = nil;
            [fileManager removeItemAtPath:newURL.path error:&fileManagerError];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(fileManagerError);
            });
        }];
        
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(error);
            });
        }
    }];
}

- (void)uploadLocalFile:(NSString *)fromPath toPath:(NSString *)toPath completion:(CDECompletionBlock)block
{
    [operationQueue addOperationWithBlock:^{
        NSError *error = nil;
        NSURL *fromURL = [NSURL fileURLWithPath:fromPath];
        NSURL *toURL = [NSURL fileURLWithPath:[self fullPathForPath:toPath]];

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:fromURL options:0 writingItemAtURL:toURL options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
            NSError *fileManagerError = nil;
            [fileManager removeItemAtPath:newWritingURL.path error:NULL];
            [fileManager copyItemAtPath:newReadingURL.path toPath:newWritingURL.path error:&fileManagerError];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(fileManagerError);
            });
        }];
        
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(error);
            });
        }
    }];
}

- (void)downloadFromPath:(NSString *)fromPath toLocalFile:(NSString *)toPath completion:(CDECompletionBlock)block
{
    [operationQueue addOperationWithBlock:^{
        NSError *error = nil;
        NSURL *fromURL = [NSURL fileURLWithPath:[self fullPathForPath:fromPath]];
        NSURL *toURL = [NSURL fileURLWithPath:toPath];
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:fromURL options:0 writingItemAtURL:toURL options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
            NSError *fileManagerError = nil;
            [fileManager removeItemAtPath:newWritingURL.path error:NULL];
            [fileManager copyItemAtPath:newReadingURL.path toPath:newWritingURL.path error:&fileManagerError];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(fileManagerError);
            });
        }];
        
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(error);
            });
        }
    }];
}

@end
