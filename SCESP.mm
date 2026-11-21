// SCESP.mm v3 — StandChillow (Unity IL2CPP, iOS arm64), ESP for offline bot matches
//
// - everything is resolved by class/method name at runtime through the exported il2cpp API
// - enemies only: team is read from the PlayerController fields typed Core.Team,
//   "me" is the character standing at the camera
// - hot path uses direct method-pointer calls (no il2cpp_runtime_invoke, no boxing garbage)
// - draws at 30 fps, object scan about once a second
//
// Build (GitHub Actions workflow already set up): upload this file as SCESP.mm.
// Tap the status plate (top-left) to toggle the ESP on/off.
// Not compiled or run on a device by me — if it misbehaves, the plate text tells where.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <vector>

// ---- config ----------------------------------------------------------------------------
static const char *kGameImage = "Chillow.StandChillow.Client.dll";
struct Target { const char *ns; const char *name; };
static const Target kTargets[] = {
    {"Chillow.StandChillow.Player", "PlayerController"},
    {"Chillow.StandChillow.Player", "CharacterPlayer"},
    {"Chillow.StandChillow.Bots.Core", "BotPlayerController"},
};
static const int   kN = sizeof(kTargets) / sizeof(kTargets[0]);
static const char *kTeamType = "Chillow.StandChillow.Core.Team";   // None=0 Tr=1 Ct=2 Spectator=3
static const float kHeadHeight = 1.8f;    // metres above transform.position (feet pivot assumed)
static const float kSelfRadius = 0.7f;    // character this close to the camera is "me"
static const int   kRefreshTicks = 30;    // object rescan interval, in 30 fps ticks

// ---- il2cpp API ------------------------------------------------------------------------
typedef void *(*fn_domain_get)(void);
typedef void **(*fn_domain_get_assemblies)(void *, size_t *);
typedef void *(*fn_assembly_get_image)(void *);
typedef const char *(*fn_image_get_name)(void *);
typedef void *(*fn_class_from_name)(void *, const char *, const char *);
typedef void *(*fn_class_get_method)(void *, const char *, int);
typedef void *(*fn_runtime_invoke)(void *, void *, void **, void **);
typedef void *(*fn_class_get_type)(void *);
typedef void *(*fn_type_get_object)(void *);
typedef uint32_t (*fn_gchandle_new)(void *, int);
typedef void *(*fn_gchandle_get)(uint32_t);
typedef void (*fn_gchandle_free)(uint32_t);
typedef void *(*fn_class_get_fields)(void *, void **);
typedef void *(*fn_class_get_parent)(void *);
typedef void *(*fn_field_get_type)(void *);
typedef int (*fn_field_get_offset)(void *);
typedef int (*fn_field_get_flags)(void *);
typedef char *(*fn_type_get_name)(void *);

static fn_domain_get il2_domain_get;
static fn_domain_get_assemblies il2_get_assemblies;
static fn_assembly_get_image il2_asm_image;
static fn_image_get_name il2_image_name;
static fn_class_from_name il2_class_from_name;
static fn_class_get_method il2_get_method;
static fn_runtime_invoke il2_invoke;
static fn_class_get_type il2_class_type;
static fn_type_get_object il2_type_object;
static fn_gchandle_new il2_gc_new;
static fn_gchandle_get il2_gc_get;
static fn_gchandle_free il2_gc_free;
static fn_class_get_fields il2_class_fields;
static fn_class_get_parent il2_class_parent;
static fn_field_get_type il2_field_type;
static fn_field_get_offset il2_field_offset;
static fn_field_get_flags il2_field_flags;
static fn_type_get_name il2_type_name;

struct V3 { float x, y, z; };

// direct-call signatures (IL2CPP instance methods take (self, MethodInfo*))
typedef void *(*d_get_main)(void *mi);
typedef void *(*d_get_transform)(void *self, void *mi);
typedef V3 (*d_get_position)(void *self, void *mi);
typedef V3 (*d_w2s)(void *self, V3 p, void *mi);
typedef int (*d_screen)(void *mi);

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
    il2_class_type      = (fn_class_get_type)sym("il2cpp_class_get_type");
    il2_type_object     = (fn_type_get_object)sym("il2cpp_type_get_object");
    il2_gc_new          = (fn_gchandle_new)sym("il2cpp_gchandle_new");
    il2_gc_get          = (fn_gchandle_get)sym("il2cpp_gchandle_get_target");
    il2_gc_free         = (fn_gchandle_free)sym("il2cpp_gchandle_free");
    il2_class_fields    = (fn_class_get_fields)sym("il2cpp_class_get_fields");
    il2_class_parent    = (fn_class_get_parent)sym("il2cpp_class_get_parent");
    il2_field_type      = (fn_field_get_type)sym("il2cpp_field_get_type");
    il2_field_offset    = (fn_field_get_offset)sym("il2cpp_field_get_offset");
    il2_field_flags     = (fn_field_get_flags)sym("il2cpp_field_get_flags");
    il2_type_name       = (fn_type_get_name)sym("il2cpp_type_get_name");
    return il2_domain_get && il2_get_assemblies && il2_asm_image && il2_image_name &&
           il2_class_from_name && il2_get_method && il2_invoke && il2_class_type &&
           il2_type_object && il2_gc_new && il2_gc_get && il2_gc_free && il2_class_fields &&
           il2_class_parent && il2_field_type && il2_field_offset && il2_field_flags && il2_type_name;
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

// ---- resolved state --------------------------------------------------------------------
static void *m_findObjects;                 // MethodInfo, only used once per scan
static void *k_targets[8];
static size_t g_counts[8];
static int g_active = -1;                   // index of the target class that has live objects
static std::vector<int> g_teamOffsets;      // instance-field offsets of Core.Team fields
static int g_teamField = -1;                // which of them is the real team (auto-picked)

static d_get_main d_cam_main;  static void *mi_cam_main;
static d_get_transform d_tr;   static void *mi_tr;
static d_get_position d_pos;   static void *mi_pos;
static d_w2s d_world2screen;   static void *mi_w2s;
static d_screen d_sw, d_sh;    static void *mi_sw, *mi_sh;

static bool g_ready = false;
static bool g_espOn = true;
static bool g_apiOk = false;

static void *direct(void *methodInfo) { return methodInfo ? *(void **)methodInfo : nullptr; }

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

    // FindObjectsOfType(Type) is stripped in this build; (Type, bool) is present.
    m_findObjects = il2_get_method(cObject, "FindObjectsOfType", 2);
    mi_cam_main = il2_get_method(cCamera, "get_main", 0);
    mi_w2s      = il2_get_method(cCamera, "WorldToScreenPoint", 1);
    mi_tr       = il2_get_method(cComp, "get_transform", 0);
    mi_pos      = il2_get_method(cTrans, "get_position", 0);
    mi_sw       = il2_get_method(cScreen, "get_width", 0);
    mi_sh       = il2_get_method(cScreen, "get_height", 0);
    d_cam_main = (d_get_main)direct(mi_cam_main);
    d_world2screen = (d_w2s)direct(mi_w2s);
    d_tr  = (d_get_transform)direct(mi_tr);
    d_pos = (d_get_position)direct(mi_pos);
    d_sw  = (d_screen)direct(mi_sw);
    d_sh  = (d_screen)direct(mi_sh);

    for (int i = 0; i < kN; i++) k_targets[i] = il2_class_from_name(game, kTargets[i].ns, kTargets[i].name);
    NSLog(@"[SCESP] resolve: find=%p cam=%p w2s=%p tr=%p pos=%p", m_findObjects, d_cam_main, d_world2screen, d_tr, d_pos);
    for (int i = 0; i < kN; i++) NSLog(@"[SCESP] target %s = %p", kTargets[i].name, k_targets[i]);
    bool any = false; for (int i = 0; i < kN; i++) if (k_targets[i]) any = true;
    return m_findObjects && d_cam_main && d_world2screen && d_tr && d_pos && d_sw && d_sh && any;
}

// find fields typed Core.Team on a class (and its parents)
static void findTeamFields(void *klass) {
    g_teamOffsets.clear();
    g_teamField = -1;
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;                // static
            const char *tn = il2_type_name(il2_field_type(f));
            if (tn && strcmp(tn, kTeamType) == 0) g_teamOffsets.push_back(il2_field_offset(f));
        }
    }
    NSLog(@"[SCESP] team fields: %zu", g_teamOffsets.size());
}

// ---- object list -----------------------------------------------------------------------
static std::vector<uint32_t> g_handles;

static size_t scanClass(int t, std::vector<uint32_t> &out) {
    void *typeObj = il2_type_object(il2_class_type(k_targets[t]));
    bool inactive = false;
    void *args[2] = { typeObj, &inactive };
    void *exc = nullptr;
    void *arr = il2_invoke(m_findObjects, nullptr, args, &exc);
    if (exc || !arr) return 0;
    uintptr_t len = *(uintptr_t *)((char *)arr + 24);   // Il2CppArray.max_length
    void **elems = (void **)((char *)arr + 32);
    if (len > 128) len = 128;
    size_t n = 0;
    for (uintptr_t i = 0; i < len; i++)
        if (elems[i]) { out.push_back(il2_gc_new(elems[i], 0)); n++; }
    return n;
}

static void refreshObjects() {
    std::vector<uint32_t> fresh;
    for (int t = 0; t < kN; t++) g_counts[t] = 0;
    if (g_active >= 0 && k_targets[g_active]) {
        g_counts[g_active] = scanClass(g_active, fresh);
    }
    if (fresh.empty()) {                       // nothing from the active class: re-detect
        for (int t = 0; t < kN; t++) {
            if (!k_targets[t]) continue;
            g_counts[t] = scanClass(t, fresh);
            if (g_counts[t] > 0) {
                if (g_active != t) { g_active = t; findTeamFields(k_targets[t]); }
                break;
            }
        }
    }
    for (uint32_t h : g_handles) il2_gc_free(h);
    g_handles = fresh;
}

static inline bool alive(void *obj) {                        // UnityEngine.Object.m_CachedPtr != 0
    return *(void **)((char *)obj + 16) != nullptr;
}
static inline int readTeam(void *obj, int field) {
    if (field < 0 || field >= (int)g_teamOffsets.size()) return 0;
    return *(int *)((char *)obj + g_teamOffsets[field]);
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
    int _tick;
}

- (UIWindow *)keyWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)toggle { g_espOn = !g_espOn; }

- (void)setStatus:(NSString *)s {
    if (_btn) [_btn setTitle:s forState:UIControlStateNormal];
}

- (void)tick:(CADisplayLink *)link {
    UIWindow *win = [self keyWindow];
    if (!win) return;
    if (!_btn) {
        _btn = [UIButton buttonWithType:UIButtonTypeCustom];
        _btn.frame = CGRectMake(8, 44, 250, 24);
        _btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _btn.layer.cornerRadius = 6;
        _btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
        _btn.titleLabel.lineBreakMode = NSLineBreakByClipping;
        [_btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [_btn addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    }
    if (_btn.superview != win) { [_btn removeFromSuperview]; [win addSubview:_btn]; }
    [win bringSubviewToFront:_btn];

    if (!g_ready) {
        if (_frame++ % 30) return;                                  // retry about once per second
        if (!g_apiOk) g_apiOk = loadApi();
        if (!g_apiOk) { [self setStatus:@"ESP | il2cpp API missing"]; return; }
        if (!resolveAll()) { [self setStatus:@"ESP | waiting for game classes"]; return; }
        g_ready = true;
        _tick = 0;
    }
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
    if (_overlay.superview != win) { [_overlay removeFromSuperview]; [win insertSubview:_overlay belowSubview:_btn]; }

    UIBezierPath *path = [UIBezierPath bezierPath];
    int drawn = 0, myTeam = -1;
    bool camOk = false;

    if (g_espOn) {
        if (_tick++ % kRefreshTicks == 0) refreshObjects();
        @try {
            void *cam = d_cam_main(mi_cam_main);
            int sw = d_sw(mi_sw), sh = d_sh(mi_sh);
            if (cam && alive(cam) && sw > 0 && sh > 0) {
                camOk = true;
                void *ctr = d_tr(cam, mi_tr);
                V3 camPos = d_pos(ctr, mi_pos);
                CGSize vs = _overlay.bounds.size;

                // pass 1: positions, find "me", detect the team field
                struct P { void *obj; V3 pos; bool self; };
                std::vector<P> ps;
                for (uint32_t h : g_handles) {
                    void *obj = il2_gc_get(h);
                    if (!obj || !alive(obj)) continue;
                    void *tr = d_tr(obj, mi_tr);
                    if (!tr) continue;
                    V3 pos = d_pos(tr, mi_pos);
                    float dx = pos.x - camPos.x, dz = pos.z - camPos.z;
                    bool self = dx * dx + dz * dz < kSelfRadius * kSelfRadius;
                    ps.push_back({obj, pos, self});
                }
                if (g_teamField < 0 && !g_teamOffsets.empty()) {
                    for (int f = 0; f < (int)g_teamOffsets.size(); f++) {
                        bool has1 = false, has2 = false;
                        for (auto &p : ps) { int v = readTeam(p.obj, f); if (v == 1) has1 = true; if (v == 2) has2 = true; }
                        if (has1 && has2) { g_teamField = f; break; }
                    }
                }
                for (auto &p : ps) if (p.self && g_teamField >= 0) myTeam = readTeam(p.obj, g_teamField);

                // pass 2: project and draw enemies
                for (auto &p : ps) {
                    if (p.self) continue;
                    if (g_teamField >= 0) {
                        int tv = readTeam(p.obj, g_teamField);
                        if (tv != 1 && tv != 2) continue;                 // spectator / none
                        if ((myTeam == 1 || myTeam == 2) && tv == myTeam) continue;   // teammate
                    }
                    V3 head = { p.pos.x, p.pos.y + kHeadHeight, p.pos.z };
                    V3 a = d_world2screen(cam, head, mi_w2s);
                    V3 b = d_world2screen(cam, p.pos, mi_w2s);
                    if (a.z <= 0 || b.z <= 0) continue;                    // behind camera
                    CGFloat hx = a.x / sw * vs.width,  hy = (1.0 - a.y / sh) * vs.height;
                    CGFloat fx = b.x / sw * vs.width,  fy = (1.0 - b.y / sh) * vs.height;
                    CGFloat bh = fy - hy; if (bh < 4) continue;
                    CGFloat bw = bh * 0.5, cx = (hx + fx) * 0.5;
                    [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(cx - bw / 2, hy, bw, bh)]];
                    drawn++;
                }
            }
        } @catch (...) {}
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _boxes.frame = _overlay.bounds;
    _boxes.path = path.CGPath;
    [CATransaction commit];

    NSMutableString *cs = [NSMutableString string];
    for (int i = 0; i < kN; i++) [cs appendFormat:@"%s%zu", i ? "/" : "", g_counts[i]];
    [self setStatus:[NSString stringWithFormat:@"ESP %@ | %@ | team f%d me%d | draw %d | cam %@",
                     g_espOn ? @"ON" : @"OFF", cs, g_teamField, myTeam, drawn, camOk ? @"ok" : @"-"]];
}
@end

static SCESPDriver *g_driver;

__attribute__((constructor)) static void scesp_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_driver = [SCESPDriver new];
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector(tick:)];
        dl.preferredFramesPerSecond = 30;
        [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        NSLog(@"[SCESP] loaded");
    });
}
