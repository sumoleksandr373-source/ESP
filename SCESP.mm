// SCESP.mm — StandChillow 2.07 (Unity IL2CPP, iOS arm64), ESP for offline bots / dummies
//
// How it works: UnityFramework exports the il2cpp_* API, so everything is resolved by class
// name at runtime (class names are not obfuscated, method/field names are). No offsets, no
// code patching, so it survives re-signing and small game updates.
//   1. find Camera.main and all BotPlayerController / DummyController objects
//   2. take transform.position, project through Camera.WorldToScreenPoint
//   3. draw boxes on a transparent UIKit overlay
//
// Build on your Mac (needs full Xcode, not just CLT):
//   xcrun -sdk iphoneos clang++ -std=c++17 -arch arm64 -miphoneos-version-min=15.0 \
//     -dynamiclib -fobjc-arc -framework UIKit -framework QuartzCore -framework Foundation \
//     -o libSCESP.dylib SCESP.mm
//
// ESign: import the ipa -> Signature/Advanced -> inject libSCESP.dylib -> sign -> install.
//
// Not compiled or run on a device by me. If it fails, check the log lines tagged [SCESP].

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <vector>

// ---- targets (edit here) ---------------------------------------------------------------
static const char *kGameImage = "Chillow.StandChillow.Client.dll";
struct Target { const char *ns; const char *name; };
static const Target kTargets[] = {
    {"Chillow.StandChillow.Bots.Core", "BotPlayerController"},
    {"Chillow.StandChillow.Dummy",     "DummyController"},
};
static const float kHeadHeight = 1.8f;   // metres above transform.position (assumes feet pivot)
static const int   kRefreshFrames = 20;  // re-scan for objects every N frames

// ---- il2cpp API ------------------------------------------------------------------------
typedef void *(*fn_domain_get)(void);
typedef void **(*fn_domain_get_assemblies)(void *, size_t *);
typedef void *(*fn_assembly_get_image)(void *);
typedef const char *(*fn_image_get_name)(void *);
typedef void *(*fn_class_from_name)(void *, const char *, const char *);
typedef void *(*fn_class_get_method)(void *, const char *, int);
typedef void *(*fn_runtime_invoke)(void *, void *, void **, void **);
typedef void *(*fn_object_unbox)(void *);
typedef void *(*fn_class_get_type)(void *);
typedef void *(*fn_type_get_object)(void *);
typedef uint32_t (*fn_gchandle_new)(void *, int);
typedef void *(*fn_gchandle_get)(uint32_t);
typedef void (*fn_gchandle_free)(uint32_t);

static fn_domain_get il2_domain_get;
static fn_domain_get_assemblies il2_get_assemblies;
static fn_assembly_get_image il2_asm_image;
static fn_image_get_name il2_image_name;
static fn_class_from_name il2_class_from_name;
static fn_class_get_method il2_get_method;
static fn_runtime_invoke il2_invoke;
static fn_object_unbox il2_unbox;
static fn_class_get_type il2_class_type;
static fn_type_get_object il2_type_object;
static fn_gchandle_new il2_gc_new;
static fn_gchandle_get il2_gc_get;
static fn_gchandle_free il2_gc_free;

struct V3 { float x, y, z; };

static void *sym(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    if (!p) NSLog(@"[SCESP] missing symbol %s", n);
    return p;
}

static bool loadApi() {
    il2_domain_get      = (fn_domain_get)sym("il2cpp_domain_get");
    il2_get_assemblies  = (fn_domain_get_assemblies)sym("il2cpp_domain_get_assemblies");
    il2_asm_image       = (fn_assembly_get_image)sym("il2cpp_assembly_get_image");
    il2_image_name      = (fn_image_get_name)sym("il2cpp_image_get_name");
    il2_class_from_name = (fn_class_from_name)sym("il2cpp_class_from_name");
    il2_get_method      = (fn_class_get_method)sym("il2cpp_class_get_method_from_name");
    il2_invoke          = (fn_runtime_invoke)sym("il2cpp_runtime_invoke");
    il2_unbox           = (fn_object_unbox)sym("il2cpp_object_unbox");
    il2_class_type      = (fn_class_get_type)sym("il2cpp_class_get_type");
    il2_type_object     = (fn_type_get_object)sym("il2cpp_type_get_object");
    il2_gc_new          = (fn_gchandle_new)sym("il2cpp_gchandle_new");
    il2_gc_get          = (fn_gchandle_get)sym("il2cpp_gchandle_get_target");
    il2_gc_free         = (fn_gchandle_free)sym("il2cpp_gchandle_free");
    return il2_domain_get && il2_get_assemblies && il2_asm_image && il2_image_name &&
           il2_class_from_name && il2_get_method && il2_invoke && il2_unbox &&
           il2_class_type && il2_type_object && il2_gc_new && il2_gc_get && il2_gc_free;
}

static void *findImage(const char *name) {
    size_t n = 0;
    void **asms = il2_get_assemblies(il2_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il2_asm_image(asms[i]);
        if (img && strcmp(il2_image_name(img), name) == 0) return img;
    }
    return nullptr;
}

// ---- resolved handles ------------------------------------------------------------------
static void *m_findObjects, *m_cam_main, *m_w2s, *m_get_transform, *m_get_position;
static void *m_screen_w, *m_screen_h;
static void *k_targets[2];
static bool g_findTakesBool = false;
static bool g_ready = false;
static bool g_espOn = true;
static bool g_apiOk = false;

static bool resolveAll() {
    void *core = findImage("UnityEngine.CoreModule.dll");
    void *game = findImage(kGameImage);
    if (!core || !game) return false;

    void *cObject = il2_class_from_name(core, "UnityEngine", "Object");
    void *cCamera = il2_class_from_name(core, "UnityEngine", "Camera");
    void *cComp   = il2_class_from_name(core, "UnityEngine", "Component");
    void *cTrans  = il2_class_from_name(core, "UnityEngine", "Transform");
    void *cScreen = il2_class_from_name(core, "UnityEngine", "Screen");
    if (!cObject || !cCamera || !cComp || !cTrans || !cScreen) return false;

    m_findObjects = il2_get_method(cObject, "FindObjectsOfType", 1);
    if (!m_findObjects) { m_findObjects = il2_get_method(cObject, "FindObjectsOfType", 2); g_findTakesBool = m_findObjects != nullptr; }
    m_cam_main      = il2_get_method(cCamera, "get_main", 0);
    m_w2s           = il2_get_method(cCamera, "WorldToScreenPoint", 1);
    m_get_transform = il2_get_method(cComp, "get_transform", 0);
    m_get_position  = il2_get_method(cTrans, "get_position", 0);
    m_screen_w      = il2_get_method(cScreen, "get_width", 0);
    m_screen_h      = il2_get_method(cScreen, "get_height", 0);

    for (int i = 0; i < 2; i++) k_targets[i] = il2_class_from_name(game, kTargets[i].ns, kTargets[i].name);
    NSLog(@"[SCESP] resolve: find=%p cam=%p w2s=%p tr=%p pos=%p t0=%p t1=%p",
          m_findObjects, m_cam_main, m_w2s, m_get_transform, m_get_position, k_targets[0], k_targets[1]);
    return m_findObjects && m_cam_main && m_w2s && m_get_transform && m_get_position &&
           m_screen_w && m_screen_h && (k_targets[0] || k_targets[1]);
}

// ---- helpers ---------------------------------------------------------------------------
static bool getVec3(void *method, void *obj, void **args, V3 *out) {
    void *exc = nullptr;
    void *boxed = il2_invoke(method, obj, args, &exc);
    if (exc || !boxed) return false;
    *out = *(V3 *)il2_unbox(boxed);
    return true;
}
static int getInt(void *method) {
    void *exc = nullptr;
    void *boxed = il2_invoke(method, nullptr, nullptr, &exc);
    if (exc || !boxed) return 0;
    return *(int *)il2_unbox(boxed);
}

static std::vector<uint32_t> g_handles;

static void refreshObjects() {
    for (uint32_t h : g_handles) il2_gc_free(h);
    g_handles.clear();
    for (int t = 0; t < 2; t++) {
        if (!k_targets[t]) continue;
        void *typeObj = il2_type_object(il2_class_type(k_targets[t]));
        void *exc = nullptr;
        void *arr = nullptr;
        if (g_findTakesBool) {
            bool inactive = false;
            void *args[2] = { typeObj, &inactive };
            arr = il2_invoke(m_findObjects, nullptr, args, &exc);
        } else {
            void *args[1] = { typeObj };
            arr = il2_invoke(m_findObjects, nullptr, args, &exc);
        }
        if (exc || !arr) continue;
        uintptr_t len = *(uintptr_t *)((char *)arr + 24);   // Il2CppArray.max_length
        void **elems = (void **)((char *)arr + 32);         // first element
        if (len > 256) len = 256;
        for (uintptr_t i = 0; i < len; i++)
            if (elems[i]) g_handles.push_back(il2_gc_new(elems[i], 0));
    }
}

// ---- overlay ---------------------------------------------------------------------------
@interface SCESPDriver : NSObject
- (void)tick:(CADisplayLink *)link;
- (void)toggle;
@end

@implementation SCESPDriver {
    UIView *_overlay;
    CAShapeLayer *_boxes;
    UIButton *_btn;
    NSString *_stage;
    int _frame;
}

- (UIWindow *)keyWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)tick:(CADisplayLink *)link {
    {
        UIWindow *win = [self keyWindow];
        if (win) {
    if (!_btn) {
        _btn = [UIButton buttonWithType:UIButtonTypeCustom];
        _btn.frame = CGRectMake(8, 44, 190, 26);
        _btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _btn.layer.cornerRadius = 6;
        _btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
        [_btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [_btn addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    }
    if (_btn.superview != win) { [_btn removeFromSuperview]; [win addSubview:_btn]; }
    [win bringSubviewToFront:_btn];
        }
    }
    if (!g_ready) {
        if (_frame++ % 60) return;                 // retry about once per second
        _stage = @"waiting for il2cpp";
        if (!g_apiOk) g_apiOk = loadApi();
        if (!g_apiOk) { _stage = @"il2cpp API missing"; [self updateButton:0 cam:NO]; return; }
        _stage = @"resolving classes";
        if (!resolveAll()) { [self updateButton:0 cam:NO]; return; }
        g_ready = true;
        NSLog(@"[SCESP] ready");
        _frame = 0;
    }
    UIWindow *win = [self keyWindow];
    if (!win) return;
    if (!_overlay) {
        _overlay = [[UIView alloc] initWithFrame:win.bounds];
        _overlay.userInteractionEnabled = NO;
        _overlay.backgroundColor = UIColor.clearColor;
        _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _boxes = [CAShapeLayer layer];
        _boxes.strokeColor = UIColor.redColor.CGColor;
        _boxes.fillColor = UIColor.clearColor.CGColor;
        _boxes.lineWidth = 1.5;
        [_overlay.layer addSublayer:_boxes];
    }
    if (_overlay.superview != win) { [_overlay removeFromSuperview]; [win addSubview:_overlay]; }
    [win bringSubviewToFront:_overlay];

    if (_frame++ % kRefreshFrames == 0) refreshObjects();

    UIBezierPath *path = [UIBezierPath bezierPath];
    void *exc = nullptr;
    void *cam = il2_invoke(m_cam_main, nullptr, nullptr, &exc);
    int sw = getInt(m_screen_w), sh = getInt(m_screen_h);
    bool camOk = cam && !exc;
    if (g_espOn && camOk && sw > 0 && sh > 0) {
        CGSize vs = _overlay.bounds.size;
        for (uint32_t h : g_handles) {
            void *obj = il2_gc_get(h);
            if (!obj) continue;
            void *e1 = nullptr;
            void *tr = il2_invoke(m_get_transform, obj, nullptr, &e1);
            if (e1 || !tr) continue;
            V3 pos;
            if (!getVec3(m_get_position, tr, nullptr, &pos)) continue;
            V3 head = { pos.x, pos.y + kHeadHeight, pos.z }, foot = pos, sh_, sf;
            void *a1[1] = { &head }, *a2[1] = { &foot };
            if (!getVec3(m_w2s, cam, a1, &sh_) || !getVec3(m_w2s, cam, a2, &sf)) continue;
            if (sh_.z <= 0 || sf.z <= 0) continue;                 // behind the camera
            // Unity screen space: origin bottom-left, pixels -> UIKit points
            CGFloat hx = sh_.x / sw * vs.width,  hy = (1.0 - sh_.y / sh) * vs.height;
            CGFloat fx = sf.x  / sw * vs.width,  fy = (1.0 - sf.y  / sh) * vs.height;
            CGFloat bh = fy - hy; if (bh < 4) continue;
            CGFloat bw = bh * 0.5, cx = (hx + fx) * 0.5;
            [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(cx - bw / 2, hy, bw, bh)]];
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _boxes.frame = _overlay.bounds;
    _boxes.path = path.CGPath;
    [CATransaction commit];
    _stage = @"ready";
    [self updateButton:g_handles.size() cam:camOk];
}

- (void)toggle { g_espOn = !g_espOn; }

- (void)updateButton:(size_t)n cam:(BOOL)cam {
    if (!_btn) return;
    NSString *t = [NSString stringWithFormat:@"ESP %@ | %@ | obj %zu | cam %@",
                   g_espOn ? @"ON" : @"OFF", _stage ?: @"-", n, cam ? @"ok" : @"-"];
    [_btn setTitle:t forState:UIControlStateNormal];
}
@end

static SCESPDriver *g_driver;

__attribute__((constructor)) static void scesp_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_driver = [SCESPDriver new];
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector(tick:)];
        [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        NSLog(@"[SCESP] loaded");
    });
}
