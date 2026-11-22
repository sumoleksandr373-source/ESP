// SCESP.mm v5.3 — StandChillow (Unity IL2CPP, iOS arm64), ESP for offline bot matches
//
// Box / skeleton / chams / box fill, enemies only (teammates optional), settings panel.
// Tap the small "ESP" plate (top-left) to open/close the settings panel.
//
// - everything is resolved by class/method name at runtime through the exported il2cpp API
// - team comes from the PlayerController fields typed Core.Team; "me" is the character at the camera
// - skeleton = real bones of each character's biggest SkinnedMeshRenderer, parent->child lines
// - chams = swaps the enemy's materials for an unlit colour material that ignores depth
//   (needs a built-in shader that exists in the build; the panel shows which one it found)
// - hot path uses direct method-pointer calls; drawing is 30 fps, scan about once a second
//
// Not compiled or run on a device by me. If something misbehaves, the panel's status line says where.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include <unordered_map>
#include <ctype.h>
#include <string>

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
static const float kSelfRadius = 0.7f;
static const int   kRefreshTicks = 30;
static const char *kChamShaders[] = { "Hidden/Internal-Colored", "GUI/Text Shader", "UI/Default", "Sprites/Default" };
// bones whose lowercase name contains any of these are never drawn and never count for the box
static const char *kBoneSkip[] = { "root", "ik", "target", "pole", "weapon", "gun" };
// bones further than this from the player pivot are junk (IK helpers, world-origin bones)
static const float kBelowFeet = 0.3f, kMaxReach = 2.0f;
static const float kAimFov = 18.0f;   // degrees: aim lock only grabs targets this close to the crosshair

// ---- settings --------------------------------------------------------------------------
struct Settings {
    bool on = true, box = true, skel = true, chams = false, fill = false, team = false, lowcpu = false, noocc = true, aim = false;
    int color = 0;
    float lw = 1.5f;
    float head = 1.8f;
};
static Settings g_set;
static bool g_dirty = true;

static UIColor *colorFor(int i, CGFloat a) {
    switch (i) {
        case 0: return [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:a];
        case 1: return [UIColor colorWithRed:0.1 green:1 blue:0.2 alpha:a];
        case 2: return [UIColor colorWithRed:0.1 green:0.9 blue:1 alpha:a];
        case 3: return [UIColor colorWithRed:1 green:0.9 blue:0.1 alpha:a];
        case 4: return [UIColor colorWithRed:1 green:1 blue:1 alpha:a];
        case 5: return [UIColor colorWithRed:1 green:0.2 blue:1 alpha:a];
        default: return [UIColor colorWithRed:1 green:0.55 blue:0.1 alpha:a];
    }
}
static void saveSettings() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:g_set.on forKey:@"scesp_on"];       [d setBool:g_set.box forKey:@"scesp_box"];
    [d setBool:g_set.skel forKey:@"scesp_skel"];   [d setBool:g_set.chams forKey:@"scesp_chams"];
    [d setBool:g_set.fill forKey:@"scesp_fill"];   [d setBool:g_set.team forKey:@"scesp_team"];
    [d setBool:g_set.lowcpu forKey:@"scesp_low"];
    [d setBool:g_set.noocc forKey:@"scesp_noocc"];
    [d setInteger:g_set.color forKey:@"scesp_color"];
    [d setFloat:g_set.lw forKey:@"scesp_lw"];      [d setFloat:g_set.head forKey:@"scesp_head"];
}
static void loadSettings() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![d objectForKey:@"scesp_on"]) return;
    g_set.on = [d boolForKey:@"scesp_on"];         g_set.box = [d boolForKey:@"scesp_box"];
    g_set.skel = [d boolForKey:@"scesp_skel"];     g_set.chams = [d boolForKey:@"scesp_chams"];
    g_set.fill = [d boolForKey:@"scesp_fill"];     g_set.team = [d boolForKey:@"scesp_team"];
    g_set.lowcpu = [d boolForKey:@"scesp_low"];
    g_set.noocc = [d objectForKey:@"scesp_noocc"] ? [d boolForKey:@"scesp_noocc"] : true;
    g_set.color = (int)[d integerForKey:@"scesp_color"];
    g_set.lw = [d floatForKey:@"scesp_lw"];        g_set.head = [d floatForKey:@"scesp_head"];
    if (g_set.lw < 0.5f) g_set.lw = 1.5f;
    if (g_set.head < 1.0f) g_set.head = 1.8f;
}

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
typedef void *(*fn_class_get_methods)(void *, void **);
typedef void *(*fn_class_get_parent)(void *);
typedef void *(*fn_field_get_type)(void *);
typedef int (*fn_field_get_offset)(void *);
typedef int (*fn_field_get_flags)(void *);
typedef char *(*fn_type_get_name)(void *);
typedef const char *(*fn_method_get_name)(void *);
typedef uint32_t (*fn_method_param_count)(void *);
typedef void *(*fn_method_get_param)(void *, uint32_t);
typedef void *(*fn_string_new)(const char *);
typedef void *(*fn_object_new)(void *);
typedef void *(*fn_array_new)(void *, uintptr_t);
typedef const uint16_t *(*fn_string_chars)(void *);
typedef int (*fn_string_length)(void *);
typedef void *(*fn_class_from_type)(void *);
typedef bool (*fn_class_is_vt)(void *);

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
static fn_class_get_methods il2_class_methods;
static fn_class_get_parent il2_class_parent;
static fn_field_get_type il2_field_type;
static fn_field_get_offset il2_field_offset;
static fn_field_get_flags il2_field_flags;
static fn_type_get_name il2_type_name;
static fn_method_get_name il2_method_name;
static fn_method_param_count il2_method_pcount;
static fn_method_get_param il2_method_param;
static fn_string_new il2_string_new;
static fn_object_new il2_object_new;
static fn_array_new il2_array_new;
static fn_string_chars il2_str_chars;
static fn_string_length il2_str_len;
static fn_class_from_type il2_class_from_type;
static fn_class_is_vt il2_class_is_vt;

struct V3 { float x, y, z; };
struct Col { float r, g, b, a; };

typedef void *(*d_get_main)(void *mi);
typedef void *(*d_obj_get)(void *self, void *mi);
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
    il2_class_methods   = (fn_class_get_methods)sym("il2cpp_class_get_methods");
    il2_class_parent    = (fn_class_get_parent)sym("il2cpp_class_get_parent");
    il2_field_type      = (fn_field_get_type)sym("il2cpp_field_get_type");
    il2_field_offset    = (fn_field_get_offset)sym("il2cpp_field_get_offset");
    il2_field_flags     = (fn_field_get_flags)sym("il2cpp_field_get_flags");
    il2_type_name       = (fn_type_get_name)sym("il2cpp_type_get_name");
    il2_method_name     = (fn_method_get_name)sym("il2cpp_method_get_name");
    il2_method_pcount   = (fn_method_param_count)sym("il2cpp_method_get_param_count");
    il2_method_param    = (fn_method_get_param)sym("il2cpp_method_get_param");
    il2_string_new      = (fn_string_new)sym("il2cpp_string_new");
    il2_object_new      = (fn_object_new)sym("il2cpp_object_new");
    il2_array_new       = (fn_array_new)sym("il2cpp_array_new");
    il2_str_chars       = (fn_string_chars)sym("il2cpp_string_chars");     // optional (bone names)
    il2_str_len         = (fn_string_length)sym("il2cpp_string_length");   // optional
    il2_class_from_type = (fn_class_from_type)sym("il2cpp_class_from_type");   // optional (aim learning)
    il2_class_is_vt     = (fn_class_is_vt)sym("il2cpp_class_is_valuetype");    // optional
    return il2_domain_get && il2_get_assemblies && il2_asm_image && il2_image_name &&
           il2_class_from_name && il2_get_method && il2_invoke && il2_class_type &&
           il2_type_object && il2_gc_new && il2_gc_get && il2_gc_free && il2_class_fields &&
           il2_class_methods && il2_class_parent && il2_field_type && il2_field_offset &&
           il2_field_flags && il2_type_name && il2_method_name && il2_method_pcount &&
           il2_method_param && il2_string_new && il2_object_new && il2_array_new;
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

// method lookup that tells overloads apart by their first parameter's type name
static void *findMethod(void *klass, const char *name, uint32_t argc, const char *p0) {
    void *iter = nullptr, *m;
    while ((m = il2_class_methods(klass, &iter))) {
        if (strcmp(il2_method_name(m), name) != 0 || il2_method_pcount(m) != argc) continue;
        if (!p0) return m;
        const char *tn = il2_type_name(il2_method_param(m, 0));
        if (tn && strcmp(tn, p0) == 0) return m;
    }
    return nullptr;
}

static void *inv(void *mi, void *obj, void **args) {
    if (!mi) return nullptr;
    void *exc = nullptr;
    void *r = il2_invoke(mi, obj, args, &exc);
    return exc ? nullptr : r;
}

// ---- resolved state --------------------------------------------------------------------
static void *k_targets[8];
static size_t g_counts[8];
static int g_active = -1;
static std::vector<int> g_teamOffsets;
static int g_teamField = -1;

static void *k_smr, *k_material, *k_shader;
static void *mi_find, *mi_get_bones, *mi_get_smats, *mi_set_smats, *mi_find_shader, *mi_mat_ctor;
static void *mi_set_color, *mi_set_queue, *mi_setint, *mi_setglobal, *mi_get_name, *mi_hasprop;
static void *k_animator, *k_occsys;
static void *mi_anim_cull, *mi_beh_enabled, *mi_smr_offscreen, *mi_rend_enabled, *mi_cam_occ;
static void *mi_rend_get_enabled, *mi_rend_isvis, *mi_rend_get_froff, *mi_rend_set_froff, *mi_cam_get_occ;
static void *mi_get_go, *mi_go_active, *mi_go_layer;

static d_get_main d_cam_main;  static void *mi_cam_main;
static d_obj_get d_tr;         static void *mi_tr;
static d_obj_get d_parent;     static void *mi_parent;
static d_get_position d_pos;   static void *mi_pos;
static d_w2s d_world2screen;   static void *mi_w2s;
static d_screen d_sw, d_sh;    static void *mi_sw, *mi_sh;
static d_get_position d_fwd;   static void *mi_fwd;
static void *k_aim;

static bool g_ready = false;
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
    void *cRend   = il2_class_from_name(core, "UnityEngine", "Renderer");
    k_smr         = il2_class_from_name(core, "UnityEngine", "SkinnedMeshRenderer");
    k_material    = il2_class_from_name(core, "UnityEngine", "Material");
    k_shader      = il2_class_from_name(core, "UnityEngine", "Shader");
    if (!cObject || !cCamera || !cComp || !cTrans || !cScreen) return false;

    mi_get_name = il2_get_method(cObject, "get_name", 0);
    // FindObjectsOfType(Type) is stripped in this build; (Type, bool) is present.
    mi_find     = il2_get_method(cObject, "FindObjectsOfType", 2);
    mi_cam_main = il2_get_method(cCamera, "get_main", 0);
    mi_w2s      = il2_get_method(cCamera, "WorldToScreenPoint", 1);
    mi_tr       = il2_get_method(cComp, "get_transform", 0);
    mi_pos      = il2_get_method(cTrans, "get_position", 0);
    mi_parent   = il2_get_method(cTrans, "get_parent", 0);
    mi_fwd      = il2_get_method(cTrans, "get_forward", 0);
    mi_sw       = il2_get_method(cScreen, "get_width", 0);
    mi_sh       = il2_get_method(cScreen, "get_height", 0);
    d_cam_main = (d_get_main)direct(mi_cam_main);
    d_world2screen = (d_w2s)direct(mi_w2s);
    d_tr  = (d_obj_get)direct(mi_tr);
    d_parent = (d_obj_get)direct(mi_parent);
    d_fwd = (d_get_position)direct(mi_fwd);
    d_pos = (d_get_position)direct(mi_pos);
    d_sw  = (d_screen)direct(mi_sw);
    d_sh  = (d_screen)direct(mi_sh);

    // skeleton / chams helpers (all optional: missing ones just disable that feature)
    if (k_smr)  mi_get_bones = il2_get_method(k_smr, "get_bones", 0);
    {   // occlusion / animation-culling overrides (optional)
        void *cBeh = il2_class_from_name(core, "UnityEngine", "Behaviour");
        if (cBeh) mi_beh_enabled = il2_get_method(cBeh, "set_enabled", 1);
        if (cRend) mi_rend_enabled = il2_get_method(cRend, "set_enabled", 1);
        if (cRend) {
            mi_rend_get_enabled = il2_get_method(cRend, "get_enabled", 0);
            mi_rend_isvis       = il2_get_method(cRend, "get_isVisible", 0);
            mi_rend_get_froff   = il2_get_method(cRend, "get_forceRenderingOff", 0);
            mi_rend_set_froff   = il2_get_method(cRend, "set_forceRenderingOff", 1);
        }
        mi_cam_get_occ = il2_get_method(cCamera, "get_useOcclusionCulling", 0);
        mi_get_go = il2_get_method(cComp, "get_gameObject", 0);
        { void *cGO = il2_class_from_name(core, "UnityEngine", "GameObject");
          if (cGO) { mi_go_active = il2_get_method(cGO, "get_activeInHierarchy", 0); mi_go_layer = il2_get_method(cGO, "get_layer", 0); } }
        if (k_smr) mi_smr_offscreen = il2_get_method(k_smr, "set_updateWhenOffscreen", 1);
        mi_cam_occ = il2_get_method(cCamera, "set_useOcclusionCulling", 1);
        void *animImg = findImage("UnityEngine.AnimationModule.dll");
        if (animImg) {
            k_animator = il2_class_from_name(animImg, "UnityEngine", "Animator");
            if (k_animator) mi_anim_cull = il2_get_method(k_animator, "set_cullingMode", 1);
        }
        k_occsys = il2_class_from_name(game, "Chillow.StandChillow.Occlusion.Dynamic", "OcclusionSystem");
    }
    if (cRend) {
        mi_get_smats = il2_get_method(cRend, "get_sharedMaterials", 0);
        mi_set_smats = il2_get_method(cRend, "set_sharedMaterials", 1);
    }
    if (k_shader) {
        mi_find_shader = findMethod(k_shader, "Find", 1, "System.String");
        mi_setglobal   = findMethod(k_shader, "SetGlobalFloat", 2, "System.String");
    }
    if (k_material) {
        mi_mat_ctor  = findMethod(k_material, ".ctor", 1, "UnityEngine.Shader");
        mi_set_color = il2_get_method(k_material, "set_color", 1);
        mi_set_queue = il2_get_method(k_material, "set_renderQueue", 1);
        mi_setint    = findMethod(k_material, "SetInt", 2, "System.String");
        mi_hasprop   = findMethod(k_material, "HasProperty", 1, "System.String");
    }

    for (int i = 0; i < kN; i++) k_targets[i] = il2_class_from_name(game, kTargets[i].ns, kTargets[i].name);
    k_aim = il2_class_from_name(game, "Chillow.StandChillow.Player.Aim", "AimController");
    NSLog(@"[SCESP] resolve: find=%p cam=%p w2s=%p tr=%p pos=%p parent=%p bones=%p",
          mi_find, d_cam_main, d_world2screen, d_tr, d_pos, d_parent, mi_get_bones);
    bool any = false; for (int i = 0; i < kN; i++) if (k_targets[i]) any = true;
    return mi_find && d_cam_main && d_world2screen && d_tr && d_pos && d_sw && d_sh && any;
}

static void findTeamFields(void *klass) {
    g_teamOffsets.clear();
    g_teamField = -1;
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;
            const char *tn = il2_type_name(il2_field_type(f));
            if (tn && strcmp(tn, kTeamType) == 0) g_teamOffsets.push_back(il2_field_offset(f));
        }
    }
}

static inline bool alive(void *obj) { return obj && *(void **)((char *)obj + 16) != nullptr; }
static inline int readTeam(void *obj, int field) {
    if (field < 0 || field >= (int)g_teamOffsets.size()) return 0;
    return *(int *)((char *)obj + g_teamOffsets[field]);
}

// ---- aim lock (offline) ----------------------------------------------------------------
// The look angles live in obfuscated float fields, so they are LEARNED at runtime: while the user
// turns the view, every float field of the local PlayerController / AimController (one nesting level
// deep) is correlated with the camera's yaw / pitch. The best match is then nudged toward the target.
// The correction is computed from the camera's real forward vector every tick, so recoil kicks are
// compensated one tick later.
static std::vector<uint32_t> g_aimH;
struct Cand { uint8_t src, deref; int off, off2; };
struct Stat { float last = 0; bool have = false; double sv2 = 0, sy2 = 0, sp2 = 0, svy = 0, svp = 0; int n = 0; };
static std::vector<Cand> g_cands;
static std::vector<Stat> g_stats;
static bool g_learn = false, g_lhave = false;
static float g_ly = 0, g_lp = 0;
static double g_learnT0 = 0, g_msgUntil = 0;
static NSString *g_learnMsg = @"aim: not learned";
static Cand g_yawC = {0, 0, 0, 0}, g_pitC = {0, 0, 0, 0};
static float g_yawK = 0, g_pitK = 0;
static bool g_haveYaw = false, g_havePit = false;

static inline float wrap180(float a) { while (a > 180.f) a -= 360.f; while (a < -180.f) a += 360.f; return a; }

static void pushCand(uint8_t src, int mode, int outer, int off) {
    if (g_cands.size() > 4000) return;
    if (mode == 0)      g_cands.push_back({ src, 0, off, 0 });
    else if (mode == 1) g_cands.push_back({ src, 0, outer + off - 16, 0 });   // inline struct
    else                g_cands.push_back({ src, 1, outer, off });            // through a reference
}
static void scanClass(void *klass, uint8_t src, int mode, int outer, int depth) {
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;
            void *ft = il2_field_type(f);
            const char *tn = ft ? il2_type_name(ft) : nullptr;
            if (!tn) continue;
            int off = il2_field_offset(f);
            if (!strcmp(tn, "System.Single")) pushCand(src, mode, outer, off);
            else if (!strcmp(tn, "UnityEngine.Vector2")) { pushCand(src, mode, outer, off); pushCand(src, mode, outer, off + 4); }
            else if (depth == 0 && mode == 0 && il2_class_from_type && il2_class_is_vt && !strncmp(tn, "Chillow.StandChillow.Player.", 28)) {
                void *nk = il2_class_from_type(ft);
                if (nk) scanClass(nk, src, il2_class_is_vt(nk) ? 1 : 2, off, 1);
            }
        }
    }
}
static float *candAddr(const Cand &c, void *me, void *aim) {
    char *o = (char *)(c.src == 0 ? me : aim);
    if (!o) return nullptr;
    if (c.deref) { char *p = *(char **)(o + c.off); return p ? (float *)(p + c.off2) : nullptr; }
    return (float *)(o + c.off);
}
static void *nearestAim(V3 cp) {
    void *best = nullptr; float bd = 1e9f;
    for (uint32_t h : g_aimH) {
        void *o = il2_gc_get(h);
        if (!alive(o)) continue;
        void *tr = d_tr(o, mi_tr);
        if (!tr) continue;
        V3 q = d_pos(tr, mi_pos);
        float dx = q.x - cp.x, dy = q.y - cp.y, dz = q.z - cp.z, d = dx * dx + dy * dy + dz * dz;
        if (d < bd) { bd = d; best = o; }
    }
    return best;
}
static void saveAim() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (g_haveYaw) [d setObject:@[@(g_yawC.src), @(g_yawC.deref), @(g_yawC.off), @(g_yawC.off2), @(g_yawK)] forKey:@"scesp_yawc"];
    if (g_havePit) [d setObject:@[@(g_pitC.src), @(g_pitC.deref), @(g_pitC.off), @(g_pitC.off2), @(g_pitK)] forKey:@"scesp_pitc"];
}
static void loadAim() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *y = [d arrayForKey:@"scesp_yawc"], *p = [d arrayForKey:@"scesp_pitc"];
    if (y.count == 5) { g_yawC.src = [y[0] intValue]; g_yawC.deref = [y[1] intValue]; g_yawC.off = [y[2] intValue]; g_yawC.off2 = [y[3] intValue]; g_yawK = [y[4] floatValue]; g_haveYaw = true; }
    if (p.count == 5) { g_pitC.src = [p[0] intValue]; g_pitC.deref = [p[1] intValue]; g_pitC.off = [p[2] intValue]; g_pitC.off2 = [p[3] intValue]; g_pitK = [p[4] floatValue]; g_havePit = true; }
    if (g_haveYaw && g_havePit) g_learnMsg = @"aim: learned fields loaded";
}
static void learnStep(void *me, void *aim, float yaw, float pit) {
    if (!g_lhave) {
        g_ly = yaw; g_lp = pit; g_lhave = true;
        for (size_t i = 0; i < g_cands.size(); i++) { float *a = candAddr(g_cands[i], me, aim); g_stats[i].have = a != nullptr; if (a) g_stats[i].last = *a; }
        return;
    }
    float dy = wrap180(yaw - g_ly), dp = pit - g_lp;
    g_ly = yaw; g_lp = pit;
    bool moved = fabsf(dy) > 0.15f || fabsf(dp) > 0.15f;
    for (size_t i = 0; i < g_cands.size(); i++) {
        Stat &s = g_stats[i];
        float *a = candAddr(g_cands[i], me, aim);
        if (!a) { s.have = false; continue; }
        float v = *a;
        if (!s.have) { s.last = v; s.have = true; continue; }
        float dv = v - s.last; s.last = v;
        if (dv > 180.f) dv -= 360.f; else if (dv < -180.f) dv += 360.f;
        if (!moved || dv != dv || fabsf(dv) > 200.f || fabsf(dy) > 90.f) continue;
        s.sv2 += (double)dv * dv; s.sy2 += (double)dy * dy; s.sp2 += (double)dp * dp;
        s.svy += (double)dv * dy; s.svp += (double)dv * dp; s.n++;
    }
}
static void learnFinish() {
    g_learn = false; g_lhave = false;
    int by = -1, bp = -1; double cy = 0.97, cp = 0.97, ky = 0, kp = 0;
    for (size_t i = 0; i < g_cands.size(); i++) {
        Stat &s = g_stats[i];
        if (s.n < 12 || s.sv2 < 1e-12) continue;
        double ry = s.svy / sqrt(s.sv2 * s.sy2 + 1e-18), rp = s.svp / sqrt(s.sv2 * s.sp2 + 1e-18);
        double sy = s.svy / (s.sy2 + 1e-12), sp = s.svp / (s.sp2 + 1e-12);
        if (s.sy2 > 20 && fabs(ry) > cy && fabs(sy) > 0.005 && fabs(sy) < 50) { cy = fabs(ry); by = (int)i; ky = sy; }
        if (s.sp2 > 20 && fabs(rp) > cp && fabs(sp) > 0.005 && fabs(sp) < 50) { cp = fabs(rp); bp = (int)i; kp = sp; }
    }
    if (by >= 0 && by == bp) bp = -1;
    if (by >= 0) { g_yawC = g_cands[by]; g_yawK = (float)ky; g_haveYaw = true; }
    if (bp >= 0) { g_pitC = g_cands[bp]; g_pitK = (float)kp; g_havePit = true; }
    saveAim();
    g_learnMsg = [NSString stringWithFormat:@"learn: yaw %s (%.2f) pitch %s (%.2f) of %zu", by >= 0 ? "OK" : "NO", cy, bp >= 0 ? "OK" : "NO", cp, g_cands.size()];
    g_msgUntil = CACurrentMediaTime() + 10;
    NSLog(@"[SCESP] %@  yaw k=%.4f off=%d/%d  pit k=%.4f off=%d/%d", g_learnMsg, g_yawK, g_yawC.off, g_yawC.off2, g_pitK, g_pitC.off, g_pitC.off2);
}
static void aimStep(void *me, void *aim, float dyaw, float dpit) {
    float *py = candAddr(g_yawC, me, aim), *pp = candAddr(g_pitC, me, aim);
    if (py) *py += g_yawK * dyaw * 0.5f;
    if (pp) *pp += g_pitK * dpit * 0.5f;
}

// ---- scene scan ------------------------------------------------------------------------
struct PlayerInfo {
    std::vector<char> skip;         // per bone: junk bone (by name), never drawn
    uint32_t obj = 0;
    std::vector<uint32_t> smr;      // SkinnedMeshRenderer handles belonging to this player
    std::vector<uint32_t> anim;     // Animator handles belonging to this player
    uint32_t body = 0;              // the SMR with the most bones = third-person body (not FP arms)
    std::vector<uint32_t> bone;     // Transform handles (biggest SMR's bones)
    std::vector<int> parent;        // parent index inside `bone`, or -1
};
static std::vector<PlayerInfo> g_pl;

static std::unordered_map<void *, char> g_skipCache;
static int g_dumped = 0;
static bool boneNameSkip(void *tr) {
    auto it = g_skipCache.find(tr);
    if (it != g_skipCache.end()) return it->second;
    bool skip = false;
    if (mi_get_name && il2_str_chars && il2_str_len) {
        void *str = inv(mi_get_name, tr, nullptr);
        if (str) {
            int len = il2_str_len(str);
            const uint16_t *ch = il2_str_chars(str);
            char buf[96]; int n = len < 95 ? len : 95; if (n < 0) n = 0;
            for (int i = 0; i < n; i++) buf[i] = ch[i] < 128 ? (char)tolower(ch[i]) : '?';
            buf[n] = 0;
            for (const char *k : kBoneSkip) if (strstr(buf, k)) { skip = true; break; }
            if (g_dumped < 90) { g_dumped++; NSLog(@"[SCESP] bone '%s'%s", buf, skip ? " (skipped)" : ""); }
        }
    }
    if (g_skipCache.size() > 8192) g_skipCache.clear();
    g_skipCache[tr] = skip;
    return skip;
}

static void freeInfo(PlayerInfo &p) {
    if (p.obj) il2_gc_free(p.obj);
    for (uint32_t h : p.smr) il2_gc_free(h);
    for (uint32_t h : p.anim) il2_gc_free(h);
    if (p.body) il2_gc_free(p.body);
    for (uint32_t h : p.bone) il2_gc_free(h);
}

static size_t findObjs(void *klass, std::vector<void *> &out, size_t cap) {
    void *typeObj = il2_type_object(il2_class_type(klass));
    bool inactive = false;
    void *args[2] = { typeObj, &inactive };
    void *arr = inv(mi_find, nullptr, args);
    if (!arr) return 0;
    uintptr_t len = *(uintptr_t *)((char *)arr + 24);
    void **elems = (void **)((char *)arr + 32);
    if (len > cap) len = cap;
    size_t n = 0;
    for (uintptr_t i = 0; i < len; i++) if (elems[i]) { out.push_back(elems[i]); n++; }
    return n;
}

static void rescan(bool wantBones) {
    std::vector<void *> objs;
    for (int t = 0; t < kN; t++) g_counts[t] = 0;
    for (uint32_t h : g_aimH) il2_gc_free(h);
    g_aimH.clear();
    if (k_aim) { std::vector<void *> ao; findObjs(k_aim, ao, 32); for (void *x : ao) g_aimH.push_back(il2_gc_new(x, 0)); }
    if (g_active >= 0 && k_targets[g_active]) g_counts[g_active] = findObjs(k_targets[g_active], objs, 64);
    if (objs.empty()) {
        for (int t = 0; t < kN; t++) {
            if (!k_targets[t]) continue;
            g_counts[t] = findObjs(k_targets[t], objs, 64);
            if (g_counts[t] > 0) { if (g_active != t) { g_active = t; findTeamFields(k_targets[t]); } break; }
        }
    }

    std::vector<PlayerInfo> fresh(objs.size());
    for (size_t i = 0; i < objs.size(); i++) fresh[i].obj = il2_gc_new(objs[i], 0);

    if (wantBones && k_smr && mi_get_bones && d_parent && !objs.empty()) {
        // ancestors (self, parent, grandparent) of every player; unique ones identify the owner
        struct Anc { void *tr; int pl; int cnt; };
        std::vector<Anc> anc;
        for (size_t i = 0; i < objs.size(); i++) {
            void *tr = d_tr(objs[i], mi_tr);
            for (int lvl = 0; lvl < 3 && tr; lvl++) {
                bool found = false;
                for (auto &a : anc) if (a.tr == tr) { a.cnt++; found = true; break; }
                if (!found) anc.push_back({tr, (int)i, 1});
                tr = d_parent(tr, mi_parent);
            }
        }
        auto ownerOf = [&](void *comp) -> int {
            void *tr = d_tr(comp, mi_tr);
            for (int depth = 0; depth < 20 && tr; depth++) {
                for (auto &a : anc) if (a.tr == tr && a.cnt == 1) return a.pl;
                tr = d_parent(tr, mi_parent);
            }
            return -1;
        };
        std::vector<void *> smrs;
        findObjs(k_smr, smrs, 512);
        std::vector<std::vector<void *>> mine(objs.size());
        for (void *smr : smrs) { int o = ownerOf(smr); if (o >= 0) mine[o].push_back(smr); }
        std::vector<std::vector<void *>> animsOf(objs.size());
        if (k_animator) {
            std::vector<void *> anims;
            findObjs(k_animator, anims, 512);
            for (void *an : anims) { int o = ownerOf(an); if (o >= 0) animsOf[o].push_back(an); }
        }
        for (size_t i = 0; i < objs.size(); i++) {
            void *best = nullptr, *bestSmr = nullptr; uintptr_t bestN = 0;
            for (void *smr : mine[i]) {
                fresh[i].smr.push_back(il2_gc_new(smr, 0));
                void *arr = inv(mi_get_bones, smr, nullptr);
                uintptr_t n = arr ? *(uintptr_t *)((char *)arr + 24) : 0;
                if (n > bestN) { bestN = n; best = arr; bestSmr = smr; }
            }
            for (void *an : animsOf[i]) fresh[i].anim.push_back(il2_gc_new(an, 0));
            if (bestSmr) fresh[i].body = il2_gc_new(bestSmr, 0);
            if (!best) continue;
            if (bestN > 160) bestN = 160;
            void **bones = (void **)((char *)best + 32);
            std::vector<void *> bp;
            for (uintptr_t b = 0; b < bestN; b++) {
                bp.push_back(bones[b]);
                fresh[i].bone.push_back(bones[b] ? il2_gc_new(bones[b], 0) : 0);
                fresh[i].skip.push_back(bones[b] ? (char)boneNameSkip(bones[b]) : 1);
            }
            for (uintptr_t b = 0; b < bestN; b++) {
                int pi = -1;
                if (bp[b]) {
                    void *par = d_parent(bp[b], mi_parent);
                    for (uintptr_t c = 0; c < bestN && par; c++) if (bp[c] == par) { pi = (int)c; break; }
                }
                fresh[i].parent.push_back(pi);
            }
        }
    }
    for (auto &p : g_pl) freeInfo(p);
    g_pl.swap(fresh);
}

// ---- occlusion override ----------------------------------------------------------------
// The game hides occluded characters itself (OcclusionSystem -> ObjectOccludee), and animators of
// hidden models stop updating (that is the T-pose). Turn that system off while skeleton/chams are on.
static std::vector<uint32_t> g_occ;
static bool g_occOff = false;

static void setOcclusion(bool disabled) {
    for (uint32_t h : g_occ) il2_gc_free(h);
    g_occ.clear();
    if (k_occsys) {
        std::vector<void *> o;
        findObjs(k_occsys, o, 8);
        for (void *x : o) g_occ.push_back(il2_gc_new(x, 0));
    }
    bool en = !disabled;
    for (uint32_t h : g_occ) {
        void *x = il2_gc_get(h);
        if (alive(x)) { void *a[1] = { &en }; inv(mi_beh_enabled, x, a); }
    }
    void *cam = d_cam_main(mi_cam_main);
    if (cam && alive(cam)) { bool u = !disabled; void *a[1] = { &u }; inv(mi_cam_occ, cam, a); }
    g_occOff = disabled;
}

static void forceVisible(bool full) {
    // Only enemy bodies: never "me" (the camera's own third-person body must stay hidden) and
    // never the first-person arms meshes (they float in the air if switched on).
    void *cam = d_cam_main(mi_cam_main);
    bool haveCam = false; V3 cp = { 0, 0, 0 };
    if (cam && alive(cam)) { void *ct = d_tr(cam, mi_tr); if (ct) { cp = d_pos(ct, mi_pos); haveCam = true; } }
    for (auto &p : g_pl) {
        void *po = il2_gc_get(p.obj);
        if (!alive(po)) continue;
        if (haveCam) {
            void *tr = d_tr(po, mi_tr);
            if (!tr) continue;
            V3 q = d_pos(tr, mi_pos);
            float dx = q.x - cp.x, dz = q.z - cp.z;
            if (dx * dx + dz * dz < kSelfRadius * kSelfRadius * 4) continue;      // me
        } else continue;
        if (p.body) {
            void *r = il2_gc_get(p.body);
            if (alive(r)) {
                bool t = true; void *a[1] = { &t };
                inv(mi_rend_enabled, r, a);
                { bool f = false; void *a2[1] = { &f }; inv(mi_rend_set_froff, r, a2); }
                if (full) inv(mi_smr_offscreen, r, a);
            }
        }
        if (!full) continue;
        for (uint32_t h : p.anim) {
            void *an = il2_gc_get(h);
            if (!alive(an)) continue;
            int mode = 0; void *a1[1] = { &mode };      // AnimatorCullingMode.AlwaysAnimate
            inv(mi_anim_cull, an, a1);
        }
    }
}

// ---- chams -----------------------------------------------------------------------------
struct Cham { uint32_t rend; uint32_t orig; };
static std::vector<Cham> g_chams;
static uint32_t g_chamMat = 0;
static const char *g_chamShaderUsed = nullptr;
static bool g_chamFailed = false;
static int g_chamMode = 2;          // 0 = shader has _ZTest, 1 = UI/Default via unity_GUIZTestMode, 2 = no x-ray
static uint32_t g_ztName = 0;

static void setMatInt(void *mat, const char *name, int v) {
    void *s = il2_string_new(name);
    void *args[2] = { s, &v };
    inv(mi_setint, mat, args);
}
static void updateChamColor() {
    if (!g_chamMat || !mi_set_color) return;
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    UIColor *u = colorFor(g_set.color, 1);
    CGFloat r, g, b, a; [u getRed:&r green:&g blue:&b alpha:&a];
    Col c = { (float)r, (float)g, (float)b, 0.65f };
    void *args[1] = { &c };
    inv(mi_set_color, mat, args);
}
static bool matHasProp(void *mat, const char *name) {
    if (!mi_hasprop) return true;                       // cannot check: assume yes
    void *args[1] = { il2_string_new(name) };
    void *r = inv(mi_hasprop, mat, args);
    return r ? *(bool *)((char *)r + 16) : false;       // boxed bool
}
static int g_chamReapply = 0;
static bool ensureChamMaterial() {
    if (g_chamMat) return true;
    if (g_chamFailed || !mi_find_shader || !mi_mat_ctor || !k_material) { g_chamFailed = true; return false; }
    void *chosen = nullptr, *fallback = nullptr;
    const char *used = nullptr, *fallbackName = nullptr;
    int mode = 2;
    for (const char *nm : kChamShaders) {
        void *args[1] = { il2_string_new(nm) };
        void *shader = inv(mi_find_shader, nullptr, args);
        if (!shader) continue;
        void *mat = il2_object_new(k_material);
        if (!mat) continue;
        void *cargs[1] = { shader };
        inv(mi_mat_ctor, mat, cargs);
        int m = 2;
        if (!strcmp(nm, "Hidden/Internal-Colored")) m = matHasProp(mat, "_ZTest") ? 0 : 2;   // 0 = _ZTest property
        else if (!strcmp(nm, "GUI/Text Shader"))    m = 3;                                    // 3 = ZTest Always baked in
        else if (!strcmp(nm, "UI/Default"))         m = mi_setglobal ? 1 : 2;                 // 1 = via global
        if (m != 2) { chosen = mat; mode = m; used = nm; break; }
        if (!fallback) { fallback = mat; fallbackName = nm; }
    }
    if (!chosen) { chosen = fallback; used = fallbackName; mode = 2; }
    if (!chosen) { g_chamFailed = true; return false; }
    g_chamShaderUsed = used; g_chamMode = mode;
    g_chamMat = il2_gc_new(chosen, 0);
    if (g_chamMode == 0 && mi_setint) { setMatInt(chosen, "_ZTest", 8); setMatInt(chosen, "_ZWrite", 0); setMatInt(chosen, "_Cull", 0); }
    if (mi_set_queue) { int q = 3500; void *a[1] = { &q }; inv(mi_set_queue, chosen, a); }
    updateChamColor();
    NSLog(@"[SCESP] chams shader=%s mode=%d", used, mode);
    return true;
}
// UI/Default reads its ZTest from the global unity_GUIZTestMode; keep it on "Always" while chams are live
static void pumpChamZTest() {
    if (g_chamMode != 1 || !mi_setglobal || g_chams.empty()) return;
    if (!g_ztName) g_ztName = il2_gc_new(il2_string_new("unity_GUIZTestMode"), 0);
    void *nm = il2_gc_get(g_ztName);
    float v = 8.0f;
    void *args[2] = { nm, &v };
    inv(mi_setglobal, nullptr, args);
}
static void restoreCham(Cham &c) {
    void *r = il2_gc_get(c.rend), *orig = il2_gc_get(c.orig);
    if (r && alive(r) && orig) { void *a[1] = { orig }; inv(mi_set_smats, r, a); }
    il2_gc_free(c.rend); il2_gc_free(c.orig);
}
static void applyCham(void *rend) {
    void *orig = inv(mi_get_smats, rend, nullptr);
    if (!orig) return;
    uintptr_t n = *(uintptr_t *)((char *)orig + 24);
    if (n == 0 || n > 16) return;
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    void *arr = il2_array_new(k_material, n);
    if (!arr) return;
    void **el = (void **)((char *)arr + 32);
    for (uintptr_t i = 0; i < n; i++) el[i] = mat;
    void *a[1] = { arr };
    if (inv(mi_set_smats, rend, a) == nullptr && false) return;
    g_chams.push_back({ il2_gc_new(rend, 0), il2_gc_new(orig, 0) });
}
// The game replaces sharedMaterials itself (hit flash, state change). Our entry would stay in g_chams
// while the cham is already gone -> check the live array and put our material back.
static void verifyChams() {
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    for (auto &c : g_chams) {
        void *r = il2_gc_get(c.rend);
        if (!r || !alive(r)) continue;
        void *cur = inv(mi_get_smats, r, nullptr);
        if (!cur) continue;
        uintptr_t n = *(uintptr_t *)((char *)cur + 24);
        if (n == 0 || n > 16) continue;
        void **el = (void **)((char *)cur + 32);
        bool ok = true;
        for (uintptr_t i = 0; i < n; i++) if (el[i] != mat) { ok = false; break; }
        if (ok) continue;
        void *arr = il2_array_new(k_material, n);
        if (!arr) continue;
        void **ne = (void **)((char *)arr + 32);
        for (uintptr_t i = 0; i < n; i++) ne[i] = mat;
        void *a[1] = { arr };
        inv(mi_set_smats, r, a);
        g_chamReapply++;
    }
}
// `want` = renderers that should carry chams right now (enemy SMRs); empty = restore everything
static void reconcileChams(const std::vector<void *> &want) {
    for (size_t i = 0; i < g_chams.size();) {
        void *r = il2_gc_get(g_chams[i].rend);
        bool keep = r && alive(r);
        if (keep) { keep = false; for (void *w : want) if (w == r) { keep = true; break; } }
        if (!keep) { restoreCham(g_chams[i]); g_chams.erase(g_chams.begin() + i); } else i++;
    }
    if (want.empty() || !mi_get_smats || !mi_set_smats || !ensureChamMaterial()) return;
    for (void *w : want) {
        bool has = false;
        for (auto &c : g_chams) if (il2_gc_get(c.rend) == w) { has = true; break; }
        if (!has) applyCham(w);
    }
}


// ---- class/method dump (for finding the fire path) ----------------------------------------
// Panel button "Dump -> clipboard": every class of the game image whose name looks shooting-related,
// with the methods that look relevant: signature + RVA (address minus image base).
static NSString *dumpFirePath() {
    void *game = findImage(kGameImage);
    if (!game) return @"game image not found";
    typedef size_t (*f_cnt)(void *);              typedef void *(*f_cls)(void *, size_t);
    typedef const char *(*f_nm)(void *);          typedef void *(*f_ret)(void *);
    f_cnt  imgCount = (f_cnt)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    f_cls  imgClass = (f_cls)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
    f_nm   cName    = (f_nm)dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    f_nm   cNs      = (f_nm)dlsym(RTLD_DEFAULT, "il2cpp_class_get_namespace");
    f_ret  mRet     = (f_ret)dlsym(RTLD_DEFAULT, "il2cpp_method_get_return_type");
    if (!imgCount || !imgClass || !cName || !cNs || !mRet) return @"il2cpp class enumeration API missing";

    static const char *clsKeys[] = { "weapon", "gun", "shoot", "fire", "bullet", "projectile", "ballistic", "hitscan", "raycast", "aim", "recoil", "damage", "firearm", "shot" };
    static const char *mthKeys[] = { "fire", "shoot", "shot", "ray", "hit", "bullet", "aim", "spread", "recoil", "direction", "damage", "cast", "trace", "muzzle", "origin", "projectile", "attack" };
    auto lower = [](const char *in) { std::string o; for (; in && *in; in++) o += (char)tolower(*in); return o; };
    auto hit = [](const std::string &h, const char *const *keys, size_t n) { for (size_t i = 0; i < n; i++) if (h.find(keys[i]) != std::string::npos) return true; return false; };

    NSMutableString *out = [NSMutableString string];
    size_t total = imgCount(game);
    int classesOut = 0;
    for (size_t i = 0; i < total && classesOut < 80 && out.length < 60000; i++) {
        void *k = imgClass(game, i);
        if (!k) continue;
        std::string cn = lower(cName(k));
        if (!hit(cn, clsKeys, sizeof(clsKeys) / sizeof(clsKeys[0]))) continue;
        classesOut++;
        [out appendFormat:@"%s.%s\n", cNs(k), cName(k)];
        void *iter = nullptr, *m; int shown = 0;
        while ((m = il2_class_methods(k, &iter)) && shown < 40) {
            const char *mn = il2_method_name(m);
            if (!hit(lower(mn), mthKeys, sizeof(mthKeys) / sizeof(mthKeys[0]))) continue;
            shown++;
            NSMutableString *sig = [NSMutableString string];
            uint32_t pc = il2_method_pcount(m);
            for (uint32_t p = 0; p < pc; p++) { const char *tn = il2_type_name(il2_method_param(m, p)); [sig appendFormat:@"%s%s", p ? ", " : "", tn ? tn : "?"]; }
            const char *rn = il2_type_name(mRet(m));
            void *fp = direct(m); Dl_info di; long rva = 0;
            if (fp && dladdr(fp, &di)) rva = (long)((char *)fp - (char *)di.dli_fbase);
            [out appendFormat:@"  %s %s(%@)  rva=0x%lx\n", rn ? rn : "?", mn, sig, rva];
        }
    }
    return out.length ? out : @"nothing matched";
}

static bool unboxBool(void *b) { return b ? *(bool *)((char *)b + 16) : false; }
static int unboxInt(void *b) { return b ? *(int *)((char *)b + 16) : -1; }
// state of one enemy body renderer, as the engine sees it right now
static NSString *diagRenderer(void *r) {
    if (!r || !alive(r)) return @"diag: -";
    int en = mi_rend_get_enabled ? unboxBool(inv(mi_rend_get_enabled, r, nullptr)) : -1;
    int vis = mi_rend_isvis ? unboxBool(inv(mi_rend_isvis, r, nullptr)) : -1;
    int fo = mi_rend_get_froff ? unboxBool(inv(mi_rend_get_froff, r, nullptr)) : -1;
    int act = -1, layer = -1;
    void *go = mi_get_go ? inv(mi_get_go, r, nullptr) : nullptr;
    if (go) { act = mi_go_active ? unboxBool(inv(mi_go_active, go, nullptr)) : -1; layer = mi_go_layer ? unboxInt(inv(mi_go_layer, go, nullptr)) : -1; }
    void *cam = d_cam_main(mi_cam_main);
    int co = (cam && mi_cam_get_occ) ? unboxBool(inv(mi_cam_get_occ, cam, nullptr)) : -1;
    return [NSString stringWithFormat:@"diag e%d v%d f%d act%d L%d camOcc%d", en, vis, fo, act, layer, co];
}

// ---- UI --------------------------------------------------------------------------------
@interface SCESPDriver : NSObject
- (void)tick;
@end

@implementation SCESPDriver {
    UIView *_overlay;
    CAShapeLayer *_boxes, *_skel;
    UIButton *_btn;
    UIView *_panel;
    UILabel *_status;
    UILabel *_lwLabel, *_hdLabel;
    int _frame, _vfy;
    void *_diagR;
    double _lastTick, _lastScan;
}

- (UIWindow *)keyWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)addSwitch:(NSString *)title col:(int)col row:(int)row tag:(int)tag on:(BOOL)on {
    CGFloat cx = col ? 170 : 10, y = 30 + row * 28;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(cx, y, 96, 26)];
    l.text = title; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:12];
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.7;
    UISwitch *s = [[UISwitch alloc] init];
    s.transform = (CGAffineTransform){ 0.68, 0, 0, 0.68, 0, 0 };
    s.center = CGPointMake(cx + 96 + 20, y + 13);
    s.tag = tag; s.on = on;
    [s addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:l]; [_panel addSubview:s];
}

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(8, 72, 330, 312)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
    _panel.layer.cornerRadius = 10;
    _panel.hidden = YES;

    UILabel *hd = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 330, 26)];
    hd.text = @"  \u2630  ESP settings  (drag here to move)";
    hd.textColor = UIColor.whiteColor; hd.font = [UIFont boldSystemFontOfSize:12];
    hd.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    hd.userInteractionEnabled = YES;
    hd.layer.cornerRadius = 10; hd.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    hd.clipsToBounds = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMoved:)];
    [hd addGestureRecognizer:pan];
    [_panel addSubview:hd];

    [self addSwitch:@"ESP" col:0 row:0 tag:0 on:g_set.on];
    [self addSwitch:@"Box" col:1 row:0 tag:1 on:g_set.box];
    [self addSwitch:@"Skeleton" col:0 row:1 tag:2 on:g_set.skel];
    [self addSwitch:@"Chams" col:1 row:1 tag:3 on:g_set.chams];
    [self addSwitch:@"Box fill" col:0 row:2 tag:4 on:g_set.fill];
    [self addSwitch:@"Teammates" col:1 row:2 tag:5 on:g_set.team];
    [self addSwitch:@"Low CPU" col:0 row:3 tag:6 on:g_set.lowcpu];
    [self addSwitch:@"No occlusion" col:1 row:3 tag:7 on:g_set.noocc];

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"R", @"G", @"C", @"Y", @"W", @"M", @"O"]];
    seg.frame = CGRectMake(10, 148, 310, 26);
    seg.selectedSegmentIndex = g_set.color;
    [seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:seg];

    _lwLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 180, 150, 14)];
    _lwLabel.textColor = UIColor.whiteColor; _lwLabel.font = [UIFont systemFontOfSize:10];
    [_panel addSubview:_lwLabel];
    UISlider *s1 = [[UISlider alloc] initWithFrame:CGRectMake(10, 194, 150, 26)];
    s1.minimumValue = 0.5; s1.maximumValue = 4; s1.value = g_set.lw; s1.tag = 10;
    [s1 addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:s1];

    _hdLabel = [[UILabel alloc] initWithFrame:CGRectMake(170, 180, 150, 14)];
    _hdLabel.textColor = UIColor.whiteColor; _hdLabel.font = [UIFont systemFontOfSize:10];
    [_panel addSubview:_hdLabel];
    UISlider *s2 = [[UISlider alloc] initWithFrame:CGRectMake(170, 194, 150, 26)];
    s2.minimumValue = 1.4; s2.maximumValue = 2.2; s2.value = g_set.head; s2.tag = 11;
    [s2 addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:s2];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(10, 224, 310, 50)];
    _status.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    _status.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _status.numberOfLines = 4;
    [_panel addSubview:_status];
    UIButton *lb = [UIButton buttonWithType:UIButtonTypeCustom];
    lb.frame = CGRectMake(10, 280, 150, 26);
    lb.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1]; lb.layer.cornerRadius = 6;
    lb.titleLabel.font = [UIFont systemFontOfSize:12];
    [lb setTitle:@"Learn look fields" forState:UIControlStateNormal];
    [lb addTarget:self action:@selector(learnTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:lb];
    UILabel *al = [[UILabel alloc] initWithFrame:CGRectMake(170, 280, 96, 26)];
    al.text = @"Aim lock"; al.textColor = UIColor.whiteColor; al.font = [UIFont systemFontOfSize:12];
    [_panel addSubview:al];
    UISwitch *as = [[UISwitch alloc] init];
    as.transform = (CGAffineTransform){ 0.68, 0, 0, 0.68, 0, 0 };
    as.center = CGPointMake(170 + 96 + 20, 293);
    as.tag = 8; as.on = g_set.aim;
    [as addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:as];
    [self refreshLabels];
}

- (void)panMoved:(UIPanGestureRecognizer *)g {
    UIView *sv = _panel.superview;
    if (!sv) return;
    CGPoint t = [g translationInView:sv];
    CGPoint c = CGPointMake(_panel.center.x + t.x, _panel.center.y + t.y);
    CGSize hs = CGSizeMake(_panel.bounds.size.width / 2, _panel.bounds.size.height / 2);
    if (c.x < hs.width * 0.3) c.x = hs.width * 0.3;
    if (c.y < hs.height * 0.3) c.y = hs.height * 0.3;
    if (c.x > sv.bounds.size.width - hs.width * 0.3) c.x = sv.bounds.size.width - hs.width * 0.3;
    if (c.y > sv.bounds.size.height - hs.height * 0.3) c.y = sv.bounds.size.height - hs.height * 0.3;
    _panel.center = c;
    [g setTranslation:CGPointMake(0, 0) inView:sv];
}

- (void)refreshLabels {
    _lwLabel.text = [NSString stringWithFormat:@"Line width: %.1f", g_set.lw];
    _hdLabel.text = [NSString stringWithFormat:@"Box height m: %.2f", g_set.head];
}

- (void)swChanged:(UISwitch *)s {
    switch (s.tag) {
        case 0: g_set.on = s.on; break;
        case 1: g_set.box = s.on; break;
        case 2: g_set.skel = s.on; break;
        case 3: g_set.chams = s.on; break;
        case 4: g_set.fill = s.on; break;
        case 5: g_set.team = s.on; break;
        case 6: g_set.lowcpu = s.on; break;
        case 7: g_set.noocc = s.on; break;
        case 8: g_set.aim = s.on; break;
    }
    g_dirty = true; saveSettings();
}
- (void)segChanged:(UISegmentedControl *)s { g_set.color = (int)s.selectedSegmentIndex; g_dirty = true; saveSettings(); }
- (void)slChanged:(UISlider *)s {
    if (s.tag == 10) g_set.lw = s.value; else g_set.head = s.value;
    [self refreshLabels]; saveSettings();
}
- (void)plateTapped { _panel.hidden = !_panel.hidden; }
- (void)learnTapped {
    if (!g_ready) return;
    if (g_learn) { learnFinish(); return; }
    if (g_active < 0 || !k_targets[g_active]) { g_learnMsg = @"learn: no player class yet"; g_msgUntil = CACurrentMediaTime() + 5; return; }
    g_cands.clear(); g_stats.clear(); g_lhave = false;
    scanClass(k_targets[g_active], 0, 0, 0, 0);
    if (k_aim) scanClass(k_aim, 1, 0, 0, 0);
    g_stats.assign(g_cands.size(), Stat());
    g_learn = true; g_learnT0 = CACurrentMediaTime();
}
- (void)dumpTapped {
    if (!g_ready) { _status.text = @"dump: game not ready yet"; return; }
    NSString *d = dumpFirePath();
    UIPasteboard.generalPasteboard.string = d;
    NSLog(@"[SCESP] dump (%lu chars) copied to clipboard\n%@", (unsigned long)d.length, d);
    _status.text = [NSString stringWithFormat:@"dump copied: %lu chars", (unsigned long)d.length];
}

// Called from a run-loop observer that fires AFTER Unity's frame callback, so bone and camera
// transforms are the ones of the frame that was just rendered (no one-frame lag).
- (void)tick {
    double now = CACurrentMediaTime();
    double minDt = g_set.lowcpu ? 0.030 : 0.0145;
    if (now - _lastTick < minDt) return;
    _lastTick = now;

    UIWindow *win = [self keyWindow];
    if (!win) return;
    if (!_btn) {
        _btn = [UIButton buttonWithType:UIButtonTypeCustom];
        _btn.frame = CGRectMake(8, 44, 64, 24);
        _btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _btn.layer.cornerRadius = 6;
        _btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
        [_btn setTitle:@"ESP \u2699" forState:UIControlStateNormal];
        [_btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [_btn addTarget:self action:@selector(plateTapped) forControlEvents:UIControlEventTouchUpInside];
        [self buildPanel];
    }
    if (_btn.superview != win) { [_btn removeFromSuperview]; [win addSubview:_btn]; }
    if (_panel.superview != win) { [_panel removeFromSuperview]; [win addSubview:_panel]; }
    [win bringSubviewToFront:_panel];
    [win bringSubviewToFront:_btn];

    if (!g_ready) {
        if (_frame++ % 30) return;
        if (!g_apiOk) g_apiOk = loadApi();
        if (!g_apiOk) { _status.text = @"il2cpp API missing"; return; }
        if (!resolveAll()) { _status.text = @"waiting for game classes..."; return; }
        g_ready = true; _lastScan = 0;
    }
    if (!_overlay) {
        _overlay = [[UIView alloc] initWithFrame:win.bounds];
        _overlay.userInteractionEnabled = NO;
        _overlay.backgroundColor = UIColor.clearColor;
        _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _boxes = [CAShapeLayer layer]; _skel = [CAShapeLayer layer];
        _boxes.fillColor = UIColor.clearColor.CGColor; _skel.fillColor = UIColor.clearColor.CGColor;
        [_overlay.layer addSublayer:_boxes]; [_overlay.layer addSublayer:_skel];
    }
    if (_overlay.superview != win) { [_overlay removeFromSuperview]; [win insertSubview:_overlay belowSubview:_btn]; }

    UIBezierPath *boxPath = [UIBezierPath bezierPath];
    UIBezierPath *skelPath = [UIBezierPath bezierPath];
    int drawn = 0, myTeam = -1;
    bool camOk = false;
    std::vector<void *> wantChams;
    bool scanNow = false;
    void *diagR = nullptr;

    if (g_set.on) {
        if (now - _lastScan > 1.0) { rescan(g_set.skel || g_set.chams || g_set.box); scanNow = true; _lastScan = now; }
        @try {
            void *cam = d_cam_main(mi_cam_main);
            int sw = d_sw(mi_sw), sh = d_sh(mi_sh);
            if (cam && alive(cam) && sw > 0 && sh > 0) {
                camOk = true;
                void *ctr = d_tr(cam, mi_tr);
                V3 camPos = d_pos(ctr, mi_pos);
                CGSize vs = _overlay.bounds.size;

                struct P { PlayerInfo *pi; void *obj; V3 pos; bool self; };
                std::vector<P> ps;
                for (auto &pi : g_pl) {
                    void *obj = il2_gc_get(pi.obj);
                    if (!alive(obj)) continue;
                    void *tr = d_tr(obj, mi_tr);
                    if (!tr) continue;
                    V3 pos = d_pos(tr, mi_pos);
                    float dx = pos.x - camPos.x, dz = pos.z - camPos.z;
                    ps.push_back({ &pi, obj, pos, dx * dx + dz * dz < kSelfRadius * kSelfRadius });
                }
                if (g_teamField < 0 && !g_teamOffsets.empty()) {
                    for (int f = 0; f < (int)g_teamOffsets.size(); f++) {
                        bool h1 = false, h2 = false;
                        for (auto &p : ps) { int v = readTeam(p.obj, f); if (v == 1) h1 = true; if (v == 2) h2 = true; }
                        if (h1 && h2) { g_teamField = f; break; }
                    }
                }
                for (auto &p : ps) if (p.self && g_teamField >= 0) myTeam = readTeam(p.obj, g_teamField);

                std::vector<V3> tg; void *meObj = nullptr;
                for (auto &p : ps) if (p.self) meObj = p.obj;
                std::vector<CGPoint> sp; std::vector<char> okp;
                for (auto &p : ps) {
                    if (p.self) continue;
                    if (g_teamField >= 0) {
                        int tv = readTeam(p.obj, g_teamField);
                        if (tv != 1 && tv != 2) continue;
                        if (!g_set.team && (myTeam == 1 || myTeam == 2) && tv == myTeam) continue;
                    }
                    PlayerInfo &pi = *p.pi;
                    if (pi.body) { void *r = il2_gc_get(pi.body); if (r) wantChams.push_back(r); }
                    else for (uint32_t h : pi.smr) { void *r = il2_gc_get(h); if (r) wantChams.push_back(r); }

                    size_t nb = pi.bone.size();
                    sp.assign(nb, CGPointMake(0, 0)); okp.assign(nb, 0);
                    float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
                    V3 hw = { 0, 0, 0 }; float hy = -1e9f;
                    int good = 0;
                    for (size_t b = 0; b < nb; b++) {
                        void *bt = pi.bone[b] ? il2_gc_get(pi.bone[b]) : nullptr;
                        if (!alive(bt)) continue;
                        if (b < pi.skip.size() && pi.skip[b]) continue;
                        V3 w = d_pos(bt, mi_pos);
                        { float ex = w.x - p.pos.x, ey = w.y - p.pos.y, ez = w.z - p.pos.z;
                          if (ey < -kBelowFeet || ey > g_set.head + 0.8f || ex * ex + ez * ez > kMaxReach * kMaxReach) continue; }
                        if (w.y > hy) { hy = w.y; hw = w; }
                        V3 s = d_world2screen(cam, w, mi_w2s);
                        if (s.z <= 0) continue;
                        CGFloat x = s.x / sw * vs.width, y = (1.0 - s.y / sh) * vs.height;
                        sp[b] = CGPointMake(x, y); okp[b] = 1; good++;
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                    if (hy > -1e8f) tg.push_back(hw); else tg.push_back({ p.pos.x, p.pos.y + 1.6f, p.pos.z });
                    bool haveBones = good >= 6;

                    if (g_set.skel && haveBones) {
                        for (size_t b = 0; b < nb; b++) {
                            int par = pi.parent[b];
                            if (par < 0 || !okp[b] || !okp[par]) continue;
                            [skelPath moveToPoint:sp[par]]; [skelPath addLineToPoint:sp[b]];
                        }
                    }
                    if (g_set.box || g_set.fill) {
                        CGRect r;
                        if (haveBones) {
                            CGFloat pad = 6;
                            r = CGRectMake(minX - pad, minY - pad * 2, (maxX - minX) + pad * 2, (maxY - minY) + pad * 3);
                        } else {
                            V3 head = { p.pos.x, p.pos.y + g_set.head, p.pos.z };
                            V3 a = d_world2screen(cam, head, mi_w2s), b = d_world2screen(cam, p.pos, mi_w2s);
                            if (a.z <= 0 || b.z <= 0) continue;
                            CGFloat hx = a.x / sw * vs.width, hy = (1.0 - a.y / sh) * vs.height;
                            CGFloat fx = b.x / sw * vs.width, fy = (1.0 - b.y / sh) * vs.height;
                            CGFloat bh = fy - hy; if (bh < 4) continue;
                            CGFloat bw = bh * 0.5, cx = (hx + fx) * 0.5;
                            r = CGRectMake(cx - bw / 2, hy, bw, bh);
                        }
                        [boxPath appendPath:[UIBezierPath bezierPathWithRect:r]];
                    }
                    drawn++;
                }
                // ---- aim lock / learning (offline) ----
                if (meObj && mi_fwd && d_fwd) {
                    V3 f = d_fwd(ctr, mi_fwd);
                    float curYaw = atan2f(f.x, f.z) * 57.29578f;
                    float curPit = -asinf(fmaxf(-1.f, fminf(1.f, f.y))) * 57.29578f;
                    void *aimObj = nearestAim(camPos);
                    if (g_learn) {
                        learnStep(meObj, aimObj, curYaw, curPit);
                        if (now - g_learnT0 > 6.0) learnFinish();
                        else g_learnMsg = [NSString stringWithFormat:@"learning %.0fs: turn LEFT/RIGHT and UP/DOWN", 6.0 - (now - g_learnT0)];
                    } else if (g_set.aim && g_haveYaw && g_havePit && !tg.empty()) {
                        float best = kAimFov, dyB = 0, dpB = 0; bool got = false;
                        for (auto &t : tg) {
                            float dx = t.x - camPos.x, dy = t.y - camPos.y, dz = t.z - camPos.z;
                            float len = sqrtf(dx * dx + dy * dy + dz * dz);
                            if (len < 0.5f) continue;
                            float ey = wrap180(atan2f(dx, dz) * 57.29578f - curYaw), ep = -asinf(dy / len) * 57.29578f - curPit;
                            float e = sqrtf(ey * ey + ep * ep);
                            if (e < best) { best = e; dyB = ey; dpB = ep; got = true; }
                        }
                        if (got) aimStep(meObj, aimObj, dyB, dpB);
                    }
                }
            }
        } @catch (...) {}
    }

    {
        bool wantOcc = g_set.on && g_set.noocc && (g_set.chams || g_set.skel);
        @try {
            if (scanNow || g_dirty) {
                if (wantOcc) { setOcclusion(true); forceVisible(true); }
                else if (g_occOff) setOcclusion(false);
            } else if (wantOcc && g_occOff) {
                forceVisible(false);    // every tick: the game flips renderers back off on hit / state change
            }
        } @catch (...) {}
    }

    if (!wantChams.empty()) diagR = wantChams[0];
    if (g_dirty || scanNow || !g_set.on) {
        @try {
            if (!g_set.on || !g_set.chams) wantChams.clear();
            reconcileChams(wantChams);
            if (g_dirty) updateChamColor();
        } @catch (...) {}
        g_dirty = false;
    }
    @try { if (g_set.on && g_set.chams && !g_chams.empty() && (++_vfy % 6 == 0)) verifyChams(); } @catch (...) {}
    @try { pumpChamZTest(); } @catch (...) {}

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _boxes.frame = _overlay.bounds; _skel.frame = _overlay.bounds;
    _boxes.strokeColor = g_set.box ? colorFor(g_set.color, 1).CGColor : UIColor.clearColor.CGColor;
    _boxes.fillColor = g_set.fill ? colorFor(g_set.color, 0.18).CGColor : UIColor.clearColor.CGColor;
    _skel.strokeColor = colorFor(g_set.color, 1).CGColor;
    _boxes.lineWidth = g_set.lw; _skel.lineWidth = g_set.lw;
    _boxes.path = boxPath.CGPath; _skel.path = skelPath.CGPath;
    [CATransaction commit];

    if (!_panel.hidden) {
        NSMutableString *cs = [NSMutableString string];
        for (int i = 0; i < kN; i++) [cs appendFormat:@"%s%zu", i ? "/" : "", g_counts[i]];
        NSString *sh = g_chamShaderUsed ? [NSString stringWithUTF8String:g_chamShaderUsed] : (g_chamFailed ? @"no shader" : @"-");
        _status.text = [NSString stringWithFormat:@"found %@ | team f%d me%d | draw %d | cam %@\nchams: %@ | %s | %zu on re%d | occ %s(%zu)",
                        cs, g_teamField, myTeam, drawn, camOk ? @"ok" : @"-", sh,
                        g_chamMode == 2 ? "NO x-ray" : "x-ray", g_chams.size(), g_chamReapply,
                        g_occOff ? "off" : "on", g_occ.size()];
        @try { _status.text = [_status.text stringByAppendingFormat:@"\n%@", (g_learn || now < g_msgUntil) ? g_learnMsg : diagRenderer(diagR)]; } @catch (...) {}
    }
}
@end

static SCESPDriver *g_driver;

typedef void *(*cf_obs_create)(void *alloc, unsigned long activities, bool repeats, long order, void (^block)(void *obs, unsigned long act));
typedef void *(*cf_main_loop)(void);
typedef void (*cf_add_obs)(void *rl, void *obs, void *mode);

__attribute__((constructor)) static void scesp_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        loadSettings();
        loadAim();
        g_driver = [SCESPDriver new];
        // CoreFoundation is resolved at runtime so the dylib needs no extra link flags.
        cf_obs_create create = (cf_obs_create)dlsym(RTLD_DEFAULT, "CFRunLoopObserverCreateWithHandler");
        cf_main_loop mainLoop = (cf_main_loop)dlsym(RTLD_DEFAULT, "CFRunLoopGetMain");
        cf_add_obs addObs = (cf_add_obs)dlsym(RTLD_DEFAULT, "CFRunLoopAddObserver");
        void **commonModes = (void **)dlsym(RTLD_DEFAULT, "kCFRunLoopCommonModes");
        if (create && mainLoop && addObs && commonModes) {
            // kCFRunLoopBeforeWaiting = 1 << 5
            void *obs = create(nullptr, (1UL << 5), true, 0, ^(void *o, unsigned long act) { [g_driver tick]; });
            addObs(mainLoop(), obs, *commonModes);
            NSLog(@"[SCESP] loaded (runloop observer)");
        } else {
            CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector(tick)];
            dl.preferredFramesPerSecond = 60;
            [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            NSLog(@"[SCESP] loaded (display link fallback)");
        }
    });
}
