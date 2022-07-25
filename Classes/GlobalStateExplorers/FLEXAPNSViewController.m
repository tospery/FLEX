//
//  FLEXAPNSViewController.m
//  FLEX
//
//  Created by Tanner Bennett on 6/28/22.
//  Copyright © 2022 FLEX Team. All rights reserved.
//

#import "FLEXAPNSViewController.h"
#import "FLEXObjectExplorerFactory.h"
#import "FLEXMutableListSection.h"
#import "FLEXSingleRowSection.h"
#import "NSUserDefaults+FLEX.h"
#import "UIBarButtonItem+FLEX.h"
#import "NSDateFormatter+FLEX.h"
#import "FLEXResources.h"
#import "FLEXUtility.h"
#import "FLEXRuntimeUtility.h"
#import "flex_fishhook.h"
#import <dlfcn.h>
#import <UserNotifications/UserNotifications.h>

#define orig(method, ...) if (orig_##method) { orig_##method(__VA_ARGS__); }

@interface FLEXAPNSViewController ()
@property (nonatomic, readonly, class) Class appDelegateClass;
@property (nonatomic, class) NSData *deviceToken;
@property (nonatomic, class) NSError *registrationError;
@property (nonatomic, readonly, class) NSMutableArray<NSDictionary *> *remoteNotifications;
@property (nonatomic, readonly, class) NSMutableArray<UNNotification *> *userNotifications;

@property (nonatomic) FLEXSingleRowSection *deviceToken;
@property (nonatomic) FLEXMutableListSection<NSDictionary *> *remoteNotifications;
@property (nonatomic) FLEXMutableListSection<UNNotification *> *userNotifications;
@end

@implementation FLEXAPNSViewController

#pragma mark Swizzles

/// Hook User Notifications related methods on the app delegate
/// and UNUserNotificationCenter delegate classes
+ (void)load { FLEX_EXIT_IF_NO_CTORS()
    if (!NSUserDefaults.standardUserDefaults.flex_enableAPNSCapture) {
        return;
    }
    
    //──────────────────────//
    //     App Delegate     //
    //──────────────────────//

    // Hook UIApplication to intercept app delegate
    Class uiapp = UIApplication.self;
    auto orig_uiapp_setDelegate = (void(*)(id, SEL, id))class_getMethodImplementation(
        uiapp, @selector(setDelegate:)
    );
    
    IMP uiapp_setDelegate = imp_implementationWithBlock(^(id _, id delegate) {
        [self hookAppDelegateClass:[delegate class]];
        orig_uiapp_setDelegate(_, @selector(setDelegate:), delegate);
    });
    
    class_replaceMethod(
        uiapp,
        @selector(setDelegate:),
        uiapp_setDelegate,
        "v@:@"
    );
    
    //───────────────────────────────────────────//
    //     UNUserNotificationCenter Delegate     //
    //───────────────────────────────────────────//
    
    Class unusernc = UNUserNotificationCenter.self;
    auto orig_unusernc_setDelegate = (void(*)(id, SEL, id))class_getMethodImplementation(
        unusernc, @selector(setDelegate:)
    );
    
    IMP unusernc_setDelegate = imp_implementationWithBlock(^(id _, id delegate) {
        [self hookUNUserNotificationCenterDelegateClass:[delegate class]];
        orig_unusernc_setDelegate(_, @selector(setDelegate:), delegate);
    });
    
    class_replaceMethod(
        unusernc,
        @selector(setDelegate:),
        unusernc_setDelegate,
        "v@:@"
    );
}

+ (void)hookAppDelegateClass:(Class)appDelegate {
    // Abort if we already hooked something
    if (_appDelegateClass) {
        return;
    }
    
    _appDelegateClass = appDelegate;
    
    auto types_didRegisterForRemoteNotificationsWithDeviceToken = "v@:@@";
    auto types_didFailToRegisterForRemoteNotificationsWithError = "v@:@@";
    auto types_didReceiveRemoteNotification = "v@:@@@?";
    
    auto orig_didRegisterForRemoteNotificationsWithDeviceToken = (void(*)(id, SEL, id, id))class_getMethodImplementation(
        appDelegate, @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:)
    );
    auto orig_didFailToRegisterForRemoteNotificationsWithError = (void(*)(id, SEL, id, id))class_getMethodImplementation(
        appDelegate, @selector(application:didFailToRegisterForRemoteNotificationsWithError:)
    );
    auto orig_didReceiveRemoteNotification = (void(*)(id, SEL, id, id, id))class_getMethodImplementation(
        appDelegate, @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:)
    );
    
    IMP didRegisterForRemoteNotificationsWithDeviceToken = imp_implementationWithBlock(^(id _, id app, NSData *token) {
        self.deviceToken = token;
        orig(didRegisterForRemoteNotificationsWithDeviceToken, _, nil, app, token);
    });
    IMP didFailToRegisterForRemoteNotificationsWithError = imp_implementationWithBlock(^(id _, id app, NSError *error) {
        self.registrationError = error;
        orig(didFailToRegisterForRemoteNotificationsWithError, _, nil, app, error);
    });
    IMP didReceiveRemoteNotification = imp_implementationWithBlock(^(id _, id app, NSDictionary *payload, id handler) {
        // TODO: notify when new notifications are added
        [self.remoteNotifications addObject:payload];
        orig(didReceiveRemoteNotification, _, nil, app, payload, handler);
    });
    
    class_replaceMethod(
        appDelegate,
        @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:),
        didRegisterForRemoteNotificationsWithDeviceToken,
        types_didRegisterForRemoteNotificationsWithDeviceToken
    );
    class_replaceMethod(
        appDelegate,
        @selector(application:didFailToRegisterForRemoteNotificationsWithError:),
        didFailToRegisterForRemoteNotificationsWithError,
        types_didFailToRegisterForRemoteNotificationsWithError
    );
    class_replaceMethod(
        appDelegate,
        @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:),
        didReceiveRemoteNotification,
        types_didReceiveRemoteNotification
    );
}

+ (void)hookUNUserNotificationCenterDelegateClass:(Class)delegate {
    auto types_didReceiveNotificationResponse = "v@:@@@?";
    auto orig_didReceiveNotificationResponse = (void(*)(id, SEL, id, id, id))class_getMethodImplementation(
        delegate, @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)
    );
    
    IMP didReceiveNotification = imp_implementationWithBlock(^(id _, id __, UNNotificationResponse *response, id ___) {
        [self.userNotifications addObject:response.notification];
        orig_didReceiveNotificationResponse(_, nil, __, response, ___);
    });
    
    class_replaceMethod(
        delegate,
        @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:),
        didReceiveNotification,
        types_didReceiveNotificationResponse
    );
}

#pragma mark Class Properties

static Class _appDelegateClass = nil;
+ (Class)appDelegateClass {
    return _appDelegateClass;
}

static NSData *_apnsDeviceToken = nil;
+ (NSData *)deviceToken {
    return _apnsDeviceToken;
}

+ (void)setDeviceToken:(NSData *)deviceToken {
    _apnsDeviceToken = deviceToken;
}

static NSError *_apnsRegistrationError = nil;
+ (NSError *)registrationError {
    return _apnsRegistrationError;
}

+ (void)setRegistrationError:(NSError *)error {
    _apnsRegistrationError = error;
}

+ (NSMutableArray<NSDictionary *> *)userNotifications {
    static NSMutableArray *_userNotifications = nil;
    if (!_userNotifications) {
        _userNotifications = [NSMutableArray new];
    }
    
    return _userNotifications;
}

+ (NSMutableArray<NSDictionary *> *)remoteNotifications {
    static NSMutableArray *_remoteNotifications = nil;
    if (!_remoteNotifications) {
        _remoteNotifications = [NSMutableArray new];
    }
    
    return _remoteNotifications;
}

#pragma mark Instance stuff

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Push Notifications";
    
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadData) forControlEvents:UIControlEventValueChanged];
    
    [self addToolbarItems:@[
        [UIBarButtonItem
            flex_itemWithImage:FLEXResources.gearIcon
            target:self
            action:@selector(settingsButtonTapped)
        ],
    ]];
}

- (NSArray<FLEXTableViewSection *> *)makeSections {
    self.deviceToken = [FLEXSingleRowSection title:@"APNS Device Token" reuse:nil cell:^(UITableViewCell *cell) {
        NSData *token = FLEXAPNSViewController.deviceToken;
        cell.textLabel.text = token ? @(*((NSUInteger *)token.bytes)).stringValue : @"Not yet registered";
        cell.detailTextLabel.text = token.description;
    }];
    self.deviceToken.selectionAction = ^(UIViewController *host) {
        NSData *token = FLEXAPNSViewController.deviceToken;
        if (token) {
            [host.navigationController pushViewController:[
                FLEXObjectExplorerFactory explorerViewControllerForObject:token
            ] animated:YES];
        }
    };
    
    // Remote Notifications //
    
    self.remoteNotifications = [FLEXMutableListSection list:FLEXAPNSViewController.remoteNotifications
        cellConfiguration:^(UITableViewCell *cell, NSDictionary *notif, NSInteger row) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            // TODO: date received
            cell.detailTextLabel.text = [FLEXRuntimeUtility summaryForObject:notif];
        }
        filterMatcher:^BOOL(NSString *filterText, NSDictionary *notif) {
            return [notif.description localizedCaseInsensitiveContainsString:filterText];
        }
    ];
    
    self.remoteNotifications.customTitle = @"Remote Notifications";
    self.remoteNotifications.selectionHandler = ^(UIViewController *host, NSDictionary *notif) {
        [host.navigationController pushViewController:[
            FLEXObjectExplorerFactory explorerViewControllerForObject:notif
        ] animated:YES];
    };
    
    // User Notifications //
    
    self.userNotifications = [FLEXMutableListSection list:FLEXAPNSViewController.userNotifications
        cellConfiguration:^(UITableViewCell *cell, UNNotification *notif, NSInteger row) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            
            // Subtitle is 'subtitle \n date'
            NSString *dateString = [NSDateFormatter flex_stringFrom:notif.date format:FLEXDateFormatPreciseClock];
            NSString *subtitle = notif.request.content.subtitle;
            subtitle = subtitle ? [NSString stringWithFormat:@"%@\n%@", subtitle, dateString] : dateString;
        
            cell.textLabel.text = notif.request.content.title;
            cell.detailTextLabel.text = subtitle;
        }
        filterMatcher:^BOOL(NSString *filterText, NSDictionary *notif) {
            return [notif.description localizedCaseInsensitiveContainsString:filterText];
        }
    ];
    
    self.userNotifications.customTitle = @"Push Notifications";
    self.userNotifications.selectionHandler = ^(UIViewController *host, UNNotification *notif) {
        [host.navigationController pushViewController:[
            FLEXObjectExplorerFactory explorerViewControllerForObject:notif.request
        ] animated:YES];
    };
    
    return @[self.deviceToken, self.remoteNotifications, self.userNotifications];
}

- (void)reloadData {
    [self.refreshControl endRefreshing];
    
    self.remoteNotifications.customTitle = [NSString stringWithFormat:
        @"%@ notifications", @(self.remoteNotifications.filteredList.count)
    ];
    [super reloadData];
}

- (void)settingsButtonTapped {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = defaults.flex_enableAPNSCapture;

    NSString *apnsToggle = enabled ? @"Disable Capture" : @"Enable Capture";
    
    [FLEXAlert makeAlert:^(FLEXAlert *make) {
        make.title(@"Settings")
            .message(@"Enable or disable the capture of push notifications.\n\n")
            .message(@"This will hook UIApplicationMain on launch until it is disabled, ")
            .message(@"and swizzle some app delegate methods. Restart the app for changes to take effect.");
        
        make.button(apnsToggle).destructiveStyle().handler(^(NSArray<NSString *> *strings) {
            [defaults flex_toggleBoolForKey:kFLEXDefaultsAPNSCaptureEnabledKey];
        });
        make.button(@"Dismiss").cancelStyle();
    } showFrom:self];
}

#pragma mark - FLEXGlobalsEntry

+ (NSString *)globalsEntryTitle:(FLEXGlobalsRow)row {
    return @"📌  Push Notifications";
}

+ (UIViewController *)globalsEntryViewController:(FLEXGlobalsRow)row {
    return [self new];
}

@end
