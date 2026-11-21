// ACListViewController.m — 主界面
#import "ACListViewController.h"
#import "ACAppEnumerator.h"
#import "ACCommon.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, ACSection) {
    ACSectionIdentity = 0,   // IDFA / IDFV / ATT
    ACSectionData,           // 文件 / 偏好 / 钥匙串 / 深度
    ACSectionMode,           // 预演
    ACSectionApps,           // 按 App 控制
    ACSectionBulk,           // 批量操作
    ACSectionCount
};

static const void *kSwitchBIDKey = &kSwitchBIDKey;
static const void *kSwitchCfgKey = &kSwitchCfgKey;

static NSString *const kUDKeyIDFA   = @"fakeIDFA";
static NSString *const kUDKeyGlobal = @"globalConfig";

static NSString *const kPrefFile = @"com.zaka.attribclean.plist";

@interface ACListViewController () <UISearchResultsUpdating>

@property (nonatomic, strong) NSMutableArray<ACAppInfo *> *allApps;
@property (nonatomic, strong) NSMutableArray<ACAppInfo *> *shownApps;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledMap;
@property (nonatomic, strong) NSMutableDictionary *globalCfg;
@property (nonatomic, strong) UISearchController *searchCtrl;

// 私有方法提前声明，避免编译器把未知返回类型当成 id
- (NSMutableDictionary *)defaultGlobalConfig;
- (void)loadGlobalConfig;
- (void)saveGlobalConfig;
- (NSString *)prefsPathForApp:(ACAppInfo *)a;
- (NSDictionary *)savedConfigForApp:(ACAppInfo *)a;
- (BOOL)writeConfigForApp:(ACAppInfo *)a enabled:(BOOL)enabled;
- (void)applyGlobalToAllAppsCompletion:(void (^)(NSUInteger ok, NSUInteger fail))completion;
- (void)reloadAll;
- (void)setupSearch;
- (void)applyFilter;
- (void)globalSwitchToggled:(UISwitch *)sw;
- (void)appSwitchToggled:(UISwitch *)sw;
- (void)bulkAllOn;
- (void)bulkAllOff;
- (void)bulkSetAll:(BOOL)on;
- (void)regenerateIdentity;
- (void)toast:(NSString *)text;
- (NSUInteger)enabledCount;
- (UITableViewCell *)switchCell:(NSString *)title sub:(NSString *)sub key:(NSString *)key;
- (UITableViewCell *)appCellAtIndexPath:(NSIndexPath *)ip;
- (UITableViewCell *)actionCellWithTitle:(NSString *)title icon:(NSString *)icon;
- (UIImage *)scaled:(UIImage *)img to:(CGSize)size;
- (void)showLogForApp:(ACAppInfo *)a;

@end

@implementation ACListViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"归因清理";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(reloadAll)];

    self.allApps = [NSMutableArray array];
    self.shownApps = [NSMutableArray array];
    self.enabledMap = [NSMutableDictionary dictionary];

    [self loadGlobalConfig];
    [self setupSearch];
    [self reloadAll];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
}

#pragma mark - 配置

- (NSMutableDictionary *)defaultGlobalConfig {
    return [@{
        kACKeyCleanIDFA     : @YES,
        kACKeyCleanIDFV     : @YES,
        kACKeyCleanATT      : @YES,
        kACKeyCleanFiles    : @YES,
        kACKeyCleanPrefs    : @YES,
        kACKeyCleanKeychain : @YES,
        kACKeyDeepClean     : @NO,
        kACKeyDryRun        : @NO,
    } mutableCopy];
}

- (void)loadGlobalConfig {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kUDKeyGlobal];
    self.globalCfg = [self defaultGlobalConfig];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        [self.globalCfg addEntriesFromDictionary:saved];
    }
}

- (void)saveGlobalConfig {
    [[NSUserDefaults standardUserDefaults] setObject:self.globalCfg forKey:kUDKeyGlobal];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)prefsPathForApp:(ACAppInfo *)a {
    if (!a.dataPath) return nil;
    return [[a.dataPath stringByAppendingPathComponent:@"Library/Preferences"]
            stringByAppendingPathComponent:kPrefFile];
}

- (NSDictionary *)savedConfigForApp:(ACAppInfo *)a {
    NSString *p = [self prefsPathForApp:a];
    if (!p) return nil;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

/// 把全局配置 + 单个 App 的开关合并后写进该 App 的容器
- (BOOL)writeConfigForApp:(ACAppInfo *)a enabled:(BOOL)enabled {
    if (!a.dataPath) return NO;

    @try {
        NSString *dir = [a.dataPath stringByAppendingPathComponent:@"Library/Preferences"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];

        NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
        NSDictionary *exist = [self savedConfigForApp:a];
        if (exist) [cfg addEntriesFromDictionary:exist];

        [cfg addEntriesFromDictionary:self.globalCfg];
        cfg[kACKeyEnabled] = @(enabled);

        NSString *idfa = [[NSUserDefaults standardUserDefaults] stringForKey:kUDKeyIDFA];
        if (idfa.length == 36) cfg[kACKeyFakeIDFA] = idfa;

        BOOL ok = [cfg writeToFile:[self prefsPathForApp:a] atomically:YES];

        // 用户手动动开关，就把这个 App 的熔断计数清掉，等于「恢复自动清理」
        if (ok) {
            NSString *stateFile = [[a.dataPath stringByAppendingPathComponent:
                                    @"Library/Caches/com.zaka.attribclean"]
                                   stringByAppendingPathComponent:@"state.plist"];
            [[NSFileManager defaultManager] removeItemAtPath:stateFile error:NULL];
        }
        return ok;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

/// 把所有已开启 App 的配置按当前全局设置重写一遍
- (void)applyGlobalToAllAppsCompletion:(void (^)(NSUInteger ok, NSUInteger fail))completion {
    NSArray<ACAppInfo *> *apps = [self.allApps copy];
    NSDictionary *enMap = [self.enabledMap copy];
    NSDictionary *global = [self.globalCfg copy];
    NSString *idfa = [[NSUserDefaults standardUserDefaults] stringForKey:kUDKeyIDFA];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger ok = 0, fail = 0;

        for (ACAppInfo *a in apps) {
            @autoreleasepool {
                if (!a.dataPath) continue;
                if (![enMap[a.bundleID] boolValue]) continue;

                @try {
                    NSString *dir = [a.dataPath stringByAppendingPathComponent:@"Library/Preferences"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:NULL];
                    NSString *path = [dir stringByAppendingPathComponent:kPrefFile];

                    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
                    NSDictionary *exist = [NSDictionary dictionaryWithContentsOfFile:path];
                    if ([exist isKindOfClass:[NSDictionary class]]) [cfg addEntriesFromDictionary:exist];

                    [cfg addEntriesFromDictionary:global];
                    cfg[kACKeyEnabled] = @YES;
                    if (idfa.length == 36) cfg[kACKeyFakeIDFA] = idfa;

                    if ([cfg writeToFile:path atomically:YES]) ok++; else fail++;
                } @catch (__unused NSException *e) {
                    fail++;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, fail);
        });
    });
}

#pragma mark - 加载

- (void)reloadAll {
    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<ACAppInfo *> *apps = [ACAppEnumerator installedApps];
        NSMutableDictionary *enMap = [NSMutableDictionary dictionaryWithCapacity:apps.count];

        for (ACAppInfo *a in apps) {
            @autoreleasepool {
                NSString *p = a.dataPath
                    ? [[a.dataPath stringByAppendingPathComponent:@"Library/Preferences"]
                       stringByAppendingPathComponent:kPrefFile]
                    : nil;
                NSDictionary *cfg = p ? [NSDictionary dictionaryWithContentsOfFile:p] : nil;
                enMap[a.bundleID] = @([cfg[kACKeyEnabled] boolValue]);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self_ = weakSelf;
            if (!self_) return;
            self_.allApps = [apps mutableCopy];
            self_.enabledMap = enMap;
            [self_ applyFilter];
            [self_.tableView reloadData];
        });
    });
}

#pragma mark - 搜索

- (void)setupSearch {
    self.searchCtrl = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchCtrl.searchResultsUpdater = self;
    self.searchCtrl.obscuresBackgroundDuringPresentation = NO;
    self.searchCtrl.searchBar.placeholder = @"搜索 App 名称或 Bundle ID";

    if (@available(iOS 15.0, *)) {
        self.navigationItem.searchController = self.searchCtrl;
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
    }
    self.definesPresentationContext = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)ctrl {
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)applyFilter {
    NSString *q = self.searchCtrl.searchBar.text.lowercaseString;
    if (q.length == 0) {
        self.shownApps = [self.allApps mutableCopy];
        return;
    }
    NSMutableArray *r = [NSMutableArray array];
    for (ACAppInfo *a in self.allApps) {
        NSString *hay = [NSString stringWithFormat:@"%@ %@", a.name ?: @"", a.bundleID ?: @""].lowercaseString;
        if ([hay containsString:q]) [r addObject:a];
    }
    self.shownApps = r;
}

#pragma mark - 开关动作

- (void)globalSwitchToggled:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, kSwitchCfgKey);
    if (![key isKindOfClass:[NSString class]]) return;

    self.globalCfg[key] = @(sw.on);
    [self saveGlobalConfig];

    // 把新设置同步到所有已开启的 App
    [self applyGlobalToAllAppsCompletion:^(NSUInteger ok, NSUInteger fail) {
        if (fail > 0) {
            NSLog(@"[AttribClean] 同步完成：成功 %lu，失败 %lu", (unsigned long)ok, (unsigned long)fail);
        }
    }];
}

- (void)appSwitchToggled:(UISwitch *)sw {
    NSString *bid = objc_getAssociatedObject(sw, kSwitchBIDKey);
    if (![bid isKindOfClass:[NSString class]]) return;

    __block ACAppInfo *target = nil;
    for (ACAppInfo *a in self.allApps) {
        if ([a.bundleID isEqualToString:bid]) { target = a; break; }
    }
    if (!target) { sw.on = !sw.on; return; }

    BOOL ok = [self writeConfigForApp:target enabled:sw.on];
    if (!ok) {
        sw.on = !sw.on;
        [self toast:@"写入失败：这台设备上没权限改这个 App 的容器"];
        return;
    }

    self.enabledMap[bid] = @(sw.on);
}

#pragma mark - 批量操作

- (void)bulkAllOn {
    [self bulkSetAll:YES];
}

- (void)bulkAllOff {
    [self bulkSetAll:NO];
}

- (void)bulkSetAll:(BOOL)on {
    NSArray<ACAppInfo *> *apps = [self.shownApps copy];
    if (apps.count == 0) return;

    // 主线程先取一份配置快照，避免后台线程跨队列读
    NSDictionary *global = [self.globalCfg copy];
    NSString *idfa = [[NSUserDefaults standardUserDefaults] stringForKey:kUDKeyIDFA];

    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger ok = 0, fail = 0;

        for (ACAppInfo *a in apps) {
            @autoreleasepool {
                if (!a.dataPath) { fail++; continue; }

                @try {
                    NSString *dir = [a.dataPath stringByAppendingPathComponent:@"Library/Preferences"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:NULL];
                    NSString *path = [dir stringByAppendingPathComponent:kPrefFile];

                    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
                    NSDictionary *exist = [NSDictionary dictionaryWithContentsOfFile:path];
                    if ([exist isKindOfClass:[NSDictionary class]]) [cfg addEntriesFromDictionary:exist];

                    [cfg addEntriesFromDictionary:global];
                    cfg[kACKeyEnabled] = @(on);

                    if (idfa.length == 36) cfg[kACKeyFakeIDFA] = idfa;

                    if ([cfg writeToFile:path atomically:YES]) ok++; else fail++;
                } @catch (__unused NSException *e) {
                    fail++;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;

            for (ACAppInfo *a in apps) {
                if (a.dataPath) s.enabledMap[a.bundleID] = @(on);
            }
            [s.tableView reloadData];

            NSString *msg = [NSString stringWithFormat:@"成功 %lu 个，失败 %lu 个",
                             (unsigned long)ok, (unsigned long)fail];
            [s toast:on ? [@"已全部开启，" stringByAppendingString:msg]
                       : [@"已全部关闭，" stringByAppendingString:msg]];
        });
    });
}

- (void)regenerateIdentity {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"重新生成标识"
                                                              message:@"会给所有已开启的 App 换一个新的广告标识（IDFA）。下次打开这些 App 生效，原来那个就再也对不上了。"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"生成" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSString *fresh = [[NSUUID UUID] UUIDString].uppercaseString;
        [[NSUserDefaults standardUserDefaults] setObject:fresh forKey:kUDKeyIDFA];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [self applyGlobalToAllAppsCompletion:^(NSUInteger ok, NSUInteger fail) {
            [self toast:[NSString stringWithFormat:@"新标识：%@", fresh]];
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 提示

- (void)toast:(NSString *)text {
    if (![text isKindOfClass:[NSString class]]) return;
    if (self.presentedViewController) return;   // 已经有弹窗在显示，别叠

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                              message:text
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { [ac dismissViewControllerAnimated:YES completion:nil]; }
            @catch (__unused NSException *e) {}
        });
    }];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return ACSectionCount;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ACSectionIdentity: return @"清理标识";
        case ACSectionData:     return @"清理数据";
        case ACSectionMode:     return @"执行方式";
        case ACSectionApps:     return [NSString stringWithFormat:@"按 App 控制（已开启 %lu / 共 %lu）",
                                        (unsigned long)[self enabledCount], (unsigned long)self.allApps.count];
        case ACSectionBulk:     return @"批量操作";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == ACSectionApps) {
        return @"选中开关后，被选的 App 每次启动都会自动清一遍归因数据。首次开启要重启一次该 App 才生效。点某一行可以看它上次清理的明细。";
    }
    if (section == ACSectionIdentity) {
        return @"IDFA 是广告标识；IDFV 是应用厂商标识；ATT 是系统的「允许跟踪」授权状态。";
    }
    return nil;
}

- (NSUInteger)enabledCount {
    NSUInteger n = 0;
    for (NSNumber *v in self.enabledMap.allValues) if ([v boolValue]) n++;
    return n;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ACSectionIdentity: return 3;
        case ACSectionData:     return 4;
        case ACSectionMode:     return 1;
        case ACSectionApps:     return MAX((NSInteger)self.shownApps.count, 1);
        case ACSectionBulk:     return 3;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == ACSectionApps) return 60.0;
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.section) {
        case ACSectionIdentity: {
            if (ip.row == 0) return [self switchCell:@"广告标识 IDFA" sub:@"每次启动换成新生成的标识" key:kACKeyCleanIDFA];
            if (ip.row == 1) return [self switchCell:@"应用厂商标识 IDFV" sub:@"按厂商标识分组，换成新的" key:kACKeyCleanIDFV];
            return [self switchCell:@"跟踪授权 ATT" sub:@"直接视为已授权" key:kACKeyCleanATT];
        }
        case ACSectionData: {
            if (ip.row == 0) return [self switchCell:@"缓存与文件" sub:@"SDK 写在缓存、文稿、临时目录里的数据" key:kACKeyCleanFiles];
            if (ip.row == 1) return [self switchCell:@"偏好设置" sub:@"SDK 的配置文件和安装标识" key:kACKeyCleanPrefs];
            if (ip.row == 2) return [self switchCell:@"钥匙串" sub:@"SDK 存在钥匙串里的安装标识" key:kACKeyCleanKeychain];
            return [self switchCell:@"深度清理" sub:@"扩大匹配范围，可能删到 App 自己的缓存" key:kACKeyDeepClean];
        }
        case ACSectionMode: {
            return [self switchCell:@"预演模式" sub:@"只记录会删什么，不实际删除" key:kACKeyDryRun];
        }
        case ACSectionApps: {
            return [self appCellAtIndexPath:ip];
        }
        case ACSectionBulk: {
            NSArray *titles = @[@"全部开启", @"全部关闭", @"重新生成广告标识"];
            NSArray *icons  = @[@"checkmark.circle", @"xmark.circle", @"arrow.triangle.2.circlepath"];
            return [self actionCellWithTitle:titles[ip.row] icon:icons[ip.row]];
        }
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

#pragma mark - Cell 构造

- (UITableViewCell *)switchCell:(NSString *)title sub:(NSString *)sub key:(NSString *)key {
    static NSString *cid = @"accell";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = [[UISwitch alloc] init];
        [sw addTarget:self action:@selector(globalSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;

        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 1;
    }

    cell.textLabel.text = title;
    cell.detailTextLabel.text = sub;

    UISwitch *sw = (UISwitch *)cell.accessoryView;
    sw.on = [self.globalCfg[key] boolValue];
    objc_setAssociatedObject(sw, kSwitchCfgKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);

    return cell;
}

- (UITableViewCell *)appCellAtIndexPath:(NSIndexPath *)ip {
    if (self.shownApps.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = self.searchCtrl.searchBar.text.length
            ? @"没有匹配的 App"
            : @"没读到已安装的 App（检查越狱权限）";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    ACAppInfo *a = self.shownApps[ip.row];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = a.name;
    cell.detailTextLabel.text = a.bundleID;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = a.icon ? [self scaled:a.icon to:CGSizeMake(42, 42)]
                                  : [UIImage systemImageNamed:@"square.stack.3d.up"];
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.clipsToBounds = YES;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [self.enabledMap[a.bundleID] boolValue];
    sw.enabled = (a.dataPath != nil);
    objc_setAssociatedObject(sw, kSwitchBIDKey, a.bundleID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [sw addTarget:self action:@selector(appSwitchToggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    return cell;
}

- (UITableViewCell *)actionCellWithTitle:(NSString *)title icon:(NSString *)icon {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    if (@available(iOS 13.0, *)) {
        cell.imageView.image = [UIImage systemImageNamed:icon];
    }
    return cell;
}

- (UIImage *)scaled:(UIImage *)img to:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
    [img drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

#pragma mark - 选中

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == ACSectionBulk) {
        if (ip.row == 0) [self bulkAllOn];
        else if (ip.row == 1) [self bulkAllOff];
        else [self regenerateIdentity];
        return;
    }

    if (ip.section == ACSectionApps && self.shownApps.count > 0) {
        [self showLogForApp:self.shownApps[ip.row]];
    }
}

- (void)showLogForApp:(ACAppInfo *)a {
    NSString *text = @"这个 App 还没有清理记录。\n\n开启开关后，打开一次该 App 就会生成记录。";

    if (a.dataPath) {
        NSString *p = [a.dataPath stringByAppendingPathComponent:
                       @"Library/Caches/com.zaka.attribclean/state.plist"];
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:p];
        NSArray *lines = st[@"lastCleanLog"];

        if ([lines isKindOfClass:[NSArray class]] && lines.count) {
            NSMutableString *s = [NSMutableString string];
            NSNumber *t = st[@"lastCleanTime"];
            if ([t isKindOfClass:[NSNumber class]]) {
                NSDateFormatter *f = [[NSDateFormatter alloc] init];
                f.dateFormat = @"MM-dd HH:mm:ss";
                [s appendFormat:@"上次清理：%@\n", [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t.doubleValue]]];
            }
            [s appendString:@"————————————\n"];
            for (NSString *l in lines) {
                if ([l isKindOfClass:[NSString class]]) [s appendFormat:@"%@\n", l];
            }
            text = s;
        }
    }

    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = a.name;
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.text = text;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(16, 14, 16, 14);
    [vc.view addSubview:tv];

    [self.navigationController pushViewController:vc animated:YES];
}

@end
