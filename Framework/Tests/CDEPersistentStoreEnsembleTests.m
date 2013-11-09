//
//  CDEPersistentStoreEnsembleTests.m
//  Ensembles Mac
//
//  Created by Drew McCormack on 25/09/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "CDEEventStore.h"
#import "CDEPersistentStoreEnsemble.h"
#import "CDELocalCloudFileSystem.h"

@interface CDEMockLocalFileSystem : CDELocalCloudFileSystem

@property (nonatomic, readwrite) id <NSObject, NSCoding, NSCopying> identityToken;

@end

@implementation CDEMockLocalFileSystem {
    id <NSObject, NSCopying, NSCoding> _identityToken;
}

- (id <NSObject, NSCopying, NSCoding>)identityToken
{
    return _identityToken;
}

- (void)setIdentityToken:(id <NSObject, NSCopying, NSCoding>)newToken
{
    _identityToken = newToken;
}

@end


@interface CDEPersistentStoreEnsemble (CDETestMethods)

- (CDEEventStore *)eventStore;

@end


@interface CDEPersistentStoreEnsembleTests : XCTestCase <CDEPersistentStoreEnsembleDelegate>

@end

@implementation CDEPersistentStoreEnsembleTests {
    CDEPersistentStoreEnsemble *ensemble;
    CDEMockLocalFileSystem *cloudFileSystem;
    NSString *cloudDir;
    NSURL *storeURL;
    BOOL tokenChangeCausedDeleech;
    BOOL finishedAsync;
}

- (void)setUp
{
    [super setUp];
    
    cloudDir = [NSTemporaryDirectory() stringByAppendingString:@"CDEPersistentStoreEnsembleTests"];
    [[NSFileManager defaultManager] removeItemAtPath:cloudDir error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:cloudDir withIntermediateDirectories:YES attributes:nil error:NULL];

    cloudFileSystem = (id)[[CDEMockLocalFileSystem alloc] initWithRootDirectory:cloudDir];
    cloudFileSystem.identityToken = @"first";
    
    NSString *storePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"teststore.sqlite"];
    storeURL = [NSURL fileURLWithPath:storePath];
    [[NSFileManager defaultManager] removeItemAtURL:storeURL error:NULL];
    
    NSURL *testModelURL = [[NSBundle bundleForClass:self.class] URLForResource:@"CDEStoreModificationEventTestsModel" withExtension:@"momd"];
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:testModelURL];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:NULL];
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
    context.persistentStoreCoordinator = coordinator;
    [NSEntityDescription insertNewObjectForEntityForName:@"Parent" inManagedObjectContext:context];
    [context save:NULL];
    
    ensemble = [[CDEPersistentStoreEnsemble alloc] initWithEnsembleIdentifier:@"testensemble" persistentStorePath:storePath managedObjectModelURL:testModelURL cloudFileSystem:(id)cloudFileSystem];
    ensemble.delegate = self;
    
    tokenChangeCausedDeleech = NO;
}

- (void)tearDown
{
    NSArray *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSString *appSupportDir = [urls.lastObject path];
    NSString *eventStoreRoot = [appSupportDir stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]];
    eventStoreRoot = [eventStoreRoot stringByAppendingPathComponent:@"com.mentalfaculty.ensembles.eventdata"];
    [[NSFileManager defaultManager] removeItemAtPath:eventStoreRoot error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:cloudDir error:NULL];
    [[NSFileManager defaultManager] removeItemAtURL:storeURL error:NULL];
    [super tearDown];
}

- (void)waitForAsync
{
    finishedAsync = NO;
    while (!finishedAsync) CFRunLoopRun();
}

- (void)finishAsync
{
    finishedAsync = YES;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)testInitialization
{
    XCTAssertNotNil(ensemble, @"Ensemble should not be nil");
}

- (void)testLeech
{
    [ensemble leechPersistentStoreWithCompletion:^(NSError *error) {
        XCTAssertNil(error, @"Error occurred while leeching");
        [self finishAsync];
    }];
    [self waitForAsync];
}

- (void)testDeleech
{
    [ensemble leechPersistentStoreWithCompletion:^(NSError *error) {
        XCTAssertNil(error, @"Error occurred while leeching");
        [ensemble deleechPersistentStoreWithCompletion:^(NSError *error) {
            XCTAssertNil(error, @"Error occurred while deleeching");
            [self finishAsync];
        }];
    }];
    [self waitForAsync];
}

- (void)testDeleechWithoutLeech
{
    [ensemble deleechPersistentStoreWithCompletion:^(NSError *error) {
        XCTAssertNotNil(error, @"Error should occur while deleeching");
        [self finishAsync];
    }];
    [self waitForAsync];
}

- (void)testChangingIdentityTokenCausesDeleech
{
    XCTAssertFalse(tokenChangeCausedDeleech, @"Should be NO");
    [ensemble leechPersistentStoreWithCompletion:^(NSError *error) {
        XCTAssertNil(error, @"Error occurred while leeching");
        cloudFileSystem.identityToken = @"second";
        [self performSelector:@selector(checkForDeleech) withObject:nil afterDelay:0.05];
    }];
    [self waitForAsync];
}

- (void)testInitWithIncompleteMandatoryEventsCausesDeleech
{
    [ensemble leechPersistentStoreWithCompletion:^(NSError *error) {
        XCTAssertNil(error, @"Error occurred while leeching");
        [[ensemble eventStore] registerIncompleteEventIdentifier:@"123" isMandatory:YES];
        [self finishAsync];
    }];
    [self waitForAsync];
    
    [ensemble processPendingChangesWithCompletion:^(NSError *error) {
        [self finishAsync];
    }];
    [self waitForAsync];
    
    ensemble = [[CDEPersistentStoreEnsemble alloc] initWithEnsembleIdentifier:@"testensemble" persistentStorePath:ensemble.storePath managedObjectModelURL:ensemble.managedObjectModelURL cloudFileSystem:(id)cloudFileSystem];
    ensemble.delegate = self;
    
    [self performSelector:@selector(checkForDeleech) withObject:nil afterDelay:0.05];
    [self waitForAsync];
}

- (void)testInitWithIncompleteNonMandatoryEventsDoesNotCauseDeleech
{
    [ensemble leechPersistentStoreWithCompletion:^(NSError *error) {
        XCTAssertNil(error, @"Error occurred while leeching");
        [[ensemble eventStore] registerIncompleteEventIdentifier:@"123" isMandatory:NO];
        [self finishAsync];
    }];
    [self waitForAsync];
    
    ensemble = [[CDEPersistentStoreEnsemble alloc] initWithEnsembleIdentifier:@"testensemble" persistentStorePath:ensemble.storePath managedObjectModelURL:ensemble.managedObjectModelURL cloudFileSystem:(id)cloudFileSystem];
    ensemble.delegate = self;
    
    [self performSelector:@selector(checkForLeech) withObject:nil afterDelay:0.05];
    [self waitForAsync];
    
    [ensemble deleechPersistentStoreWithCompletion:^(NSError *error) {
        [self finishAsync];
    }];
    [self waitForAsync];
}

- (void)checkForLeech
{
    XCTAssert(!tokenChangeCausedDeleech, @"A deleech occurred when it shouldn't have");
    [self finishAsync];
}

- (void)checkForDeleech
{
    XCTAssert(tokenChangeCausedDeleech, @"No deleech occurred");
    [self finishAsync];
}

- (void)persistentStoreEnsemble:(CDEPersistentStoreEnsemble *)ensemble didDeleechWithError:(NSError *)error
{
    tokenChangeCausedDeleech = YES;
}

@end
