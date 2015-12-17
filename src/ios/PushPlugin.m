/*
 Copyright 2009-2011 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binaryform must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided withthe distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

//  See GGLInstanceID.h
#define GMP_NO_MODULES true

#import "PushPlugin.h"
#import "CloudMessaging.h"
#import <objc/runtime.h>

@implementation PushPlugin: CDVPlugin

@synthesize notificationMessage;
@synthesize isInline;

@synthesize callbackId;
@synthesize notificationCallbackId;
@synthesize callback;
@synthesize clearBadge;
@synthesize handlerObj;

@synthesize usesGCM;
@synthesize gcmSandbox;
@synthesize gcmSenderId;
@synthesize gcmRegistrationOptions;
@synthesize gcmRegistrationHandler;
@synthesize gcmRegistrationToken;
@synthesize gcmTopics;

static char launchNotificationKey;

static BOOL registerSuccessMethodFound = NO;
static BOOL registeFailMethodFound = NO;
static BOOL receivedNotifFound = NO;
static BOOL becomeActiveFound = NO;

-(void)initGCMRegistrationHandler;
{
    __weak __block PushPlugin *weakSelf = self;
    gcmRegistrationHandler = ^(NSString *registrationToken, NSError *error){
        if (registrationToken != nil) {
            NSLog(@"GCM Registration Token: %@", registrationToken);
            [weakSelf setGcmRegistrationToken: registrationToken];

            id topics = [weakSelf gcmTopics];
            if (topics != nil) {
                for (NSString *topic in topics) {
                    NSLog(@"subscribe from topic: %@", topic);
                    id pubSub = [GCMPubSub sharedInstance];
                    [pubSub subscribeWithToken: [weakSelf gcmRegistrationToken]
                        topic:[NSString stringWithFormat:@"/topics/%@", topic]
                        options:nil
                        handler:^void(NSError *error) {
                            if (error) {
                                if (error.code == 3001) {
                                    NSLog(@"Already subscribed to %@", topic);
                                } else {
                                    NSLog(@"Failed to subscribe to topic %@: %@", topic, error);
                                }
                            }
                            else {
                                NSLog(@"Successfully subscribe to topic %@", topic);
                            }
                    }];
                }
            }

            [weakSelf registerWithToken:registrationToken];
        } else {
            NSLog(@"Registration to GCM failed with error: %@", error.localizedDescription);
            [weakSelf failWithMessage:@"" withError:error];
        }
    };
}

//  GCM refresh token
//  Unclear how this is testable under normal circumstances
- (void)onTokenRefresh {
#if !TARGET_IPHONE_SIMULATOR
    // A rotation of the registration tokens is happening, so the app needs to request a new token.
    NSLog(@"The GCM registration token needs to be changed.");
    [[GGLInstanceID sharedInstance] tokenWithAuthorizedEntity:[self gcmSenderId]
                                                        scope:kGGLInstanceIDScopeGCM
                                                      options:[self gcmRegistrationOptions]
                                                      handler:[self gcmRegistrationHandler]];
#endif
}

- (void)willSendDataMessageWithID:(NSString *)messageID error:(NSError *)error {
    NSLog(@"willSendDataMessageWithID");
    if (error) {
        // Failed to send the message.
    } else {
        // Will send message, you can save the messageID to track the message
    }
}

- (void)didSendDataMessageWithID:(NSString *)messageID {
    NSLog(@"willSendDataMessageWithID");
    // Did successfully send message identified by messageID
}

- (void)didDeleteMessagesOnServer {
    NSLog(@"didDeleteMessagesOnServer");
    // Some messages sent to this device were deleted on the GCM server before reception, likely
    // because the TTL expired. The client should notify the app server of this, so that the app
    // server can resend those messages.
}

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{

        unsigned int numberOfClasses = 0;
        Class *classes = objc_copyClassList(&numberOfClasses);
        Class appDelegateClass = nil;
        for (unsigned int i = 0; i < numberOfClasses; ++i) {
            if (class_conformsToProtocol(classes[i], @protocol(UIApplicationDelegate))) {
                appDelegateClass = classes[i];
            }
        }
        receivedNotifFound = MethodSwizzle(appDelegateClass, @selector(application:didReceiveRemoteNotification:), @selector(application:didReceiveRemoteNotification:));

        registerSuccessMethodFound = MethodSwizzle(appDelegateClass, @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:), @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:));


        registeFailMethodFound = MethodSwizzle(appDelegateClass, @selector(application:didFailToRegisterForRemoteNotificationsWithError:), @selector(didFailToRegisterForRemoteNotificationsWithError:));

        receivedNotifFound = MethodSwizzle(appDelegateClass, @selector(applicationDidBecomeActive:), @selector(applicationDidBecomeActive:));


        NSLog(@"Register success method found? %d Register fail method found? %d Receive found %d?", registerSuccessMethodFound, registeFailMethodFound , receivedNotifFound);

    });
}

// Replace or Exchange method implementations
// Return YES if method was exchanged, NO if replaced
BOOL MethodSwizzle(Class clazz, SEL originalSelector, SEL overrideSelector)
{
    Method originalMethod = class_getInstanceMethod(clazz, originalSelector);
    Method overrideMethod = class_getInstanceMethod([PushPlugin class], overrideSelector);

    // try to add, if it does not exist, replace
    if (class_addMethod(clazz, originalSelector, method_getImplementation(overrideMethod), method_getTypeEncoding(overrideMethod))) {
        class_replaceMethod(clazz, overrideSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
    }
    // add failed, so we exchange
    else {
        method_exchangeImplementations(originalMethod, overrideMethod);
        return YES;
    }

    return NO;
}

- (void)unregister:(CDVInvokedUrlCommand*)command;
{
    self.callbackId = command.callbackId;

    NSArray* topics = [command argumentAtIndex:0];

    if (topics != nil) {
        id pubSub = [GCMPubSub sharedInstance];
        for (NSString *topic in topics) {
            NSLog(@"unsubscribe from topic: %@", topic);
            [pubSub unsubscribeWithToken: [self gcmRegistrationToken]
                topic:topic
                options:nil
                handler:^void(NSError *error) {
                    if (error) {
                        NSLog(@"Failed to unsubscribe from topic %@: %@", topic, error);
                    }
                    else {
                        NSLog(@"Successfully unsubscribe from topic %@", topic);
                    }
            }];
        }
    } else {
        [[UIApplication sharedApplication] unregisterForRemoteNotifications];
        [self successWithMessage:@"unregistered"];
    }
}

// HS TODO NEED TO TEST THIS - ADDED
// This code will be called immediately after application:didFinishLaunchingWithOptions:. We need
// to process notifications in cold-start situations
- (void)createNotificationChecker:(NSNotification *)notification
{
    if (notification)
    {
        NSDictionary *launchOptions = [notification userInfo];
        if (launchOptions)
            self.launchNotification = [launchOptions objectForKey: @"UIApplicationLaunchOptionsRemoteNotificationKey"];
    }
}

// HS TODO NEED TO TEST THIS - ADDED
// The accessors use an Associative Reference since you can't define a iVar in a category
// http://developer.apple.com/library/ios/#documentation/cocoa/conceptual/objectivec/Chapters/ocAssociativeReferences.html
- (NSMutableArray *)launchNotification
{
    return objc_getAssociatedObject(self, &launchNotificationKey);
}
- (void)setLaunchNotification:(NSDictionary *)aDictionary
{
    objc_setAssociatedObject(self, &launchNotificationKey, aDictionary, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)dealloc
{
    self.launchNotification = nil; // clear the association and release the object
}

- (void)init:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^ {

        NSLog(@"Push Plugin register called");
        self.callbackId = command.callbackId;

        NSMutableDictionary* options = [command.arguments objectAtIndex:0];
        NSMutableDictionary* iosOptions = [options objectForKey:@"ios"];

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
        UIUserNotificationType UserNotificationTypes = UIUserNotificationTypeNone;
#endif
        UIRemoteNotificationType notificationTypes = UIRemoteNotificationTypeNone;

        id badgeArg = [iosOptions objectForKey:@"badge"];
        id soundArg = [iosOptions objectForKey:@"sound"];
        id alertArg = [iosOptions objectForKey:@"alert"];
        id clearBadgeArg = [iosOptions objectForKey:@"clearBadge"];

        if (([badgeArg isKindOfClass:[NSString class]] && [badgeArg isEqualToString:@"true"]) || [badgeArg boolValue])
        {
            notificationTypes |= UIRemoteNotificationTypeBadge;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
            UserNotificationTypes |= UIUserNotificationTypeBadge;
#endif
        }

        if (([soundArg isKindOfClass:[NSString class]] && [soundArg isEqualToString:@"true"]) || [soundArg boolValue])
        {
            notificationTypes |= UIRemoteNotificationTypeSound;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
            UserNotificationTypes |= UIUserNotificationTypeSound;
#endif
        }

        if (([alertArg isKindOfClass:[NSString class]] && [alertArg isEqualToString:@"true"]) || [alertArg boolValue])
        {
            notificationTypes |= UIRemoteNotificationTypeAlert;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
            UserNotificationTypes |= UIUserNotificationTypeAlert;
#endif
        }

        notificationTypes |= UIRemoteNotificationTypeNewsstandContentAvailability;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
        UserNotificationTypes |= UIUserNotificationActivationModeBackground;
#endif

        if (clearBadgeArg == nil || ([clearBadgeArg isKindOfClass:[NSString class]] && [clearBadgeArg isEqualToString:@"false"]) || ![clearBadgeArg boolValue]) {
            NSLog(@"PushPlugin.register: setting badge to false");
            clearBadge = NO;
        } else {
            NSLog(@"PushPlugin.register: setting badge to true");
            clearBadge = YES;
            [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
        }
        NSLog(@"PushPlugin.register: clear badge is set to %d", clearBadge);

        if (notificationTypes == UIRemoteNotificationTypeNone)
            NSLog(@"PushPlugin.register: Push notification type is set to none");

        isInline = NO;

        NSLog(@"PushPlugin.register: better button setup");
        // setup action buttons
        id categoryOptions = [iosOptions objectForKey:@"categories"];
        NSMutableSet *categories = [self createCategories: categoryOptions];

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
        if ([[UIApplication sharedApplication]respondsToSelector:@selector(registerUserNotificationSettings:)]) {
            UIUserNotificationSettings *settings = [UIUserNotificationSettings settingsForTypes:UserNotificationTypes categories:categories];
            [[UIApplication sharedApplication] registerUserNotificationSettings:settings];
            [[UIApplication sharedApplication] registerForRemoteNotifications];
        } else {
            [[UIApplication sharedApplication] registerForRemoteNotificationTypes:
             (UIRemoteNotificationTypeBadge | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeAlert)];
        }
#else
        [[UIApplication sharedApplication] registerForRemoteNotificationTypes:
         (UIRemoteNotificationTypeBadge | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeAlert)];
#endif

        //  GCM options
        [self setGcmSenderId: [iosOptions objectForKey:@"senderID"]];
        NSLog(@"GCM Sender ID %@", gcmSenderId);
        if([[self gcmSenderId] length] > 0) {
            NSLog(@"Using GCM Notification");
            [self setUsesGCM: YES];
            [self initGCMRegistrationHandler];
        } else {
            NSLog(@"Using APNS Notification");
            [self setUsesGCM:NO];
        }
        id gcmSandBoxArg = [iosOptions objectForKey:@"gcmSandbox"];

        [self setGcmSandbox:@NO];
        if ([self usesGCM] &&
            (([gcmSandBoxArg isKindOfClass:[NSString class]] && [gcmSandBoxArg isEqualToString:@"true"]) ||
             [gcmSandBoxArg boolValue]))
        {
            NSLog(@"Using GCM Sandbox");
            [self setGcmSandbox:@YES];
        }

        if (notificationMessage)			// if there is a pending startup notification
            [self notificationReceived];	// go ahead and process it

    }];
}

- (NSMutableSet *) createCategories:(NSDictionary *)categoryOptions {
    NSMutableSet *categories = [[NSMutableSet alloc] init];
    if (categoryOptions != nil && [categoryOptions isKindOfClass:[NSDictionary class]]) {
        for (id key in categoryOptions) {
            NSLog(@"categories: key %@", key);
            id category = [categoryOptions objectForKey:key];

            id yesButton = [category objectForKey:@"yes"];
            UIMutableUserNotificationAction *yesAction;
            if (yesButton != nil && [yesButton  isKindOfClass:[NSDictionary class]]) {
                yesAction = [self createAction: yesButton];
            }
            id noButton = [category objectForKey:@"no"];
            UIMutableUserNotificationAction *noAction;
            if (noButton != nil && [noButton  isKindOfClass:[NSDictionary class]]) {
                noAction = [self createAction: noButton];
            }
            id maybeButton = [category objectForKey:@"maybe"];
            UIMutableUserNotificationAction *maybeAction;
            if (maybeButton != nil && [maybeButton  isKindOfClass:[NSDictionary class]]) {
                maybeAction = [self createAction: maybeButton];
            }

            // First create the category
            UIMutableUserNotificationCategory *notificationCategory = [[UIMutableUserNotificationCategory alloc] init];

            // Identifier to include in your push payload and local notification
            notificationCategory.identifier = key;

            NSMutableArray *categoryArray = [[NSMutableArray alloc] init];
            NSMutableArray *minimalCategoryArray = [[NSMutableArray alloc] init];
            if (yesButton != nil) {
                [categoryArray addObject:yesAction];
                [minimalCategoryArray addObject:yesAction];
            }
            if (noButton != nil) {
                [categoryArray addObject:noAction];
                [minimalCategoryArray addObject:noAction];
            }
            if (maybeButton != nil) {
                [categoryArray addObject:maybeAction];
            }

            // Add the actions to the category and set the action context
            [notificationCategory setActions:categoryArray forContext:UIUserNotificationActionContextDefault];

            // Set the actions to present in a minimal context
            [notificationCategory setActions:minimalCategoryArray forContext:UIUserNotificationActionContextMinimal];

            NSLog(@"Adding category %@", key);
            [categories addObject:notificationCategory];
        }
    }
    return categories;
}

- (void) didFailToRegisterForRemoteNotificationsWithError:(NSError*)error
{
    NSLog(@"didFailtoRegisterForRemoteNotificationsWithError");
    /*if (self.callbackId == nil) {
        NSLog(@"Unexpected call to didFailToRegisterForRemoteNotificationsWithError, ignoring: %@", error);
        return;
    }*/
    NSLog(@"Push Plugin register failed");
    [self failWithMessage:@"" withError:error];

}

- (UIMutableUserNotificationAction *)createAction:(NSDictionary *)dictionary {

    UIMutableUserNotificationAction *myAction = [[UIMutableUserNotificationAction alloc] init];

    myAction = [[UIMutableUserNotificationAction alloc] init];
    myAction.identifier = [dictionary objectForKey:@"callback"];
    myAction.title = [dictionary objectForKey:@"title"];
    id mode =[dictionary objectForKey:@"foreground"];
    if (mode == nil || ([mode isKindOfClass:[NSString class]] && [mode isEqualToString:@"false"]) || ![mode boolValue]) {
        myAction.activationMode = UIUserNotificationActivationModeBackground;
    } else {
        myAction.activationMode = UIUserNotificationActivationModeForeground;
    }
    id destructive = [dictionary objectForKey:@"destructive"];
    if (destructive == nil || ([destructive isKindOfClass:[NSString class]] && [destructive isEqualToString:@"false"]) || ![destructive boolValue]) {
        myAction.destructive = NO;
    } else {
        myAction.destructive = YES;
    }
    myAction.authenticationRequired = NO;

    return myAction;
}

/*
 - (void) application:(UIApplication*)app didRegisterForRemoteNotificationsWithDeviceToken:(NSData*)deviceToken
 {
 NSLog(@"didRegisterForRemoteNotificationsWithDeviceToken");
 }
 */
//- (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
- (void) application:(UIApplication*)app didRegisterForRemoteNotificationsWithDeviceToken:(NSData*)deviceToken
{
    // HS TO DO - Fix callback id coming from AppDelegate
    /*if (self.callbackId == nil) {
        NSLog(@"Unexpected call to didRegisterForRemoteNotificationsWithDeviceToken, ignoring: %@", deviceToken);
        return;
    }*/
    NSLog(@"Push Plugin register success: %@", deviceToken);

    //if (registerSuccessMethodFound)
      //  [self myApplication:application didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];

    NSMutableDictionary *results = [NSMutableDictionary dictionary];
    NSString *token = [[[[deviceToken description] stringByReplacingOccurrencesOfString:@"<"withString:@""]
                        stringByReplacingOccurrencesOfString:@">" withString:@""]
                       stringByReplacingOccurrencesOfString: @" " withString: @""];
    [results setValue:token forKey:@"deviceToken"];

#if !TARGET_IPHONE_SIMULATOR
    // Get Bundle Info for Remote Registration (handy if you have more than one app)
    [results setValue:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"] forKey:@"appName"];
    [results setValue:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] forKey:@"appVersion"];

    // Check what Notifications the user has turned on.  We registered for all three, but they may have manually disabled some or all of them.
#define SYSTEM_VERSION_LESS_THAN(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedAscending)

    NSUInteger rntypes;
    if (!SYSTEM_VERSION_LESS_THAN(@"8.0")) {
        rntypes = [[[UIApplication sharedApplication] currentUserNotificationSettings] types];
    } else {
        rntypes = [[UIApplication sharedApplication] enabledRemoteNotificationTypes];
    }

    // Set the defaults to disabled unless we find otherwise...
    NSString *pushBadge = @"disabled";
    NSString *pushAlert = @"disabled";
    NSString *pushSound = @"disabled";

    // Check what Registered Types are turned on. This is a bit tricky since if two are enabled, and one is off, it will return a number 2... not telling you which
    // one is actually disabled. So we are literally checking to see if rnTypes matches what is turned on, instead of by number. The "tricky" part is that the
    // single notification types will only match if they are the ONLY one enabled.  Likewise, when we are checking for a pair of notifications, it will only be
    // true if those two notifications are on.  This is why the code is written this way
    if(rntypes & UIRemoteNotificationTypeBadge){
        pushBadge = @"enabled";
    }
    if(rntypes & UIRemoteNotificationTypeAlert) {
        pushAlert = @"enabled";
    }
    if(rntypes & UIRemoteNotificationTypeSound) {
        pushSound = @"enabled";
    }

    [results setValue:pushBadge forKey:@"pushBadge"];
    [results setValue:pushAlert forKey:@"pushAlert"];
    [results setValue:pushSound forKey:@"pushSound"];

    // Get the users Device Model, Display Name, Token & Version Number
    UIDevice *dev = [UIDevice currentDevice];
    [results setValue:dev.name forKey:@"deviceName"];
    [results setValue:dev.model forKey:@"deviceModel"];
    [results setValue:dev.systemVersion forKey:@"deviceSystemVersion"];

    if([self usesGCM]) {
        GGLInstanceIDConfig *instanceIDConfig = [GGLInstanceIDConfig defaultConfig];
        instanceIDConfig.delegate = self;
        [[GGLInstanceID sharedInstance] startWithConfig:instanceIDConfig];

        [self setGcmRegistrationOptions: @{kGGLInstanceIDRegisterAPNSOption:deviceToken,
                                     kGGLInstanceIDAPNSServerTypeSandboxOption:[self gcmSandbox]}];

        [[GGLInstanceID sharedInstance] tokenWithAuthorizedEntity:[self gcmSenderId]
                                                            scope:kGGLInstanceIDScopeGCM
                                                          options:[self gcmRegistrationOptions]
                                                          handler:[self gcmRegistrationHandler]];

        GCMConfig *gcmConfig = [GCMConfig defaultConfig];
        //gcmConfig.receiverDelegate = self;
        [[GCMService sharedInstance] startWithConfig:gcmConfig];

    } else {
        [self registerWithToken: token];
    }
#endif
}

- (id) getCommandInstance:(NSString*)className
{
    //[UIApplication sharedApplication].delegate;
    //[[[UIApplication sharedApplication].keyWindow.rootViewController getCommandInstance:className] ]
    return [((CDVViewController*)self.viewController)  getCommandInstance:className];

    //return [mvc getCommandInstance:className];
}


- (void)applicationDidBecomeActive:(UIApplication *)application {

    NSLog(@"active");
    //PushPlugin *pushHandler = getCommandInstance;@"PushNotification";
    //PushPlugin *pushHandler = [((CDVViewController*)self.viewController) getCommandInstance:@"PushNotification"];

    // TODO - Fix to get current view controller?
    PushPlugin *pushHandler = [(CDVViewController*)application.keyWindow.rootViewController getCommandInstance:@"PushNotification"];

    if (pushHandler.clearBadge) {
        NSLog(@"PushPlugin clearing badge");
        //zero badge
        application.applicationIconBadgeNumber = 0;
    } else {
        NSLog(@"PushPlugin skip clear badge");
    }

    //if (self.launchNotification) {
    /*if (pushHandler.launchNotification) {
        pushHandler.isInline = NO;
        pushHandler.notificationMessage = self.launchNotification;
        //self.launchNotification = nil;
        pushHandler.launchNotification = nil;
        [pushHandler performSelectorOnMainThread:@selector(notificationReceived) withObject:pushHandler waitUntilDone:NO];
    }*/
}

/*- (application:(UIApplication*)app didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {*/
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))backgroundCompletionHandler {
    NSLog(@"didReceiveNotification with fetchCompletionHandler");

    // app is in the foreground so call notification callback
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        NSLog(@"app active");
        notificationMessage = userInfo;
        self.isInline = YES;
        [self notificationReceived];

        //HS TODO - NOT SURE IF completionHandler code is right or working - review all code
        backgroundCompletionHandler(UIBackgroundFetchResultNewData);
    }
    // app is in background or in stand by
    else {
        NSLog(@"app inactive");

        // do some convoluted logic to find out if this should be a silent push.
        long silent = 0;
        id aps = [userInfo objectForKey:@"aps"];
        id contentAvailable = [aps objectForKey:@"content-available"];
        if ([contentAvailable isKindOfClass:[NSString class]] && [contentAvailable isEqualToString:@"1"]) {
            silent = 1;
        } else if ([contentAvailable isKindOfClass:[NSNumber class]]) {
            silent = [contentAvailable integerValue];
        }

        if (silent == 1) {
            NSLog(@"this should be a silent push");
            void (^safeHandler)(UIBackgroundFetchResult) = ^(UIBackgroundFetchResult result){
                dispatch_async(dispatch_get_main_queue(), ^{
                    backgroundCompletionHandler(result);
                });
            };

            NSMutableDictionary* params = [NSMutableDictionary dictionaryWithCapacity:2];
            [params setObject:safeHandler forKey:@"handler"];

            notificationMessage = userInfo;
            self.isInline = NO;
            self.handlerObj = params;
            [self notificationReceived];
        } else {
            NSLog(@"just put it in the shade");
            //save it for later
            self.launchNotification = userInfo;

            backgroundCompletionHandler(UIBackgroundFetchResultNewData);
        }
    }
}

- (void)notificationReceived {
    NSLog(@"Notification received");

    if (notificationMessage && self.callbackId != nil)
    {
        NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:4];
        NSMutableDictionary* additionalData = [NSMutableDictionary dictionaryWithCapacity:4];


        for (id key in notificationMessage) {
            if ([key isEqualToString:@"aps"]) {
                id aps = [notificationMessage objectForKey:@"aps"];

                for(id key in aps) {
                    NSLog(@"Push Plugin key: %@", key);
                    id value = [aps objectForKey:key];

                    if ([key isEqualToString:@"alert"]) {
                        if ([value isKindOfClass:[NSDictionary class]]) {
                            for (id messageKey in value) {
                                id messageValue = [value objectForKey:messageKey];
                                if ([messageKey isEqualToString:@"body"]) {
                                    [message setObject:messageValue forKey:@"message"];
                                } else if ([messageKey isEqualToString:@"title"]) {
                                    [message setObject:messageValue forKey:@"title"];
                                } else {
                                    [additionalData setObject:messageValue forKey:messageKey];
                                }
                            }
                        }
                        else {
                            [message setObject:value forKey:@"message"];
                        }
                    } else if ([key isEqualToString:@"title"]) {
                        [message setObject:value forKey:@"title"];
                    } else if ([key isEqualToString:@"badge"]) {
                        [message setObject:value forKey:@"count"];
                    } else if ([key isEqualToString:@"sound"]) {
                        [message setObject:value forKey:@"sound"];
                    } else if ([key isEqualToString:@"image"]) {
                        [message setObject:value forKey:@"image"];
                    } else {
                        [additionalData setObject:value forKey:key];
                    }
                }
            } else {
                [additionalData setObject:[notificationMessage objectForKey:key] forKey:key];
            }
        }

        if (isInline) {
            [additionalData setObject:[NSNumber numberWithBool:YES] forKey:@"foreground"];
        } else {
            [additionalData setObject:[NSNumber numberWithBool:NO] forKey:@"foreground"];
        }

        [message setObject:additionalData forKey:@"additionalData"];

        // send notification message
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
        [pluginResult setKeepCallbackAsBool:YES];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];

        notificationMessage = nil;
    }
}

- (void)setApplicationIconBadgeNumber:(CDVInvokedUrlCommand *)command
{
    NSMutableDictionary* options = [command.arguments objectAtIndex:0];
    int badge = [[options objectForKey:@"badge"] intValue] ?: 0;

    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:badge];

    NSString* message = [NSString stringWithFormat:@"app badge count set to %d", badge];
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)getApplicationIconBadgeNumber:(CDVInvokedUrlCommand *)command
{
    NSInteger badge = [UIApplication sharedApplication].applicationIconBadgeNumber;

    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(int)badge];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)hasPermission:(CDVInvokedUrlCommand *)command
{
    BOOL enabled = NO;
    id<UIApplicationDelegate> appDelegate = [UIApplication sharedApplication].delegate;
    if ([appDelegate respondsToSelector:@selector(userHasRemoteNotificationsEnabled)]) {
        enabled = [appDelegate performSelector:@selector(userHasRemoteNotificationsEnabled)];
    }

    NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:1];
    [message setObject:[NSNumber numberWithBool:enabled] forKey:@"isEnabled"];
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

-(void)successWithMessage:(NSString *)message
{
    if (self.callbackId != nil)
    {
        CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
        [self.commandDelegate sendPluginResult:commandResult callbackId:self.callbackId];
    }
}

-(void)registerWithToken:(NSString*)token; {
    // Send result to trigger 'registration' event but keep callback
    NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:1];
    [message setObject:token forKey:@"registrationId"];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
    [pluginResult setKeepCallbackAsBool:YES];

    //HS TODO - this line doesn't work because self is AppDelegate now
    //[self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    PushPlugin *pushHandler = [(CDVViewController*)[UIApplication sharedApplication].keyWindow.rootViewController getCommandInstance:@"PushNotification"];
    [pushHandler.commandDelegate sendPluginResult:pluginResult callbackId:pushHandler.callbackId];
}


-(void)failWithMessage:(NSString *)message withError:(NSError *)error
{
    NSString *errorMessage = (error) ? [NSString stringWithFormat:@"%@ - %@", message, [error localizedDescription]] : message;
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];

    [self.commandDelegate sendPluginResult:commandResult callbackId:self.callbackId];
}

-(void) finish:(CDVInvokedUrlCommand*)command
{
    NSLog(@"Push Plugin finish called");

    [self.commandDelegate runInBackground:^ {
        UIApplication *app = [UIApplication sharedApplication];
        float finishTimer = (app.backgroundTimeRemaining > 20.0) ? 20.0 : app.backgroundTimeRemaining;

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:finishTimer
                                       target:self
                                       selector:@selector(stopBackgroundTask:)
                                       userInfo:nil
                                       repeats:NO];
        });

        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

-(void)stopBackgroundTask:(NSTimer*)timer
{
    UIApplication *app = [UIApplication sharedApplication];

    NSLog(@"Push Plugin stopBackgroundTask called");

    if (handlerObj) {
        NSLog(@"Push Plugin handlerObj");
        completionHandler = [handlerObj[@"handler"] copy];
        if (completionHandler) {
            NSLog(@"Push Plugin: stopBackgroundTask (remaining t: %f)", app.backgroundTimeRemaining);
            completionHandler(UIBackgroundFetchResultNewData);
            completionHandler = nil;
        }
    }
}


@end
